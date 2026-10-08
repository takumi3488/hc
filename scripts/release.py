#!/usr/bin/env python3
"""Build and collect hc releases using only Python's standard library."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import platform
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = ROOT / "scripts" / "targets.json"
ZIG_DOWNLOADS = {
    "x86_64-linux": (
        "https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz",
        "1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026",
    ),
    "aarch64-linux": (
        "https://ziglang.org/download/0.17.0/zig-aarch64-linux-0.17.0.tar.xz",
        "9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8",
    ),
    "x86_64-macos": (
        "https://ziglang.org/download/0.17.0/zig-x86_64-macos-0.17.0.tar.xz",
        "4f9a1c5269aa17ebda5e6d3c2b89d6cbf36f7d2b22a0306e9ab98f25f95529c6",
    ),
    "aarch64-macos": (
        "https://ziglang.org/download/0.17.0/zig-aarch64-macos-0.17.0.tar.xz",
        "b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a",
    ),
    "x86_64-windows": (
        "https://ziglang.org/download/0.17.0/zig-x86_64-windows-0.17.0.zip",
        "b5663f69581dcf391293fbf16c06cb80d81d806545ce618b4d0bab7f0eb8c428",
    ),
}
PRIMARY_TARGETS = (
    "x86_64-linux-musl",
    "aarch64-linux-musl",
    "x86_64-macos-none",
    "aarch64-macos-none",
    "x86_64-windows-gnu",
)
EXPECTED_COUNTS = {1: 1, 2: 55, 3: 20}
SEMVER_TAG = re.compile(
    r"v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(?:-((?:0|[1-9]\d*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)"
    r"(?:\.(?:0|[1-9]\d*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*))?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
)


def release_version(tag: str) -> str:
    if SEMVER_TAG.fullmatch(tag) is None:
        raise ValueError(f"invalid release tag (expected v-prefixed SemVer): {tag}")
    return tag[1:]


def load_manifest() -> dict:
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    targets = manifest.get("targets", [])
    seen: set[str] = set()
    tiers = {1: 0, 2: 0, 3: 0}
    for target in targets:
        triple = target.get("triple", "")
        if not re.fullmatch(r"[a-zA-Z0-9_]+(?:-[a-zA-Z0-9_.]+){1,2}", triple):
            raise ValueError(f"invalid target triple: {triple!r}")
        if triple in seen:
            raise ValueError(f"duplicate target triple: {triple}")
        seen.add(triple)
        tier = target.get("tier")
        if tier not in tiers:
            raise ValueError(f"invalid Zig support tier for {triple}: {tier!r}")
        tiers[tier] += 1
        if not target.get("pattern"):
            raise ValueError(f"missing Support Table pattern for {triple}")
    if tiers != EXPECTED_COUNTS:
        raise ValueError(f"target manifest is incomplete: expected {EXPECTED_COUNTS}, found {tiers}")
    missing_primary = set(PRIMARY_TARGETS) - seen
    if missing_primary:
        raise ValueError(f"target manifest is missing required targets: {sorted(missing_primary)}")
    expected_no_spawn = {
        "wasm32-wasi",
        "wasm64-wasi",
        "aarch64-ios",
        "aarch64-tvos",
        "aarch64-visionos",
        "aarch64-watchos",
    }
    marked_no_spawn = {item["triple"] for item in targets if item.get("no_spawn")}
    if marked_no_spawn != expected_no_spawn:
        raise ValueError(f"unexpected no-spawn target set: {sorted(marked_no_spawn)}")
    return manifest


def target_index(manifest: dict) -> dict[str, dict]:
    return {target["triple"]: target for target in manifest["targets"]}


def json_write(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def host_archive() -> str:
    machine = platform.machine().lower()
    machine = {"amd64": "x86_64", "x64": "x86_64", "arm64": "aarch64"}.get(machine, machine)
    system = platform.system().lower()
    host = f"{machine}-{'macos' if system == 'darwin' else system}"
    if host not in ZIG_DOWNLOADS:
        raise RuntimeError(f"no pinned Zig 0.17.0 download for host {host}")
    return host


def safe_member(name: str, destination: Path) -> Path:
    member = PurePosixPath(name)
    if member.is_absolute() or ".." in member.parts:
        raise ValueError(f"unsafe compiler archive path: {name!r}")
    path = destination.joinpath(*member.parts)
    if not path.resolve().is_relative_to(destination.resolve()):
        raise ValueError(f"unsafe compiler archive path: {name!r}")
    return path


def extract_tar(archive_path: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive_path, "r:xz") as archive:
        for member in archive.getmembers():
            path = safe_member(member.name, destination)
            if member.isdir():
                path.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                path.parent.mkdir(parents=True, exist_ok=True)
                source = archive.extractfile(member)
                if source is None:
                    raise ValueError(f"missing compiler archive entry: {member.name}")
                with source, path.open("wb") as output:
                    shutil.copyfileobj(source, output)
                path.chmod(member.mode & 0o777)
            else:
                raise ValueError(f"unsupported compiler archive entry: {member.name}")


def extract_zip(archive_path: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive_path) as archive:
        for member in archive.infolist():
            path = safe_member(member.filename, destination)
            if stat.S_ISLNK(member.external_attr >> 16):
                raise ValueError(f"unsupported compiler archive symlink: {member.filename}")
            if member.is_dir():
                path.mkdir(parents=True, exist_ok=True)
                continue
            path.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(member) as source, path.open("wb") as output:
                shutil.copyfileobj(source, output)


def ensure_private_cache(path: Path) -> None:
    path.mkdir(parents=True, mode=0o700, exist_ok=True)
    information = path.lstat()
    if not stat.S_ISDIR(information.st_mode):
        raise ValueError(f"unsafe Zig cache directory: {path}")
    if os.name == "posix":
        if information.st_uid != os.geteuid() or stat.S_IMODE(information.st_mode) & 0o077:
            raise ValueError(f"unsafe Zig cache ownership or permissions: {path}")


def cache_file_exists(path: Path) -> bool:
    try:
        information = path.lstat()
    except FileNotFoundError:
        return False
    if not stat.S_ISREG(information.st_mode):
        raise ValueError(f"unsafe Zig cache file: {path}")
    return True


def extract_verified_zig(archive_path: Path, destination: Path, host: str) -> Path:
    binary_name = "zig.exe" if host.endswith("-windows") else "zig"
    with tempfile.TemporaryDirectory(prefix=".zig-extract-", dir=destination) as temporary:
        staging = Path(temporary)
        if archive_path.suffix == ".zip":
            extract_zip(archive_path, staging)
        else:
            extract_tar(archive_path, staging)
        binary = next(staging.glob(f"zig-*-0.17.0/{binary_name}"), None)
        if binary is None or not stat.S_ISREG(binary.lstat().st_mode):
            raise RuntimeError(f"Zig archive did not contain its compiler for {host}")
        relative = binary.relative_to(staging)
        staged_root = staging / relative.parts[0]
        installed_root = destination / relative.parts[0]
        try:
            information = installed_root.lstat()
        except FileNotFoundError:
            pass
        else:
            if stat.S_ISLNK(information.st_mode):
                raise ValueError(f"unsafe Zig cache path: {installed_root}")
            if stat.S_ISDIR(information.st_mode):
                shutil.rmtree(installed_root)
            else:
                installed_root.unlink()
        staged_root.replace(installed_root)
    return destination / relative


def install_zig(out: Path) -> Path:
    host = host_archive()
    url, expected_sha256 = ZIG_DOWNLOADS[host]
    ensure_private_cache(out)
    archive_path = out / Path(url).name
    partial_path = archive_path.with_suffix(archive_path.suffix + ".partial")
    if not cache_file_exists(archive_path) or sha256(archive_path) != expected_sha256:
        if cache_file_exists(partial_path):
            partial_path.unlink()
        digest = hashlib.sha256()
        try:
            with urllib.request.urlopen(url, timeout=120) as response, partial_path.open("xb") as archive:
                while chunk := response.read(1024 * 1024):
                    digest.update(chunk)
                    archive.write(chunk)
            actual_sha256 = digest.hexdigest()
            if actual_sha256 != expected_sha256:
                raise RuntimeError(f"Zig archive SHA-256 mismatch: expected {expected_sha256}, got {actual_sha256}")
            partial_path.replace(archive_path)
        finally:
            partial_path.unlink(missing_ok=True)
    binary = extract_verified_zig(archive_path, out, host)
    if not binary.is_file():
        raise RuntimeError(f"Zig archive did not contain its compiler for {host}")
    return binary


def resolve_zig() -> tuple[str, str]:
    configured = os.environ.get("ZIG")
    zig = configured or shutil.which("zig")
    if zig is None:
        cache = Path(tempfile.gettempdir()) / f"hc-zig-{host_archive()}-0.17.0"
        zig = str(install_zig(cache))
    result = subprocess.run([zig, "version"], capture_output=True, text=True, check=False, timeout=15)
    version = result.stdout.strip()
    if result.returncode != 0 or version != "0.17.0":
        raise RuntimeError(f"expected Zig 0.17.0 from {zig}, got {version or result.stderr.strip()!r}")
    return zig, version


def setup_zig(args: argparse.Namespace) -> int:
    binary = install_zig(Path(args.out))
    print(binary.parent)
    return 0


def build_target(triple: str, out: Path) -> int:
    manifest = load_manifest()
    item = next((target for target in manifest["targets"] if target["triple"] == triple), None)
    if item is None:
        raise ValueError(f"unknown target triple: {triple}")
    target_dir = out.resolve() / triple
    target_dir.mkdir(parents=True, exist_ok=True)
    log_path = target_dir / "build.log"
    binary_name = "hc.exe" if "windows" in triple else "hc"
    binary_path = target_dir / binary_name
    report = {
        "schema_version": 1,
        "zig_version": manifest["zig_version"],
        "tier": item["tier"],
        "pattern": item["pattern"],
        "triple": triple,
        "attempted": False,
        "status": "build-failed",
        "returncode": None,
        "binary": None,
        "log": "build.log",
        "reason": None,
    }
    if item.get("no_spawn"):
        report.update(status="unsupported-no-spawn", reason=item["no_spawn"])
        log_path.write_text(f"Unavailable: {item['no_spawn']}\n", encoding="utf-8")
        json_write(target_dir / "report.json", report)
        print(f"{triple}: {report['status']} — {report['reason']}")
        return 0

    try:
        zig, _ = resolve_zig()
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        report["reason"] = f"Zig compiler unavailable: {error}"
        log_path.write_text(report["reason"] + "\n", encoding="utf-8")
        json_write(target_dir / "report.json", report)
        print(f"{triple}: build failed — {report['reason']}", file=sys.stderr)
        return 1

    command = [
        zig,
        "build-exe",
        str(ROOT / "hc.zig"),
        "-target",
        triple,
        "-O",
        "ReleaseSafe",
        f"-femit-bin={binary_path}",
    ]
    report["command"] = command
    try:
        with log_path.open("wb") as log:
            log.write(("$ " + json.dumps(command) + "\n").encode())
            completed = subprocess.run(
                command,
                cwd=ROOT,
                stdout=log,
                stderr=subprocess.STDOUT,
                check=False,
                timeout=25 * 60,
            )
        report["attempted"] = True
        report["returncode"] = completed.returncode
        if completed.returncode == 0 and binary_path.is_file():
            report.update(status="success", binary=binary_name)
        else:
            reason = f"zig build-exe exited {completed.returncode}"
            if completed.returncode == 0:
                reason = "zig build-exe succeeded but emitted no executable"
            report["reason"] = reason
            binary_path.unlink(missing_ok=True)
    except subprocess.TimeoutExpired:
        report["attempted"] = True
        report["reason"] = "zig build-exe exceeded the 25-minute target timeout"
        with log_path.open("ab") as log:
            log.write((report["reason"] + "\n").encode())
        binary_path.unlink(missing_ok=True)
    except OSError as error:
        report["reason"] = f"could not start zig build-exe: {error}"
        with log_path.open("ab") as log:
            log.write((report["reason"] + "\n").encode())
    json_write(target_dir / "report.json", report)
    print(f"{triple}: {report['status']}" + (f" — {report['reason']}" if report["reason"] else ""))
    return 0 if report["status"] == "success" else 1


def run_smoke(binary: Path) -> None:
    binary = binary.resolve()
    if not binary.is_file():
        raise RuntimeError(f"CLI executable not found: {binary}")

    env = os.environ.copy()
    env["HERDR_ENV"] = "0"
    def run(args: list[str], *, input_bytes: bytes | None = None) -> subprocess.CompletedProcess[bytes]:
        return subprocess.run(
            [str(binary), *args],
            input=input_bytes,
            capture_output=True,
            check=False,
            timeout=15,
            env=env,
        )

    help_result = run(["--help"])
    if help_result.returncode != 0 or not help_result.stdout or help_result.stderr:
        raise RuntimeError("`hc --help` must succeed with help on stdout only")

    passed_args = ["ordinary", "two words", ";not-a-shell"]
    echo_code = "import json,sys; json.dump(sys.argv[1:],sys.stdout)"
    echo_result = run(["--", sys.executable, "-c", echo_code, *passed_args])
    try:
        received_args = json.loads(echo_result.stdout)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise RuntimeError("hc child argument output was not valid JSON") from error
    if echo_result.returncode != 0 or received_args != passed_args or echo_result.stderr:
        raise RuntimeError("hc did not preserve command arguments, stdout, and success status")

    stdin_code = "import sys; data=sys.stdin.buffer.read(); sys.stdout.buffer.write(data)"
    stdin_result = run(["--", sys.executable, "-c", stdin_code], input_bytes=b"hc-stdin-smoke\n")
    if stdin_result.returncode != 0 or stdin_result.stdout != b"hc-stdin-smoke\n" or stdin_result.stderr:
        raise RuntimeError("hc did not pass stdin and child stdout through")

    error_code = "import sys; sys.stderr.write('hc-child-stderr'); sys.exit(37)"
    error_result = run(["--", sys.executable, "-c", error_code])
    if error_result.returncode != 37 or error_result.stderr != b"hc-child-stderr" or error_result.stdout:
        raise RuntimeError("hc did not pass child stderr and exit status through")

    if os.name == "posix":
        run_posix_signal_smoke(binary)


def run_posix_signal_smoke(binary: Path) -> None:
    import pty
    import signal
    import time

    def wait_for(predicate, message: str, timeout: float = 5.0) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.01)
        raise RuntimeError(message)

    with tempfile.TemporaryDirectory(prefix="hc-signal-smoke-") as temporary:
        root = Path(temporary)
        helper = root / "fake-herdr"
        helper.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys, time\n"
            "with open(os.environ['HERDR_LOG'], 'a', encoding='utf-8') as log:\n"
            "    log.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            "if '--state' in sys.argv and sys.argv[sys.argv.index('--state') + 1] == 'idle':\n"
            "    time.sleep(0.35)\n",
            encoding="utf-8",
        )
        helper.chmod(0o700)

        def herdr_environment(log_path: Path) -> dict[str, str]:
            return {
                **os.environ,
                "HERDR_ENV": "1",
                "HERDR_PANE_ID": "signal-smoke",
                "HERDR_BIN_PATH": str(helper),
                "HERDR_SOCKET_PATH": str(root / "fake-herdr.sock"),
                "HERDR_LOG": str(log_path),
            }

        hangup_pid_path = root / "hangup-child.pid"
        hangup_events_path = root / "hangup-child.events"
        hangup_events_path.write_text("", encoding="utf-8")
        hangup_code = (
            "import signal, sys, time\n"
            "pid_path, events_path = sys.argv[1:3]\n"
            "def on_hangup(signum, frame):\n"
            "    with open(events_path, 'a', encoding='utf-8') as events:\n"
            "        events.write('SIGHUP\\n')\n"
            "    raise SystemExit(0)\n"
            "signal.signal(signal.SIGHUP, on_hangup)\n"
            "with open(pid_path, 'w', encoding='utf-8') as pid_file:\n"
            "    pid_file.write(str(__import__('os').getpid()))\n"
            "while True: time.sleep(0.05)\n"
        )
        hangup_log = root / "hangup-herdr.jsonl"
        wrapper = subprocess.Popen(
            [str(binary), "--", sys.executable, "-c", hangup_code, str(hangup_pid_path), str(hangup_events_path)],
            env=herdr_environment(hangup_log),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        hangup_child_pid = None
        try:
            wait_for(hangup_pid_path.exists, "hc child did not start for SIGHUP regression")
            hangup_child_pid = int(hangup_pid_path.read_text(encoding="utf-8"))
            os.kill(wrapper.pid, signal.SIGHUP)
            if wrapper.wait(timeout=10) != 0:
                raise RuntimeError("hc did not preserve the SIGHUP child's exit status")
            if hangup_events_path.read_text(encoding="utf-8").splitlines() != ["SIGHUP"]:
                raise RuntimeError("hc did not forward SIGHUP exactly once to its child")
            release_calls = [
                call
                for line in hangup_log.read_text(encoding="utf-8").splitlines()
                if (call := json.loads(line))[1:2] == ["release-agent"]
            ]
            if len(release_calls) != 1 or release_calls[0][:3] != ["pane", "release-agent", "signal-smoke"]:
                raise RuntimeError("hc did not release Herdr after handling SIGHUP")
            wait_for(
                lambda: not _posix_process_exists(hangup_child_pid),
                "hc exited without reaping its SIGHUP-terminated child",
                timeout=2.0,
            )
        finally:
            if wrapper.poll() is None:
                wrapper.kill()
                wrapper.wait()
            if hangup_child_pid is not None:
                _posix_kill(hangup_child_pid, signal.SIGKILL)

        pty_code = (
            "import os, signal, sys, time\n"
            "pid_path, events_path = sys.argv[1:3]\n"
            "shutdown_at = None\n"
            "def record_signal(signum, frame):\n"
            "    global shutdown_at\n"
            "    with open(events_path, 'a', encoding='utf-8') as events:\n"
            "        events.write(signal.Signals(signum).name + '\\n')\n"
            "    if shutdown_at is None: shutdown_at = time.monotonic() + 0.25\n"
            "signal.signal(signal.SIGINT, record_signal)\n"
            "signal.signal(signal.SIGTERM, record_signal)\n"
            "with open(pid_path, 'w', encoding='utf-8') as pid_file:\n"
            "    pid_file.write(str(os.getpid()))\n"
            "while shutdown_at is None or time.monotonic() < shutdown_at:\n"
            "    time.sleep(0.01)\n"
        )

        def run_pty_case(send_terminal_interrupt: bool) -> None:
            pid_path = root / ("ctrl-c-child.pid" if send_terminal_interrupt else "wrapper-signal-child.pid")
            wrapper_pid_path = root / ("ctrl-c-wrapper.pid" if send_terminal_interrupt else "wrapper-signal-wrapper.pid")
            events_path = root / ("ctrl-c-child.events" if send_terminal_interrupt else "wrapper-signal-child.events")
            events_path.write_text("", encoding="utf-8")
            env = herdr_environment(root / ("ctrl-c-herdr.jsonl" if send_terminal_interrupt else "wrapper-signal-herdr.jsonl"))
            supervisor_pid, master_fd = pty.fork()
            if supervisor_pid == 0:
                release_read, release_write = os.pipe()
                wrapper_pid = os.fork()
                if wrapper_pid == 0:
                    os.close(release_write)
                    os.read(release_read, 1)
                    os.close(release_read)
                    try:
                        os.execve(
                            str(binary),
                            [str(binary), "--", sys.executable, "-c", pty_code, str(pid_path), str(events_path)],
                            env,
                        )
                    except OSError:
                        os._exit(127)
                os.close(release_read)
                os.setpgid(wrapper_pid, wrapper_pid)
                os.tcsetpgrp(0, wrapper_pid)
                wrapper_pid_path.write_text(str(wrapper_pid), encoding="utf-8")
                os.write(release_write, b"x")
                os.close(release_write)
                _, wrapper_status = os.waitpid(wrapper_pid, 0)
                os._exit(os.WEXITSTATUS(wrapper_status) if os.WIFEXITED(wrapper_status) else 1)
            wrapper_pid = None
            child_pid = None
            reaped = False
            try:
                wait_for(wrapper_pid_path.exists, "hc wrapper did not start in PTY regression")
                wrapper_pid = int(wrapper_pid_path.read_text(encoding="utf-8"))
                wrapper_pgid = wrapper_pid
                wait_for(
                    lambda: _pty_foreground_group(master_fd) == wrapper_pgid,
                    "PTY supervisor did not put hc in the foreground",
                )
                wait_for(pid_path.exists, "hc child did not start in PTY regression")
                child_pid = int(pid_path.read_text(encoding="utf-8"))
                wait_for(
                    lambda: _pty_foreground_group(master_fd) == child_pid,
                    "hc did not give the PTY foreground to its child process group",
                )
                if send_terminal_interrupt:
                    os.write(master_fd, b"\x03")
                    expected_signal = "SIGINT"
                else:
                    os.kill(wrapper_pid, signal.SIGTERM)
                    expected_signal = "SIGTERM"
                wait_for(
                    lambda: events_path.stat().st_size > 0,
                    f"PTY child did not receive {expected_signal}",
                )
                wait_for(
                    lambda: _pty_foreground_group(master_fd) == wrapper_pgid,
                    f"hc did not restore the PTY foreground process group after {expected_signal} "
                    f"(expected {wrapper_pgid}, observed {_pty_foreground_group(master_fd)})",
                )
                waited, status = os.waitpid(supervisor_pid, os.WNOHANG)
                if waited == supervisor_pid:
                    reaped = True
                    raise RuntimeError("hc exited before PTY foreground restoration was observed")
                if events_path.read_text(encoding="utf-8").splitlines() != [expected_signal]:
                    raise RuntimeError(f"hc delivered {expected_signal} more than once to the PTY child")
                deadline = time.monotonic() + 5.0
                while time.monotonic() < deadline:
                    waited, status = os.waitpid(supervisor_pid, os.WNOHANG)
                    if waited == supervisor_pid:
                        reaped = True
                        if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
                            raise RuntimeError("hc failed its PTY signal regression")
                        return
                    time.sleep(0.01)
                raise RuntimeError("hc did not exit after the PTY child handled its signal")
            finally:
                if not reaped:
                    if wrapper_pid is not None:
                        _posix_kill(wrapper_pid, signal.SIGKILL)
                    _posix_kill(supervisor_pid, signal.SIGKILL)
                    try:
                        os.waitpid(supervisor_pid, 0)
                    except ChildProcessError:
                        pass
                if child_pid is not None:
                    _posix_kill(child_pid, signal.SIGKILL)
                os.close(master_fd)

        run_pty_case(send_terminal_interrupt=True)
        run_pty_case(send_terminal_interrupt=False)


def _posix_process_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def _posix_kill(pid: int, signum: int) -> None:
    try:
        os.kill(pid, signum)
    except ProcessLookupError:
        pass


def _pty_foreground_group(master_fd: int) -> int | None:
    try:
        return os.tcgetpgrp(master_fd)
    except OSError:
        return None


def smoke(args: argparse.Namespace) -> int:
    run_smoke(Path(args.binary))
    print(f"native CLI smoke passed: {args.binary}")
    return 0


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def deterministic_archive(binary: Path, archive_path: Path, member_name: str) -> None:
    with archive_path.open("wb") as output:
        with gzip.GzipFile(filename="", mode="wb", fileobj=output, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w") as archive:
                entry = tarfile.TarInfo(member_name)
                entry.size = binary.stat().st_size
                entry.mode = 0o755
                entry.mtime = 0
                entry.uid = entry.gid = 0
                entry.uname = entry.gname = ""
                with binary.open("rb") as source:
                    archive.addfile(entry, source)


def formula_text(tag: str, repository: str, hashes: dict[str, str]) -> str:
    version = release_version(tag)
    base = f"https://github.com/{repository}/releases/download/{tag}"
    linux_x64 = "hc-x86_64-linux-musl.tar.gz"
    linux_arm = "hc-aarch64-linux-musl.tar.gz"
    mac_x64 = "hc-x86_64-macos-none.tar.gz"
    mac_arm = "hc-aarch64-macos-none.tar.gz"
    return f'''class Hc < Formula
  desc "Herdr lifecycle-aware command wrapper"
  homepage "https://github.com/{repository}"
  version "{version}"

  on_macos do
    on_arm do
      url "{base}/{mac_arm}"
      sha256 "{hashes[mac_arm]}"
    end
    on_intel do
      url "{base}/{mac_x64}"
      sha256 "{hashes[mac_x64]}"
    end
  end

  on_linux do
    on_arm do
      url "{base}/{linux_arm}"
      sha256 "{hashes[linux_arm]}"
    end
    on_intel do
      url "{base}/{linux_x64}"
      sha256 "{hashes[linux_x64]}"
    end
  end

  def install
    bin.install "hc"
  end

  test do
    ENV["HERDR_ENV"] = "0"
    assert_equal "hc-homebrew-smoke\n", shell_output("#{{bin}}/hc -- /bin/echo hc-homebrew-smoke")
    assert_empty shell_output("#{{bin}}/hc -- /bin/sh -c 'exit 37'", 37)
  end
end
'''


def collect_reports(root: Path, excluded: Path) -> list[Path]:
    reports = []
    for path in root.rglob("report.json"):
        resolved = path.resolve()
        if excluded == resolved or excluded in resolved.parents:
            continue
        if ".git" not in path.parts:
            reports.append(path)
    return sorted(reports, key=lambda path: path.as_posix())


def collect(tag: str, repository: str, out: Path) -> int:
    release_version(tag)
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError(f"invalid GitHub repository: {repository}")
    manifest = load_manifest()
    expected = target_index(manifest)
    destination = out.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    incoming = collect_reports(Path.cwd().resolve(), destination)
    by_target: dict[str, tuple[dict, Path]] = {}
    errors: list[str] = []
    for report_path in incoming:
        try:
            report = json.loads(report_path.read_text(encoding="utf-8"))
            if not isinstance(report, dict):
                errors.append(f"invalid report object in {report_path}")
                continue
            if report.get("schema_version") != 1 or report.get("zig_version") != manifest["zig_version"]:
                errors.append(f"unsupported report schema or Zig version in {report_path}")
                continue
            triple = report.get("triple")
            if not isinstance(triple, str) or triple not in expected:
                errors.append(f"unknown target report {report_path}: {triple!r}")
                continue
            if triple in by_target:
                errors.append(f"duplicate report for {triple}: {report_path}")
                continue
            if report.get("tier") != expected[triple]["tier"] or report.get("pattern") != expected[triple]["pattern"]:
                errors.append(f"manifest metadata mismatch for {triple}: {report_path}")
                continue
            if report.get("log") != "build.log":
                errors.append(f"invalid build log name for {triple}: {report_path}")
                continue
            by_target[triple] = (report, report_path)
        except (OSError, json.JSONDecodeError) as error:
            errors.append(f"invalid report {report_path}: {error}")

    coverage_targets = []
    archives: dict[str, Path] = {}
    for triple, item in expected.items():
        received = by_target.get(triple)
        if received is None:
            coverage_targets.append({
                "tier": item["tier"],
                "pattern": item["pattern"],
                "triple": triple,
                "status": "missing-report",
                "attempted": False,
                "reason": "no per-target build report was collected",
            })
            errors.append(f"missing report for {triple}")
            continue
        report, report_path = received
        status = report.get("status")
        if item.get("no_spawn"):
            if status != "unsupported-no-spawn" or report.get("reason") != item["no_spawn"] or report.get("attempted") is not False:
                errors.append(f"invalid no-spawn report for {triple}")
        elif status == "success":
            if report.get("attempted") is not True or report.get("returncode") != 0:
                errors.append(f"successful report does not record an attempted zero-exit build for {triple}")
        elif status == "build-failed":
            if not isinstance(report.get("reason"), str) or not report.get("reason"):
                errors.append(f"failed build report has no failure reason for {triple}")
        else:
            errors.append(f"invalid build status {status!r} for {triple}")
        coverage_targets.append({
            "tier": item["tier"],
            "pattern": item["pattern"],
            "triple": triple,
            "status": status,
            "attempted": bool(report.get("attempted")),
            "reason": report.get("reason"),
            "returncode": report.get("returncode"),
        })
        for suffix, path in (("json", report_path), ("log", report_path.parent / "build.log")):
            if not path.is_file():
                errors.append(f"missing {suffix} diagnostic for {triple}: {path}")
                continue
            shutil.copyfile(path, destination / f"target-{triple}.{suffix}")
        if status != "success":
            continue
        binary_name = "hc.exe" if "windows" in triple else "hc"
        binary_name_in_report = report.get("binary")
        binary_path = report_path.parent / binary_name
        if binary_name_in_report != binary_name or not binary_path.is_file() or binary_path.is_symlink():
            errors.append(f"successful target report has no safe {binary_name} binary for {triple}")
            continue
        archive_name = f"hc-{triple}.tar.gz"
        archive_path = destination / archive_name
        deterministic_archive(binary_path, archive_path, binary_name)
        archives[archive_name] = archive_path

    missing_primary = [target for target in PRIMARY_TARGETS if f"hc-{target}.tar.gz" not in archives]
    coverage = {
        "schema_version": 1,
        "tag": tag,
        "repository": repository,
        "zig_version": manifest["zig_version"],
        "support_table": manifest["support_table"],
        "summary": {
            "targets": len(coverage_targets),
            "built": sum(target["status"] == "success" for target in coverage_targets),
            "build_failed": sum(target["status"] == "build-failed" for target in coverage_targets),
            "unsupported_no_spawn": sum(target["status"] == "unsupported-no-spawn" for target in coverage_targets),
            "missing_reports": sum(target["status"] == "missing-report" for target in coverage_targets),
            "required_primary_missing": missing_primary,
            "validation_errors": sorted(set(errors)),
        },
        "targets": coverage_targets,
    }
    json_write(destination / "target-coverage.json", coverage)
    if missing_primary:
        errors.extend(f"required primary target did not build: {triple}" for triple in missing_primary)
    if errors:
        print("release collection rejected: " + "; ".join(sorted(set(errors))), file=sys.stderr)
        return 1

    archive_hashes = {name: sha256(path) for name, path in sorted(archives.items())}
    formula_path = destination / "hc.rb"
    formula_path.write_text(formula_text(tag, repository, archive_hashes), encoding="utf-8")
    installer_path = destination / "install.sh"
    shutil.copy2(ROOT / "install.sh", installer_path)
    published_assets = {**archives, formula_path.name: formula_path, installer_path.name: installer_path}
    checksums = "".join(
        f"{sha256(path)}  {name}\n" for name, path in sorted(published_assets.items())
    )
    (destination / "SHA256SUMS").write_text(checksums, encoding="ascii")
    print(f"collected {len(archives)} archives and {len(coverage_targets)} target reports in {destination}")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("matrix", help="print the complete Zig Tier 1-3 target matrix")
    setup_parser = subparsers.add_parser("setup-zig", help="download and verify Zig 0.17.0 for this host")
    setup_parser.add_argument("--out", required=True, help="directory to extract the pinned Zig archive")
    build_parser = subparsers.add_parser("build", help="attempt one manifest target and write its report")
    build_parser.add_argument("target", help="exact target triple from scripts/targets.json")
    build_parser.add_argument("--out", required=True, help="directory for target output and diagnostics")
    collect_parser = subparsers.add_parser("collect", help="validate reports, package binaries, checksums and formula")
    collect_parser.add_argument("tag")
    collect_parser.add_argument("repository")
    collect_parser.add_argument("--out", required=True, help="directory for release assets and reports")
    smoke_parser = subparsers.add_parser("smoke", help="exercise a native hc binary")
    smoke_parser.add_argument("--binary", required=True, help="path to the native executable")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.command == "matrix":
            manifest = load_manifest()
            print(json.dumps([item["triple"] for item in manifest["targets"]], separators=(",", ":")))
            return 0
        if args.command == "setup-zig":
            return setup_zig(args)
        if args.command == "build":
            return build_target(args.target, Path(args.out))
        if args.command == "collect":
            return collect(args.tag, args.repository, Path(args.out))
        if args.command == "smoke":
            return smoke(args)
        raise AssertionError(args.command)
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        print(f"release.py: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
