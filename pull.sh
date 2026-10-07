#!/usr/bin/env bash
# Pull the offline bundle from Docker Hub and re-tag every image back to the
# local name the VSS / Live Insight / LLM compose files expect. Safe to re-run:
# images that are already present under their local name are skipped.
#
#   ./pull.sh                 pull everything in images.txt
#   REPO=<registry>/<repo> ./pull.sh
#
# Model images (models/...) are only pulled here; install.sh copies their
# /model contents into the volumes and HF cache after compose creates them.
set -uo pipefail

REPO="${REPO:-docker.io/ispsae/vss-3.2.1-offline-bundle}"
DIR=$(cd "$(dirname "$0")" && pwd)
LIST="$DIR/images.txt"

entries=$(grep -vE '^\s*(#|$)' "$LIST")
total=$(echo "$entries" | wc -l)
i=0; pulled=0; skipped=0; failed=0

echo "$(date +%T) pulling $total images from $REPO"
while read -r type src dst; do
  i=$((i + 1))
  if docker image inspect "$src" >/dev/null 2>&1; then
    echo "$(date +%T) [$i/$total] skip  $src (already present)"
    skipped=$((skipped + 1))
    continue
  fi
  t0=$(date +%s)
  if docker pull -q "$REPO:$dst" >/dev/null && docker tag "$REPO:$dst" "$src"; then
    # Keep only the local name so `docker images` matches the original host.
    [ "$REPO:$dst" != "$src" ] && docker rmi "$REPO:$dst" >/dev/null
    echo "$(date +%T) [$i/$total] ok    $src  ($(( $(date +%s) - t0 ))s)"
    pulled=$((pulled + 1))
  else
    echo "$(date +%T) [$i/$total] FAIL  $REPO:$dst"
    failed=$((failed + 1))
  fi
done <<< "$entries"

echo "$(date +%T) done: pulled=$pulled skipped=$skipped failed=$failed"
[ "$failed" -eq 0 ]
