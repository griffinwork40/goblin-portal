# shell-integration.bash — Goblin Portal terminal shell integration for bash.
#
# The bash twin of shell-integration.zsh: same sequences, same meaning.
#   OSC 7  — the shell's directory on every prompt (the sidebar's fallback when the
#            kernel cwd cannot be read, and the "remote: host" note over ssh).
#   OSC 133 A/C/D — prompt start, command start, command end with its exit status,
#            which drive the tab's status dot and long-command notifications.
#
# How to install — add as the LAST line of ~/.bashrc (and ~/.bash_profile, if your
# login shell reads only that; macOS Terminal-style login shells do):
#
#     [[ -n "$GOBLIN_PORTAL_INTEGRATION_BASH" ]] && source "$GOBLIN_PORTAL_INTEGRATION_BASH"
#
# Last, because it prepends to PROMPT_COMMAND to capture the command's exit status
# before anything else can overwrite $?, and appends a marker that must run after
# everything else in PROMPT_COMMAND (see _gp_prompt_ready).
#
# Works on macOS's /bin/bash (3.2.57) and on bash 4/5 — nothing here needs a newer
# bash, and check-shell-scripts.sh drives /bin/bash for real.
#
# Command start (OSC 133 C) needs a DEBUG trap, which bash has only one of:
#   - bash-preexec loaded (starship, atuin, ...): we register through its
#     precmd_functions / preexec_functions arrays and leave the trap to it.
#   - no DEBUG trap set: we install our own.
#   - someone else's DEBUG trap: we do NOT replace it. You still get OSC 7 and the
#     prompt marker; command status (C/D) is skipped rather than breaking their trap.
#
# Known gap (shared with bash-preexec): bash fires no DEBUG trap for a line that is
# ONLY a subshell, e.g. `(make)`, so that line reports no C/D. `make` or `{ make; }` do.

# Zellij note (issue #207): this script stays SILENT inside zellij
# (TERM_PROGRAM=zellij) intentionally — no DCS Ptmux passthrough is needed:
#   • OSC 133 A/C/D: supported natively by zellij ≥ 0.45.0 (PR #5460); zellij
#     parses and uses the markers itself, so the outer terminal (Goblin Portal)
#     receives them through zellij's own rendering.
#   • OSC 7: zellij main (PR #4867, post-0.45.1) forwards the focused pane's
#     working directory to the parent terminal automatically on every render.
# Unlike tmux (which uses DCS Ptmux passthrough), zellij intercepts and
# re-emits these sequences natively — the shell script has nothing to wrap.
# Detection: $ZELLIJ env var is set by zellij since v0.5.1 (2021-04-23).
[[ "$TERM_PROGRAM" == "GoblinPortal" ]] || return 0
[[ $- == *i* ]] || return 0
# Sourcing twice would prepend twice and emit every sequence twice.
[[ -n "${_gp_installed:-}" ]] && return 0
_gp_installed=1

# ── helpers ──────────────────────────────────────────────────────────────────

_gp_osc() {
    printf '\033]%s\a' "$1"
}

# RFC 3986 percent-encode a path over UTF-8 BYTES — the same walk as the zsh script.
# `local LC_ALL=C` makes ${string:$i:1} one octet, so café → caf%C3%A9; without it
# bash 3.2 under a UTF-8 locale hands printf a code point and writes %E9 (the gate's
# multibyte case falsifies exactly that).
#
# The `& 255` is load-bearing on bash 3.2: its printf reads "'<byte>" as a SIGNED
# char, so 0xC3 comes back as -61 and '%02X' prints %FFFFFFFFFFFFFFC3 (observed on
# /bin/bash 3.2.57). `printf -v` (bash 3.1+) keeps the walk free of subshells.
_gp_urlencode() {
    local LC_ALL=C
    local string="$1" encoded="" byte i code hex
    for (( i = 0; i < ${#string}; i++ )); do
        byte="${string:$i:1}"
        case "$byte" in
            [a-zA-Z0-9_.~/-]) encoded+="$byte" ;;
            *)
                printf -v code '%d' "'$byte"
                printf -v hex '%%%02X' $(( code & 255 ))
                encoded+="$hex"
                ;;
        esac
    done
    printf '%s' "$encoded"
}

# ── prompt side ──────────────────────────────────────────────────────────────

# First in PROMPT_COMMAND: D (command ended) then A (prompt starting) then OSC 7,
# the order zsh's precmd uses. Returns the captured status so PROMPT_COMMAND entries
# and a PS1 that display $? still see the command's status, not ours.
_gp_precmd() {
    local exit_status=$?
    if [[ -n "${_gp_cmd_running:-}" ]]; then
        _gp_osc "133;D;${exit_status}"
        unset _gp_cmd_running
    fi
    _gp_osc "133;A"
    _gp_osc "7;file://${HOSTNAME}$(_gp_urlencode "$PWD")"
    return "$exit_status"
}

# LAST in PROMPT_COMMAND: from here until the user's next command, the DEBUG trap
# may fire C. Arming this inside _gp_precmd instead would let every later
# PROMPT_COMMAND entry trip the trap and report a command nobody typed — the gate's
# "foreign PROMPT_COMMAND" case falsifies exactly that.
_gp_prompt_ready() {
    _gp_at_prompt=1
}

# ── command side ─────────────────────────────────────────────────────────────

_gp_preexec() {
    _gp_osc "133;C"
    _gp_cmd_running=1
}

# The DEBUG trap fires before EVERY simple command, so it must recognise the one
# that matters: the first command of a line the user typed.
#   - not armed: a later command of the same line, or a PROMPT_COMMAND entry.
#   - COMP_LINE set: a completion function running at the prompt.
#   - BASH_COMMAND inside PROMPT_COMMAND: Return on an empty line runs no command,
#     so the trap's next firing is the prompt machinery itself (substring match,
#     the same approximation bash-preexec makes).
# Always returns 0: under `shopt -s extdebug` a non-zero DEBUG trap SKIPS the
# command it guards.
_gp_debug_trap() {
    [[ -n "${_gp_at_prompt:-}" ]] || return 0
    [[ -z "${COMP_LINE:-}" ]] || return 0
    [[ "${PROMPT_COMMAND[*]}" == *"$BASH_COMMAND"* ]] && return 0
    unset _gp_at_prompt
    _gp_preexec
    return 0
}

# ── install ──────────────────────────────────────────────────────────────────

if [[ -n "${bash_preexec_imported:-}${__bp_imported:-}" ]]; then
    # bash-preexec runs precmd functions with $? set to the command's status.
    precmd_functions+=(_gp_precmd)
    preexec_functions+=(_gp_preexec)
else
    # Newlines, not ';', as separators: a PROMPT_COMMAND that already ends in ';'
    # would otherwise become ';;', a syntax error that silences every prompt.
    if [[ "$(declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then
        PROMPT_COMMAND=(_gp_precmd "${PROMPT_COMMAND[@]}" _gp_prompt_ready)  # bash 5.1+
    else
        PROMPT_COMMAND=$'_gp_precmd\n'"${PROMPT_COMMAND:-}"$'\n_gp_prompt_ready'
    fi
    if [[ -z "$(trap -p DEBUG)" ]]; then
        trap '_gp_debug_trap' DEBUG
    fi
fi
