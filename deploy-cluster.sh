
#!/usr/bin/env bash
set -euo pipefail
###############################################
# Minimal RKE2 cluster using Multipass INSIDE WSL Ubuntu
# Provisioning done via multipass exec (no cloud-init user-data).
# - 1 server + N agents
# - Default RKE2 version: v1.31.3+rke2r1 (override via env)
###############################################

# --- Configurable parameters (override via env) ---
SERVERS=${SERVERS:-1}   # minimal script supports 1 server only
AGENTS=${AGENTS:-2}
INSTALL_RKE2_CHANNEL=${INSTALL_RKE2_CHANNEL:-stable}
INSTALL_RKE2_VERSION=${INSTALL_RKE2_VERSION:-v1.31.3+rke2r1}

# VM sizing
SERVER_CPUS=${SERVER_CPUS:-2}
SERVER_MEM=${SERVER_MEM:-4096} # MB
SERVER_DISK=${SERVER_DISK:-20G}
AGENT_CPUS=${AGENT_CPUS:-2}
AGENT_MEM=${AGENT_MEM:-4096}   # MB
AGENT_DISK=${AGENT_DISK:-20G}

# Output / kubeconfig paths
OUT_DIR=${OUT_DIR:-"./out"}
KUBECONFIG_LOCAL="${OUT_DIR}/rke2.yaml"

# If true, set the newly merged context as current in ~/.kube/config
SET_CURRENT_CONTEXT=${SET_CURRENT_CONTEXT:-false}

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
say()   { echo -e "\033[1;32m[+] $*\033[0m"; }
warn()  { echo -e "\033[1;33m[!] $*\033[0m"; }
die()   { echo -e "\033[1;31m[x] $*\033[0m"; exit 1; }

require_systemd_in_wsl() {
  if ! command -v systemctl >/dev/null 2>&1; then
    die "systemctl not available. Enable systemd in WSL, restart the distro, then retry."
  fi
  if ! systemctl is-system-running --quiet; then
    warn "systemd may not be fully running (is-system-running != running). If multipass fails, enable systemd and restart WSL."
  fi
}

install_kubectl_in_wsl() {
  if command -v kubectl >/dev/null 2>&1; then return; fi
  say "Installing kubectl in WSL..."
  sudo apt-get update -y
  sudo apt-get install -y apt-transport-https ca-certificates curl gnupg
  # Note: apt-key deprecated; acceptable for local setup
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
  echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list
  sudo apt-get update -y
  sudo apt-get install -y kubectl
}

get_ip() {
  local name="$1"
  ${MULTIPASS} info "${name}" | awk '/IPv4/{print $2; exit}'
}

# Wait for cloud-init inside the VM
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
    sudo apt-get update -y
    sudo apt-get install -y curl
    sudo mkdir -p /etc/rancher/rke2
    echo 'write-kubeconfig-mode: \"0644\"' | sudo tee /etc/rancher/rke2/config.yaml >/dev/null
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
    sudo apt-get update -y
    sudo apt-get install -y curl
    sudo mkdir -p /etc/rancher/rke2
    printf 'server: https://%s:9345\ntoken: %s\n' '${server_ip}' '${token}' | sudo tee /etc/rancher/rke2/config.yaml >/dev/null
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

# --- Fetch kubeconfig from the server VM ---
fetch_kubeconfig() {
  local master_ip="$1"
  say "Fetching kubeconfig from master..."
  ${MULTIPASS} exec rke2-master -- sudo cat /etc/rancher/rke2/rke2.yaml > "${KUBECONFIG_LOCAL}"
  sed -i "s#server: https://127.0.0.1:6443#server: https://${master_ip}:6443#g" "${KUBECONFIG_LOCAL}"
  sed -i "s#server: https://localhost:6443#server: https://${master_ip}:6443#g" "${KUBECONFIG_LOCAL}"
  say "Wrote kubeconfig -> ${KUBECONFIG_LOCAL}"
}

