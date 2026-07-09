#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${ROOT_DIR}/manifests"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

wait_for_available_deployment() {
  local namespace="$1"
  local name="$2"
  local timeout="${3:-600}"
  oc wait -n "${namespace}" --for=condition=Available "deployment/${name}" --timeout="${timeout}s"
}

wait_for_object() {
  local namespace="$1"
  local kind="$2"
  local name="$3"
  local timeout="${4:-600}"
  local start
  start="$(date +%s)"
  while true; do
    if oc get -n "${namespace}" "${kind}/${name}" >/dev/null 2>&1; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      echo "timed out waiting for ${kind}/${name} in ${namespace}" >&2
      exit 1
    fi
    sleep 5
  done
}

wait_for_storageprofile() {
  local name="$1"
  local timeout="${2:-600}"
  local start
  start="$(date +%s)"
  while true; do
    if oc get storageprofile "${name}" >/dev/null 2>&1; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      echo "timed out waiting for storageprofile/${name}" >&2
      exit 1
    fi
    sleep 5
  done
}

wait_for_snapshotclass() {
  local name="$1"
  local timeout="${2:-600}"
  local start
  start="$(date +%s)"
  while true; do
    if oc get volumesnapshotclass "${name}" >/dev/null 2>&1; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      echo "timed out waiting for volumesnapshotclass/${name}" >&2
      exit 1
    fi
    sleep 5
  done
}

wait_for_datasource() {
  local namespace="$1"
  local name="$2"
  local timeout="${3:-3600}"
  local start
  start="$(date +%s)"
  while true; do
    if oc get datasource "${name}" -n "${namespace}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -qx 'True'; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      echo "timed out waiting for datasource/${name} in ${namespace}" >&2
      exit 1
    fi
    sleep 10
  done
}

wait_for_clone_strategy() {
  local name="$1"
  local expected="$2"
  local timeout="${3:-600}"
  local start
  start="$(date +%s)"
  while true; do
    if [[ "$(oc get storageprofile "${name}" -o jsonpath='{.status.cloneStrategy}' 2>/dev/null)" == "${expected}" ]]; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      echo "timed out waiting for storageprofile/${name} cloneStrategy=${expected}" >&2
      exit 1
    fi
    sleep 5
  done
}

wait_for_rwx_access_mode() {
  local name="$1"
  local timeout="${2:-600}"
  local start
  start="$(date +%s)"
  while true; do
    if oc get storageprofile "${name}" -o jsonpath='{.status.claimPropertySets[*].accessModes[*]}' 2>/dev/null | grep -qw ReadWriteMany; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      echo "timed out waiting for storageprofile/${name} to advertise ReadWriteMany" >&2
      exit 1
    fi
    sleep 5
  done
}

clear_forced_clone_strategy() {
  if [[ "$(oc get storageprofile nfs-csi -o jsonpath='{.spec.cloneStrategy}' 2>/dev/null)" == "copy" ]]; then
    oc patch storageprofile nfs-csi --type=json -p='[{"op":"remove","path":"/spec/cloneStrategy"}]'
  fi
}

patch_csi_controller_liveness_port() {
  local patch
  patch="$(
    oc get deployment csi-nfs-controller -n csi-driver-nfs -o json | python3 -c '
import json
import sys

deployment = json.load(sys.stdin)
containers = deployment["spec"]["template"]["spec"]["containers"]
ops = []

for container_index, container in enumerate(containers):
    for arg_index, arg in enumerate(container.get("args", [])):
        if arg == "--http-endpoint=localhost:29652":
            ops.append(
                {
                    "op": "replace",
                    "path": f"/spec/template/spec/containers/{container_index}/args/{arg_index}",
                    "value": "--http-endpoint=localhost:29654",
                }
            )
    port = container.get("livenessProbe", {}).get("httpGet", {}).get("port")
    if str(port) == "29652":
        ops.append(
            {
                "op": "replace",
                "path": f"/spec/template/spec/containers/{container_index}/livenessProbe/httpGet/port",
                "value": 29654,
            }
        )

print(json.dumps(ops))
'
  )"

  if [[ "${patch}" != "[]" ]]; then
    oc patch deployment csi-nfs-controller -n csi-driver-nfs --type=json -p "${patch}"
  fi
}

need oc
need helm
need python3
need grep

oc apply -f "${MANIFESTS_DIR}/01-nfs-server.yaml"
oc adm policy add-scc-to-user privileged -z nfs-server -n nfs-storage
wait_for_available_deployment nfs-storage nfs-server

helm repo add csi-driver-nfs https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install csi-driver-nfs csi-driver-nfs/csi-driver-nfs \
  --version 4.13.4 \
  --namespace csi-driver-nfs \
  --create-namespace \
  --set controller.runOnControlPlane=true \
  --set controller.replicas=1 \
  --set controller.strategyType=Recreate \
  --set controller.enableSnapshotCompression=false \
  --set externalSnapshotter.enabled=true \
  --set externalSnapshotter.customResourceDefinitions.enabled=false

oc adm policy add-scc-to-user privileged -z csi-nfs-node-sa -n csi-driver-nfs
oc adm policy add-scc-to-user privileged -z csi-nfs-controller-sa -n csi-driver-nfs

wait_for_object csi-driver-nfs deployment csi-nfs-controller
patch_csi_controller_liveness_port
wait_for_available_deployment csi-driver-nfs csi-nfs-controller
oc wait -n csi-driver-nfs --for=condition=Ready pod --all --timeout=600s

oc annotate storageclass hostpath-csi storageclass.kubernetes.io/is-default-class- --overwrite || true
oc apply -f "${MANIFESTS_DIR}/02-nfs-storageclass.yaml"
oc apply -f "${MANIFESTS_DIR}/03-nfs-snapshotclass.yaml"
wait_for_snapshotclass csi-nfs-snapclass
wait_for_storageprofile nfs-csi
wait_for_rwx_access_mode nfs-csi
clear_forced_clone_strategy
wait_for_clone_strategy nfs-csi snapshot
wait_for_datasource openshift-virtualization-os-images rhel10

echo
echo "Shared storage status:"
oc get storageclass,volumesnapshotclass
oc get storageprofile nfs-csi -o yaml
