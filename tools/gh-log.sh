#!/usr/bin/env bash
set -uo pipefail
API="https://api.github.com"
REPO="otaku-say/cepheus-kernel-ksun"
AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json")
RUN=$(curl -sS "${AUTH[@]}" --max-time 30 "$API/repos/$REPO/actions/runs?per_page=1" \
      | python -c "import json,sys; print(json.load(sys.stdin)['workflow_runs'][0]['id'])")
echo "run=$RUN"
curl -sS "${AUTH[@]}" --max-time 30 "$API/repos/$REPO/actions/runs/$RUN/jobs" \
 | python -c "
import json,sys
d=json.load(sys.stdin)
for j in d['jobs']:
    print('JOB', j['name'], j['status'], j['conclusion'])
    for s in j['steps']:
        if s['conclusion'] not in ('success','skipped',None):
            print('   FAILED STEP:', s['number'], s['name'])
"
JOB=$(curl -sS "${AUTH[@]}" --max-time 30 "$API/repos/$REPO/actions/runs/$RUN/jobs" \
      | python -c "
import json,sys
d=json.load(sys.stdin)
for j in d['jobs']:
    if j['conclusion']=='failure': print(j['id']); break
")
echo "job=$JOB"
rm -rf /tmp/ghlog && mkdir -p /tmp/ghlog
curl -sSL "${AUTH[@]}" --max-time 90 "$API/repos/$REPO/actions/jobs/$JOB/logs" -o /tmp/ghlog/job.zip
(cd /tmp/ghlog && unzip -oq job.zip 2>/dev/null; ls | head)
echo "=== tail of log ==="
cat /tmp/ghlog/*.txt 2>/dev/null | tail -60
