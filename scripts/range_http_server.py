#!/usr/bin/env python3
"""Small static file server with single-range HTTP support.

Useful for iLO/iDRAC URL virtual media, which may require byte-range requests
to mount ISO images reliably.
"""

import argparse
import contextlib
import email.utils
import http.server
import io
import os
import posixpath
import shutil
import socketserver
from pathlib import Path
from typing import Optional
from urllib.parse import unquote


class ByteRange:
    def __init__(self, start: int, end: int) -> None:
        self.start = start
        self.end = end

    @property
    def length(self) -> int:
        return self.end - self.start + 1


class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


class RangeRequestHandler(http.server.SimpleHTTPRequestHandler):
    server_version = "RangeHTTP/1.0"

    def __init__(self, *args, directory: Optional[str] = None, **kwargs):
        self.range: Optional[ByteRange] = None
        self.directory = directory or os.getcwd()
        super().__init__(*args, **kwargs)

    def send_head(self):
        path = self.translate_path(self.path)
        if os.path.isdir(path):
            return self.list_directory(path)

        ctype = self.guess_type(path)
        try:
            source = open(path, "rb")
        except OSError:
            self.send_error(http.HTTPStatus.NOT_FOUND, "File not found")
            return None

        try:
            fs = os.fstat(source.fileno())
            total_size = fs.st_size
            self.range = self.parse_range_header(total_size)

            if self.range is None:
                self.send_response(http.HTTPStatus.OK)
                self.send_common_headers(ctype, total_size, fs.st_mtime)
            else:
                self.send_response(http.HTTPStatus.PARTIAL_CONTENT)
                self.send_common_headers(ctype, self.range.length, fs.st_mtime)
                self.send_header(
                    "Content-Range",
                    f"bytes {self.range.start}-{self.range.end}/{total_size}",
                )
                source.seek(self.range.start)

            self.end_headers()
            return source
        except Exception:
            source.close()
            raise

    def copyfile(self, source, outputfile):
        if self.range is None:
            shutil.copyfileobj(source, outputfile)
            return

        remaining = self.range.length
        while remaining > 0:
            chunk = source.read(min(1024 * 1024, remaining))
            if not chunk:
                break
            outputfile.write(chunk)
            remaining -= len(chunk)

    def send_common_headers(self, ctype: str, length: int, mtime: float) -> None:
        self.send_header("Content-type", ctype)
        self.send_header("Content-Length", str(length))
        self.send_header("Last-Modified", self.date_time_string(mtime))
        self.send_header("Accept-Ranges", "bytes")

    def parse_range_header(self, total_size: int) -> Optional[ByteRange]:
        header = self.headers.get("Range")
        if not header:
            return None

        if not header.startswith("bytes="):
            self.send_error(http.HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
            raise ValueError("unsupported range unit")

        spec = header[len("bytes=") :].strip()
        if "," in spec:
            self.send_error(http.HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
            raise ValueError("multiple ranges are not supported")

        start_text, sep, end_text = spec.partition("-")
        if not sep:
            self.send_error(http.HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
            raise ValueError("invalid range format")

        if start_text == "":
            suffix_length = int(end_text)
            if suffix_length <= 0:
                self.send_error(http.HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
                raise ValueError("invalid suffix length")
            start = max(total_size - suffix_length, 0)
            end = total_size - 1
        else:
            start = int(start_text)
            end = total_size - 1 if end_text == "" else int(end_text)

        if start < 0 or end < start or start >= total_size:
            self.send_error(http.HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
            raise ValueError("range outside file")

        end = min(end, total_size - 1)
        return ByteRange(start=start, end=end)

    # Copied from stdlib 3.11 SimpleHTTPRequestHandler, adapted to keep
    # behavior stable on older Python versions.
    def translate_path(self, path):
        path = path.split("?", 1)[0]
        path = path.split("#", 1)[0]
        trailing_slash = path.rstrip().endswith("/")
        path = posixpath.normpath(unquote(path))
        words = filter(None, path.split("/"))
        path = self.directory or os.getcwd()
        for word in words:
            if os.path.dirname(word) or word in (os.curdir, os.pardir):
                continue
            path = os.path.join(path, word)
        if trailing_slash:
            path += "/"
        return path


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Static HTTP server with byte-range support."
    )
    parser.add_argument("--bind", default="0.0.0.0", help="Bind address")
    parser.add_argument("--port", type=int, default=18083, help="Listen port")
    parser.add_argument(
        "--directory",
        default=".",
        help="Directory to serve (default: current working directory)",
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()
    directory = str(Path(args.directory).resolve())

    handler = lambda *a, **kw: RangeRequestHandler(
        *a, directory=directory, **kw
    )
    server = ThreadingHTTPServer((args.bind, args.port), handler)

    print(f"Serving {directory} on http://{args.bind}:{args.port}", flush=True)
    with contextlib.suppress(KeyboardInterrupt):
        server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
