[CmdletBinding()]
param(
    [switch]$Lan,
    [switch]$ConfigureFirewall,
    [ValidateSet("Performance64GB", "Balanced", "Safe")]
    [string]$Profile = "Performance64GB",
    [ValidateRange(1, 65535)]
    [int]$Port = 8188,
    [ValidateRange(0.25, 4.0)]
    [double]$ReserveVramGiB = 0.8,
    [ValidateRange(1.0, 16.0)]
    [double]$PinnedMemoryLimitGiB = 8.0,
    [ValidateRange(1, 4)]
    [int]$AsyncOffloadStreams = 2,
    [ValidateSet("Recycle", "Flush", "None")]
    [string]$PostPromptStrategy = "Recycle",
    [switch]$DisablePostPromptMemoryFlush,
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
$GpuResultLog = Join-Path $Root "gpu_detect_result.log"

function ConvertTo-NativeArgument {
    param([AllowEmptyString()][string]$Argument)

    if ($null -eq $Argument) {
        $Argument = ""
    }
    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') {
        return $Argument
    }

    # Quote according to CommandLineToArgvW / the Microsoft C runtime rules.
    # Start-Process joins ArgumentList into one command line on Windows
    # PowerShell 5.1, so paths containing spaces must be escaped explicitly.
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append([char]34)
    $backslashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq [char]92) {
            $backslashes++
            continue
        }
        if ($character -eq [char]34) {
            for ($index = 0; $index -lt (2 * $backslashes + 1); $index++) {
                [void]$builder.Append([char]92)
            }
            [void]$builder.Append([char]34)
        } else {
            for ($index = 0; $index -lt $backslashes; $index++) {
                [void]$builder.Append([char]92)
            }
            [void]$builder.Append($character)
        }
        $backslashes = 0
    }
    for ($index = 0; $index -lt (2 * $backslashes); $index++) {
        [void]$builder.Append([char]92)
    }
    [void]$builder.Append([char]34)
    return $builder.ToString()
}

function Invoke-NativeProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [string]$RedirectStandardOutput,
        [string]$RedirectStandardError
    )

    # Start-Process keeps native stderr outside PowerShell's error stream.
    # This prevents ordinary Python/ROCm diagnostics from becoming a
    # terminating NativeCommandError under ErrorActionPreference=Stop.
    $nativeArguments = @(
        $ArgumentList | ForEach-Object { ConvertTo-NativeArgument ([string]$_) }
    )
    $startParameters = @{
        FilePath = $FilePath
        ArgumentList = $nativeArguments
        Wait = $true
        PassThru = $true
        NoNewWindow = $true
    }
    if ($RedirectStandardOutput) {
        $startParameters["RedirectStandardOutput"] = $RedirectStandardOutput
    }
    if ($RedirectStandardError) {
        $startParameters["RedirectStandardError"] = $RedirectStandardError
    }
    return Start-Process @startParameters
}

if (-not (Test-Path $Python) -or -not (Test-Path $RocmSdk)) {
    throw "The pinned runtime is missing. Run install-rx6700xt-h3.bat first."
}

$ComputerSystem = Get-CimInstance Win32_ComputerSystem
$TotalRamGiB = [math]::Round([double]$ComputerSystem.TotalPhysicalMemory / 1GB, 1)
if ($Profile -eq "Performance64GB" -and $TotalRamGiB -lt 56.0) {
    throw "Performance64GB requires at least 56 GiB of physical RAM. Detected $TotalRamGiB GiB. Use -Profile Balanced."
}

$gpuProcess = Invoke-NativeProcess `
    -FilePath $Python `
    -ArgumentList @((Join-Path $Root "detect_gpu.py")) `
    -RedirectStandardOutput $GpuResultLog `
    -RedirectStandardError $GpuLog
$detectedArch = [string](
    Get-Content -LiteralPath $GpuResultLog -ErrorAction SilentlyContinue |
        Where-Object { $_.Trim() } |
        Select-Object -Last 1
)
$detectedArch = $detectedArch.Trim()
if ($gpuProcess.ExitCode -ne 0 -or $detectedArch -ne "gfx1031") {
    throw "Expected gfx1031 but detected '$detectedArch'. See $GpuLog. No HSA architecture override will be used."
}

