#!/bin/bash
set -e
cd ~/free5gc-compose

echo "Starting Containerlab transport..."
sudo containerlab deploy -t clab.yaml --reconfigure

# ---- Auto-detect container IPs ----
R1_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' clab-g7-transport-r1)
UPF1_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' upf-slice1)
UPF2_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' upf-slice2)

echo "r1 IP:         $R1_IP"
echo "upf-slice1 IP: $UPF1_IP"
echo "upf-slice2 IP: $UPF2_IP"

# ---- Host routes ----
echo "Adding host routes..."
sudo ip route replace 192.168.200.0/24 via "$R1_IP"

# ---- Configure router/svc interfaces ----
echo "Configuring interfaces..."
docker exec clab-g7-transport-r1  sh -lc 'ip addr add 192.168.100.1/30 dev eth1 2>/dev/null || true; ip link set eth1 up'
docker exec clab-g7-transport-r2  sh -lc 'ip addr add 192.168.100.2/30 dev eth1 2>/dev/null || true; ip link set eth1 up'
docker exec clab-g7-transport-r2  sh -lc 'ip addr add 192.168.200.1/24 dev eth2 2>/dev/null || true; ip link set eth2 up'
docker exec clab-g7-transport-svc sh -lc 'ip addr add 192.168.200.2/24 dev eth1 2>/dev/null || true; ip link set eth1 up'

# ---- Enable IP forwarding on routers ----
echo "Enabling IP forwarding..."
docker exec clab-g7-transport-r1 sh -lc 'echo 1 > /proc/sys/net/ipv4/ip_forward'
docker exec clab-g7-transport-r2 sh -lc 'echo 1 > /proc/sys/net/ipv4/ip_forward'

# ---- Transport routes (r1 <-> r2 <-> svc) ----
echo "Adding transport routes..."
docker exec clab-g7-transport-r1  sh -lc 'ip route add 192.168.200.0/24 via 192.168.100.2 2>/dev/null || true'
docker exec clab-g7-transport-svc sh -lc 'ip route add 192.168.100.0/30 via 192.168.200.1 dev eth1 2>/dev/null || true'

# ---- Slice routing: svc knows how to reach both UE subnets ----
echo "Adding slice routes on svc..."
docker exec clab-g7-transport-svc sh -lc 'ip route add 10.60.0.0/16 via 192.168.200.1 dev eth1 2>/dev/null || true'
docker exec clab-g7-transport-svc sh -lc 'ip route add 10.61.0.0/16 via 192.168.200.1 dev eth1 2>/dev/null || true'

# ---- r1 return routes back to UE subnets via UPFs ----
echo "Adding return routes on r1..."
docker exec clab-g7-transport-r1 sh -lc "ip route add 10.60.0.0/16 via $UPF1_IP 2>/dev/null || true"
docker exec clab-g7-transport-r1 sh -lc "ip route add 10.61.0.0/16 via $UPF2_IP 2>/dev/null || true"

# ---- UPF routes to svc network via r1 ----
echo "Adding routes on UPFs..."
docker exec upf-slice1 sh -lc "ip route replace 192.168.200.0/24 via $R1_IP 2>/dev/null || true"
docker exec upf-slice2 sh -lc "ip route replace 192.168.200.0/24 via $R1_IP 2>/dev/null || true"

# ---- Remove any direct bypass route from UERANSIM ----
echo "Removing bypass route from UERANSIM if present..."
docker exec ueransim sh -lc 'ip route del 192.168.200.0/24 2>/dev/null || true'

# ---- Prepare video service on svc ----
echo "Preparing video service..."
docker exec clab-g7-transport-svc sh -lc '
  set -e
  apk update >/dev/null
  apk add --no-cache iperf3 python3 wget curl procps ffmpeg nginx >/dev/null
  mkdir -p /video /var/lib/nginx/html /etc/nginx/http.d
'

# ---- Copy project video if it exists on host ----
if [ -f ~/free5gc-compose/video.mp4 ]; then
  echo "Copying project video to svc..."
  docker cp ~/free5gc-compose/video.mp4 clab-g7-transport-svc:/video/video.mp4
  echo "Re-encoding video for HTTP streaming..."
  docker exec clab-g7-transport-svc sh -lc '
    set -e
    ffmpeg -i /video/video.mp4 -vf scale=320:180 -b:v 200k -movflags faststart /video/video_demo.mp4 -y -loglevel quiet
    test -s /video/video_demo.mp4
    cp -f /video/video_demo.mp4 /var/lib/nginx/html/video_demo.mp4
  '
  echo "Demo video ready."
else
  echo "WARNING: ~/free5gc-compose/video.mp4 not found. Using fallback video."
  docker exec clab-g7-transport-svc sh -lc '
    set -e
    wget -q -O /video/video_demo.mp4 https://samplelib.com/lib/preview/mp4/sample-5s.mp4
    test -s /video/video_demo.mp4
    cp -f /video/video_demo.mp4 /var/lib/nginx/html/video_demo.mp4
  '
