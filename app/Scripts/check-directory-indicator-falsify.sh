#!/bin/bash
#
# check-directory-indicator-falsify.sh
# Called by check-directory-indicator.sh --falsify.
# Four mutants, each must make check-directory-indicator.sh exit 1.
#
# STRATEGY.
#   Each mutant gets a full copy of app/ in a mktemp dir (APFS clonefile: cp -cR,
#   fast and space-free). vendor is symlinked so Package.swift's `../vendor/SwiftTerm`
#   still resolves. The mutated source is written into the copy, a checksum guard
#   ensures the text actually changed, then check-directory-indicator.sh is run from
#   inside the copy. Exit 1 means the gate detected the defect; exit 0 means it did not.
#
# MUTANTS.
#   M1 (SpaceViewController+DirectoryFollow.swift): gate status update behind
#      `guard let directory` — indicator never updates for remote-with-nil-directory.
#   M2 (FileTreeViewController+FollowStatus.swift): remove idempotency guard —
#      a new view is installed on every updateDirectoryFollowStatus call.
#   M3 (FileTreeViewController+FollowStatus.swift): show indicator for .unavailable —
#      transient state leaks into the UI.
#   M4 (FileTreeViewController+FollowStatus.swift): insert the indicator at
#      stack index 0 instead of 1, placing it above the git header.
#
# EXIT CONTRACT.
#   0 = all mutants caught (each exited 1).
#   1 = at least one mutant was not caught (gate is blind to that defect).
#   2 = environmental (copy failed, checksum stale, swift build failed in copy, …).
#
set -uo pipefail

