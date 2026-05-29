#!/usr/bin/env bash
set -euo pipefail

CONTOUR_NAMESPACE="${CONTOUR_NAMESPACE:-projectcontour}"
CONTOUR_GATEWAY_CLASS="${CONTOUR_GATEWAY_CLASS:-contour}"
RADIUS_GATEWAY_NAMESPACE="${RADIUS_GATEWAY_NAMESPACE:-radius-system}"
RADIUS_GATEWAY_NAME="${RADIUS_GATEWAY_NAME:-radius}"

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

kubectl get namespace "${RADIUS_GATEWAY_NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${RADIUS_GATEWAY_NAMESPACE}"

cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${RADIUS_GATEWAY_NAME}
  namespace: ${RADIUS_GATEWAY_NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: radius
    app.kubernetes.io/part-of: radius
spec:
  gatewayClassName: ${CONTOUR_GATEWAY_CLASS}
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
EOF

kubectl wait --timeout=5m -n "${RADIUS_GATEWAY_NAMESPACE}" gateway/"${RADIUS_GATEWAY_NAME}" --for=condition=Programmed
kubectl get gateway -n "${RADIUS_GATEWAY_NAMESPACE}" "${RADIUS_GATEWAY_NAME}"
