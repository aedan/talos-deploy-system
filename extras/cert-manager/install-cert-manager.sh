#!/bin/bash
# shellcheck disable=SC2124,SC2145,SC2294
#
# Install cert-manager using Helm
# This script installs cert-manager with custom overrides

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

GLOBAL_OVERRIDES_DIR="${REPO_ROOT}/etc/helm-configs/global_overrides"
SERVICE_CONFIG_DIR="${REPO_ROOT}/etc/helm-configs/cert-manager"
BASE_OVERRIDES="${REPO_ROOT}/extras/cert-manager/cert-manager-helm-overrides.yaml"

# Read cert-manager version from helm-chart-versions.yaml
VERSION_FILE="${REPO_ROOT}/etc/helm-chart-versions.yaml"
if [ ! -f "$VERSION_FILE" ]; then
    echo "Error: helm-chart-versions.yaml not found at $VERSION_FILE"
    exit 1
fi

# Extract cert-manager version using grep and sed
CERT_MANAGER_VERSION=$(grep 'cert-manager:' "$VERSION_FILE" | sed 's/.*cert-manager: *//')

if [ -z "$CERT_MANAGER_VERSION" ]; then
    echo "Error: Could not extract cert-manager version from $VERSION_FILE"
    exit 1
fi

echo "Installing cert-manager version: ${CERT_MANAGER_VERSION}"

# Add Jetstack Helm repository
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo update

# Build Helm command
HELM_CMD="helm upgrade --install --namespace cert-manager --create-namespace cert-manager jetstack/cert-manager --version ${CERT_MANAGER_VERSION}"

# Add base overrides
HELM_CMD+=" -f ${BASE_OVERRIDES}"

# Add global overrides if they exist
for dir in "$GLOBAL_OVERRIDES_DIR" "$SERVICE_CONFIG_DIR"; do
    if compgen -G "${dir}/*.yaml" > /dev/null; then
        for yaml_file in "${dir}"/*.yaml; do
            # Avoid re-adding the base override file if present in the service directory
            if [ "${yaml_file}" != "${BASE_OVERRIDES}" ]; then
                HELM_CMD+=" -f ${yaml_file}"
            fi
        done
    fi
done

# Add any additional arguments passed to the script
HELM_CMD+=" $@"

echo "Executing Helm command:"
echo "${HELM_CMD}"
eval "${HELM_CMD}"
