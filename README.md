# Talos Deploy System - dnsmasq PXE Boot with Image Factory

Automated Ansible playbook that deploys and configures dnsmasq to provide DHCP and PXE boot services with integrated Talos Linux Image Factory support for custom image generation.

## Features

### Core Features
- **DHCP server** with static IP reservations
- **MAC address whitelist** - Only serves DHCP to known machines
- **PXE boot support** with TFTP server
- **HTTP server (nginx)** - Serves Talos installer images locally on port 8080
- **Automated syslinux installation** and configuration

### Talos Linux Integration
- **Talos Image Factory API integration** - Automatically generates custom images
- **System extensions support** - Default: iscsi-tools and util-linux-tools
- **Automatic image downloads** - Kernel, initramfs, and installer images downloaded locally
- **Flexible installer serving** - Choose between local HTTP server (airgapped) or direct factory.talos.dev pull (internet-connected)
- **Version control** - Specify exact Talos version in inventory
- **Architecture support** - amd64 and arm64

### Security
- Only machines defined in inventory receive IP addresses
- Static DHCP reservations prevent IP conflicts
- Interface binding for network isolation

## Prerequisites

- **Ansible** 2.9+ installed on the control machine
- **Python 3.6+** with pip
- **Root/sudo access** on the target machine (localhost)
- **Internet connection** for downloading Talos images from Image Factory
- **Ubuntu/Debian or RHEL/Rocky/CentOS** Linux distribution

## Installation

### Setup Virtual Environment (Recommended)

```bash
./setup-ansible-env.sh
source ~/.venvs/talos-deploy/bin/activate
```

This will install:
- Ansible
- Python dependencies (netaddr, urllib3)
- Required Ansible collections

### Manual Installation

```bash
pip install -r requirements.txt
ansible-galaxy collection install ansible.utils ansible.posix community.general
```

## Quick Start

### 1. Clone the repository

```bash
git clone https://github.com/aedan/talos-deploy-system.git
cd talos-deploy-system
```

### 2. Setup environment

```bash
./setup-ansible-env.sh
source ~/.venvs/talos-deploy/bin/activate
```

### 3. Create your inventory

```bash
cp inventory.yml.example inventory.yml
```

Edit `inventory.yml` and configure:

```yaml
# Network configuration
dhcp_interface: eno1                    # Your network interface
domain: internal.example.com            # Your domain

# DHCP range
dhcp_range:
  start: 192.168.1.100
  end: 192.168.1.150

# Talos Image Factory configuration
talos_version: v1.11.3                  # Talos version
talos_arch: amd64                       # Architecture
talos_extensions:                       # System extensions
  - siderolabs/iscsi-tools
  - siderolabs/util-linux-tools

# Add your machines
pxe_hosts:
  - name: node01.example.com
    mac: 52:54:00:12:34:56
    ip: 192.168.1.101
```

### 4. Deploy PXE Server

```bash
ansible-playbook -i inventory.yml playbooks/deploy-dnsmasq.yml
```

The playbook will:
1. Install dnsmasq, syslinux, and nginx packages
2. Configure DHCP server with your static hosts
3. Set up TFTP server for PXE boot files
4. Configure nginx HTTP server on port 8080 (if `use_local_installer: true`)
5. Generate Talos schematic with your extensions
6. Upload schematic to Image Factory
7. Download custom kernel, initramfs, and installer image (installer only if `use_local_installer: true`)
8. Configure PXE boot menu
9. Start dnsmasq and nginx services (nginx only if `use_local_installer: true`)

### 5. Generate Talos Configurations

```bash
ansible-playbook -i inventory.yml playbooks/generate-talos-configs.yml
```

This will:
1. Download/update talosctl to match your Talos version
2. Generate cluster secrets (only once, idempotent)
3. Create individual node configs for control plane and workers
4. Generate talosconfig for cluster management
5. Create deployment documentation

Output: `./talos-configs/` directory with:
- Individual node YAML configs
- `secrets.yaml` (keep secure!)
- `talosconfig` for cluster access
- `README.md` with deployment instructions

### 6. PXE Boot All Nodes

**Option A: Automated via OOB Management (iLO/iDRAC)**

```bash
ansible-playbook -i inventory.yml playbooks/pxe-boot-servers.yml
```

This will:
1. Connect to each server's iLO/iDRAC via Redfish API
2. Set next boot to PXE/Network
3. Trigger server restart
4. Monitor boot progress via dnsmasq logs

