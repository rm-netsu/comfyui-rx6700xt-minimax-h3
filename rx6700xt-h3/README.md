# RX 6700 XT MiniMax H3 profile

This directory contains the reproducible native-Windows profile used by the
repository root installer. It targets Radeon RX 6700 XT and RX 6750 XT GPUs
(`gfx1031`) with 12 GiB VRAM.

## Design

The profile uses W4A8/INT4 storage and replaces the INT8 GEMM path that fails on
RDNA2 with a Triton implementation. It does not run under WSL and does not spoof
the GPU architecture.

The packaged `gfx1031` optimization also replaces Comfy Kitchen's eager W4A8
decoder with its fused Triton decoder. Packed INT4 weights are written directly
to the target INT8 buffer in one kernel launch. This avoids multiple full-size
FP32/INT32 temporary tensors and an unnecessary FP32 activation copy. The
current layer's INT8 buffer is still materialized; a direct W4A8×A8 GEMM is not
enabled without hardware benchmarking.

## Pinned components

- ComfyUI `0.33.0`, based on `patientx-cfz/comfyui-rocm` commit
  `066420efbe1c689a8bd9158cfe3976c8f7e06156`.
- Python `3.12.9`, verified by SHA-256 and Python Software Foundation signature.
- PyTorch `2.12.0+rocm7.15.0a20260728` and ROCm SDK
  `7.15.0a20260728` from the AMD multi-architecture package index.
- Native `amd-torch-device-gfx1031` package.
- `triton-windows==3.7.0.post26`.
- `comfy-kitchen==0.2.31`.
- `patientx/ComfyUI-INT8-Fast-ROCM` commit
  `78e9875550df441c17ed2a225deae90c4211a09f` plus the hash-checked local
  `gfx1031` W4A8 patch.
- Revision-, size-, and SHA-256-pinned model files listed in
  [`models.json`](models.json).

SageAttention, FlashAttention, Aiter, bitsandbytes, ComfyUI Manager, and
uncontrolled nightly upgrades are not installed by this profile. They are not
required for its MiniMax H3 path and would add unrelated failure modes.

## Requirements

- Windows 10 22H2 build 19045+ or Windows 11 x64.
- Radeon RX 6700 XT or RX 6750 XT (`PCI DEV_73DF`, `gfx1031`).
- At least 32 GiB system RAM; the default performance profile requires 64 GiB.
- A system-managed Windows page file.
- Approximately 55 GiB free disk space for the default installation and models.
- Git for Windows and a current AMD Software: Adrenalin Edition driver.
- Visual Studio C++ Build Tools with a Windows SDK for Triton's AMD host module.

Use a short writable installation path such as
`D:\AI\minimax-h3-rx6700xt`. Do not install under `Program Files`.

## Installation

First, run this once from an elevated Command Prompt:

```powershell
.\install-build-tools-rx6700xt-h3.bat
```

This installs only the Microsoft C++ Build Tools workload and recommended
Windows SDK; the Visual Studio IDE is not required.

From the repository root, run:

```powershell
.\install-rx6700xt-h3.bat
```

The installer does not disable Microsoft Defender, add Defender exclusions, or
modify the display driver. If the local PowerShell execution policy blocks
scripts, grant permission only to the current shell:

```powershell
Set-ExecutionPolicy -Scope Process RemoteSigned
```

If the exact pinned Python 3.12.9 is already registered on the machine, the
official Python EXE may return success while ignoring a second `TargetDir`.
The profile installer detects that case, verifies the existing interpreter's
version, architecture, and Python Software Foundation signature, then creates a
clean application-local `python_env` copy. The registered installation is not
modified.

Then review the model licenses and authorize the downloads:

```powershell
.\download-minimax-h3-models.bat -AcceptLicenses
```

The default set contains the FL2VA W4A8 diffusion model, INT4 text encoder,
video VAE, and audio VAE. Downloads resume through `.part` files and are exposed
under their final names only after size and SHA-256 verification.

Optional model selections:

```powershell
# Download reference-to-video instead of FL2VA.
.\download-minimax-h3-models.bat -AcceptLicenses -Variant ref2va

# Download both diffusion variants and the larger W4A8 text encoder.
.\download-minimax-h3-models.bat -AcceptLicenses -Variant both -TextEncoder w4a8

# Include the optional Turbo eight-step LoRA.
.\download-minimax-h3-models.bat -AcceptLicenses -IncludeTurbo
```

## Diagnostics

Run the quick environment and model check:

```powershell
.\diagnose-rx6700xt-h3.bat -RequireModels
```

Before the first generation, run the full Triton INT8/W4A8 test:

```powershell
.\diagnose-rx6700xt-h3.bat -Full -RequireModels
```

The launcher and diagnostic ignore process-inherited `CC` and `CXX` overrides.
This prevents an unrelated cross-compiler from being used to build Triton's
native x64 helper module. The system environment is not modified.

The report is written to `rx6700xt-h3-diagnostic.json`. It includes the package
versions, detected architecture, VRAM, FP16 matrix test, external-node commit,
local optimization status, model presence, and full kernel smoke-test output.

## Launching

Localhost only:

```powershell
.\start-minimax-h3-local.bat
```

Local network:

```powershell
.\start-minimax-h3-lan.bat
```

