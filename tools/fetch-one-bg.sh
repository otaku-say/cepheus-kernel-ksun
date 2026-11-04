#!/usr/bin/env bash
# background one artifact download
cd "$(dirname "$0")"
nohup bash ./fetch-one.sh "${1:-cepheus-kernel-ksu-16.0}" > fetch-one.log 2>&1 &
echo "started ${1:-cepheus-kernel-ksu-16.0}"
