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

wait_for_storageprofile_gone() {
  local name="$1"
  local timeout="${2:-300}"
  local start
  start="$(date +%s)"
  while true; do
    if ! oc get storageprofile "${name}" >/dev/null 2>&1; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      echo "timed out waiting for storageprofile/${name} to disappear" >&2
      exit 1
    fi
    sleep 5
  done
}

need oc
need rg

if oc get pvc -A -o custom-columns='STORAGECLASS:.spec.storageClassName' --no-headers | rg -qx 'hostpath-csi'; then
  echo "hostpath-csi still has PVC users; refusing to delete the storage class" >&2
  exit 1
fi

oc delete -f "${MANIFESTS_DIR}/01-hostpath-storageclass.yaml" --ignore-not-found
wait_for_storageprofile_gone hostpath-csi

echo
echo "Storage warning status:"
oc get storageclass,storageprofile
