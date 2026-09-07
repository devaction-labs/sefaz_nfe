#!/usr/bin/env bash
# Push wiki/ to github.com/devaction-labs/sefaz_nfe/wiki
#
# GitHub does not create REPO.wiki.git until the first page exists in the UI.
# Open https://github.com/devaction-labs/sefaz_nfe/wiki once, save Home, then run this.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
git clone git@github.com:devaction-labs/sefaz_nfe.wiki.git "$TMP"
cp "$ROOT"/wiki/*.md "$TMP/"
cd "$TMP"
git add -A
git diff --cached --quiet && echo "wiki already up to date" && exit 0
git commit -m "Sync wiki from repo wiki/ directory."
git push
echo "https://github.com/devaction-labs/sefaz_nfe/wiki"
