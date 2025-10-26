#!/usr/bin/env python3
"""
Redfish PXE Boot Trigger Script
Handles legacy SSL ciphers and HTTP redirects for iLO/iDRAC
"""

import ssl
import sys
import json
import urllib3
from urllib.request import Request, urlopen, HTTPPasswordMgrWithDefaultRealm, HTTPBasicAuthHandler, build_opener, install_opener
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

def setup_auth(username, password):
    """Setup basic auth handler"""
    password_mgr = HTTPPasswordMgrWithDefaultRealm()
    password_mgr.add_password(None, None, username, password)
    auth_handler = HTTPBasicAuthHandler(password_mgr)
    return auth_handler

def set_boot_device(oob_address, username, password, boot_device="Pxe"):
    """Set one-time boot device via Redfish"""
    url = f"https://{oob_address}/redfish/v1/Systems/1"

    data = {
        "Boot": {
            "BootSourceOverrideEnabled": "Once",
            "BootSourceOverrideTarget": boot_device
        }
    }

    auth_handler = setup_auth(username, password)
    opener = build_opener(auth_handler)
    install_opener(opener)

    try:
        request = Request(url,
                         data=json.dumps(data).encode('utf-8'),
                         headers={'Content-Type': 'application/json'},
                         method='PATCH')

        context = create_legacy_ssl_context()
        response = urlopen(request, context=context, timeout=30)
        return True, response.getcode(), "Boot device set successfully"
    except HTTPError as e:
        return False, e.code, f"HTTP Error: {e.reason}"
    except URLError as e:
        return False, -1, f"URL Error: {e.reason}"
    except Exception as e:
        return False, -1, f"Error: {str(e)}"

def reset_server(oob_address, username, password, reset_type="ForceRestart"):
    """Trigger server reset via Redfish"""
    url = f"https://{oob_address}/redfish/v1/Systems/1/Actions/ComputerSystem.Reset"

    data = {
        "ResetType": reset_type
    }

    auth_handler = setup_auth(username, password)
    opener = build_opener(auth_handler)
    install_opener(opener)

    try:
        request = Request(url,
                         data=json.dumps(data).encode('utf-8'),
                         headers={'Content-Type': 'application/json'},
                         method='POST')

        context = create_legacy_ssl_context()
        response = urlopen(request, context=context, timeout=30)
        return True, response.getcode(), "Server reset triggered"
    except HTTPError as e:
        # Some servers return 308 redirect - follow it
        if e.code == 308 and 'Location' in e.headers:
            try:
                redirect_url = e.headers['Location']
                if not redirect_url.startswith('http'):
                    redirect_url = f"https://{oob_address}{redirect_url}"
                request = Request(redirect_url,
                                data=json.dumps(data).encode('utf-8'),
                                headers={'Content-Type': 'application/json'},
                                method='POST')
                response = urlopen(request, context=context, timeout=30)
                return True, response.getcode(), "Server reset triggered (after redirect)"
            except Exception as redirect_err:
                return False, e.code, f"Redirect failed: {str(redirect_err)}"
        return False, e.code, f"HTTP Error: {e.reason}"
    except URLError as e:
        return False, -1, f"URL Error: {e.reason}"
    except Exception as e:
        return False, -1, f"Error: {str(e)}"

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
