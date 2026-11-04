#!/usr/bin/env bash
# start the artifact download in the background and return immediately
cd "$(dirname "$0")"
nohup bash ./fetch-artifacts.sh > fetch.log 2>&1 &
echo "started, log: $(pwd)/fetch.log"
