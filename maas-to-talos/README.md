# MAAS to Ansible Inventory Converter

This script pulls machine data from a MAAS (Metal as a Service) deployment and generates an Ansible inventory YAML file suitable for PXE/Talos Linux deployments.

## Features

- Connects to MAAS API v2.0
- Fetches all deployed/ready machines
- **Advanced network configuration extraction:**
  - Automatically extracts full network configuration from MAAS
  - Supports multiple interfaces with multiple IP addresses
  - VLAN configuration replication
  - Bond/LAG configuration with LACP support
  - Bridge unwrapping (converts bridges to bonds or simple interfaces)
  - Static routes and MTU settings
  - Ignored interfaces detection
- Identifies installation disks
- Detects out-of-band management (iLO, iDRAC, Redfish, IPMI)
- Assigns roles based on MAAS tags
- Generates properly formatted YAML inventory for Talos deployment

## Prerequisites

- Python 3.6 or higher
- Access to a MAAS server (tested with MAAS 3.2.11)
- MAAS API key

## Installation

1. Install Python dependencies:
```bash
pip install -r requirements.txt
```

Or install manually:
```bash
pip install requests PyYAML
```

## Getting Your MAAS API Key

### Method 1: Web UI
1. Log in to MAAS web interface
2. Click on your username in the top right corner
3. Select "API keys" from the dropdown
4. Click "Generate API key" if you don't have one
5. Copy the key (format: `consumer_key:token_key:token_secret`)

### Method 2: Command Line (on MAAS server)
```bash
sudo maas apikey --username=admin
```

Replace `admin` with your MAAS username.

## Usage

### Quick Start - Interactive Setup

The easiest way to get started is with the interactive setup:

```bash
python3 maas_to_inventory.py --setup
```

**When running on the MAAS server itself:**
1. Prompts for your MAAS URL (defaults to localhost)
2. Prompts for your MAAS username
3. Automatically retrieves/generates API key using `sudo maas apikey --username=<user>`
4. Asks for inventory settings (domain, output file, etc.)
5. Creates a `maas_config.ini` file with secure permissions (600)

**When running on a remote machine:**
1. Prompts for your MAAS URL
2. Prompts you to manually enter an API key
3. Asks for inventory settings
4. Creates the configuration file

After setup, simply run without arguments:
```bash
python3 maas_to_inventory.py
```

### Basic Usage (Command Line)

```bash
python3 maas_to_inventory.py \
  --maas-url http://192.168.1.5:5240/MAAS \
  --api-key "your:api:key"
```

### With Template File

If you have an existing inventory template with custom settings:

```bash
python3 maas_to_inventory.py \
  --maas-url http://192.168.1.5:5240/MAAS \
  --api-key "your:api:key" \
  --template inventory_template.yml \
  --output inventory.yml
```

### Custom Domain and Tags

```bash
python3 maas_to_inventory.py \
  --maas-url http://192.168.1.5:5240/MAAS \
  --api-key "your:api:key" \
  --domain cluster.local \
  --controlplane-tag master \
  --output production_inventory.yml
```

### Full Example

```bash
python3 maas_to_inventory.py \
  --maas-url http://maas.example.com:5240/MAAS \
  --api-key "QNsZ8KPvwX4m2dJ7cR:hG9kL3nM5pQ8rT2vW:xY4zB6cD8fH2jK5mN7pR9tV" \
  --template inventory_template.yml \
  --output inventory.yml \
  --domain pxe.local \
  --controlplane-tag controlplane
```

## Command Line Arguments

