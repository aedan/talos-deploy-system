# Usage Examples

## Example 1: Interactive Setup (Recommended)

### On MAAS Server

1. **Run interactive setup:**
```bash
python3 maas_to_inventory.py --setup
```

2. **Interactive prompts:**
```
============================================================
MAAS Configuration Setup
============================================================

✓ MAAS CLI detected - can automatically retrieve API key

MAAS Server URL
  Default: http://localhost:5240/MAAS (running on MAAS server)
  Or enter custom URL (e.g., http://192.168.1.5:5240/MAAS)
  Enter MAAS URL [http://localhost:5240/MAAS]:

MAAS Authentication
  Enter your MAAS username to retrieve/generate API key
  MAAS Username: admin

Retrieving API key for user 'admin'...
(This will run: sudo maas apikey --username=admin)
✓ API key retrieved successfully

Inventory Settings
  Domain name for hosts [pxe.local]:
  Output inventory file [inventory.yml]:
  Template file (optional, press Enter to skip):
  MAAS tag for controlplane nodes [controller]:

Configuration Summary:
  MAAS URL: http://localhost:5240/MAAS
  API Key: ******************** (hidden)
  Domain: pxe.local
  Output: inventory.yml
  Template: (none)
  Controlplane Tag: controller

Save this configuration? [Y/n]: y

✓ Configuration saved to maas_config.ini
  File permissions set to 600 (owner read/write only)
```

3. **Run the script:**
```bash
python3 maas_to_inventory.py
```

4. **Output:**
```
Connecting to MAAS at http://192.168.1.5:5240/MAAS...
Fetching machines from MAAS...
Found 6 machines
Processing node01...
Processing node02...
Processing node03...
Processing worker01...
Processing worker02...
Processing worker03...

Writing inventory to inventory.yml...
Successfully generated inventory with 6 hosts

Summary:
  Control plane nodes: 3
  Worker nodes: 3
```

---

## Example 2: Using Template to Preserve Custom Settings

If you have existing custom configuration in your inventory file:

```bash
python3 maas_to_inventory.py \
  --template inventory_template.yml \
  --output inventory.yml
```

This will:
- Keep all your custom Talos settings
- Keep network configuration
- Keep DHCP settings
- **Only update** the `pxe_hosts` section with MAAS data

---

## Example 3: Command Line Only (No Config File)

```bash
python3 maas_to_inventory.py \
  --maas-url http://192.168.1.5:5240/MAAS \
  --api-key "QNsZ8KPvwX:hG9kL3nM5p:xY4zB6cD8f" \
  --domain cluster.local \
  --output production-inventory.yml \
  --controlplane-tag master
```

---

## Example 4: Manual Configuration (Alternative to Interactive Setup)

If you prefer to manually edit the config file:

```bash
# Copy example config
cp maas_config.ini.example maas_config.ini

# Get your API key
sudo maas apikey --username=admin

# Edit config file
nano maas_config.ini
```

Edit `maas_config.ini`:
```ini
[maas]
url = http://192.168.1.5:5240/MAAS
api_key = QNsZ8KPvwX:hG9kL3nM5p:xY4zB6cD8f

[inventory]
domain = pxe.local
output = inventory.yml
controlplane_tag = controller
```

Then run:
```bash
python3 maas_to_inventory.py
```

---

## Example 5: Different Environments

### Development Environment
```bash
python3 maas_to_inventory.py \
  --config dev_maas_config.ini \
  --output dev-inventory.yml
```

### Production Environment
```bash
python3 maas_to_inventory.py \
  --config prod_maas_config.ini \
  --output prod-inventory.yml
```

---

## Sample Output

Given MAAS machines:
- node01 (Tagged: controlplane) - 192.168.1.101 - iLO
- node02 (Tagged: controlplane) - 192.168.1.102 - iLO  
- node03 (Tagged: controlplane) - 192.168.1.103 - iDRAC
- worker01 - 192.168.1.111 - iLO
- worker02 - 192.168.1.112 - Redfish
- worker03 - 192.168.1.113 - IPMI

Generated `inventory.yml`:

