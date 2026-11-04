#!/usr/bin/env bash
# Fails when a built OpenCast product weak-imports any Swift symbol.
#
# A Swift API marked `@backDeployed(before: <newer than our floor>)` compiles to
# a client thunk that checks the OS version and then calls the OS's own symbol
# through a weak import. An OS seed that reports the new version but predates
# the symbol leaves that import NULL, and the call jumps to address 0. This is
# what crashed 2026.11.1 on the iOS 27.2 beta 24B5089g (issue 34): the iOS 27.2
# SDK back-deployed `Date.<=` and `Date.>=`.
#
# Back deployment is the known source of a Swift weak import in this app, so
# any `[weak-import]` of a `_$s…` symbol fails the check, whatever guards the
# call. The allowlist starts empty; an entry needs a recorded decision.
#
# Usage: scripts/check-weak-swift-imports.sh --product <path>
#   <path> is an .xcarchive, an .app, or a Mach-O file. For a bundle, the check
#   reads every Mach-O file inside it: executables, Debug builds'
#   `.debug.dylib` siblings, frameworks, and app extensions with their own
#   debug dylibs (test bundles excluded). A product from which no import
#   can be read fails the check.
# Runs under the system bash 3.2.
set -euo pipefail

allowlist=()

usage() {
  printf 'usage: %s --product <xcarchive | app | Mach-O path>\n' "$0" >&2
  exit 2
}

product=""
while [ $# -gt 0 ]; do
  case "$1" in
    --product)
      [ $# -ge 2 ] || usage
      product="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done
[ -n "$product" ] || usage
[ -e "$product" ] || { printf 'FAIL: no such product: %s\n' "$product" >&2; exit 2; }

case "$product" in
  *.xcarchive|*.xcarchive/)
    app=$(find "$product/Products/Applications" -maxdepth 1 -name '*.app' -print -quit)
    [ -n "$app" ] || { printf 'FAIL: no .app inside %s\n' "$product" >&2; exit 2; }
    ;;
  *)
    app="$product"
    ;;
esac

binaries=()
if [ -d "$app" ]; then
  # A test bundle a test run injects into a Debug product never ships.
  while IFS= read -r -d '' file; do
    case "$(file -b "$file")" in
      Mach-O*) binaries+=("$file") ;;
    esac
  done < <(find "$app" -type f -not -path '*.xctest/*' -print0 | sort -z)
  [ "${#binaries[@]}" -gt 0 ] || { printf 'FAIL: no Mach-O files inside %s\n' "$app" >&2; exit 2; }
else
  binaries+=("$app")
fi

is_allowed() {
  local symbol="$1" entry
  for entry in ${allowlist[@]+"${allowlist[@]}"}; do
    [ "$entry" = "$symbol" ] && return 0
  done
  return 1
}

failures=0
import_rows=0
for binary in "${binaries[@]}"; do
  imports=$(xcrun dyld_info -imports "$binary")
  # Count import records only: a row's symbol (`_…`) stands in column 1 or 2;
  # architecture and `-imports:` header lines carry none.
  rows=$(printf '%s\n' "$imports" | awk '$1 ~ /^_/ || $2 ~ /^_/ { n++ } END { print n + 0 }')
  import_rows=$((import_rows + rows))
  # Chained-fixup rows put the symbol in column 2, other rows in column 1, so
  # take the Swift symbol token wherever it stands.
  weak=$(printf '%s\n' "$imports" | grep -F '[weak-import]' | grep -oE '_\$s[^[:space:]]+' || true)
  for symbol in $weak; do
    is_allowed "$symbol" && continue
    demangled=$(printf '%s\n' "${symbol#_}" | xcrun swift-demangle --simplified)
    printf 'FAIL: %s weak-imports %s (%s)\n' "${binary#"$app"/}" "$symbol" "$demangled"
    failures=$((failures + 1))
  done
done

# A product that imports nothing at all means dyld_info output this script
# cannot read (a single Xcode preview stub may legitimately import nothing).
if [ "$import_rows" -eq 0 ]; then
  printf 'FAIL: no imports read from any binary of %s; dyld_info output not understood\n' "$product" >&2
  exit 2
fi

if [ "$failures" -gt 0 ]; then
  printf 'FAIL: %d disallowed weak import(s) of Swift symbols. A likely cause is a call to an @backDeployed API newer than the deployment floor; an OS build that reports that version without exporting the symbol turns the call into a jump to address 0. Compare through a form that is not back-deployed (for Date: timeIntervalSinceReferenceDate), or record an allowlist decision.\n' "$failures" >&2
  exit 1
fi
printf 'PASS: no weak Swift imports in %d binar%s of %s\n' "${#binaries[@]}" "$([ "${#binaries[@]}" -eq 1 ] && echo y || echo ies)" "$product"
