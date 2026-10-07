#!/usr/bin/env bash
# Composition tests for Cache with `crossplane composition render`, against the
# compose-cache image `crossplane project build` produced (no cluster needed).
#   1. costCenter matches no CostCenter -> nothing composed, Ready=False, warning.
#   2. costCenter matches -> ConfigMap + Deployment + Service, status.endpoint set.
#
# Render's project mode would rebuild every embedded function and gives each
# Python build 60 s, which isn't enough here; so build once (when the function
# changed), load the images into Docker, and render with an explicit functions file.
set -euo pipefail
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/../.." && pwd )"
T="${DIR}/tests/composition"
XPKG="${DIR}/_output/devopsdays.xpkg"

if [[ ! -f "${XPKG}" || -n "$(find "${DIR}/functions/compose-cache" "${DIR}/crossplane-project.yaml" \
      -type f ! -path '*/__pycache__/*' -newer "${XPKG}" | head -1)" ]]; then
  echo "  (building the project: crossplane project build)"
  (cd "${DIR}" && crossplane project build >/dev/null)
fi
docker load -q -i "${XPKG}" >/dev/null

render() {
  # Run outside the project directory, so render uses the functions file.
  (cd "${T}" && crossplane composition render "$1" "${DIR}/apis/cache/composition.yaml" functions.yaml \
    --required-resources costcenters.yaml -r)
}
fail=0
check() { if eval "$2"; then echo "  ✔ $1"; else echo "  ✘ $1"; fail=1; fi; }

out=$(render "${T}/xr-stuck.yaml")
kinds=$(echo "${out}" | yq -N 'select(.kind != "Result") | .kind' | sort | tr '\n' ' ')
check "stuck: only the XR is rendered (${kinds})" '[[ "${kinds}" == "Cache " ]]'
check "stuck: Ready=False" '[[ "$(echo "${out}" | yq -N "select(.kind==\"Cache\") | .status.conditions[] | select(.type==\"Ready\") | .status")" == "False" ]]'
check "stuck: condition says why" 'echo "${out}" | grep -q "No CostCenter matches CC-4171"'
check "stuck: warning result" 'echo "${out}" | yq -N "select(.kind==\"Result\") | .severity" | grep -q Warning'
check "stuck: status lists known cost centers" '[[ "$(echo "${out}" | yq -N "select(.kind==\"Cache\") | .status.costCenter.known | length")" == "3" ]]'

out=$(render "${T}/xr-ok.yaml")
kinds=$(echo "${out}" | yq -N 'select(.kind != "Result" and .kind != "Cache") | .kind' | sort | tr '\n' ' ')
check "match: ConfigMap, Deployment, Service (${kinds})" '[[ "${kinds}" == "ConfigMap Deployment Service " ]]'
check "match: CostCenterResolved=True" '[[ "$(echo "${out}" | yq -N "select(.kind==\"Cache\") | .status.conditions[] | select(.type==\"CostCenterResolved\") | .status")" == "True" ]]'
check "match: endpoint in status" '[[ "$(echo "${out}" | yq -N "select(.kind==\"Cache\") | .status.endpoint")" == "demo-ok-valkey.default.svc:6379" ]]'
check "match: preloaded image, IfNotPresent" '[[ "$(echo "${out}" | yq -N "select(.kind==\"Deployment\") | .spec.template.spec.containers[0].imagePullPolicy")" == "IfNotPresent" ]]'
exit "${fail}"
