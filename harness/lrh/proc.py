"""Subprocess helpers and the content-addressed oracle cache."""

import contextlib
import fcntl
import hashlib
import json
import math
import os
import random
import signal
import shutil
import subprocess
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path

from . import config


@dataclass
class Res:
    rc: int  # negative = killed by signal; 124 = timeout
    out: bytes
    err: bytes
    timed_out: bool = False
    timeout_msg: str = ""  # with timed_out: "timeout (cpu 120s)" or "timeout (wall 480s)"
    cpu: float | None = None  # user+sys seconds of the process (and the children it waited for), if measured

    @property
    def ok(self) -> bool:
        return self.rc == 0 and not self.timed_out

    def err_tail(self, n: int = 2000) -> str:
        return self.err.decode(errors="replace")[-n:]

    def fail_msg(self, tool: str) -> str:
        """`opt exited with 3` or `opt timeout (cpu 120s)`, for check messages."""
        return f"{tool} {self.timeout_msg}" if self.timed_out else f"{tool} exited with {self.rc}"


# ---------------------------------------------------------------- machine-wide job slots

_slot_state = threading.local()


def max_jobs() -> int:
    """Machine-wide limit on concurrent tool processes over all harness instances (LRH_MAX_JOBS; 0 = no limit)."""
    v = os.environ.get("LRH_MAX_JOBS", "")
    return int(v) if v.strip() else (os.cpu_count() or 1)


def _slot_fds(n: int) -> list[int]:
    """This thread's descriptors for slot-0..n-1 plus the gather lock (index n), opened once per thread and process.

    flock() locks belong to an open file description: two threads (or a parent and its forked worker) sharing one
    descriptor would both "hold" the same slot. So every thread opens its own (O_CLOEXEC: tools don't inherit them).
    """
    st = getattr(_slot_state, "fds", None)
    if st is None or st[0] != os.getpid() or len(st[1]) != n + 1:
        d = config.JOBS_DIR
        if not d.is_dir():
            d.mkdir(parents=True, exist_ok=True)
            try:
                os.chmod(d, 0o1777)
            except OSError:
                pass
        names = [f"slot-{i}" for i in range(n)] + ["gather"]
        old_umask = os.umask(0)
        try:
            fds = [os.open(d / nm, os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o666) for nm in names]
        finally:
            os.umask(old_umask)
        st = (os.getpid(), fds)
        _slot_state.fds = st
    return st[1]


