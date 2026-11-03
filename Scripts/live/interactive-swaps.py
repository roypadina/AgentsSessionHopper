#!/usr/bin/env python3
"""Live test of interactive hand-offs with the REAL claude in a private pty: one session moves across every
profile, forced by mocked usage (SESSIONHOPPER_MOCK_LIMITS) with "move without asking" on, then comes back.

    Scripts/live/interactive-swaps.py ~/.claude ~/.claude-work [...] [--openrouter-key-file F]

One tiny prompt on the first profile (a few cents); the moves themselves send no prompt (an idle session
resumes silently). Temp state dir: your own ASH config, logs and usage are untouched. Without a key file the
OpenRouter profile gets a fake key (the move still happens; claude only fails if prompted).
Profiles must share one projects/ folder (sessionhopper doctor).
"""
import fcntl, json, os, pty, select, signal, struct, subprocess, sys, tempfile, termios, time

here = os.path.dirname(os.path.abspath(__file__))
# Not SESSIONHOPPER_BIN: inside a supervised session that names the installed release, not this build.
BIN = os.environ.get("ASH_TEST_BIN") or os.path.join(here, "../../.build/debug/sessionhopper")
args, key = sys.argv[1:], None
if "--openrouter-key-file" in args:
    i = args.index("--openrouter-key-file"); key = args[i + 1]; del args[i:i + 2]
dirs = [os.path.realpath(os.path.expanduser(a)) for a in args]
if len(dirs) < 2: sys.exit(__doc__)
if "sessionhopper run" not in subprocess.run([BIN, "help"], capture_output=True, text=True).stdout:
    sys.exit(f"{BIN} is an older build (no `run`): swift build first")

T = tempfile.mkdtemp(prefix="ash-live-")
state, mock, cwd = f"{T}/state", f"{T}/mock", f"{T}/cwd"
for d in (state, mock, cwd): os.makedirs(d)
home = os.path.expanduser("~")
names = [f"p{i + 1}" for i in range(len(dirs))]
profiles = [{"name": n, "dir": d, "exportConfigDir": d != f"{home}/.claude"} for n, d in zip(names, dirs)]
if not key:
    key = f"{T}/fake.key"
    with os.fdopen(os.open(key, os.O_WRONLY | os.O_CREAT, 0o600), "w") as f: f.write("sk-or-v1-" + "0" * 64 + "\n")
profiles.append({"name": "or", "dir": dirs[0], "exportConfigDir": profiles[0]["exportConfigDir"], "kind": "openrouter", "keyFile": key})
json.dump({"profiles": profiles, "autoMove": True, "suggestThreshold": 85, "hardThreshold": 97}, open(f"{state}/config.json", "w"))

env = {k: v for k, v in os.environ.items() if not k.startswith(("CLAUDE", "SESSIONHOPPER", "CMUX"))}
env.update(SESSIONHOPPER_STATE_DIR=state, SESSIONHOPPER_MOCK_LIMITS=mock, TERM="xterm-256color")
if key.startswith(T): env["CLAUDE_CODE_MAX_RETRIES"] = "1"  # claude retries a 401 for minutes; the fake key fails at once
log = open(f"{T}/pty.out", "wb")
results = []

def check(name, ok):
    results.append(ok); print(("PASS " if ok else "FAIL ") + name, flush=True)

def full(n):
    json.dump({"five_hour": {"used_percentage": 99, "resets_at": time.time() + 3600}, "sampled_at": time.time()},
              open(f"{mock}/{n}.limits.json", "w"))

def events():
    try: return [json.loads(l) for l in open(f"{state}/events.jsonl")]
    except FileNotFoundError: return []

def live():
    d = f"{state}/sessions"
    return [json.load(open(f"{d}/{f}")) for f in os.listdir(d) if f.endswith(".json")] if os.path.isdir(d) else []

def on(n): return any(r["profile"] == n and r["child"] > 0 for r in live())

pid, fd = pty.fork()
if pid == 0:
    os.chdir(cwd); os.execve(BIN, [BIN], env)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))

def pump(secs, until=None):
    end = time.time() + secs
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try: log.write(os.read(fd, 65536)); log.flush()
            except OSError: return False
        if until and until(): return True
        if os.waitpid(pid, os.WNOHANG)[0]: return False
    return False

try:
    check("starts on p1", pump(60, lambda: on("p1")))
    pump(10)
    os.write(fd, b"Reply with just: ok"); pump(1); os.write(fd, b"\r")
    sid = live()[0]["session"]
    pump(5); check("first turn finishes", pump(120, lambda: not os.path.exists(f"{state}/sessions/{sid}.busy")))
    pump(3)
    path = names + ["or"]
    for i, n in enumerate(path[:-1]):
        full(n)
        nxt = path[i + 1]
        check(f"{n} at 99%: moves to {nxt}", pump(90, lambda: on(nxt)))
        pump(8)
    for f in os.listdir(mock): os.remove(f"{mock}/{f}")
    check("usage back: leaves OpenRouter for p1", pump(90, lambda: on("p1")))
    moves = [(e.get("from"), e.get("to")) for e in events() if e["type"] == "switch"]
    check("switch log has every hop", moves == list(zip(path, path[1:])) + [("or", "p1")])
    print("moves:", moves, flush=True)
    pump(5)
    os.write(fd, b"/exit"); pump(1); os.write(fd, b"\r"); pump(20)
finally:
    try:
        if not os.waitpid(pid, os.WNOHANG)[0]: os.kill(pid, signal.SIGTERM); os.waitpid(pid, 0)
    except ChildProcessError: pass
    # Only this test's own transcript, by its exact id.
    for s in {e.get("session") for e in events() if e.get("session")}:
        subprocess.run(["find", f"{dirs[0]}/projects/", "-maxdepth", "2", "-name", f"{s}.jsonl", "-delete"])
    # Its project folder too, once empty (claude leaves an empty memory/ in it).
    subprocess.run(["find", f"{dirs[0]}/projects/", "-maxdepth", "1", "-type", "d", "-name", f"*{os.path.basename(T)}-cwd",
                    "-exec", "find", "{}", "-empty", "-delete", ";"])
    print(f"---- {sum(results)} passed, {len(results) - sum(results)} failed (state: {T})")
sys.exit(0 if results and all(results) else 1)
