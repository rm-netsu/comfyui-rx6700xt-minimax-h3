[CmdletBinding()]
param(
    [switch]$Lan,
    [switch]$ConfigureFirewall,
    [ValidateSet("Balanced", "Safe")]
    [string]$Profile = "Balanced",
    [ValidateRange(1, 65535)]
    [int]$Port = 8188,
    [ValidateRange(0.25, 4.0)]
    [double]$ReserveVramGiB = 0.8,
    [switch]$NoBrowser,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ExtraArgs
)

$ErrorActionPreference = "Stop"
$ProfileDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ProfileDir
$PythonDir = Join-Path $Root "python_env"
$Python = Join-Path $PythonDir "python.exe"
$RocmSdk = Join-Path $PythonDir "Scripts\rocm-sdk.exe"
$GpuLog = Join-Path $Root "gpu_detect_debug.log"

if (-not (Test-Path $Python) -or -not (Test-Path $RocmSdk)) {
    throw "The pinned runtime is missing. Run install-rx6700xt-h3.bat first."
}

$detectedArch = (& $Python (Join-Path $Root "detect_gpu.py") 2>$GpuLog | Select-Object -Last 1).Trim()
if ($LASTEXITCODE -ne 0 -or $detectedArch -ne "gfx1031") {
    throw "Expected gfx1031 but detected '$detectedArch'. See $GpuLog. No HSA architecture override will be used."
}

& $RocmSdk init
if ($LASTEXITCODE -ne 0) {
    throw "rocm-sdk init failed. Run diagnose-rx6700xt-h3.bat for details."
}
$RocmRoot = (& $RocmSdk path --root | Select-Object -Last 1).Trim()
if ($LASTEXITCODE -ne 0 -or -not $RocmRoot) {
    throw "Could not resolve the ROCm SDK root."
}

$env:PATH = "$PythonDir;$PythonDir\Scripts;$RocmRoot\bin;$env:PATH"
$env:HIP_PATH = $RocmRoot
$env:ROCM_PATH = $RocmRoot

# RDNA2-safe backend policy. Do not add HSA_OVERRIDE_GFX_VERSION here.
$env:TORCH_BACKENDS_CUDA_FLASH_SDP_ENABLED = "0"
$env:TORCH_BACKENDS_CUDA_MEM_EFF_SDP_ENABLED = "0"
$env:TORCH_BACKENDS_CUDA_MATH_SDP_ENABLED = "1"
$env:TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL = "0"
$env:ROCM_INT8_KITCHEN_PATCH = "force"
$env:COMFYUI_ENABLE_MIOPEN = "0"
$env:TRITON_PRINT_AUTOTUNING = "0"
$env:TRITON_CACHE_AUTOTUNING = "1"
$env:PYTORCH_TUNABLEOP_ENABLED = "0"
$env:TRITON_CACHE_DIR = Join-Path $Root "triton-cache"
$env:PYTORCH_TUNABLEOP_CACHE_DIR = Join-Path $Root "tunableop-cache"
New-Item -ItemType Directory -Path $env:TRITON_CACHE_DIR -Force | Out-Null
New-Item -ItemType Directory -Path $env:PYTORCH_TUNABLEOP_CACHE_DIR -Force | Out-Null

$RocmDevel = Join-Path $PythonDir "Lib\site-packages\_rocm_sdk_devel\bin"
if (Test-Path $RocmDevel) {
    $env:MIOPEN_SYSTEM_DB_PATH = $RocmDevel
    $env:ROCBLAS_TENSILE_DB_PATH = Join-Path $RocmDevel "rocblas"
    $env:ROCBLAS_TENSILE_LIBPATH = Join-Path $RocmDevel "rocblas\library"
}

$ListenAddress = "127.0.0.1"
if ($Lan) {
    $ListenAddress = "0.0.0.0"
    if ($ConfigureFirewall) {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw "-ConfigureFirewall requires an elevated PowerShell window."
        }
        $ruleName = "ComfyUI MiniMax H3 RX6700XT TCP $Port"
        if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule `
                -DisplayName $ruleName `
                -Direction In `
                -Action Allow `
                -Protocol TCP `
                -LocalPort $Port `
                -Profile Private `
                -RemoteAddress LocalSubnet | Out-Null
            Write-Host "Created a Private/LocalSubnet-only firewall rule for TCP $Port." -ForegroundColor Green
        }
    } else {
        Write-Warning "LAN mode has no authentication. Allow TCP $Port only on a Private network and only from LocalSubnet."
    }
}

$requiredModels = @(
    "models\diffusion_models\minimax_h3_fl2va_pruned-w4a8_convrot_pruned.safetensors",
    "models\text_encoders\qwen3vl_32b_minimax_h3-int4_convrot.safetensors",
    "models\vae\minimax_h3_video_vae_fp16.safetensors",
    "models\vae\minimax_h3_audio_vae_fp32.safetensors"
)
$missing = @($requiredModels | Where-Object { -not (Test-Path (Join-Path $Root $_)) })
if ($missing.Count -gt 0) {
    Write-Warning "The default H3 workflow is missing $($missing.Count) model file(s). Run download-minimax-h3-models.bat -AcceptLicenses."
}

$ComfyArgs = @(
    (Join-Path $Root "main.py"),
    "--listen", $ListenAddress,
    "--port", $Port.ToString(),
    "--reserve-vram", $ReserveVramGiB.ToString([Globalization.CultureInfo]::InvariantCulture),
    "--cache-none",
    "--disable-smart-memory",
    "--disable-pinned-memory",
    "--use-quad-cross-attention",
    "--disable-triton-backend",
    "--disable-api-nodes"
)

if ($Profile -eq "Balanced") {
    $ComfyArgs += @("--enable-dynamic-vram", "--vram-headroom", "0.8")
} else {
    $ComfyArgs += @("--disable-dynamic-vram", "--lowvram", "--disable-cuda-graphs")
}
if (-not $NoBrowser -and -not $Lan) {
    $ComfyArgs += "--auto-launch"
}
if ($ExtraArgs) {
    $ComfyArgs += $ExtraArgs
}

Write-Host "`nMiniMax H3 / RX 6700 XT profile" -ForegroundColor Cyan
Write-Host "GPU arch : $detectedArch"
Write-Host "ROCm     : $RocmRoot"
Write-Host "Mode     : $Profile"
Write-Host "URL      : http://$ListenAddress`:$Port"
Write-Host "Workflow : sample-workflows\MiniMax_H3_RX6700XT_W4A8_2s.json"
Write-Host ""

Push-Location $Root
try {
    & $Python @ComfyArgs
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