@contextlib.contextmanager
def job_slot(count: int = 1):
    """Hold `count` of the machine-wide job slots (a jobserver shared by every harness process on the machine).

    Slots are flock()ed files config.JOBS_DIR/slot-<i>, i < max_jobs(). The kernel drops a flock when its holder
    dies, so a killed harness never leaks a slot. Deadlock-free: a thread holding a slot never waits for another one
    (nested job_slot() calls in one thread are no-ops), except while gathering count > 1 slots, which only one
    thread on the machine does at a time (the `gather` lock); single-slot holders always finish without waiting, and
    finished gatherers too, so the gatherer always gets its slots. Waiting is polling (2-50 ms, randomised).
    """
    n = max_jobs()
    if n <= 0 or count <= 0 or getattr(_slot_state, "held", False):
        yield
        return
    count = min(count, n)
    fds = _slot_fds(n)
    held: list[int] = []
    gathering = False
    _slot_state.held = True
    try:
        if count > 1:
            fcntl.flock(fds[n], fcntl.LOCK_EX)
            gathering = True
        delay = 0.002
        while len(held) < count:
            start = random.randrange(n)
            for k in range(n):
                i = (start + k) % n
                if i in held:
                    continue
                try:
                    fcntl.flock(fds[i], fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    continue
                held.append(i)
                if len(held) == count:
                    break
            if len(held) < count:
                time.sleep(delay * (0.5 + random.random()))
                delay = min(delay * 1.5, 0.05)
        if gathering:
            fcntl.flock(fds[n], fcntl.LOCK_UN)
            gathering = False
        yield
    finally:
        for i in held:
            fcntl.flock(fds[i], fcntl.LOCK_UN)
        if gathering:
            fcntl.flock(fds[n], fcntl.LOCK_UN)
        _slot_state.held = False


def slots_in_use() -> tuple[int, int]:
    """(slots currently held by anyone, max_jobs()), for `harness/run jobs`."""
    n = max_jobs()
    if n <= 0:
        return 0, 0
    busy = 0
    for i in range(n):
        try:
            fd = os.open(config.JOBS_DIR / f"slot-{i}", os.O_RDWR | os.O_CLOEXEC)
        except FileNotFoundError:
            continue
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(fd, fcntl.LOCK_UN)
        except BlockingIOError:
            busy += 1
        finally:
            os.close(fd)
    return busy, n


# ---------------------------------------------------------------- running processes

def run(cmd: list[str], *, cwd=None, stdin: bytes | None = None, timeout: float = config.TOOL_TIMEOUT,
        env: dict | None = None, slot: bool = True) -> Res:
    """Wall-clock limited run (LLVM's tools, clang, test programs). env: extra variables on top of the harness's.

    slot: hold a machine-wide job slot while it runs (job_slot()); False for things that aren't one CPU's worth of
    work (an impl's build.sh runs its own parallel build; git)."""
    with job_slot() if slot else contextlib.nullcontext():
        return _run(cmd, cwd=cwd, stdin=stdin, timeout=timeout, env=env)


def _run(cmd, *, cwd, stdin, timeout, env) -> Res:
    try:
        p = subprocess.run(
            cmd,
            cwd=cwd,
            env={**os.environ, **env} if env else None,
            input=stdin if stdin is not None else b"",
            capture_output=True,
            timeout=timeout,
        )
        return Res(p.returncode, p.stdout, p.stderr)
    except subprocess.TimeoutExpired as e:
        msg = f"timeout (wall {timeout:g}s)"
        return Res(124, e.stdout or b"", (e.stderr or b"") + f"\n[harness] {msg}".encode(), True, msg)
    except OSError as e:
        return Res(127, b"", f"[harness] could not execute {cmd[0]}: {e}".encode())


def run_limited(cmd: list[str], *, cwd=None, stdin: bytes | None = None, cpu_limit: float | None = None,
                env: dict | None = None) -> Res:
    """Run one of an implementation's tools under a CPU-time limit (default config.TOOL_CPU_LIMIT), holding a
    machine-wide job slot (job_slot()) while it runs.

    CPU time (user+sys) barely moves with machine load, so a test that passes at load 1 also passes at load 40; wall
    time doesn't (see docs/testing.md, "Timeouts"). The limit is RLIMIT_CPU (set by a /bin/sh shim that then execs
    the tool; inherited by anything it starts; the kernel sends SIGXCPU at the limit, SIGKILL 5 s later), plus a wall-clock backstop of
    config.TOOL_WALL_FACTOR x the limit for a tool that hangs without using CPU (sleep, deadlock, blocked read).
    The child runs in its own process group so a timeout kills everything it started.
    """
    with job_slot():
        return _run_limited(cmd, cwd=cwd, stdin=stdin, cpu_limit=cpu_limit, env=env)


def _run_limited(cmd, *, cwd, stdin, cpu_limit, env) -> Res:
    limit = cpu_limit if cpu_limit is not None else config.TOOL_CPU_LIMIT
    wall = limit * config.TOOL_WALL_FACTOR
    soft = max(1, math.ceil(limit))
    # The limit has to be in place before the tool runs (a wrapper could fork before a prlimit() from here lands), and
    # a preexec_fn is unsafe with the harness's threads; so a shell sets it and execs the tool (~1 ms).
    shim = ["/bin/sh", "-c", f'ulimit -S -t {soft} && ulimit -H -t {soft + 5} && exec "$@"', "sh", *cmd]
    try:
        p = subprocess.Popen(shim, cwd=cwd, env={**os.environ, **env} if env else None, stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    except OSError as e:
        return Res(127, b"", f"[harness] could not execute {cmd[0]}: {e}".encode())

    bufs = {}

    def reader(name, f):
        bufs[name] = f.read()
        f.close()

    def writer():
        try:
            p.stdin.write(stdin or b"")
        except (BrokenPipeError, OSError):
            pass
        try:
            p.stdin.close()
        except OSError:
            pass

    threads = [threading.Thread(target=reader, args=("out", p.stdout), daemon=True),
               threading.Thread(target=reader, args=("err", p.stderr), daemon=True),
               threading.Thread(target=writer, daemon=True)]
    for t in threads:
        t.start()
    status = {}

    def reaper():
        while True:
            try:
                _, st, ru = os.wait4(p.pid, 0)
            except InterruptedError:
                continue
            status.update(st=st, cpu=ru.ru_utime + ru.ru_stime)
            return

    rt = threading.Thread(target=reaper, daemon=True)
    rt.start()
    rt.join(wall)
    wall_hit = rt.is_alive()
    if wall_hit:
        kill_group(p.pid)
        rt.join()
    deadline = time.monotonic() + 2
    for t in threads[:2]:
        t.join(max(0, deadline - time.monotonic()))
    if any(t.is_alive() for t in threads[:2]):
        kill_group(p.pid)  # leftovers of a tool that forked and exited hold the pipes open
        for t in threads[:2]:
            t.join()
    p.returncode = os.waitstatus_to_exitcode(status["st"])  # we reaped it; keep Popen from trying again
    out, err, cpu, rc = bufs.get("out", b""), bufs.get("err", b""), status["cpu"], p.returncode
    if wall_hit:
        msg = f"timeout (wall {wall:g}s; cpu {cpu:.0f}s used)"
        return Res(124, out, err + f"\n[harness] {msg}".encode(), True, msg, cpu)
    # At the limit: killed by SIGXCPU/SIGKILL (or a child was, whatever the parent then reported).
    if cpu >= soft - 0.05:
        msg = f"timeout (cpu {soft}s)"
        return Res(124, out, err + f"\n[harness] {msg}".encode(), True, msg, cpu)
    return Res(rc, out, err, False, "", cpu)


def kill_group(pid: int):
    try:
        os.killpg(pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass


def sha(*parts) -> str:
    h = hashlib.sha256()
    for p in parts:
        if isinstance(p, str):
            p = p.encode()
        elif not isinstance(p, bytes):
            p = json.dumps(p, sort_keys=True).encode()
        h.update(len(p).to_bytes(8, "little"))
        h.update(p)
    return h.hexdigest()


def cached(key_parts: list, compute) -> dict:
    """Memoize compute() -> dict of JSON-serialisable values, keyed by LLVM version + key_parts.

    Entries are written atomically (temp file + rename), so concurrent workspaces can share the cache.
    """
    key = sha(config.LLVM_VERSION, *key_parts)
    d = config.cache_dir() / key[:2]
    f = d / f"{key}.json"
    if f.exists():
        return json.loads(f.read_text())
    val = compute()
    d.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp-")
    with os.fdopen(fd, "w") as fh:
        json.dump(val, fh)
    os.replace(tmp, f)
    return val


class Workdir:
    """A temporary directory for one check; removed afterwards."""

    def __enter__(self) -> Path:
        self.path = Path(tempfile.mkdtemp(prefix="lrh-"))
        return self.path

    def __exit__(self, *exc):
        shutil.rmtree(self.path, ignore_errors=True)
