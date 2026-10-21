"""check-shell-scripts-cases.py — the case table for check-shell-scripts.sh.

Drives the SHIPPED Resources/shell-integration.{bash,zsh,fish} inside real interactive
shells (driver: check-shell-scripts-driver.py) and asserts the OSC 133 / OSC 7 stream
each one writes — what ShellIntegration.handle and Osc7Directory.parse then consume.
check-shell-integration.sh gates those consumers; until this file, nothing ran the
scripts that FEED them.

Exit: 0 all pass, 1 a real failure, 2 environmental (a required shell missing).
GATE_SCRIPT_DIR overrides where the scripts are read from (falsification copies).
GATE_ONLY=<case id> runs just that case.
"""

import os
import shutil
import subprocess
import sys
import tempfile
import urllib.parse

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import importlib.util  # noqa: E402

_spec = importlib.util.spec_from_file_location(
    "driver", os.path.join(os.path.dirname(os.path.abspath(__file__)), "check-shell-scripts-driver.py"))
driver = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(driver)

SCRIPTS = os.environ.get("GATE_SCRIPT_DIR") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "Resources")
BASH_SCRIPT = os.path.join(SCRIPTS, "shell-integration.bash")
ZSH_SCRIPT = os.path.join(SCRIPTS, "shell-integration.zsh")
FISH_SCRIPT = os.path.join(SCRIPTS, "shell-integration.fish")
ONLY = os.environ.get("GATE_ONLY")

ROOT = os.path.realpath(tempfile.mkdtemp(prefix="gp-shells-"))
DEEP = os.path.join("café x", "日本")  # a space, a 2-byte and two 3-byte characters
os.makedirs(os.path.join(ROOT, DEEP))

failures = []
ran = 0


def kinds(step):
    """133 tokens reduced to A / C / D;<code>; native fish parameters dropped."""
    out = []
    for t in step["tokens"]:
        if not t.startswith("133;"):
            continue
        body = t[4:]
        out.append(body if body.startswith("D") else body.split(";")[0])
    return [k for k in out if k != "B"]


def markers(step_or_tokens):
    toks = step_or_tokens["tokens"] if isinstance(step_or_tokens, dict) else step_or_tokens
    return [t[2:] for t in toks if t.startswith("M:")]


def osc7_paths(step):
    paths = []
    for t in step["tokens"]:
        if t.startswith("7;file://"):
            rest = t[len("7;file://"):]
            host, _, path = rest.partition("/")
            paths.append((host, urllib.parse.unquote("/" + path, errors="strict")))
    return paths


def case(cid, desc):
    def wrap(fn):
        global ran
        if ONLY and ONLY != cid:
            return fn
        ran += 1
        try:
            problems = fn() or []
        except Exception as exc:  # a harness crash is a failure of THIS case, named
            problems = ["harness raised %r" % (exc,)]
        mark = "ok  " if not problems else "FAIL"
        print("  %s %-4s %s" % (mark, cid, desc))
        for p in problems:
            print("         - " + p)
            failures.append(cid)
        return fn
    return wrap


def expect_steps(res, want):
    probs = []
    for i, (step, exp) in enumerate(zip(res["steps"], want)):
        if step["timed_out"]:
            probs.append("step %d: no prompt (no OSC 7) within the timeout" % i)
        if exp is not None and kinds(step) != exp:
            probs.append("step %d: 133 sequence %s, want %s" % (i, kinds(step), exp))
    return probs


def check_deep_path(res):
    paths = osc7_paths(res["steps"][-1])
    want = os.path.join(ROOT, DEEP)
    if not paths:
        return ["no OSC 7 after cd"]
    host, got = paths[-1]
    probs = [] if got == want else ["OSC 7 decodes to %r, want %r" % (got, want)]
    if not host:
        probs.append("OSC 7 carries no host (Osc7Directory needs it to tell local from remote)")
    return probs


# ── bash ──────────────────────────────────────────────────────────────────────

