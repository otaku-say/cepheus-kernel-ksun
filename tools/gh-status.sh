#!/usr/bin/env bash
set -uo pipefail
API="https://api.github.com"
REPO="otaku-say/cepheus-kernel-ksun"
AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json")
RUN=$(curl -sS "${AUTH[@]}" --max-time 30 "$API/repos/$REPO/actions/runs?per_page=1" \
      | python -c "import json,sys; r=json.load(sys.stdin)['workflow_runs'][0]; print(r['id'])")
curl -sS "${AUTH[@]}" --max-time 30 "$API/repos/$REPO/actions/runs/$RUN" \
 | python -c "
import json,sys
r=json.load(sys.stdin)
print('run', r['id'], r['head_sha'][:8], r['status'], r['conclusion'], r['created_at'])
"
curl -sS "${AUTH[@]}" --max-time 30 "$API/repos/$REPO/actions/runs/$RUN/jobs" \
 | python -c "
import json,sys
for j in json.load(sys.stdin)['jobs']:
    steps=[s for s in j['steps'] if s['status'] not in ('queued','pending')]
    cur=[s['name'] for s in j['steps'] if s['status']=='in_progress']
    print(' ', j['name'], '|', j['status'], j['conclusion'], '| current:', cur[-1:] or '-')
    for s in j['steps']:
        if s['conclusion'] in ('failure','cancelled'):
            print('     FAILED:', s['name'])
"
