#!/usr/bin/env bash
# download the newest successful build artifacts and report what is inside
set -uo pipefail
API="https://api.github.com"
REPO="otaku-say/cepheus-kernel-ksun"
AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json")
DEST="${1:-D:/dialogues/2edad4366200d55cb6a8/2026-11-04/431546e6-1fa4-43e7-9103-871c3ef45076/kbuild/artifacts}"
mkdir -p "$DEST"; cd "$DEST"

curl -sS "${AUTH[@]}" --max-time 40 "$API/repos/$REPO/actions/artifacts?per_page=20" \
 | python -c "
import json,sys
seen=set()
for a in json.load(sys.stdin)['artifacts']:   # API returns newest first
    if a['name'] in seen or a['expired']: continue
    seen.add(a['name'])
    print(a['id'], a['name'], a['size_in_bytes'])
" > list.txt
cat list.txt

while read -r id name size; do
  size=${size%$'\r'}   # CRLF from the Windows python writer
  echo "== downloading $name ($((size/1048576)) MiB)"
  curl -sSL "${AUTH[@]}" --max-time 180 "$API/repos/$REPO/actions/artifacts/$id/zip" -o "$name.zip"
  rm -rf "$name"; mkdir -p "$name"
  ( cd "$name" && python -c "import zipfile,sys; zipfile.ZipFile('../$name.zip').extractall('.')" )
  ls -lh "$name" | tail -n +2 | awk '{print "   ", $5, $9}'
done < list.txt
