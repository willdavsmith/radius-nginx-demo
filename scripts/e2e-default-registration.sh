#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RADIUS_DIR="${ROOT_DIR}/submodules/radius"
ENVIRONMENT="${ENVIRONMENT:-default-registration-demo}"
APP_NAMESPACE="${APP_NAMESPACE:-default-registration-demo}"
ORIGINAL_HOME="${HOME}"
E2E_HOME="${E2E_HOME:-$(mktemp -d)}"
export HOME="${E2E_HOME}"
export DOTNET_BUNDLE_EXTRACT_BASE_DIR="${DOTNET_BUNDLE_EXTRACT_BASE_DIR:-/tmp/dotnet-bundle-extract}"
mkdir -p "${HOME}"
if [[ -d "${ORIGINAL_HOME}/.rad/bin" && ! -e "${HOME}/.rad/bin" ]]; then
  mkdir -p "${HOME}/.rad"
  ln -s "${ORIGINAL_HOME}/.rad/bin" "${HOME}/.rad/bin"
fi

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command '$1' was not found." >&2
    exit 1
  fi
}

for cmd in docker kind kubectl helm rad jq; do
  require_command "$cmd"
done

cd "${ROOT_DIR}"

kind create cluster --name radius

rad install kubernetes \
  --chart "${RADIUS_DIR}/deploy/Chart" \
  --set rp.publicEndpointOverride=localhost:8081 \
  --set dashboard.enabled=false

"${ROOT_DIR}/submodules/resource-types-contrib/.github/scripts/verify-ucp-readiness.sh"
kubectl get namespace "${APP_NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${APP_NAMESPACE}"

rad group create default
rad workspace create kubernetes default --group default --force
rad group switch default
rad env create "${ENVIRONMENT}" --preview
rad env update "${ENVIRONMENT}" --kubernetes-namespace "${APP_NAMESPACE}" --preview

rad resource-type show 'Radius.Compute/containers' -o json >/tmp/radius-containers-resource-type.json
rad resource-type show 'Radius.Compute/routes' -o json >/tmp/radius-routes-resource-type.json

rad recipe-pack show default --group default -o json >/tmp/radius-default-recipe-pack.json
jq -e '
  .properties.recipes["Radius.Compute/containers"].recipeKind == "bicep" and
  (.properties.recipes["Radius.Compute/containers"].recipeLocation | contains("ghcr.io/radius-project/kube-recipes/containers:")) and
  .properties.recipes["Radius.Compute/routes"].recipeKind == "bicep" and
  (.properties.recipes["Radius.Compute/routes"].recipeLocation | contains("ghcr.io/radius-project/kube-recipes/routes:")) and
  .properties.recipes["Radius.Compute/routes"].parameters.gatewayName == "radius" and
  .properties.recipes["Radius.Compute/routes"].parameters.gatewayNamespace == "radius-system"
' /tmp/radius-default-recipe-pack.json >/dev/null

rad env show "${ENVIRONMENT}" --preview -o json >/tmp/radius-default-registration-env.json
jq -s -e '
  any(.[0].properties.recipePacks[]; . == "/planes/radius/local/resourceGroups/default/providers/Radius.Core/recipePacks/default")
' /tmp/radius-default-registration-env.json >/dev/null

kubectl get gatewayclass contour >/dev/null
kubectl get gateway radius -n radius-system >/dev/null

echo "E2E succeeded: routes resource type and default route recipe are registered by default."
