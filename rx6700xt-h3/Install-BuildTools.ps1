[CmdletBinding()]
param(
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-NativeBuildHeaders {
    $programFilesX86 = ${env:ProgramFiles(x86)}
    if (-not $programFilesX86) {
        return $false
    }

    $msvcHeader = Get-ChildItem `
        -Path (Join-Path $programFilesX86 "Microsoft Visual Studio\*\*\VC\Tools\MSVC\*\include\stdlib.h") `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $sdkHeader = Get-ChildItem `
        -Path (Join-Path $programFilesX86 "Windows Kits\10\Include\*\ucrt\stdlib.h") `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1
    return [bool]($msvcHeader -and $sdkHeader)
}

if (Test-NativeBuildHeaders) {
    Write-Host "MSVC x64/x86 Build Tools and Windows SDK headers are already installed." -ForegroundColor Green
    exit 0
}
if (-not (Test-Administrator)) {
    throw "Run install-build-tools-rx6700xt-h3.bat from an elevated Command Prompt (Run as administrator)."
}

$downloadDir = Join-Path $env:TEMP "minimax-h3-rx6700xt-prerequisites"
$bootstrapper = Join-Path $downloadDir "vs_BuildTools.exe"
New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null

Write-Host "Downloading the signed Microsoft Visual Studio Build Tools bootstrapper..." -ForegroundColor Cyan
Invoke-WebRequest `
    -Uri "https://aka.ms/vs/17/release/vs_BuildTools.exe" `
    -OutFile $bootstrapper `
    -UseBasicParsing

$signature = Get-AuthenticodeSignature -LiteralPath $bootstrapper
if ($signature.Status -ne "Valid" -or $signature.SignerCertificate.Subject -notmatch "Microsoft Corporation") {
    throw "The Visual Studio Build Tools bootstrapper does not have a valid Microsoft signature."
}

$setupArguments = @(
    "--wait",
    "--norestart",
    "--add", "Microsoft.VisualStudio.Workload.VCTools",
    "--add", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
    "--includeRecommended"
)
if ($Quiet) {
    $setupArguments += "--quiet"
} else {
    $setupArguments += "--passive"
}

Write-Host "Installing MSVC x64/x86 Build Tools and the recommended Windows SDK..." -ForegroundColor Cyan
$process = Start-Process `
    -FilePath $bootstrapper `
    -ArgumentList $setupArguments `
    -Wait `
    -PassThru
if ($process.ExitCode -notin 0, 3010) {
    throw "Visual Studio Build Tools installation failed with exit code $($process.ExitCode)."
}
if (-not (Test-NativeBuildHeaders)) {
    throw "Setup completed, but the required MSVC or Windows SDK headers were not found. Open Visual Studio Installer and add 'C++ build tools' with a Windows SDK."
}

Write-Host "Build Tools prerequisite installed successfully." -ForegroundColor Green
if ($process.ExitCode -eq 3010) {
    Write-Warning "Windows requested a restart. Restart before running the full Triton diagnostic."
} else {
    Write-Host "Close any running ComfyUI process, then run diagnose-rx6700xt-h3.bat -Full -RequireModels."
}
