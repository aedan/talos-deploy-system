#!/usr/bin/env python3
"""
MAAS to Ansible Inventory Converter
Pulls machine data from MAAS and generates a YAML inventory file for PXE/Talos deployment
"""

import requests
import yaml
import argparse
import sys
import os
import getpass
import subprocess
import shutil
from typing import Dict, List, Any
from configparser import ConfigParser
from collections import Counter


class MAASClient:
    """Client for interacting with MAAS"""

    def __init__(self, maas_url: str, api_key: str):
        """
        Initialize MAAS client

        Args:
            maas_url: MAAS server URL (e.g., http://maas.example.com:5240/MAAS)
            api_key: MAAS API key
        """
        self.maas_url = maas_url.rstrip('/')
        self.api_key = api_key
        self.use_cli = shutil.which('maas') is not None
        self.profile_name = 'talos-deploy'

        # If CLI is available, create/update login profile
        if self.use_cli:
            self._setup_cli_profile()
        else:
            # Fallback to HTTP API
            self.session = requests.Session()
            self.session.headers.update({
                'Authorization': f'OAuth oauth_version=1.0, oauth_signature_method=PLAINTEXT, oauth_consumer_key={api_key.split(":")[0]}, oauth_token={api_key.split(":")[1]}, oauth_signature=&{api_key.split(":")[2]}'
            })

    def _setup_cli_profile(self):
        """Setup MAAS CLI profile for authentication"""
        try:
            # Login/update profile
            result = subprocess.run(
                ['maas', 'login', self.profile_name, self.maas_url, self.api_key],
                capture_output=True,
                text=True,
                check=False
            )
            if result.returncode != 0:
                print(f"Warning: Failed to setup MAAS CLI profile: {result.stderr}")
                print("Falling back to HTTP API")
                self.use_cli = False
        except Exception as e:
            print(f"Warning: Failed to setup MAAS CLI: {e}")
            print("Falling back to HTTP API")
            self.use_cli = False

    def _run_cli_command(self, resource: str) -> Any:
        """Run a MAAS CLI command and return JSON result"""
        try:
            result = subprocess.run(
                ['maas', self.profile_name, resource, 'read'],
                capture_output=True,
                text=True,
                check=True
            )
            return yaml.safe_load(result.stdout)
        except subprocess.CalledProcessError as e:
            print(f"Error running MAAS CLI command: {e}", file=sys.stderr)
            print(f"stderr: {e.stderr}", file=sys.stderr)
            sys.exit(1)
        except Exception as e:
            print(f"Error: {e}", file=sys.stderr)
            sys.exit(1)

    def _make_request(self, endpoint: str, method: str = 'GET', params: Dict = None) -> Any:
        """Make an API request to MAAS via HTTP"""
        url = f"{self.maas_url}/api/2.0/{endpoint}"

        try:
            if method == 'GET':
                response = self.session.get(url, params=params)
            else:
                response = self.session.request(method, url, data=params)

            response.raise_for_status()
            return response.json()
        except requests.exceptions.RequestException as e:
            print(f"Error making request to MAAS: {e}", file=sys.stderr)
            sys.exit(1)

    def get_machines(self) -> List[Dict]:
        """Fetch all machines from MAAS"""
        if self.use_cli:
            return self._run_cli_command('machines')
        return self._make_request('machines/')

    def get_machine_details(self, system_id: str) -> Dict:
        """Fetch detailed information for a specific machine"""
        if self.use_cli:
            return self._run_cli_command(f'machine {system_id}')
        return self._make_request(f'machines/{system_id}/')

    def get_subnets(self) -> List[Dict]:
        """Fetch all subnets from MAAS"""
        if self.use_cli:
            return self._run_cli_command('subnets')
        return self._make_request('subnets/')


def find_pxe_subnet(subnets: List[Dict]) -> Dict:
    """
    Find the PXE boot subnet (the one with DHCP enabled)

    Args:
        subnets: List of subnet data from MAAS

    Returns:
        PXE subnet dict or empty dict if not found
    """
    for subnet in subnets:
        # Check if DHCP is enabled on this subnet
        if subnet.get('managed', False) or subnet.get('allow_proxy', False):
            return subnet

    # If no DHCP subnet found, return first available subnet as fallback
    if subnets:
        print("Warning: No DHCP-enabled subnet found, using first subnet as fallback")
        return subnets[0]

    return {}


