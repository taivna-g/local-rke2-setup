
#!/usr/bin/env bash
set -euo pipefail

###########################################################
# Minimal RKE2 cluster using Multipass INSIDE WSL Ubuntu
# Provisioning done via multipass exec (no cloud-init user-data).
# - 1 server + N agents
# - Default RKE2 version: v1.31.3+rke2r1 (override via env)
###########################################################

# --- Configurable parameters (override via env) ---
SERVERS=${SERVERS:-1}               # minimal script supports 1 server only
AGENTS=${AGENTS:-2}

# RKE2 channel/version (version pinned by default; can override via env)
INSTALL_RKE2_CHANNEL=${INSTALL_RKE2_CHANNEL:-stable}
INSTALL_RKE2_VERSION=${INSTALL_RKE2_VERSION:-v1.31.3+rke2r1}

# VM sizing
SERVER_CPUS=${SERVER_CPUS:-2}
SERVER_MEM=${SERVER_MEM:-4096}      # MB
SERVER_DISK=${SERVER_DISK:-20G}

AGENT_CPUS=${AGENT_CPUS:-2}
AGENT_MEM=${AGENT_MEM:-4096}        # MB
AGENT_DISK=${AGENT_DISK:-20G}

OUT_DIR=${OUT_DIR:-"./out"}
KUBECONFIG_LOCAL="${OUT_DIR}/rke2.yaml"

# --- Resolve multipass (Linux snap inside WSL) ---
if command -v multipass >/dev/null 2>&1; then
  MULTIPASS="multipass"
elif [ -x "/snap/bin/multipass" ]; then
  MULTIPASS="/snap/bin/multipass"
else
  echo "ERROR: multipass not found in WSL. Install: sudo snap install multipass"
  exit 1
fi

mkdir -p "${OUT_DIR}"

