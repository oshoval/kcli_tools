#!/usr/bin/env bash

set -euo pipefail

TARGET_NODE="${TARGET_NODE:-}"
EXPORT_PATH="${EXPORT_PATH:-/var/nfs-csi-export}"
SNAPSHOT_NAMESPACE="${SNAPSHOT_NAMESPACE:-openshift-virtualization-os-images}"
STALE_SNAPSHOT_MINUTES="${STALE_SNAPSHOT_MINUTES:-120}"
RESTART_KUBELET="${RESTART_KUBELET:-true}"
WAIT_TIMEOUT_SECS="${WAIT_TIMEOUT_SECS:-180}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

get_target_nodes() {
  if [[ -n "${TARGET_NODE}" ]]; then
    tr ',' '\n' <<<"${TARGET_NODE}" | sed '/^$/d'
    return 0
  fi

  oc get nodes -o json | jq -r '
    .items[]
    | select(any(.status.conditions[]; .type == "DiskPressure" and .status == "True"))
    | .metadata.name
  '
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

print_node_conditions() {
  local node="$1"

  oc get node "${node}" -o jsonpath='{range .status.conditions[*]}{.type}={.status}:{.reason}{"\n"}{end}'
}

print_host_usage() {
  local node="$1"

  host_exec "${node}" "df -h /var \"${EXPORT_PATH}\""
  echo "---"
  host_exec "${node}" "du -sh ${EXPORT_PATH}/snapshot-* 2>/dev/null | sort -h || true"
}

collect_stale_snapshots() {
  oc get volumesnapshot -n "${SNAPSHOT_NAMESPACE}" -o json | jq -r --argjson cutoff "${STALE_SNAPSHOT_MINUTES}" '
    .items[]?
    | select(.metadata.name | startswith("tmp-snapshot-"))
    | select((.status.readyToUse // false) != true)
    | select((now - (.metadata.creationTimestamp | fromdateiso8601)) > ($cutoff * 60))
    | .metadata.name
  '
}

collect_live_snapshot_dirs() {
  oc get volumesnapshotcontent -o json | jq -r '
    .items[]?.metadata.name
    | sub("^snapcontent-"; "snapshot-")
  ' | sort -u
}

collect_host_snapshot_dirs() {
  local node="$1"

  host_exec "${node}" "find \"${EXPORT_PATH}\" -mindepth 1 -maxdepth 1 -type d -name 'snapshot-*' -printf '%f\n' | sort"
}

wait_for_node_ready() {
  local node="$1"
  oc wait --for=condition=Ready "node/${node}" --timeout="${WAIT_TIMEOUT_SECS}s" >/dev/null
}

wait_for_disk_pressure_clear() {
  local node="$1"
  local deadline status

  deadline=$((SECONDS + WAIT_TIMEOUT_SECS))
  while (( SECONDS < deadline )); do
    status="$(oc get node "${node}" -o json | jq -r 'first(.status.conditions[] | select(.type == "DiskPressure") | .status) // "Unknown"')"
    if [[ "${status}" == "False" ]]; then
      return 0
    fi
    sleep 5
  done

  return 1
}

process_node() {
  local node="$1"
  local host_snapshot_output
  local -a host_snapshot_dirs orphan_dirs
  local -A live_snapshot_dirs=()
  local orphan_list

  echo "Target node: ${node}"
  echo
  echo "Initial node conditions:"
  print_node_conditions "${node}" || return 1
  echo
  echo "Initial host usage:"
  print_host_usage "${node}" || return 1

  while IFS= read -r dir; do
    [[ -n "${dir}" ]] || continue
    live_snapshot_dirs["${dir}"]=1
  done < <(collect_live_snapshot_dirs)

  host_snapshot_output="$(collect_host_snapshot_dirs "${node}")" || return 1
  mapfile -t host_snapshot_dirs <<<"${host_snapshot_output}"
  orphan_dirs=()
  for dir in "${host_snapshot_dirs[@]}"; do
    [[ -n "${dir}" ]] || continue
    if [[ -z "${live_snapshot_dirs[${dir}]+x}" ]]; then
      orphan_dirs+=("${dir}")
    fi
  done

  if (( ${#orphan_dirs[@]} > 0 )); then
    echo
    echo "Removing orphaned snapshot directories from ${EXPORT_PATH}:"
    printf '  %s\n' "${orphan_dirs[@]}"
    orphan_list="${orphan_dirs[*]}"
    host_exec "${node}" "for d in ${orphan_list}; do du -sh \"${EXPORT_PATH}/\$d\"; done | sort -h" || return 1
    host_exec "${node}" "for d in ${orphan_list}; do rm -rf \"${EXPORT_PATH}/\$d\"; done" || return 1
  else
    echo
    echo "No orphaned snapshot directories found under ${EXPORT_PATH}."
  fi

  echo
  echo "Host usage after cleanup:"
  print_host_usage "${node}" || return 1

  if [[ "${RESTART_KUBELET}" == "true" ]]; then
    echo
    echo "Restarting kubelet on ${node}..."
    host_exec "${node}" "systemctl restart kubelet" || return 1
    wait_for_node_ready "${node}" || return 1

    if wait_for_disk_pressure_clear "${node}"; then
      echo "DiskPressure cleared on ${node}."
    else
      echo "DiskPressure is still present on ${node} after ${WAIT_TIMEOUT_SECS}s." >&2
      print_node_conditions "${node}" >&2
      return 1
    fi
  fi

  echo
  echo "Final node conditions:"
  print_node_conditions "${node}" || return 1
}

need oc
need jq
need sed

mapfile -t STALE_SNAPSHOTS < <(collect_stale_snapshots)
if (( ${#STALE_SNAPSHOTS[@]} > 0 )); then
  echo
  echo "Deleting stale VolumeSnapshots older than ${STALE_SNAPSHOT_MINUTES} minute(s):"
  printf '  %s\n' "${STALE_SNAPSHOTS[@]}"
  oc delete volumesnapshot -n "${SNAPSHOT_NAMESPACE}" "${STALE_SNAPSHOTS[@]}" --ignore-not-found=true
else
  echo
  echo "No stale VolumeSnapshots matched the cleanup criteria."
fi

mapfile -t NODES < <(get_target_nodes)
if (( ${#NODES[@]} == 0 )); then
  echo
  echo "No nodes currently report DiskPressure. Nothing to do."
  exit 0
fi

FAILED_NODES=()
for NODE in "${NODES[@]}"; do
  echo
  echo "==================== ${NODE} ===================="
  if ! process_node "${NODE}"; then
    FAILED_NODES+=("${NODE}")
  fi
done

if (( ${#FAILED_NODES[@]} > 0 )); then
  echo
  echo "Recovery failed on:"
  printf '  %s\n' "${FAILED_NODES[@]}"
  exit 1
fi
