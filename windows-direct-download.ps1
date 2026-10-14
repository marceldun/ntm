$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Server = '202.155.14.177'
$Username = 'marcel'
$Password = '456qwe456'
$DriveLetter = 'V:'
$FolderName = ([char]0x7535)+([char]0x8111)+([char]0x4E0B)+([char]0x8F7D)
$Candidates = @(
    @{ Base = "https://$Server"; Unc = "\\$Server@SSL\DavWWWRoot\dav" },
    @{ Base = "https://${Server}:8443"; Unc = "\\$Server@SSL@8443\DavWWWRoot\dav" }
)

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    $argument = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $process = Start-Process powershell.exe -Verb RunAs -ArgumentList $argument -Wait -PassThru
    exit $process.ExitCode
}

$temporary = Join-Path $env:TEMP 'vps-cloud-drive-cert.pem'
$oldValidation = [Net.ServicePointManager]::ServerCertificateValidationCallback
try {
    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    $selected = $null
    foreach ($candidate in $Candidates) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri ($candidate.Base + '/certificate.pem') -OutFile $temporary -TimeoutSec 10
            $selected = $candidate
            break
        } catch {}
    }
} finally {
    [Net.ServicePointManager]::ServerCertificateValidationCallback = $oldValidation
}
if (-not $selected) { throw 'Cannot reach the VPS cloud drive on port 443 or 8443.' }

$certificate = New-Object Security.Cryptography.X509Certificates.X509Certificate2($temporary)
$store = New-Object Security.Cryptography.X509Certificates.X509Store('Root','LocalMachine')
$store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
try {
    if (-not ($store.Certificates | Where-Object Thumbprint -eq $certificate.Thumbprint)) {
        $store.Add($certificate)
    }
} finally { $store.Close() }
Remove-Item $temporary -Force -ErrorAction SilentlyContinue

$webClient = Get-Service -Name WebClient -ErrorAction Stop
Set-Service -Name WebClient -StartupType Automatic
$parameters = 'HKLM:\SYSTEM\CurrentControlSet\Services\WebClient\Parameters'
New-ItemProperty -Path $parameters -Name FileSizeLimitInBytes -PropertyType DWord -Value ([uint32]::MaxValue) -Force | Out-Null
New-ItemProperty -Path $parameters -Name BasicAuthLevel -PropertyType DWord -Value 1 -Force | Out-Null
if ($webClient.Status -eq 'Running') { Restart-Service WebClient -Force } else { Start-Service WebClient }

foreach ($credentialTarget in @($Server, "$Server@SSL", "$Server@SSL@8443")) {
    cmdkey.exe "/add:$credentialTarget" "/user:$Username" "/pass:$Password" | Out-Null
}
& net.exe use $DriveLetter /delete /y 2>$null | Out-Null
& net.exe use $DriveLetter $selected.Unc $Password "/user:$Username" '/persistent:yes' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Failed to map $DriveLetter (exit code $LASTEXITCODE)." }

$downloadPath = $selected.Unc.TrimEnd('\') + '\' + $FolderName
if (-not (Test-Path -LiteralPath $downloadPath)) { New-Item -ItemType Directory -Path $downloadPath | Out-Null }

foreach ($policy in @('HKCU:\Software\Policies\Google\Chrome','HKCU:\Software\Policies\Microsoft\Edge')) {
    New-Item -Path $policy -Force | Out-Null
    New-ItemProperty -Path $policy -Name DownloadDirectory -PropertyType String -Value $downloadPath -Force | Out-Null
    New-ItemProperty -Path $policy -Name PromptForDownloadLocation -PropertyType DWord -Value 0 -Force | Out-Null
}

$testFile = Join-Path $downloadPath '.vps-direct-download-test.txt'
[IO.File]::WriteAllText($testFile, 'VPS direct download OK', [Text.UTF8Encoding]::new($false))
if ([IO.File]::ReadAllText($testFile) -ne 'VPS direct download OK') { throw 'VPS cloud drive write test failed.' }
Remove-Item $testFile -Force

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'VPS-Cloud-Drive.lnk'))
$shortcut.TargetPath = $downloadPath
$shortcut.Save()

Write-Host ''
Write-Host 'Success: Chrome and Edge downloads now go directly to the VPS and then sync to Android.' -ForegroundColor Green
Write-Host "Cloud drive: $DriveLetter"
Write-Host "Download directory: $downloadPath"
Write-Host 'Close and reopen the browser once to apply its download policy.'
