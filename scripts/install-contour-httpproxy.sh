#!/usr/bin/env bash
set -euo pipefail

CONTOUR_NAMESPACE="${CONTOUR_NAMESPACE:-projectcontour}"

echo "Installing Contour with HTTPProxy support..."
kubectl apply -f https://projectcontour.io/quickstart/contour.yaml

kubectl wait --timeout=5m -n "${CONTOUR_NAMESPACE}" deployment/contour --for=condition=Available
kubectl rollout status --timeout=5m -n "${CONTOUR_NAMESPACE}" daemonset/envoy
kubectl get service -n "${CONTOUR_NAMESPACE}" envoy

cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: radius-contour-httpproxy-recipes
rules:
  - apiGroups:
      - projectcontour.io
    resources:
      - httpproxies
    verbs:
      - get
      - list
      - watch
      - create
      - update
      - patch
      - delete
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: radius-contour-httpproxy-recipes
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: radius-contour-httpproxy-recipes
subjects:
  - kind: ServiceAccount
    name: dynamic-rp
    namespace: radius-system
EOF
