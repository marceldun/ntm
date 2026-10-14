param(
    [Parameter(Mandatory = $true)][string]$VpsDeviceId,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-f0-9]{32}$')][string]$EnrollmentToken
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ArchiveUrl = 'https://github.com/syncthing/syncthing/releases/download/v1.27.2/syncthing-windows-amd64-v1.27.2.zip'
$ArchiveSha256 = 'b54eb32ea5a9888867195e1f20d649ad9866c0644483434f3f839330c1070d1b'
$InstallRoot = Join-Path $env:LOCALAPPDATA 'VPS-Auto-Sync-v2'
$HomePath = Join-Path $InstallRoot 'config'
$ExePath = Join-Path $InstallRoot 'syncthing.exe'
$Api = 'http://127.0.0.1:28384'
$FolderId = 'pc-downloads'
$FolderLabel = ([char]0x7535)+([char]0x8111)+([char]0x4E0B)+([char]0x8F7D)
$DownloadRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads'
$DownloadPath = Join-Path $DownloadRoot 'VPS-Auto-Sync'

if ($VpsDeviceId -notmatch '^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$') {
    throw 'The VPS device ID in the generated command is invalid.'
}

New-Item -ItemType Directory -Path $InstallRoot,$HomePath,$DownloadPath -Force | Out-Null
$archive = Join-Path $env:TEMP 'syncthing-windows-amd64-v1.27.2.zip'
$staging = Join-Path $env:TEMP 'vps-auto-sync-v2-extract'

Write-Host '[1/6] Installing the verified Windows sync engine...'
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

Write-Host '[2/6] Starting and configuring automatic synchronization...'
$apiKey = $null
$serviceOnline = $false
try {
    [xml]$xml = Get-Content -LiteralPath (Join-Path $HomePath 'config.xml')
    $apiKey = [string]$xml.configuration.gui.apikey
    $headers = @{'X-API-Key' = $apiKey}
    $status = Invoke-RestMethod -Uri "$Api/rest/system/status" -Headers $headers -TimeoutSec 2
    $serviceOnline = [bool]$status.myID
} catch {}

$arguments = "serve --home=`"$HomePath`" --no-browser --no-restart --no-default-folder --gui-address=127.0.0.1:28384 --logflags=0"
if (-not $serviceOnline) {
    Start-Process -FilePath $ExePath -ArgumentList $arguments -WindowStyle Hidden
}

for ($attempt = 0; $attempt -lt 120; $attempt++) {
    try {
        [xml]$xml = Get-Content -LiteralPath (Join-Path $HomePath 'config.xml')
        $apiKey = [string]$xml.configuration.gui.apikey
        if ($apiKey) {
            $headers = @{'X-API-Key' = $apiKey}
            $status = Invoke-RestMethod -Uri "$Api/rest/system/status" -Headers $headers -TimeoutSec 2
            if ($status.myID) { break }
        }
    } catch {}
    Start-Sleep -Milliseconds 500
}
if (-not $apiKey -or -not $status.myID) { throw 'The local Syncthing service did not start.' }

$config = Invoke-RestMethod -Uri "$Api/rest/config" -Headers $headers
$self = @($config.devices) | Where-Object { $_.deviceID -eq $status.myID } | Select-Object -First 1
if (-not $self) { throw 'The local Syncthing identity is missing.' }
$self.name = "PC-$EnrollmentToken"

$vps = @($config.devices) | Where-Object { $_.deviceID -eq $VpsDeviceId } | Select-Object -First 1
if (-not $vps) {
    $vps = [pscustomobject]@{deviceID=$VpsDeviceId; name='VPS'; addresses=@('dynamic'); compression='metadata'}
    $config.devices = @($config.devices) + $vps
}
$vps.addresses = @('dynamic')
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

Write-Host '[3/6] Enabling startup and the Chrome/Edge download folder...'
$startup = [Environment]::GetFolderPath('Startup')
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut((Join-Path $startup 'VPS-Auto-Sync-v2.lnk'))
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
& net.exe use 'V:' /delete /y 2>$null | Out-Null

Write-Host -NoNewline '[4/6] Waiting for the secure VPS connection'
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

Write-Host -NoNewline '[5/6] Running a real PC-to-VPS file replication test'
$testFile = Join-Path $DownloadPath '.v2-end-to-end-test.txt'
[IO.File]::WriteAllText($testFile, 'V2 PC to VPS sync test', [Text.UTF8Encoding]::new($false))
Invoke-RestMethod -Uri "$Api/rest/db/scan?folder=$FolderId" -Headers $headers -Method Post | Out-Null
$replicated = $false
for ($attempt = 0; $attempt -lt 120; $attempt++) {
    try {
        $completion = Invoke-RestMethod -Uri "$Api/rest/db/completion?device=$VpsDeviceId&folder=$FolderId" -Headers $headers
        if ($completion.globalFiles -ge 1 -and $completion.completion -ge 100) { $replicated = $true; break }
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
Write-Host '[6/6] Complete.'
Write-Host 'V2 setup passed: PC -> VPS automatic synchronization is working.' -ForegroundColor Green
Write-Host "Automatic browser download folder: $DownloadPath"
Write-Host 'Close and reopen Chrome or Edge once.'
