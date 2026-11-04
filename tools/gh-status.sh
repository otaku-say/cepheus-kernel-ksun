#!/usr/bin/env bash
set -uo pipefail
API="https://api.github.com"
AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json")
echo "== workflow file present?"
curl -sS "${AUTH[@]}" --max-time 30 "$API/repos/otaku-say/cepheus-kernel-ksun/contents/.github/workflows/build.yml" \
 | python -c "import json,sys;d=json.load(sys.stdin);print('path:',d.get('path'),'size:',d.get('size'))"
echo "== runs"
curl -sS "${AUTH[@]}" --max-time 30 "$API/repos/otaku-say/cepheus-kernel-ksun/actions/runs?per_page=5" \
 | python -c "
import json,sys
d=json.load(sys.stdin)
print('total:',d.get('total_count'))
for r in d.get('workflow_runs',[]):
    print(' ',r['id'],r['name'],r['status'],r['conclusion'],r['head_sha'][:8],r['created_at'])
"
