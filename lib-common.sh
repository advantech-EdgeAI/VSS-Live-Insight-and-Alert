# Shared helpers for setup-host.sh.
# Source this file; do not run it directly.

# Validated versions (keep in sync with the README version table).
DOCKER_MIN_VERSION="28.3.3"
DOCKER_MAX_VERSION_EXCLUSIVE="29.5.0"
DOCKER_INSTALL_VERSION="28.3.3"
COMPOSE_MIN_VERSION="2.39.1"
NVIDIA_CTK_MIN_VERSION="1.17.8"
NGC_CLI_VERSION="4.10.0"

VSS_GIT_URL="https://github.com/NVIDIA-AI-Blueprints/video-search-and-summarization.git"
VSS_GIT_TAG="v3.2.1"
VSS_SAMPLE_DATA="nvidia/vss-developer/dev-profile-sample-data:3.2.0"

LLM_ENDPOINT_URL_DEFAULT="http://127.0.0.1:11434"
VSS_ENV_FILE="${HOME}/.vss-thor.env"

if [[ -t 1 ]]; then
  _c_red=$'\e[31m' _c_green=$'\e[32m' _c_yellow=$'\e[33m' _c_blue=$'\e[34m' _c_reset=$'\e[0m'
else
  _c_red='' _c_green='' _c_yellow='' _c_blue='' _c_reset=''
fi

log_step() { echo; echo "${_c_blue}==> $*${_c_reset}"; }
log_info() { echo "    $*"; }
log_skip() { echo "    ${_c_green}[skip]${_c_reset} $*"; }
log_ok()   { echo "    ${_c_green}[ok]${_c_reset} $*"; }
log_warn() { echo "    ${_c_yellow}[warn]${_c_reset} $*" >&2; }
fail()     { echo "${_c_red}[ERROR]${_c_reset} $*" >&2; exit 1; }

# version_ge A B -> true when A >= B
version_ge() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

# version_lt A B -> true when A < B
version_lt() {
  ! version_ge "$1" "$2"
}

first_semver() {
  grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1
}

docker_client_version() {
  docker --version 2>/dev/null | first_semver
}

compose_version() {
  docker compose version --short 2>/dev/null | sed 's/^v//' | first_semver
}

nvidia_ctk_version() {
  nvidia-ctk --version 2>/dev/null | first_semver
}

ngc_version() {
  ngc --version 2>/dev/null | first_semver
}

# Prints the guidance for a Docker version outside the supported range.
docker_version_guidance() {
  local current="$1"
  cat >&2 <<EOF

Docker ${current} is installed, but VSS 3.2.1 requires Docker
>= ${DOCKER_MIN_VERSION} and < ${DOCKER_MAX_VERSION_EXCLUSIVE}.
This script does not change an existing Docker installation, because
other containers on this device may depend on it.

To switch to the validated version yourself:

  # 1. Stop and back up anything you still need from existing containers.
  # 2. Remove the current Docker packages (images and volumes under
  #    /var/lib/docker are kept):
  sudo apt-get remove -y docker-ce docker-ce-cli docker-ce-rootless-extras
  # 3. Install the validated version and pin it:
  curl -fsSL https://get.docker.com | sudo sh -s -- --version ${DOCKER_INSTALL_VERSION}
  sudo apt-mark hold docker-ce docker-ce-cli

Then run this script again.
EOF
}

# Reads LLM service settings (MODEL_ID, VLLM_IMAGE, HF_CACHE_DIR, ...) the same
# way llm-profile.sh does. Usage: load_llm_profile <llm-service-dir>
load_llm_profile() {
  local dir="$1"
  # .env.local may hold an empty HF_TOKEN; keep a token that is already set.
  local saved_hf_token="${HF_TOKEN:-}"
  [[ -f "${dir}/profile.env" ]] || fail "LLM profile not found: ${dir}/profile.env"
  set -a
  # shellcheck disable=SC1091
  source "${dir}/profile.env"
  if [[ -f "${dir}/.env.local" ]]; then
    # shellcheck disable=SC1091
    source "${dir}/.env.local"
  fi
  set +a
  HF_TOKEN="${saved_hf_token:-${HF_TOKEN:-}}"
  HF_CACHE_DIR="${HF_CACHE_DIR:-${HOME}/.cache/huggingface-qwen38}"
}

# Same completeness rule as llm-profile.sh prepare_artifacts().
# Usage: model_cache_complete <hf-cache-dir> <model-id>
model_cache_complete() {
  local cache_dir="$1" model_id="$2"
  local root="${cache_dir}/models--${model_id//\//--}"
  local snapshot
  snapshot="$(find "${root}/snapshots" -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null || true)"

  [[ -n "${snapshot}" ]] \
    && [[ -f "${snapshot}/config.json" ]] \
    && { [[ -f "${snapshot}/model.safetensors" ]] \
      || [[ -f "${snapshot}/model.safetensors.index.json" ]]; } \
    && ! find "${root}" -type f -name '*.incomplete' -print -quit 2>/dev/null | grep -q . \
    && ! find -L "${snapshot}" -type l -print -quit 2>/dev/null | grep -q .
}

# Sets KEY=VALUE in an env file, replacing an existing line or appending one.
# Usage: set_env_line <file> <key> <value>
set_env_line() {
  local file="$1" key="$2" value="$3" tmp
  touch "${file}"
  tmp="$(mktemp "${file}.tmp.XXXXXX")"
  awk -v key="${key}" -v value="${value}" '
    BEGIN { found = 0 }
    index($0, key "=") == 1 { print key "=" value; found = 1; next }
    { print }
    END { if (!found) print key "=" value }
  ' "${file}" >"${tmp}"
  chmod --reference="${file}" "${tmp}" 2>/dev/null || true
  mv "${tmp}" "${file}"
}
