#!/usr/bin/env bash

set -euo pipefail

DATASOURCE_NAMESPACE="${DATASOURCE_NAMESPACE:-openshift-virtualization-os-images}"
DATASOURCE_NAME="${DATASOURCE_NAME:-rhel10}"
NFS_NAMESPACE="${NFS_NAMESPACE:-nfs-storage}"
NFS_DEPLOYMENT="${NFS_DEPLOYMENT:-nfs-server}"
EXPORT_PATH="${EXPORT_PATH:-/var/nfs-csi-export}"
PIN_LABEL_KEY="${PIN_LABEL_KEY:-virt-cluster-validate.nfs-source}"
PIN_LABEL_VALUE="${PIN_LABEL_VALUE:-primary}"
TARGET_NODE="${TARGET_NODE:-}"
WAIT_TIMEOUT_SECS="${WAIT_TIMEOUT_SECS:-180}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

get_source_pvc() {
  oc get datasource "${DATASOURCE_NAME}" -n "${DATASOURCE_NAMESPACE}" -o json | jq -r '
    .status.source.pvc.name // .spec.source.pvc.name // empty
  '
}

get_source_subdir() {
  local pvc_name="$1"
  local volume_name

  volume_name="$(oc get pvc "${pvc_name}" -n "${DATASOURCE_NAMESPACE}" -o jsonpath='{.spec.volumeName}')"
  oc get pv "${volume_name}" -o json | jq -r '
    .spec.csi.volumeAttributes.subdir // empty
  '
}

get_running_nfs_pod() {
  oc get pod -n "${NFS_NAMESPACE}" -l app=nfs-server -o json | jq -r '
    first(.items[] | select(.status.phase == "Running") | .metadata.name) // empty
  '
}

get_running_nfs_node() {
  local pod="$1"
  oc get pod "${pod}" -n "${NFS_NAMESPACE}" -o jsonpath='{.spec.nodeName}'
}

get_mcd_pod() {
  local node="$1"

  oc get pod -n openshift-machine-config-operator -o json | jq -r --arg node "${node}" '
    first(
      .items[]
      | select(.metadata.name | startswith("machine-config-daemon-"))
      | select(.spec.nodeName == $node and .status.phase == "Running")
      | .metadata.name
    ) // empty
  '
}

host_exec() {
  local node="$1"
  local command="$2"
  local pod

  pod="$(get_mcd_pod "${node}")"
  if [[ -z "${pod}" ]]; then
    echo "could not find a running machine-config-daemon pod on ${node}" >&2
    return 1
  fi

  oc exec -n openshift-machine-config-operator "${pod}" -c machine-config-daemon -- \
    chroot /rootfs sh -c "${command}"
}

list_worker_nodes() {
  oc get nodes -l node-role.kubernetes.io/worker -o json | jq -r '.items[].metadata.name'
}

find_nodes_with_subdir() {
  local subdir="$1"
  local node

  for node in $(list_worker_nodes); do
    if host_exec "${node}" "test -d \"${EXPORT_PATH}/${subdir}\"" >/dev/null 2>&1; then
      echo "${node}"
    fi
  done
}

pin_deployment_to_node() {
  local node="$1"

  oc label node "${node}" "${PIN_LABEL_KEY}=${PIN_LABEL_VALUE}" --overwrite
  oc patch deployment "${NFS_DEPLOYMENT}" -n "${NFS_NAMESPACE}" --type=merge -p "{
    \"spec\": {
      \"template\": {
        \"spec\": {
          \"nodeSelector\": {
            \"kubernetes.io/os\": \"linux\",
            \"node-role.kubernetes.io/worker\": \"\",
            \"${PIN_LABEL_KEY}\": \"${PIN_LABEL_VALUE}\"
          }
        }
      }
    }
  }"
}

verify_export_on_pod() {
  local pod="$1"
  local subdir="$2"

  oc exec -n "${NFS_NAMESPACE}" "${pod}" -- sh -c "test -d \"/exports/${subdir}\""
}

need oc
need jq

SOURCE_PVC="$(get_source_pvc)"
if [[ -z "${SOURCE_PVC}" ]]; then
  echo "could not resolve source PVC for ${DATASOURCE_NAMESPACE}/${DATASOURCE_NAME}" >&2
  exit 1
fi

SOURCE_SUBDIR="$(get_source_subdir "${SOURCE_PVC}")"
if [[ -z "${SOURCE_SUBDIR}" ]]; then
  echo "could not resolve source export subdir for PVC ${SOURCE_PVC}" >&2
  exit 1
fi

NFS_POD="$(get_running_nfs_pod)"
if [[ -z "${NFS_POD}" ]]; then
  echo "could not find a running NFS server pod in ${NFS_NAMESPACE}" >&2
  exit 1
fi

CURRENT_NODE="$(get_running_nfs_node "${NFS_POD}")"

echo "DataSource: ${DATASOURCE_NAMESPACE}/${DATASOURCE_NAME}"
echo "Source PVC: ${SOURCE_PVC}"
echo "Source subdir: ${SOURCE_SUBDIR}"
echo "Current NFS pod: ${NFS_POD}"
echo "Current NFS node: ${CURRENT_NODE}"

if verify_export_on_pod "${NFS_POD}" "${SOURCE_SUBDIR}"; then
  echo
  echo "The active NFS export already contains ${SOURCE_SUBDIR}. Nothing to fix."
  exit 0
fi

if [[ -n "${TARGET_NODE}" ]]; then
  mapfile -t MATCHING_NODES < <(printf '%s\n' "${TARGET_NODE}")
else
  mapfile -t MATCHING_NODES < <(find_nodes_with_subdir "${SOURCE_SUBDIR}")
fi

if (( ${#MATCHING_NODES[@]} == 0 )); then
  echo "did not find ${SOURCE_SUBDIR} on any worker node" >&2
  exit 1
fi

if (( ${#MATCHING_NODES[@]} > 1 )); then
  echo "found ${SOURCE_SUBDIR} on multiple nodes:" >&2
  printf '  %s\n' "${MATCHING_NODES[@]}" >&2
  echo "re-run with TARGET_NODE=<node> to choose one explicitly" >&2
  exit 1
fi

FIX_NODE="${MATCHING_NODES[0]}"

echo
echo "Pinning ${NFS_DEPLOYMENT} to ${FIX_NODE} so the export serves ${SOURCE_SUBDIR}..."
pin_deployment_to_node "${FIX_NODE}"
oc rollout status "deployment/${NFS_DEPLOYMENT}" -n "${NFS_NAMESPACE}" --timeout="${WAIT_TIMEOUT_SECS}s"

NEW_POD="$(get_running_nfs_pod)"
NEW_NODE="$(get_running_nfs_node "${NEW_POD}")"

echo
echo "New NFS pod: ${NEW_POD}"
echo "New NFS node: ${NEW_NODE}"

if [[ "${NEW_NODE}" != "${FIX_NODE}" ]]; then
  echo "NFS pod did not move to ${FIX_NODE}" >&2
  exit 1
fi

verify_export_on_pod "${NEW_POD}" "${SOURCE_SUBDIR}" || {
  echo "NFS pod moved, but ${SOURCE_SUBDIR} is still missing from /exports" >&2
  exit 1
}

echo "Verified ${SOURCE_SUBDIR} is now present in the active NFS export."
