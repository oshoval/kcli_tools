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

wait_for_csv() {
  local namespace="$1"
  local timeout="${2:-900}"
  local start
  start="$(date +%s)"
  while true; do
    if oc get csv -n "${namespace}" -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -qx 'Succeeded'; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      echo "timed out waiting for a Succeeded CSV in ${namespace}" >&2
      exit 1
    fi
    sleep 5
  done
}

wait_for_crd() {
  local name="$1"
  local timeout="${2:-600}"
  local start
  start="$(date +%s)"
  while true; do
    if oc get crd "${name}" >/dev/null 2>&1; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      echo "timed out waiting for crd/${name}" >&2
      exit 1
    fi
    sleep 5
  done
}

need oc
need grep

oc apply -f "${MANIFESTS_DIR}/01-nmstate-operator.yaml"
wait_for_csv openshift-nmstate
oc apply -f "${MANIFESTS_DIR}/02-nmstate-cr.yaml"
wait_for_crd nodenetworkconfigurationpolicies.nmstate.io

echo
echo "NMState status:"
oc get csv -n openshift-nmstate
oc get nmstate nmstate -o yaml
oc get crd nodenetworkconfigurationpolicies.nmstate.io
