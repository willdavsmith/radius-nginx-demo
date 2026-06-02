#!/usr/bin/env bash
set -euo pipefail

NGF_VERSION="${NGF_VERSION:-v2.6.0}"
NGF_NAMESPACE="${NGF_NAMESPACE:-nginx-gateway}"
NGF_RELEASE="${NGF_RELEASE:-ngf}"
NGF_GATEWAY_NAMESPACE="${NGF_GATEWAY_NAMESPACE:-default-nginx-radius-demo}"
NGF_GATEWAY_NAME="${NGF_GATEWAY_NAME:-radius}"

echo "Installing Gateway API CRDs for NGINX Gateway Fabric ${NGF_VERSION}..."
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/experimental-install.yaml

echo "Installing NGINX Gateway Fabric..."
helm upgrade --install "${NGF_RELEASE}" oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
  --namespace "${NGF_NAMESPACE}" \
  --create-namespace \
  --wait

kubectl wait --timeout=5m -n "${NGF_NAMESPACE}" "deployment/${NGF_RELEASE}-nginx-gateway-fabric" --for=condition=Available
kubectl get gatewayclass nginx

kubectl get namespace "${NGF_GATEWAY_NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NGF_GATEWAY_NAMESPACE}"

cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${NGF_GATEWAY_NAME}
  namespace: ${NGF_GATEWAY_NAMESPACE}
spec:
  gatewayClassName: nginx
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
EOF

kubectl wait --timeout=5m -n "${NGF_GATEWAY_NAMESPACE}" gateway/"${NGF_GATEWAY_NAME}" --for=condition=Programmed
kubectl get gateway -n "${NGF_GATEWAY_NAMESPACE}" "${NGF_GATEWAY_NAME}"
