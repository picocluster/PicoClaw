#!/usr/bin/env python3
"""
Publish mDNS CNAME aliases for PicoClaw via Avahi D-Bus.

CNAME records point alias.local → <this machine's hostname>.local so macOS
Bonjour resolves them correctly without any client-side /etc/hosts edits.
A-records announced by third parties are ignored by macOS; CNAMEs are followed.

Subscribes to Avahi state changes so CNAMEs are re-published if the daemon
restarts or the hostname changes (e.g. after a conflict resolution rename).

Usage: python3 mdns-aliases.py claw.local threadweaver.local
Runs forever (suitable as a systemd service).
"""

import sys
import signal
import dbus
import dbus.mainloop.glib
from gi.repository import GLib
import avahi

# DNS constants not exported by all python3-avahi versions
DNS_CLASS_IN = 1
DNS_TYPE_CNAME = 5

ALIASES = sys.argv[1:] if len(sys.argv) > 1 else ["claw.local", "threadweaver.local"]

group = None
server = None
bus = None


def encode_dns_name(name: str) -> list:
    parts = name.rstrip(".").split(".")
    result = []
    for part in parts:
        encoded = part.encode("utf-8")
        result.append(len(encoded))
        result.extend(encoded)
    result.append(0)
    return result


def publish(fqdn: str):
    global group
    if group is not None:
        try:
            group.Reset()
        except Exception:
            pass

    group = dbus.Interface(
        bus.get_object(avahi.DBUS_NAME, server.EntryGroupNew()),
        avahi.DBUS_INTERFACE_ENTRY_GROUP,
    )

    if not fqdn.endswith("."):
        fqdn += "."

    rdata = dbus.Array([dbus.Byte(b) for b in encode_dns_name(fqdn)], signature="y")

    for alias in ALIASES:
        a = alias if alias.endswith(".") else alias + "."
        group.AddRecord(
            avahi.IF_UNSPEC,
            avahi.PROTO_UNSPEC,
            dbus.UInt32(0),
            a,
            dbus.UInt16(DNS_CLASS_IN),
            dbus.UInt16(DNS_TYPE_CNAME),
            dbus.UInt32(60),
            rdata,
        )
        print(f"Publishing CNAME: {a} → {fqdn}", flush=True)

    group.Commit()
    print("Committed.", flush=True)


def on_server_state_changed(state, error=None):
    if state == avahi.SERVER_RUNNING:
        fqdn = str(server.GetHostNameFqdn())
        print(f"Avahi RUNNING, hostname={fqdn}", flush=True)
        publish(fqdn)


def main():
    global server, bus

    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()

    server = dbus.Interface(
        bus.get_object(avahi.DBUS_NAME, avahi.DBUS_PATH_SERVER),
        avahi.DBUS_INTERFACE_SERVER,
    )

    server.connect_to_signal("StateChanged", on_server_state_changed)

    # Publish immediately if already running
    state = server.GetState()
    if state == avahi.SERVER_RUNNING:
        on_server_state_changed(state)

    GLib.MainLoop().run()


if __name__ == "__main__":
    main()
