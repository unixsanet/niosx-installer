#!/usr/bin/env bash
#
# niosx_prepare_and_install.sh
#
# Purpose:
#   Determine and optionally execute the appropriate host-preparation and
#   NIOS-X installation commands for a bare-metal Linux server, based on the
#   Infoblox "NIOS-X Bare-Metal" deployment guide.
#
# Design goals:
#   - Detect the supported OS family (RHEL 8/9 or Ubuntu 22.04/24.04).
#   - Perform pre-flight validation before making changes.
#   - Default to DRY RUN / PLAN mode so operators can review the exact commands.
#   - Support separate phases for host preparation and NIOS-X installation.
#   - Apply the documented commands conservatively, with explicit warnings when
#     the Infoblox guide requires environment-specific judgment.
#
# IMPORTANT:
#   - This script does NOT download the Infoblox installer automatically.
#     The Infoblox documentation requires downloading the NIOS-X install script
#     from the Infoblox Portal first. Pass that local file path with
#     --install-script during the install phase.
#   - Review the generated plan before using --mode execute in production.
#   - Some network changes can interrupt remote sessions.
#
# Example usage:
#   # 1) Review all prep + install commands for this host
#   ./niosx_prepare_and_install.sh \
#     --phase all \
#     --join-token YOUR_JOIN_TOKEN \
#     --install-script /root/niosx.sh
#
#   # 2) Execute only the host preparation phase
#   sudo ./niosx_prepare_and_install.sh --mode execute --phase prep
#
#   # 3) After reboot, execute the install phase with custom K3s CIDRs
#   sudo ./niosx_prepare_and_install.sh \
#     --mode execute \
#     --phase install \
#     --join-token YOUR_JOIN_TOKEN \
#     --install-script /root/niosx.sh \
#     --cluster-cidr 10.42.0.0/16 \
#     --service-cidr 10.43.0.0/16
#
#   # 4) Reconfigure networking after host/DNS changes
#   sudo ./niosx_prepare_and_install.sh \
#     --mode execute \
#     --phase reconfigure-network \
#     --install-script /root/niosx.sh
#
set -euo pipefail

SCRIPT_NAME=$(basename "$0")
MODE="plan"                     # plan | execute
PHASE="all"                     # prep | install | all | reconfigure-network
JOIN_TOKEN=""
INSTALL_SCRIPT=""
PROXY_URL=""
CLUSTER_CIDR=""
SERVICE_CIDR=""
PORTAL_IFACE=""
NON_PORTAL_IFACES=""
DNS_RESOLVER="8.8.8.8"
ALLOW_REBOOT="false"
FORCE="false"

OS_FAMILY=""
OS_VERSION_ID=""
OS_MAJOR=""

