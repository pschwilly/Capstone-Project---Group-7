#!/bin/bash
set -e
cd ~/free5gc-compose
echo "Starting Containerlab VoIP transport..."
sudo containerlab deploy -t clab-voip.yaml --reconfigure
R1_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' clab-g7-voip-r1)
echo "r1 core-side IP is: $R1_IP"
echo "Adding host route to VoIP service network..."
sudo ip route replace 192.168.210.0/24 via "$R1_IP"
echo "Installing networking tools on r1 and r2..."
docker exec clab-g7-voip-r1 sh -lc '/sbin/apk add --no-cache iproute2 iputils >/dev/null'
docker exec clab-g7-voip-r2 sh -lc '/sbin/apk add --no-cache iproute2 iputils >/dev/null'
echo "Installing networking tools on svc-voip..."
docker exec clab-g7-voip-svc-voip sh -lc 'apt-get update >/dev/null 2>&1 && apt-get install -y iproute2 iputils-ping procps >/dev/null 2>&1 || true'
echo "Configuring router interfaces..."
docker exec clab-g7-voip-r1 sh -lc '/sbin/ip addr add 192.168.110.1/30 dev eth1 2>/dev/null || true; /sbin/ip link set eth1 up'
docker exec clab-g7-voip-r2 sh -lc '/sbin/ip addr add 192.168.110.2/30 dev eth1 2>/dev/null || true; /sbin/ip link set eth1 up'
docker exec clab-g7-voip-r2 sh -lc '/sbin/ip addr add 192.168.210.1/24 dev eth2 2>/dev/null || true; /sbin/ip link set eth2 up'
echo "Configuring VoIP service interface..."
docker exec clab-g7-voip-svc-voip sh -lc 'ip addr add 192.168.210.2/24 dev eth1 2>/dev/null || true; ip link set eth1 up; ip route add default via 192.168.210.1 2>/dev/null || true'
echo "Enabling router forwarding..."
docker exec clab-g7-voip-r1 sh -lc 'echo 1 > /proc/sys/net/ipv4/ip_forward'
docker exec clab-g7-voip-r2 sh -lc 'echo 1 > /proc/sys/net/ipv4/ip_forward'
echo "Adding transport routes..."
docker exec clab-g7-voip-r1 sh -lc '/sbin/ip route add 192.168.210.0/24 via 192.168.110.2 2>/dev/null || true'
docker exec clab-g7-voip-svc-voip sh -lc 'ip route add 192.168.110.0/30 via 192.168.210.1 dev eth1 2>/dev/null || true'
echo "Adding slice routing..."
docker exec clab-g7-voip-svc-voip sh -lc 'ip route add 10.60.0.0/16 via 192.168.210.1 dev eth1 2>/dev/null || true'
docker exec ueransim sh -lc "ip route add 192.168.210.0/24 via $R1_IP 2>/dev/null || true"
docker exec upf-slice1 sh -lc "ip route add 192.168.210.0/24 via $R1_IP 2>/dev/null || true"
echo "Quick validation..."
docker exec clab-g7-voip-r1 ping -c 1 192.168.210.2
docker exec ueransim sh -lc 'ping -I 10.60.0.1 -c 2 192.168.210.2'
docker exec clab-g7-voip-svc-voip sh -lc 'ss -lun | grep 5060 || true'
echo "VoIP transport network ready."
echo "VoIP service IP: 192.168.210.2"
