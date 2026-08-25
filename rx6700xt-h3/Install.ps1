[CmdletBinding()]
param(
    [switch]$SkipPython,
    [switch]$SkipRuntime,
    [switch]$SkipCustomNode,
    [switch]$SkipDiagnostics,
    [switch]$ForceGpu
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ProfileDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ProfileDir
$Profile = Get-Content (Join-Path $ProfileDir "profile.json") -Raw | ConvertFrom-Json
$PythonDir = Join-Path $Root "python_env"
$Python = Join-Path $PythonDir "python.exe"
$Downloads = Join-Path $Root ".downloads-rx6700xt-h3"
$Constraints = Join-Path $ProfileDir "constraints.txt"
$InstallRecord = Join-Path $Root ".rx6700xt-h3-install.json"

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Invoke-External {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList
    )
    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $FilePath $($ArgumentList -join ' ')"
    }
}

function Test-PinnedPython {
    param([Parameter(Mandatory = $true)][string]$Candidate)

    if (-not (Test-Path -LiteralPath $Candidate -PathType Leaf)) {
        return $false
    }
    try {
        $probe = & $Candidate -c "import struct, sys; print('.'.join(map(str, sys.version_info[:3]))); print(struct.calcsize('P') * 8); print(sys.base_prefix)" 2>$null
        if ($LASTEXITCODE -ne 0 -or $probe.Count -lt 3) {
            return $false
        }
        $version = [string]$probe[0]
        $bits = [string]$probe[1]
        $basePrefix = [string]$probe[2]
        if ($version -ne [string]$Profile.python.version -or $bits -ne "64") {
            return $false
        }
        $basePython = Join-Path $basePrefix "python.exe"
        if (-not (Test-Path -LiteralPath $basePython -PathType Leaf)) {
            return $false
        }
        $signature = Get-AuthenticodeSignature $basePython
        return ($signature.Status -eq "Valid" -and $signature.SignerCertificate.Subject -match "Python Software Foundation")
    } catch {
        return $false
    }
}

function Find-PinnedPython {
    $candidates = [System.Collections.Generic.List[string]]::new()

    $launcher = Get-Command "py.exe" -ErrorAction SilentlyContinue
    if ($launcher) {
        try {
            $candidate = & $launcher.Source "-3.12" -c "import sys; print(sys.executable)" 2>$null | Select-Object -Last 1
            if ($LASTEXITCODE -eq 0 -and $candidate) {
                $candidates.Add(([string]$candidate).Trim())
            }
        } catch {
        }
    }

    $registryRoots = @(
        "Registry::HKEY_CURRENT_USER\Software\Python\PythonCore",
        "Registry::HKEY_LOCAL_MACHINE\Software\Python\PythonCore",
        "Registry::HKEY_LOCAL_MACHINE\Software\WOW6432Node\Python\PythonCore"
    )
    foreach ($registryRoot in $registryRoots) {
        Get-ChildItem -LiteralPath $registryRoot -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -like "3.12*" } |
            ForEach-Object {
                try {
                    $installPathKey = Get-Item -LiteralPath (Join-Path $_.PSPath "InstallPath") -ErrorAction Stop
                    $installPath = [string]$installPathKey.GetValue("")
                    if ($installPath) {
                        $candidates.Add((Join-Path $installPath "python.exe"))
                    }
                } catch {
                }
            }
    }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (Test-PinnedPython $candidate) {
            return $candidate
        }
    }
    return $null
}

