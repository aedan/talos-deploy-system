# dnsmasq PXE Boot Setup

This Ansible playbook deploys and configures dnsmasq to provide DHCP and PXE boot services.

## Features

- DHCP server with static IP reservations
- Only serves DHCP to known MAC addresses (secure whitelist)
- PXE boot support with TFTP server
- Configurable boot images and parameters
- All hosts defined in inventory file

## Prerequisites

- Ansible installed on the control machine
- Root/sudo access on the target machine (localhost)
- PXE boot files (pxelinux.0, kernel, initrd)

## File Structure

```
.
├── deploy-dnsmasq.yml           # Main playbook
├── inventory.yml                # Inventory with host definitions
├── templates/
│   ├── dnsmasq.conf.j2          # Main dnsmasq configuration
│   ├── dnsmasq-pxe.conf.j2      # PXE-specific settings
│   ├── dnsmasq-hosts.conf.j2    # Static DHCP reservations
│   └── pxelinux.cfg.default.j2  # PXE boot menu
└── README-dnsmasq.md            # This file
```

## Configuration

### 1. Edit inventory.yml

Update the following variables:

- `dhcp_interface`: Network interface to listen on (e.g., eth0, ens192)
- `domain`: Domain name for your network
- `dhcp_range`: IP range for DHCP (start and end)
- `pxe_boot_image`: Path to your pxelinux.0 file
- `pxe_kernel`: Kernel filename in the images directory
- `pxe_initrd`: Initial ramdisk filename
- `pxe_boot_params`: Kernel boot parameters

### 2. Define your hosts

Add each machine to the `pxe_hosts` list with:
- `name`: Hostname
- `mac`: MAC address (format: XX:XX:XX:XX:XX:XX)
- `ip`: Static IP address to assign

Example:
```yaml
pxe_hosts:
  - name: node01
    mac: 52:54:00:12:34:56
    ip: 192.168.1.101
```

### 3. Prepare PXE boot files

Before running the playbook, ensure you have:
- `pxelinux.0` (from syslinux package)
- Kernel image (vmlinuz or similar)
- Initial ramdisk (initrd.img or similar)
- `menu.c32` (from syslinux package)

Update the `pxe_boot_image` path in inventory.yml to point to your pxelinux.0 file.

## Usage

### Deploy dnsmasq

```bash
ansible-playbook -i inventory.yml deploy-dnsmasq.yml
```

### Deploy with specific tags (future enhancement)

```bash
ansible-playbook -i inventory.yml deploy-dnsmasq.yml --tags config
```

### Verify deployment

```bash
# Check dnsmasq status
sudo systemctl status dnsmasq

# View dnsmasq logs
sudo journalctl -u dnsmasq -f

# Check DHCP leases
sudo cat /var/lib/misc/dnsmasq.leases
```

## Security Features

- **MAC Address Whitelist**: Only machines in the `pxe_hosts` list will receive IP addresses
- **Static Reservations**: Each machine gets a specific, predictable IP address
- **Interface Binding**: dnsmasq only listens on the specified interface

## Troubleshooting

### dnsmasq won't start
- Check if port 67 (DHCP) or 69 (TFTP) are already in use
- Verify the network interface exists: `ip link show`
- Check logs: `sudo journalctl -u dnsmasq -n 50`

### Machines not getting IP addresses
- Verify MAC address is correct in inventory
- Check dnsmasq logs for DHCP requests
- Ensure the network interface is up and connected

### PXE boot not working
- Verify TFTP files are in `/var/lib/tftpboot/`
- Check file permissions (should be readable)
- Ensure pxelinux.0 and menu.c32 are from the same syslinux version

## Customization

### Change TFTP root directory

Edit the playbook variable:
```yaml
dnsmasq_tftp_root: /srv/tftp
```

### Add multiple PXE boot options

Edit `templates/pxelinux.cfg.default.j2` to add more LABEL sections.

### Disable DNS functions

Set in inventory.yml:
```yaml
dns_enabled: false
```

## Example: Setting up for Talos Linux

```yaml
pxe_boot_image: /usr/lib/syslinux/pxelinux.0
pxe_kernel: vmlinuz-talos
pxe_initrd: initramfs-talos.xz
pxe_boot_label: talos-install
pxe_boot_menu_text: Install Talos Linux
pxe_boot_params: talos.platform=metal console=ttyS0
```

## License

This configuration is provided as-is for educational and production use.
