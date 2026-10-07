#!/usr/bin/env bash
# Load the offline bundle from a file archive instead of Harbor (no network).
# The folder holds images.tar (docker save of every image in images.txt, local
# names kept), SHA256SUMS, the nvidia-l4t-gstreamer .deb and these scripts.
#
#   sudo dpkg -i nvidia-l4t-gstreamer_*.deb   # before install.sh
#   ./load.sh                                  # verify + docker load + check names
#   ./install.sh
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
cd "$DIR"

echo "$(date +%T) verifying images.tar (sha256, a few minutes)"
sha256sum -c SHA256SUMS

echo "$(date +%T) docker load (20-30 min)"
docker load -i images.tar | tail -3

missing=$(grep -vE '^\s*(#|$)' images.txt | while read -r _ src _; do
  docker image inspect "$src" >/dev/null 2>&1 || echo "$src"; done)
if [ -n "$missing" ]; then
  echo "ERROR: images missing after load:"; echo "$missing"; exit 1
fi
echo "$(date +%T) all $(grep -cvE '^\s*(#|$)' images.txt) images present; next: ./install.sh"
