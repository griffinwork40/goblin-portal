# shell-integration.fish — Goblin Portal terminal shell integration for fish.
#
# fish 4.0+ already speaks most of this protocol on its own, so this script is the
# part fish does not always send:
#   OSC 7  — the shell's directory on every prompt. fish 4's default config sends one
#            too, but only from its stock config files (`fish --no-config`, or a
#            config that replaces them, sends none). A duplicate report is harmless:
#            the app stores the latest path.
#   OSC 133 A/C/D — prompt start, command start, command end with its exit status.
#            fish 4.0+ emits these natively under its `mark-prompt` feature (measured
#            on fish 4.9.3: `133;A;click_events=1`, `133;C;cmdline_url=…`, `133;D;0`;
#            Goblin Portal's parser keys on the first byte, so those parse as-is).
#            We emit our own ONLY when that feature is off or unknown (fish 3.x),
#            because two D's per command would report every command twice.
#
# How to install — add to ~/.config/fish/config.fish:
#
#     set -q GOBLIN_PORTAL_INTEGRATION_FISH; and source $GOBLIN_PORTAL_INTEGRATION_FISH
#
# Wrapped in one `if` rather than an early `return`: a top-level return in a sourced
# file is not reliable across fish 3.x releases, and this file must be a no-op
# everywhere except an interactive fish inside Goblin Portal.
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

if test "$TERM_PROGRAM" = GoblinPortal; and status is-interactive; and not set -q _gp_installed
    set -g _gp_installed 1

    # ── multiplexer passthrough ───────────────────────────────────────────────
    #
    # GNU screen: wrap OSC sequences in a DCS passthrough envelope so they reach
    # the outer terminal rather than being consumed by screen's VT100 emulator.
    #
    # Detection: $STY is set by screen (session socket name). We also check $TERM
    # in case $STY was cleared by a login shell.
    #
    # Format: ESC P <inner-sequence> ESC \
    #   where <inner-sequence> is the OSC verbatim (ESC ] ... BEL).
    # Unlike tmux (which uses ESC P tmux; ESC ESC ] ... BEL ESC \), screen uses
    # raw DCS with no prefix string and no ESC doubling.
    #
    # Limitation: screen's DCS passthrough is best-effort. Some older screen
    # builds (pre-4.x) silently drop unrecognised DCS sequences. No .screenrc
    # setting is required for basic DCS forwarding in screen 4.6+.
    set -g _gp_in_screen 0
    if set -q STY; or string match -q 'screen*' -- $TERM
        set -g _gp_in_screen 1
    end

    # `status test-feature` returns 0 = on, 1 = off, 2 = no such feature (fish < 4.0).
    # Anything but "on" means fish will not mark prompts, so we do.
    set -g _gp_emit_133 0
    if not status test-feature mark-prompt 2>/dev/null
        set -g _gp_emit_133 1
    end

    # ── OSC helper ───────────────────────────────────────────────────────────
    #
    # Emit an OSC sequence, wrapping in screen DCS passthrough when needed.
    # `string escape --style=url` percent-encodes over UTF-8 bytes and leaves
    # '/' alone: café → caf%C3%A9.
    function _gp_osc
        if test $_gp_in_screen = 1
            # ESC P  OSC-payload  ESC \
            printf '\033P\033]%s\a\033\\' $argv[1]
        else
            printf '\e]%s\a' $argv[1]
        end
    end

    # One handler, so the order matches zsh's precmd: A, then OSC 7. (D comes from
    # fish_postexec, which fish fires before fish_prompt.)
    function _gp_prompt --on-event fish_prompt
        if test $_gp_emit_133 = 1
            _gp_osc '133;A'
        end
        _gp_osc "7;file://$hostname"(string escape --style=url -- $PWD)
    end

    if test $_gp_emit_133 = 1
        function _gp_preexec --on-event fish_preexec
            _gp_osc '133;C'
            set -g _gp_cmd_running 1
        end

        # $status here is the command's; capture it before anything can change it.
        # The guard mirrors zsh's: a postexec with no preexec reports nothing.
        function _gp_postexec --on-event fish_postexec
            set -l exit_status $status
            if set -q _gp_cmd_running
                _gp_osc "133;D;$exit_status"
                set -e _gp_cmd_running
            end
        end
    end
end
