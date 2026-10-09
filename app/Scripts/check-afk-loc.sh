#!/usr/bin/env bash
#
# check-afk-loc.sh — structural gate: every `| \`X.swift\` | N |` row in AFK.md
# must equal `wc -l` for the named file in Sources/GoblinPortal/ (or
# Sources/GoblinPortalCLI/ if not found there).
#
# The problem this solves: four consecutive PRs hand-corrected stale rows, each
# one that reached review with a wrong count already. A table that the toolchain
# can check in one second costs less context than one an agent must recount by
# inference. The table is the map; the map must stay true.
#
# Exit codes (gate convention — matches check-file-size.sh et al.):
#   0 = every parsed row matches wc -l exactly
#   1 = at least one row mismatch (file, table value, actual value printed)
#   2 = environmental problem (AFK.md missing, no rows parsed — a parser that
#       finds zero rows must NOT pass, because that means the regex changed and
#       the gate is blind)
#
# Usage:
#   cd app && ./Scripts/check-afk-loc.sh           # normal use
#   AFKMD=../path/to/other.md ./Scripts/check-afk-loc.sh  # point at a copy
#
# The AFKMD override is how falsification tests work: mutate a temp copy, point
# the script at it, require exit 1.
#
# Scope note: rows with approximations (~N) are treated as exact after the tilde
# is stripped. The table should carry exact numbers; tildes here indicated drift
# that predated this gate. Every row should now have an exact count.
#
# Parser: matches lines of the form
#   | `Foo.swift` | N |   (N is one or more digits, optionally preceded by ~ or
#                          followed by a space and ⚠ or other text in the cell)
# The backtick-name and the first number in the LOC cell are the two fields we
# need. Everything after the number in the LOC cell is ignored so the gate does
# not break on ceiling-proximity warnings like "⚠ 2 lines from the ceiling".

set -euo pipefail

# Run from app/ so relative paths are stable.
cd "$(dirname "$0")/.."

AFKMD="${AFKMD:-../AFK.md}"

# ── Environmental checks ────────────────────────────────────────────────────

if [ ! -f "$AFKMD" ]; then
  echo "ERROR: AFK.md not found at $AFKMD" >&2
  echo "Run from app/ or set AFKMD=/path/to/AFK.md" >&2
  exit 2
fi

# ── Parse rows ──────────────────────────────────────────────────────────────
# Extract: filename<TAB>stated_loc
# Row format in AFK.md:
#   | `AppDelegate.swift` | 348 | ...
#   | `SyntaxTokeniser.swift` | ~175 | ...
#   | `FileTreeViewController+Git.swift` | 348 ⚠ | ...
#
# awk pulls: field 2 = `Filename.swift`, field 3 = LOC cell
# Strip backticks from name; strip ~ and anything after first non-digit from LOC.

parsed=$(awk -F'|' '
  /\| *`[A-Za-z0-9+_.-]+\.swift` *\|/ {
    name = $2
    loc  = $3
    gsub(/^[[:space:]`]+|[[:space:]`]+$/, "", name)
    gsub(/^[[:space:]~]+/, "", loc)
    match(loc, /^[0-9]+/)
    n = substr(loc, 1, RLENGTH)
    if (name ~ /\.swift$/ && n ~ /^[0-9]+$/) {
      print name "\t" n
    }
  }
' "$AFKMD")

row_count=$(echo "$parsed" | grep -c . 2>/dev/null || true)

if [ "$row_count" -eq 0 ]; then
  echo "ERROR: no rows parsed from $AFKMD — regex may have broken or the table" >&2
  echo "format changed. A parser that finds zero rows must NOT pass (exit 2)." >&2
  exit 2
fi

echo "Parsed $row_count rows from $AFKMD"
echo

# ── Check each row ──────────────────────────────────────────────────────────

failures=0
checked=0

printf '%-50s  %6s  %6s  %s\n' "FILE" "TABLE" "ACTUAL" "STATUS"
printf '%-50s  %6s  %6s  %s\n' "--------------------------------------------------" "------" "------" "------"

while IFS='	' read -r fname stated; do
  [ -n "$fname" ] || continue

  # Look in GoblinPortal first, then GoblinPortalCLI.
  src=""
  for dir in Sources/GoblinPortal Sources/GoblinPortalCLI; do
    candidate="$dir/$fname"
    if [ -f "$candidate" ]; then
      src="$candidate"
      break
    fi
  done

  if [ -z "$src" ]; then
    printf '%-50s  %6s  %6s  SKIP (not in Sources/)\n' "$fname" "$stated" "?"
    continue
  fi

  actual=$(wc -l < "$src" | tr -d ' ')
  checked=$(( checked + 1 ))

  if [ "$actual" -eq "$stated" ]; then
    printf '%-50s  %6s  %6s  ok\n' "$fname" "$stated" "$actual"
  else
    printf '%-50s  %6s  %6s  MISMATCH\n' "$fname" "$stated" "$actual"
    failures=$(( failures + 1 ))
  fi
done <<< "$parsed"

echo

# ── Environmental sanity: at least one file was checked ─────────────────────

if [ "$checked" -eq 0 ]; then
  echo "ERROR: no source files found under Sources/ — Sources/ may be missing." >&2
  exit 2
fi

# ── Verdict ─────────────────────────────────────────────────────────────────

if [ "$failures" -gt 0 ]; then
  echo "FAIL: $failures of $checked rows have a stale LOC count."
  echo
  echo "Fix: update the AFK.md table to match wc -l for each file shown above."
  echo "The convention (AFK.md Conventions): every new file's row is updated in"
  echo "the same commit that adds it, so the map stays true."
  exit 1
fi

echo "OK: all $checked rows match wc -l."
