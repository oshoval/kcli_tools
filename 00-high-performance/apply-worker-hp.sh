#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${ROOT_DIR}/manifests"
HP_NODE="${HP_NODE:-}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

need oc
need python3

if [[ -z "${HP_NODE}" ]]; then
  HP_NODE="$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[0].metadata.name}')"
fi

if [[ -z "${HP_NODE}" ]]; then
  echo "could not determine HP_NODE automatically" >&2
  echo "Run with: HP_NODE=<worker-node-name> ${BASH_SOURCE[0]}" >&2
  exit 1
fi

CPU_COUNT="$(oc get node "${HP_NODE}" -o jsonpath='{.status.capacity.cpu}')"
if [[ "${CPU_COUNT}" =~ ^[0-9]+$ ]] && (( CPU_COUNT < 20 )); then
  echo "node ${HP_NODE} only has ${CPU_COUNT} CPUs; bundled profile expects at least 20" >&2
  exit 1
fi

INTERNAL_IP="$(oc get node "${HP_NODE}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
HOST_CIDRS="$(oc get node "${HP_NODE}" -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/host-cidrs}')"

if [[ -z "${INTERNAL_IP}" || -z "${HOST_CIDRS}" ]]; then
  echo "could not determine InternalIP/host-cidrs for ${HP_NODE}" >&2
  exit 1
fi

NODEIP_HINT="$(
  INTERNAL_IP="${INTERNAL_IP}" HOST_CIDRS="${HOST_CIDRS}" python3 - <<'PY'
import ipaddress
import json
import os
import sys

internal = ipaddress.ip_address(os.environ["INTERNAL_IP"])
cidrs = json.loads(os.environ["HOST_CIDRS"])

for cidr in cidrs:
    network = ipaddress.ip_network(cidr, strict=False)
    if internal.version == 4 and internal in network:
        hint = next(network.hosts(), None)
        if hint is None or hint == internal:
            print(f"could not derive NODEIP_HINT from {cidr}", file=sys.stderr)
            sys.exit(1)
        print(hint)
        sys.exit(0)

print(f"could not find an IPv4 host CIDR containing {internal}", file=sys.stderr)
sys.exit(1)
PY
)"

echo "Targeting worker: ${HP_NODE}"
echo "Using node IP hint: ${NODEIP_HINT}"

oc debug node/"${HP_NODE}" -- chroot /host bash -lc "printf 'NODEIP_HINT=%s\n' '${NODEIP_HINT}' > /etc/default/nodeip-configuration && cat /etc/default/nodeip-configuration"

oc label node "${HP_NODE}" node-role.kubernetes.io/worker-hp="" --overwrite

oc apply -f "${MANIFESTS_DIR}/01-worker-hp-mcp.yaml"
oc apply -f "${MANIFESTS_DIR}/02-worker-hp-performanceprofile.yaml"

echo "Waiting for worker-hp MCP to finish updating..."
oc wait mcp/worker-hp --for=condition=Updated=True --timeout=90m
oc wait mcp/worker-hp --for=condition=Degraded=False --timeout=90m
oc wait node/"${HP_NODE}" --for=condition=Ready --timeout=30m
oc wait node/"${HP_NODE}" --for=jsonpath='{.metadata.labels.kubevirt\.io/cpumanager}'=true --timeout=30m

echo
echo "Node labels:"
oc get node "${HP_NODE}" -o jsonpath='{.metadata.labels.kubevirt\.io/cpumanager}{" "}{.metadata.labels.cpumanager}{" "}{.status.capacity.hugepages-2Mi}{"\n"}'

echo
echo "cpu_manager_state:"
oc debug node/"${HP_NODE}" -- chroot /host cat /var/lib/kubelet/cpu_manager_state