$rocmInitProcess = Invoke-NativeProcess -FilePath $RocmSdk -ArgumentList @("init")
if ($rocmInitProcess.ExitCode -ne 0) {
    throw "rocm-sdk init failed. Run diagnose-rx6700xt-h3.bat for details."
}
$RocmPathLog = Join-Path $Root "rocm_sdk_root.log"
$RocmPathErrorLog = Join-Path $Root "rocm_sdk_path_debug.log"
$rocmPathProcess = Invoke-NativeProcess `
    -FilePath $RocmSdk `
    -ArgumentList @("path", "--root") `
    -RedirectStandardOutput $RocmPathLog `
    -RedirectStandardError $RocmPathErrorLog
$RocmRoot = [string](
    Get-Content -LiteralPath $RocmPathLog -ErrorAction SilentlyContinue |
        Where-Object { $_.Trim() } |
        Select-Object -Last 1
)
$RocmRoot = $RocmRoot.Trim()
if ($rocmPathProcess.ExitCode -ne 0 -or -not $RocmRoot) {
    throw "Could not resolve the ROCm SDK root."
}

$env:PATH = "$PythonDir;$PythonDir\Scripts;$RocmRoot\bin;$env:PATH"
$env:HIP_PATH = $RocmRoot
$env:ROCM_PATH = $RocmRoot

# triton-windows bundles an x64 TinyCC implementation for its small JIT host
# modules. An unrelated global CC/CXX override takes precedence and cannot
# build a CPython win_amd64 extension. Remove the overrides only from this
# launcher process; system settings and embedded toolchains are not modified.
if (Test-Path Env:CC) {
    Write-Warning "Ignoring inherited CC='$env:CC' for the Triton x64 runtime."
    Remove-Item Env:CC
}
if (Test-Path Env:CXX) {
    Write-Warning "Ignoring inherited CXX='$env:CXX' for the Triton x64 runtime."
    Remove-Item Env:CXX
}

$HipLld = @(
    (Join-Path $RocmRoot "bin\ld.lld.exe"),
    (Join-Path $RocmRoot "llvm\bin\ld.lld.exe")
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($HipLld) {
    $env:TRITON_HIP_LLD_PATH = $HipLld
}

$ProgramRoots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) |
    Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
    Select-Object -Unique
