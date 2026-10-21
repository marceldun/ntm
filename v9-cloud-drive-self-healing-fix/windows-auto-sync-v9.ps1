param(
    [Parameter(Mandatory = $true)][string]$VpsDeviceId,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-f0-9]{32}$')][string]$EnrollmentToken,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9-]{8,64}$')][string]$VpsFolderId,
    [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9._-]{3,120}$')][string]$VpsLabel,
    [string]$VpsAddress = 'dynamic'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ArchiveUrl = 'https://github.com/syncthing/syncthing/releases/download/v1.27.2/syncthing-windows-amd64-v1.27.2.zip'
$ArchiveSha256 = 'b54eb32ea5a9888867195e1f20d649ad9866c0644483434f3f839330c1070d1b'
$InstallRoot = Join-Path $env:LOCALAPPDATA 'VPS-Auto-Sync-v9'
$HomePath = Join-Path $InstallRoot 'config'
$ExePath = Join-Path $InstallRoot 'syncthing.exe'
$PortFile = Join-Path $InstallRoot 'gui-port.txt'
$LogPath = Join-Path $InstallRoot 'syncthing-v9.log'
$StdoutPath = Join-Path $InstallRoot 'syncthing-v9.stdout.log'
$StderrPath = Join-Path $InstallRoot 'syncthing-v9.stderr.log'
$WatchdogPath = Join-Path $InstallRoot 'syncthing-watchdog-v9.vbs'
$FolderId = $VpsFolderId
$FolderLabel = $VpsLabel
$DownloadRoot = 'D:\'
$DownloadPath = Join-Path $DownloadRoot $VpsLabel

if ($VpsDeviceId -notmatch '^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$') {
    throw 'The VPS device ID in the generated command is invalid.'
}
if (-not (Test-Path -LiteralPath 'D:\')) {
    throw 'Drive D: does not exist. Connect or create the D: drive, then run this same command again.'
}

New-Item -ItemType Directory -Path $InstallRoot,$HomePath,$DownloadPath -Force | Out-Null
$archive = Join-Path $env:TEMP 'syncthing-windows-amd64-v1.27.2.zip'
$staging = Join-Path $env:TEMP 'vps-auto-sync-v9-extract'

Write-Host '[1/7] Installing the verified Windows sync engine...'
if (-not (Test-Path -LiteralPath $ExePath)) {
    Invoke-WebRequest -UseBasicParsing -Uri $ArchiveUrl -OutFile $archive
    $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $ArchiveSha256) { throw 'Syncthing archive SHA-256 verification failed.' }
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -LiteralPath $archive -DestinationPath $staging -Force
    $downloadedExe = Get-ChildItem -LiteralPath $staging -Filter 'syncthing.exe' -Recurse | Select-Object -First 1
    if (-not $downloadedExe) { throw 'The Syncthing executable is missing from the verified archive.' }
    Copy-Item -LiteralPath $downloadedExe.FullName -Destination $ExePath -Force
}

if (-not (Test-Path -LiteralPath (Join-Path $HomePath 'config.xml'))) {
    & $ExePath generate "--home=$HomePath" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Syncthing configuration generation failed.' }
}

Write-Host '[2/7] Starting and configuring automatic synchronization...'
function Get-FreeGuiPort {
    foreach ($candidate in 28384..28434) {
        $listener = $null
        try {
            $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $candidate)
            $listener.Start()
            return $candidate
        } catch {} finally {
            if ($listener) { $listener.Stop() }
        }
    }
    throw 'No free local GUI port was found.'
}

function Get-StartupFailureText {
    $lines = @()
    foreach ($file in @($LogPath,$StdoutPath,$StderrPath)) {
        if (Test-Path -LiteralPath $file) {
            $lines += "--- $file ---"
            $lines += @(Get-Content -LiteralPath $file -Tail 25 -ErrorAction SilentlyContinue)
        }
    }
    if (-not $lines) { return 'Syncthing produced no log output.' }
    return ($lines -join [Environment]::NewLine)
}