log()  { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME [options]

Options:
  --mode plan|execute             Default: plan
  --phase prep|install|all|reconfigure-network
                                  Default: all
  --join-token TOKEN              Required for install phase
  --install-script PATH           Path to downloaded Infoblox NIOS-X install script
  --proxy URL                     Proxy for NIOS-X installer, e.g. http://proxy:8080
  --cluster-cidr CIDR             Optional custom K3s cluster CIDR
  --service-cidr CIDR             Optional custom K3s service CIDR
  --portal-iface IFACE            On RHEL 9, interface used to reach Infoblox Portal
  --non-portal-ifaces LIST        Comma-separated interfaces that must not install a default route
  --dns-resolver IP               Ubuntu resolver to write to /etc/resolv.conf (default: 8.8.8.8)
  --restart-network		  Restart the network after making changes (console only!)
  --allow-reboot                  Permit reboot during execute/prep phase
  --force                         Continue despite non-fatal warnings where possible
  -h, --help                      Show this help

Recommended workflow:
  1. Run in plan mode and review the generated commands.
  2. Run execute/prep.
  3. Reboot if indicated by the script or guide.
  4. Run execute/install.

Notes:
  - This script is derived from the Infoblox NIOS-X Bare-Metal guide.
  - It deliberately separates OS preparation from software installation.
  - Download the official NIOS-X install script from the Infoblox Portal first.
EOF
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    die "Run this script as root (for example, with sudo)."
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

run_cmd() {
  local desc=$1
  local cmd=$2

  if [[ "$MODE" == "plan" ]]; then
    printf '\n# %s\n%s\n' "$desc" "$cmd"
  else
    log "$desc"
    bash -c "$cmd"
  fi
}

require_file() {
  local path=$1
  [[ -f "$path" ]] || die "Required file not found: $path"
}

validate_ipv4() {
  local ip=$1
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Invalid IPv4 address: $ip"
}

validate_mode_phase() {
  [[ "$MODE" == "plan" || "$MODE" == "execute" ]] || die "--mode must be plan or execute"
  case "$PHASE" in
    prep|install|all|reconfigure-network) ;;
    *) die "--phase must be prep, install, all, or reconfigure-network" ;;
  esac
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        MODE=${2:-}; shift 2 ;;
      --phase)
        PHASE=${2:-}; shift 2 ;;
      --join-token)
        JOIN_TOKEN=${2:-}; shift 2 ;;
      --install-script)
        INSTALL_SCRIPT=${2:-}; shift 2 ;;
      --proxy)
        PROXY_URL=${2:-}; shift 2 ;;
      --cluster-cidr)
        CLUSTER_CIDR=${2:-}; shift 2 ;;
      --service-cidr)
        SERVICE_CIDR=${2:-}; shift 2 ;;
      --portal-iface)
        PORTAL_IFACE=${2:-}; shift 2 ;;
      --non-portal-ifaces)
        NON_PORTAL_IFACES=${2:-}; shift 2 ;;
      --dns-resolver)
        DNS_RESOLVER=${2:-}; shift 2 ;;
      --allow-reboot)
        ALLOW_REBOOT="true"; shift ;;
      --restart-network)
	      RESTART_NETWORK="true"; shift ;;
      --force)
        FORCE="true"; shift ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done
}

detect_os() {
  [[ -r /etc/os-release ]] || die "/etc/os-release not found; cannot detect OS"
  # shellcheck disable=SC1091
  . /etc/os-release

  OS_VERSION_ID=${VERSION_ID:-}
  OS_MAJOR=${OS_VERSION_ID%%.*}

  case "${ID:-}" in
    rhel|rocky|almalinux|centos)
      OS_FAMILY="rhel"
      ;;
    ubuntu)
      OS_FAMILY="ubuntu"
      ;;
    *)
      die "Unsupported OS ID: ${ID:-unknown}. Expected RHEL-compatible or Ubuntu."
      ;;
  esac

  if [[ "$OS_FAMILY" == "rhel" ]]; then
    [[ "$OS_MAJOR" == "8" || "$OS_MAJOR" == "9" ]] || die "Supported RHEL major versions: 8 or 9"
  fi

  if [[ "$OS_FAMILY" == "ubuntu" ]]; then
    [[ "$OS_VERSION_ID" == "22.04" || "$OS_VERSION_ID" == "24.04" ]] || die "Supported Ubuntu versions: 22.04 or 24.04"
  fi
}

