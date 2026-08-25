# MiniMax H3 for ComfyUI on Radeon RX 6700 XT

An experimental native-Windows ComfyUI distribution for running MiniMax H3 on
AMD Radeon RX 6700 XT and RX 6750 XT GPUs (`gfx1031`, 12 GiB VRAM).

This project is based on
[`patientx-cfz/comfyui-rocm`](https://github.com/patientx-cfz/comfyui-rocm)
and adds a reproducible MiniMax H3 profile, pinned ROCm packages, verified model
downloads, a low-VRAM workflow, and an RDNA2-compatible W4A8/INT8 execution path.

> [!WARNING]
> This is an experimental community build. It is not an official AMD, MiniMax,
> Comfy Org, or PyTorch release. Keep a known-good copy of your environment and
> do not use the generic ROCm updater with this profile.

## Highlights

- Native Windows 10/11 execution; WSL is not used.
- Native `gfx1031` PyTorch device package; no `HSA_OVERRIDE_GFX_VERSION` spoofing.
- W4A8 MiniMax H3 diffusion model and INT4 text encoder by default.
- RDNA2-safe Triton replacement for the unsupported INT8 GEMM path.
- Fused packed-INT4-to-INT8 decoding with reduced temporary memory use.
- Pinned Python, PyTorch, ROCm, Triton, Comfy Kitchen, and custom-node revisions.
- Resumable model downloads with revision, size, and SHA-256 validation.
- Local-only and LAN launchers with conservative 12 GiB VRAM defaults.

## Supported configuration

| Component | Supported target |
| --- | --- |
| Operating system | Windows 10 22H2 build 19045+ or Windows 11 x64 |
| GPU | Radeon RX 6700 XT / RX 6750 XT |
| Architecture | `gfx1031` |
| VRAM | 12 GiB |
| System RAM | 32 GiB minimum; 64 GiB recommended |
| Free disk space | About 55 GiB for the default environment and models |

Other GPUs are intentionally rejected by the profile installer unless the
hardware check is explicitly overridden for development. They have not been
validated by this project.

## Quick start

Install [Git for Windows](https://git-scm.com/download/win) and a current AMD
Software: Adrenalin Edition driver first. Do not place the repository under
`Program Files`; a short writable path such as `D:\AI\minimax-h3-rx6700xt` is
recommended.

Open PowerShell in the repository directory and run:

```powershell
.\install-rx6700xt-h3.bat
```

Review the applicable model licenses, then explicitly authorize the default
model downloads:

```powershell
.\download-minimax-h3-models.bat -AcceptLicenses
```

Run the full hardware and kernel diagnostic:

```powershell
.\diagnose-rx6700xt-h3.bat -Full -RequireModels
```

Start ComfyUI locally:

```powershell
.\start-minimax-h3-local.bat
```

Load the included starter workflow:

```text
sample-workflows\MiniMax_H3_RX6700XT_W4A8_2s.json
```

The starter workflow uses 608×352 output, a two-second duration, 15 steps, and
no Turbo LoRA. Confirm that it completes before increasing duration or
resolution.

For detailed installation, model variants, LAN setup, diagnostics, and recovery
notes, see [`rx6700xt-h3/README.md`](rx6700xt-h3/README.md).

## Updating an existing installation

To apply the packaged W4A8 optimization without reinstalling the pinned Python
and ROCm runtime:

```powershell
.\install-rx6700xt-h3.bat -SkipRuntime
.\diagnose-rx6700xt-h3.bat -Full -RequireModels
```

The installer preserves unexpected changes in the external custom-node checkout
instead of overwriting them.

## W4A8 execution path

Comfy Kitchen normally expands grouped packed INT4 weights into an INT8 tensor
before invoking INT8 GEMM. The local patch keeps the stable two-stage design but
replaces the eager multi-temporary decoder with one Triton kernel and routes the
result through the RDNA2-compatible GEMM implementation.

The optimization removes several full-size FP32/INT32 decoder intermediates and
an unnecessary FP32 activation copy. It does not yet fuse the weight decoder
into the GEMM itself, so one INT8 buffer for the current layer is still
materialized. A direct W4A8×A8 kernel remains experimental until it can be
benchmarked on physical `gfx1031` hardware.

## Network access

The default launcher binds to `127.0.0.1`. LAN mode can be enabled with:

```powershell
.\start-minimax-h3-lan.bat
```

ComfyUI does not provide authentication. Do not expose port `8188` to the
Internet. The optional firewall command creates a Private-network,
LocalSubnet-only rule:

```powershell
.\start-minimax-h3-lan.bat -ConfigureFirewall
```

## Reproducibility

Runtime versions are pinned in [`rx6700xt-h3/profile.json`](rx6700xt-h3/profile.json)
and [`rx6700xt-h3/constraints.txt`](rx6700xt-h3/constraints.txt). Model source
revisions, expected sizes, and hashes are recorded in
[`rx6700xt-h3/models.json`](rx6700xt-h3/models.json). The local external-node
patch is stored under [`rx6700xt-h3/patches`](rx6700xt-h3/patches).

Run the profile tests on a development machine with:

```bash
python -m unittest discover -s tests-rx6700xt -v
```

GPU kernel validation must be performed on Windows with the target Radeon card
using `diagnose-rx6700xt-h3.bat -Full`.

## Known limitations

- The Windows `gfx1031` ROCm stack is under active development.
- MiniMax H3 exceeds 12 GiB once activations and working buffers are included;
  model offloading to system RAM is expected.
- W4A8 may have a small quality loss relative to the larger INT8 checkpoint.
- The first run compiles and autotunes Triton kernels. Later runs reuse the
  persistent cache.
- Performance claims require measurements on physical RX 6700 XT hardware; the
  repository tests validate configuration and patch integrity, not throughput.

## Upstream projects and model sources

- [ComfyUI](https://github.com/Comfy-Org/ComfyUI)
- [comfyui-rocm](https://github.com/patientx-cfz/comfyui-rocm)
- [Comfy Kitchen](https://github.com/Comfy-Org/comfy-kitchen)
- [ComfyUI-INT8-Fast-ROCM](https://github.com/patientx/ComfyUI-INT8-Fast-ROCM)
- [AMD TheRock](https://github.com/ROCm/TheRock)
- [Comfy Org MiniMax H3 models](https://huggingface.co/Comfy-Org/MiniMax-H3)
- [W4A8/INT4 MiniMax H3 quantization](https://huggingface.co/Winnougan/MiniMax-H3-INT4_Convrot_ComfyUI)

## License

The repository code is distributed under the GNU General Public License v3.0;
see [`LICENSE`](LICENSE). Upstream components and downloaded model files retain
their own licenses and notices. Model files are not included in this repository
and are downloaded only after explicit user authorization.
