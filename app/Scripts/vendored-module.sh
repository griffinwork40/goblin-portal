#!/bin/bash
#
# One question, asked by the two gates whose subject is the VENDORED emulator rather than
# a file in Sources/GoblinPortal: **where is the compiled SwiftTerm module, and is it the tree on
# disk rather than something left over?**
#
# Sourced, never executed. `check-reflow.sh` and `check-altbuffer-resize.sh` both link a
# merged `SwiftTerm.o`, and both had an identical copy of this logic until 2026-08-05,
# when fixing it in one place and not the other became an obvious way to ship a gate that
# passes for the wrong reason. It lives here rather than inline because check-reflow.sh hit
# the 350-line ceiling, and the rule for that is to find the seam — this is the seam: it is
# one whole concern with exactly two callers, and neither of them is *about* build layout.
#
# Contract:
#   resolve_vendored_module   sets PRODUCTS to the directory holding SwiftTerm.o,
#                             or exits 2 (environmental — never an assertion failure).
#
# Callers must have already cd'd to app/ and may define say(); a fallback is provided so
# this file is testable on its own.

if ! declare -F say >/dev/null 2>&1; then
  say() { echo "$@"; }
fi

resolve_vendored_module() {
  # Request the Swift Build backend EXPLICITLY rather than taking the toolchain default.
  # This harness links a MERGED module object, and that is the only backend which emits
  # one — classic SwiftPM emits per-file objects under SwiftTerm.build/ and no merged
  # object at all, so on classic these gates cannot run.
  #
  # Two wrong versions preceded this one, and both are worth remembering. First a
  # hardcoded ".build/out/Products/Debug", i.e. the Swift Build layout treated as a
  # constant: it worked for the author (whose 6.4 defaults to that backend) and failed for
  # everyone else. Then `--show-bin-path` with no backend pinned, which is the supported
  # question asked of the WRONG backend — CI on 6.3.3 has the flag and still defaults to
  # classic, so it kept failing, just legibly. Selecting the backend is the fix. Asking
  # politely where the wrong backend put things is not.
  local flags=()
  if swift build --help 2>&1 | grep -q -- '--build-system'; then
    flags=(--build-system swiftbuild)
  fi

  # ALWAYS build — never skip on "the .o already exists". That guard was check-reflow.sh's
  # own first bug and the exact silent-failure shape the vendor pin exists to kill: .build
  # is warm in every real working copy, so the gate linked whatever was compiled LAST
  # rather than the vendor tree under test, and a re-vendored SwiftTerm missing patch 0002
  # passed 8/8 against a stale patched object. SwiftPM is incremental, so building
  # unconditionally costs seconds and is the only way the gate's subject is the tree on disk.
  say "building SwiftTerm first (the harness links the vendored module)…"
  if ! swift build "${flags[@]}" >/dev/null 2>&1; then
    echo "error: swift build failed — fix that before trusting this gate." >&2
    exit 2
  fi

  PRODUCTS="$(swift build "${flags[@]}" --show-bin-path 2>/dev/null)"
  if [[ -z "$PRODUCTS" || ! -d "$PRODUCTS" ]]; then
    echo "error: could not resolve the SwiftPM bin path." >&2
    exit 2
  fi

  # Exit 2 rather than 1 if it is missing: environmental, not an assertion failure. But name
  # the real requirement — the bare "absent after swift build" this used to print reads as a
  # failed build and sends the reader looking for one that did not happen.
  if [[ ! -f "$PRODUCTS/SwiftTerm.o" ]]; then
    echo "error: $PRODUCTS/SwiftTerm.o absent after a successful swift build." >&2
    echo "       This gate links a MERGED module object, which only the Swift Build" >&2
    echo "       backend emits. Classic SwiftPM emits per-file objects instead." >&2
    echo "       Backend requested: ${flags[*]:-<toolchain default, no flag available>}" >&2
    echo "       Yours: $(swift --version 2>&1 | head -1)" >&2
    exit 2
  fi
}
