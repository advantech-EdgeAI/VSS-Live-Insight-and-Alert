#!/usr/bin/env bash
# Start the offline VSS stack: LLM -> VSS (mdx) -> Live Insight.
# Run at boot by vss-offline.service. Docker already restarts most containers
# itself; this brings up the ones it does not (kafka, phoenix, vss-vios-sensor,
# vss-vios-nvstreamer-lvs). Safe to run any time: running containers are untouched.
set -u

for _ in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 2; done

rc=0
for project in qwen38-llm mdx vss-live-insight; do
  echo "starting $project"
  docker compose -p "$project" start || { echo "start failed: $project" >&2; rc=1; }
done
exit $rc