**Option B: Manual Boot**

Manually boot each server and select network/PXE boot from BIOS or iLO/iDRAC console.

All nodes will:
1. Download kernel and initramfs from dnsmasq
2. Boot into Talos maintenance mode
3. Wait for configuration to be applied

### 7. Deploy Configurations to All Nodes

```bash
ansible-playbook -i inventory.yml playbooks/deploy-talos-cluster.yml
```

This will:
1. Apply configurations to all nodes
2. Wait for all control plane nodes to be fully healthy (installer downloaded, disk installed, rebooted, services running)
3. Wait for all worker nodes to be fully healthy
4. Verify etcd service is ready on first control plane
5. Check if cluster is already bootstrapped
6. Display next steps

**Note:** This playbook includes comprehensive health checks to ensure all nodes are fully ready. It stops before bootstrapping to allow you to verify node status.

### 8. Bootstrap the Cluster

After all nodes are healthy, bootstrap etcd and extract kubeconfig:

```bash
ansible-playbook -i inventory.yml playbooks/bootstrap-talos-cluster.yml
```

This will:
1. Check if etcd is already bootstrapped
2. Bootstrap etcd on first control plane node (if not already done)
3. Wait for etcd cluster to be operational
4. Wait for Kubernetes API to be available
5. Extract kubeconfig to `~/.kube/config`
6. Verify cluster access

**Note:** Nodes will show `NotReady` until CNI (kube-ovn) is installed - this is expected!

### 9. Install Additional Services (Optional)

After the cluster is deployed, you can install additional services like cert-manager:

```bash
cd extras/cert-manager
./install-cert-manager.sh
```

See the [extras/README.md](extras/README.md) for more information on available services and customization options.

## File Structure

```
.
├── inventory.yml.example           # Example inventory file
├── inventory.yml                   # Your inventory (gitignored)
├── playbooks/                      # Ansible playbooks
│   ├── deploy-dnsmasq.yml          # PXE server deployment
│   ├── generate-talos-configs.yml  # Generate Talos node configs
│   ├── pxe-boot-servers.yml        # Trigger PXE boot via iLO/iDRAC
│   ├── reset-to-maintenance.yml    # Reset nodes to maintenance mode
│   └── deploy-talos-cluster.yml    # Bootstrap and deploy cluster
├── scripts/
│   └── redfish_pxe_boot.py         # Redfish API client for OOB management
├── templates/
│   ├── dnsmasq.conf.j2             # Main dnsmasq configuration
│   ├── dnsmasq-pxe.conf.j2         # PXE-specific settings
│   ├── dnsmasq-hosts.conf.j2       # Static DHCP reservations
│   ├── nginx-talos.conf.j2         # nginx HTTP server configuration
│   ├── pxelinux.cfg.default.j2     # PXE boot menu
│   ├── talos-schematic.yaml.j2     # Talos Image Factory schematic
│   ├── talos-controlplane.yaml.j2  # Control plane node template
│   └── talos-worker.yaml.j2        # Worker node template
├── extras/                         # Additional service installation scripts
│   ├── cert-manager/               # Cert-manager installation
│   │   ├── install-cert-manager.sh
│   │   └── cert-manager-helm-overrides.yaml
│   └── README.md                   # Extras documentation
├── etc/                            # Configuration files
│   ├── helm-chart-versions.yaml    # Centralized Helm chart versions
│   └── helm-configs/               # Helm override configurations
│       ├── global_overrides/       # Global overrides for all charts
│       └── cert-manager/           # Cert-manager specific overrides
├── talos-configs/                  # Generated configs (gitignored)
│   ├── *.yaml                      # Individual node configs
│   ├── secrets.yaml                # Cluster secrets
│   ├── talosconfig                 # Talos CLI config
│   └── DEPLOYMENT.md               # Deployment guide
├── pxe-boot-*.log                  # Boot trigger logs (gitignored)
├── maintenance-reset-*.log         # Maintenance reset logs (gitignored)
└── README.md                       # This file
```

## Configuration

### Network Settings

```yaml
dhcp_interface: eth0                # Interface to listen on
domain: pxe.local                   # Internal domain name
pxe_server_address: 192.168.1.10    # PXE/HTTP server IP or hostname
dhcp_range:
  start: 192.168.1.100              # DHCP range start
  end: 192.168.1.150                # DHCP range end
lease_time: "12h"                   # DHCP lease duration
```

