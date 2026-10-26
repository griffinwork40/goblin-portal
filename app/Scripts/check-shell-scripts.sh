#!/bin/bash
#
# Do the SHIPPED shell-integration scripts (Resources/shell-integration.{bash,zsh,fish})
# write the OSC 7 / OSC 133 stream the app's parsers expect, inside REAL interactive
# shells?
#
# WHAT IS UNDER TEST: the three scripts, as a user's rc file sources them.
#   Scripts/check-shell-scripts-driver.py — pty driver (answers fish 4's DA1 query)
#   Scripts/check-shell-scripts-cases.py  — the case table (B1-B12, Z1-Z2, F1-F5)
#
# WHY THIS IS SEPARATE FROM check-shell-integration.sh. That gate compiles the Swift
# CONSUMERS (ShellIntegration.swift, Osc7Directory.swift) and feeds them hand-written
# payloads. Nothing ran the PRODUCERS: the zsh script shipped with no behavioural
# check at all, and the first run of the bash script under /bin/bash 3.2 showed why
# one is needed — bash 3.2's printf reads a high byte as a signed char, so `é`
# encoded as %FFFFFFFFFFFFFFC3%FFFFFFFFFFFFFFA9 and every non-ASCII path broke OSC 7.
#
# SHELLS. /bin/bash (3.2.57 on macOS — the hard compatibility target), any
# /opt/homebrew/bin/bash or $GATE_BASH, /bin/zsh, and fish ($GATE_FISH or PATH). A
# missing fish exits 2 rather than passing with the fish script unexercised; set
# GATE_ALLOW_NO_FISH=1 to accept that knowingly.
#
# SCREEN PASSTHROUGH. The scripts wrap OSC 7 and OSC 133 in a GNU screen DCS
# passthrough envelope (ESC P <payload> ESC \) when $STY is set or $TERM starts
# with "screen". This cannot be exercised here: the pty harness does not run screen,
# and screen's DCS forwarding requires a real outer terminal to receive the bytes.
# Cases that WOULD be needed if screen were available in the pty harness:
#   SC1  STY set: OSC 7 arrives at the outer pty wrapped in ESC P ... ESC \
#   SC2  TERM=screen: same wrapping without STY (login-shell cleared STY)
#   SC3  neither STY nor TERM=screen*: bare OSC (no wrapping, existing B1-B12/Z1-Z2/F1-F5)
#   SC4  bash/zsh/fish all produce identical DCS-wrapped payloads (cross-shell parity)
# Blocked by: screen not installed on the CI / build host; no pty-in-pty harness.
# Track in #207 (multiplexer passthrough).
#
# FALSIFY (--falsify). Copies Resources/ to a temp dir, applies one mutant per copy,
# and runs ONLY the case that mutant must break (GATE_ONLY). A mutant counts as caught
# only when that run exits 1; exit 0 is MISSED; a pattern that no longer applies, or
# an environmental exit, makes the whole falsify run exit 2. Zero mutants run -> 2.
#
# EXIT CODES: 0 = all cases pass. 1 = a real failure (or a missed mutant).
#             2 = environmental (no python3, a required shell missing, stale mutant).
#
set -uo pipefail
cd "$(dirname "$0")/.."
export PYTHONDONTWRITEBYTECODE=1

command -v python3 >/dev/null 2>&1 || { echo "error: python3 not found" >&2; exit 2; }
for sh in /bin/bash /bin/zsh; do
    [[ -x "$sh" ]] || { echo "error: $sh not found" >&2; exit 2; }
done
for f in Resources/shell-integration.bash Resources/shell-integration.zsh \
         Resources/shell-integration.fish Scripts/check-shell-scripts-cases.py \
         Scripts/check-shell-scripts-driver.py; do
    [[ -f "$f" ]] || { echo "error: $f not found — did it move?" >&2; exit 2; }
done

CASES="Scripts/check-shell-scripts-cases.py"

if [[ "${1:-}" != "--falsify" ]]; then
    python3 "$CASES"
    exit $?
fi

# ── falsification ────────────────────────────────────────────────────────────
# name @ file @ declared case @ old @ new   ('@' because the patterns contain '|')
# Each row removes ONE defence the scripts' comments claim, and names the case that
# exists to notice.
MUTANTS=(
  'no-prompt-command-guard@bash@B2@    [[ "${PROMPT_COMMAND[*]}" == *"$BASH_COMMAND"* ]] && return 0\n@'
  'no-byte-mask@bash@B5@$(( code & 255 ))@$code'
  'no-c-locale@bash@B5@    local LC_ALL=C\n@'
  'trap-returns-nonzero@bash@B6@[[ -n "${_gp_at_prompt:-}" ]] || return 0@[[ -n "${_gp_at_prompt:-}" ]] || return 1'
  'precmd-drops-status@bash@B4@    return "$exit_status"\n@'
  'no-running-guard@bash@B1@    if [[ -n "${_gp_cmd_running:-}" ]]; then\n        _gp_osc "133;D;${exit_status}"@    if true; then\n        _gp_osc "133;D;${exit_status}"'
  'fish-always-emits-133@fish@F1@if not status test-feature mark-prompt 2>/dev/null@if true'
  'bash-no-ptmux-detection@bash@B14@    if [[ "$_gp_pt" == "on" || "$_gp_pt" == "all" ]]; then\n        _gp_tmux_passthrough=1\n    fi@    if false; then\n        _gp_tmux_passthrough=1\n    fi'
  'bash-no-ptmux-wrap@bash@B14@        printf '"'"'\033Ptmux;\033\033]%s\033\\\033\\'"'"' "$payload"@        printf '"'"'\033]%s\a'"'"' "$payload"'
  'zsh-no-ptmux-detection@zsh@Z4@    [[ "$_gp_pt" == "on" || "$_gp_pt" == "all" ]] && _gp_tmux_passthrough=1@    true'
)

caught=0; missed=0; ran=0
for row in "${MUTANTS[@]}"; do
    IFS='@' read -r name shell cid old new <<<"$row"
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/gp-shells-falsify.XXXXXX")"
    cp Resources/shell-integration.* "$tmp/"
    # Literal string replace in python (no regex, no sed quoting): \n is the only
    # translation. Exit 3 = the pattern is gone.
    if ! python3 - "$tmp/shell-integration.$shell" "$old" "$new" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
unesc = lambda s: s.replace("\\n", "\n")
old, new = unesc(old), unesc(new)
src = open(path).read()
if src.count(old) != 1:
    sys.exit(3)
open(path, "w").write(src.replace(old, new))
PY
    then
        echo "  STALE  $name: its pattern no longer matches shell-integration.$shell exactly once" >&2
        rm -rf "$tmp"; exit 2
    fi
    GATE_SCRIPT_DIR="$tmp" GATE_ONLY="$cid" python3 "$CASES" >"$tmp/out.log" 2>&1
    rc=$?
    ran=$((ran + 1))
    case "$rc" in
        1) caught=$((caught + 1)); echo "  caught  $name -> $cid fails" ;;
        0) missed=$((missed + 1)); echo "  MISSED  $name -> $cid still passes"; sed 's/^/          /' "$tmp/out.log" ;;
        *) echo "  ENV     $name -> exit $rc"; sed 's/^/          /' "$tmp/out.log"; rm -rf "$tmp"; exit 2 ;;
    esac
    rm -rf "$tmp"
done

(( ran > 0 )) || { echo "error: no mutant ran" >&2; exit 2; }
echo "falsify: $caught/$ran caught"
(( missed == 0 )) || exit 1
exit 0
