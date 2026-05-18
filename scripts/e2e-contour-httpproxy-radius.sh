#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRIB_DIR="${ROOT_DIR}/submodules/resource-types-contrib"
DEMO_APP="${ROOT_DIR}/demo/app.bicep"
ENVIRONMENT="${ENVIRONMENT:-default}"
APP_NAME="${APP_NAME:-contour-httpproxy-radius-demo}"
APP_NAMESPACE="${APP_NAMESPACE:-default-contour-httpproxy-radius-demo}"
CONTOUR_NAMESPACE="${CONTOUR_NAMESPACE:-projectcontour}"
HTTPPROXY_HOSTNAME="${HTTPPROXY_HOSTNAME:-localhost}"
RECIPE_PACK_NAME="${RECIPE_PACK_NAME:-contour-httpproxy-radius-demo-pack}"
RECIPE_PACK_FILE="${CONTRIB_DIR}/contour-httpproxy-radius-demo-recipe-pack.bicep"
ORIGINAL_HOME="${HOME}"
E2E_HOME="${E2E_HOME:-$(mktemp -d)}"
export HOME="${E2E_HOME}"
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
"${ROOT_DIR}/scripts/install-contour-httpproxy.sh"

make build-resource-type TYPE_FOLDER=Compute/gateways
make build-resource-type TYPE_FOLDER=Compute/containers
make build-resource-type TYPE_FOLDER=Compute/routes

make build-terraform-recipe RECIPE_PATH=Compute/gateways/recipes/kubernetes-contour-httpproxy/terraform
make build-bicep-recipe RECIPE_PATH=Compute/containers/recipes/kubernetes/bicep/kubernetes-containers.bicep
make build-terraform-recipe RECIPE_PATH=Compute/routes/recipes/kubernetes-contour-httpproxy/terraform

cat > "${RECIPE_PACK_FILE}" <<EOF
extension radius

resource recipePack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: '${RECIPE_PACK_NAME}'
  location: 'global'
  properties: {
    recipes: {
      'Radius.Compute/gateways': {
        recipeKind: 'terraform'
        recipeLocation: 'http://tf-module-server.radius-test-tf-module-server.svc.cluster.local/gateways-kubernetes-contour-httpproxy.zip'
      }
      'Radius.Compute/containers': {
        recipeKind: 'bicep'
        recipeLocation: 'reciperegistry:5000/radius-recipes/compute/containers/kubernetes/bicep/kubernetes-containers:latest'
        plainHttp: true
      }
      'Radius.Compute/routes': {
        recipeKind: 'terraform'
        recipeLocation: 'http://tf-module-server.radius-test-tf-module-server.svc.cluster.local/routes-kubernetes-contour-httpproxy.zip'
        parameters: {
          hostname: '${HTTPPROXY_HOSTNAME}'
        }
      }
    }
  }
}
EOF

rad deploy "${RECIPE_PACK_FILE}" --group default -e "${ENVIRONMENT}"
rad env update "${ENVIRONMENT}" --recipe-packs "${RECIPE_PACK_NAME}" --preview

cp ./*-extension.tgz "${ROOT_DIR}/"
cp bicepconfig.json "${ROOT_DIR}/bicepconfig.json"

rad deploy "${DEMO_APP}" --application "${APP_NAME}" -e "${ENVIRONMENT}" -p gatewayClassName=contour

HTTPPROXY_STATUS=""
for _ in {1..60}; do
  HTTPPROXY_STATUS="$(kubectl get httpproxy -n "${APP_NAMESPACE}" web -o jsonpath='{.status.currentStatus}' 2>/dev/null || true)"
  if [[ "${HTTPPROXY_STATUS}" == "valid" ]]; then
    break
  fi
  sleep 5
done

if [[ "${HTTPPROXY_STATUS}" != "valid" ]]; then
  echo "E2E failed: HTTPProxy was not valid." >&2
  kubectl get httpproxy -n "${APP_NAMESPACE}" web -o yaml >&2 || true
  kubectl get pods,svc -n "${APP_NAMESPACE}" >&2 || true
  kubectl get pods,svc -n "${CONTOUR_NAMESPACE}" >&2 || true
  exit 1
fi

kubectl port-forward -n "${CONTOUR_NAMESPACE}" service/envoy 8080:80 >/tmp/radius-contour-httpproxy-demo-port-forward.log 2>&1 &
PF_PID=$!
trap 'kill ${PF_PID} >/dev/null 2>&1 || true' EXIT

for _ in {1..30}; do
  if curl -fsS -H "Host: ${HTTPPROXY_HOSTNAME}" http://127.0.0.1:8080/ >/tmp/radius-contour-httpproxy-demo-response.html; then
    grep -qi "welcome to nginx" /tmp/radius-contour-httpproxy-demo-response.html
    echo "E2E succeeded: Radius app responded through Contour HTTPProxy recipes."
    exit 0
  fi
  sleep 2
done

echo "E2E failed: application did not respond through Contour HTTPProxy." >&2
kubectl get httpproxy,pods,svc -n "${APP_NAMESPACE}" >&2 || true
kubectl get pods,svc -n "${CONTOUR_NAMESPACE}" >&2 || true
exit 1