# --- Helpers ---
say()  { echo -e "\033[1;32m[+] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
die()  { echo -e "\033[1;31m[x] $*\033[0m"; exit 1; }

require_systemd_in_wsl() {
  if ! command -v systemctl >/dev/null 2>&1; then
    die "systemctl not available. Enable systemd in WSL, restart the distro, then retry."
  fi
  # If systemd isn’t fully running, snap/multipass may fail.
  if ! systemctl is-system-running --quiet; then
    warn "systemd may not be fully running (is-system-running != running). If multipass fails, enable systemd and restart WSL."
  fi
}

install_kubectl_in_wsl() {
  if command -v kubectl >/dev/null 2>&1; then return; fi
  say "Installing kubectl in WSL..."
  sudo apt-get update -y
  sudo apt-get install -y apt-transport-https ca-certificates curl gnupg
  # Note: apt-key is deprecated; fine for quick local setup
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
  echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list
  sudo apt-get update -y
  sudo apt-get install -y kubectl
}

get_ip() {
  local name="$1"
  ${MULTIPASS} info "${name}" | awk '/IPv4/{print $2; exit}'
}

# Even though we don’t use cloud-init for provisioning, the base image still runs cloud-init.
# Waiting ensures the VM is fully initialized (network, packages, etc.) before provisioning.
wait_for_cloud_init_done() {
  local name="$1"
  say "Waiting for cloud-init to complete on ${name}..."
  for i in {1..60}; do
    if ${MULTIPASS} exec "${name}" -- bash -lc 'cloud-init status --wait >/dev/null 2>&1 || true; cloud-init status 2>/dev/null | grep -q "status: done"'; then
      say "cloud-init done on ${name}"
      return 0
    fi
    sleep 3
  done
  warn "cloud-init may not have reported 'done' on ${name}, continuing anyway."
}

# --- VM lifecycle ---
launch_master_vm() {
  local name="rke2-master"
  if [ "${SERVERS}" -ne 1 ]; then
    warn "This minimal script supports 1 server only. Using 1."
  fi
  say "Launching ${name}..."
  ${MULTIPASS} launch --name "${name}" --cpus "${SERVER_CPUS}" --memory "${SERVER_MEM}M" --disk "${SERVER_DISK}" --timeout 600
  wait_for_cloud_init_done "${name}"
}

launch_agent_vm() {
  local name="$1"
  say "Launching ${name}..."
  ${MULTIPASS} launch --name "${name}" --cpus "${AGENT_CPUS}" --memory "${AGENT_MEM}M" --disk "${AGENT_DISK}" --timeout 600
  wait_for_cloud_init_done "${name}"
}

# --- Provisioning (post-boot, via multipass exec) ---
provision_master() {
  local name="rke2-master"
  say "Provisioning RKE2 server on ${name}..."
  ${MULTIPASS} exec "${name}" -- bash -lc "
    set -euo pipefail
    # Ensure curl present
    sudo apt-get update -y
    sudo apt-get install -y curl
    # Basic server config
    sudo mkdir -p /etc/rancher/rke2
    echo 'write-kubeconfig-mode: \"0644\"' | sudo tee /etc/rancher/rke2/config.yaml >/dev/null
    # Install RKE2 server as root, preserving env vars
    curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_CHANNEL='${INSTALL_RKE2_CHANNEL}' INSTALL_RKE2_VERSION='${INSTALL_RKE2_VERSION}' sh -
    sudo systemctl enable rke2-server.service
    sudo systemctl start rke2-server.service
  "
  say "Waiting for rke2-server.service to be active..."
  for i in {1..60}; do
    if ${MULTIPASS} exec "${name}" -- bash -lc "systemctl is-active --quiet rke2-server.service"; then
      say "rke2-server is active on ${name}"
      break
    fi
    sleep 5
  done
}

provision_agent() {
  local name="$1"
  local server_ip="$2"
  local token="$3"
  say "Provisioning RKE2 agent on ${name}..."
  ${MULTIPASS} exec "${name}" -- bash -lc "
    set -euo pipefail
    # Ensure curl present
    sudo apt-get update -y
    sudo apt-get install -y curl
    # Agent config
    sudo mkdir -p /etc/rancher/rke2
    printf 'server: https://%s:9345\ntoken: %s\n' '${server_ip}' '${token}' | sudo tee /etc/rancher/rke2/config.yaml >/dev/null
    # Install RKE2 agent as root, preserving env vars
    curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_CHANNEL='${INSTALL_RKE2_CHANNEL}' INSTALL_RKE2_VERSION='${INSTALL_RKE2_VERSION}' INSTALL_RKE2_TYPE='agent' sh -
    sudo systemctl enable rke2-agent.service
    sudo systemctl start rke2-agent.service
  "
  say "Waiting for rke2-agent.service to be active on ${name}..."
  for i in {1..60}; do
    if ${MULTIPASS} exec "${name}" -- bash -lc "systemctl is-active --quiet rke2-agent.service"; then
      say "rke2-agent is active on ${name}"
      break
    fi
    sleep 5
  done
}

# --- Fetch kubeconfig ---
fetch_kubeconfig() {
  local master_ip="$1"
  say "Fetching kubeconfig from master..."
  ${MULTIPASS} exec rke2-master -- sudo cat /etc/rancher/rke2/rke2.yaml > "${KUBECONFIG_LOCAL}"
  sed -i "s#server: https://127.0.0.1:6443#server: https://${master_ip}:6443#g" "${KUBECONFIG_LOCAL}"
  sed -i "s#server: https://localhost:6443#server: https://${master_ip}:6443#g" "${KUBECONFIG_LOCAL}"
  say "Wrote kubeconfig -> ${KUBECONFIG_LOCAL}"
}

# --- Teardown helper ---
teardown() {
  warn "Deleting all VMs (WSL multipass)..."
  ${MULTIPASS} delete rke2-master >/dev/null 2>&1 || true
  for i in $(seq 1 "${AGENTS}"); do
    ${MULTIPASS} delete "rke2-worker${i}" >/dev/null 2>&1 || true
  done
  ${MULTIPASS} purge >/dev/null 2>&1 || true
  say "Teardown completed."
}

# --- Main ---
trap 'warn "Tip: cleanup via: ${MULTIPASS} delete rke2-master rke2-worker1 rke2-worker2 && ${MULTIPASS} purge"' EXIT

say "=== Minimal RKE2 setup (Multipass inside WSL; exec-based provisioning) ==="
say "Server: 1, Agents: ${AGENTS}, Channel: ${INSTALL_RKE2_CHANNEL}, Version: ${INSTALL_RKE2_VERSION}"

require_systemd_in_wsl
install_kubectl_in_wsl

# Create VMs
launch_master_vm
MASTER_IP="$(get_ip rke2-master)"
provision_master
TOKEN="$(${MULTIPASS} exec rke2-master -- sudo cat /var/lib/rancher/rke2/server/node-token)"

for i in $(seq 1 "${AGENTS}"); do
  name="rke2-worker${i}"
  launch_agent_vm "${name}"
  provision_agent "${name}" "${MASTER_IP}" "${TOKEN}"
done

fetch_kubeconfig "${MASTER_IP}"

say "Validating cluster..."
KUBECONFIG_ABS="$(realpath "${KUBECONFIG_LOCAL}")"
kubectl --kubeconfig="${KUBECONFIG_ABS}" get nodes -o wide

cat <<EOF

Next steps:
  export KUBECONFIG="$(realpath "${KUBECONFIG_LOCAL}")"
  kubectl get nodes -o wide
  kubectl -n kube-system get pods

Teardown:
  ${MULTIPASS} list
  ${MULTIPASS} delete rke2-master rke2-worker1 rke2-worker2
  ${MULTIPASS} purge

EOF

say "All done ✅"
``
