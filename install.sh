#!/usr/bin/env bash
# Install the offline VSS bundle on a clean Jetson AGX Thor (run after pull.sh).
# Nothing here needs the internet: images come from pull.sh, configs and models
# from the bundle images. Run as the mic-743 user; sudo is asked once (sysctl).
#
#   ./install.sh            install and start everything
#   ./install.sh --no-start install, create containers and models, but do not start
set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
LIST="$DIR/images.txt"
START=true; [ "${1:-}" = "--no-start" ] && START=false

CONFIG_IMAGE=vss-offline-config:offline-261001
VLLM_IMAGE_TAG=vllm/vllm-openai:nightly-0961bbae2894d574be790d219651824eb199318e
MODEL_RTVI=models/rtvi-qwen3.5-9b:rtvi3.2.1-offline-261001
MODEL_RTVI_HF=models/rtvi-hf-cache:rtvi3.2.1-offline-261001
MODEL_TRANSLATION=models/translation-zh-ja-ko:opus-int8-offline-261001
MODEL_LLM=models/qwen3.8-27b-nvfp4:hf-482ca0f-offline-261001

VSS=$HOME/video-search-and-summarization
DOCKER_DIR=$VSS/deploy/docker
GEN_ENV=developer-profiles/dev-profile-lvs/generated.env
OFFLINE_YML=$HOME/vss-3.2.1/vss-3.2.1-thor-setup/compose.offline.yml
LLM_DIR=$HOME/vss-3.2.1/llm-services/qwen3.8
INSIGHT=$HOME/vss-live-insight-and-alert
HF_CACHE=$HOME/.cache/huggingface-qwen38

