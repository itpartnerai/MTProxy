#!/usr/bin/env python3

import argparse
import os
import random
import socket
import struct
import subprocess
import sys
import time


TAG_MAP = {
    "compact": 0xEFEFEFEF,
    "medium": 0xEEEEEEEE,
    "padded": 0xDDDDDDDD,
}

BAD_PREFIXES = {
    b"HEAD",
    b"POST",
    b"GET ",
    b"OPTI",
    b"\xee\xee\xee\xee",
    b"\xdd\xdd\xdd\xdd",
}


def aes_256_ctr_crypt(key: bytes, iv: bytes, payload: bytes) -> bytes:
    proc = subprocess.run(
        [
            "openssl",
            "enc",
            "-aes-256-ctr",
            "-nopad",
            "-nosalt",
            "-K",
            key.hex(),
            "-iv",
            iv.hex(),
        ],
        input=payload,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.decode("utf-8", "replace"))
    return proc.stdout


def build_header(secret: bytes, tag_name: str, dc_id: int) -> bytes:
    tag = TAG_MAP[tag_name]
    while True:
        header = bytearray(os.urandom(64))
        if header[0] == 0xEF:
            continue
        if bytes(header[:4]) in BAD_PREFIXES or bytes(header[:4]) == b"\x00\x00\x00\x00":
            continue
        if bytes(header[4:8]) == b"\x00\x00\x00\x00":
            continue
        break

    header[56:60] = struct.pack("<I", tag)
    header[60:62] = struct.pack("<h", dc_id)
    header[62:64] = os.urandom(2)

    key_material = bytes(header[8:40]) + secret
    key = __import__("hashlib").sha256(key_material).digest()
    iv = bytes(header[40:56])
    encrypted = aes_256_ctr_crypt(key, iv, bytes(header))
    return bytes(header[:56]) + encrypted[56:64]


def socket_is_closed(sock: socket.socket, timeout: float) -> bool:
    sock.settimeout(timeout)
    try:
        data = sock.recv(1, socket.MSG_PEEK)
        return data == b""
    except socket.timeout:
        return False
    except (BlockingIOError, InterruptedError):
        return False
    except OSError:
        return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--secret", required=True, help="32 hex chars")
    parser.add_argument("--tag", choices=sorted(TAG_MAP.keys()), default="compact")
    parser.add_argument("--dc-id", type=int, default=0)
    parser.add_argument("--hold-seconds", type=float, default=0.0)
    parser.add_argument("--expect", choices=("open", "closed"), default="open")
    parser.add_argument("--settle-seconds", type=float, default=0.35)
    args = parser.parse_args()

    secret = bytes.fromhex(args.secret)
    if len(secret) != 16:
        raise SystemExit("secret must be 16 bytes / 32 hex chars")

    header = build_header(secret, args.tag, args.dc_id)

    sock = socket.create_connection((args.host, args.port), timeout=3.0)
    try:
        sock.sendall(header)
        time.sleep(args.settle_seconds)
        closed = socket_is_closed(sock, timeout=0.25)

        if args.expect == "open" and closed:
            return 2
        if args.expect == "closed" and not closed:
            return 3

        if args.expect == "open" and args.hold_seconds > 0:
            time.sleep(args.hold_seconds)
        return 0
    finally:
        try:
            sock.close()
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main())
