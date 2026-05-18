#!/usr/bin/env bash
set -euo pipefail

CONTOUR_NAMESPACE="${CONTOUR_NAMESPACE:-projectcontour}"

echo "Installing Contour with HTTPProxy support..."
kubectl apply -f https://projectcontour.io/quickstart/contour.yaml

kubectl wait --timeout=5m -n "${CONTOUR_NAMESPACE}" deployment/contour --for=condition=Available
kubectl rollout status --timeout=5m -n "${CONTOUR_NAMESPACE}" daemonset/envoy
kubectl get service -n "${CONTOUR_NAMESPACE}" envoy