def bash_suite(bash):
    argv = [bash, "--norc", "--noprofile", "-i"]
    tag = os.path.basename(os.path.dirname(os.path.dirname(bash))) if "homebrew" in bash else "bash"
    version = subprocess.run([bash, "-c", "echo ${BASH_VERSINFO[0]}${BASH_VERSINFO[1]}"],
                             capture_output=True, text=True).stdout.strip()
    print("%s (%s, %s):" % (tag, bash, version))
    S = BASH_SCRIPT

    @case("B1", "true then false: C, D;0 / C, D;1; first prompt has A and no D")
    def _():
        r = driver.run(argv, S, lines=["true", "false"], cwd=ROOT)
        return expect_steps(r, [["A"], ["C", "D;0", "A"], ["C", "D;1", "A"]])

    @case("B2", "Return on an empty line reports no command")
    def _():
        return expect_steps(driver.run(argv, S, lines=["", "true"], cwd=ROOT),
                            [["A"], ["A"], ["C", "D;0", "A"]])

    @case("B3", "an existing PROMPT_COMMAND ending in ';' survives, trips no C")
    def _():
        r = driver.run(argv, S, setup=["PROMPT_COMMAND='history -a; '"],
                       lines=["", "true"], cwd=ROOT)
        return expect_steps(r, [["A"], ["A"], ["C", "D;0", "A"]])

    @case("B4", "$? survives: later PROMPT_COMMAND sees 1, and the trap leaves $? alone")
    def _():
        r = driver.run(argv, S, setup=["PROMPT_COMMAND='echo @@pc=$?@@'"],
                       lines=["false", "false; echo @@rc=$?@@"], cwd=ROOT)
        probs = expect_steps(r, [None, ["C", "D;1", "A"], ["C", "D;0", "A"]])
        if "pc=1" not in markers(r["steps"][1]):
            probs.append("PROMPT_COMMAND after us saw %s, want pc=1" % markers(r["steps"][1]))
        if "rc=1" not in markers(r["steps"][2]):
            probs.append("$? inside the line read %s, want rc=1" % markers(r["steps"][2]))
        return probs

    @case("B5", "OSC 7 percent-encodes UTF-8 bytes and decodes back to $PWD")
    def _():
        return check_deep_path(driver.run(argv, S, lines=["cd '%s'" % DEEP], cwd=ROOT))

    @case("B6", "shopt -s extdebug: the trap never skips a command")
    def _():
        r = driver.run(argv, S, lines=["shopt -s extdebug",
                                       'echo @@"m"1@@; echo @@"m"2@@'], cwd=ROOT)
        got = markers(r["steps"][2])
        return [] if got == ["m1", "m2"] else ["printed %s, want ['m1', 'm2']" % got]

    @case("B7", "someone else's DEBUG trap is kept; OSC 7 and A still flow")
    def _():
        r = driver.run(argv, S, setup=["trap 'true' DEBUG"], cwd=ROOT,
                       lines=["true", 'echo @@trap=$(trap -p DEBUG | tr -dc a-z_)@@'])
        probs = expect_steps(r, [["A"], ["A"], ["A"]])
        # tr keeps lowercase only: "trap -- 'true' DEBUG" -> traptrue; ours -> ..._gp_debug_trap
        if markers(r["steps"][2]) != ["trap=traptrue"]:
            probs.append("trap after source: %s" % markers(r["steps"][2]))
        return probs

    @case("B8", "sourcing twice installs once")
    def _():
        r = driver.run(argv, S, lines=["source " + S, "true"], cwd=ROOT)
        # The second `source` is itself a typed command, so it reports C, D;0 once.
        probs = expect_steps(r, [["A"], ["C", "D;0", "A"], ["C", "D;0", "A"]])
        if len(osc7_paths(r["steps"][2])) != 1:
            probs.append("%d OSC 7 per prompt, want 1" % len(osc7_paths(r["steps"][2])))
        return probs

    @case("B9", "bash-preexec present: registers in its arrays, touches no trap or PROMPT_COMMAND")
    def _():
        r = driver.run(argv, S, no_prompt=True, cwd=ROOT, setup=[
            "bash_preexec_imported=defined; precmd_functions=(); preexec_functions=()",
            "PROMPT_COMMAND=''"], lines=[
            "echo @@pre=${preexec_functions[*]}@@ @@post=${precmd_functions[*]}@@ "
            "@@pc=${#PROMPT_COMMAND}@@ @@trap=$(trap -p DEBUG | wc -c | tr -dc 0-9)@@"])
        got = markers(driver.tokens(r["raw"]))
        want = ["pre=_gp_preexec", "post=_gp_precmd", "pc=0", "trap=0"]
        return [] if got == want else ["state %s, want %s" % (got, want)]

    @case("B10", "documented gap: a subshell-only line reports no command")
    def _():
        return expect_steps(driver.run(argv, S, lines=["(exit 7)"], cwd=ROOT), [["A"], ["A"]])

    @case("B11", "another terminal: sourcing is a no-op")
    def _():
        r = driver.run(argv, S, term_program="Apple_Terminal", no_prompt=True, cwd=ROOT,
                       lines=["true", "echo @@pc=${#PROMPT_COMMAND}@@"])
        toks = driver.tokens(r["raw"])
        probs = [t for t in toks if not t.startswith("M:")]
        return (["emitted %s" % probs] if probs else []) + (
            [] if markers(toks) == ["pc=0"] else ["PROMPT_COMMAND changed: %s" % markers(toks)])

    @case("B12", "non-interactive bash: silent, exit 0")
    def _():
        env = dict(os.environ, TERM_PROGRAM="GoblinPortal")
        p = subprocess.run([bash, "-c", "source '%s'; echo ok" % S], env=env,
                           capture_output=True)
        return [] if (p.returncode, p.stdout, p.stderr) == (0, b"ok\n", b"") else [
            "rc=%d out=%r err=%r" % (p.returncode, p.stdout, p.stderr)]


