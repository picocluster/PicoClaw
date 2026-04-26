#!/usr/bin/env python3
"""
Publish mDNS CNAME aliases for PicoClaw via Avahi D-Bus.

CNAME records point alias.local → <this machine's hostname>.local so macOS
Bonjour resolves them correctly without any client-side /etc/hosts edits.
A-records announced by third parties are ignored by macOS; CNAMEs are followed.

Usage: python3 mdns-aliases.py claw.local threadweaver.local
Runs forever (suitable as a systemd service).
"""

import sys
import signal
import dbus
import avahi

ALIASES = sys.argv[1:] if len(sys.argv) > 1 else ["claw.local", "threadweaver.local"]


def encode_dns_name(name: str) -> list[int]:
    """Encode a DNS name as a length-prefixed byte sequence."""
    parts = name.rstrip(".").split(".")
    result = []
    for part in parts:
        encoded = part.encode("utf-8")
        result.append(len(encoded))
        result.extend(encoded)
    result.append(0)
    return result


def main():
    bus = dbus.SystemBus()
    server = dbus.Interface(
        bus.get_object(avahi.DBUS_NAME, avahi.DBUS_PATH_SERVER),
        avahi.DBUS_INTERFACE_SERVER,
    )

    fqdn = str(server.GetHostNameFqdn())
    if not fqdn.endswith("."):
        fqdn += "."

    group = dbus.Interface(
        bus.get_object(avahi.DBUS_NAME, server.EntryGroupNew()),
        avahi.DBUS_INTERFACE_ENTRY_GROUP,
    )

    rdata = dbus.Array([dbus.Byte(b) for b in encode_dns_name(fqdn)], signature="y")

    for alias in ALIASES:
        if not alias.endswith("."):
            alias += "."
        group.AddRecord(
            avahi.IF_UNSPEC,
            avahi.PROTO_UNSPEC,
            dbus.UInt32(0),
            alias,
            dbus.UInt16(avahi.CLASS_IN),
            dbus.UInt16(avahi.TYPE_CNAME),
            dbus.UInt32(60),
            rdata,
        )
        print(f"Publishing CNAME: {alias} → {fqdn}", flush=True)

    group.Commit()
    print("Committed. Running.", flush=True)
    signal.pause()


if __name__ == "__main__":
    main()
