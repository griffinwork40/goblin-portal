# shell-integration.zsh — Goblin Portal terminal shell integration for zsh.
#
# What this enables:
#   OSC 7  — tells Goblin Portal where the shell is on every prompt. The sidebar follows
#            the shell's kernel cwd (live, so `cd X && cmd` is right mid-command); a
#            local OSC 7 is the fallback when that cannot be read, and a REMOTE one
#            names the host in the "remote: host" note.
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
#     source "/path/to/Goblin Portal.app/Contents/Resources/shell-integration.zsh"
#
# Guard: only activates when TERM_PROGRAM is GoblinPortal. Sourcing in another
# terminal is a no-op, so this block is safe to leave in your .zshrc
# unconditionally.
#
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

[[ "$TERM_PROGRAM" == "GoblinPortal" || "$TERM_PROGRAM" == "Umber" ]] || return 0  # backward-compat alias -- remove after one release

# ── multiplexer passthrough ───────────────────────────────────────────────────

# GNU screen: wrap OSC sequences in a DCS passthrough envelope so they reach
# the outer terminal rather than being consumed by screen's VT100 emulator.
#
# Detection: $STY is set by screen (it holds the session socket name).  We
# also check $TERM in case $STY was cleared by a login shell.
#
# Format: ESC P <inner-sequence> ESC \
#   where <inner-sequence> is the OSC verbatim (ESC ] ... BEL).
# Unlike tmux, screen uses raw DCS with no "tmux;" prefix; the inner ESC does
# NOT need to be doubled.
#
# Limitation: screen's DCS passthrough is a best-effort channel.  Some older
# screen builds (pre-4.x) silently drop unrecognised DCS sequences.  If OSC 7
# or 133 are not received by the outer terminal, add "mapscrn /dev/null" or
# upgrade to screen 4.6+.  screen does not require any special .screenrc
# setting for basic DCS forwarding.
#
# Cache the result at source time — $STY and $TERM don't change mid-session.
_gp_in_screen=0
if [[ -n "${STY:-}" || "${TERM:-}" == screen* ]]; then
    _gp_in_screen=1
fi

# ── helpers ──────────────────────────────────────────────────────────────────

# Emit an OSC sequence.  Outside a multiplexer: BEL (\a) terminator, shorter
# than ST (ESC \) and universally understood by SwiftTerm.  Inside screen:
# wrap in DCS passthrough so the sequence reaches the outer terminal.


# ── tmux DCS passthrough detection ───────────────────────────────────────────
#
# When $TMUX is set and the session has `allow-passthrough on`, OSC sequences
# must be wrapped in a DCS Ptmux envelope so the outer terminal (Goblin Portal)
# receives them. Without wrapping, tmux consumes OSC sequences silently.
#
# Detection runs ONCE at shell startup (result cached in _gp_tmux_passthrough).
# `tmux show -gqv allow-passthrough` returns "on" or "all" (tmux 3.3a+) when
# passthrough is enabled, and empty string or "off" otherwise. On tmux < 3.2
# the flag does not exist and the command returns empty — same code path as
# "off", so we safely fall through to the existing silent behaviour.
#
# ATTRIBUTION CAVEAT: tmux delivers passthrough sequences from ANY pane to the
# outer terminal without pane attribution. Two panes cd-ing simultaneously can
# cross-contaminate each other's OSC 7 reports. The 750 ms poll in
# TmuxDirectory.swift remains the attribution-correct backstop; passthrough is
# an instant supplement, not a replacement.

_gp_tmux_passthrough=0
if [[ -n "$TMUX" ]]; then
    _gp_pt=$(tmux show -gqv allow-passthrough 2>/dev/null)
    [[ "$_gp_pt" == "on" || "$_gp_pt" == "all" ]] && _gp_tmux_passthrough=1
    unset _gp_pt
fi

# ── helpers ──────────────────────────────────────────────────────────────────

# Emit an OSC sequence. When tmux passthrough is enabled, wraps the sequence in
# a DCS Ptmux envelope so the outer terminal receives it:
#   ESC P tmux ; ESC <payload-with-doubled-ESCs> ESC \
# The inner OSC uses ST (ESC \) not BEL as its terminator — BEL inside a DCS
# string is not valid. Every ESC byte in the payload is doubled so tmux can
# identify the terminating ESC \ unambiguously. Without passthrough, emits a
# plain OSC with BEL terminator.

_gp_osc() {
    if (( _gp_in_screen )); then
        # ESC P  OSC-payload  ESC \
        printf '\033P\033]%s\a\033\\' "$1"
    elif [[ "$_gp_tmux_passthrough" == "1" ]]; then
        local payload="${1//$'\033'/$'\033\033'}"
        printf '\033Ptmux;\033\033]%s\033\\\033\\' "$payload"
    else
        printf '\033]%s\a' "$1"
    fi
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

    # OSC 7 — current working directory, emitted at precmd (so it predates any `cd` in the
    # next command line — why the app prefers the kernel cwd locally). SwiftTerm accepts the
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
