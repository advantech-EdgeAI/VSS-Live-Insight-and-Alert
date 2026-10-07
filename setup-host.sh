#!/usr/bin/env bash
# Prepares a Jetson AGX Thor host for VSS 3.2.1.
#
# Run once with sudo from your normal user account, then reboot:
#   sudo ./setup-host.sh
#
# Safe to run again: steps that are already done are skipped.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
source "${script_dir}/lib-common.sh"

usage() {
  cat <<'EOF'
Usage:
  sudo ./setup-host.sh [options]

Prepares the Jetson AGX Thor host for VSS 3.2.1:
  - apt packages (NVIDIA container stack, GStreamer H.264 plugin, git-lfs, ...)
  - Docker 28.3.3 (stops if an unsupported Docker version is already installed)
  - NVIDIA container runtime as the Docker default runtime
  - network sysctl settings
  - vss-perf.service: sets MAXN power mode and runs jetson_clocks at every boot

Options:
  --no-reboot-prompt   Do not ask to reboot at the end
  -h, --help           Show this help
EOF
}

reboot_prompt=true
while (($#)); do
  case "$1" in
    --no-reboot-prompt) reboot_prompt=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

preflight() {
  log_step "Checking the host"
  [[ "${EUID}" -eq 0 ]] || fail "Run this script with sudo: sudo $0"
  target_user="${SUDO_USER:-}"
  [[ -n "${target_user}" && "${target_user}" != "root" ]] ||
    fail "Run this script with sudo from your normal user account, not as root directly."
  [[ "$(uname -m)" == "aarch64" ]] || fail "This script is for Jetson AGX Thor (aarch64)."

  if [[ -f /etc/nv_tegra_release ]]; then
    local release
    release="$(head -n1 /etc/nv_tegra_release)"
    log_info "Jetson Linux: ${release}"
    grep -q '^# R38' /etc/nv_tegra_release ||
      log_warn "This package is validated on JetPack 7.1 (Jetson Linux R38). Continuing anyway."
  else
    log_warn "/etc/nv_tegra_release not found; this does not look like a Jetson device."
  fi
  log_ok "Running as root for user '${target_user}'"
}

install_packages() {
  log_step "Installing apt packages"
  local packages=(nvidia-container nvidia-l4t-gstreamer curl jq git git-lfs unzip)
  local missing=()
  local pkg
  for pkg in "${packages[@]}"; do
    dpkg -s "${pkg}" >/dev/null 2>&1 || missing+=("${pkg}")
  done
  if ((${#missing[@]} == 0)); then
    log_skip "All packages already installed"
    return
  fi
  log_info "Installing: ${missing[*]}"
  apt-get update
  apt-get install -y "${missing[@]}"
  log_ok "Packages installed"
}

install_docker() {
  log_step "Checking Docker"
  local current
  if command -v docker >/dev/null 2>&1; then
    current="$(docker_client_version)"
    [[ -n "${current}" ]] || fail "Could not read the installed Docker version."
    if version_lt "${current}" "${DOCKER_MIN_VERSION}" ||
      version_ge "${current}" "${DOCKER_MAX_VERSION_EXCLUSIVE}"; then
      docker_version_guidance "${current}"
      exit 1
    fi
    log_skip "Docker ${current} is within the supported range"
  else
    log_info "Installing Docker ${DOCKER_INSTALL_VERSION}"
    curl -fsSL https://get.docker.com | sh -s -- --version "${DOCKER_INSTALL_VERSION}"
    log_ok "Docker $(docker_client_version) installed"
  fi

  # Keep apt upgrade from moving Docker past the supported range.
  if dpkg -s docker-ce >/dev/null 2>&1; then
    apt-mark hold docker-ce docker-ce-cli >/dev/null
    log_ok "docker-ce and docker-ce-cli are held at the current version"
  fi

  systemctl enable --now docker >/dev/null 2>&1

  local compose ctk
  compose="$(compose_version)"
  ctk="$(nvidia_ctk_version)"
  [[ -n "${compose}" ]] && version_ge "${compose}" "${COMPOSE_MIN_VERSION}" ||
    fail "Docker Compose plugin ${compose:-not found} is older than ${COMPOSE_MIN_VERSION}."
  [[ -n "${ctk}" ]] && version_ge "${ctk}" "${NVIDIA_CTK_MIN_VERSION}" ||
    fail "NVIDIA Container Toolkit ${ctk:-not found} is older than ${NVIDIA_CTK_MIN_VERSION}."
  log_ok "Docker Compose ${compose}, NVIDIA Container Toolkit ${ctk}"

  if id -nG "${target_user}" | tr ' ' '\n' | grep -qx docker; then
    log_skip "User '${target_user}' is already in the docker group"
  else
    usermod -aG docker "${target_user}"
    log_ok "Added '${target_user}' to the docker group (takes effect after reboot)"
  fi
}

configure_docker_runtime() {
  log_step "Configuring the NVIDIA container runtime"
  local daemon_json=/etc/docker/daemon.json
  local before after tmp

  before="$(sha256sum "${daemon_json}" 2>/dev/null || true)"

  # Must run before "default-runtime": "nvidia" is set, or Docker fails with
  # "unknown default runtime nvidia".
  nvidia-ctk runtime configure --runtime=docker >/dev/null

  [[ -s "${daemon_json}" ]] || echo '{}' >"${daemon_json}"
  tmp="$(mktemp "${daemon_json}.tmp.XXXXXX")"
  jq '. + {"exec-opts": ["native.cgroupdriver=cgroupfs"], "default-runtime": "nvidia"}' \
    "${daemon_json}" >"${tmp}"
  chmod 644 "${tmp}"
  mv "${tmp}" "${daemon_json}"

  after="$(sha256sum "${daemon_json}")"
  if [[ "${before}" == "${after}" ]]; then
    log_skip "daemon.json already configured"
  else
    systemctl daemon-reload
    systemctl restart docker
    log_ok "daemon.json updated and Docker restarted"
  fi
}

configure_sysctl() {
  log_step "Applying network sysctl settings"
  local conf=/etc/sysctl.d/99-vss.conf
  local desired
  desired="$(printf '%s\n' \
    'net.ipv6.conf.all.disable_ipv6 = 1' \
    'net.ipv6.conf.default.disable_ipv6 = 1' \
    'net.ipv6.conf.lo.disable_ipv6 = 1' \
    'net.core.rmem_max = 5242880' \
    'net.core.wmem_max = 5242880' \
    'net.ipv4.tcp_rmem = 4096 87380 16777216' \
    'net.ipv4.tcp_wmem = 4096 65536 16777216')"

  if [[ -f "${conf}" && "$(cat "${conf}")" == "${desired}" ]]; then
    log_skip "${conf} already up to date"
  else
    printf '%s\n' "${desired}" >"${conf}"
    log_ok "Wrote ${conf}"
  fi
  # Load only our file. "sysctl --system" also reloads other distro files, and
  # some set keys the Jetson kernel lacks (e.g. net.core.default_qdisc), which
  # makes it exit non-zero and stops this script under set -e.
  sysctl -p "${conf}" >/dev/null
  log_ok "sysctl settings applied"
}

install_perf_service() {
  log_step "Installing vss-perf.service (MAXN power mode + jetson_clocks at boot)"
  local nvpmodel_bin jetson_clocks_bin
  nvpmodel_bin="$(command -v nvpmodel || true)"
  jetson_clocks_bin="$(command -v jetson_clocks || true)"
  [[ -n "${nvpmodel_bin}" && -n "${jetson_clocks_bin}" ]] ||
    fail "nvpmodel or jetson_clocks not found. Is this a Jetson device with JetPack installed?"

  cat >/usr/local/sbin/vss-perf.sh <<EOF
#!/usr/bin/env bash
# Installed by setup-host.sh (VSS 3.2.1). Keeps the Thor at maximum performance.
set -u
current_mode="\$(${nvpmodel_bin} -q 2>/dev/null | tail -n1 | tr -d '[:space:]')"
if [[ "\${current_mode}" != "0" ]]; then
  ${nvpmodel_bin} -m 0 </dev/null || echo "vss-perf: could not set power mode 0" >&2
fi
${jetson_clocks_bin}
EOF
  chmod 755 /usr/local/sbin/vss-perf.sh

  cat >/etc/systemd/system/vss-perf.service <<'EOF'
[Unit]
Description=VSS: set MAXN power mode and run jetson_clocks
After=nvpmodel.service multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vss-perf.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable vss-perf.service >/dev/null 2>&1
  log_ok "vss-perf.service enabled"

  # Set MAXN now so the reboot below comes up in the right mode.
  local current_mode
  current_mode="$("${nvpmodel_bin}" -q 2>/dev/null | tail -n1 | tr -d '[:space:]')"
  if [[ "${current_mode}" == "0" ]]; then
    log_skip "Power mode is already 0 (MAXN)"
  else
    log_info "Setting power mode 0 (MAXN). If nvpmodel asks to reboot, answer NO;"
    log_info "this script asks to reboot at the end."
    "${nvpmodel_bin}" -m 0 || log_warn "nvpmodel -m 0 did not finish; it will be retried at boot."
  fi
}

print_summary() {
  log_step "Host setup complete"
  cat <<EOF
    Next steps:
      1. Reboot (applies the docker group, power mode, and jetson_clocks).
      2. Confirm the fan is running before starting any workload.
      3. As '${target_user}' (no sudo), run:
           ${script_dir}/setup-vss.sh
EOF
}

preflight
install_packages
install_docker
configure_docker_runtime
configure_sysctl
install_perf_service
print_summary

if [[ "${reboot_prompt}" == "true" && -t 0 ]]; then
  echo
  read -rp "Reboot now? [y/N] " answer
  if [[ "${answer}" =~ ^[Yy]$ ]]; then
    reboot
  fi
fi