def extract_network_settings(subnet: Dict) -> Dict:
    """
    Extract network settings from PXE subnet

    Args:
        subnet: Subnet data from MAAS

    Returns:
        Dict with gateway, netmask, and nameservers
    """
    settings = {}

    if subnet:
        # Extract gateway
        settings['network_gateway'] = subnet.get('gateway_ip', '')

        # Extract netmask from CIDR
        cidr = subnet.get('cidr', '')
        if '/' in cidr:
            settings['network_netmask'] = int(cidr.split('/')[-1])
        else:
            settings['network_netmask'] = 24  # default

        # Extract DNS servers
        dns_servers = subnet.get('dns_servers', [])
        if dns_servers:
            settings['network_nameservers'] = dns_servers
        else:
            # Fallback to common public DNS
            settings['network_nameservers'] = ['8.8.8.8', '1.1.1.1']

    return settings


def extract_primary_mac(machine: Dict) -> str:
    """Extract primary MAC address from machine"""
    boot_interface = machine.get('boot_interface')
    if boot_interface and 'mac_address' in boot_interface:
        return boot_interface['mac_address']
    
    # Fallback to first interface
    interfaces = machine.get('interface_set', [])
    if interfaces:
        return interfaces[0].get('mac_address', '')
    
    return ''


def extract_boot_interface_name(machine: Dict) -> str:
    """Extract the boot interface name from machine"""
    boot_interface = machine.get('boot_interface')
    if boot_interface and 'name' in boot_interface:
        return boot_interface['name']

    # Fallback to first physical interface
    for iface in machine.get('interface_set', []):
        if iface.get('type') == 'physical' and iface.get('name'):
            return iface['name']

    return 'eth0'  # default fallback


def extract_primary_ip(machine: Dict) -> str:
    """Extract primary IP address from machine"""
    # Try boot interface first
    boot_interface = machine.get('boot_interface')
    if boot_interface:
        links = boot_interface.get('links', [])
        for link in links:
            if link.get('mode') == 'static' and link.get('ip_address'):
                return link['ip_address']
    
    # Fallback to any static IP
    for interface in machine.get('interface_set', []):
        for link in interface.get('links', []):
            if link.get('mode') == 'static' and link.get('ip_address'):
                return link['ip_address']
    
    return ''


def extract_install_disk(machine: Dict) -> str:
    """Extract the primary installation disk"""
    # Get physical block devices
    block_devices = machine.get('blockdevice_set', [])
    
    # Try to find boot disk
    for device in block_devices:
        if device.get('type') == 'physical':
            # MAAS typically uses /dev/disk/by-id/ paths, convert to /dev/sdX
            name = device.get('name', '')
            if name.startswith('/dev/'):
                return name
            else:
                return f"/dev/{name}"
    
    # Default fallback
    return '/dev/sda'


def determine_role(machine: Dict, controlplane_tag: str) -> str:
    """
    Determine the role (controlplane or worker) based on machine tags

    Args:
        machine: Machine data from MAAS
        controlplane_tag: Tag to check for controlplane designation

    Returns:
        'controlplane' or 'worker'
    """
    machine_tags = [tag.lower() for tag in machine.get('tag_names', [])]

    # Check for the specified controlplane tag
    if controlplane_tag.lower() in machine_tags:
        return 'controlplane'

    # Also check for common alternative tags
    common_controlplane_tags = ['controlplane', 'control-plane', 'master', 'cp', 'controller']
    for tag in common_controlplane_tags:
        if tag in machine_tags:
            return 'controlplane'

    return 'worker'


