# Radius Gateway Controller Demos

This repository demonstrates routes-only ingress with Radius recipes. The application declares `Radius.Compute/routes`; the Kubernetes Gateway object is installed separately as platform infrastructure.

The workspace pins two upstream repositories as submodules:

- `submodules/radius`: Radius source, on branch `replace-contour-with-nginx-demo`.
- `submodules/resource-types-contrib`: contributed Radius resource types and recipes, including the routes recipe used for this demo.

## NGINX Gateway Fabric Demo

1. Creates a local kind cluster.
2. Installs Radius with Contour skipped.
3. Installs Kubernetes Gateway API CRDs and NGINX Gateway Fabric.
4. Creates a Kubernetes `Gateway` for the NGINX GatewayClass.
5. Registers `Radius.Compute/containers` and `Radius.Compute/routes`.
6. Deploys `demo/app.bicep`.
7. Curls the application through the NGINX Gateway data plane.

## Run Locally

Prerequisites: Bash 4 or newer, Docker, kind, kubectl, Helm, wget, curl, jq, and oras.

```bash
git submodule update --init --recursive
./scripts/e2e-nginx-radius.sh
```

## Contour Gateway API Demo

The Contour demo follows the same pattern, but installs Contour after Radius via the Contour Gateway Provisioner. The installer script creates the same shared Gateway that Radius will create during `rad install kubernetes` when Contour installation is enabled.

```bash
git submodule update --init --recursive
./scripts/e2e-contour-radius.sh
```

The script leaves the cluster running for inspection. Clean it up with:

```bash
kind delete cluster --name radius
docker rm -f reciperegistry
```

## Notes

NGINX Gateway Fabric currently installs from the official OCI Helm chart at `oci://ghcr.io/nginx/charts/nginx-gateway-fabric`. Its documentation requires Gateway API CRDs before install and states that the default installation creates a `nginx` GatewayClass.

Contour installs from the official Gateway Provisioner quickstart manifest at `https://projectcontour.io/quickstart/contour-gateway-provisioner.yaml`. The script creates a `contour` GatewayClass using Contour's Gateway API controller name, `projectcontour.io/gateway-controller`.
