# Radius + NGINX Gateway Fabric Demo

This repository demonstrates replacing Radius' Contour-based ingress dependency with NGINX Gateway Fabric for Kubernetes ingress.

The workspace pins two upstream repositories as submodules:

- `submodules/radius`: Radius source, on branch `replace-contour-with-nginx-demo`.
- `submodules/resource-types-contrib`: contributed Radius resource types and recipes, including the nginx Gateway recipe added for this demo.

## What The Demo Does

1. Creates a local kind cluster.
2. Installs Radius with Contour skipped.
3. Installs Kubernetes Gateway API CRDs and NGINX Gateway Fabric.
4. Registers `Radius.Compute/gateways`, `Radius.Compute/containers`, and `Radius.Compute/routes`.
5. Deploys `demo/app.bicep`.
6. Curls the application through the NGINX Gateway data plane.

## Run Locally

Prerequisites: Docker, kind, kubectl, Helm, wget, curl, jq, and oras.

```bash
git submodule update --init --recursive
./scripts/e2e-nginx-radius.sh
```

The script leaves the cluster running for inspection. Clean it up with:

```bash
kind delete cluster --name radius
docker rm -f reciperegistry
```

## Notes

NGINX Gateway Fabric currently installs from the official OCI Helm chart at `oci://ghcr.io/nginx/charts/nginx-gateway-fabric`. Its documentation requires Gateway API CRDs before install and states that the default installation creates a `nginx` GatewayClass.
