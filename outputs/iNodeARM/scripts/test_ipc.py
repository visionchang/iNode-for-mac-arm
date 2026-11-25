#!/usr/bin/env python3
"""Headless desktop-core regression checks; no credentials or network changes."""
import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time


def exercise(core: Path, delay: float, mode: str):
    folder = Path(tempfile.mkdtemp(prefix="ia-ipc-test-", dir="/private/tmp"))
    folder.chmod(0o700)
    path = folder / "control.sock"
    process = subprocess.Popen(
        [str(core), str(path), str(os.getuid()), str(os.getpid())],
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
    )
    client = socket.socket(socket.AF_UNIX)
    client.settimeout(5)
    reader = None
    try:
        deadline = time.monotonic() + 5
        while not path.exists():
            assert process.poll() is None, "core exited before listening"
            assert time.monotonic() < deadline, "socket creation timeout"
            time.sleep(0.02)
        client.connect(str(path))
        reader = client.makefile("rb")
        assert json.loads(reader.readline())["event"] == "ready"
        time.sleep(delay)
        assert process.poll() is None, "idle IPC client caused premature exit"
        if mode == "fragment":
            client.sendall(b'{"op":')
            time.sleep(0.25)
            assert process.poll() is None, "partial command caused premature exit"
            client.sendall(b'"invalid"}\n')
            reply = json.loads(reader.readline())
            assert reply["event"] == "error", reply
            assert "未知命令" in reply["message"], reply
        elif mode == "stop":
            client.sendall(b'{"op":"stop"}\n')
        else:
            client.shutdown(socket.SHUT_RDWR)
        assert process.wait(timeout=5) == 0, process.stderr.read().decode()
        assert not path.exists(), "socket path was not removed"
        print(f"PASS: {mode}, {delay}s idle, clean exit")
    finally:
        if reader:
            reader.close()
        client.close()
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
        process.stderr.close()
        shutil.rmtree(folder)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("core", nargs="?", type=Path, default=(
        Path(__file__).resolve().parents[2]
        / "iNode ARM.app/Contents/MacOS/inode-desktop"
    ))
    args = parser.parse_args()
    for delay, mode in [(0.25, "stop"), (1, "stop"), (1, "fragment"), (1, "eof")]:
        exercise(args.core.resolve(), delay, mode)