fi

echo "Video service ready."

# ---- Configure nginx ----
echo "Configuring nginx..."
docker exec clab-g7-transport-svc sh -lc '
  cat > /etc/nginx/http.d/default.conf << "EOF"
server {
    listen 80;
    server_name _;
    root /var/lib/nginx/html;
    location / {
        autoindex on;
    }
}
EOF
'

# ---- Start services ----
echo "Stopping old services..."
docker exec clab-g7-transport-svc sh -lc 'killall iperf3 python3 nginx 2>/dev/null || true'

echo "Starting iperf3 and nginx..."
docker exec -d clab-g7-transport-svc sh -lc 'iperf3 -s >/tmp/iperf3.log 2>&1'
docker exec -d clab-g7-transport-svc sh -lc 'nginx -g "daemon off;" >/tmp/nginx.log 2>&1'

# ---- Wait for HTTP server ----
echo "Waiting for HTTP server..."
for i in 1 2 3 4 5 6 7 8 9 10; do
  if docker exec clab-g7-transport-svc sh -lc 'curl -I --max-time 2 http://127.0.0.1/video_demo.mp4 >/dev/null 2>&1'; then
    break
  fi
  sleep 1
done

# ---- Force video service traffic over live Slice 2 UE tunnel ----
echo "Forcing Slice 2 route on UERANSIM..."
docker exec ueransim sh -lc '
TUN=$(ip -o -4 addr show | sed -n "/10\.61\./{s/^[0-9]\+: \([^ ]*\).*/\1/p;q}")
if [ -z "$TUN" ]; then
  echo "WARNING: no active Slice 2 tunnel with 10.61.x.x found."
  echo "WARNING: service and VNC are ready, but route pinning was skipped."
  exit 0
fi
SRC=$(ip -o -4 addr show "$TUN" | sed -n "s/.* inet \([0-9.]*\)\/.*/\1/p")
ip route replace 192.168.200.2/32 dev "$TUN" src "$SRC"
echo "Pinned 192.168.200.2 via $TUN src $SRC"
ip route get 192.168.200.2
'

# ---- Validation ----
echo ""
echo "=== Validation ==="

echo "--- HTTP server on svc ---"
docker exec clab-g7-transport-svc sh -lc 'curl -I --max-time 5 http://127.0.0.1/video_demo.mp4'

echo "--- r1 can reach svc ---"
docker exec clab-g7-transport-r1 ping -c 1 192.168.200.2

echo "--- UE can reach video on Slice 2 path ---"
docker exec ueransim sh -lc 'curl -I --max-time 10 http://192.168.200.2/video_demo.mp4 || true'

echo "--- Slice 2 route check on UERANSIM ---"
docker exec ueransim sh -lc 'ip route get 192.168.200.2 || true'

echo ""
echo "Transport network ready."
echo ""

# ---- Start VNC and noVNC for demo ----
echo "Starting VNC desktop in UERANSIM container..."
docker exec ueransim sh -lc '
  export USER=root
  vncserver -kill :1 >/dev/null 2>&1 || true
  pkill -f websockify 2>/dev/null || true
  pkill -f Xtightvnc 2>/dev/null || true
  pkill -f xfce4-session 2>/dev/null || true
  rm -rf /tmp/.X1-lock /tmp/.X11-unix
  mkdir -p /tmp/.X11-unix /root/.vnc
  chmod 1777 /tmp/.X11-unix
  echo "net4901*" | vncpasswd -f > /root/.vnc/passwd
  chmod 600 /root/.vnc/passwd
  vncserver :1 -geometry 1280x720 -depth 24 >/tmp/vncserver.log 2>&1 || true
  sleep 2
  export DISPLAY=:1
  startxfce4 >/tmp/xfce.log 2>&1 &
  sleep 2
' 2>/dev/null || true

docker exec -d ueransim sh -lc 'websockify --web /usr/share/novnc/ 6080 localhost:5901 >/tmp/websockify.log 2>&1'
echo "VNC desktop ready."

echo ""
echo "=== DEMO COMMANDS ==="
echo ""
echo "Run:"
echo "  ./start_clab_transport.sh"
echo ""
echo "On a new terminal on your computer:"
echo "  ssh -L 6080:10.100.200.17:6080 -l group7 134.117.92.142"
echo ""
echo "Open:"
echo "  http://localhost:6080/vnc_lite.html"
echo ""
echo "In the desktop terminal, run:"
echo "  ffplay -an -autoexit http://192.168.200.2/video_demo.mp4"
echo ""
echo "In the normal terminal, run:"
echo "  docker exec -it upf-slice2 tcpdump -i upfgtp -n host 192.168.200.2"