```yaml
all:
  hosts:
    localhost:
      ansible_connection: local
      domain: pxe.local
      pxe_hosts:
        - name: node01.pxe.local
          mac: 52:54:00:aa:bb:01
          ip: 192.168.1.101
          role: controlplane
          install_disk: /dev/sda
          oob_type: ilo
          oob_address: 192.168.1.201
          oob_username: Administrator
          oob_password: changeme123
        
        - name: node02.pxe.local
          mac: 52:54:00:aa:bb:02
          ip: 192.168.1.102
          role: controlplane
          install_disk: /dev/sda
          oob_type: ilo
          oob_address: 192.168.1.202
          oob_username: Administrator
          oob_password: changeme123
        
        - name: node03.pxe.local
          mac: 52:54:00:aa:bb:03
          ip: 192.168.1.103
          role: controlplane
          install_disk: /dev/nvme0n1
          oob_type: idrac
          oob_address: 192.168.1.203
          oob_username: root
          oob_password: calvin
        
        - name: worker01.pxe.local
          mac: 52:54:00:aa:bb:11
          ip: 192.168.1.111
          role: worker
          install_disk: /dev/sda
          oob_type: ilo
          oob_address: 192.168.1.211
          oob_username: Administrator
          oob_password: changeme123
        
        - name: worker02.pxe.local
          mac: 52:54:00:aa:bb:12
          ip: 192.168.1.112
          role: worker
          install_disk: /dev/sda
          oob_type: redfish
          oob_address: 192.168.1.212
          oob_username: admin
          oob_password: password123
        
        - name: worker03.pxe.local
          mac: 52:54:00:aa:bb:13
          ip: 192.168.1.113
          role: worker
          install_disk: /dev/sda
          oob_type: ipmi
          oob_address: 192.168.1.213
          oob_username: ADMIN
          oob_password: ADMIN
```

---

## Example 6: Advanced Networking - Multiple Interfaces and VLANs

### MAAS Configuration

Given MAAS machines with complex network setups:
- **node01**: Primary interface `eno1` with 192.168.1.101, VLAN interface `eno1.100` with 172.16.0.101
- **node02**: Bond interface `bond0` (containing `eno2` + `eno3`) with 10.0.0.102
- **node03**: Bridge `br0` (containing `eno1` + `eno2`) with 192.168.1.103

### Running the Script

```bash
python3 maas_to_inventory.py
```

### Generated Inventory with Advanced Networking

```yaml
all:
  hosts:
    localhost:
      ansible_connection: local
      domain: pxe.local
      network_gateway: 192.168.1.1
      network_netmask: 24
      network_nameservers:
        - 8.8.8.8
        - 1.1.1.1
      pxe_hosts:
        # Node with VLAN
        - name: node01.pxe.local
          mac: 52:54:00:aa:bb:01
          ip: 192.168.1.101
          role: controlplane
          install_disk: /dev/sda
          network_config:
            - interface: eno1
              addresses:
                - 192.168.1.101/24
              mtu: 1500
              routes:
                - network: 0.0.0.0/0
                  gateway: 192.168.1.1
            - interface: eno1.100
              vlan:
                vlanId: 100
                vlanProtocol: 802.1q
              addresses:
                - 172.16.0.101/24
              mtu: 1500
          ignored_interfaces:
            - eno2
            - eno3

        # Node with Bond
        - name: node02.pxe.local
          mac: 52:54:00:aa:bb:02
          ip: 10.0.0.102
          role: controlplane
          install_disk: /dev/sda
          network_config:
            - interface: eno1
              addresses:
                - 192.168.1.102/24
              mtu: 1500
              routes:
                - network: 0.0.0.0/0
                  gateway: 192.168.1.1
            - interface: bond0
              bond:
                mode: 802.3ad
                lacpRate: fast
                interfaces:
                  - eno2
                  - eno3
              addresses:
                - 10.0.0.102/24
              mtu: 1500

        # Node with Bridge (automatically unwrapped to bond)
        - name: node03.pxe.local
          mac: 52:54:00:aa:bb:03
          ip: 192.168.1.103
          role: worker
          install_disk: /dev/sda
          network_config:
            - interface: bond-br0  # Bridge converted to bond
              bond:
                mode: 802.3ad
                lacpRate: fast
                interfaces:
                  - eno1
                  - eno2
              addresses:
                - 192.168.1.103/24
              mtu: 1500
              routes:
                - network: 0.0.0.0/0
                  gateway: 192.168.1.1
          ignored_interfaces:
            - eno3
            - eno4
```

**Key Points:**
- VLAN interfaces are preserved with proper vlanId configuration
- Bond interfaces maintain their mode and member configuration
- **Bridges are automatically unwrapped**:
  - `br0` with multiple members (`eno1`, `eno2`) → Converted to `bond-br0` with 802.3ad LACP
  - IP address from bridge transferred to the bond
- Interfaces without IPs are added to `ignored_interfaces`

---

## Example 7: Bridge Unwrapping Examples

### Scenario 1: Bridge with Single Interface

**MAAS Configuration:**
- Bridge: `br0`
- Members: `eno1` only
- IP: 192.168.1.101/24

