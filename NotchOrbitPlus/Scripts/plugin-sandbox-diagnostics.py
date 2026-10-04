"""Collect bounded diagnostics for the failed CI fixture child, never other crashes."""
from pathlib import Path
import json
import os
import re
import selectors
import subprocess
import sys
import time


def main():
    report = Path(sys.argv[1])
    started = float(sys.argv[2])
    status = json.loads((report / "status.json").read_text())
    pid = status.get("process_id")
    if not isinstance(pid, int) or pid <= 1:
        return
    matching_pid = re.compile(rb'"(?:pid|processID)"\s*:\s*' + str(pid).encode() + rb'\b')
    directory = Path.home() / "Library/Logs/DiagnosticReports"
    copied = []
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline and not copied:
        if directory.is_dir():
            candidates = sorted(directory.iterdir(), key=lambda path: path.name, reverse=True)[:200]
            for path in candidates:
                if not path.name.startswith(("bash-", "sh-", "sandbox-exec-")) or path.suffix not in (".ips", ".crash"):
                    continue
                try:
                    if path.is_symlink() or not path.is_file() or path.stat().st_mtime < started - 2:
                        continue
                    with path.open("rb") as handle:
                        data = handle.read(262_144)
                    if not matching_pid.search(data):
                        continue
                    target = "fixture-crash-" + str(len(copied) + 1) + path.suffix
                    (report / target).write_bytes(data)
                    copied.append(target)
                    if len(copied) == 2:
                        break
                except OSError:
                    continue
        if not copied:
            time.sleep(0.25)
    predicate = f'processIdentifier == {pid} OR ((process == "sandboxd" OR process == "kernel") AND eventMessage CONTAINS "({pid})")'
    command = ["/usr/bin/log", "show", "--last", "1m", "--style", "json", "--predicate", predicate]
    child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    output = bytearray()
    reason = "completed"
    deadline = time.monotonic() + 4
    with selectors.DefaultSelector() as selector:
        selector.register(child.stdout, selectors.EVENT_READ)
        while time.monotonic() < deadline:
            events = selector.select(timeout=0.25)
            if not events:
                if child.poll() is not None:
                    break
                continue
            chunk = os.read(child.stdout.fileno(), 8192)
            if not chunk:
                break
            remaining = 262_144 - len(output)
            output.extend(chunk[:remaining])
            if len(chunk) > remaining or len(output) == 262_144:
                reason = "bounded at 256 KiB"
                break
        else:
            reason = "four-second deadline"
    if child.poll() is None:
        child.kill()
    try:
        child.wait(timeout=1)
    except subprocess.TimeoutExpired:
        pass
    child.stdout.close()
    (report / "fixture-unified-log.json").write_bytes(output)
    (report / "diagnostics-status.json").write_text(json.dumps({
        "fixture_process_id": pid,
        "matching_crash_reports": copied,
        "unified_log_bytes": len(output),
        "unified_log_outcome": reason,
        "unified_log_exit_status": child.returncode,
    }, indent=2) + "\n")


if __name__ == "__main__":
    main()
