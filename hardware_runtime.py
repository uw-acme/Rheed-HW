"""Record hardware tool invocations without changing the existing RTL or firmware."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess
import time


def source_manifest(root: Path):
    paths = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode().split("\0")
    return [{"path": name, "sha256": hashlib.sha256((root / name).read_bytes()).hexdigest(),
             "size_bytes": (root / name).stat().st_size}
            for name in paths if name and (root / name).is_file()]


def run_tool(command: list[str], directory: Path, *, timeout: int = 300):
    """Capture exact command, exit status and streams, including missing tool/timeouts."""
    start = time.time()
    try:
        result = subprocess.run(command, cwd=directory, text=True, capture_output=True, timeout=timeout)
        return {"command": command, "working_directory": str(directory), "started_at_unix": start,
                "duration_seconds": time.time() - start, "exit_code": result.returncode,
                "stdout": result.stdout, "stderr": result.stderr,
                "status": "succeeded" if result.returncode == 0 else "failed"}
    except (FileNotFoundError, subprocess.TimeoutExpired) as exc:
        def stream(name):
            value = getattr(exc, name, None) or ""
            return value.decode("utf-8", errors="replace") if isinstance(value, bytes) else value
        return {"command": command, "working_directory": str(directory), "started_at_unix": start,
                "duration_seconds": time.time() - start, "exit_code": None,
                "status": "blocked" if isinstance(exc, FileNotFoundError) else "timed_out",
                "error": str(exc), "stdout": stream("stdout"), "stderr": stream("stderr")}


def capture_command(tracker, command: list[str], directory: Path, *, timeout: int = 300):
    result = run_tool(command, directory, timeout=timeout)
    tracker.record_cell(source="# Hardware tool invocation\n" + repr(command),
                        stdout=result.get("stdout", ""), stderr=result.get("stderr", ""),
                        success=result["status"] == "succeeded",
                        error=None if result["status"] == "succeeded" else RuntimeError(result.get("error", "tool failed")),
                        assigned_names=["tool_result"], user_ns={"tool_result": result},
                        duration_seconds=result["duration_seconds"])
    if result["status"] != "succeeded":
        raise RuntimeError(f"Hardware stage {result['status']}: {command[0]}")
    return result


def capture_outputs(tracker, paths: list[str], *, role: str):
    """Require every explicitly requested output to exist before claiming success."""
    from rheed_runtime import capture_directory
    for name in paths:
        path = Path(name)
        if path.is_dir():
            capture_directory(tracker, path, role=role)
        elif path.is_file():
            tracker.capture_file(path, role=role)
        else:
            raise FileNotFoundError(f"Requested {role} output was not produced: {path}")
