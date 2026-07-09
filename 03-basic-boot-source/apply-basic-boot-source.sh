#!/usr/bin/env bash

set -euo pipefail

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
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

need oc
need grep

wait_for_datasource openshift-virtualization-os-images rhel10

echo
echo "Boot source status:"
oc get datasource rhel10 -n openshift-virtualization-os-images -o yaml
oc get dataimportcron rhel10-image-cron -n openshift-virtualization-os-images -o yaml
