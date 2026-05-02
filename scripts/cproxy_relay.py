#!/usr/bin/env python3
"""Expose a simple local HTTP CONNECT proxy that relays through cproxy.

This lets a browser use a normal local proxy setting while the script handles:
- the SSH-forwarded upstream proxy port
- TLS/SNI for the upstream secure proxy
- proxy authentication to cproxy
"""

from __future__ import annotations

import argparse
import base64
import sys
import select
import socket
import ssl
import threading
from typing import Dict, Tuple


BUFFER_SIZE = 65536


def read_headers(conn: socket.socket) -> tuple[str, Dict[str, str], bytes]:
    data = bytearray()
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(BUFFER_SIZE)
        if not chunk:
            break
        data.extend(chunk)

    header_blob, _, remainder = bytes(data).partition(b"\r\n\r\n")
    lines = header_blob.decode("iso-8859-1").split("\r\n") if header_blob else []
    if not lines:
        raise ConnectionError("client closed before sending a request")

    headers: Dict[str, str] = {}
    for line in lines[1:]:
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        headers[key.strip().lower()] = value.strip()

    return lines[0], headers, remainder


def open_upstream(
    upstream_host: str,
    upstream_port: int,
    server_name: str,
    insecure: bool,
) -> ssl.SSLSocket:
    raw = socket.create_connection((upstream_host, upstream_port), timeout=15)
    context = ssl.create_default_context()
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.maximum_version = ssl.TLSVersion.TLSv1_2
    context.set_ciphers("DEFAULT:@SECLEVEL=1")
    if insecure:
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
    return context.wrap_socket(raw, server_hostname=server_name)


def read_upstream_headers(conn: socket.socket) -> tuple[str, bytes]:
    data = bytearray()
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(BUFFER_SIZE)
        if not chunk:
            break
        data.extend(chunk)
    header_blob, _, remainder = bytes(data).partition(b"\r\n\r\n")
    lines = header_blob.decode("iso-8859-1").split("\r\n") if header_blob else []
    if not lines:
        raise ConnectionError("upstream proxy closed before responding")
    return lines[0], remainder


def relay_bidirectional(left: socket.socket, right: socket.socket) -> None:
    sockets = [left, right]
    try:
        while True:
            readable, _, _ = select.select(sockets, [], [], 60)
            if not readable:
                continue

            for sock in readable:
                peer = right if sock is left else left
                data = sock.recv(BUFFER_SIZE)
                if not data:
                    return
                peer.sendall(data)
    finally:
        try:
            left.close()
        finally:
            right.close()


def forward_http_request(
    upstream: ssl.SSLSocket,
    request_line: str,
    headers: Dict[str, str],
    remainder: bytes,
    auth_header: str,
) -> tuple[str, bytes]:
    header_lines = [request_line]
    saw_auth = False
    for key, value in headers.items():
        if key.lower() == "proxy-authorization":
            saw_auth = True
            header_lines.append(f"Proxy-Authorization: {value}")
            continue
        header_lines.append(f"{key.title()}: {value}")
    if not saw_auth:
        header_lines.append(f"Proxy-Authorization: {auth_header}")
    header_lines.append("")
    header_lines.append("")
    upstream.sendall("\r\n".join(header_lines).encode("iso-8859-1") + remainder)
    return read_upstream_headers(upstream)


def handle_client(
    client: socket.socket,
    upstream_host: str,
    upstream_port: int,
    upstream_server_name: str,
    auth_header: str,
    insecure_upstream: bool,
) -> None:
    try:
        request_line, headers, remainder = read_headers(client)
        method, target, _ = request_line.split(" ", 2)

        upstream = open_upstream(
            upstream_host,
            upstream_port,
            upstream_server_name,
            insecure_upstream,
        )

        if method.upper() == "CONNECT":
            connect_req = (
                f"CONNECT {target} HTTP/1.1\r\n"
                f"Host: {target}\r\n"
                f"Proxy-Authorization: {auth_header}\r\n"
                "Proxy-Connection: Keep-Alive\r\n"
                "\r\n"
            )
            upstream.sendall(connect_req.encode("iso-8859-1"))
            status_line, remainder = read_upstream_headers(upstream)
            if not status_line.startswith("HTTP/1.1 200") and not status_line.startswith(
                "HTTP/1.0 200"
            ):
                client.sendall(f"{status_line}\r\n\r\n".encode("iso-8859-1") + remainder)
                upstream.close()
                return

            client.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
            if remainder:
                client.sendall(remainder)
            relay_bidirectional(client, upstream)
            return

        status_line, upstream_remainder = forward_http_request(
            upstream,
            request_line,
            headers,
            remainder,
            auth_header,
        )
        client.sendall(f"{status_line}\r\n\r\n".encode("iso-8859-1") + upstream_remainder)
        relay_bidirectional(client, upstream)
    except Exception as exc:  # pragma: no cover - operational helper
        print(f"relay error: {exc}", file=sys.stderr, flush=True)
        try:
            client.sendall(
                (
                    "HTTP/1.1 502 Bad Gateway\r\n"
                    "Content-Type: text/plain\r\n"
                    f"Content-Length: {len(str(exc))}\r\n"
                    "\r\n"
                    f"{exc}"
                ).encode("utf-8")
            )
        except Exception:
            pass
        client.close()


def serve(
    listen_host: str,
    listen_port: int,
    upstream_host: str,
    upstream_port: int,
    upstream_server_name: str,
    auth_header: str,
    insecure_upstream: bool,
) -> None:
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((listen_host, listen_port))
    server.listen()

    print(
        f"Local relay listening on http://{listen_host}:{listen_port} "
        f"-> https://{upstream_server_name}:{upstream_port}",
        flush=True,
    )

    while True:
        client, _ = server.accept()
        thread = threading.Thread(
            target=handle_client,
            args=(
                client,
                upstream_host,
                upstream_port,
                upstream_server_name,
                auth_header,
                insecure_upstream,
            ),
            daemon=True,
        )
        thread.start()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listen-host", default="127.0.0.1")
    parser.add_argument("--listen-port", type=int, default=18080)
    parser.add_argument("--upstream-host", default="127.0.0.1")
    parser.add_argument("--upstream-port", type=int, default=13128)
    parser.add_argument("--upstream-server-name", default="cproxy.iad3.corp.rackspace.net")
    parser.add_argument("--proxy-user", required=True)
    parser.add_argument("--proxy-password", required=True)
    parser.add_argument("--insecure-upstream", action="store_true")
    args = parser.parse_args()

    auth_token = base64.b64encode(
        f"{args.proxy_user}:{args.proxy_password}".encode("utf-8")
    ).decode("ascii")
    auth_header = f"Basic {auth_token}"

    serve(
        args.listen_host,
        args.listen_port,
        args.upstream_host,
        args.upstream_port,
        args.upstream_server_name,
        auth_header,
        args.insecure_upstream,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
