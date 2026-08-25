# r13 durable prompt queue

## What changed

r12 resets the degraded Windows HIP/WDDM context by restarting ComfyUI after
each completed prompt. That restores sampler performance, but the upstream
ComfyUI queue and history normally exist only in process memory.

r13 adds an atomic local journal for the supervised `Recycle` strategy. Before
the process exits, and whenever the queue changes, it records:

- pending prompt priority and order;
- prompt IDs and complete API graphs;
- workflow metadata, seeds, client metadata, and selected outputs;
- completed prompt history and output metadata;
- the next automatic queue number.

The replacement process restores this state before it opens the server. A task
that was marked running when a process terminated unexpectedly is returned to
the pending heap and may execute again (at-least-once recovery).

The journal is stored at:

```text
user\rx6700xt-h3-queue-state.json
```

Writes use a same-directory temporary file, flush, `fsync`, and atomic replace,
so an interrupted write cannot leave a partially updated primary journal. An
invalid journal is moved to an `.invalid-<timestamp>` recovery file.

## Security boundary

The journal contains local prompts and workflow metadata in readable JSON. It
never writes Comfy API authentication tokens. If an authenticated API prompt is
present, the supervised restart is cancelled and the current process continues
running, rather than either losing the prompt or persisting its credential.

The packaged launcher already uses `--disable-api-nodes`, so normal MiniMax H3
and local video-editing queues are fully recoverable.

## User-visible behavior

You may queue multiple local jobs. After each job:

1. its output and history are committed;
2. the remaining queue is atomically journaled;
3. the Python/HIP process exits;
4. the supervisor starts a fresh process;
5. history and pending prompts are restored and execution continues.

The web UI briefly disconnects while the process is replaced and should
reconnect to the same address and port automatically.
