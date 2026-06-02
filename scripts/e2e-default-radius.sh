#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRIB_DIR="${ROOT_DIR}/submodules/resource-types-contrib"
RADIUS_DIR="${ROOT_DIR}/submodules/radius"
DEMO_APP="${ROOT_DIR}/demo/default-radius-app.bicep"
ENVIRONMENT="${ENVIRONMENT:-default}"
APP_NAME="${APP_NAME:-default-radius-demo}"
APP_NAMESPACE="${APP_NAMESPACE:-default-radius-demo}"
ROUTE_HOSTNAME="${ROUTE_HOSTNAME:-default.example.com}"
GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-radius-system}"
GATEWAY_NAME="${GATEWAY_NAME:-radius}"
RECIPE_PACK_FILE="${ROOT_DIR}/default-recipe-pack.bicep"
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

cd "${ROOT_DIR}"

kind create cluster --name radius

if ! docker ps | grep -q "reciperegistry"; then
  docker run -d --restart=always -p 5000:5000 --name reciperegistry registry:2
  docker network connect kind reciperegistry || true
fi

kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:5000"
    hostFromContainerRuntime: "reciperegistry:5000"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/experimental-install.yaml

rad install kubernetes \
  --chart "${RADIUS_DIR}/deploy/Chart" \
  --set rp.publicEndpointOverride=localhost:8081 \
  --set dashboard.enabled=false

"${CONTRIB_DIR}/.github/scripts/verify-ucp-readiness.sh"
kubectl get namespace "${APP_NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${APP_NAMESPACE}"

rad group create default
rad workspace create kubernetes default --group default --force
rad group switch default
rad env create "${ENVIRONMENT}" --preview
rad env update "${ENVIRONMENT}" --kubernetes-namespace "${APP_NAMESPACE}" --preview

cd "${CONTRIB_DIR}"
make build-bicep-recipe RECIPE_PATH=Compute/containers/recipes/kubernetes/bicep/kubernetes-containers.bicep
make build-bicep-recipe RECIPE_PATH=Compute/routes/recipes/kubernetes/bicep/kubernetes-routes.bicep

cd "${ROOT_DIR}"
"${HOME}/.rad/bin/bicep" publish-extension "${RADIUS_DIR}/hack/bicep-types-radius/generated/index.json" --target "${ROOT_DIR}/radius-extension.tgz" --force

cat > "${ROOT_DIR}/bicepconfig.json" <<EOF
{
  "experimentalFeaturesEnabled": {
    "extensibility": true
  },
  "extensions": {
    "radius": "./radius-extension.tgz",
    "radiusCompute": "br:biceptypes.azurecr.io/radiuscompute:latest"
  }
}
EOF

cat > "${RECIPE_PACK_FILE}" <<EOF
extension radius

resource recipePack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'default'
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
rad env update "${ENVIRONMENT}" --recipe-packs default --preview

rad deploy "${DEMO_APP}" --application "${APP_NAME}" -e "${ENVIRONMENT}" -p routeHostname="${ROUTE_HOSTNAME}"

ROUTE_COUNT="0"
for _ in {1..30}; do
  ROUTE_COUNT="$(kubectl get httproute -n "${APP_NAMESPACE}" -o json | jq -r '.items | length')"
  if [[ "${ROUTE_COUNT}" != "0" ]]; then
    break
  fi
  sleep 10
done

if [[ "${ROUTE_COUNT}" == "0" ]]; then
  echo "E2E failed: HTTPRoute was not created." >&2
  kubectl get gateway -n "${GATEWAY_NAMESPACE}" -o yaml >&2 || true
  kubectl get httproute -n "${APP_NAMESPACE}" -o yaml >&2 || true
  exit 1
fi

ENVOY_TARGET=""
ENVOY_TARGET_PORT="80"
for _ in {1..60}; do
  ENVOY_TARGET="$(kubectl get pods -n "${GATEWAY_NAMESPACE}" -o name | awk '/^pod\/contour-envoy-/ { print; exit }')"
  if [[ -n "${ENVOY_TARGET}" ]]; then
    ENVOY_TARGET_PORT="8080"
    break
  fi
  if kubectl get service -n "${GATEWAY_NAMESPACE}" "envoy-${GATEWAY_NAME}" >/dev/null 2>&1; then
    ENVOY_TARGET="service/envoy-${GATEWAY_NAME}"
    break
  fi
  if kubectl get service -n "${GATEWAY_NAMESPACE}" contour-envoy >/dev/null 2>&1; then
    ENVOY_TARGET="service/contour-envoy"
    break
  fi
  sleep 5
done

if [[ -z "${ENVOY_TARGET}" ]]; then
  echo "E2E failed: Contour Envoy service was not created." >&2
  kubectl get gateway -n "${GATEWAY_NAMESPACE}" -o yaml >&2 || true
  kubectl get pods,svc -n "${GATEWAY_NAMESPACE}" >&2 || true
  exit 1
fi

kubectl port-forward -n "${GATEWAY_NAMESPACE}" "${ENVOY_TARGET}" 8080:"${ENVOY_TARGET_PORT}" >/tmp/radius-default-demo-port-forward.log 2>&1 &
PF_PID=$!
trap 'kill ${PF_PID} >/dev/null 2>&1 || true' EXIT

for _ in {1..30}; do
  if ! kill -0 "${PF_PID}" >/dev/null 2>&1; then
    echo "E2E failed: Contour port-forward exited early." >&2
    cat /tmp/radius-default-demo-port-forward.log >&2 || true
    exit 1
  fi
  if grep -q "Forwarding from" /tmp/radius-default-demo-port-forward.log 2>/dev/null; then
    break
  fi
  sleep 1
done

for _ in {1..60}; do
  if curl -fsS -H "Host: ${ROUTE_HOSTNAME}" http://127.0.0.1:8080/ >/tmp/radius-default-demo-response.html; then
    grep -qi "welcome to nginx" /tmp/radius-default-demo-response.html
    echo "E2E succeeded: default Radius install routed traffic through Contour Gateway API."
    exit 0
  fi
  sleep 2
done

echo "E2E failed: application did not respond through default Contour Gateway." >&2
cat /tmp/radius-default-demo-port-forward.log >&2 || true
kubectl get gateway,httproute,pods,svc -n "${APP_NAMESPACE}" >&2 || true
kubectl get pods,svc -n "${GATEWAY_NAMESPACE}" >&2 || true
exit 1
