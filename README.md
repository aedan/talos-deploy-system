# Talos Deploy System - dnsmasq PXE Boot with Image Factory

Automated Ansible playbook that deploys and configures dnsmasq to provide DHCP and PXE boot services with integrated Talos Linux Image Factory support for custom image generation.

## Features

### Core Features
- **DHCP server** with static IP reservations
- **MAC address whitelist** - Only serves DHCP to known machines
- **PXE boot support** with TFTP server
- **Automated syslinux installation** and configuration

### Talos Linux Integration
- **Talos Image Factory API integration** - Automatically generates custom images
- **System extensions support** - Default: iscsi-tools and util-linux-tools
- **Automatic image downloads** - Kernel and initramfs downloaded to TFTP root
- **Version control** - Specify exact Talos version in inventory
- **Architecture support** - amd64 and arm64

### Security
- Only machines defined in inventory receive IP addresses
- Static DHCP reservations prevent IP conflicts
- Interface binding for network isolation

## Prerequisites

- **Ansible** 2.9+ installed on the control machine
- **Root/sudo access** on the target machine (localhost)
- **Internet connection** for downloading Talos images from Image Factory
- **Ubuntu/Debian or RHEL/Rocky/CentOS** Linux distribution

## Quick Start

### 1. Clone the repository

```bash
git clone https://github.com/aedan/talos-deploy-system.git
cd talos-deploy-system
```

### 2. Create your inventory

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
talos_version: v1.8.3                   # Talos version
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

### 3. Deploy

```bash
ansible-playbook -i inventory.yml deploy-dnsmasq.yml
```

The playbook will:
1. Install dnsmasq and syslinux packages
2. Configure DHCP server with your static hosts
3. Set up TFTP server
4. Generate Talos schematic with your extensions
5. Upload schematic to Image Factory
6. Download custom kernel and initramfs
7. Configure PXE boot menu
8. Start dnsmasq service

## File Structure

```
.
├── deploy-dnsmasq.yml              # Main Ansible playbook
├── inventory.yml.example           # Example inventory file
├── inventory.yml                   # Your inventory (gitignored)
├── templates/
│   ├── dnsmasq.conf.j2             # Main dnsmasq configuration
│   ├── dnsmasq-pxe.conf.j2         # PXE-specific settings
│   ├── dnsmasq-hosts.conf.j2       # Static DHCP reservations
│   ├── pxelinux.cfg.default.j2     # PXE boot menu
│   └── talos-schematic.yaml.j2     # Talos Image Factory schematic
└── README.md                       # This file
```

## Configuration

### Network Settings

```yaml
dhcp_interface: eth0                # Interface to listen on
domain: pxe.local                   # Internal domain name
dhcp_range:
  start: 192.168.1.100              # DHCP range start
  end: 192.168.1.150                # DHCP range end
lease_time: "12h"                   # DHCP lease duration
```

### Talos Image Factory

```yaml
talos_version: v1.8.3               # Talos Linux version
talos_arch: amd64                   # Architecture (amd64, arm64)
talos_extensions:                   # System extensions to include
  - siderolabs/iscsi-tools
  - siderolabs/util-linux-tools
  - siderolabs/qemu-guest-agent     # Add more as needed
talos_extra_kernel_args: []         # Optional kernel arguments
talos_download_iso: false           # Set true to download ISO
```

Available extensions: https://factory.talos.dev

### PXE Boot Options

```yaml
pxe_boot_label: talos-install           # Boot menu label
pxe_boot_menu_text: Install Talos Linux # Menu description
pxe_timeout: 30                          # Timeout (deciseconds)
pxe_default_label: talos-install         # Auto-boot option
pxe_boot_params: talos.platform=metal... # Kernel parameters
```

### Host Definitions

Each machine needs:
- **name**: FQDN or hostname
- **mac**: MAC address (XX:XX:XX:XX:XX:XX format)
- **ip**: Static IP address

```yaml
pxe_hosts:
  - name: control-plane-1.k8s.local
    mac: 52:54:00:aa:bb:cc
    ip: 192.168.1.10

  - name: worker-1.k8s.local
    mac: 52:54:00:dd:ee:ff
    ip: 192.168.1.20
```

## Usage Examples

### Deploy with default settings

```bash
ansible-playbook -i inventory.yml deploy-dnsmasq.yml
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

### Update to new Talos version

Edit `inventory.yml`:
```yaml
talos_version: v1.9.0
```

Re-run the playbook to download new images:
```bash
ansible-playbook -i inventory.yml deploy-dnsmasq.yml
```

## How It Works

### Talos Image Factory Integration

1. **Schematic Generation**: The playbook creates a YAML schematic based on your configuration
2. **API Upload**: Schematic is uploaded to `https://factory.talos.dev/schematics`
3. **ID Retrieval**: Image Factory returns a unique schematic ID
4. **Image Download**: Custom kernel and initramfs are downloaded using the schematic ID
5. **PXE Configuration**: Boot menu is configured to use the downloaded images

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

### PXE boot fails with "ldlinux.c32 not found"

The playbook automatically installs syslinux files. If you see this error:

```bash
# Verify syslinux files
ls -la /var/lib/tftpboot/*.c32

# Re-run playbook to copy files
ansible-playbook -i inventory.yml deploy-dnsmasq.yml
```

### Image Factory download timeouts

Large initramfs files may timeout on slow connections:

```bash
# Manual download as fallback
sudo curl -L -o /var/lib/tftpboot/kernel-amd64 \
  https://factory.talos.dev/image/{schematic-id}/v1.8.3/kernel-amd64

sudo curl -L -o /var/lib/tftpboot/initramfs-amd64.xz \
  https://factory.talos.dev/image/{schematic-id}/v1.8.3/initramfs-amd64.xz
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

- **Firewall rules**: Ensure ports 67/UDP (DHCP) and 69/UDP (TFTP) are allowed
- **Network isolation**: Use interface binding to limit dnsmasq scope
- **MAC filtering**: Only whitelisted machines receive DHCP
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