**Note:** `pxe_server_address` is used for the nginx HTTP server that serves Talos installer images on port 8080.

### Talos Image Factory

```yaml
talos_version: v1.11.3              # Talos Linux version
talos_arch: amd64                   # Architecture (amd64, arm64)
talos_extensions:                   # System extensions to include
  - siderolabs/iscsi-tools
  - siderolabs/util-linux-tools
  - siderolabs/qemu-guest-agent     # Add more as needed
talos_extra_kernel_args: []         # Optional kernel arguments
talos_download_iso: false           # Set true to download ISO
use_local_installer: true           # Use local nginx for installer images (true) or pull from factory.talos.dev (false)
```

**`use_local_installer` option:**
- `true` (default): Downloads installer image to local nginx server, nodes install from local HTTP server (no external internet required during installation)
- `false`: Nodes pull installer images directly from factory.talos.dev (requires internet access on PXE network). If nginx is currently enabled, it will be stopped and disabled.

Available extensions: https://factory.talos.dev

### PXE Boot Options

```yaml
pxe_boot_label: talos-install           # Boot menu label
pxe_boot_menu_text: Install Talos Linux # Menu description
pxe_timeout: 30                          # Timeout (deciseconds)
pxe_default_label: talos-install         # Auto-boot option
pxe_boot_params: talos.platform=metal... # Kernel parameters
```

### Cluster Configuration

```yaml
talos_cluster_name: cluster.local
talos_cluster_endpoint: https://talos-api.example.com:6443
talos_kubernetes_version: v1.34.1

# Network configuration (from deployer node)
network_gateway: 192.168.1.1
network_netmask: 24
network_nameservers:
  - 8.8.8.8
  - 1.1.1.1
network_mtu: 1500
network_primary_interface: eno1

# Longhorn configuration
longhorn_mount_path: /var/lib/longhorn
```

### Host Definitions

Each machine needs:
- **name**: FQDN or hostname
- **mac**: MAC address (XX:XX:XX:XX:XX:XX format)
- **ip**: Static IP address
- **role**: `controlplane` or `worker`
- **install_disk**: Disk for Talos installation
- **oob_type**: `ilo`, `idrac`, or `redfish` (optional, for automated PXE boot)
- **oob_address**: OOB management IP (optional)
- **oob_username**: OOB username (optional)
- **oob_password**: OOB password (optional)

```yaml
pxe_hosts:
  - name: control-plane-1.k8s.local
    mac: 52:54:00:aa:bb:cc
    ip: 192.168.1.10
    role: controlplane
    install_disk: /dev/sda
    # Out-of-Band Management (optional)
    oob_type: ilo
    oob_address: 192.168.1.110
    oob_username: Administrator
    oob_password: your-ilo-password

  - name: worker-1.k8s.local
    mac: 52:54:00:dd:ee:ff
    ip: 192.168.1.20
    role: worker
    install_disk: /dev/sda
    oob_type: idrac
    oob_address: 192.168.1.120
    oob_username: root
    oob_password: your-idrac-password
```

**Note:** OOB credentials are stored in `inventory.yml` which is gitignored for security.

## Complete Workflow

### Full Deployment from Scratch

```bash
# 1. Deploy PXE server
ansible-playbook -i inventory.yml playbooks/deploy-dnsmasq.yml

# 2. Generate Talos configurations
ansible-playbook -i inventory.yml playbooks/generate-talos-configs.yml

# 3. PXE boot all nodes (automated via OOB)
ansible-playbook -i inventory.yml playbooks/pxe-boot-servers.yml

# 4. Deploy configurations to all nodes
ansible-playbook -i inventory.yml playbooks/deploy-talos-cluster.yml

# 5. Bootstrap the cluster
ansible-playbook -i inventory.yml playbooks/bootstrap-talos-cluster.yml

# 6. Verify cluster
kubectl get nodes  # Will show NotReady (expected without CNI)
kubectl get pods -A
```

## Usage Examples

### Deploy PXE server only

```bash
ansible-playbook -i inventory.yml playbooks/deploy-dnsmasq.yml
```

### Check deployment status

```bash
# Check dnsmasq status
sudo systemctl status dnsmasq

# View dnsmasq logs
sudo journalctl -u dnsmasq -f

# Check DHCP leases
sudo cat /var/lib/misc/dnsmasq.leases

# Verify TFTP files
ls -la /var/lib/tftpboot/
```

