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
    $programRoots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
        Select-Object -Unique
    if (-not $programRoots) {
        return $false
    }

    $msvcHeader = $null
    $sdkHeader = $null
    $vsWhereCandidates = @(
        (Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"),
        (Join-Path $env:ProgramFiles "Microsoft Visual Studio\Installer\vswhere.exe")
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    $vsWhereCommand = Get-Command vswhere.exe -ErrorAction SilentlyContinue
    if ($vsWhereCommand) {
        $vsWhereCandidates += $vsWhereCommand.Source
    }
    foreach ($vsWherePath in ($vsWhereCandidates | Select-Object -Unique)) {
        $installPaths = @(
            & $vsWherePath `
                -products * `
                -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
                -property installationPath 2>$null
        )
        foreach ($installPath in $installPaths) {
            $msvcHeader = Get-ChildItem `
                -Path (Join-Path $installPath "VC\Tools\MSVC\*\include\stdlib.h") `
                -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($msvcHeader) {
                break
            }
        }
        if ($msvcHeader) {
            break
        }
    }

    foreach ($programRoot in $programRoots) {
        if (-not $msvcHeader) {
            $msvcHeader = Get-ChildItem `
                -Path (Join-Path $programRoot "Microsoft Visual Studio\*\*\VC\Tools\MSVC\*\include\stdlib.h") `
                -ErrorAction SilentlyContinue |
                Select-Object -First 1
        }
    }

    $sdkRoots = @()
    foreach ($registryPath in @(
        "HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots"
    )) {
        $registeredRoot = (Get-ItemProperty -LiteralPath $registryPath -ErrorAction SilentlyContinue).KitsRoot10
        if ($registeredRoot) {
            $sdkRoots += $registeredRoot
        }
    }
    foreach ($programRoot in $programRoots) {
        $sdkRoots += Join-Path $programRoot "Windows Kits\10"
    }
    foreach ($sdkRoot in ($sdkRoots | Where-Object { $_ } | Select-Object -Unique)) {
        $sdkHeader = Get-ChildItem `
            -Path (Join-Path $sdkRoot "Include\*\ucrt\stdlib.h") `
            -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($sdkHeader) {
            break
        }
    }
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