# ── zsh (parity; the shipped script had no behavioural gate before this) ─────

def zsh_suite():
    argv = ["/bin/zsh", "-f", "-i"]
    print("zsh (/bin/zsh):")

    @case("Z1", "true then false: C, D;0 / C, D;1; empty line silent")
    def _():
        r = driver.run(argv, ZSH_SCRIPT, lines=["true", "false", ""], cwd=ROOT)
        return expect_steps(r, [["A"], ["C", "D;0", "A"], ["C", "D;1", "A"], ["A"]])

    @case("Z2", "OSC 7 decodes back to $PWD")
    def _():
        return check_deep_path(driver.run(argv, ZSH_SCRIPT, lines=["cd '%s'" % DEEP], cwd=ROOT))


# ── fish ──────────────────────────────────────────────────────────────────────

def fish_suite(fish):
    argv = [fish, "--no-config", "-i"]  # --no-config: the only OSC 7 is ours
    ver = subprocess.run([fish, "--version"], capture_output=True, text=True).stdout.strip()
    print("fish (%s, %s):" % (fish, ver))
    legacy = {"fish_features": "no-mark-prompt"}

    @case("F1", "native mark-prompt on: we add OSC 7, never a second D")
    def _():
        r = driver.run(argv, FISH_SCRIPT, cwd=ROOT,
                       lines=["true", "false", "echo @@emit=$_gp_emit_133@@"])
        probs = [] if markers(r["steps"][3]) == ["emit=0"] else [
            "_gp_emit_133: %s, want emit=0" % markers(r["steps"][3])]
        for i, code in ((1, "D;0"), (2, "D;1")):
            ds = [k for k in kinds(r["steps"][i]) if k.startswith("D")]
            if ds != [code]:
                probs.append("step %d: D tokens %s, want exactly [%r]" % (i, ds, code))
            if len(osc7_paths(r["steps"][i])) != 1:
                probs.append("step %d: %d OSC 7, want 1" % (i, len(osc7_paths(r["steps"][i]))))
        return probs

    @case("F2", "mark-prompt off (fish 3.x path): our A/C/D, empty line silent")
    def _():
        r = driver.run(argv, FISH_SCRIPT, cwd=ROOT, extra_env=legacy,
                       lines=["true", "false", ""])
        return expect_steps(r, [["A"], ["C", "D;0", "A"], ["C", "D;1", "A"], ["A"]])

    @case("F3", "mark-prompt off: fish_prompt still sees the command's $status")
    def _():
        r = driver.run(argv, FISH_SCRIPT, cwd=ROOT, extra_env=legacy, lines=[
            "function fish_prompt; echo @@ps=$status@@; echo '> '; end", "false"])
        return [] if "ps=1" in markers(r["steps"][2]) else [
            "fish_prompt saw %s, want ps=1" % markers(r["steps"][2])]

    @case("F4", "OSC 7 decodes back to $PWD")
    def _():
        return check_deep_path(driver.run(argv, FISH_SCRIPT, lines=["cd '%s'" % DEEP], cwd=ROOT))

    @case("F5", "another terminal: no OSC 7, nothing installed")
    def _():
        r = driver.run(argv, FISH_SCRIPT, term_program="Apple_Terminal", no_prompt=True,
                       cwd=ROOT, lines=["echo @@inst=(set -q _gp_installed; and echo yes; or echo no)@@"])
        toks = driver.tokens(r["raw"])
        probs = ["emitted OSC 7"] if any(t.startswith("7;") for t in toks) else []
        return probs + ([] if markers(toks) == ["inst=no"] else ["installed: %s" % markers(toks)])


def main():
    bashes = ["/bin/bash"] + [b for b in (os.environ.get("GATE_BASH"), "/opt/homebrew/bin/bash")
                              if b and os.path.exists(b)]
    fish = os.environ.get("GATE_FISH") or shutil.which("fish") or (
        "/opt/homebrew/bin/fish" if os.path.exists("/opt/homebrew/bin/fish") else None)
    if not fish and os.environ.get("GATE_ALLOW_NO_FISH") != "1":
        print("error: fish not found — install it (brew install fish) or set GATE_ALLOW_NO_FISH=1"
              " to accept an UNGATED fish script.", file=sys.stderr)
        return 2
    for b in dict.fromkeys(bashes):
        bash_suite(b)
    zsh_suite()
    if fish:
        fish_suite(fish)
    else:
        print("fish: NOT RUN (GATE_ALLOW_NO_FISH=1) — shell-integration.fish is ungated here")
    shutil.rmtree(ROOT, ignore_errors=True)
    if ran == 0:
        print("error: no case ran (GATE_ONLY=%s matches nothing)" % ONLY, file=sys.stderr)
        return 2
    print("\n%s" % ("all %d shell-script cases passed" % ran if not failures
                    else "%d case(s) FAILED: %s" % (len(set(failures)), " ".join(dict.fromkeys(failures)))))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
