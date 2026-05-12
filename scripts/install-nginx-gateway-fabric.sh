#!/usr/bin/env bash
set -euo pipefail

NGF_VERSION="${NGF_VERSION:-v2.6.0}"
NGF_NAMESPACE="${NGF_NAMESPACE:-nginx-gateway}"
NGF_RELEASE="${NGF_RELEASE:-ngf}"

echo "Installing Gateway API CRDs for NGINX Gateway Fabric ${NGF_VERSION}..."
kubectl kustomize "https://github.com/nginx/nginx-gateway-fabric/config/crd/gateway-api/standard?ref=${NGF_VERSION}" | kubectl apply -f -

echo "Installing NGINX Gateway Fabric..."
helm upgrade --install "${NGF_RELEASE}" oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
  --namespace "${NGF_NAMESPACE}" \
  --create-namespace \
  --wait

kubectl wait --timeout=5m -n "${NGF_NAMESPACE}" "deployment/${NGF_RELEASE}-nginx-gateway-fabric" --for=condition=Available
kubectl get gatewayclass nginx
