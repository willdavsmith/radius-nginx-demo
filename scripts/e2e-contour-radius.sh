#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRIB_DIR="${ROOT_DIR}/submodules/resource-types-contrib"
DEMO_APP="${ROOT_DIR}/demo/app.bicep"
ENVIRONMENT="${ENVIRONMENT:-default}"
APP_NAME="${APP_NAME:-contour-radius-demo}"
APP_NAMESPACE="${APP_NAMESPACE:-default-contour-radius-demo}"
ROUTE_HOSTNAME="${ROUTE_HOSTNAME:-contour.example.com}"
CONTOUR_NAMESPACE="${CONTOUR_NAMESPACE:-projectcontour}"
GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-radius-system}"
GATEWAY_NAME="${GATEWAY_NAME:-radius}"
RECIPE_PACK_NAME="${RECIPE_PACK_NAME:-contour-radius-demo-pack}"
RECIPE_PACK_FILE="${CONTRIB_DIR}/contour-radius-demo-recipe-pack.bicep"
ORIGINAL_HOME="${HOME}"
E2E_HOME="${E2E_HOME:-$(mktemp -d)}"
export HOME="${E2E_HOME}"
export DOTNET_BUNDLE_EXTRACT_BASE_DIR="${DOTNET_BUNDLE_EXTRACT_BASE_DIR:-/tmp/dotnet-bundle-extract}"
mkdir -p "${HOME}"
if [[ -d "${ORIGINAL_HOME}/.rad/bin" && ! -e "${HOME}/.rad/bin" ]]; then
  mkdir -p "${HOME}/.rad"
  ln -s "${ORIGINAL_HOME}/.rad/bin" "${HOME}/.rad/bin"
fi

if (( BASH_VERSINFO[0] < 4 )); then
  echo "Error: this e2e requires Bash 4 or newer because resource-types-contrib build scripts use Bash 4 features." >&2
  exit 1
fi

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command '$1' was not found." >&2
    exit 1
  fi
}

for cmd in docker kind kubectl helm rad curl jq oras zip; do
  require_command "$cmd"
done

cd "${CONTRIB_DIR}"

make create-radius-cluster
kubectl get namespace "${APP_NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${APP_NAMESPACE}"
rad env update "${ENVIRONMENT}" --kubernetes-namespace "${APP_NAMESPACE}" --preview
"${ROOT_DIR}/scripts/install-contour-gateway-provisioner.sh"
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/experimental-install.yaml

make build-resource-type TYPE_FOLDER=Compute/containers
make build-resource-type TYPE_FOLDER=Compute/routes

make build-bicep-recipe RECIPE_PATH=Compute/containers/recipes/kubernetes/bicep/kubernetes-containers.bicep
make build-bicep-recipe RECIPE_PATH=Compute/routes/recipes/kubernetes/bicep/kubernetes-routes.bicep

cat > "${RECIPE_PACK_FILE}" <<EOF
extension radius

resource recipePack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: '${RECIPE_PACK_NAME}'
  location: 'global'
  properties: {
    recipes: {
      'Radius.Compute/containers': {
        recipeKind: 'bicep'
        recipeLocation: 'reciperegistry:5000/radius-recipes/compute/containers/kubernetes/bicep/kubernetes-containers:latest'
        plainHttp: true
      }
      'Radius.Compute/routes': {
        recipeKind: 'bicep'
        recipeLocation: 'reciperegistry:5000/radius-recipes/compute/routes/kubernetes/bicep/kubernetes-routes:latest'
        plainHttp: true
      }
    }
  }
}
EOF

rad deploy "${RECIPE_PACK_FILE}" --group default -e "${ENVIRONMENT}"
rad env update "${ENVIRONMENT}" --recipe-packs "${RECIPE_PACK_NAME}" --preview

