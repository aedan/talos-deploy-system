#!/usr/bin/env python3
"""
Redfish PXE Boot Trigger Script
Handles legacy SSL ciphers and HTTP redirects for iLO/iDRAC
"""

import ssl
import sys
import json
import base64
import urllib3
from urllib.request import Request, urlopen, HTTPPasswordMgrWithDefaultRealm, HTTPBasicAuthHandler, build_opener, install_opener, HTTPHandler, HTTPSHandler
from urllib.error import HTTPError, URLError

# Disable SSL warnings for self-signed certificates
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

def create_legacy_ssl_context():
    """Create SSL context that supports legacy ciphers like DH"""
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    # Allow legacy weak ciphers (for old iDRAC/iLO)
    context.set_ciphers('DEFAULT:@SECLEVEL=1')
    return context

def make_request(url, username, password, method='GET', data=None):
    """Make HTTP request with auth and legacy SSL support"""
    context = create_legacy_ssl_context()

    # Create Basic Auth header manually
    credentials = f"{username}:{password}"
    encoded_credentials = base64.b64encode(credentials.encode('utf-8')).decode('utf-8')
    auth_header = f"Basic {encoded_credentials}"

    # Build opener with custom SSL context
    https_handler = HTTPSHandler(context=context)
    opener = build_opener(https_handler)

    headers = {
        'Content-Type': 'application/json',
        'Authorization': auth_header
    }

    if data:
        data = json.dumps(data).encode('utf-8')

    base_url = '/'.join(url.split('/')[:3])  # https://host

    request = Request(url, data=data, headers=headers, method=method)

    try:
        response = opener.open(request, timeout=30)
        return True, response.getcode(), f"Success"
    except HTTPError as e:
        # Handle redirects manually for PATCH/POST
        if e.code in [301, 302, 307, 308] and 'Location' in e.headers:
            redirect_url = e.headers['Location']
            original_redirect = redirect_url  # Save for debugging
            if not redirect_url.startswith('http'):
                redirect_url = f"{base_url}{redirect_url}"

            # Retry with redirect URL - auth header is already in headers dict
            try:
                request = Request(redirect_url, data=data, headers=headers, method=method)
                response = opener.open(request, timeout=30)
                return True, response.getcode(), f"Success (after redirect to {original_redirect})"
            except Exception as redirect_err:
                return False, e.code, f"Redirect to {original_redirect} failed: {str(redirect_err)}"
        return False, e.code, f"HTTP Error: {e.reason}"
    except URLError as e:
        return False, -1, f"URL Error: {str(e.reason)}"
    except Exception as e:
        return False, -1, f"Error: {str(e)}"

def set_boot_device(oob_address, username, password, boot_device="Pxe"):
    """Set one-time boot device via Redfish"""
    url = f"https://{oob_address}/redfish/v1/Systems/1"

    data = {
        "Boot": {
            "BootSourceOverrideEnabled": "Once",
            "BootSourceOverrideTarget": boot_device
        }
    }

    success, code, msg = make_request(url, username, password, method='PATCH', data=data)
    if success:
        return True, code, "Boot device set successfully"

    # If standard Redfish fails with 400, try Dell OEM method for old iDRAC
    if code == 400:
        # Try Dell-specific OEM endpoint for iDRAC7/8
        oem_url = f"https://{oob_address}/redfish/v1/Systems/System.Embedded.1"
        oem_data = {
            "Boot": {
                "BootSourceOverrideEnabled": "Once",
                "BootSourceOverrideTarget": boot_device
            }
        }
        success_oem, code_oem, msg_oem = make_request(oem_url, username, password, method='PATCH', data=oem_data)
        if success_oem:
            return True, code_oem, "Boot device set successfully (Dell OEM)"
        return False, code_oem, f"Standard and OEM methods failed: {msg} / {msg_oem}"

    return False, code, msg

def reset_server(oob_address, username, password, reset_type="ForceRestart"):
    """Trigger server reset via Redfish"""
    url = f"https://{oob_address}/redfish/v1/Systems/1/Actions/ComputerSystem.Reset"

    data = {
        "ResetType": reset_type
    }

    success, code, msg = make_request(url, username, password, method='POST', data=data)
    if success:
        return True, code, "Server reset triggered"

    # If standard Redfish fails with 400, try Dell OEM variations
    if code == 400:
        oem_url = f"https://{oob_address}/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset"

        # Try ForceRestart first (for when server is on)
        success_oem, code_oem, msg_oem = make_request(oem_url, username, password, method='POST', data=data)
        if success_oem:
            return True, code_oem, "Server reset triggered (Dell OEM)"

        # If server might be off, try On to power it on
        data_on = {"ResetType": "On"}
        success_on, code_on, msg_on = make_request(oem_url, username, password, method='POST', data=data_on)
        if success_on:
            return True, code_on, "Server powered on (Dell OEM)"

        # Try ForceOff then On (two-step reboot for servers that are currently on)
        data_off = {"ResetType": "ForceOff"}
        success_off, code_off, msg_off = make_request(oem_url, username, password, method='POST', data=data_off)
        if success_off:
            # Wait for server to fully power off
            import time
            time.sleep(5)
            # Now power it back on
            success_on2, code_on2, msg_on2 = make_request(oem_url, username, password, method='POST', data=data_on)
            if success_on2:
                return True, code_on2, "Server reset triggered (Dell OEM ForceOff+On)"
            else:
                # ForceOff worked but On failed - return partial success message
                return False, code_on2, f"Server powered off successfully but failed to power back on: {msg_on2}"

        return False, code_oem, f"All Dell reset methods failed: std={msg}, oem={msg_oem}, on={msg_on}, off={msg_off}"

    return False, code, msg

def main():
    if len(sys.argv) != 5:
        print(json.dumps({
            "failed": True,
            "msg": "Usage: redfish_pxe_boot.py <oob_address> <username> <password> <action>"
        }))
        sys.exit(1)

    oob_address = sys.argv[1]
    username = sys.argv[2]
    password = sys.argv[3]
    action = sys.argv[4]  # "set_boot" or "reset"

    if action == "set_boot":
        success, code, msg = set_boot_device(oob_address, username, password)
    elif action == "reset":
        success, code, msg = reset_server(oob_address, username, password)
    else:
        success, code, msg = False, -1, f"Unknown action: {action}"

    result = {
        "failed": not success,
        "changed": success,
        "status_code": code,
        "msg": msg
    }

    print(json.dumps(result))
    sys.exit(0 if success else 1)

if __name__ == "__main__":
    main()
