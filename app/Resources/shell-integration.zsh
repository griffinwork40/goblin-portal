# shell-integration.zsh — Goblin Portal terminal shell integration for zsh.
#
# What this enables:
#   OSC 7  — tells Goblin Portal where the shell is on every prompt, so the sidebar
#            follows the shell without polling the kernel every 750ms.
#   OSC 133 A/C/D — command lifecycle boundaries, so Goblin Portal can mark a tab
#            when a command fails or a long-running build finishes while you
#            were looking elsewhere.
#
# How to install:
#   Add to ~/.zshrc (after oh-my-zsh / prezto / zi init if you use one):
#
#     [[ -n "$GOBLIN_PORTAL_INTEGRATION" ]] && source "$GOBLIN_PORTAL_INTEGRATION"
#
#   Goblin Portal sets GOBLIN_PORTAL_INTEGRATION to the path of this script in the shell
#   environment. If you prefer to source explicitly:
#
#     source /path/to/GoblinPortal.app/Contents/Resources/shell-integration.zsh
#
# Guard: only activates when TERM_PROGRAM is GoblinPortal. Sourcing in another
# terminal is a no-op, so this block is safe to leave in your .zshrc
# unconditionally.

[[ "$TERM_PROGRAM" == "GoblinPortal" || "$TERM_PROGRAM" == "Umber" ]] || return 0

# ── helpers ──────────────────────────────────────────────────────────────────

# Emit an OSC sequence. BEL (\a) is the terminator — shorter than ST (ESC \)
# and universally understood by SwiftTerm.
_gp_osc() {
    printf '\033]%s\a' "$1"
}

# RFC 3986 percent-encode a path. Only the characters that are safe inside a
# file:// URL are left as-is; '/' is left unencoded (it is a path separator,
# not data). Encoding operates over UTF-8 BYTES, not Unicode code points —
# `printf '%02X'` of a multibyte character (e.g. 'é') yields the code-point
# value (0xE9), not the two UTF-8 bytes (0xC3 0xA9), producing a malformed URL
# that fails percent-decoding. The LC_ALL=C trick forces a byte-at-a-time walk
# so non-ASCII characters encode correctly: café → %C3%A9, 日 → %E6%97%A5.
_gp_urlencode() {
    local string="$1" encoded="" byte
    # LC_ALL=C makes the shell treat the string as raw bytes (one character =
    # one octet), so ${string:$i:1} yields exactly one UTF-8 byte per iteration.
    local LC_ALL=C
    local i
    for (( i = 0; i < ${#string}; i++ )); do
        byte="${string:$i:1}"
        case "$byte" in
            [a-zA-Z0-9_.~/-]) encoded+="$byte" ;;
            *) encoded+=$(printf '%%%02X' "'$byte") ;;
        esac
    done
    printf '%s' "$encoded"
}

# ── OSC 133 hooks ─────────────────────────────────────────────────────────────

# precmd fires AFTER a command, BEFORE the prompt is drawn.
# Order within precmd: D first (command ended), then A (prompt starting).
# Both are emitted in a single precmd function registered with add-zsh-hook so
# the ordering is guaranteed — two separate hooks could interleave.
_gp_precmd() {
    local exit_status=$?  # capture before anything else changes $?

    # OSC 133 D — command finished. Only emit if a command actually ran (i.e.
    # preexec ran before this precmd). The _gp_cmd_running guard prevents a
    # spurious D on the very first prompt after sourcing, before any command.
    if [[ -n "$_gp_cmd_running" ]]; then
        _gp_osc "133;D;${exit_status}"
        unset _gp_cmd_running
    fi

    # OSC 133 A — prompt start. Tells Goblin Portal the shell is about to draw a prompt.
    _gp_osc "133;A"

    # OSC 7 — current working directory. Emitted here (in precmd) so Goblin Portal knows
    # where the shell is as soon as the prompt is visible. SwiftTerm accepts the
    # file://hostname/path format; the hostname is included per the spec so the
    # terminal can ignore OSC 7 from a remote shell in a local tab.
    local url_path
    url_path="$(_gp_urlencode "$PWD")"
    _gp_osc "7;file://${HOST}${url_path}"
}

# preexec fires after the user presses Return and before the command runs.
_gp_preexec() {
    # OSC 133 C — command start. Marks the moment the shell hands control to the
    # user's command, so Goblin Portal can measure how long it ran.
    _gp_osc "133;C"
    _gp_cmd_running=1
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd  _gp_precmd
add-zsh-hook preexec _gp_preexec
