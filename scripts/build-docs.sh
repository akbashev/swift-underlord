#!/usr/bin/env bash
# Builds the documentation site: each public module's symbols with its catalog (Sources/<Module>/<Module>.docc), and
# the notes (the README's findings and docs/*.md, turned into DocC articles here), merged into one archive and laid
# out for static hosting under /$HOSTING_BASE_PATH, as GitHub Pages serves a project site.
#
#   bash scripts/build-docs.sh [output directory, default .build/site]
#
# Build it on Linux for the whole API: EventLoop and IORing are Linux-only and have no symbols elsewhere.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-.build/site}
BASE=${HOSTING_BASE_PATH:-swift-underlord}
MODULES=(SHA256 Gzip CRC32 CPUFeatures Bcrypt EventLoop IORing Buffers JSON HTTP JWT FastCollections)
NOTES=(measuring stdlib concurrency hardware traps case-gzip)
# DocC: on the PATH, next to the real swift binary (a toolchain linked into /usr/local/bin), or through xcrun on macOS.
SWIFT_BIN=$(dirname "$(readlink -f "$(command -v swift)")")
if command -v docc > /dev/null; then DOCC=(docc)
elif [ -x "$SWIFT_BIN/docc" ]; then DOCC=("$SWIFT_BIN/docc")
else DOCC=(xcrun docc); fi
WORK=.build/docs
rm -rf "$WORK" "$OUT"
mkdir -p "$WORK"

# Symbol graphs, public API only, sorted into a directory per module (its extensions of other modules' types too).
GRAPHS=$(swift package dump-symbol-graph --minimum-access-level public 2>&1 | sed -n 's/^Files written to //p')
[ -d "$GRAPHS" ] || { echo "build-docs: no symbol graphs" >&2; exit 1; }
for module in "${MODULES[@]}"; do
  mkdir -p "$WORK/graphs/$module"
  cp "$GRAPHS/$module.symbols.json" "$GRAPHS/$module"@*.symbols.json "$WORK/graphs/$module/" 2> /dev/null || true
done

# The notes as articles: the README's introduction and findings for the root page, links between notes made DocC links.
CATALOG="$WORK/Notes.docc"
mkdir -p "$CATALOG"
doclinks() { sed -E 's#\]\((docs/)?([a-z0-9-]+)\.md\)#](<doc:\2>)#g; s#\[docs\]\(docs\)#notes#g'; }
{
  echo "# Swift under load"
  echo
  echo "@Metadata {"
  echo "    @TechnologyRoot"
  echo "}"
  # From the README: its introduction and findings, up to the modules table.
  sed -n '2,/^## Modules/p' README.md | sed '$d' | doclinks
  echo "## Topics"
  echo
  echo "### Notes"
  echo
  for note in "${NOTES[@]}"; do echo "- <doc:$note>"; done
} > "$CATALOG/Notes.md"
for note in "${NOTES[@]}"; do doclinks < "docs/$note.md" > "$CATALOG/$note.md"; done

ARCHIVES=()
for module in "${MODULES[@]}"; do
  "${DOCC[@]}" convert "Sources/$module/$module.docc" \
    --additional-symbol-graph-dir "$WORK/graphs/$module" \
    --fallback-display-name "$module" --fallback-bundle-identifier "swift-underlord.$module" \
    --output-path "$WORK/$module.doccarchive" > "$WORK/$module.log" 2>&1 \
    || { cat "$WORK/$module.log" >&2; exit 1; }
  grep -E 'warning|error' "$WORK/$module.log" | sed "s/^/$module: /" >&2 || true
  ARCHIVES+=("$WORK/$module.doccarchive")
done
"${DOCC[@]}" convert "$CATALOG" --fallback-display-name Notes \
  --fallback-bundle-identifier swift-underlord.notes --output-path "$WORK/Notes.doccarchive" > "$WORK/Notes.log" 2>&1 \
  || { cat "$WORK/Notes.log" >&2; exit 1; }
grep -E 'warning|error' "$WORK/Notes.log" | sed "s/^/Notes: /" >&2 || true
ARCHIVES+=("$WORK/Notes.doccarchive")

"${DOCC[@]}" merge "${ARCHIVES[@]}" --synthesized-landing-page-name swift-underlord \
  --synthesized-landing-page-kind Package --output-path "$WORK/swift-underlord.doccarchive"
"${DOCC[@]}" process-archive transform-for-static-hosting "$WORK/swift-underlord.doccarchive" \
  --hosting-base-path "$BASE" --output-path "$OUT"
# The site's root opens the documentation.
cat > "$OUT/index.html" <<HTML
<!doctype html>
<meta charset="utf-8">
<meta http-equiv="refresh" content="0; url=/$BASE/documentation/">
<link rel="canonical" href="/$BASE/documentation/">
<title>swift-underlord</title>
<a href="/$BASE/documentation/">swift-underlord documentation</a>
HTML
echo "site in $OUT (served under /$BASE)"
