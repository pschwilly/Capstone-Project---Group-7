#!/bin/bash
set -e

# Accept forwarding for the demo topology.
iptables -C FORWARD -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -j ACCEPT

# Remove old blanket NAT rules if they exist.
iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null || true
iptables -t nat -D POSTROUTING -o eth1 -j MASQUERADE 2>/dev/null || true
