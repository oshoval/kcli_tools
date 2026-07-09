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

wait_for_hpp() {
  local timeout="${1:-600}"
  local start
  start="$(date +%s)"
  while true; do
    if oc get hostpathprovisioner hostpath-provisioner -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -qx 'True'; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      echo "timed out waiting for hostpath-provisioner to become Available" >&2
      exit 1
    fi
    sleep 5
  done
}

need oc
need grep

oc apply -f "${MANIFESTS_DIR}/01-hostpath-provisioner.yaml"
wait_for_hpp

echo
echo "Storage status:"
oc get storageclass
oc get hostpathprovisioner hostpath-provisioner -o yaml