cp ./*-extension.tgz "${ROOT_DIR}/"
cp bicepconfig.json "${ROOT_DIR}/bicepconfig.json"

rad deploy "${DEMO_APP}" --application "${APP_NAME}" -e "${ENVIRONMENT}" -p routeHostname="${ROUTE_HOSTNAME}"

kubectl wait --timeout=5m -n "${GATEWAY_NAMESPACE}" gateway/"${GATEWAY_NAME}" --for=condition=Programmed
for _ in {1..30}; do
  ROUTE_STATUS="$(kubectl get httproute -n "${APP_NAMESPACE}" -o json | jq -r '
    .items as $routes |
    if ($routes | length) == 0 then "waiting"
    elif ([ $routes[].status.parents[]?.conditions[]? | select(.type == "Accepted" and .status == "True") ] | length) >= ($routes | length) then "accepted"
    else "waiting"
    end
  ')"
  if [[ "${ROUTE_STATUS}" == "accepted" ]]; then
    break
  fi
  sleep 10
done

if [[ "${ROUTE_STATUS}" != "accepted" ]]; then
  echo "E2E failed: HTTPRoute was not accepted." >&2
  kubectl get httproute -n "${APP_NAMESPACE}" -o yaml >&2 || true
  exit 1
fi

ENVOY_SERVICE_NAMESPACE=""
ENVOY_SERVICE_NAME=""
for _ in {1..30}; do
  if kubectl get service -n "${GATEWAY_NAMESPACE}" "envoy-${GATEWAY_NAME}" >/dev/null 2>&1; then
    ENVOY_SERVICE_NAMESPACE="${GATEWAY_NAMESPACE}"
    ENVOY_SERVICE_NAME="envoy-${GATEWAY_NAME}"
    break
  fi
  if kubectl get service -n "${GATEWAY_NAMESPACE}" envoy >/dev/null 2>&1; then
    ENVOY_SERVICE_NAMESPACE="${GATEWAY_NAMESPACE}"
    ENVOY_SERVICE_NAME="envoy"
    break
  fi
  if kubectl get service -n "${APP_NAMESPACE}" envoy-web >/dev/null 2>&1; then
    ENVOY_SERVICE_NAMESPACE="${APP_NAMESPACE}"
    ENVOY_SERVICE_NAME="envoy-web"
    break
  fi
  if kubectl get service -n "${APP_NAMESPACE}" envoy >/dev/null 2>&1; then
    ENVOY_SERVICE_NAMESPACE="${APP_NAMESPACE}"
    ENVOY_SERVICE_NAME="envoy"
    break
  fi
  if kubectl get service -n "${CONTOUR_NAMESPACE}" envoy >/dev/null 2>&1; then
    ENVOY_SERVICE_NAMESPACE="${CONTOUR_NAMESPACE}"
    ENVOY_SERVICE_NAME="envoy"
    break
  fi
  sleep 5
done

if [[ -z "${ENVOY_SERVICE_NAMESPACE}" ]]; then
  echo "E2E failed: Contour Envoy service was not created." >&2
  kubectl get gateway -n "${GATEWAY_NAMESPACE}" -o yaml >&2 || true
  kubectl get pods,svc -n "${GATEWAY_NAMESPACE}" >&2 || true
  kubectl get pods,svc -n "${APP_NAMESPACE}" >&2 || true
  kubectl get pods,svc -n "${CONTOUR_NAMESPACE}" >&2 || true
  exit 1
fi

kubectl port-forward -n "${ENVOY_SERVICE_NAMESPACE}" "service/${ENVOY_SERVICE_NAME}" 8080:80 >/tmp/radius-contour-demo-port-forward.log 2>&1 &
PF_PID=$!
trap 'kill ${PF_PID} >/dev/null 2>&1 || true' EXIT

for _ in {1..30}; do
  if curl -fsS -H "Host: ${ROUTE_HOSTNAME}" http://127.0.0.1:8080/ >/tmp/radius-contour-demo-response.html; then
    grep -qi "welcome to nginx" /tmp/radius-contour-demo-response.html
    echo "E2E succeeded: Radius app responded through Contour Gateway API."
    exit 0
  fi
  sleep 2
done

echo "E2E failed: application did not respond through Contour." >&2
kubectl get gateway,httproute,pods,svc -n "${APP_NAMESPACE}" >&2 || true
kubectl get pods,svc -n "${GATEWAY_NAMESPACE}" >&2 || true
kubectl get pods,svc -n "${CONTOUR_NAMESPACE}" >&2 || true
exit 1