preflight_common() {
  log "Detected OS family: $OS_FAMILY $OS_VERSION_ID"

  if grep -qaE 'docker|containerd|kubepods' /proc/1/cgroup 2>/dev/null; then
    die "This host appears to be running inside a container; Docker-in-Docker is not supported. Use a dedicated bare-metal server."
  fi

  if [[ -e /usr/local/bin/k3s ]]; then
    die "Found /usr/local/bin/k3s. The NIOS-X guide requires no K3s binary in /usr/local/bin."
  fi

  local var_free_kb
  var_free_kb=$(df -Pk /var 2>/dev/null | awk 'NR==2 {print $4}')
  [[ -n "$var_free_kb" ]] || die "Unable to determine free space for /var"
  if (( var_free_kb < 20971520 )); then
    die "/var has less than 20 GiB free. Expand /var before proceeding."
  fi

  if command_exists ss; then
    if ss -lntup 2>/dev/null | grep -qE '[:.]53\s'; then
      warn "A process appears to be listening on port 53. The guide requires port 53 to be free."
      [[ "$FORCE" == "true" ]] || die "Resolve port 53 conflicts or rerun with --force after review."
    fi
  elif command_exists netstat; then
    if netstat -lntup 2>/dev/null | grep -qE '[:.]53\s'; then
      warn "A process appears to be listening on port 53. The guide requires port 53 to be free."
      [[ "$FORCE" == "true" ]] || die "Resolve port 53 conflicts or rerun with --force after review."
    fi
  else
    warn "Neither ss nor netstat is available yet; port 53 usage could not be validated preflight."
  fi
}

preflight_install_inputs() {
  [[ -n "$JOIN_TOKEN" ]] || die "--join-token is required for install phase"
  [[ -n "$INSTALL_SCRIPT" ]] || die "--install-script is required for install phase"
  require_file "$INSTALL_SCRIPT"

  if [[ -n "$CLUSTER_CIDR" && -z "$SERVICE_CIDR" ]] || [[ -z "$CLUSTER_CIDR" && -n "$SERVICE_CIDR" ]]; then
    die "--cluster-cidr and --service-cidr must be provided together"
  fi
}

build_rhel_prep() {
  cat <<'EOF'
# ========================
# RHEL host preparation
# ========================
EOF

  run_cmd "Install yum/dnf utilities, storage helpers, and containerd" \
    "dnf install -y dnf-utils device-mapper-persistent-data lvm2 && \
     dnf config-manager --add-repo=https://download.docker.com/linux/centos/docker-ce.repo && \
     dnf install -y containerd.io"

  run_cmd "Install dig utility and net-tools" \
    "dnf install -y bind-utils net-tools"

  run_cmd "Install SELinux packages required by the guide" \
    "dnf install -y container-selinux selinux-policy-base"

  run_cmd "Install the k3s SELinux package matching the RHEL major version" \
    "OS=\$(rpm -E '%{rhel}') && dnf install -y https://github.com/k3s-io/k3s-selinux/releases/download/v1.6.latest.1/k3s-selinux-1.6-1.el\${OS}.noarch.rpm"

  run_cmd "Create a default containerd configuration" \
    "mkdir -p /etc/containerd && containerd config default > /etc/containerd/config.toml"

  run_cmd "Set containerd service LimitNOFILE as recommended" \
    "mkdir -p /etc/systemd/system/containerd.service.d && \
     printf '[Service]\nLimitNOFILE=1024:1048576\n' > /etc/systemd/system/containerd.service.d/override.conf && \
     systemctl daemon-reload && systemctl enable containerd && systemctl restart containerd"

  run_cmd "Disable nm-cloud-setup service" \
    "systemctl disable nm-cloud-setup.service || true"

  run_cmd "Disable firewalld and enable iptables services" \
    "systemctl stop firewalld.service || true && \
     systemctl disable firewalld.service || true && \
     systemctl mask firewalld.service || true && \
     dnf install -y iptables-services && \
     systemctl enable iptables && \
     modprobe ipv6 && modprobe ip6_tables && \
     systemctl start iptables"

  run_cmd "Remove the default FORWARD reject rule from /etc/sysconfig/iptables if present, then restart iptables" \
    "if [[ -f /etc/sysconfig/iptables ]]; then \
         sed -i '/^-A FORWARD -j REJECT --reject-with icmp-host-prohibited$/d' /etc/sysconfig/iptables; \
       fi && \
     systemctl restart iptables"

  if [[ "$OS_MAJOR" == "9" ]]; then
    run_cmd "Migrate NetworkManager connections to the new keyfile format if needed" \
      "nmcli connection migrate || true"

    run_cmd "Show NetworkManager connections so duplicate connections can be reviewed" \
      "nmcli con show"

    if [[ -n "$NON_PORTAL_IFACES" ]]; then
      IFS=',' read -r -a ifaces <<< "$NON_PORTAL_IFACES"
      for iface in "${ifaces[@]}"; do
        run_cmd "Prevent non-portal interface $iface from installing a default route" \
          "nmcli conn modify '$iface' ipv4.never-default yes && nmcli conn down '$iface' || true && nmcli conn up '$iface'"
      done
    else
      warn "No --non-portal-ifaces specified. If this RHEL 9 host has multiple interfaces, set never-default on non-portal interfaces per the guide."
    fi

    if [[ -n "$PORTAL_IFACE" ]]; then
      run_cmd "Set the portal-facing interface $PORTAL_IFACE to the best default route metric" \
        "nmcli conn modify '$PORTAL_IFACE' ipv4.route-metric 0"
    else
      warn "No --portal-iface specified. On multi-homed RHEL 9 hosts, specify the interface used to reach the Infoblox Portal."
    fi

    run_cmd "Remove any legacy GATEWAY line from /etc/sysconfig/network if present" \
      "if [[ -f /etc/sysconfig/network ]]; then sed -i '/^GATEWAY=/d' /etc/sysconfig/network; fi"

    if [[ "$RESTART_NETWORK" == "true" ]]; then
        run_cmd "Restart NetworkManager networking" \
          "nmcli networking off && nmcli networking on"
    fi

  fi

  if [[ "$MODE" == "plan" ]]; then
    cat <<'EOF'
# The Infoblox guide recommends rebooting after the above RHEL preparation.
# In execute mode, pass --allow-reboot if you want this script to reboot.
EOF
  elif [[ "$ALLOW_REBOOT" == "true" ]]; then
    log "Rebooting as requested after RHEL preparation"
    reboot
  else
    warn "RHEL preparation completed. Reboot is recommended before NIOS-X installation."
  fi
}