ComfyUI has no built-in authentication. Do not forward its port to the
Internet. To add a Windows Firewall rule limited to Private networks and the
local subnet, run an elevated PowerShell window once:

```powershell
.\start-minimax-h3-lan.bat -ConfigureFirewall
```

Open `http://<host-ip>:8188` from another computer. The host IPv4 address can be
listed with:

```powershell
Get-NetIPAddress -AddressFamily IPv4
```

Load this workflow in ComfyUI:

```text
sample-workflows\MiniMax_H3_RX6700XT_W4A8_2s.json
```

### Video plus reference editing

The build also includes a native-core node kit for source-video editing:

```powershell
# General object/garment/prop replacement, about 9.2 GiB.
.\download-video-edit-models.bat -AcceptLicenses -Pack Bernini

# SAM3-tracked person/character replacement, about 26.7 GiB total.
.\download-video-edit-models.bat -AcceptLicenses -Pack SCAIL
```

Load one of these workflows:

```text
sample-workflows\Video_Object_Replacement_Bernini_1.3B_RX6700XT.json
sample-workflows\Character_Replacement_SCAIL2_INT8_RX6700XT.json
```

Bernini-R 1.3B is the recommended first path for an arbitrary object. SCAIL-2
is the tracked, character-focused path. MiniMax H3 Ref2VA is a creative
reference generator and is not described as a pixel-preserving video editor.
See [`VIDEO_EDITING.md`](VIDEO_EDITING.md) for prompts, presets, limitations,
and the recommended quality progression.

The starter profile is intentionally conservative: 608×352, two seconds, 15
steps, and no Turbo LoRA. Increase duration first and resolution second. H3 must
offload weights to system RAM on a 12 GiB card; this is expected and does not
mean that the matrix operations run on the CPU.

The launchers default to `Performance64GB`. This mode keeps compressed weights
in RAM, enables smart VRAM residency, uses two asynchronous offload streams,
and caps pinned host memory at 8 GiB. The existing ComfyUI offload streams
provide the staging buffers, so the profile does not allocate a second model
cache.

The cap and stream count can be adjusted explicitly:

```powershell
.\start-minimax-h3-local.bat -PinnedMemoryLimitGiB 6 -AsyncOffloadStreams 2
```

The launcher uses supervised process recycling on `gfx1031`. A completed prompt
is saved normally, then ComfyUI exits with a private restart status and the
launcher starts a fresh process on the same address and port. This is required
because hardware testing showed a severe second-run slowdown even after every
tracked AIMDO buffer and pinned registration had been released. Model files,
outputs, and the persistent Triton cache are not removed. The browser remains
open and reconnects to the restarted server.

The default recycle strategy keeps an atomic journal under
`user\rx6700xt-h3-queue-state.json`, so pending local prompts, their order,
workflow metadata, seeds, and visible history survive each process restart.
Authenticated Comfy API tokens are never journaled; such a prompt suppresses
the restart instead. See [`R13-DURABLE-QUEUE.md`](R13-DURABLE-QUEUE.md).

The older ordered flush can still be selected for diagnostics, or all
post-prompt handling can be disabled for small workflows:

```powershell
.\start-minimax-h3-local.bat -PostPromptStrategy Flush
.\start-minimax-h3-local.bat -PostPromptStrategy None
```

Do not add `--fast-disk` or `--high-ram` to this profile. The complete default
model set fits in 64 GiB RAM, while `--high-ram` would enable aggressive node
caching and relax pin eviction.

On a machine with less than 56 GiB detected physical RAM, use Balanced mode:

```powershell
.\start-minimax-h3-local.bat -Profile Balanced
```

If the Balanced profile resets the driver or runs out of memory, try Safe mode:

```powershell
.\start-minimax-h3-local.bat -Profile Safe
```

## Updating the optimization only

For an existing installation with the pinned runtime already present:

```powershell
.\install-rx6700xt-h3.bat -SkipRuntime
.\diagnose-rx6700xt-h3.bat -Full -RequireModels
```

Do not run the generic `rocm-pytorch-package-updater.bat` for this profile. It
will replace the tested package set with a newer nightly build. Test changed
pins in a copy of the installation and rerun the full diagnostic.

## Experimental status

AMD publishes Windows packages for `gfx1031` through TheRock, but this software
stack remains under active development. The W4A8 checkpoints are third-party
quantizations and may have a small quality loss compared with the larger INT8
checkpoint. No throughput figure should be treated as established until it has
been measured on physical RX 6700 XT hardware.

## References

- [AMD TheRock supported GPUs](https://github.com/ROCm/TheRock/blob/main/SUPPORTED_GPUS.md)
- [AMD TheRock packages and releases](https://github.com/ROCm/TheRock/blob/main/RELEASES.md)
- [ComfyUI MiniMax H3 guide](https://docs.comfy.org/tutorials/video/minimax/minimax-h3)
- [Comfy Org MiniMax H3 repository](https://huggingface.co/Comfy-Org/MiniMax-H3)
- [W4A8/INT4 MiniMax H3 quantization](https://huggingface.co/Winnougan/MiniMax-H3-INT4_Convrot_ComfyUI)
- [RDNA2 INT8 compatibility patch](https://github.com/patientx/ComfyUI-INT8-Fast-ROCM)
- [MiniMax H3 model license](https://huggingface.co/MiniMaxAI/MiniMax-H3/blob/main/LICENSE)
