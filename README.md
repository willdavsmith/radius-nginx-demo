# Radius Gateway Controller Demos

This repository demonstrates running Radius with built-in Contour installation disabled, then adding an ingress implementation explicitly through installer scripts and Radius recipes.

The workspace pins two upstream repositories as submodules:

- `submodules/radius`: Radius source, on branch `replace-contour-with-nginx-demo`.
- `submodules/resource-types-contrib`: contributed Radius resource types and recipes, including the nginx Gateway recipe added for this demo.

## NGINX Gateway Fabric Demo

1. Creates a local kind cluster.
2. Installs Radius with Contour skipped.
3. Installs Kubernetes Gateway API CRDs and NGINX Gateway Fabric.
4. Registers `Radius.Compute/gateways`, `Radius.Compute/containers`, and `Radius.Compute/routes`.
5. Deploys `demo/app.bicep`.
6. Curls the application through the NGINX Gateway data plane.

## Run Locally

Prerequisites: Bash 4 or newer, Docker, kind, kubectl, Helm, wget, curl, jq, and oras.

```bash
git submodule update --init --recursive
./scripts/e2e-nginx-radius.sh
```

## Contour Gateway API Demo

The Contour demo follows the same pattern, but installs Contour after Radius via the Contour Gateway Provisioner and uses the same Gateway API recipes with `gatewayClassName=contour`.

```bash
git submodule update --init --recursive
./scripts/e2e-contour-radius.sh
```

## Contour HTTPProxy Demo

The Contour HTTPProxy demo shows that the current built-in Contour behavior can also be mirrored through recipes. It installs Contour with HTTPProxy support, deploys the same Radius app, and uses alternate recipe variants that create a Contour `HTTPProxy` instead of Gateway API `Gateway` and `HTTPRoute` resources.

```bash
git submodule update --init --recursive
./scripts/e2e-contour-httpproxy-radius.sh
```

The script leaves the cluster running for inspection. Clean it up with:

```bash
kind delete cluster --name radius
docker rm -f reciperegistry
```

## Notes

NGINX Gateway Fabric currently installs from the official OCI Helm chart at `oci://ghcr.io/nginx/charts/nginx-gateway-fabric`. Its documentation requires Gateway API CRDs before install and states that the default installation creates a `nginx` GatewayClass.

Contour installs from the official Gateway Provisioner quickstart manifest at `https://projectcontour.io/quickstart/contour-gateway-provisioner.yaml`. The script creates a `contour` GatewayClass using Contour's Gateway API controller name, `projectcontour.io/gateway-controller`.