| Argument | Required | Default | Description |
|----------|----------|---------|-------------|
| `--maas-url` | Yes | - | MAAS server URL (e.g., http://192.168.1.5:5240/MAAS) |
| `--api-key` | Yes | - | MAAS API key (format: consumer:token:secret) |
| `--template` | No | - | Path to template YAML file to preserve custom settings |
| `--output` | No | `inventory.yml` | Output file path |
| `--domain` | No | `pxe.local` | Domain name to append to hostnames |
| `--controlplane-tag` | No | `controlplane` | MAAS tag to identify control plane nodes |

## MAAS Machine Requirements

For the script to properly extract machine information:

1. **Machines must be in one of these states:**
   - Deployed
   - Ready
   - Allocated
   - Deploying

2. **Network Configuration:**
   - At least one interface with a static IP assignment
   - MAC address available on boot interface

3. **Tags (for role assignment):**
   - Tag machines with `controlplane`, `control-plane`, `master`, or `cp` for control plane nodes
   - All other machines are assigned the `worker` role

## Tagging Machines in MAAS

To tag machines as control plane nodes:

### Web UI
1. Go to Machines
2. Select a machine
3. Click "Configuration" tab
4. Under "Tags", add `controlplane`
5. Save

### Command Line
```bash
maas admin tag update-nodes controlplane add=<machine-hostname>
```

## Output Structure

The script generates a YAML file with one of two formats:

### Simple Networking (Backward Compatible)

For machines with basic network configuration:

```yaml
all:
  hosts:
    localhost:
      ansible_connection: local
      domain: pxe.local
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

### Advanced Networking (NEW!)

For machines with complex network configuration (multiple IPs, VLANs, bonds, bridges):

```yaml
all:
  hosts:
    localhost:
      ansible_connection: local
      domain: pxe.local
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

## Preserving Custom Configuration

To preserve your custom network, DHCP, HTTP server, and Talos settings:

1. Save your existing inventory file as a template
2. Use the `--template` option to merge MAAS data with your settings:

```bash
python3 maas_to_inventory.py \
  --maas-url http://192.168.1.5:5240/MAAS \
  --api-key "your:api:key" \
  --template my_custom_inventory.yml \
  --output inventory.yml
```

The script will preserve all your custom settings and only update the `pxe_hosts` section.

**Custom settings preserved:**
- Network configuration (`dhcp_interface`, `pxe_server_address`, DHCP ranges, DNS)
- Talos settings (`talos_version`, `talos_extensions`, `talos_cluster_name`, etc.)
- PXE boot configuration
- All other variables in the template

## Troubleshooting

### "No MAC address found"
- Ensure the machine has at least one physical network interface configured in MAAS
- Check that the machine has been commissioned

### "No IP address found"
- Verify that the machine has a static IP assignment in MAAS
- Check subnet configuration in MAAS

### Authentication Errors
- Verify your API key format: `consumer_key:token_key:token_secret`
- Check that the API key hasn't been revoked
- Ensure your MAAS user has appropriate permissions

### Connection Errors
- Verify the MAAS URL includes `/MAAS` at the end
- Check network connectivity to the MAAS server
- Verify the MAAS server is running: `sudo systemctl status maas-rackd maas-regiond`

## Advanced Networking Features

### Automatic Network Configuration Extraction

The script now automatically extracts comprehensive network configuration from MAAS and generates Talos-compatible network settings. This includes:

#### Multiple Interfaces with Multiple IPs
- Each interface can have multiple static IP addresses
- All addresses are preserved in the Talos configuration

#### VLAN Support
- VLAN interfaces (e.g., `eno1.100`) are automatically detected
- VLAN ID and protocol (802.1q) are preserved
- IP addresses on VLANs are maintained

#### Bond/LAG Support
- Bond interfaces configured in MAAS are replicated in Talos
- Bond mode (e.g., 802.3ad, active-backup) is preserved
- LACP rate is set for 802.3ad bonds
- Member interfaces are correctly configured

#### Bridge Unwrapping (Special Handling)

MAAS often uses bridges for VM networking, but Talos doesn't require bridges for most use cases. The script intelligently handles bridges:

- **Bridge with multiple interfaces** → Converted to a Talos bond (802.3ad LACP)
  - Example: `br0` containing `eno1` + `eno2` → `bond0` with members `eno1`, `eno2`

- **Bridge with single interface** → Converted to simple interface
  - Example: `br0` containing `eno1` → Configuration applied directly to `eno1`

- **IP addresses on bridges** → Transferred to the bond or interface
  - All static IPs configured on the bridge are assigned to the resulting interface/bond

This ensures your machines have the same network connectivity in Talos as they had in MAAS, but using Talos-native configuration.

#### Static Routes and MTU
- Custom MTU settings are preserved per interface
- Static routes are maintained
- Default gateway is automatically configured on the primary interface

#### Ignored Interfaces
- Interfaces without IP addresses are automatically added to the ignored list
- Disabled interfaces are excluded from configuration

### How It Works

1. **Network Discovery**: Script fetches full interface details from MAAS
2. **Bridge Analysis**: Identifies bridges and their member interfaces
3. **Configuration Extraction**: Extracts IPs, VLANs, bonds, routes, MTU for each interface
4. **Bridge Conversion**: Converts bridges to bonds or simple interfaces as appropriate
5. **Talos Format**: Generates proper Talos network configuration in `network_config` section
6. **Template Application**: Ansible templates apply this configuration when generating machine files

### Compatibility

The script maintains **backward compatibility**:
- Simple single-interface configurations still work with the basic format
- Complex configurations use the new `network_config` structure
- Both formats are supported by the Talos templates

## What Gets Extracted from MAAS

| Field | MAAS Source | Notes |
|-------|-------------|-------|
| `name` | `hostname` + domain | FQDN of the machine |
| `mac` | `boot_interface.mac_address` | Primary boot interface MAC |
| `ip` | `interface_set[].links[].ip_address` | First static IP found (for backward compat) |
| `role` | `tag_names` | Based on tags (controlplane/worker) |
| `install_disk` | `blockdevice_set[]` | First physical block device |
| `network_config` | `interface_set[]` | **NEW!** Detailed network configuration: |
| `network_config[].interface` | `interface.name` | Interface name (e.g., eno1, bond0) |
| `network_config[].addresses` | `links[].ip_address` + `subnet.cidr` | All static IPs with CIDR notation |
| `network_config[].mtu` | `interface.effective_mtu` | MTU setting per interface |
| `network_config[].vlan` | `interface.vlan.vid` | VLAN configuration (for VLAN interfaces) |
| `network_config[].bond` | `interface.params.bond_mode` + `parents` | Bond configuration with mode and members |
| `network_config[].routes` | `subnet.gateway_ip` | Static routes (default gateway) |
| `ignored_interfaces` | `interface_set[]` (no IPs) | Interfaces without IP addresses |
| `oob_type` | `power_type` | Mapped to ilo/idrac/redfish/ipmi |
| `oob_address` | `power_parameters.power_address` | BMC IP address |
| `oob_username` | `power_parameters.power_user` | BMC username |
| `oob_password` | `power_parameters.power_pass` | BMC password |

**Note on Bridges**: Bridge interfaces are automatically unwrapped and converted to bonds (if multiple members) or simple interfaces (if single member).

## Security Considerations

⚠️ **Important:** The generated inventory file contains sensitive information:
- OOB/BMC passwords
- IP addresses
- Network topology

**Recommendations:**
1. Protect the inventory file with appropriate permissions:
   ```bash
   chmod 600 inventory.yml
   ```

2. Use Ansible Vault to encrypt sensitive data:
   ```bash
   ansible-vault encrypt inventory.yml
   ```

3. Store in a secure location
4. Never commit to public repositories without encryption

## Advanced Usage

### Filtering Machines

To only include machines with specific tags, modify the script or pre-filter in MAAS by deploying only the machines you want to include.

### Custom Role Mapping

Edit the `determine_role()` function in the script to implement custom logic:

```python
def determine_role(machine: Dict, tags: List[str]) -> str:
    machine_tags = [tag.lower() for tag in machine.get('tag_names', [])]
    
    # Your custom logic here
    if 'gpu-node' in machine_tags:
        return 'gpu-worker'
    elif 'storage' in machine_tags:
        return 'storage'
    # ... etc
```

## Contributing

Feel free to extend this script for your specific needs. Common extensions:
- Custom disk selection logic
- Multiple network interface handling
- Additional metadata extraction
- Integration with other tools

## Support

For MAAS-specific issues, refer to:
- [MAAS Documentation](https://maas.io/docs)
- [MAAS API Documentation](https://maas.io/docs/api)

For script issues:
- Check Python version: `python3 --version`
- Verify dependencies: `pip list | grep -E 'requests|PyYAML'`
- Enable debug output by adding print statements

## License

MIT License - Feel free to modify and distribute as needed.