QUIET="${QUIET:-0}"
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }
die() { echo "error: $*" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Locate the real app/ root (we are called from app/).
# ---------------------------------------------------------------------------
REAL_APP="$(cd "$(dirname "$0")/.." && pwd)"
REAL_WORKTREE="$(cd "$REAL_APP/.." && pwd)"
REAL_VENDOR="$REAL_WORKTREE/vendor"

[[ -d "$REAL_VENDOR" ]] || die "vendor dir not found at $REAL_VENDOR"

MAINSCRIPT="$REAL_APP/Scripts/check-directory-indicator.sh"
[[ -x "$MAINSCRIPT" ]] || die "check-directory-indicator.sh not found or not executable"

# ---------------------------------------------------------------------------
# Global temp dir — one trap cleans all mutant clones.
# ---------------------------------------------------------------------------
FALSIFY_TMP="$(mktemp -d)"
trap 'rm -rf "$FALSIFY_TMP"' EXIT

all_ok=1

# ---------------------------------------------------------------------------
# make_clone <label> — copy app/ to a fresh tmpdir, symlink vendor.
# Prints the path of the clone on stdout. Exits 2 on failure.
# ---------------------------------------------------------------------------
make_clone() {
  local label="$1"
  local dest="$FALSIFY_TMP/$label"
  mkdir -p "$dest"

  # APFS clonefile first (near-instant, space-free); fall back to plain copy.
  if ! cp -cR "$REAL_APP" "$dest/app" 2>/dev/null; then
    cp -R "$REAL_APP" "$dest/app" || die "cp -R app/ failed for mutant $label"
  fi

  # vendor lives one level above app/ in the real tree; mirror that layout.
  ln -s "$REAL_VENDOR" "$dest/vendor" \
    || die "ln -s vendor failed for mutant $label"

  echo "$dest"
}

# ---------------------------------------------------------------------------
# verify_changed <file> <before_cksum> <label>
# Exits 2 if the file's checksum has not changed (stale pattern).
# ---------------------------------------------------------------------------
verify_changed() {
  local file="$1" before="$2" label="$3"
  local after; after="$(cksum "$file" | awk '{print $1}')"
  [[ "$after" != "$before" ]] \
    || die "mutant $label: substitution did not change $file — pattern is stale"
}

# ---------------------------------------------------------------------------
# run_mutant <label> <clone_app_dir>
# Runs check-directory-indicator.sh (normal mode) from the mutant's app dir.
# Updates all_ok.
# ---------------------------------------------------------------------------
run_mutant() {
  local label="$1" clone_app="$2"
  local mscript="$clone_app/Scripts/check-directory-indicator.sh"
  [[ -x "$mscript" ]] || die "mutant $label: script not found in clone at $mscript"

  local mout mstatus
  mout="$(QUIET=1 "$mscript" 2>&1)"; mstatus=$?

  if [[ $mstatus -eq 1 ]]; then
    say "  ok  mutant $label → exit 1 (gate caught the defect)"
  elif [[ $mstatus -eq 0 ]]; then
    say "  FAIL mutant $label → exit 0 (gate is BLIND to this defect)"
    all_ok=0
  elif [[ $mstatus -eq 2 ]]; then
    say "  FAIL mutant $label → exit 2 (environmental in clone — treating as blind)"
    say "       clone output: $mout"
    all_ok=0
  else
    say "  FAIL mutant $label → exit $mstatus (unexpected — treating as blind)"
    all_ok=0
  fi
}

# ===========================================================================
# M1 — gate status update behind directory != nil
# File: SpaceViewController+DirectoryFollow.swift
# The real code calls updateDirectoryFollowStatus unconditionally (even with nil
# directory). M1 adds `guard let directory` BEFORE the status call so a remote
# shell with nil directory never updates the indicator. Case 9 catches this.
# ===========================================================================
say "  --- mutant M1 (status not updated when directory nil) ---"

M1_CLONE="$(make_clone m1)"
M1_SRC="$M1_CLONE/app/Sources/GoblinPortal/SpaceViewController+DirectoryFollow.swift"
M1_BEFORE="$(cksum "$M1_SRC" | awk '{print $1}')"

perl -i -0pe \
  's|        let context = host\.shellContext\n        space\.fileTree\.updateDirectoryFollowStatus\(context\.followStatus\)\n\n        // Only repoint the tree|        let context = host.shellContext\n        guard let directory = context.directory else { return }  // MUTANT-M1\n        space.fileTree.updateDirectoryFollowStatus(context.followStatus)\n\n        // Only repoint the tree|' \
  "$M1_SRC"

verify_changed "$M1_SRC" "$M1_BEFORE" "M1"
run_mutant "M1" "$M1_CLONE/app"

# ===========================================================================
# M2 — remove idempotency guard (new view installed on every call)
# File: FileTreeViewController+FollowStatus.swift
# The real code short-circuits if the view exists. M2 removes that guard so
# updateDirectoryFollowStatus falls through to the install path every time.
# Case 7 catches this (exactly-1 view after 5 calls).
# ===========================================================================
say "  --- mutant M2 (new view installed on every updateDirectoryFollowStatus call) ---"

M2_CLONE="$(make_clone m2)"
M2_SRC="$M2_CLONE/app/Sources/GoblinPortal/FileTreeViewController+FollowStatus.swift"
M2_BEFORE="$(cksum "$M2_SRC" | awk '{print $1}')"

perl -i -0pe \
  's|        // IDEMPOTENT_INSTALL_GUARD — if already installed, update in place\.\n        if let existing = followIndicatorView\(on: self\) \{\n            updateExistingFollowIndicator\(existing, status: status\)\n            return\n        \}|        // MUTANT-M2: idempotency guard removed — always fall through to install|' \
  "$M2_SRC"

verify_changed "$M2_SRC" "$M2_BEFORE" "M2"
run_mutant "M2" "$M2_CLONE/app"

# ===========================================================================
# M3 — show indicator for .unavailable (transient state leaks into UI)
# File: FileTreeViewController+FollowStatus.swift
# The real updateExistingFollowIndicator calls configure(status:) which hides
# for .unavailable. M3 forces isHidden = false after configure() when status
# is .unavailable. Case 6 catches this.
# ===========================================================================
say "  --- mutant M3 (.unavailable shows indicator) ---"

M3_CLONE="$(make_clone m3)"
M3_SRC="$M3_CLONE/app/Sources/GoblinPortal/FileTreeViewController+FollowStatus.swift"
M3_BEFORE="$(cksum "$M3_SRC" | awk '{print $1}')"

perl -i -0pe \
  's|        indicator\.configure\(status: status\)\n    \}\n\}|        indicator.configure(status: status)\n        // MUTANT-M3: show for .unavailable\n        if case .unavailable = status { indicator.isHidden = false }\n    \}\n\}|' \
  "$M3_SRC"

verify_changed "$M3_SRC" "$M3_BEFORE" "M3"
run_mutant "M3" "$M3_CLONE/app"

# ===========================================================================
# M4 — insert indicator at stack index 0 (above the git header)
# File: FileTreeViewController+FollowStatus.swift
# The real code inserts the indicator at index 1, after the git header at 0,
# so git → indicator → filter → tree. M4 inserts at index 0, putting the
# indicator above the git header. Case 8 catches this — it asserts git header
# index < indicator index.
# ===========================================================================
say "  --- mutant M4 (indicator inserted above git header at index 0) ---"

M4_CLONE="$(make_clone m4)"
M4_SRC="$M4_CLONE/app/Sources/GoblinPortal/FileTreeViewController+FollowStatus.swift"
M4_BEFORE="$(cksum "$M4_SRC" | awk '{print $1}')"

perl -i -0pe \
  's|        let insertAt = min\(1, stack\.arrangedSubviews\.count\)\n        stack\.insertArrangedSubview\(indicator, at: insertAt\)|        let insertAt = 0  // MUTANT-M4: above git header\n        stack.insertArrangedSubview(indicator, at: insertAt)|' \
  "$M4_SRC"

verify_changed "$M4_SRC" "$M4_BEFORE" "M4"
run_mutant "M4" "$M4_CLONE/app"

# ===========================================================================
# Final verdict
# ===========================================================================
if [[ $all_ok -eq 1 ]]; then
  say "==> falsification PASSED — all 4 mutants caused exit 1"
  exit 0
else
  say "==> falsification FAILED — one or more mutants were not detected (gate is blind)"
  exit 1
fi