function Copy-LocalPython {
    param([Parameter(Mandatory = $true)][string]$SourcePython)

    $sourceRoot = & $SourcePython -c "import sys; print(sys.base_prefix)" | Select-Object -Last 1
    if ($LASTEXITCODE -ne 0 -or -not $sourceRoot) {
        throw "Could not resolve the existing Python base directory."
    }
    $sourceRoot = ([string]$sourceRoot).Trim()
    $sourcePython = Join-Path $sourceRoot "python.exe"
    if (-not (Test-PinnedPython $sourcePython)) {
        throw "The existing Python installation failed the version, architecture or signature check."
    }

    if (Test-Path -LiteralPath $PythonDir) {
        $entries = @(Get-ChildItem -LiteralPath $PythonDir -Force -ErrorAction SilentlyContinue)
        if ($entries.Count -gt 0) {
            $backup = "$PythonDir.incomplete-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Move-Item -LiteralPath $PythonDir -Destination $backup
            Write-Warning "The incomplete python_env was preserved as $backup"
        }
    }
    New-Item -ItemType Directory -Path $PythonDir -Force | Out-Null

    Write-Host "Creating an isolated local copy from signed Python $($Profile.python.version): $sourceRoot"
    $excludedSitePackages = Join-Path $sourceRoot "Lib\site-packages"
    $excludedScripts = Join-Path $sourceRoot "Scripts"
    & robocopy.exe $sourceRoot $PythonDir /E /COPY:DAT /DCOPY:DAT /R:2 /W:1 /NFL /NDL /NJH /NJS /NP /XD $excludedSitePackages $excludedScripts
    $robocopyExitCode = $LASTEXITCODE
    if ($robocopyExitCode -gt 7) {
        throw "Could not create the local Python copy. Robocopy exit code: $robocopyExitCode."
    }
    if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) {
        throw "The local Python copy does not contain $Python."
    }

    & $Python -m ensurepip --upgrade
    if ($LASTEXITCODE -ne 0) {
        throw "Could not bootstrap pip in the local Python copy."
    }
    $localVersion = & $Python -c "import sys; print('.'.join(map(str, sys.version_info[:3])))"
    if ($LASTEXITCODE -ne 0 -or $localVersion -ne [string]$Profile.python.version) {
        throw "The local Python copy failed validation."
    }
}

function Assert-Host {
    Write-Step "Checking Windows, RX 6700 XT and free space"

    if (-not $IsWindows -and $PSVersionTable.PSVersion.Major -ge 6) {
        throw "This profile is for native Windows 10/11, not WSL or Linux."
    }
    if ([Environment]::Is64BitOperatingSystem -ne $true) {
        throw "A 64-bit Windows installation is required."
    }

    $os = Get-CimInstance Win32_OperatingSystem
    if ([int]$os.BuildNumber -lt 19045) {
        throw "Windows build 19045 or newer is required. Current build: $($os.BuildNumber)."
    }

    $gpu = Get-CimInstance Win32_VideoController | Where-Object {
        $_.Name -match "(?i)Radeon.*(RX )?67(00|50)" -or
        $_.PNPDeviceID -match "(?i)VEN_1002&DEV_73DF"
    } | Select-Object -First 1

    if (-not $gpu -and -not $ForceGpu) {
        throw "RX 6700/6750 XT (gfx1031, PCI DEV_73DF) was not found. Use -ForceGpu only if the adapter is known to be gfx1031."
    }
    if ($gpu) {
        Write-Host "GPU: $($gpu.Name) [$($gpu.PNPDeviceID)]"
    } else {
        Write-Warning "GPU check was overridden. The installer will still require gfx1031 at runtime."
    }

    $ramGiB = [math]::Floor([double]$os.TotalVisibleMemorySize / 1MB)
    if ($ramGiB -lt [int]$Profile.target.minimum_ram_gib) {
        Write-Warning "Only ${ramGiB} GiB RAM detected. MiniMax H3 needs at least 32 GiB; 64 GiB is recommended."
    } else {
        Write-Host "RAM: ${ramGiB} GiB"
    }

    $qualifier = Split-Path -Qualifier $Root
    if ($qualifier) {
        $driveName = $qualifier.TrimEnd(':')
        $drive = Get-PSDrive -Name $driveName
        $freeGiB = [math]::Floor([double]$drive.Free / 1GB)
        if ($freeGiB -lt [int]$Profile.target.minimum_free_disk_gib_without_models) {
            throw "Only ${freeGiB} GiB is free on ${qualifier}. At least 18 GiB is required before downloading models."
        }
        if ($freeGiB -lt [int]$Profile.target.minimum_free_disk_gib_with_default_models) {
            Write-Warning "${freeGiB} GiB is free. The default H3 model set needs about 31 GiB plus working space; 55 GiB free is recommended."
        } else {
            Write-Host "Free disk: ${freeGiB} GiB"
        }
    }
}

