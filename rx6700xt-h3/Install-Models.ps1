[CmdletBinding()]
param(
    [switch]$AcceptLicenses,
    [ValidateSet("fl2va", "ref2va", "both")]
    [string]$Variant = "fl2va",
    [ValidateSet("int4", "w4a8")]
    [string]$TextEncoder = "int4",
    [switch]$IncludeTurbo
)

$ErrorActionPreference = "Stop"
$ProfileDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ProfileDir
$Python = Join-Path $Root "python_env\python.exe"
$Manifest = Join-Path $ProfileDir "models.json"
$Downloader = Join-Path $ProfileDir "download_models.py"

if (-not $AcceptLicenses) {
    Write-Host "Review these licenses before downloading:" -ForegroundColor Yellow
    Write-Host "  https://huggingface.co/MiniMaxAI/MiniMax-H3/blob/main/LICENSE"
    Write-Host "  https://huggingface.co/Winnougan/MiniMax-H3-INT4_Convrot_ComfyUI"
    throw "Pass -AcceptLicenses to confirm that you accept the model licenses."
}
if (-not (Test-Path $Python)) {
    throw "python_env was not found. Run install-rx6700xt-h3.bat first."
}

$arguments = @(
    $Downloader,
    "--manifest", $Manifest,
    "--root", $Root,
    "--variant", $Variant,
    "--text-encoder", $TextEncoder,
    "--accept-licenses"
)
if ($IncludeTurbo) {
    $arguments += "--include-turbo"
}

& $Python @arguments
exit $LASTEXITCODE
