[CmdletBinding()]
param(
    [switch]$Full,
    [switch]$RequireModels
)

$ErrorActionPreference = "Stop"
$ProfileDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ProfileDir
$PythonDir = Join-Path $Root "python_env"
$Python = Join-Path $PythonDir "python.exe"
$RocmSdk = Join-Path $PythonDir "Scripts\rocm-sdk.exe"
$Report = Join-Path $Root "rx6700xt-h3-diagnostic.json"

if (-not (Test-Path $Python) -or -not (Test-Path $RocmSdk)) {
    throw "The pinned runtime is missing. Run install-rx6700xt-h3.bat first."
}

& $RocmSdk init
if ($LASTEXITCODE -ne 0) {
    throw "rocm-sdk init failed."
}
$RocmRoot = (& $RocmSdk path --root | Select-Object -Last 1).Trim()
$env:PATH = "$PythonDir;$PythonDir\Scripts;$RocmRoot\bin;$env:PATH"
$env:HIP_PATH = $RocmRoot
$env:ROCM_PATH = $RocmRoot
$env:ROCM_INT8_KITCHEN_PATCH = "force"
$env:TORCH_BACKENDS_CUDA_FLASH_SDP_ENABLED = "0"
$env:TORCH_BACKENDS_CUDA_MEM_EFF_SDP_ENABLED = "0"
$env:TORCH_BACKENDS_CUDA_MATH_SDP_ENABLED = "1"

$arguments = @(
    (Join-Path $ProfileDir "diagnose_runtime.py"),
    "--root", $Root,
    "--report", $Report
)
if ($Full) { $arguments += "--full" }
if ($RequireModels) { $arguments += "--require-models" }

& $Python @arguments
if ($LASTEXITCODE -ne 0) {
    throw "ROCm diagnostic failed. See $Report."
}