function Install-LocalPython {
    if (Test-Path $Python) {
        $version = & $Python -c "import sys; print('.'.join(map(str, sys.version_info[:3])))"
        if ($LASTEXITCODE -ne 0 -or $version -ne $Profile.python.version) {
            throw "python_env exists but is not Python $($Profile.python.version). Move it aside and run the installer again."
        }
        Write-Host "Python $version already installed."
        return
    }
    if ($SkipPython) {
        throw "-SkipPython was specified, but $Python does not exist."
    }

    # The python.org EXE intentionally supports a single registered installation
    # of a given version. If 3.12.9 is already registered, it can return success
    # while ignoring TargetDir. Reuse only an exact, 64-bit, PSF-signed install
    # and make a clean application-local copy instead.
    $existingPython = Find-PinnedPython
    if ($existingPython) {
        Write-Step "Preparing local Python $($Profile.python.version) from the existing signed installation"
        Copy-LocalPython $existingPython
        return
    }

    Write-Step "Installing signed Python $($Profile.python.version) into python_env"
    New-Item -ItemType Directory -Path $Downloads -Force | Out-Null
    $installer = Join-Path $Downloads "python-$($Profile.python.version)-amd64.exe"
    if (-not (Test-Path $installer)) {
        Invoke-WebRequest -Uri $Profile.python.url -OutFile $installer -UseBasicParsing
    }

    $actualHash = (Get-FileHash $installer -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $Profile.python.sha256) {
        throw "Python installer hash mismatch. Expected $($Profile.python.sha256), got $actualHash."
    }
    $signature = Get-AuthenticodeSignature $installer
    if ($signature.Status -ne "Valid" -or $signature.SignerCertificate.Subject -notmatch "Python Software Foundation") {
        throw "Python installer signature is not valid for the Python Software Foundation: $($signature.Status)."
    }

    $installArguments = @(
        "/quiet",
        "InstallAllUsers=0",
        "TargetDir=`"$PythonDir`"",
        "Include_pip=1",
        "Include_dev=1",
        "Include_test=0",
        "Include_launcher=0",
        "InstallLauncherAllUsers=0",
        "PrependPath=0",
        "Shortcuts=0",
        "AssociateFiles=0"
    )
    $installLog = Join-Path $Downloads "python-$($Profile.python.version)-install.log"
    $installArguments = @("/log", "`"$installLog`"") + $installArguments
    $process = Start-Process -FilePath $installer -ArgumentList $installArguments -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "Python installation failed with exit code $($process.ExitCode). See $installLog"
    }
    if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) {
        $existingPython = Find-PinnedPython
        if ($existingPython) {
            Write-Warning "The Python installer returned success but reused its registered installation instead of TargetDir."
            Copy-LocalPython $existingPython
            return
        }
        throw "Python installer returned success but $Python was not created. See $installLog"
    }
}

function Install-Runtime {
    if ($SkipRuntime) {
        Write-Warning "Skipping ROCm, PyTorch and ComfyUI dependency installation."
        return
    }

    Write-Step "Installing pinned ROCm 7.15 / PyTorch 2.12 for native gfx1031"
    $env:PIP_DISABLE_PIP_VERSION_CHECK = "1"
    $rocmPackages = @(
        "torch[device-gfx1031]==$($Profile.rocm.torch)",
        "torchvision[device-gfx1031]==$($Profile.rocm.torchvision)",
        "torchaudio==$($Profile.rocm.torchaudio)",
        "rocm-sdk-devel==$($Profile.rocm.sdk_devel)"
    )
    $rocmArguments = @("-m", "pip", "install", "--index-url", $Profile.rocm.index_url) + $rocmPackages
    Invoke-External -FilePath $Python -ArgumentList $rocmArguments

    $RocmSdk = Join-Path $PythonDir "Scripts\rocm-sdk.exe"
    if (-not (Test-Path $RocmSdk)) {
        throw "rocm-sdk.exe was not installed."
    }
    Invoke-External -FilePath $RocmSdk -ArgumentList @("init")

    Write-Step "Installing pinned ComfyUI dependencies"
    Invoke-External -FilePath $Python -ArgumentList @(
        "-m", "pip", "install",
        "-r", (Join-Path $Root "requirements.txt"),
        "-c", $Constraints
    )
    Invoke-External -FilePath $Python -ArgumentList @(
        "-m", "pip", "install",
        "triton-windows==$($Profile.extensions.triton_windows)",
        "-c", $Constraints
    )
}

