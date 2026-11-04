#!/usr/bin/env bash
# download the newest artifact with a given name into artifacts/<name>-<id>/
set -uo pipefail
API="https://api.github.com"
REPO="otaku-say/cepheus-kernel-ksun"
AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json")
WANT="${1:?artifact name}"
DEST="${2:-D:/dialogues/2edad4366200d55cb6a8/2026-11-04/431546e6-1fa4-43e7-9103-871c3ef45076/kbuild/artifacts}"
mkdir -p "$DEST"
cd "$DEST"

INFO=$(curl -sS "${AUTH[@]}" --max-time 40 \
  "$API/repos/$REPO/actions/artifacts?per_page=30" \
  | python -c "
import json,sys
for a in json.load(sys.stdin)['artifacts']:
    if a['name']=='$WANT' and not a['expired']:
        print(a['id'], a['name'], a['size_in_bytes'])
        break
")
ID=$(echo "$INFO" | cut -d' ' -f1)
NAME=$(echo "$INFO" | cut -d' ' -f2)
SIZE=$(echo "$INFO" | cut -d' ' -f3)
echo "artifact ${NAME} id=${ID} size=$(( ${SIZE:-0} / 1048576 )) MiB"

D="$NAME-$ID"
if [ ! -s "$D.zip" ]; then
  curl -sSL "${AUTH[@]}" --max-time 900 \
    "$API/repos/$REPO/actions/artifacts/$ID/zip" -o "$D.zip"
fi
rm -rf "$D"; mkdir -p "$D"
( cd "$D" && python -c "import zipfile; zipfile.ZipFile('../$D.zip').extractall('.')" )
find "$D" -type f | while read -r f; do
  printf "  %12s  %s\n" "$(stat -c %s "$f")" "${f#"$D"/}"
done