def extract_oob_info(machine: Dict) -> Dict[str, str]:
    """Extract out-of-band management information"""
    power_type = machine.get('power_type', '')
    power_params = machine.get('power_parameters', {})
    
    oob_info = {}
    
    # Map MAAS power types to OOB types
    if 'ipmi' in power_type:
        oob_info['oob_type'] = 'ipmi'
    elif 'virsh' in power_type:
        oob_info['oob_type'] = 'virsh'
    elif 'hmc' in power_type:
        oob_info['oob_type'] = 'hmc'
    elif 'ilo' in power_type.lower() or 'hpilo' in power_type.lower():
        oob_info['oob_type'] = 'ilo'
    elif 'idrac' in power_type.lower() or 'drac' in power_type.lower():
        oob_info['oob_type'] = 'idrac'
    elif 'redfish' in power_type.lower():
        oob_info['oob_type'] = 'redfish'
    else:
        oob_info['oob_type'] = power_type or 'manual'
    
    # Extract connection details
    if 'power_address' in power_params:
        oob_info['oob_address'] = power_params['power_address']
    
    if 'power_user' in power_params:
        oob_info['oob_username'] = power_params['power_user']
    
    if 'power_pass' in power_params:
        oob_info['oob_password'] = power_params['power_pass']
    
    return oob_info


def get_ignored_interfaces(machine: Dict, boot_interface_name: str) -> List[str]:
    """
    Get list of network interfaces that should be ignored (all except boot interface)

    Args:
        machine: Machine data from MAAS
        boot_interface_name: Name of the boot interface to exclude

    Returns:
        List of interface names to ignore
    """
    ignored = []
    for iface in machine.get('interface_set', []):
        if iface.get('type') == 'physical' and iface.get('name'):
            iface_name = iface['name']
            if iface_name != boot_interface_name:
                ignored.append(iface_name)
    return ignored


