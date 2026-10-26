"""check-shell-scripts-driver.py — drive a REAL interactive shell through a pty and
record the OSC 7 / OSC 133 sequences it writes. Imported by check-shell-scripts-cases.py.

WHY A PTY AND NOT `bash -c`. Every hook under test (PROMPT_COMMAND, the DEBUG trap,
zsh precmd/preexec, fish's fish_prompt/fish_preexec/fish_postexec events) fires only
in an INTERACTIVE shell reading a terminal. `bash -c` runs none of them, so a
`-c` harness would pass against an empty script.

WHY THE DA1 REPLY. fish 4.x queries the terminal at startup and holds its first
prompt until it sees a Primary Device Attributes answer (measured on fish 4.9.3: it
writes `ESC [ 0 c` and waits). SwiftTerm answers that in the app; this driver must too.

STEPS. A run is a list of steps. Step 0 is everything from the `source` line to the
first OSC 7 after it (the first prompt the script draws). Step i>0 is everything
from sending input line i to the next OSC 7, plus a short tail so a sequence the
shell writes just after it (fish's native `133;A`) lands in the same step. Every
supported script emits OSC 7 once per prompt, which makes it a reliable prompt
boundary; a step that never sees one is marked timed_out.

TOKENS. Each step is a list of strings: OSC payloads verbatim ("133;D;1",
"7;file://host/path") and markers ("M:rc=1") printed by `echo @@...@@`. A marker's
value class excludes `$` and `?`, so the terminal's echo of the typed command
(`echo @@rc=$?@@`) is never mistaken for its output (`@@rc=1@@`).

DCS PTMUX UNWRAPPING. When the shell runs inside a simulated tmux environment
(TMUX set, allow-passthrough on), OSC sequences arrive wrapped in a DCS Ptmux
envelope: ESC P tmux ; ESC <payload-with-doubled-ESCs> ESC \\ . tokens() and
_osc7_closed() unwrap these transparently so all existing case assertions work
unchanged regardless of whether passthrough is active.
"""

import os
import pty
import re
import select
import time

# Raw OSC: ESC ] <payload> BEL-or-ST
_OSC_RAW = rb"\x1b\]((?:7|133);[^\x07\x1b]*)(?:\x07|\x1b\\)"
# DCS Ptmux envelope: ESC P tmux ; ESC <doubled-payload> ESC \
# The inner payload has every ESC doubled; we capture the doubled run.
_DCS_PTMUX = rb"\x1bPtmux;\x1b((?:[^\x1b]|\x1b\x1b)*)(?:\x1b\\){2}"
_MARKER = rb"@@([A-Za-z0-9_=.:/-]+)@@"
_TOKEN = re.compile(_OSC_RAW + rb"|" + _DCS_PTMUX + rb"|" + _MARKER)
_DA1_QUERIES = (b"\x1b[c", b"\x1b[0c")
_DA1_REPLY = b"\x1b[?62;22c"


def _unwrap_dcs(doubled):
    """Undo the ESC-doubling inside a DCS Ptmux payload: \x1b\x1b → \x1b."""
    return doubled.replace(b"\x1b\x1b", b"\x1b")


def _osc7_closed(b):
    """True when b contains a complete OSC 7 sequence (raw or DCS-wrapped)."""
    # Raw: ESC ] 7 ; ... BEL-or-ST
    i = b.rfind(b"\x1b]7;")
    if i >= 0 and (b.find(b"\x07", i) >= 0 or b.find(b"\x1b\\", i + 1) >= 0):
        return True
    # DCS-wrapped: ESC P tmux ; ESC ESC ] 7 ; ... ESC \ ESC \
    i = b.rfind(b"\x1bPtmux;")
    if i >= 0:
        inner_start = b.find(b"\x1b\x1b]7;", i)
        if inner_start >= 0 and b.find(b"\x1b\\", inner_start + 4) >= 0:
            return True
    return False


class ShellRun:
    def __init__(self, argv, env, cwd):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:  # child
            os.chdir(cwd)
            os.execvpe(argv[0], argv, env)
        self.raw = b""

    def _read(self, seconds, stop=None):
        """Read for up to `seconds`; return early once `stop(new_bytes)` is true."""
        got = b""
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([self.fd], [], [], 0.02)
            if not ready:
                continue
            try:
                chunk = os.read(self.fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            got += chunk
            if any(q in chunk for q in _DA1_QUERIES):
                os.write(self.fd, _DA1_REPLY)
            if stop and stop(got):
                break
        self.raw += got
        return got

    def send(self, line):
        os.write(self.fd, line.encode() + b"\r")

    def step(self, line, timeout=4.0):
        """Send `line` (None = send nothing) and collect one step."""
        if line is not None:
            self.send(line)
        got = self._read(timeout, stop=lambda b: _osc7_closed(b))
        timed_out = not _osc7_closed(got)
        got += self._read(0.15)  # tail: native fish markers right after the prompt
        return {"tokens": tokens(got), "timed_out": timed_out}

    def close(self):
        try:
            self.send("exit")
            self._read(0.3)
        finally:
            try:
                os.kill(self.pid, 9)
            except OSError:
                pass
            try:
                os.waitpid(self.pid, 0)
            except OSError:
                pass
            os.close(self.fd)


def tokens(raw):
    out = []
    for m in _TOKEN.finditer(raw):
        if m.group(1) is not None:
            # Raw OSC payload
            out.append(m.group(1).decode("utf-8", "replace"))
        elif m.group(2) is not None:
            # DCS Ptmux — unwrap doubled ESCs, then extract the inner OSC payload.
            inner = _unwrap_dcs(m.group(2))
            # inner is now: ESC ] <payload> ESC \  (ST-terminated OSC)
            osc_m = re.match(rb"\x1b\]((?:7|133);[^\x1b]*)(?:\x1b\\)?", inner)
            if osc_m:
                out.append(osc_m.group(1).decode("utf-8", "replace"))
        else:
            out.append("M:" + m.group(3).decode())
    return out


def run(argv, script, setup=(), lines=(), term_program="GoblinPortal", cwd="/",
        extra_env=None, startup_wait=3.0, no_prompt=False):
    """Start `argv`, type each `setup` line, source `script`, then type `lines`.

    Returns {"steps": [...], "raw": bytes}. With no_prompt (the script is expected to be
    a no-op, so no OSC 7 will ever arrive) each step simply waits out a short window.
    """
    env = {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
        "HOME": os.environ.get("GATE_HOME", "/tmp"),
        "TERM": "xterm-256color",
        "TERM_PROGRAM": term_program,
        "LANG": "en_US.UTF-8",
        "LC_ALL": "en_US.UTF-8",
    }
    env.update(extra_env or {})
    sh = ShellRun(list(argv), env, cwd)
    try:
        sh._read(startup_wait, stop=lambda b: b.rstrip().endswith((b"$", b"%", b">", b"#")))
        for s in setup:
            sh.send(s)
            sh._read(0.25)
        wait = 0.6 if no_prompt else 4.0
        steps = [sh.step("source " + script, timeout=wait)]
        for line in lines:
            steps.append(sh.step(line, timeout=wait))
        return {"steps": steps, "raw": sh.raw}
    finally:
        sh.close()