$oldRoots = @(
    (Join-Path $env:LOCALAPPDATA 'VPS-Auto-Sync-v2'),
    (Join-Path $env:LOCALAPPDATA 'VPS-Auto-Sync-v3'),
    (Join-Path $env:LOCALAPPDATA 'VPS-Auto-Sync-v4'),
    (Join-Path $env:LOCALAPPDATA 'VPS-Auto-Sync-v5'),
    (Join-Path $env:LOCALAPPDATA 'VPS-Auto-Sync-v6'),
    (Join-Path $env:LOCALAPPDATA 'VPS-Auto-Sync-v7')
)
Get-Process -Name syncthing -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        foreach ($oldRoot in $oldRoots) {
            if ($_.Path -like "$oldRoot\*") { Stop-Process -Id $_.Id -Force; break }
        }
    } catch {}
}

[xml]$xml = Get-Content -LiteralPath (Join-Path $HomePath 'config.xml')
$apiKey = [string]$xml.configuration.gui.apikey
$headers = @{'X-API-Key' = $apiKey}
$serviceOnline = $false
$savedPort = 0
if (Test-Path -LiteralPath $PortFile) { [void][int]::TryParse((Get-Content $PortFile -Raw).Trim(), [ref]$savedPort) }
if ($savedPort -ge 1024 -and $savedPort -le 65535) {
    $Api = "http://127.0.0.1:$savedPort"
    try {
        $status = Invoke-RestMethod -Uri "$Api/rest/system/status" -Headers $headers -TimeoutSec 2
        $serviceOnline = [bool]$status.myID
    } catch {}
}

