"""check-shell-scripts-fish-cases.py — fish suite + tmux passthrough helpers.

Split from check-shell-scripts-cases.py at the 350-LOC ceiling. Owns:
  - _make_fake_tmux / _ptmux_env: fake tmux binary for passthrough detection tests.
  - fish_suite: F1–F8 cases for shell-integration.fish.
  - tmux_passthrough_cases(bash_argv, zsh_argv): B14/B15 and Z4/Z5 cases,
    registered into whichever suite calls them.

Call register(mod) first so this module writes into the caller's ran/failures/ONLY
globals via the case() decorator — the same approach the driver uses.
"""

import os
import shutil
import subprocess
import tempfile

_mod = None  # set by register()


def register(mod):
    """Bind this module's case() decorator to the caller's shared state."""
    global _mod
    _mod = mod


def _case(cid, desc):
    """Delegate to the caller module's case() decorator."""
    return _mod.case(cid, desc)


def _make_fake_tmux(tmpdir, passthrough_value):
    """Write a fake `tmux` script that answers `show -gqv allow-passthrough`.

    Lets the shell integration scripts detect passthrough without a real tmux
    server. Only `tmux show` is handled; all other subcommands exit 1 so an
    accidental real-tmux call surfaces as an error.
    """
    script = os.path.join(tmpdir, "tmux")
    with open(script, "w") as f:
        f.write("#!/bin/sh\n")
        f.write('if [ "$1" = "show" ]; then\n')
        f.write('  echo %s\n' % (passthrough_value or "''",))
        f.write("  exit 0\n")
        f.write("fi\n")
        f.write("exit 1\n")
    os.chmod(script, 0o755)
    return tmpdir


def _ptmux_env(passthrough_on):
    """Return (extra_env, tmpdir) that simulate a tmux pane.

    TMUX is set so the scripts enter their $TMUX branch. PATH is prepended
    with a dir holding a fake `tmux` binary. Caller must shutil.rmtree(tmpdir).
    """
    tmpdir = tempfile.mkdtemp(prefix="gp-faketmux-")
    value = "on" if passthrough_on else ""
    _make_fake_tmux(tmpdir, value)
    base = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
    return {
        "TMUX": "/tmp/tmux-99999/default,99999,0",
        "PATH": tmpdir + ":" + base,
    }, tmpdir


def bash_tmux_cases(bash_argv):
    """Register B14/B15: tmux passthrough cases for one bash binary."""
    driver = _mod.driver
    ROOT = _mod.ROOT
    BASH_SCRIPT = _mod.BASH_SCRIPT
    expect_steps = _mod.expect_steps

    @_case("B14", "tmux passthrough on: OSC 7 and 133 arrive wrapped in DCS Ptmux")
    def _():
        extra, tmpdir = _ptmux_env(passthrough_on=True)
        try:
            r = driver.run(bash_argv, BASH_SCRIPT, lines=["true"], cwd=ROOT,
                           extra_env=extra)
            probs = expect_steps(r, [["A"], ["C", "D;0", "A"]])
            if b"\x1bPtmux;" not in r["raw"]:
                probs.append("raw output has no DCS Ptmux envelope (\\x1bPtmux;)")
            return probs
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

    @_case("B15", "tmux passthrough off: raw OSC flows, no DCS Ptmux envelope")
    def _():
        # With TMUX set but allow-passthrough off, _gp_tmux_passthrough stays 0
        # and the scripts emit plain OSC — a real tmux would swallow those, but
        # the harness has no multiplexer so they arrive on the pty unchanged.
        # What matters: no DCS Ptmux envelope was produced.
        extra, tmpdir = _ptmux_env(passthrough_on=False)
        try:
            r = driver.run(bash_argv, BASH_SCRIPT, lines=["true"], cwd=ROOT,
                           extra_env=extra)
            probs = expect_steps(r, [["A"], ["C", "D;0", "A"]])
            if b"\x1bPtmux;" in r["raw"]:
                probs.append("raw output contains unexpected DCS Ptmux envelope")
            return probs
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)


def zsh_tmux_cases():
    """Register Z4/Z5: tmux passthrough cases for zsh."""
    driver = _mod.driver
    ROOT = _mod.ROOT
    ZSH_SCRIPT = _mod.ZSH_SCRIPT
    expect_steps = _mod.expect_steps
    zsh_argv = ["/bin/zsh", "-f", "-i"]

    @_case("Z4", "tmux passthrough on: OSC 7 and 133 arrive wrapped in DCS Ptmux")
    def _():
        extra, tmpdir = _ptmux_env(passthrough_on=True)
        try:
            r = driver.run(zsh_argv, ZSH_SCRIPT, lines=["true"], cwd=ROOT,
                           extra_env=extra)
            probs = expect_steps(r, [["A"], ["C", "D;0", "A"]])
            if b"\x1bPtmux;" not in r["raw"]:
                probs.append("raw output has no DCS Ptmux envelope (\\x1bPtmux;)")
            return probs
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

    @_case("Z5", "tmux passthrough off: raw OSC flows, no DCS Ptmux envelope")
    def _():
        extra, tmpdir = _ptmux_env(passthrough_on=False)
        try:
            r = driver.run(zsh_argv, ZSH_SCRIPT, lines=["true"], cwd=ROOT,
                           extra_env=extra)
            probs = expect_steps(r, [["A"], ["C", "D;0", "A"]])
            if b"\x1bPtmux;" in r["raw"]:
                probs.append("raw output contains unexpected DCS Ptmux envelope")
            return probs
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)


