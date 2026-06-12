#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRIB_DIR="${ROOT_DIR}/submodules/resource-types-contrib"
RADIUS_DIR="${ROOT_DIR}/submodules/radius"
DEMO_APP="${ROOT_DIR}/demo/default-radius-app.bicep"
ENVIRONMENT="${ENVIRONMENT:-default}"
ENVIRONMENT_ID="/planes/radius/local/resourcegroups/default/providers/Radius.Core/environments/${ENVIRONMENT}"
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

if [[ "$(docker inspect -f '{{.State.Running}}' reciperegistry 2>/dev/null || true)" != "true" ]]; then
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
        parameters: {
          gatewayName: '${GATEWAY_NAME}'
          gatewayNamespace: '${GATEWAY_NAMESPACE}'
        }
      }
    }
  }
}
EOF

rad deploy "${RECIPE_PACK_FILE}" --group default -e "${ENVIRONMENT_ID}"
rad env update "${ENVIRONMENT}" --recipe-packs default --preview

rad deploy "${DEMO_APP}" --application "${APP_NAME}" -e "${ENVIRONMENT_ID}" -p routeHostname="${ROUTE_HOSTNAME}"

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

for _ in {1..20}; do
  kubectl delete pod radius-default-curl -n "${APP_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl run radius-default-curl \
    -n "${APP_NAMESPACE}" \
    --restart=Never \
    --image=curlimages/curl:8.15.0 \
    --image-pull-policy=IfNotPresent \
    --command -- sh -c "curl -sS --connect-timeout 5 --max-time 10 -w '\nHTTP_STATUS:%{http_code}\n' -H 'Host: ${ROUTE_HOSTNAME}' 'http://contour-envoy.${GATEWAY_NAMESPACE}.svc.cluster.local/'" >/dev/null
  kubectl wait --timeout=20s -n "${APP_NAMESPACE}" pod/radius-default-curl --for=jsonpath='{.status.phase}'=Succeeded >/dev/null 2>&1 || true
  kubectl logs -n "${APP_NAMESPACE}" radius-default-curl >/tmp/radius-default-demo-response.html 2>/tmp/radius-default-demo-curl.log || true
  if grep -q "HTTP_STATUS:200" /tmp/radius-default-demo-response.html && grep -qi "welcome to nginx" /tmp/radius-default-demo-response.html; then
    grep -qi "welcome to nginx" /tmp/radius-default-demo-response.html
    echo "E2E succeeded: default Radius install routed traffic through Contour Gateway API."
    exit 0
  fi
  sleep 2
done

echo "E2E failed: application did not respond through default Contour Gateway." >&2
cat /tmp/radius-default-demo-response.html >&2 || true
cat /tmp/radius-default-demo-curl.log >&2 || true
kubectl get gateway,httproute,pods,svc -n "${APP_NAMESPACE}" >&2 || true
kubectl get pods,svc -n "${GATEWAY_NAMESPACE}" >&2 || true
exit 1