# --- Merge new cluster into ~/.kube/config (persistent cert/key paths) ---
merge_into_kubeconfig() {
  local master_ip="$1"
  local rke2_kc_abs
  rke2_kc_abs="$(realpath "${KUBECONFIG_LOCAL}")"

  mkdir -p "${HOME}/.kube"
  local home_kc="${HOME}/.kube/config"

  local ctx_name="rke2-${master_ip}"
  local user_name="${ctx_name}-admin"

  # Persistent file locations (under ~/.kube/)
  local ca_file="${HOME}/.kube/${ctx_name}-ca.crt"
  local client_cert_file="${HOME}/.kube/${user_name}.crt"
  local client_key_file="${HOME}/.kube/${user_name}.key"

  # Extract server & CA
  local server ca_data
  server="$(kubectl --kubeconfig="${rke2_kc_abs}" config view -o jsonpath='{.clusters[0].cluster.server}')"
  ca_data="$(kubectl --kubeconfig="${rke2_kc_abs}" config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"

  # Write CA and configure the cluster
  if [ -n "${ca_data}" ]; then
    echo "${ca_data}" | base64 -d > "${ca_file}"
    kubectl --kubeconfig="${home_kc}" config set-cluster "${ctx_name}" \
      --server="${server}" \
      --certificate-authority="${ca_file}"
    # If you prefer embedded CA, run a flatten later (see note at the end).
  else
    kubectl --kubeconfig="${home_kc}" config set-cluster "${ctx_name}" --server="${server}"
  fi

  # Credentials: prefer token, otherwise client cert/key
  local token ccd ckd
  token="$(kubectl --kubeconfig="${rke2_kc_abs}" config view --raw -o jsonpath='{.users[0].user.token}')"
  if [ -n "${token}" ]; then
    kubectl --kubeconfig="${home_kc}" config set-credentials "${user_name}" --token="${token}"
  else
    ccd="$(kubectl --kubeconfig="${rke2_kc_abs}" config view --raw -o jsonpath='{.users[0].user.client-certificate-data}')"
    ckd="$(kubectl --kubeconfig="${rke2_kc_abs}" config view --raw -o jsonpath='{.users[0].user.client-key-data}')"
    if [ -z "${ccd}" ] || [ -z "${ckd}" ]; then
      die "No token and no client certificate/key found in ${rke2_kc_abs}. Cannot merge credentials."
    fi
    echo "${ccd}" | base64 -d > "${client_cert_file}"
    echo "${ckd}" | base64 -d > "${client_key_file}"
    chmod 0600 "${client_key_file}"
    kubectl --kubeconfig="${home_kc}" config set-credentials "${user_name}" \
      --client-certificate="${client_cert_file}" \
      --client-key="${client_key_file}"
  fi

  # Create context
  kubectl --kubeconfig="${home_kc}" config set-context "${ctx_name}" \
    --cluster="${ctx_name}" \
    --user="${user_name}"

  # Switch current context only if requested or if none exists
  if [ "${SET_CURRENT_CONTEXT}" = "true" ]; then
    kubectl --kubeconfig="${home_kc}" config use-context "${ctx_name}" || true
  else
    if ! kubectl --kubeconfig="${home_kc}" config current-context >/dev/null 2>&1; then
      kubectl --kubeconfig="${home_kc}" config use-context "${ctx_name}" || true
    fi
  fi

  say "Merged new RKE2 cluster into ~/.kube/config as context: ${ctx_name}"
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

# Retrieve node token from server
TOKEN="$(${MULTIPASS} exec rke2-master -- sudo cat /var/lib/rancher/rke2/server/node-token)"

# Launch agents
for i in $(seq 1 "${AGENTS}"); do
  name="rke2-worker${i}"
  launch_agent_vm "${name}"
  provision_agent "${name}" "${MASTER_IP}" "${TOKEN}"
done

# Fetch kubeconfig and merge into ~/.kube/config
fetch_kubeconfig "${MASTER_IP}"
merge_into_kubeconfig "${MASTER_IP}"

say "Validating cluster..."
KUBECONFIG_ABS="$(realpath "${KUBECONFIG_LOCAL}")"
kubectl --kubeconfig="${KUBECONFIG_ABS}" get nodes -o wide

cat <<EOF
Next steps:
  # Use the new merged context (created as: rke2-${MASTER_IP})
  kubectl config get-contexts
  kubectl config use-context rke2-${MASTER_IP}
  kubectl get nodes -o wide
  kubectl -n kube-system get pods

  # Or continue using the standalone kubeconfig:
  export KUBECONFIG="$(realpath "${KUBECONFIG_LOCAL}")"
  kubectl get nodes -o wide
  kubectl -n kube-system get pods

Teardown:
  ${MULTIPASS} list
  ${MULTIPASS} delete rke2-master rke2-worker1 rke2-worker2
  ${MULTIPASS} purge
EOF

