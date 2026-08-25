# r12 supervised process recycling

## Why a process restart is required

On the validated RX 6700 XT system, the first 15-step MiniMax H3 sampler ran at
14.90 seconds per step. After a complete r11 cleanup released 4621.9 MiB of
staged host memory and reduced registered pinned memory from 4621.9 MiB to zero,
the second sampler still ran at 116.61 seconds per step. Restarting only the
ComfyUI process restores first-run performance.

This demonstrates that the remaining degradation is below ComfyUI's model,
node, and pinned-memory caches. The persistent state belongs to the process's
HIP/WDDM context and cannot be reliably reset through PyTorch's public cache
APIs.

## Default behavior

The RX 6700 XT launcher now supervises ComfyUI. After one prompt completes and
its output is saved, ComfyUI exits with a private restart status. The launcher
waits two seconds and starts a fresh process on the same address and port. The
browser remains open and reconnects to the server.

Queue only one prompt at a time. ComfyUI's pending queue is process-local, so
additional queued prompts cannot survive the recycle. Saved output files are
not affected.

## Alternative strategies

The strategy can be selected explicitly:

```powershell
.\start-minimax-h3-local.bat -PostPromptStrategy Recycle
.\start-minimax-h3-local.bat -PostPromptStrategy Flush
.\start-minimax-h3-local.bat -PostPromptStrategy None
```

- `Recycle` is the default and creates a fresh HIP/WDDM process after each
  prompt.
- `Flush` keeps the r11 ordered AIMDO/model/allocator cleanup for diagnostics.
- `None` keeps the process and all caches alive. It is suitable only for small
  workflows that do not reproduce the slowdown.

The legacy `-DisablePostPromptMemoryFlush` switch maps to `None` for backward
compatibility.
