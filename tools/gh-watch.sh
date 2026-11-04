#!/usr/bin/env bash
# wait, then print the newest workflow run status
sleep "${1:-240}"
exec bash "$(cd "$(dirname "$0")" && pwd)/gh-status.sh"
