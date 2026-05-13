#!/usr/bin/env bash
set -euo pipefail

CONTOUR_NAMESPACE="${CONTOUR_NAMESPACE:-projectcontour}"
CONTOUR_GATEWAY_CLASS="${CONTOUR_GATEWAY_CLASS:-contour}"

echo "Installing Contour Gateway Provisioner..."
kubectl apply -f https://projectcontour.io/quickstart/contour-gateway-provisioner.yaml

kubectl wait --timeout=5m -n "${CONTOUR_NAMESPACE}" deployment/contour-gateway-provisioner --for=condition=Available

cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: ${CONTOUR_GATEWAY_CLASS}
spec:
  controllerName: projectcontour.io/gateway-controller
EOF

kubectl wait --timeout=5m gatewayclass/"${CONTOUR_GATEWAY_CLASS}" --for=condition=Accepted
kubectl get gatewayclass "${CONTOUR_GATEWAY_CLASS}"