step() { echo; echo "=== $(date +%T) $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
trap 'echo "ERROR: install.sh stopped at line $LINENO: $BASH_COMMAND" >&2' ERR
MARKER=$HOME/.vss-offline-bundle-261001   # written once the configs are restored

# The VSS offline settings that are not in generated.env (see compose.offline.yml).
export VST_STREAM_PROCESSOR_IMAGE_TAG=3.2.1-offline NVSTREAMER_IMAGE_TAG=3.2.1-offline
export VST_INSTALL_ADDITIONAL_PACKAGES=false NVSTREAMER_INSTALL_ADDITIONAL_PACKAGES=false
export INSTALL_PROPRIETARY_CODECS=false

vss_compose() {
  (cd "$DOCKER_DIR" && docker compose -p mdx --env-file "$GEN_ENV" \
    -f compose.yml -f "$OFFLINE_YML" "$@")
}
llm_compose() {
  (cd "$LLM_DIR" && VLLM_IMAGE=$VLLM_IMAGE_TAG docker compose -p qwen38-llm \
    --env-file profile.env -f compose.yml "$@")
}
# Alert Bridge is not part of the LVS profile; Live Insight's manage.sh adds it
# to the mdx project with these three configs. Same here.
alert_bridge_compose() {
  local cfg=$DOCKER_DIR/developer-profiles/dev-profile-alerts/vlm-as-verifier/configs
  (unset VLM_BASE_URL KAFKA_BOOTSTRAP_SERVERS
   export VLM_AS_VERIFIER_CONFIG_FILE=$cfg/config.yml
   export VLM_AS_VERIFIER_CONFIG_FILE_REALTIME=$INSIGHT/config/alert-bridge-realtime.yml
   export VLM_AS_VERIFIER_ALERT_TYPE_CONFIG_FILE=$cfg/alert_type_config.json
   vss_compose "$@")
}
insight_compose() {
  docker compose -p vss-live-insight --project-directory "$INSIGHT" \
    -f "$INSIGHT/compose.yml" --env-file "$INSIGHT/.env" "$@"
}

# Copy /model of a model image into a volume sub-directory (skip if already filled).
fill_volume() {
  local volume=$1 image=$2 subdir=$3 owner=$4
  if docker run --rm -v "$volume:/dst" alpine:3.23.4 sh -c "[ -n \"\$(ls -A /dst/$subdir 2>/dev/null)\" ]"; then
    echo "  $volume/$subdir already filled, skipping"; return
  fi
  docker run --rm -v "$volume:/dst" "$image" sh -c \
    "mkdir -p /dst/$subdir && cp -a /model/. /dst/$subdir/ && chown -R $owner /dst/$subdir"
  echo "  $volume/$subdir <- $image"
}

step "1/7 checks"
[ "$(uname -m)" = aarch64 ] || die "not an aarch64 Jetson"
grep -q "R38 (release), REVISION: 4.0" /etc/nv_tegra_release || die "L4T must be R38.4.0 (same as the source host)"
docker info --format '{{json .Runtimes}}' | grep -q '"nvidia"' || die "NVIDIA container runtime missing"
# Containers get the Jetson hardware codecs (nvv4l2decoder ...) from the host;
# without this package RT-VLM cannot decode H.264 and VST cannot transcode.
dpkg -s nvidia-l4t-gstreamer >/dev/null 2>&1 \
  || die "host package nvidia-l4t-gstreamer missing: sudo apt-get install nvidia-l4t-gstreamer (then reboot)"
ip -4 addr show l4tbr0 | grep -q 192.168.55.1 || die "l4tbr0 192.168.55.1 missing (HOST_IP of the bundle)"
[ "$HOME" = /home/mic-743 ] || die "run as mic-743: bundle paths are /home/mic-743/..."
missing=$(grep -vE '^\s*(#|$)' "$LIST" | while read -r _ src _; do docker image inspect "$src" >/dev/null 2>&1 || echo "$src"; done)
docker image inspect "$CONFIG_IMAGE" >/dev/null 2>&1 || missing="$missing $CONFIG_IMAGE"
[ -z "${missing// /}" ] || die "images missing, run pull.sh first:$(printf '\n  %s' $missing)"
echo "  ok"

step "2/7 configs from $CONFIG_IMAGE"
if [ -f "$MARKER" ]; then
  echo "  already restored by an earlier run ($MARKER), skipping"
else
  for d in "$VSS" "$HOME/vss-3.2.1" "$INSIGHT" "$HOME/vss-translation-service"; do
    [ -e "$d" ] && die "$d already exists; remove it or install on a clean host"
  done
  cid=$(docker create "$CONFIG_IMAGE")
  docker cp "$cid:/bundle/." "$HOME/"
  docker rm "$cid" >/dev/null
  echo "$CONFIG_IMAGE restored $(date -Is)" > "$MARKER"
  echo "  restored VSS repo, vss-3.2.1, Live Insight, translation service"
fi

step "3/7 host preparation"
for d in data_log/analytics_cache data_log/calibration_toolkit data_log/elastic/data data_log/elastic/logs \
         data_log/kafka data_log/redis/data data_log/redis/log agent_eval/dataset agent_eval/results; do
  mkdir -p "$DOCKER_DIR/data-dir/$d"
done
chmod -R 777 "$DOCKER_DIR/data-dir/data_log" "$DOCKER_DIR/data-dir/agent_eval"
mkdir -p "$INSIGHT/data"
# Same kernel settings dev-profile.sh applies (IPv6 off, larger TCP buffers).
sudo bash -c "printf '%s\n' \
  'net.ipv6.conf.all.disable_ipv6 = 1' 'net.ipv6.conf.default.disable_ipv6 = 1' 'net.ipv6.conf.lo.disable_ipv6 = 1' \
  'net.core.rmem_max = 5242880' 'net.core.wmem_max = 5242880' \
  'net.ipv4.tcp_rmem = 4096 87380 16777216' 'net.ipv4.tcp_wmem = 4096 65536 16777216' \
  > /etc/sysctl.d/99-vss.conf && sysctl -q -p /etc/sysctl.d/99-vss.conf"
[ "$(cat /proc/sys/net/core/rmem_max)" = 5242880 ] || die "kernel settings from 99-vss.conf did not apply"
echo "  data-dir created, /etc/sysctl.d/99-vss.conf applied"

step "4/7 LLM model -> $HF_CACHE"
mkdir -p "$HF_CACHE"
if [ -n "$(ls -A "$HF_CACHE" 2>/dev/null)" ]; then
  echo "  already filled, skipping"
else
  docker run --rm -v "$HF_CACHE:/dst" "$MODEL_LLM" sh -c \
    "cp -a /model/. /dst/ && chown -R $(id -u):$(id -g) /dst"
  echo "  $HF_CACHE <- $MODEL_LLM"
fi

step "5/7 create containers and volumes (not started)"
llm_compose up --no-start --pull never
vss_compose up --no-start --no-build --pull never
alert_bridge_compose up --no-start --no-build --pull never --no-deps alert-bridge
insight_compose up --no-start --no-build --pull never

step "6/7 models -> volumes, boot service"
fill_volume mdx_rtvi-ngc-model-cache "$MODEL_RTVI" Qwen3.5-9B 1001:1001
fill_volume mdx_rtvi-hf-cache "$MODEL_RTVI_HF" . 1001:1001
fill_volume vss-translation-service_translation-models "$MODEL_TRANSLATION" . 1000:1000

# Docker restarts unless-stopped containers at boot with no ordering. RT-VLM's
# Kafka producer gives up for good if Kafka is not up yet (NoBrokersAvailable),
# so RT-VLM is left to vss-offline.service, whose `compose start` waits for Kafka.
docker update --restart=no vss-rtvi-vlm >/dev/null
sudo install -m 755 "$DIR/systemd/vss-start.sh" /usr/local/bin/vss-start.sh
sudo install -m 644 "$DIR/systemd/vss-offline.service" /etc/systemd/system/vss-offline.service
sudo systemctl daemon-reload
sudo systemctl enable vss-offline.service >/dev/null 2>&1
echo "  vss-offline.service enabled (starts LLM -> VSS -> Live Insight at boot)"

if ! $START; then
  echo; echo "Created but not started. Start with:"
  echo "  docker compose -p qwen38-llm start && docker compose -p mdx start && docker compose -p vss-live-insight start"
  exit 0
fi

step "7/7 start: LLM -> VSS -> Live Insight"
llm_compose up -d --pull never
echo -n "  waiting for LLM on :11434 "
for _ in $(seq 1 120); do curl -sf http://127.0.0.1:11434/v1/models >/dev/null && break; echo -n .; sleep 10; done; echo
vss_compose up -d --no-build --pull never
alert_bridge_compose up -d --no-build --pull never --no-deps alert-bridge
insight_compose up -d --no-build --pull never

echo
docker ps --format '{{.Names}}\t{{.Status}}' | sort
cat <<'EOF'

Installed. vss-offline.service starts everything at boot. Manual (no network needed):
  start: sudo systemctl start vss-offline.service   (or /usr/local/bin/vss-start.sh)
  stop:  docker compose -p vss-live-insight stop; docker compose -p mdx stop; docker compose -p qwen38-llm stop
Never run dev-profile.sh down / up, manage.sh up / restart / down, or llm-profile.sh up.
EOF