def fish_suite(fish):
    """F1–F8: shell-integration.fish behavioural cases."""
    driver = _mod.driver
    ROOT = _mod.ROOT
    FISH_SCRIPT = _mod.FISH_SCRIPT
    kinds = _mod.kinds
    markers = _mod.markers
    osc7_paths = _mod.osc7_paths
    expect_steps = _mod.expect_steps
    check_deep_path = _mod.check_deep_path
    DEEP = _mod.DEEP

    argv = [fish, "--no-config", "-i"]  # --no-config: the only OSC 7 is ours
    ver = subprocess.run([fish, "--version"], capture_output=True, text=True).stdout.strip()
    print("fish (%s, %s):" % (fish, ver))
    legacy = {"fish_features": "no-mark-prompt"}

    @_case("F1", "native mark-prompt on: we add OSC 7, never a second D")
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

    @_case("F2", "mark-prompt off (fish 3.x path): our A/C/D, empty line silent")
    def _():
        r = driver.run(argv, FISH_SCRIPT, cwd=ROOT, extra_env=legacy,
                       lines=["true", "false", ""])
        return expect_steps(r, [["A"], ["C", "D;0", "A"], ["C", "D;1", "A"], ["A"]])

    @_case("F3", "mark-prompt off: fish_prompt still sees the command's $status")
    def _():
        r = driver.run(argv, FISH_SCRIPT, cwd=ROOT, extra_env=legacy, lines=[
            "function fish_prompt; echo @@ps=$status@@; echo '> '; end", "false"])
        return [] if "ps=1" in markers(r["steps"][2]) else [
            "fish_prompt saw %s, want ps=1" % markers(r["steps"][2])]

    @_case("F4", "OSC 7 decodes back to $PWD")
    def _():
        return check_deep_path(driver.run(argv, FISH_SCRIPT,
                                          lines=["cd '%s'" % DEEP], cwd=ROOT))

    @_case("F5", "another terminal: no OSC 7, nothing installed")
    def _():
        r = driver.run(argv, FISH_SCRIPT, term_program="Apple_Terminal", no_prompt=True,
                       cwd=ROOT,
                       lines=["echo @@inst=(set -q _gp_installed; and echo yes; or echo no)@@"])
        toks = driver.tokens(r["raw"])
        probs = ["emitted OSC 7"] if any(t.startswith("7;") for t in toks) else []
        return probs + ([] if markers(toks) == ["inst=no"]
                        else ["installed: %s" % markers(toks)])

    # Zellij guard (issue #207): fish guard verified independently from B13/Z3 so a
    # fish-specific regression in the TERM_PROGRAM check is caught separately.
    @_case("F6", "zellij: TERM_PROGRAM=zellij, no OSC 7, nothing installed")
    def _():
        r = driver.run(argv, FISH_SCRIPT, term_program="zellij", no_prompt=True,
                       cwd=ROOT,
                       lines=["echo @@inst=(set -q _gp_installed; and echo yes; or echo no)@@"])
        toks = driver.tokens(r["raw"])
        probs = ["emitted OSC 7"] if any(t.startswith("7;") for t in toks) else []
        return probs + ([] if markers(toks) == ["inst=no"]
                        else ["installed: %s" % markers(toks)])

    @_case("F7", "tmux passthrough on: OSC 7 and 133 arrive wrapped in DCS Ptmux")
    def _():
        extra, tmpdir = _ptmux_env(passthrough_on=True)
        try:
            r = driver.run(argv, FISH_SCRIPT, cwd=ROOT,
                           extra_env=dict(legacy, **extra), lines=["true"])
            probs = expect_steps(r, [["A"], ["C", "D;0", "A"]])
            if b"\x1bPtmux;" not in r["raw"]:
                probs.append("raw output has no DCS Ptmux envelope (\\x1bPtmux;)")
            return probs
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

    @_case("F8", "tmux passthrough off: raw OSC flows, no DCS Ptmux envelope")
    def _():
        extra, tmpdir = _ptmux_env(passthrough_on=False)
        try:
            r = driver.run(argv, FISH_SCRIPT, cwd=ROOT,
                           extra_env=dict(legacy, **extra), lines=["true"])
            probs = expect_steps(r, [["A"], ["C", "D;0", "A"]])
            if b"\x1bPtmux;" in r["raw"]:
                probs.append("raw output contains unexpected DCS Ptmux envelope")
            return probs
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)
