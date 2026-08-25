"""Atomic persistence for ComfyUI's process-local prompt queue.

The RX 6700 XT launcher deliberately recycles the Python/HIP process between
large prompts.  This module keeps the queue and its visible history durable
across that supervised restart without persisting Comfy API credentials.
"""

from __future__ import annotations

import json
import os
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any


QUEUE_STATE_VERSION = 1


class QueueStateError(RuntimeError):
    """Raised when queue state cannot be safely serialized or restored."""


@dataclass(frozen=True)
class QueueState:
    pending: list[tuple]
    running: list[tuple]
    history: dict[str, Any]
    next_number: float


def _queue_item(value: Any, label: str) -> tuple:
    if not isinstance(value, (list, tuple)) or len(value) != 6:
        raise QueueStateError(f"{label} must be a six-element queue item")

    number, prompt_id, prompt, extra_data, outputs, sensitive = value
    if isinstance(number, bool) or not isinstance(number, (int, float)):
        raise QueueStateError(f"{label} has an invalid priority")
    if not isinstance(prompt_id, str) or not prompt_id:
        raise QueueStateError(f"{label} has an invalid prompt_id")
    if not isinstance(prompt, dict):
        raise QueueStateError(f"{label} has an invalid prompt graph")
    if not isinstance(extra_data, dict):
        raise QueueStateError(f"{label} has invalid extra_data")
    if not isinstance(outputs, list):
        raise QueueStateError(f"{label} has an invalid output list")
    if not isinstance(sensitive, dict):
        raise QueueStateError(f"{label} has invalid sensitive data")
    if sensitive:
        raise QueueStateError(
            "authenticated API prompts cannot be written to the queue journal"
        )
    return (number, prompt_id, prompt, extra_data, outputs, sensitive)


def _validated_items(values: Any, label: str) -> list[tuple]:
    if not isinstance(values, list):
        raise QueueStateError(f"{label} must be an array")
    return [_queue_item(value, f"{label}[{index}]") for index, value in enumerate(values)]


def save_queue_state(
    path: str | os.PathLike[str],
    *,
    pending: list,
    running: list,
    history: dict,
    next_number: int | float,
) -> None:
    """Write a complete queue snapshot using same-directory atomic replace."""

    pending_items = _validated_items(pending, "pending")
    running_items = _validated_items(running, "running")
    prompt_ids = [item[1] for item in pending_items + running_items]
    if len(prompt_ids) != len(set(prompt_ids)):
        raise QueueStateError("the queue journal contains duplicate prompt IDs")
    if not isinstance(history, dict):
        raise QueueStateError("history must be an object")
    if isinstance(next_number, bool) or not isinstance(next_number, (int, float)):
        raise QueueStateError("next_number must be numeric")

    payload = {
        "version": QUEUE_STATE_VERSION,
        "pending": pending_items,
        "running": running_items,
        "history": history,
        "next_number": next_number,
        "saved_at_unix_ms": int(time.time() * 1000),
    }

    destination = Path(path)
    temporary = destination.with_name(
        f"{destination.name}.tmp-{os.getpid()}-{threading.get_ident()}"
    )
    try:
        destination.parent.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_TRUNC,
            0o600,
        )
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            json.dump(payload, stream, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, destination)
    except (OSError, TypeError, ValueError) as err:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass
        raise QueueStateError(f"could not write queue state: {err}") from err


def load_queue_state(path: str | os.PathLike[str]) -> QueueState | None:
    """Load and validate a queue snapshot; running work becomes retryable."""

    source = Path(path)
    if not source.is_file():
        return None
    try:
        with source.open("r", encoding="utf-8") as stream:
            payload = json.load(stream)
    except (OSError, UnicodeError, json.JSONDecodeError) as err:
        raise QueueStateError(f"could not read queue state: {err}") from err

    if not isinstance(payload, dict) or payload.get("version") != QUEUE_STATE_VERSION:
        raise QueueStateError("unsupported queue-state format")
    pending = _validated_items(payload.get("pending"), "pending")
    running = _validated_items(payload.get("running"), "running")
    prompt_ids = [item[1] for item in pending + running]
    if len(prompt_ids) != len(set(prompt_ids)):
        raise QueueStateError("the queue journal contains duplicate prompt IDs")

    history = payload.get("history")
    if not isinstance(history, dict):
        raise QueueStateError("history must be an object")
    next_number = payload.get("next_number")
    if isinstance(next_number, bool) or not isinstance(next_number, (int, float)):
        raise QueueStateError("next_number must be numeric")

    queued_numbers = [item[0] for item in pending + running if item[0] >= 0]
    if queued_numbers:
        next_number = max(next_number, max(queued_numbers) + 1)
    return QueueState(
        pending=pending,
        running=running,
        history=history,
        next_number=next_number,
    )


def quarantine_queue_state(path: str | os.PathLike[str]) -> Path | None:
    """Move unreadable state aside so later writes do not destroy evidence."""

    source = Path(path)
    if not source.exists():
        return None
    destination = source.with_name(
        f"{source.name}.invalid-{time.time_ns()}-{os.getpid()}"
    )
    try:
        os.replace(source, destination)
    except OSError:
        return None
    return destination
