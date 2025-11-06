# MAAS to Ansible Inventory Converter

This script pulls machine data from a MAAS (Metal as a Service) deployment and generates an Ansible inventory YAML file suitable for PXE/Talos Linux deployments.

## Features

- Connects to MAAS API v2.0
- Fetches all deployed/ready machines
- Extracts network configuration (MAC, IP addresses)
- Identifies installation disks
- Detects out-of-band management (iLO, iDRAC, Redfish, IPMI)
- Assigns roles based on MAAS tags
- Generates properly formatted YAML inventory

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

This will:
1. Prompt you for your MAAS URL and API key
2. Ask for inventory settings (domain, output file, etc.)
3. Create a `maas_config.ini` file with secure permissions (600)
4. Save your configuration for future runs

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

The script generates a YAML file with the following structure:

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
          oob_type: ilo
          oob_address: 192.168.1.201
          oob_username: Administrator
          oob_password: changeme
```

## Preserving Custom Configuration

To preserve your custom network, DHCP, and Talos settings:

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

## What Gets Extracted from MAAS

| Field | MAAS Source | Notes |
|-------|-------------|-------|
| `name` | `hostname` + domain | FQDN of the machine |
| `mac` | `boot_interface.mac_address` | Primary boot interface MAC |
| `ip` | `interface_set[].links[].ip_address` | First static IP found |
| `role` | `tag_names` | Based on tags (controlplane/worker) |
| `install_disk` | `blockdevice_set[]` | First physical block device |
| `oob_type` | `power_type` | Mapped to ilo/idrac/redfish/ipmi |
| `oob_address` | `power_parameters.power_address` | BMC IP address |
| `oob_username` | `power_parameters.power_user` | BMC username |
| `oob_password` | `power_parameters.power_pass` | BMC password |

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
