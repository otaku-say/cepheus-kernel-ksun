#!/usr/bin/env bash
# print the failing step's log tail for the newest run (both jobs)
set -uo pipefail
API="https://api.github.com"
REPO="otaku-say/cepheus-kernel-ksun"
AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN")
RUN=$(curl -sS "${AUTH[@]}" -H "Accept: application/vnd.github+json" --max-time 30 \
      "$API/repos/$REPO/actions/runs?per_page=1" \
      | python -c "import json,sys; print(json.load(sys.stdin)['workflow_runs'][0]['id'])")
echo "run=$RUN"
for JOB in $(curl -sS "${AUTH[@]}" -H "Accept: application/vnd.github+json" --max-time 30 \
             "$API/repos/$REPO/actions/runs/$RUN/jobs" \
             | python -c "
import json,sys
for j in json.load(sys.stdin)['jobs']:
    if j['conclusion']=='failure': print(str(j['id']).strip())
"); do
  echo "===== job $JOB"
  curl -sSL "${AUTH[@]}" --max-time 90 "$API/repos/$REPO/actions/jobs/$JOB/logs" -o "/tmp/job-$JOB.txt"
  echo "   log bytes: $(wc -c < "/tmp/job-$JOB.txt")"
  grep -nE "error:|Error [0-9]|FATAL|make\[[0-9]\]|undefined reference|No such file" "/tmp/job-$JOB.txt" \
    | tail -25
  echo "   --- last 12 lines:"
  tail -12 "/tmp/job-$JOB.txt"
done