**Generated Config:**
```yaml
network_config:
  - interface: eno1  # Bridge unwrapped to simple interface
    addresses:
      - 192.168.1.101/24
    routes:
      - network: 0.0.0.0/0
        gateway: 192.168.1.1
```

### Scenario 2: Bridge with Multiple Interfaces

**MAAS Configuration:**
- Bridge: `br0`
- Members: `eno1`, `eno2`
- IP: 192.168.1.101/24

**Generated Config:**
```yaml
network_config:
  - interface: bond-br0  # Bridge converted to bond
    bond:
      mode: 802.3ad
      lacpRate: fast
      interfaces:
        - eno1
        - eno2
    addresses:
      - 192.168.1.101/24
    routes:
      - network: 0.0.0.0/0
        gateway: 192.168.1.1
```

---

## Filtering and Customization

### Only Include Specific Machines

In MAAS, deploy only the machines you want to include. The script only processes machines in these states:
- Deployed
- Ready
- Allocated
- Deploying

### Custom Role Assignment

Edit the `determine_role()` function in the script:

```python
def determine_role(machine: Dict, tags: List[str]) -> str:
    machine_tags = [tag.lower() for tag in machine.get('tag_names', [])]
    
    # Custom logic
    if 'master' in machine_tags or 'control' in machine_tags:
        return 'controlplane'
    elif 'storage' in machine_tags:
        return 'storage'
    else:
        return 'worker'
```

### Multiple Network Interfaces

The script automatically handles multiple interfaces with advanced configuration:

1. **All configured interfaces** - Extracted with full configuration (IPs, MTU, routes)
2. **VLANs** - Automatically detected and configured with proper VLAN ID
3. **Bonds** - Extracted with mode and member interfaces
4. **Bridges** - Automatically unwrapped to bonds or simple interfaces
5. **Ignored interfaces** - Interfaces without IPs are added to `ignored_interfaces`

**Simple Configuration Example** (single interface with IP):
```yaml
- name: node01.pxe.local
  mac: 52:54:00:aa:bb:01
  ip: 192.168.1.101
  role: controlplane
  install_disk: /dev/sda
  ignored_interfaces:
    - eno2
    - eno3
    - eno4
```

**Advanced Configuration Example** (multiple interfaces, VLANs, bonds):
```yaml
- name: node02.pxe.local
  mac: 52:54:00:aa:bb:02
  ip: 192.168.1.102
  role: controlplane
  install_disk: /dev/sda
  network_config:
    - interface: eno1
      addresses:
        - 192.168.1.102/24
      mtu: 1500
      routes:
        - network: 0.0.0.0/0
          gateway: 192.168.1.1
    - interface: eno1.100
      vlan:
        vlanId: 100
        vlanProtocol: 802.1q
      addresses:
        - 172.16.0.102/24
    - interface: bond0
      bond:
        mode: 802.3ad
        lacpRate: fast
        interfaces:
          - eno2
          - eno3
      addresses:
        - 10.0.0.102/24
  ignored_interfaces:
    - eno4
```

The script automatically chooses the appropriate format based on network complexity.

---

## Integration with Ansible

After generating the inventory, use it with Ansible:

```bash
# Validate inventory
ansible-inventory -i inventory.yml --list

# Use with playbook
ansible-playbook -i inventory.yml deploy-talos.yml

# Target specific hosts
ansible-playbook -i inventory.yml deploy-talos.yml --limit controlplane
```

---

## Troubleshooting

### Machine Not Appearing

Check machine status in MAAS:
```bash
maas admin machines read | jq -r '.[] | "\(.hostname): \(.status_name)"'
```

### Wrong IP Address

The script extracts the first static IP. To use a different IP:
1. Change the IP assignment in MAAS to your preferred subnet
2. Re-run the script

### Missing OOB Credentials

Configure power management in MAAS:
```bash
# Example: Configure iLO
maas admin machine set-power-parameters <system-id> \
  power_type=hpilo \
  power_address=192.168.1.201 \
  power_user=Administrator \
  power_pass=changeme
```

---

## Security Best Practices

```bash
# Protect configuration
chmod 600 maas_config.ini
chown $USER:$USER maas_config.ini

# Protect inventory
chmod 600 inventory.yml

# Use Ansible Vault for production
ansible-vault encrypt inventory.yml

# Or encrypt just the sensitive vars
ansible-vault encrypt_string 'changeme123' --name 'oob_password'
```

---

## Continuous Updates

Set up a cron job to regularly sync from MAAS:

```bash
# Add to crontab
0 */6 * * * cd /path/to/script && ./run.sh >> /var/log/maas-sync.log 2>&1
```

This updates the inventory every 6 hours.
