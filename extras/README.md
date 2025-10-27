# Extras

This directory contains additional scripts and configurations for deploying common Kubernetes services on your Talos cluster.

## Directory Structure

```
extras/
├── cert-manager/
│   ├── install-cert-manager.sh        # Installation script
│   └── cert-manager-helm-overrides.yaml  # Base Helm values
└── README.md
```

## Helm Chart Versions

All Helm chart versions are defined in `/etc/helm-chart-versions.yaml` for centralized version management.

## Configuration Override System

The installation scripts support a layered configuration system:

1. **Base overrides**: Located in `extras/<service>/<service>-helm-overrides.yaml`
2. **Global overrides**: Located in `etc/helm-configs/global_overrides/*.yaml`
3. **Service-specific overrides**: Located in `etc/helm-configs/<service>/*.yaml`

Overrides are applied in this order, with later files taking precedence.

## cert-manager

### Installation

```bash
cd extras/cert-manager
./install-cert-manager.sh
```

### Custom Configuration

To customize cert-manager installation, create override files:

**Global configuration** (applies to all services):
```bash
cat > etc/helm-configs/global_overrides/common.yaml <<EOF
# Global settings for all Helm charts
EOF
```

**Service-specific configuration**:
```bash
cat > etc/helm-configs/cert-manager/custom-config.yaml <<EOF
# Cert-manager specific settings
installCRDs: true

webhook:
  replicaCount: 2

resources:
  limits:
    memory: 256Mi
EOF
```

### Version Management

To change the cert-manager version, edit `etc/helm-chart-versions.yaml`:

```yaml
cert-manager: v1.16.2
```

Then re-run the installation script.

### Verification

After installation, verify cert-manager is running:

```bash
kubectl get pods -n cert-manager
kubectl get crds | grep cert-manager
```

## Adding New Services

To add a new service:

1. Create a directory: `extras/<service>/`
2. Create base overrides: `extras/<service>/<service>-helm-overrides.yaml`
3. Create install script: `extras/<service>/install-<service>.sh`
4. Add version to `etc/helm-chart-versions.yaml`
5. Follow the same pattern as cert-manager

## Notes

- All scripts use Helm repository installations (not OCI) for better compatibility
- The scripts are designed to be idempotent - safe to run multiple times
- Override files are optional - the base configuration will work for most use cases
