#!/usr/bin/env python3

import argparse
import json
import os
import sqlite3
import sys
from typing import Any

from librack2.auth import Auth
from librack2.core.account import CoreAccount
from librack2.server import get_servers


SERVER_ATTRIBUTES = [
    "name",
    "primary_ip",
    "private_ip",
    "platform_name",
    "networks",
    "drac_ip",
    "drac_user",
    "os",
    "os_type",
    "service_level",
    "datacenter",
]

OOB_MARKERS = ("drac", "idrac", "ilo", "oob", "bmc")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Bridge Rackspace Core inventory through hammertime auth cache.")
    parser.add_argument(
        "--cache",
        default="~/.rackspace/hammertime/cache/sessions.db",
        help="Path to the hammertime sessions cache database.",
    )

    subparsers = parser.add_subparsers(dest="command", required=True)

    auth_parser = subparsers.add_parser("auth-status", help="Show the current cached auth state.")
    auth_parser.add_argument("--include-secret", action="store_true", help="Include the rackertoken in the JSON payload.")

    list_parser = subparsers.add_parser("account-devices", help="List devices for an account.")
    list_parser.add_argument("--account", required=True, help="Rackspace account number.")

    detail_parser = subparsers.add_parser("device-details", help="Load one device by account + device id.")
    detail_parser.add_argument("--account", required=True, help="Rackspace account number.")
    detail_parser.add_argument("--device", required=True, help="Device id / server id.")

    return parser.parse_args()


def load_auth_data(cache_path: str) -> dict[str, Any]:
    path = os.path.expanduser(cache_path)
    if not os.path.exists(path):
        raise RuntimeError(f"Hammertime session cache not found at {path}")

    conn = sqlite3.connect(path)
    try:
        rows = conn.execute("select data from auth_data").fetchall()
    finally:
        conn.close()

    for (raw_data,) in rows:
        if isinstance(raw_data, bytes):
            raw_data = raw_data.decode("utf-8")
        try:
            auth_data = json.loads(raw_data)
        except json.JSONDecodeError:
            continue
        if auth_data.get("_rackertoken"):
            return auth_data

    raise RuntimeError(f"No authenticated hammertime session was found in {path}")


def build_auth(cache_path: str) -> tuple[dict[str, Any], Auth]:
    auth_data = load_auth_data(cache_path)
    rackertoken = auth_data.get("_rackertoken")
    if not rackertoken:
        raise RuntimeError("The cached hammertime session did not include a Rackspace token.")
    return auth_data, Auth("talos-deploy", rackertoken=rackertoken, interactive=False)


def chunked(values: list[str], size: int) -> list[list[str]]:
    return [values[index:index + size] for index in range(0, len(values), size)]


def string(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, (list, tuple)):
        if not value:
            return ""
        return string(value[0])
    return str(value)


def integer(value: Any) -> int | None:
    if value in (None, ""):
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def record_marker(record: dict[str, Any]) -> str:
    parts = [
        string(record.get("network_type")).lower(),
        string(record.get("network_name")).lower(),
        string(record.get("label")).lower(),
    ]
    return " ".join(parts)


def is_oob_record(record: dict[str, Any]) -> bool:
    marker = record_marker(record)
    return any(marker_part in marker for marker_part in OOB_MARKERS)


def infer_oob_vendor(record: dict[str, Any] | None) -> str:
    marker = record_marker(record or {})
    if "ilo" in marker:
        return "ilo"
    if "idrac" in marker or "drac" in marker:
        return "idrac"
    return "redfish"


def extract_network_records(server: Any) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []

    for network in getattr(server, "networks", []) or []:
        attributes = getattr(network, "_attributes", None) or {}
        if attributes:
            records.append(dict(attributes))

    if records:
        return records

    network_data = getattr(server, "_network_data", None) or {}
    for key in ("public_ips", "private_ips", "ipv6_ips"):
        for entry in network_data.get(key, []) or []:
            records.append(dict(entry))
    return records