$VisualStudioInstallPaths = @()
$VsWhereCandidates = @(
    (Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"),
    (Join-Path $env:ProgramFiles "Microsoft Visual Studio\Installer\vswhere.exe")
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
$VsWhereCommand = Get-Command vswhere.exe -ErrorAction SilentlyContinue
if ($VsWhereCommand) {
    $VsWhereCandidates += $VsWhereCommand.Source
}
foreach ($VsWherePath in ($VsWhereCandidates | Select-Object -Unique)) {
    $VisualStudioInstallPaths += @(
        & $VsWherePath `
            -products * `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath 2>$null
    )
}
$VisualStudioInstallPaths = @($VisualStudioInstallPaths | Where-Object { $_ } | Select-Object -Unique)

$WindowsSdkRoots = @()
foreach ($RegistryPath in @(
    "HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots"
)) {
    $RegisteredRoot = (Get-ItemProperty -LiteralPath $RegistryPath -ErrorAction SilentlyContinue).KitsRoot10
    if ($RegisteredRoot) {
        $WindowsSdkRoots += $RegisteredRoot
    }
}
foreach ($ProgramRoot in $ProgramRoots) {
    $WindowsSdkRoots += Join-Path $ProgramRoot "Windows Kits\10"
}
$WindowsSdkRoots = @($WindowsSdkRoots | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)

$MsvcStdlib = $null
$WindowsSdkStdlib = $null
foreach ($InstallPath in $VisualStudioInstallPaths) {
    if (-not $MsvcStdlib) {
        $MsvcStdlib = Get-ChildItem `
            -Path (Join-Path $InstallPath "VC\Tools\MSVC\*\include\stdlib.h") `
            -ErrorAction SilentlyContinue |
            Select-Object -First 1
    }
}
if (-not $MsvcStdlib) {
    foreach ($ProgramRoot in $ProgramRoots) {
        $MsvcStdlib = Get-ChildItem `
            -Path (Join-Path $ProgramRoot "Microsoft Visual Studio\*\*\VC\Tools\MSVC\*\include\stdlib.h") `
            -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($MsvcStdlib) {
            break
        }
    }
}
foreach ($WindowsSdkRoot in $WindowsSdkRoots) {
    if (-not $WindowsSdkStdlib) {
        $WindowsSdkStdlib = Get-ChildItem `
            -Path (Join-Path $WindowsSdkRoot "Include\*\ucrt\stdlib.h") `
            -ErrorAction SilentlyContinue |
            Select-Object -First 1
    }
}

if ($MsvcStdlib -and $WindowsSdkStdlib) {
    $MsvcInclude = $MsvcStdlib.Directory.FullName
    $MsvcVersionRoot = Split-Path $MsvcInclude -Parent
    $SdkIncludeVersionRoot = Split-Path $WindowsSdkStdlib.Directory.FullName -Parent
    $SdkVersion = Split-Path $SdkIncludeVersionRoot -Leaf
    $SdkRoot = Split-Path (Split-Path $SdkIncludeVersionRoot -Parent) -Parent
    $NativeIncludePaths = @(
        $MsvcInclude,
        (Join-Path $SdkIncludeVersionRoot "ucrt"),
        (Join-Path $SdkIncludeVersionRoot "shared"),
        (Join-Path $SdkIncludeVersionRoot "um"),
        (Join-Path $SdkIncludeVersionRoot "winrt")
    ) | Where-Object { Test-Path -LiteralPath $_ }
    $NativeLibraryPaths = @(
        (Join-Path $MsvcVersionRoot "lib\x64"),
        (Join-Path $SdkRoot "Lib\$SdkVersion\ucrt\x64"),
        (Join-Path $SdkRoot "Lib\$SdkVersion\um\x64")
    ) | Where-Object { Test-Path -LiteralPath $_ }
    if ($env:INCLUDE) {
        $NativeIncludePaths += $env:INCLUDE
    }
    if ($env:LIB) {
        $NativeLibraryPaths += $env:LIB
    }
    $env:INCLUDE = $NativeIncludePaths -join ";"
    $env:LIB = $NativeLibraryPaths -join ";"
} else {
    Write-Warning "MSVC or Windows SDK headers were not found during preflight. Continuing because Triton's cached AMD runtime may already be usable. If sampling later fails to compile hip_utils.c, run install-build-tools-rx6700xt-h3.bat as administrator."
}

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
    "--use-quad-cross-attention",
    "--disable-triton-backend",
    "--disable-api-nodes"
)

if ($Profile -eq "Performance64GB") {
    $ComfyArgs += @(
        "--enable-dynamic-vram",
        "--vram-headroom", "0.8",
        "--async-offload", $AsyncOffloadStreams.ToString(),
        "--pinned-memory-limit", $PinnedMemoryLimitGiB.ToString([Globalization.CultureInfo]::InvariantCulture)
    )
} elseif ($Profile -eq "Balanced") {
    $ComfyArgs += @("--disable-smart-memory", "--disable-pinned-memory")
    $ComfyArgs += @("--enable-dynamic-vram", "--vram-headroom", "0.8")
} else {
    $ComfyArgs += @("--disable-smart-memory", "--disable-pinned-memory")
    $ComfyArgs += @("--disable-dynamic-vram", "--lowvram", "--disable-cuda-graphs")
}
$EffectivePostPromptStrategy = $PostPromptStrategy
if ($DisablePostPromptMemoryFlush) {
    $EffectivePostPromptStrategy = "None"
}
if ($EffectivePostPromptStrategy -eq "Recycle") {
    $ComfyArgs += "--restart-process-after-prompt"
} elseif ($EffectivePostPromptStrategy -eq "Flush") {
    $ComfyArgs += "--free-memory-after-prompt"
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
Write-Host "RAM      : $TotalRamGiB GiB"
if ($Profile -eq "Performance64GB") {
    Write-Host "Pinned   : $PinnedMemoryLimitGiB GiB maximum, $AsyncOffloadStreams async streams"
}
if ($EffectivePostPromptStrategy -eq "Recycle") {
    Write-Host "Repeat   : restart the supervised GPU process after every prompt"
} elseif ($EffectivePostPromptStrategy -eq "Flush") {
    Write-Host "Repeat   : release models and GPU allocator after every prompt"
} else {
    Write-Host "Repeat   : keep the current GPU process after each prompt"
}
Write-Host "URL      : http://$ListenAddress`:$Port"
Write-Host "Workflow : sample-workflows\MiniMax_H3_RX6700XT_W4A8_2s.json"
Write-Host ""

Push-Location $Root
try {
    $RestartExitCode = 75
    while ($true) {
        $comfyProcess = Invoke-NativeProcess -FilePath $Python -ArgumentList $ComfyArgs
        if ($comfyProcess.ExitCode -ne $RestartExitCode) {
            exit $comfyProcess.ExitCode
        }
        Write-Host "`nPrompt finished. Starting a fresh HIP/WDDM process..." -ForegroundColor Cyan
        Start-Sleep -Seconds 2
    }
} finally {
    Pop-Location
}
