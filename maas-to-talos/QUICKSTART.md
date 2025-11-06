# Quick Start Guide

## 1. Get Your MAAS API Key

### Option A: Web UI
1. Log into MAAS: `http://your-maas-server:5240/MAAS`
2. Click your username (top right) → "API keys"
3. Copy the key (format: `xxxxx:xxxxx:xxxxx`)

### Option B: Command Line (on MAAS server)
```bash
sudo maas apikey --username=admin
```

## 2. Configure the Script

```bash
# Copy example config
cp maas_config.ini.example maas_config.ini

# Edit with your details
nano maas_config.ini
```

Update these fields:
```ini
[maas]
url = http://192.168.1.5:5240/MAAS
api_key = your:api:key

[inventory]
domain = pxe.local
output = inventory.yml
```

## 3. Tag Your MAAS Machines (Optional but Recommended)

Tag control plane nodes in MAAS:

```bash
# Web UI: Machines → Select machine → Configuration → Tags → Add "controlplane"

# Or via CLI:
maas admin tag update-nodes controlplane add=node01
maas admin tag update-nodes controlplane add=node02
maas admin tag update-nodes controlplane add=node03
```

## 4. Run the Script

### Using the convenience wrapper:
```bash
./run.sh
```

### Or directly with Python:
```bash
python3 maas_to_inventory.py
```

### Or with command line arguments (no config file):
```bash
python3 maas_to_inventory.py \
  --maas-url http://192.168.1.5:5240/MAAS \
  --api-key "your:api:key" \
  --output inventory.yml
```

## 5. Verify the Output

```bash
cat inventory.yml
```

Look for the `pxe_hosts` section with your machines.

## 6. Secure Your Files

```bash
# Protect config file
chmod 600 maas_config.ini

# Protect inventory file
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
          oob_type: ilo
          oob_address: 192.168.1.201
          oob_username: Administrator
          oob_password: changeme
```

For detailed documentation, see [README.md](README.md)
