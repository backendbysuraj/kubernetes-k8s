#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="k8s-master"
CLUSTER_ENDPOINT="https://192.168.1.139:6443"
CONTROL_PLANE_IPS=("192.168.1.139")
WORKER_IPS=("192.168.1.140")
TALOS_VERSION="v1.13.0"
GITHUB_USER="backendbysuraj"
GITHUB_REPO="kubernetes-k8s"
GITHUB_BRANCH="talos"
FLUX_PATH="clusters/k8s-master"
CONFIG_DIR="./talos-configs"

log()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
ok()   { echo -e "    \033[1;32m[OK] $*\033[0m"; }
die()  { echo -e "\033[1;31m[FAIL] $*\033[0m" >&2; exit 1; }

log "STEP 0 — Pre-flight checks"
for cmd in talosctl kubectl flux; do
  command -v "$cmd" &>/dev/null || die "Not installed: $cmd"
  ok "$cmd found"
done
[[ -z "${GITHUB_TOKEN:-}" ]] && die "GITHUB_TOKEN is not set! Run: export GITHUB_TOKEN=ghp_yourtoken"
ok "GITHUB_TOKEN is set"

log "STEP 1 — Generating Talos configs"
mkdir -p "$CONFIG_DIR"
talosctl gen config "$CLUSTER_NAME" "$CLUSTER_ENDPOINT" \
  --output-dir "$CONFIG_DIR" \
  --talos-version "$TALOS_VERSION" \
  --force
ok "Configs saved to $CONFIG_DIR/"

log "STEP 2 — Applying config to control plane (192.168.1.139)"
talosctl apply-config --insecure --nodes 192.168.1.139 --file "$CONFIG_DIR/controlplane.yaml"
ok "Control plane configured"

log "STEP 3 — Applying config to worker (192.168.1.140)"
talosctl apply-config --insecure --nodes 192.168.1.140 --file "$CONFIG_DIR/worker.yaml"
ok "Worker configured"

log "Waiting 90 seconds for nodes to reboot..."
for i in $(seq 90 -1 1); do printf "\r    %3d seconds..." "$i"; sleep 1; done; echo ""

log "STEP 4 — Bootstrapping etcd"
export TALOSCONFIG="$CONFIG_DIR/talosconfig"
talosctl config endpoint 192.168.1.139
talosctl config node 192.168.1.139

log "Waiting for Talos API..."
until talosctl version &>/dev/null 2>&1; do printf "."; sleep 5; done; echo ""
ok "Talos API is up"

talosctl bootstrap
ok "etcd bootstrapped"

log "Waiting 60 seconds for Kubernetes to start..."
for i in $(seq 60 -1 1); do printf "\r    %3d seconds..." "$i"; sleep 1; done; echo ""

log "STEP 5 — Exporting kubeconfig"
talosctl kubeconfig --nodes 192.168.1.139 --merge=false "$CONFIG_DIR/kubeconfig"
export KUBECONFIG="$CONFIG_DIR/kubeconfig"
ok "Kubeconfig saved"

log "Waiting for nodes to be Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s
ok "All nodes Ready"
kubectl get nodes -o wide

log "STEP 6 — Bootstrapping FluxCD"
flux bootstrap github \
  --owner="$GITHUB_USER" \
  --repository="$GITHUB_REPO" \
  --branch="$GITHUB_BRANCH" \
  --path="$FLUX_PATH" \
  --personal
ok "Flux is running and watching your GitHub repo"

echo ""
echo "=============================="
echo "  DONE! Bootstrap complete."
echo "=============================="
echo "  Run these to verify:"
echo "  export KUBECONFIG=./talos-configs/kubeconfig"
echo "  kubectl get nodes"
echo "  flux get all -A"
echo "  kubectl get pods -A"
echo "=============================="