build_ubuntu_prep() {
  validate_ipv4 "$DNS_RESOLVER"

  cat <<'EOF'
# ========================
# Ubuntu host preparation
# ========================
EOF

  run_cmd "Refresh apt metadata" \
    "apt-get update"

  run_cmd "Install required utilities and package prerequisites" \
    "apt-get install -y net-tools dnsutils ca-certificates curl"

  run_cmd "Install Docker repository keyring and repository definition" \
    "install -m 0755 -d /etc/apt/keyrings && \
     curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc && \
     chmod a+r /etc/apt/keyrings/docker.asc && \
     echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
     \$(. /etc/os-release && echo \"\${UBUNTU_CODENAME:-$VERSION_CODENAME}\") stable\" > /etc/apt/sources.list.d/docker.list"

  run_cmd "Refresh apt metadata after adding the Docker repository" \
    "apt-get update"

  run_cmd "Install containerd" \
    "apt-get install -y containerd"

  run_cmd "Disable systemd-resolved and replace /etc/resolv.conf" \
    "systemctl disable systemd-resolved.service || true && \
     systemctl stop systemd-resolved.service || true && \
     rm -f /etc/resolv.conf && \
     printf 'nameserver %s\n' '$DNS_RESOLVER' > /etc/resolv.conf"

  run_cmd "Ensure the local hostname resolves via /etc/hosts" \
    "HOST_SHORT=\$(hostname -s); grep -qE '^[[:space:]]*127\\.0\\.1\\.1[[:space:]]+' /etc/hosts || echo \"127.0.1.1 \$HOST_SHORT\" >> /etc/hosts"

  run_cmd "Disable NetworkManager wait-online and dispatcher services if present" \
    "systemctl stop NetworkManager-wait-online.service 2>/dev/null || true && \
     systemctl disable NetworkManager-wait-online.service 2>/dev/null || true && \
     systemctl stop NetworkManager-dispatcher.service 2>/dev/null || true && \
     systemctl disable NetworkManager-dispatcher.service 2>/dev/null || true"

  run_cmd "Disable the primary NetworkManager service if present" \
    "if systemctl list-unit-files | grep -q '^NetworkManager.service'; then \
         systemctl stop NetworkManager.service || true; \
         systemctl disable NetworkManager.service || true; \
       fi"

  run_cmd "Switch iptables and ip6tables to legacy mode for Ubuntu 22.04/24.04" \
    "update-alternatives --set iptables /usr/sbin/iptables-legacy && \
     update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy"

  if [[ "$MODE" == "plan" ]]; then
    cat <<'EOF'
# The Infoblox guide also requires disabling unattended-upgrades.
# Because dpkg-reconfigure is interactive, run this manually during the maintenance window:
#   dpkg-reconfigure unattended-upgrades
# The guide recommends rebooting after the above Ubuntu preparation.
EOF
  else
    warn "The guide requires disabling unattended-upgrades with: dpkg-reconfigure unattended-upgrades"
    if [[ "$ALLOW_REBOOT" == "true" ]]; then
      log "Rebooting as requested after Ubuntu preparation"
      reboot
    else
      warn "Ubuntu preparation completed. Reboot is recommended before NIOS-X installation."
    fi
  fi
}

build_install_phase() {
  preflight_install_inputs

  cat <<'EOF'
# ========================
# NIOS-X installation
# ========================
EOF

  if [[ -n "$CLUSTER_CIDR" && -n "$SERVICE_CIDR" ]]; then
    run_cmd "Create /var/bootstrap/k3s_net.json with custom K3s CIDRs" \
      "mkdir -p /var/bootstrap && \
       printf '{\n  \"cluster_cidr\": \"%s\",\n  \"service_cidr\": \"%s\"\n}\n' '$CLUSTER_CIDR' '$SERVICE_CIDR' > /var/bootstrap/k3s_net.json"
  fi

  run_cmd "Make the downloaded Infoblox installer executable" \
    "chmod +x '$INSTALL_SCRIPT'"

  local install_cmd
  install_cmd="'$INSTALL_SCRIPT' -j '$JOIN_TOKEN'"
  if [[ -n "$PROXY_URL" ]]; then
    install_cmd+=" -p '$PROXY_URL'"
  fi

  run_cmd "Run the Infoblox NIOS-X installer" "$install_cmd"
}

build_reconfigure_network_phase() {
  [[ -n "$INSTALL_SCRIPT" ]] || die "--install-script is required for reconfigure-network phase"
  require_file "$INSTALL_SCRIPT"

  cat <<'EOF'
# ========================
# NIOS-X network reconfiguration
# ========================
EOF

  run_cmd "Reconfigure networking using the Infoblox installer helper" \
    "chmod +x '$INSTALL_SCRIPT' && '$INSTALL_SCRIPT' -n"
}

main() {
  parse_args "$@"
  validate_mode_phase
  detect_os

  if [[ "$MODE" == "execute" ]]; then
    require_root
  fi

  preflight_common

  case "$PHASE" in
    prep)
      if [[ "$OS_FAMILY" == "rhel" ]]; then
        build_rhel_prep
      else
        build_ubuntu_prep
      fi
      ;;
    install)
      build_install_phase
      ;;
    all)
      if [[ "$OS_FAMILY" == "rhel" ]]; then
        build_rhel_prep
      else
        build_ubuntu_prep
      fi
      printf '\n# After the documented reboot, run the installation section below.\n'
      build_install_phase
      ;;
    reconfigure-network)
      build_reconfigure_network_phase
      ;;
  esac

  if [[ "$MODE" == "plan" ]]; then
    cat <<EOF

# Review complete.
# Next step:
#   Re-run with --mode execute for the desired phase after validating the plan.
EOF
  else
    log "Completed phase: $PHASE"
  fi
}

main "$@"
