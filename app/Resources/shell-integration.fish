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

if test "$TERM_PROGRAM" = GoblinPortal; and status is-interactive; and not set -q _gp_installed
    set -g _gp_installed 1

    # `status test-feature` returns 0 = on, 1 = off, 2 = no such feature (fish < 4.0).
    # Anything but "on" means fish will not mark prompts, so we do.
    set -g _gp_emit_133 0
    if not status test-feature mark-prompt 2>/dev/null
        set -g _gp_emit_133 1
    end

    # One handler, so the order matches zsh's precmd: A, then OSC 7. (D comes from
    # fish_postexec, which fish fires before fish_prompt.) `string escape --style=url`
    # percent-encodes over UTF-8 bytes and leaves '/' alone: café → caf%C3%A9.
    function _gp_prompt --on-event fish_prompt
        if test $_gp_emit_133 = 1
            printf '\e]133;A\a'
        end
        printf '\e]7;file://%s%s\a' $hostname (string escape --style=url -- $PWD)
    end

    if test $_gp_emit_133 = 1
        function _gp_preexec --on-event fish_preexec
            printf '\e]133;C\a'
            set -g _gp_cmd_running 1
        end

        # $status here is the command's; capture it before anything can change it.
        # The guard mirrors zsh's: a postexec with no preexec reports nothing.
        function _gp_postexec --on-event fish_postexec
            set -l exit_status $status
            if set -q _gp_cmd_running
                printf '\e]133;D;%s\a' $exit_status
                set -e _gp_cmd_running
            end
        end
    end
end
