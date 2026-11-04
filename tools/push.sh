#!/usr/bin/env bash
# one-shot: create the GitHub repo (idempotent) and push the current tree.
# $GITHUB_TOKEN is injected by my-env; never echoed.
set -uo pipefail
REPO="cepheus-kernel-ksun"
OWNER="otaku-say"
API="https://api.github.com"
cd "$(dirname "$0")"

AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json")

echo "== identity"
curl -sS "${AUTH[@]}" --max-time 30 "$API/user" | python -c "import json,sys; print('login:', json.load(sys.stdin)['login'])"

echo "== create repo (409 = already exists)"
code=$(curl -sS "${AUTH[@]}" --max-time 40 -X POST "$API/user/repos" \
  -d "{\"name\":\"$REPO\",\"description\":\"Xiaomi Mi 9 (cepheus) kernel for crDroid 14 - crDroid 16.0 base (Linux 4.14.355) + KernelSU-Next manual hook, byte-compatible boot.img\",\"private\":false,\"has_wiki\":false,\"has_projects\":false}" \
  -o /tmp/repo.json -w "%{http_code}")
echo "http $code"

echo "== commit"
git add -A
git -c user.name=otaku-say -c user.email="{{EMAIL_afnvz32x}}" \
    commit -q -m "cepheus: build 4.14.355 (crDroid 16.0) with KernelSU-Next manual hook

- base: crdroidandroid/android_kernel_xiaomi_cepheus 16.0 (Linux 4.14.355-openela)
- root: KernelSU-Next legacy @ e3292239 (UAPI 5, matches manager v3.4.2),
  built-in (obj-y) because 4.14 registers LSM hooks from __init only
- deterministic source patches instead of KSU Kbuild \$(shell sed -i) racing -j
- boot.img packer reproduces the stock layout byte for byte (v0 header,
  UNCOMPRESSED_IMG + Image + appended DTBs, stock ramdisk, AVB blocks)
- allow_shell / shell_su_adb_only are set via kernel cmdline, not source edits" \
  || echo "nothing to commit"
git branch -M main

echo "== push"
git remote remove origin 2>/dev/null
git remote add origin "https://x-access-token:$GITHUB_TOKEN@github.com/$OWNER/$REPO.git"
git push -u origin main 2>&1 | tail -5
# never leave the token in .git/config
git remote set-url origin "https://github.com/$OWNER/$REPO.git"
echo "== done (token scrubbed from .git/config)"
