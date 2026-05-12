#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRIB_DIR="${ROOT_DIR}/submodules/resource-types-contrib"
DEMO_APP="${ROOT_DIR}/demo/app.bicep"
ENVIRONMENT="${ENVIRONMENT:-default}"
WORKSPACE="${WORKSPACE:-default}"
APP_NAME="${APP_NAME:-nginx-radius-demo}"
APP_NAMESPACE="${APP_NAMESPACE:-default-nginx-radius-demo}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command '$1' was not found." >&2
    exit 1
  fi
}

for cmd in docker kind kubectl helm rad curl jq oras; do
  require_command "$cmd"
done

cd "${CONTRIB_DIR}"

make create-radius-cluster
"${ROOT_DIR}/scripts/install-nginx-gateway-fabric.sh"

make build-resource-type TYPE_FOLDER=Compute/gateways
make build-resource-type TYPE_FOLDER=Compute/containers
make build-resource-type TYPE_FOLDER=Compute/routes

make build-bicep-recipe RECIPE_PATH=Compute/gateways/recipes/kubernetes/bicep/nginx-gateway.bicep
make build-bicep-recipe RECIPE_PATH=Compute/containers/recipes/kubernetes/bicep/kubernetes-containers.bicep
make build-bicep-recipe RECIPE_PATH=Compute/routes/recipes/kubernetes/bicep/kubernetes-routes.bicep

./.github/scripts/register-recipe.sh Compute/gateways/recipes/kubernetes/bicep "${ENVIRONMENT}" "${WORKSPACE}"
./.github/scripts/register-recipe.sh Compute/containers/recipes/kubernetes/bicep "${ENVIRONMENT}" "${WORKSPACE}"

rad recipe register default \
  --workspace "${WORKSPACE}" \
  --environment "${ENVIRONMENT}" \
  --resource-type Radius.Compute/routes \
  --template-kind bicep \
  --template-path reciperegistry:5000/radius-recipes/compute/routes/kubernetes/bicep/kubernetes-routes:latest \
  --parameters gatewayName=web \
  --parameters gatewayNamespace="${APP_NAMESPACE}" \
  --plain-http

rad deploy "${DEMO_APP}" --application "${APP_NAME}" -e "${ENVIRONMENT}"

kubectl wait --timeout=5m -n "${APP_NAMESPACE}" gateway/web --for=condition=Programmed
kubectl wait --timeout=5m -n "${APP_NAMESPACE}" httproute --all --for=condition=Accepted

SERVICE_NAME="$(kubectl get service -n "${APP_NAMESPACE}" -l gateway.networking.k8s.io/gateway-name=web -o jsonpath='{.items[0].metadata.name}')"
kubectl port-forward -n "${APP_NAMESPACE}" "service/${SERVICE_NAME}" 8080:80 >/tmp/radius-nginx-demo-port-forward.log 2>&1 &
PF_PID=$!
trap 'kill ${PF_PID} >/dev/null 2>&1 || true' EXIT

for _ in {1..30}; do
  if curl -fsS http://127.0.0.1:8080/ >/tmp/radius-nginx-demo-response.html; then
    grep -qi "welcome to nginx" /tmp/radius-nginx-demo-response.html
    echo "E2E succeeded: Radius app responded through NGINX Gateway Fabric."
    exit 0
  fi
  sleep 2
done

echo "E2E failed: application did not respond through NGINX Gateway Fabric." >&2
kubectl get gateway,httproute,pods,svc -n "${APP_NAMESPACE}" >&2 || true
exit 1
