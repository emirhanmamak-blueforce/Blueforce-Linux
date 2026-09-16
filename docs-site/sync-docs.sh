#!/usr/bin/env bash
# One-way sync: repo docs (../docs/*.md) -> site content (./docs/).
# The repo Markdown files are the single source of truth; never edit ./docs by hand.
set -euo pipefail

SITE_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SITE_DIR/../docs"
DST_DIR="$SITE_DIR/docs"

mkdir -p "$DST_DIR"

# Copy only numbered canonical sources; docs/_TEMPLATE.md is never site content.
shopt -s nullglob
sources=("$SRC_DIR"/[0-9][0-9]-*.md)
if [ "${#sources[@]}" -eq 0 ]; then
  echo "No numbered Markdown sources found in $SRC_DIR" >&2
  exit 1
fi
cp -f "${sources[@]}" "$DST_DIR"/

# Remove stale or non-numbered site documents, including _TEMPLATE.md.
for f in "$DST_DIR"/*.md; do
  base="$(basename "$f")"
  if [[ ! "$base" =~ ^[0-9][0-9]-.*\.md$ ]] || [ ! -f "$SRC_DIR/$base" ]; then
    rm -f "$f"
  fi
done

echo "Synced ${#sources[@]} numbered files into docs-site/docs."