def build_interfaces(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    interfaces: dict[tuple[str, Any, str], dict[str, Any]] = {}

    for index, record in enumerate(records):
        name = (
            string(record.get("network_name"))
            or string(record.get("label"))
            or string(record.get("network_type"))
            or string(record.get("ip_block_type"))
            or f"net-{index}"
        )
        mac_address = string(record.get("mac_address") or record.get("mac"))
        vlan_id = integer(record.get("vlan_number") or record.get("vlan_id"))
        key = (name, vlan_id, mac_address)

        interface = interfaces.setdefault(
            key,
            {
                "name": name,
                "addresses": [],
                "mac_address": mac_address,
                "vlan_id": vlan_id,
                "mtu": integer(record.get("mtu")),
            },
        )

        ip_address = string(record.get("ip_address"))
        if ip_address and ip_address not in interface["addresses"]:
            interface["addresses"].append(ip_address)

    return list(interfaces.values())


def pick_primary_ip(server: Any, records: list[dict[str, Any]]) -> str:
    value = string(getattr(server, "primary_ip", None))
    if value:
        return value

    primary_records = [
        record for record in records
        if "public" in string(record.get("ip_block_type")).lower() and not is_oob_record(record)
    ]
    labeled = [record for record in primary_records if string(record.get("label")).lower() == "primary"]
    target = labeled[0] if labeled else (primary_records[0] if primary_records else None)
    return string(target.get("ip_address")) if target else ""


def pick_private_ip(server: Any, records: list[dict[str, Any]]) -> str:
    value = string(getattr(server, "private_ip", None))
    if value:
        return value

    private_records = [
        record for record in records
        if "private" in string(record.get("ip_block_type")).lower()
    ]
    preferred = [
        record for record in private_records
        if string(record.get("label")).lower() != "reserved_gateway"
    ]
    target = preferred[0] if preferred else (private_records[0] if private_records else None)
    return string(target.get("ip_address")) if target else ""


def pick_oob(server: Any, records: list[dict[str, Any]]) -> dict[str, Any] | None:
    attributes = getattr(server, "attributes", None) or {}
    direct_drac = string(getattr(server, "drac_ip", None) or attributes.get("drac_ip"))
    username = string(getattr(server, "drac_user", None) or attributes.get("drac_user"))

    if direct_drac:
        return {
            "vendor": "redfish",
            "address": direct_drac,
            "username": username,
            "credential_reference": "",
            "supports_virtual_media": None,
            "supports_pxe": None,
        }

    matching_record = next((record for record in records if is_oob_record(record)), None)
    if not matching_record:
        return None

    return {
        "vendor": infer_oob_vendor(matching_record),
        "address": string(matching_record.get("ip_address") or matching_record.get("gateway_ip")),
        "username": username,
        "credential_reference": "",
        "supports_virtual_media": None,
        "supports_pxe": None,
    }


def serialize_device(server: Any, account_number: str) -> dict[str, Any]:
    attributes = getattr(server, "attributes", None) or {}
    records = extract_network_records(server)
    oob = pick_oob(server, records)
    server_id = string(getattr(server, "server", None) or getattr(server, "id", None) or attributes.get("server"))
    server_name = string(
        getattr(server, "name", None)
        or getattr(server, "server_name", None)
        or attributes.get("server_name")
        or server_id
    )

    return {
        "id": server_id,
        "account_number": string(getattr(server, "account_num", None) or attributes.get("account_num") or account_number),
        "name": server_name,
        "primary_ip": pick_primary_ip(server, records),
        "private_ip": pick_private_ip(server, records),
        "platform_name": string(attributes.get("platform_name")),
        "os_type": string(attributes.get("os_type")),
        "service_level": string(attributes.get("service_level_name") or attributes.get("service_level")),
        "service_tag": string(attributes.get("service_tag") or attributes.get("serial_number")),
        "memory_gib": None,
        "storage_gib": None,
        "install_disk": "",
        "network_interfaces": build_interfaces(records),
        "oob": oob,
        "credential_reference": "",
    }


def load_servers_for_account(auth: Auth, account_number: str) -> list[Any]:
    account = CoreAccount(auth, account_number)
    servers: list[Any] = []
    for server_ids in chunked(account.server_ids, 25):
        servers.extend(get_servers(auth, server_ids, attributes=SERVER_ATTRIBUTES))
    return servers


def print_auth_status(args: argparse.Namespace) -> None:
    auth_data = load_auth_data(args.cache)
    user = auth_data.get("_token_validation_response", {}).get("user", {}) or {}
    payload = {
        "authenticated": True,
        "username": string(user.get("username") or auth_data.get("_sso")),
        "header_name": "X-Auth-Token",
        "source": "hammertime-cache",
        "expires_at": string(auth_data.get("_saml_expires")) or None,
    }
    if args.include_secret:
        payload["secret"] = string(auth_data.get("_rackertoken"))
    print(json.dumps(payload))


def print_account_devices(args: argparse.Namespace) -> None:
    _, auth = build_auth(args.cache)
    devices = [serialize_device(server, args.account) for server in load_servers_for_account(auth, args.account)]
    devices.sort(key=lambda device: (device.get("name") or "", device.get("id") or ""))
    print(json.dumps({"account_number": args.account, "devices": devices}))


def print_device_details(args: argparse.Namespace) -> None:
    _, auth = build_auth(args.cache)
    servers = get_servers(auth, [args.device], attributes=SERVER_ATTRIBUTES)
    if not servers:
        raise RuntimeError(f"No device with id {args.device} was returned for account {args.account}")
    print(json.dumps({"device": serialize_device(servers[0], args.account)}))


def main() -> int:
    args = parse_args()

    if args.command == "auth-status":
        print_auth_status(args)
        return 0
    if args.command == "account-devices":
        print_account_devices(args)
        return 0
    if args.command == "device-details":
        print_device_details(args)
        return 0

    raise RuntimeError(f"Unsupported command: {args.command}")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
