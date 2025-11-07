# Quick Start Guide

## 1. Run Interactive Setup

The easiest way to get started:

### On MAAS Server (Recommended)
```bash
python3 maas_to_inventory.py --setup
```

This will:
- Detect you're on the MAAS server
- Prompt for your MAAS username
- Automatically retrieve your API key using `sudo maas apikey --username=<user>`
- Ask for inventory settings
- Create `maas_config.ini` with secure permissions

### On Remote Machine
```bash
python3 maas_to_inventory.py --setup
```

This will:
- Prompt for MAAS URL
- Ask you to enter API key manually (get from MAAS UI or run `sudo maas apikey --username=<user>` on MAAS server)
- Ask for inventory settings
- Create `maas_config.ini`

## 2. Tag Your MAAS Machines (Optional but Recommended)

Tag control plane nodes in MAAS:

```bash
# Web UI: Machines → Select machine → Configuration → Tags → Add "controlplane"

# Or via CLI:
maas admin tag update-nodes controlplane add=node01
maas admin tag update-nodes controlplane add=node02
maas admin tag update-nodes controlplane add=node03
```

## 3. Run the Script

After setup is complete, simply run:

```bash
python3 maas_to_inventory.py
```

This will:
- Read configuration from `maas_config.ini`
- Connect to MAAS and fetch machine data
- Extract network settings from PXE subnet
- **Extract detailed network configuration** (interfaces, VLANs, bonds, routes, MTU)
- **Automatically unwrap bridges** into bonds or simple interfaces
- Generate `inventory.yml` with complete network configuration

### Alternative: Run with command line arguments (skip config file):
```bash
python3 maas_to_inventory.py \
  --maas-url http://192.168.1.5:5240/MAAS \
  --api-key "your:api:key" \
  --output inventory.yml
```

## 4. Verify the Output

```bash
cat inventory.yml
```

Look for the `pxe_hosts` section with your machines.

## 5. Secure Your Files

The setup script automatically sets secure permissions (600) on `maas_config.ini`.

You should also protect the generated inventory file:
```bash
chmod 600 inventory.yml
```

## Common Issues

### "Authentication failed"
- Check your API key format: must be `consumer:token:secret`
- Verify the key is active in MAAS

### "No machines found"
- Ensure machines are in "Ready" or "Deployed" state
- Check machine commissioning status

### "No IP address found"
- Assign static IPs to machines in MAAS
- Check subnet configuration

## Next Steps

After generating the inventory:
1. Review the `pxe_hosts` section
2. Verify IP addresses and MAC addresses
3. Check OOB management credentials
4. Update any custom settings in the inventory file
5. Use with your Ansible playbooks

## Example Output

### Simple Configuration
```yaml
all:
  hosts:
    localhost:
      pxe_hosts:
        - name: node01.pxe.local
          mac: 52:54:00:12:34:56
          ip: 192.168.1.101
          role: controlplane
          install_disk: /dev/sda
          ignored_interfaces:
            - eno2
            - eno3
          oob_type: ilo
          oob_address: 192.168.1.201
          oob_username: Administrator
          oob_password: changeme
```

### Advanced Configuration (with VLANs, Bonds, Multiple IPs)
```yaml
all:
  hosts:
    localhost:
      pxe_hosts:
        - name: node01.pxe.local
          mac: 52:54:00:12:34:56
          ip: 192.168.1.101
          role: controlplane
          install_disk: /dev/sda
          network_config:
            - interface: eno1
              addresses:
                - 192.168.1.101/24
                - 192.168.1.102/24
              mtu: 9000
              routes:
                - network: 0.0.0.0/0
                  gateway: 192.168.1.1
            - interface: eno1.100
              vlan:
                vlanId: 100
                vlanProtocol: 802.1q
              addresses:
                - 172.16.0.101/24
            - interface: bond0
              bond:
                mode: 802.3ad
                lacpRate: fast
                interfaces:
                  - eno2
                  - eno3
              addresses:
                - 10.0.0.101/24
          ignored_interfaces:
            - eno4
          oob_type: ilo
          oob_address: 192.168.1.201
          oob_username: Administrator
          oob_password: changeme
```

**Note**: The script automatically detects complex network configurations and generates the appropriate format. Bridges are automatically unwrapped into bonds or simple interfaces.

For detailed documentation, see [README.md](README.md)