if (-not $serviceOnline) {
    Get-Process -Name syncthing -ErrorAction SilentlyContinue | ForEach-Object {
        try { if ($_.Path -like "$InstallRoot\*") { Stop-Process -Id $_.Id -Force } } catch {}
    }
    for ($launch = 1; $launch -le 2 -and -not $serviceOnline; $launch++) {
        $GuiPort = Get-FreeGuiPort
        $Api = "http://127.0.0.1:$GuiPort"
        @($LogPath,$StdoutPath,$StderrPath) | ForEach-Object { Remove-Item -LiteralPath $_ -Force -ErrorAction SilentlyContinue }
        $argumentList = @(
            'serve','--home=config','--no-browser','--no-restart','--no-upgrade','--no-default-folder',
            "--gui-address=127.0.0.1:$GuiPort",'--logfile=syncthing-v9.log','--log-max-old-files=0','--logflags=0'
        )
        $process = Start-Process -FilePath $ExePath -WorkingDirectory $InstallRoot -ArgumentList $argumentList `
            -WindowStyle Hidden -RedirectStandardOutput $StdoutPath -RedirectStandardError $StderrPath -PassThru
        Write-Host -NoNewline "  launch $launch, local port $GuiPort"
        for ($second = 0; $second -lt 30; $second++) {
            Start-Sleep -Seconds 1
            $process.Refresh()
            if ($process.HasExited) { break }
            try {
                $status = Invoke-RestMethod -Uri "$Api/rest/system/status" -Headers $headers -TimeoutSec 2
                if ($status.myID) { $serviceOnline = $true; break }
            } catch {}
            Write-Host -NoNewline '.'
        }
        Write-Host ''
        if ($serviceOnline) {
            Set-Content -LiteralPath $PortFile -Value $GuiPort -Encoding ASCII
            break
        }
        if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
        Write-Host "  launch $launch failed; automatically retrying with a new port."
    }
}
if (-not $serviceOnline) { throw ("Local Syncthing failed to start.`n" + (Get-StartupFailureText)) }

Write-Host '[3/7] Local service is running; applying the sync configuration...'
$guiPort = $Api.Split(':')[-1]
$arguments = "serve --home=`"$HomePath`" --no-browser --no-restart --no-upgrade --no-default-folder --gui-address=127.0.0.1:$guiPort --logfile=`"$LogPath`" --log-max-old-files=0 --logflags=0"

$config = Invoke-RestMethod -Uri "$Api/rest/config" -Headers $headers
$self = @($config.devices) | Where-Object { $_.deviceID -eq $status.myID } | Select-Object -First 1
if (-not $self) { throw 'The local Syncthing identity is missing.' }
$self.name = "PC-$EnrollmentToken"

$vps = @($config.devices) | Where-Object { $_.deviceID -eq $VpsDeviceId } | Select-Object -First 1
if (-not $vps) {
    $vps = [pscustomobject]@{deviceID=$VpsDeviceId; name=$VpsLabel; addresses=@($VpsAddress); compression='metadata'; paused=$false}
    $config.devices = @($config.devices) + $vps
}
$vps.name = $VpsLabel
$vps.addresses = @($VpsAddress)
$vps.paused = $false

$folder = @($config.folders) | Where-Object { $_.id -eq $FolderId } | Select-Object -First 1
if (-not $folder) {
    $folder = [pscustomobject]@{
        id=$FolderId; label=$FolderLabel; path=$DownloadPath; type='sendreceive'
        rescanIntervalS=10; fsWatcherEnabled=$true; fsWatcherDelayS=2; ignorePerms=$true
        devices=@([pscustomobject]@{deviceID=$status.myID},[pscustomobject]@{deviceID=$VpsDeviceId})
        versioning=[pscustomobject]@{type='simple'; params=[pscustomobject]@{keep='10'}}
    }
    $config.folders = @($config.folders | Where-Object { $_.id -ne 'default' }) + $folder
} else {
    $folder.label = $FolderLabel
    $folder.path = $DownloadPath
    $folder.type = 'sendreceive'
    $folder.rescanIntervalS = 10
    $folder.fsWatcherEnabled = $true
    $folder.fsWatcherDelayS = 2
    $shared = @($folder.devices | ForEach-Object {$_.deviceID})
    if ($shared -notcontains $status.myID) { $folder.devices = @($folder.devices) + [pscustomobject]@{deviceID=$status.myID} }
    if ($shared -notcontains $VpsDeviceId) { $folder.devices = @($folder.devices) + [pscustomobject]@{deviceID=$VpsDeviceId} }
}

$config.options.listenAddresses = @('tcp://0.0.0.0:22000','quic://0.0.0.0:22000','dynamic+https://relays.syncthing.net/endpoint')
$config.options.globalAnnounceServers = @('default')
$config.options.globalAnnounceEnabled = $true
$config.options.localAnnounceEnabled = $true
$config.options.relaysEnabled = $true
$config.options.natEnabled = $true
$config.options.reconnectionIntervalS = 5
$body = $config | ConvertTo-Json -Depth 50 -Compress
$bodyBytes = [Text.Encoding]::UTF8.GetBytes($body)
Invoke-RestMethod -Uri "$Api/rest/config" -Headers $headers -Method Put -ContentType 'application/json; charset=utf-8' -Body $bodyBytes | Out-Null

Write-Host '[4/7] Enabling startup and restoring browser download controls...'
$startup = [Environment]::GetFolderPath('Startup')
@('VPS-Auto-Sync-v2.lnk','VPS-Auto-Sync-v3.lnk','VPS-Auto-Sync-v4.lnk','VPS-Auto-Sync-v5.lnk','VPS-Auto-Sync-v6.lnk','VPS-Auto-Sync-v7.lnk') | ForEach-Object {
    Remove-Item -LiteralPath (Join-Path $startup $_) -Force -ErrorAction SilentlyContinue
}
$shell = New-Object -ComObject WScript.Shell
$watchdog = @"
Option Explicit
Dim shell, fso, installRoot, exePath, arguments, processes, process, running
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
installRoot = shell.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\VPS-Auto-Sync-v9"
exePath = installRoot & "\syncthing.exe"
arguments = "serve --home=" & Chr(34) & installRoot & "\config" & Chr(34) & " --no-browser --no-restart --no-upgrade --no-default-folder --gui-address=127.0.0.1:$guiPort --logfile=" & Chr(34) & installRoot & "\syncthing-v9.log" & Chr(34) & " --log-max-old-files=0 --logflags=0"
Do
  If fso.DriveExists("D:") Then
    running = False
    Set processes = GetObject("winmgmts:\\.\root\cimv2").ExecQuery("Select ExecutablePath from Win32_Process where Name='syncthing.exe'")
    For Each process In processes
      If Not IsNull(process.ExecutablePath) Then
        If LCase(process.ExecutablePath) = LCase(exePath) Then running = True
      End If
    Next
    If Not running Then shell.Run Chr(34) & exePath & Chr(34) & " " & arguments, 0, False
  End If
  WScript.Sleep 10000
Loop
"@
[IO.File]::WriteAllText($WatchdogPath, $watchdog, [Text.Encoding]::ASCII)
$shortcut = $shell.CreateShortcut((Join-Path $startup 'VPS-Auto-Sync-v9.lnk'))
$shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
$shortcut.Arguments = "//B //NoLogo `"$WatchdogPath`""
$shortcut.WorkingDirectory = $InstallRoot
$shortcut.WindowStyle = 7
$shortcut.Save()

Write-Host -NoNewline '[5/7] Waiting for the secure VPS connection'
$connected = $false
for ($attempt = 0; $attempt -lt 180; $attempt++) {
    try {
        $connections = Invoke-RestMethod -Uri "$Api/rest/system/connections" -Headers $headers -TimeoutSec 3
        if ($connections.connections.$VpsDeviceId.connected) { $connected = $true; break }
    } catch {}
    if (($attempt + 1) % 10 -eq 0) { Write-Host -NoNewline '.' }
    Start-Sleep -Seconds 1
}
Write-Host ''
if (-not $connected) { throw 'The PC could not connect to the VPS through Syncthing direct or relay transport.' }

Write-Host -NoNewline '[6/7] Testing automatic PC-to-VPS replication without a manual scan'
$testName = '.v9-auto-sync-test-' + ([guid]::NewGuid().ToString('N')) + '.txt'
$testFile = Join-Path $DownloadPath $testName
[IO.File]::WriteAllText($testFile, 'V9 PC to VPS sync test', [Text.UTF8Encoding]::new($false))
$encodedFolder = [Uri]::EscapeDataString($FolderId)
$encodedFile = [Uri]::EscapeDataString($testName)
$indexed = $false
for ($attempt = 0; $attempt -lt 120; $attempt++) {
    try {
        $fileInfo = Invoke-RestMethod -Uri "$Api/rest/db/file?folder=$encodedFolder&file=$encodedFile" -Headers $headers
        if ($fileInfo.local.name -eq $testName -and -not $fileInfo.local.deleted) { $indexed = $true; break }
    } catch {}
    if (($attempt + 1) % 10 -eq 0) { Write-Host -NoNewline '.' }
    Start-Sleep -Seconds 1
}
if (-not $indexed) { throw 'The D-drive file was not detected automatically within 120 seconds.' }
$replicated = $false
for ($attempt = 0; $attempt -lt 120; $attempt++) {
    try {
        $completion = Invoke-RestMethod -Uri "$Api/rest/db/completion?device=$VpsDeviceId&folder=$FolderId" -Headers $headers
        if ($completion.globalItems -ge 1 -and $completion.completion -ge 100) { $replicated = $true; break }
    } catch {}
    if (($attempt + 1) % 10 -eq 0) { Write-Host -NoNewline '.' }
    Start-Sleep -Seconds 1
}
Write-Host ''
if (-not $replicated) { throw 'The PC connected, but the end-to-end VPS file replication test did not finish.' }
Remove-Item -LiteralPath $testFile -Force

$desktopName = 'VPS Multi Server Sync.lnk'
$desktopShortcut = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) $desktopName))
$desktopShortcut.TargetPath = $DownloadRoot
$desktopShortcut.Save()

Write-Host ''
Write-Host '[7/7] Complete.'
Write-Host 'V9 setup passed: PC -> VPS automatic synchronization is working.' -ForegroundColor Green
Write-Host "Imported VPS: $VpsLabel"
Write-Host "Automatic sync folder: $DownloadPath"
Write-Host 'Chrome and Edge download locations remain under your control.'
$global:LASTEXITCODE = 0