def convert_maas_to_inventory(
    maas_client: MAASClient,
    template_file: str = None,
    output_file: str = 'inventory.yml',
    domain: str = 'pxe.local',
    controlplane_tag: str = 'controlplane'
) -> None:
    """
    Convert MAAS machine data to inventory YAML
    
    Args:
        maas_client: Initialized MAAS client
        template_file: Path to template YAML file (optional)
        output_file: Output file path
        domain: Domain name to use for hostnames
        controlplane_tag: Tag to identify controlplane nodes
    """
    
    # Load template if provided
    inventory = {}
    if template_file:
        try:
            with open(template_file, 'r') as f:
                inventory = yaml.safe_load(f) or {}
        except FileNotFoundError:
            print(f"Template file {template_file} not found, using default structure")
            inventory = {}
    
    # Initialize inventory structure if not present
    if 'all' not in inventory:
        inventory['all'] = {}
    if 'hosts' not in inventory['all']:
        inventory['all']['hosts'] = {}
    if 'localhost' not in inventory['all']['hosts']:
        inventory['all']['hosts']['localhost'] = {
            'ansible_connection': 'local',
            'dhcp_interface': 'eth0',
            'domain': domain,
        }
    
    # Fetch subnets from MAAS
    print("Fetching subnets from MAAS...")
    subnets = maas_client.get_subnets()
    pxe_subnet = find_pxe_subnet(subnets)

    if pxe_subnet:
        print(f"Found PXE subnet: {pxe_subnet.get('cidr', 'unknown')}")
        network_settings = extract_network_settings(pxe_subnet)

        # Update localhost with network settings from MAAS
        inventory['all']['hosts']['localhost'].update(network_settings)
        inventory['all']['hosts']['localhost']['network_mtu'] = 1500  # default MTU
        inventory['all']['hosts']['localhost']['network_ignored_interfaces'] = []  # Per-host overrides

        # Add Talos/Kubernetes defaults if not in template
        if 'longhorn_mount_path' not in inventory['all']['hosts']['localhost']:
            inventory['all']['hosts']['localhost']['longhorn_mount_path'] = '/var/lib/longhorn'

        if 'talos_extensions' not in inventory['all']['hosts']['localhost']:
            inventory['all']['hosts']['localhost']['talos_extensions'] = [
                'siderolabs/iscsi-tools',
                'siderolabs/util-linux-tools'
            ]
    else:
        print("Warning: No PXE subnet found in MAAS")

    # Fetch machines from MAAS
    print("Fetching machines from MAAS...")
    machines = maas_client.get_machines()
    print(f"Found {len(machines)} machines")
    
    # Convert machines to pxe_hosts format
    pxe_hosts = []
    boot_interfaces = []  # Track boot interface names to determine most common

    for machine in machines:
        hostname = machine.get('hostname', machine.get('fqdn', ''))
        status = machine.get('status_name', '')
        
        # Skip machines that are not deployed or ready
        if status not in ['Deployed', 'Ready', 'Allocated', 'Deploying']:
            print(f"Skipping {hostname} (status: {status})")
            continue
        
        print(f"Processing {hostname}...")

        # Extract machine data
        mac = extract_primary_mac(machine)
        ip = extract_primary_ip(machine)
        install_disk = extract_install_disk(machine)
        role = determine_role(machine, controlplane_tag)
        boot_interface_name = extract_boot_interface_name(machine)
        
        if not mac:
            print(f"Warning: No MAC address found for {hostname}, skipping")
            continue
        
        if not ip:
            print(f"Warning: No IP address found for {hostname}, skipping")
            continue
        
        # Build hostname with domain
        if '.' not in hostname:
            full_hostname = f"{hostname}.{domain}"
        else:
            full_hostname = hostname
        
        # Create host entry
        host_entry = {
            'name': full_hostname,
            'mac': mac,
            'ip': ip,
            'role': role,
            'install_disk': install_disk,
        }
        
        # Add OOB information if available
        oob_info = extract_oob_info(machine)
        if oob_info:
            host_entry.update(oob_info)

        # Add ignored interfaces (all physical interfaces except boot interface)
        ignored_interfaces = get_ignored_interfaces(machine, boot_interface_name)
        if ignored_interfaces:
            host_entry['ignored_interfaces'] = ignored_interfaces

        # Track boot interface for determining common interface name
        boot_interfaces.append(boot_interface_name)

        pxe_hosts.append(host_entry)

    # Determine most common boot interface name for network_primary_interface
    if boot_interfaces:
        most_common_interface = Counter(boot_interfaces).most_common(1)[0][0]
        inventory['all']['hosts']['localhost']['network_primary_interface'] = most_common_interface
        print(f"Primary network interface: {most_common_interface}")

    # Update inventory
    inventory['all']['hosts']['localhost']['pxe_hosts'] = pxe_hosts
    
    # Write output file
    print(f"\nWriting inventory to {output_file}...")
    with open(output_file, 'w') as f:
        yaml.dump(inventory, f, default_flow_style=False, sort_keys=False, width=120)
    
    print(f"Successfully generated inventory with {len(pxe_hosts)} hosts")
    
    # Print summary
    print("\nSummary:")
    controlplane_count = sum(1 for h in pxe_hosts if h['role'] == 'controlplane')
    worker_count = sum(1 for h in pxe_hosts if h['role'] == 'worker')
    print(f"  Control plane nodes: {controlplane_count}")
    print(f"  Worker nodes: {worker_count}")