### Reset all nodes to maintenance mode

Useful for reprovisioning, upgrading, or troubleshooting:
```bash
ansible-playbook -i inventory.yml playbooks/reset-to-maintenance.yml
```

This will:
- Wipe ALL disks on worker nodes first (using control plane as endpoint)
- Wipe ALL disks on control plane nodes (using their own endpoint)
- Nodes automatically reboot with wiped disks
- Nodes PXE boot into Talos maintenance mode (no OS on disk)
- Delete talos-configs/ directory to force fresh cluster

After reset, regenerate configs and redeploy:
```bash
# Optionally update Talos version in inventory.yml
ansible-playbook -i inventory.yml playbooks/generate-talos-configs.yml
ansible-playbook -i inventory.yml playbooks/deploy-talos-cluster.yml
```

### Regenerate configs for new nodes

Add nodes to inventory, then:
```bash
# Generate new node configs (existing configs won't be overwritten)
ansible-playbook -i inventory.yml playbooks/generate-talos-configs.yml

# Apply to new nodes
talosctl apply-config --insecure --nodes <new-node-ip> --file talos-configs/<node>.yaml
```

### Update to new Talos version

Edit `inventory.yml`:
```yaml
talos_version: v1.12.0
```

Re-run playbooks:
```bash
# Download new PXE images
ansible-playbook -i inventory.yml playbooks/deploy-dnsmasq.yml

# Regenerate configs (delete talos-configs/ first!)
rm -rf talos-configs/
ansible-playbook -i inventory.yml playbooks/generate-talos-configs.yml
```

## How It Works

### 1. Talos Image Factory Integration

1. **Schematic Generation**: Creates YAML schematic with your system extensions
2. **API Upload**: Uploads to `https://factory.talos.dev/schematics`
3. **ID Retrieval**: Receives unique schematic ID
4. **Image Download**: Downloads custom kernel and initramfs (always), plus raw disk installer (if `use_local_installer: true`)
5. **Local HTTP Serving** (optional): If `use_local_installer: true`, nginx serves installer image from `http://<pxe_server_address>:8080/talos-images/`
6. **PXE Configuration**: Configures boot menu for downloaded images

### 2. Configuration Generation

1. **Secret Generation**: Uses `talosctl gen secrets` (once, reuses existing)
2. **Secret Parsing**: Extracts all PKI certificates and tokens
3. **Template Rendering**: Generates individual configs per node with:
   - Unique hostname and IP from inventory
   - Proper role (controlplane/worker)
   - Network config from deployer node
   - Longhorn mount configuration
   - CNI set to "none" (for kube-ovn)
4. **Talosconfig Creation**: Generates CLI config for cluster management

### 3. Node Deployment (deploy-talos-cluster.yml)

1. **Config Application**: Applies configs to all nodes via `talosctl apply-config --insecure`
2. **Health Check - Control Plane**: Waits for all control plane nodes to pass `talosctl health` checks (up to 10 minutes per node)
3. **Health Check - Workers**: Waits for all worker nodes to pass `talosctl health` checks
4. **etcd Service Verification**: Confirms etcd service is available on first control plane
5. **Bootstrap Check**: Checks if etcd is already bootstrapped
6. **Summary**: Displays deployment status and next steps

### 4. Cluster Bootstrap (bootstrap-talos-cluster.yml)

1. **Bootstrap Check**: Verifies if etcd is already bootstrapped
2. **etcd Bootstrap**: Bootstraps etcd on first control plane node (if not already done)
3. **etcd Cluster Ready**: Waits for etcd members to be responsive
4. **API Availability**: Waits for Kubernetes API to respond
5. **Kubeconfig Extraction**: Downloads kubeconfig to `~/.kube/config`
6. **Verification**: Verifies cluster access (nodes will be NotReady without CNI)

### DHCP Whitelist

The playbook configures dnsmasq to only serve DHCP to known MAC addresses:

```
dhcp-host=52:54:00:12:34:56,192.168.1.101,node01,12h
dhcp-ignore=#known  # Ignore unknown MACs
```

### PXE Boot Flow