function Install-Int8Patch {
    if ($SkipCustomNode) {
        Write-Warning "Skipping the RDNA2 INT8 patch. MiniMax H3 W4A8 is not expected to work safely without it."
        return
    }

    Write-Step "Installing the pinned RDNA2 W4A8/Triton patch"
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if (-not $git) {
        throw "Git for Windows is required. Install it from https://git-scm.com/download/win and run this script again."
    }

    $node = $Profile.extensions.int8_fast_rocm
    $optimizationPatch = Join-Path $ProfileDir "patches\comfyui-int8-fast-rocm-gfx1031.patch"
    if (-not (Test-Path $optimizationPatch)) {
        throw "Missing gfx1031 W4A8 optimization patch: $optimizationPatch"
    }
    $patchHash = (Get-FileHash $optimizationPatch -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($patchHash -ne $node.local_patch_sha256) {
        throw "W4A8 optimization patch hash mismatch. Expected $($node.local_patch_sha256), got $patchHash."
    }

    $customNodes = Join-Path $Root "custom_nodes"
    $destination = Join-Path $customNodes "ComfyUI-INT8-Fast-ROCM"
    New-Item -ItemType Directory -Path $customNodes -Force | Out-Null

    if (-not (Test-Path (Join-Path $destination ".git"))) {
        Invoke-External -FilePath $git.Source -ArgumentList @(
            "clone", "--filter=blob:none", "--no-checkout", $node.repository, $destination
        )
    }

    $actualCommit = (& $git.Source -C $destination rev-parse HEAD 2>$null).Trim()
    $dirty = @(& $git.Source -C $destination status --porcelain)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect $destination."
    }

    $expectedDirtyPaths = @("int8_fused_kernel.py", "rocm_int8_kitchen_patch.py")
    $dirtyPaths = @($dirty | ForEach-Object { $_.Substring(3).Trim('"') })
    & $git.Source -C $destination apply --reverse --check $optimizationPatch 2>$null
    $optimizationAlreadyApplied = $LASTEXITCODE -eq 0
    $onlyExpectedChanges = $dirtyPaths.Count -eq $expectedDirtyPaths.Count -and
        @($dirtyPaths | Where-Object { $_ -notin $expectedDirtyPaths }).Count -eq 0

    if ($dirty.Count -gt 0 -and (-not $optimizationAlreadyApplied -or -not $onlyExpectedChanges)) {
        throw "$destination has changes other than the packaged gfx1031 optimization. They were preserved."
    }

    if ($actualCommit -ne $node.commit) {
        if ($dirty.Count -gt 0) {
            throw "$destination is modified and is not at the pinned commit. It was preserved."
        }
        Invoke-External -FilePath $git.Source -ArgumentList @(
            "-C", $destination, "fetch", "--depth", "1", "origin", $node.commit
        )
        Invoke-External -FilePath $git.Source -ArgumentList @(
            "-C", $destination, "checkout", "--detach", $node.commit
        )
        $actualCommit = (& $git.Source -C $destination rev-parse HEAD).Trim()
        $optimizationAlreadyApplied = $false
    }

    if ($actualCommit -ne $node.commit) {
        throw "Custom-node commit mismatch: expected $($node.commit), got $actualCommit."
    }

    if (-not $optimizationAlreadyApplied) {
        Invoke-External -FilePath $git.Source -ArgumentList @(
            "-C", $destination, "apply", "--check", $optimizationPatch
        )
        Invoke-External -FilePath $git.Source -ArgumentList @(
            "-C", $destination, "apply", $optimizationPatch
        )
    }

    & $git.Source -C $destination apply --reverse --check $optimizationPatch 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "The gfx1031 W4A8 optimization was not applied cleanly."
    }
}

Assert-Host
Install-LocalPython
Install-Runtime
Install-Int8Patch

$record = [ordered]@{
    profile = $Profile.name
    installed_at_utc = [DateTime]::UtcNow.ToString("o")
    base_commit = $Profile.source.base_commit
    gfx = $Profile.target.gfx
    torch = $Profile.rocm.torch
    rocm = $Profile.rocm.sdk_devel
    int8_patch_commit = $Profile.extensions.int8_fast_rocm.commit
    w4a8_optimization_patch_sha256 = $Profile.extensions.int8_fast_rocm.local_patch_sha256
}
$record | ConvertTo-Json | Set-Content -Path $InstallRecord -Encoding UTF8

if (-not $SkipDiagnostics) {
    Write-Step "Running the quick ROCm diagnostic"
    & (Join-Path $ProfileDir "Test-ROCm.ps1")
    if ($LASTEXITCODE -ne 0) {
        throw "ROCm diagnostic failed. See the output above."
    }
}

Write-Host "`nInstallation complete." -ForegroundColor Green
Write-Host "Next: run download-minimax-h3-models.bat -AcceptLicenses"
Write-Host "Then: run start-minimax-h3-local.bat or start-minimax-h3-lan.bat"