def create_config_interactive(config_file: str) -> None:
    """
    Interactively create a MAAS configuration file

    Args:
        config_file: Path to configuration file to create
    """
    print("=" * 60)
    print("MAAS Configuration Setup")
    print("=" * 60)
    print()
    print("This will create a configuration file for connecting to MAAS.")
    print(f"Configuration will be saved to: {config_file}")
    print()

    # Check if maas command is available
    maas_cmd_available = shutil.which('maas') is not None

    if maas_cmd_available:
        print("✓ MAAS CLI detected - can automatically retrieve API key")
        print()

    # Get MAAS URL
    print("MAAS Server URL")
    if maas_cmd_available:
        print("  Default: http://localhost:5240/MAAS (running on MAAS server)")
        print("  Or enter custom URL (e.g., http://192.168.1.5:5240/MAAS)")
        maas_url = input("  Enter MAAS URL [http://localhost:5240/MAAS]: ").strip()
        if not maas_url:
            maas_url = "http://localhost:5240/MAAS"
    else:
        print("  Example: http://192.168.1.5:5240/MAAS")
        maas_url = input("  Enter MAAS URL: ").strip()
        if not maas_url:
            print("Error: MAAS URL is required")
            sys.exit(1)

    # Ensure URL ends with /MAAS
    if not maas_url.endswith('/MAAS'):
        if maas_url.endswith('/'):
            maas_url += 'MAAS'
        else:
            maas_url += '/MAAS'

    print()

    # Get API key
    api_key = None

    if maas_cmd_available:
        # Use maas CLI to get/generate API key
        print("MAAS Authentication")
        print("  Enter your MAAS username to retrieve/generate API key")
        username = input("  MAAS Username: ").strip()

        if not username:
            print("Error: Username is required")
            sys.exit(1)

        print()
        print(f"Retrieving API key for user '{username}'...")
        print("(This will run: sudo maas apikey --username={username})")

        try:
            result = subprocess.run(
                ['sudo', 'maas', 'apikey', f'--username={username}'],
                capture_output=True,
                text=True,
                check=True
            )
            api_key = result.stdout.strip()

            if api_key and api_key.count(':') == 2:
                print(f"✓ API key retrieved successfully")
            else:
                print(f"Error: Invalid API key format received: {api_key}")
                sys.exit(1)

        except subprocess.CalledProcessError as e:
            print(f"Error running maas command: {e}")
            print(f"stderr: {e.stderr}")
            sys.exit(1)
        except Exception as e:
            print(f"Error: {e}")
            sys.exit(1)
    else:
        # Manual API key entry
        print("MAAS API Key")
        print("  MAAS CLI not detected - manual API key entry required")
        print("  Get this from: MAAS UI -> Click your username -> API keys")
        print("  Or run on MAAS server: sudo maas apikey --username=<your-username>")
        print("  Format: consumer_key:token_key:token_secret")
        api_key = getpass.getpass("  Enter MAAS API key (hidden): ").strip()

        if not api_key:
            print("Error: API key is required")
            sys.exit(1)

        # Validate API key format
        if api_key.count(':') != 2:
            print("Warning: API key should have format consumer_key:token_key:token_secret")
            response = input("Continue anyway? [y/N]: ").strip().lower()
            if response != 'y':
                sys.exit(1)

    print()
    print("Inventory Settings")
    domain = input("  Domain name for hosts [pxe.local]: ").strip() or 'pxe.local'
    output = input("  Output inventory file [inventory.yml]: ").strip() or 'inventory.yml'
    template = input("  Template file (optional, press Enter to skip): ").strip()
    controlplane_tag = input("  MAAS tag for controlplane nodes [controller]: ").strip() or 'controller'

    print()
    print("Configuration Summary:")
    print(f"  MAAS URL: {maas_url}")
    print(f"  API Key: {'*' * 20} (hidden)")
    print(f"  Domain: {domain}")
    print(f"  Output: {output}")
    print(f"  Template: {template or '(none)'}")
    print(f"  Controlplane Tag: {controlplane_tag}")
    print()

    response = input("Save this configuration? [Y/n]: ").strip().lower()
    if response and response != 'y':
        print("Configuration cancelled")
        sys.exit(0)

    # Create config
    config = ConfigParser()
    config.add_section('maas')
    config.set('maas', 'url', maas_url)
    config.set('maas', 'api_key', api_key)

    config.add_section('inventory')
    config.set('inventory', 'domain', domain)
    config.set('inventory', 'output', output)
    if template:
        config.set('inventory', 'template', template)
    config.set('inventory', 'controlplane_tag', controlplane_tag)

    # Write config file
    with open(config_file, 'w') as f:
        f.write("# MAAS Configuration File\n")
        f.write("# Keep this file secure - it contains credentials!\n")
        f.write("\n")
        config.write(f)

    # Set restrictive permissions on config file
    os.chmod(config_file, 0o600)

    print()
    print(f"✓ Configuration saved to {config_file}")
    print(f"  File permissions set to 600 (owner read/write only)")
    print()


