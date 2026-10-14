param(
    [Parameter(Mandatory = $true)][string]$VpsDeviceId,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-f0-9]{32}$')][string]$EnrollmentToken,
    [string]$VpsAddress = 'dynamic'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ArchiveUrl = 'https://github.com/syncthing/syncthing/releases/download/v1.27.2/syncthing-windows-amd64-v1.27.2.zip'
$ArchiveSha256 = 'b54eb32ea5a9888867195e1f20d649ad9866c0644483434f3f839330c1070d1b'
$InstallRoot = Join-Path $env:LOCALAPPDATA 'VPS-Auto-Sync-v4'
$HomePath = Join-Path $InstallRoot 'config'
$ExePath = Join-Path $InstallRoot 'syncthing.exe'
$PortFile = Join-Path $InstallRoot 'gui-port.txt'
$LogPath = Join-Path $InstallRoot 'syncthing-v4.log'
$StdoutPath = Join-Path $InstallRoot 'syncthing-v4.stdout.log'
$StderrPath = Join-Path $InstallRoot 'syncthing-v4.stderr.log'
$FolderId = 'pc-downloads'
$FolderLabel = ([char]0x7535)+([char]0x8111)+([char]0x4E0B)+([char]0x8F7D)
$DownloadRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads'
$DownloadPath = Join-Path $DownloadRoot 'VPS-Auto-Sync'

if ($VpsDeviceId -notmatch '^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$') {
    throw 'The VPS device ID in the generated command is invalid.'
}

New-Item -ItemType Directory -Path $InstallRoot,$HomePath,$DownloadPath -Force | Out-Null
$archive = Join-Path $env:TEMP 'syncthing-windows-amd64-v1.27.2.zip'
$staging = Join-Path $env:TEMP 'vps-auto-sync-v4-extract'

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

$oldRoot = Join-Path $env:LOCALAPPDATA 'VPS-Auto-Sync-v2'
Get-Process -Name syncthing -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        if ($_.Path -like "$oldRoot\*") { Stop-Process -Id $_.Id -Force }
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
            "--gui-address=127.0.0.1:$GuiPort",'--logfile=syncthing-v4.log','--log-max-old-files=0','--logflags=0'
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
$arguments = "serve --home=config --no-browser --no-restart --no-upgrade --no-default-folder --gui-address=127.0.0.1:$($Api.Split(':')[-1]) --logfile=syncthing-v4.log --log-max-old-files=0 --logflags=0"

$config = Invoke-RestMethod -Uri "$Api/rest/config" -Headers $headers
$self = @($config.devices) | Where-Object { $_.deviceID -eq $status.myID } | Select-Object -First 1
if (-not $self) { throw 'The local Syncthing identity is missing.' }
$self.name = "PC-$EnrollmentToken"

$vps = @($config.devices) | Where-Object { $_.deviceID -eq $VpsDeviceId } | Select-Object -First 1
if (-not $vps) {
    $vps = [pscustomobject]@{deviceID=$VpsDeviceId; name='VPS'; addresses=@($VpsAddress); compression='metadata'; paused=$false}
    $config.devices = @($config.devices) + $vps
}
$vps.addresses = @($VpsAddress)
$vps.paused = $false

$folder = @($config.folders) | Where-Object { $_.id -eq $FolderId } | Select-Object -First 1
if (-not $folder) {
    $folder = [pscustomobject]@{
        id=$FolderId; label=$FolderLabel; path=$DownloadPath; type='sendreceive'
        rescanIntervalS=3600; fsWatcherEnabled=$true; fsWatcherDelayS=5; ignorePerms=$true
        devices=@([pscustomobject]@{deviceID=$status.myID},[pscustomobject]@{deviceID=$VpsDeviceId})
        versioning=[pscustomobject]@{type='simple'; params=[pscustomobject]@{keep='10'}}
    }
    $config.folders = @($config.folders | Where-Object { $_.id -ne 'default' }) + $folder
} else {
    $folder.label = $FolderLabel
    $folder.path = $DownloadPath
    $folder.type = 'sendreceive'
    $folder.fsWatcherEnabled = $true
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
Invoke-RestMethod -Uri "$Api/rest/config" -Headers $headers -Method Put -ContentType 'application/json' -Body $body | Out-Null

Write-Host '[4/7] Enabling startup and the Chrome/Edge download folder...'
$startup = [Environment]::GetFolderPath('Startup')
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut((Join-Path $startup 'VPS-Auto-Sync-v4.lnk'))
$shortcut.TargetPath = $ExePath
$shortcut.Arguments = $arguments
$shortcut.WorkingDirectory = $InstallRoot
$shortcut.WindowStyle = 7
$shortcut.Save()

foreach ($policy in @('HKCU:\Software\Policies\Google\Chrome','HKCU:\Software\Policies\Microsoft\Edge')) {
    New-Item -Path $policy -Force | Out-Null
    New-ItemProperty -Path $policy -Name DownloadDirectory -PropertyType String -Value $DownloadPath -Force | Out-Null
    New-ItemProperty -Path $policy -Name PromptForDownloadLocation -PropertyType DWord -Value 0 -Force | Out-Null
}
& gpupdate.exe '/Target:User' '/Force' | Out-Null
$global:LASTEXITCODE = 0

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

Write-Host -NoNewline '[6/7] Running a real PC-to-VPS file replication test'
$testFile = Join-Path $DownloadPath '.v4-end-to-end-test.txt'
[IO.File]::WriteAllText($testFile, 'V4 PC to VPS sync test', [Text.UTF8Encoding]::new($false))
Invoke-RestMethod -Uri "$Api/rest/db/scan?folder=$FolderId" -Headers $headers -Method Post | Out-Null
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
Invoke-RestMethod -Uri "$Api/rest/db/scan?folder=$FolderId" -Headers $headers -Method Post | Out-Null

$desktopShortcut = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'VPS-Auto-Sync.lnk'))
$desktopShortcut.TargetPath = $DownloadPath
$desktopShortcut.Save()

Write-Host ''
Write-Host '[7/7] Complete.'
Write-Host 'V4 setup passed: PC -> VPS automatic synchronization is working.' -ForegroundColor Green
Write-Host "Automatic browser download folder: $DownloadPath"
Write-Host 'Chrome and Edge download policy refresh was requested automatically.'
$global:LASTEXITCODE = 0