1. Machine sends PXE boot request
2. dnsmasq responds with DHCP offer (if MAC is whitelisted)
3. Machine downloads `pxelinux.0` via TFTP
4. Boot menu is displayed
5. Auto-boots Talos installer after 3 seconds (configurable)
6. Kernel and initramfs downloaded via TFTP
7. Talos boots in maintenance mode
8. When config is applied, installer image downloads from:
   - Local nginx HTTP server on port 8080 (if `use_local_installer: true`) - no external internet required
   - factory.talos.dev (if `use_local_installer: false`) - requires internet access
9. Installation proceeds

## Troubleshooting

### dnsmasq won't start

```bash
# Check if ports are in use
sudo netstat -tulpn | grep -E ':(67|69)'

# Verify interface exists
ip link show

# Check configuration syntax
sudo dnsmasq --test
```

### Machines not getting IP addresses

```bash
# Check dnsmasq logs for DHCP requests
sudo journalctl -u dnsmasq | grep DHCP

# Verify MAC address is correct
ip link show

# Test DHCP manually
sudo nmap --script broadcast-dhcp-discover -e eth0
```

### Cluster deployment fails during health checks

If nodes fail health checks during deployment:

```bash
# Check node status directly
talosctl health --nodes <node-ip> --endpoints <node-ip> --talosconfig talos-configs/talosconfig

# Check what's failing
talosctl services --nodes <node-ip> --endpoints <node-ip> --talosconfig talos-configs/talosconfig

# View logs for specific service
talosctl logs kubelet --nodes <node-ip> --talosconfig talos-configs/talosconfig

# Check if node finished installing
talosctl get machineconfig --nodes <node-ip> --endpoints <node-ip> --talosconfig talos-configs/talosconfig
```

Common issues:
- Node still installing to disk (wait longer)
- Network connectivity issues after reboot (check static IP configuration)
- Insufficient resources (check disk space, memory)
- Installer download timeout (check internet connectivity or use_local_installer setting)

### PXE boot fails with "ldlinux.c32 not found"

The playbook automatically installs syslinux files. If you see this error:

```bash
# Verify syslinux files
ls -la /var/lib/tftpboot/*.c32

# Re-run playbook to copy files
ansible-playbook -i inventory.yml playbooks/deploy-dnsmasq.yml
```

### Image Factory download timeouts

Large initramfs files may timeout on slow connections:

```bash
# Manual download as fallback
sudo curl -L -o /var/lib/tftpboot/kernel-amd64 \
  https://factory.talos.dev/image/{schematic-id}/v1.11.3/kernel-amd64

sudo curl -L -o /var/lib/tftpboot/initramfs-amd64.xz \
  https://factory.talos.dev/image/{schematic-id}/v1.11.3/initramfs-amd64.xz
```

The playbook retries downloads up to 3 times with 10-minute timeout.

## Advanced Configuration

### Custom TFTP root

Edit playbook variables:
```yaml
vars:
  dnsmasq_tftp_root: /srv/tftp
```

### Disable DNS functions

```yaml
dns_enabled: false
```

### Multiple boot options

Edit `templates/pxelinux.cfg.default.j2` to add additional LABEL sections:

```
LABEL rescue
    MENU LABEL Boot Rescue System
    KERNEL /rescue/vmlinuz
    APPEND initrd=/rescue/initrd.img
```

### Custom kernel arguments

```yaml
talos_extra_kernel_args:
  - vga=791
  - nomodeset
```

## Security Considerations

- **Firewall rules**: Ensure ports 67/UDP (DHCP), 69/UDP (TFTP) are allowed. Port 8080/TCP (HTTP) only needed if `use_local_installer: true`
- **Network isolation**: Use interface binding to limit dnsmasq and nginx scope
- **MAC filtering**: Only whitelisted machines receive DHCP
- **HTTP server**: nginx serves only on configured `pxe_server_address` (when `use_local_installer: true`)
- **Internet requirements**: If `use_local_installer: false`, PXE network must have internet access to factory.talos.dev
- **Regular updates**: Keep Talos version current for security patches

## Contributing

Contributions welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Test your changes thoroughly
4. Submit a pull request

## License

This project is provided as-is for educational and production use.

## Resources

- [Talos Linux Documentation](https://www.talos.dev/)
- [Talos Image Factory](https://factory.talos.dev/)
- [dnsmasq Documentation](http://www.thekelleys.org.uk/dnsmasq/doc.html)
- [Syslinux Documentation](https://wiki.syslinux.org/)

## Support

For issues and questions:
- GitHub Issues: https://github.com/aedan/talos-deploy-system/issues
- Talos Community: https://slack.dev.talos-systems.io/