def load_config(config_file: str) -> Dict[str, str]:
    """Load configuration from INI file"""
    if not os.path.exists(config_file):
        return {}
    
    config = ConfigParser()
    config.read(config_file)
    
    result = {}
    if config.has_section('maas'):
        result['maas_url'] = config.get('maas', 'url', fallback=None)
        result['api_key'] = config.get('maas', 'api_key', fallback=None)
    
    if config.has_section('inventory'):
        result['domain'] = config.get('inventory', 'domain', fallback='pxe.local')
        result['output'] = config.get('inventory', 'output', fallback='inventory.yml')
        result['template'] = config.get('inventory', 'template', fallback=None)
        result['controlplane_tag'] = config.get('inventory', 'controlplane_tag', fallback='controller')
    
    return result


def main():
    parser = argparse.ArgumentParser(
        description='Convert MAAS machine inventory to Ansible YAML inventory for PXE/Talos deployment',
        epilog='Config file (maas_config.ini) can be used instead of command line arguments'
    )
    parser.add_argument(
        '--config',
        default='maas_config.ini',
        help='Configuration file path (default: maas_config.ini)'
    )
    parser.add_argument(
        '--maas-url',
        help='MAAS server URL (e.g., http://192.168.1.5:5240/MAAS)'
    )
    parser.add_argument(
        '--api-key',
        help='MAAS API key (format: consumer_key:token_key:token_secret)'
    )
    parser.add_argument(
        '--template',
        help='Template YAML file to use as base (optional)'
    )
    parser.add_argument(
        '--output',
        help='Output inventory file (default: inventory.yml)'
    )
    parser.add_argument(
        '--domain',
        help='Domain name for hosts (default: pxe.local)'
    )
    parser.add_argument(
        '--controlplane-tag',
        help='MAAS tag to identify controlplane nodes (default: controller)'
    )
    parser.add_argument(
        '--setup',
        action='store_true',
        help='Run interactive setup to create configuration file'
    )

    args = parser.parse_args()

    # Handle setup mode
    if args.setup:
        create_config_interactive(args.config)
        print("Run the script again without --setup to generate inventory.")
        sys.exit(0)

    # Check if config file exists
    if not os.path.exists(args.config):
        print(f"Configuration file not found: {args.config}")
        print()

        # If no command line args provided, offer to run setup
        if not args.maas_url and not args.api_key:
            response = input("Would you like to run interactive setup now? [Y/n]: ").strip().lower()
            if not response or response == 'y':
                create_config_interactive(args.config)
                print("Setup complete! Continuing with inventory generation...")
                print()
            else:
                print()
                print("Please either:")
                print(f"  1. Run with --setup flag: python3 {sys.argv[0]} --setup")
                print(f"  2. Provide --maas-url and --api-key on command line")
                print(f"  3. Manually create {args.config}")
                sys.exit(1)

    # Load config file
    config = load_config(args.config)

    # Command line arguments override config file
    maas_url = args.maas_url or config.get('maas_url')
    api_key = args.api_key or config.get('api_key')
    template = args.template or config.get('template')
    output = args.output or config.get('output', 'inventory.yml')
    domain = args.domain or config.get('domain', 'pxe.local')
    controlplane_tag = args.controlplane_tag or config.get('controlplane_tag', 'controller')

    # Validate required parameters
    if not maas_url:
        print("Error: --maas-url is required (or set in config file)", file=sys.stderr)
        print(f"Run with --setup to create configuration: python3 {sys.argv[0]} --setup")
        sys.exit(1)

    if not api_key:
        print("Error: --api-key is required (or set in config file)", file=sys.stderr)
        print(f"Run with --setup to create configuration: python3 {sys.argv[0]} --setup")
        sys.exit(1)
    
    # Initialize MAAS client
    print(f"Connecting to MAAS at {maas_url}...")
    maas_client = MAASClient(maas_url, api_key)

    if maas_client.use_cli:
        print("✓ Using MAAS CLI for data extraction")
    else:
        print("✓ Using MAAS HTTP API for data extraction")
    
    # Convert and generate inventory
    convert_maas_to_inventory(
        maas_client=maas_client,
        template_file=template,
        output_file=output,
        domain=domain,
        controlplane_tag=controlplane_tag
    )


if __name__ == '__main__':
    main()
