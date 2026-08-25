# r11 repeated-sampler cleanup

## What changed

On Windows ROCm, a completed DynamicVRAM prompt can leave AIMDO host staging
buffers and pinned registrations alive after ComfyUI's standard model unload.
The next `SamplerCustomAdvanced` run may then use shared GPU memory and become
several times slower, even with `--cache-none`.

r11 changes the cleanup order used by `--free-memory-after-prompt` and `/free`:

1. synchronize and discard AIMDO stream/cast buffers;
2. release staged host allocations and pinned registrations while every model
   is still present in ComfyUI's loaded-model tracker;
3. unload model residency;
4. clear the execution cache and collect Python objects;
5. flush unused HIP allocator blocks.

The cleanup does not modify weights, sampling parameters, outputs, or the
persistent Triton compilation cache. It may add model reload time before the
next prompt, but is intended to avoid a much larger sampler slowdown.

## Verification

After every completed prompt the console should contain a line similar to:

```text
DynamicVRAM pre-unload cleanup released 1234.5 MiB of staged host memory; registered pinned memory 8192.0 -> 0.0 MiB.
```

Run the same workflow twice and compare the `s/it` value printed by the sampler.
If the second run is still slower, save the two cleanup lines and the sampler
progress lines. A non-zero registered value after cleanup indicates a pin that
could not be released; a zero value with continued slowdown points to remaining
HIP/WDDM process state.

## Disable the workaround

For a small workflow that fits fully in VRAM, start with:

```powershell
.\start-minimax-h3-local.bat -DisablePostPromptMemoryFlush
```

The default RX 6700 XT launchers keep the ordered cleanup enabled.
