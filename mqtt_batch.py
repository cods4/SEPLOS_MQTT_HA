#!/usr/bin/env python3
"""Publish many MQTT messages on one connection.

Reads lines from stdin: ``retain<TAB>topic<TAB>payload``.
Credentials come from MQTT_HOST, MQTT_PORT, MQTT_USER and MQTT_PASSWORD.
Uses the MQTT 3.1.1 protocol with the Python standard library.
"""

import os
import struct
import sys
import socket


def enc_len(n):
    if n < 0:
        raise ValueError(n)
    out = bytearray()
    while True:
        digit = n % 128
        n //= 128
        if n > 0:
            digit |= 0x80
        out.append(digit)
        if n == 0:
            break
    return bytes(out)


def enc_str(text):
    data = text.encode("utf-8")
    if len(data) > 65535:
        raise ValueError("MQTT string too long")
    return struct.pack("!H", len(data)) + data


def send_packet(sock, header, body):
    sock.sendall(bytes([header]) + enc_len(len(body)) + body)


def read_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("broker closed the connection")
        buf += chunk
    return buf


def read_packet(sock):
    header = read_exact(sock, 1)[0]
    value = 0
    multiplier = 1
    while True:
        digit = read_exact(sock, 1)[0]
        value += (digit & 0x7F) * multiplier
        if digit & 0x80 == 0:
            break
        multiplier *= 128
        if multiplier > 128 ** 3:
            raise ConnectionError("invalid remaining length")
    body = read_exact(sock, value) if value else b""
    return header, body


def publish_all(host, port, user, password, messages):
    sock = socket.create_connection((host, port), timeout=10)
    try:
        sock.settimeout(10)
        flags = 0x02  # clean session
        payload = enc_str(f"seplos-{os.getpid()}")
        if user:
            flags |= 0x80
            payload += enc_str(user)
            if password:
                flags |= 0x40
                payload += enc_str(password)
        body = enc_str("MQTT") + bytes([4, flags]) + struct.pack("!H", 15) + payload
        send_packet(sock, 0x10, body)
        header, ack = read_packet(sock)
        if header != 0x20 or len(ack) < 2 or ack[1] != 0:
            raise ConnectionError(f"broker rejected the connection ({ack!r})")
        for topic, message, retain in messages:
            packet = enc_str(topic) + message.encode("utf-8")
            send_packet(sock, 0x30 | (0x01 if retain else 0x00), packet)
        send_packet(sock, 0xE0, b"")
    finally:
        sock.close()


def parse_lines(text):
    messages = []
    for line in text.splitlines():
        if line == "":
            continue
        parts = line.split("\t", 2)
        if len(parts) < 2 or not parts[1]:
            raise ValueError(f"bad publish line: {line!r}")
        payload = parts[2] if len(parts) > 2 else ""
        messages.append((parts[1], payload, parts[0] == "1"))
    return messages


def self_test():
    assert enc_len(0) == b"\x00"
    assert enc_len(127) == b"\x7f"
    assert enc_len(128) == b"\x80\x01"
    assert enc_len(16383) == b"\xff\x7f"
    assert enc_len(16384) == b"\x80\x80\x01"
    assert enc_str("ab") == b"\x00\x02ab"
    messages = parse_lines("0\ta/b\t54.90\n1\thomeassistant/sensor/x/config\t{\"n\":1}\n")
    assert messages == [
        ("a/b", "54.90", False),
        ("homeassistant/sensor/x/config", '{"n":1}', True),
    ]
    assert parse_lines("1\ttopic\t") == [("topic", "", True)]


def main(argv):
    if len(argv) > 1 and argv[1] == "--self-test":
        self_test()
        return 0
    try:
        messages = parse_lines(sys.stdin.read())
        if not messages:
            return 0
        host = os.environ.get("MQTT_HOST", "")
        if not host:
            raise ValueError("MQTT_HOST is not set")
        port = int(os.environ.get("MQTT_PORT", "1883"))
        publish_all(
            host,
            port,
            os.environ.get("MQTT_USER", ""),
            os.environ.get("MQTT_PASSWORD", ""),
            messages,
        )
    except Exception as exc:
        print(f"MQTT publish failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
