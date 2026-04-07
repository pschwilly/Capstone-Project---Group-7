#!/bin/bash
set -euo pipefail

cd ~/free5gc-compose

UE_S2_VIDEO="ue-s2-video"
UE_S2_LOAD="ue-s2-load"
UE_S1_VIDEO="ue-s1-video"
UE_S1_LOAD="ue-s1-load"

UE_CONTS=("$UE_S2_VIDEO" "$UE_S2_LOAD" "$UE_S1_VIDEO" "$UE_S1_LOAD")

S2_SVC_IP="192.168.210.2"
S1_SVC_IP="192.168.220.2"

HANDOFF_S2_NET="free5gc-compose_handoff_s2"
HANDOFF_S1_NET="free5gc-compose_handoff_s1"

R1_S2_IF="s2handoff"
R1_S1_IF="s1handoff"

R1_S2_HANDOFF_IP="172.31.2.2"
R1_S1_HANDOFF_IP="172.31.1.2"

UPF2_HANDOFF_IP="172.31.2.3"
UPF1_HANDOFF_IP="172.31.1.3"

S2_TC_ENABLE="${S2_TC_ENABLE:-1}"
S2_TC_RATE="${S2_TC_RATE:-6mbit}"
S2_TC_BURST="${S2_TC_BURST:-256kbit}"
S2_TC_LATENCY="${S2_TC_LATENCY:-400ms}"

HOST_S2_VETH="veth-r1-s2-host"
NS_S2_VETH="veth-r1-s2-ns"
HOST_S1_VETH="veth-r1-s1-host"
NS_S1_VETH="veth-r1-s1-ns"

get_priv_ip() {
  local c="$1"
  docker inspect -f '{{with index .NetworkSettings.Networks "free5gc-compose_privnet"}}{{.IPAddress}}{{end}}' "$c"
}

bridge_name_from_net() {
  local net="$1"
  local nid
  nid="$(docker network inspect -f '{{.Id}}' "$net")"
  echo "br-${nid:0:12}"
}

ensure_network_exists() {
  local net="$1"
  docker network inspect "$net" >/dev/null 2>&1 || {
    echo "ERROR: docker network $net not found."
    echo "Run: docker compose up -d --force-recreate free5gc-upf-slice1 free5gc-upf-slice2"
    exit 1
  }
}

ensure_bridge_exists() {
  local br="$1"
  ip link show "$br" >/dev/null 2>&1 || {
    echo "ERROR: bridge $br not found on host."
    exit 1
  }
}

clean_routes() {
  local c="$1"
  docker exec "$c" sh -lc '
    stopload 2>/dev/null || true
    rm -f /tmp/dl*.log
    ip route del 192.168.200.2/32 2>/dev/null || true
    ip route del 192.168.210.2/32 2>/dev/null || true
    ip route del 192.168.220.2/32 2>/dev/null || true
    ip route del 192.168.200.0/24 2>/dev/null || true
    ip route del 192.168.210.0/24 2>/dev/null || true
    ip route del 192.168.220.0/24 2>/dev/null || true
    ip route flush cache 2>/dev/null || true
  '
}

pin_service_route_prefix() {
  local c="$1"
  local prefix="$2"
  local label="$3"
  local dst="$4"

  docker exec "$c" sh -lc "
    i=1
    while [ \"\$i\" -le 20 ]; do
      TUN=\$(ip -o -4 addr show | sed -n '/${prefix}/{s/^[0-9]\\+: \\([^ ]*\\).*/\\1/p;q}')
      if [ -n \"\$TUN\" ]; then
        SRC=\$(ip -o -4 addr show \"\$TUN\" | sed -n 's/.* inet \\([0-9.]*\\)\\/.*/\\1/p')
        ip route replace ${dst}/32 dev \"\$TUN\" src \"\$SRC\"
        ip route flush cache >/dev/null 2>&1 || true
        echo '$label pinned ${dst} via' \"\$TUN\" 'src' \"\$SRC\"
        ip route get ${dst}
        exit 0
      fi
      i=\$((i+1))
      sleep 1
    done
    echo 'ERROR: no active tunnel found for $label using prefix ${prefix}.'
    exit 1
  "
}

block_service_ip() {
  local c="$1"
  local label="$2"
  local dst="$3"

  docker exec "$c" sh -lc "
    ip route replace blackhole ${dst}/32
    ip route flush cache >/dev/null 2>&1 || true
    echo '$label blocked opposite service ${dst}'
    ip route show ${dst}/32 || true
  "
}

start_vnc() {
  local c="$1"

  docker exec "$c" sh -lc '
    export USER=root
    vncserver -kill :1 >/dev/null 2>&1 || true
    pkill -x websockify 2>/dev/null || true
    pkill -x Xtightvnc 2>/dev/null || true
    pkill -x xfce4-session 2>/dev/null || true
    rm -rf /tmp/.X1-lock /tmp/.X11-unix
    mkdir -p /tmp/.X11-unix /root/.vnc
    chmod 1777 /tmp/.X11-unix
    echo "net4901*" | vncpasswd -f > /root/.vnc/passwd
    chmod 600 /root/.vnc/passwd
    cat > /root/.vnc/xstartup << "EOFX"
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
xrdb $HOME/.Xresources 2>/dev/null || true
startxfce4 &
EOFX
    chmod +x /root/.vnc/xstartup
    vncserver :1 -geometry 960x540 -depth 24 >/tmp/vncserver.log 2>&1 || true
    sleep 2
  ' >/dev/null 2>&1 || true

  docker exec -d "$c" sh -lc 'websockify --web /usr/share/novnc/ 6080 localhost:5901 >/tmp/websockify.log 2>&1'
  sleep 2
}

validate_http() {
  local c="$1"
  local label="$2"
  local base="$3"

  docker exec "$c" sh -lc "
    IFACE=\"\$(ip -o link show | awk -F': ' '/uesimtun/{print \$2; exit}')\"
    [ -n \"\$IFACE\" ] || exit 1
    curl --interface \"\$IFACE\" -I --max-time 10 http://${base}/demo_long.mp4
    curl --interface \"\$IFACE\" -I --max-time 10 http://${base}/file_2G.bin
  " >/dev/null

  echo "$label HTTP validation passed."
}

prep_service_node() {
  local node="$1"

  docker exec "$node" sh -lc '
    set -e
    apk update >/dev/null
    apk add --no-cache iperf3 python3 wget curl procps ffmpeg nginx >/dev/null
    mkdir -p /video /var/lib/nginx/html /etc/nginx/http.d
  '

  if [ -f ~/free5gc-compose/video.mp4 ]; then
    docker cp ~/free5gc-compose/video.mp4 "${node}:/video/video.mp4"
    docker exec "$node" sh -lc '
      set -e
      ffmpeg -i /video/video.mp4 -vf scale=320:180 -b:v 200k -movflags faststart /video/video_demo.mp4 -y -loglevel quiet
      test -s /video/video_demo.mp4
      cp -f /video/video_demo.mp4 /var/lib/nginx/html/video_demo.mp4
    '
  else
    docker exec "$node" sh -lc '
      set -e
      wget -q -O /video/video_demo.mp4 https://samplelib.com/lib/preview/mp4/sample-5s.mp4
      test -s /video/video_demo.mp4
      cp -f /video/video_demo.mp4 /var/lib/nginx/html/video_demo.mp4
    '
  fi

  if [ -f ~/free5gc-compose/subway.mp4 ]; then
    docker cp ~/free5gc-compose/subway.mp4 "${node}:/var/lib/nginx/html/subway.mp4"
  else
    echo "ERROR: ~/free5gc-compose/subway.mp4 not found."
    exit 1
  fi

  docker exec "$node" sh -lc '
    test -f /var/lib/nginx/html/file_2G.bin || dd if=/dev/zero of=/var/lib/nginx/html/file_2G.bin bs=1M count=2048 >/dev/null 2>&1
  '

  docker exec "$node" sh -lc '
    set -e
    ffmpeg -stream_loop -1 -i /var/lib/nginx/html/subway.mp4 -t 120 \
      -vf "fps=24,scale=854:480:flags=lanczos" \
      -c:v libx264 -preset veryfast \
      -x264-params "force-cfr=1:keyint=48:min-keyint=48:scenecut=0" \
      -b:v 1800k -maxrate 1800k -bufsize 3600k \
      -pix_fmt yuv420p -an -movflags +faststart \
      /var/lib/nginx/html/demo_long.mp4 -y >/tmp/demo_long.log 2>&1

    test -s /var/lib/nginx/html/demo_long.mp4
  '

  docker exec "$node" sh -lc '
    cat > /etc/nginx/http.d/default.conf << "EOFNGINX"
server {
    listen 80;
    server_name _;
    root /var/lib/nginx/html;
    location / {
        autoindex on;
    }
}
EOFNGINX
  '

  docker exec "$node" sh -lc 'killall iperf3 python3 nginx 2>/dev/null || true'
  docker exec -d "$node" sh -lc 'iperf3 -s >/tmp/iperf3.log 2>&1'
  docker exec -d "$node" sh -lc 'nginx -g "daemon off;" >/tmp/nginx.log 2>&1'

  READY=0
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if docker exec "$node" sh -lc 'curl -I --max-time 2 http://127.0.0.1/demo_long.mp4 >/dev/null 2>&1'; then
      READY=1
      break
    fi
    sleep 1
  done

  if [ "$READY" -ne 1 ]; then
    echo "ERROR: HTTP server did not become ready on $node"
    docker exec "$node" sh -lc 'tail -n 80 /tmp/nginx.log 2>/dev/null || true'
    exit 1
  fi
}

attach_r1_handoff_veth() {
  local net="$1"
  local bridge="$2"
  local host_if="$3"
  local ns_if="$4"
  local r1_if="$5"
  local r1_ip_cidr="$6"

  ensure_network_exists "$net"
  ensure_bridge_exists "$bridge"

  local r1_pid
  r1_pid="$(docker inspect -f '{{.State.Pid}}' clab-g7-transport-r1)"

  sudo ip link del "$host_if" 2>/dev/null || true
  sudo nsenter -t "$r1_pid" -n ip link del "$r1_if" 2>/dev/null || true

  sudo ip link add "$host_if" type veth peer name "$ns_if"
  sudo ip link set "$host_if" mtu 1500
  sudo ip link set "$host_if" master "$bridge"
  sudo ip link set "$host_if" up

  sudo ip link set "$ns_if" netns "$r1_pid"
  sudo nsenter -t "$r1_pid" -n ip link set "$ns_if" name "$r1_if"
  sudo nsenter -t "$r1_pid" -n ip link set "$r1_if" mtu 1500
  sudo nsenter -t "$r1_pid" -n ip addr flush dev "$r1_if" 2>/dev/null || true
  sudo nsenter -t "$r1_pid" -n ip addr add "$r1_ip_cidr" dev "$r1_if"
  sudo nsenter -t "$r1_pid" -n ip link set "$r1_if" up
}

clear_root_qdisc_ns() {
  local cont="$1"
  local ifname="$2"
  local pid
  pid="$(docker inspect -f '{{.State.Pid}}' "$cont")"
  sudo nsenter -t "$pid" -n tc qdisc del dev "$ifname" root 2>/dev/null || true
}

apply_tbf_qdisc_ns() {
  local cont="$1"
  local ifname="$2"
  local rate="$3"
  local burst="$4"
  local latency="$5"
  local pid
  pid="$(docker inspect -f '{{.State.Pid}}' "$cont")"
  sudo nsenter -t "$pid" -n tc qdisc del dev "$ifname" root 2>/dev/null || true
  sudo nsenter -t "$pid" -n tc qdisc replace dev "$ifname" root tbf rate "$rate" burst "$burst" latency "$latency"
  sudo nsenter -t "$pid" -n tc -s qdisc show dev "$ifname" || true
}

echo "Preparing UE containers for a clean transport run..."
for c in "${UE_CONTS[@]}"; do
  clean_routes "$c"
done

echo "Starting Containerlab transport..."
sudo containerlab deploy -t clab.yaml --reconfigure

R1_IP="$(get_priv_ip clab-g7-transport-r1)"
R2S2_IP="$(get_priv_ip clab-g7-transport-r2-s2)"
R2S1_IP="$(get_priv_ip clab-g7-transport-r2-s1)"
SVCS2_MGMT_IP="$(get_priv_ip clab-g7-transport-svc-s2)"
SVCS1_MGMT_IP="$(get_priv_ip clab-g7-transport-svc-s1)"

UPF1_IP="$(get_priv_ip upf-slice1)"
UPF2_IP="$(get_priv_ip upf-slice2)"

S2_VIDEO_IP="$(get_priv_ip "$UE_S2_VIDEO")"
S1_VIDEO_IP="$(get_priv_ip "$UE_S1_VIDEO")"

S2_BRIDGE="$(bridge_name_from_net "$HANDOFF_S2_NET")"
S1_BRIDGE="$(bridge_name_from_net "$HANDOFF_S1_NET")"

echo "Attaching r1 to dedicated handoff bridges with host-side veth pairs..."
attach_r1_handoff_veth "$HANDOFF_S2_NET" "$S2_BRIDGE" "$HOST_S2_VETH" "$NS_S2_VETH" "$R1_S2_IF" "${R1_S2_HANDOFF_IP}/29"
attach_r1_handoff_veth "$HANDOFF_S1_NET" "$S1_BRIDGE" "$HOST_S1_VETH" "$NS_S1_VETH" "$R1_S1_IF" "${R1_S1_HANDOFF_IP}/29"

echo "r1 mgmt IP:         $R1_IP"
echo "r1 handoff-s2 IP:   $R1_S2_HANDOFF_IP"
echo "r1 handoff-s1 IP:   $R1_S1_HANDOFF_IP"
echo "r2-s2 mgmt IP:      $R2S2_IP"
echo "r2-s1 mgmt IP:      $R2S1_IP"
echo "svc-s2 mgmt IP:     $SVCS2_MGMT_IP"
echo "svc-s1 mgmt IP:     $SVCS1_MGMT_IP"
echo "upf-slice1 priv IP: $UPF1_IP"
echo "upf-slice2 priv IP: $UPF2_IP"
echo "upf-slice1 handoff: $UPF1_HANDOFF_IP"
echo "upf-slice2 handoff: $UPF2_HANDOFF_IP"
echo "ue-s2-video IP:     $S2_VIDEO_IP"
echo "ue-s1-video IP:     $S1_VIDEO_IP"

echo "Adding host routes..."
sudo ip route del 192.168.200.0/24 2>/dev/null || true
sudo ip route replace 192.168.210.0/24 via "$R1_IP"
sudo ip route replace 192.168.220.0/24 via "$R1_IP"

echo "Configuring Slice 2 transport branch..."
docker exec clab-g7-transport-r1     sh -lc 'ip addr add 192.168.110.1/30 dev eth1 2>/dev/null || true; ip link set eth1 up'
docker exec clab-g7-transport-r2-s2  sh -lc 'ip addr add 192.168.110.2/30 dev eth1 2>/dev/null || true; ip link set eth1 up'
docker exec clab-g7-transport-r2-s2  sh -lc 'ip addr add 192.168.210.1/24 dev eth2 2>/dev/null || true; ip link set eth2 up'
docker exec clab-g7-transport-svc-s2 sh -lc 'ip addr add 192.168.210.2/24 dev eth1 2>/dev/null || true; ip link set eth1 up'

echo "Configuring Slice 1 transport branch..."
docker exec clab-g7-transport-r1     sh -lc 'ip addr add 192.168.120.1/30 dev eth2 2>/dev/null || true; ip link set eth2 up'
docker exec clab-g7-transport-r2-s1  sh -lc 'ip addr add 192.168.120.2/30 dev eth1 2>/dev/null || true; ip link set eth1 up'
docker exec clab-g7-transport-r2-s1  sh -lc 'ip addr add 192.168.220.1/24 dev eth2 2>/dev/null || true; ip link set eth2 up'
docker exec clab-g7-transport-svc-s1 sh -lc 'ip addr add 192.168.220.2/24 dev eth1 2>/dev/null || true; ip link set eth1 up'

echo "Enabling IPv4 forwarding on routers..."
docker exec clab-g7-transport-r1    sh -lc 'echo 1 > /proc/sys/net/ipv4/ip_forward'
docker exec clab-g7-transport-r2-s2 sh -lc 'echo 1 > /proc/sys/net/ipv4/ip_forward'
docker exec clab-g7-transport-r2-s1 sh -lc 'echo 1 > /proc/sys/net/ipv4/ip_forward'

echo "Programming routes..."
docker exec clab-g7-transport-r1    sh -lc 'ip route replace 192.168.210.0/24 via 192.168.110.2 dev eth1'
docker exec clab-g7-transport-r1    sh -lc 'ip route replace 192.168.220.0/24 via 192.168.120.2 dev eth2'
docker exec clab-g7-transport-r1    sh -lc "ip route replace 10.61.0.0/16 via $UPF2_HANDOFF_IP dev $R1_S2_IF"
docker exec clab-g7-transport-r1    sh -lc "ip route replace 10.60.0.0/16 via $UPF1_HANDOFF_IP dev $R1_S1_IF"

docker exec clab-g7-transport-r2-s2 sh -lc 'ip route replace 10.61.0.0/16 via 192.168.110.1 dev eth1'
docker exec clab-g7-transport-r2-s2 sh -lc 'ip route replace 172.31.2.0/29 via 192.168.110.1 dev eth1'
docker exec clab-g7-transport-r2-s1 sh -lc 'ip route replace 10.60.0.0/16 via 192.168.120.1 dev eth1'
docker exec clab-g7-transport-r2-s1 sh -lc 'ip route replace 172.31.1.0/29 via 192.168.120.1 dev eth1'

docker exec clab-g7-transport-svc-s2 sh -lc 'ip route replace 10.61.0.0/16 via 192.168.210.1 dev eth1'
docker exec clab-g7-transport-svc-s2 sh -lc 'ip route replace 172.31.2.0/29 via 192.168.210.1 dev eth1'
docker exec clab-g7-transport-svc-s2 sh -lc 'ip route replace 192.168.110.0/30 via 192.168.210.1 dev eth1'

docker exec clab-g7-transport-svc-s1 sh -lc 'ip route replace 10.60.0.0/16 via 192.168.220.1 dev eth1'
docker exec clab-g7-transport-svc-s1 sh -lc 'ip route replace 172.31.1.0/29 via 192.168.220.1 dev eth1'
docker exec clab-g7-transport-svc-s1 sh -lc 'ip route replace 192.168.120.0/30 via 192.168.220.1 dev eth1'

echo "Programming UPF routes toward separate service subnets..."
docker exec upf-slice2 sh -lc 'ip route del 192.168.200.0/24 2>/dev/null || true'
docker exec upf-slice1 sh -lc 'ip route del 192.168.200.0/24 2>/dev/null || true'
docker exec upf-slice2 sh -lc "ip route replace 192.168.210.0/24 via $R1_S2_HANDOFF_IP dev eth0"
docker exec upf-slice1 sh -lc "ip route replace 192.168.220.0/24 via $R1_S1_HANDOFF_IP dev eth0"

echo "Removing old direct routes from UEs..."
for c in "${UE_CONTS[@]}"; do
  clean_routes "$c"
done

echo "Preparing service nodes..."
prep_service_node clab-g7-transport-svc-s2
prep_service_node clab-g7-transport-svc-s1

echo "Clearing old demo qdiscs..."
clear_root_qdisc_ns clab-g7-transport-svc-s2 eth1
clear_root_qdisc_ns clab-g7-transport-svc-s1 eth1

if [ "$S2_TC_ENABLE" = "1" ]; then
  echo "Applying Slice 2 shared-path cap on svc-s2 eth1: rate=$S2_TC_RATE burst=$S2_TC_BURST latency=$S2_TC_LATENCY"
  apply_tbf_qdisc_ns clab-g7-transport-svc-s2 eth1 "$S2_TC_RATE" "$S2_TC_BURST" "$S2_TC_LATENCY"
else
  echo "Slice 2 shared-path cap disabled (S2_TC_ENABLE=$S2_TC_ENABLE)"
fi

echo "Pinning service routes..."
pin_service_route_prefix "$UE_S2_VIDEO" '10\.61\.' "S2 VIDEO" "$S2_SVC_IP"
pin_service_route_prefix "$UE_S2_LOAD"  '10\.61\.' "S2 LOAD"  "$S2_SVC_IP"
pin_service_route_prefix "$UE_S1_VIDEO" '10\.60\.' "S1 VIDEO" "$S1_SVC_IP"
pin_service_route_prefix "$UE_S1_LOAD"  '10\.60\.' "S1 LOAD"  "$S1_SVC_IP"

echo "Blocking opposite-slice fallback..."
block_service_ip "$UE_S2_VIDEO" "S2 VIDEO" "$S1_SVC_IP"
block_service_ip "$UE_S2_LOAD"  "S2 LOAD"  "$S1_SVC_IP"
block_service_ip "$UE_S1_VIDEO" "S1 VIDEO" "$S2_SVC_IP"
block_service_ip "$UE_S1_LOAD"  "S1 LOAD"  "$S2_SVC_IP"

echo
echo "=== Validation ==="
docker exec clab-g7-transport-r1 sh -lc "ip addr; echo; ip route"
docker exec clab-g7-transport-r1 ping -c 1 "$UPF2_HANDOFF_IP"
docker exec clab-g7-transport-r1 ping -c 1 "$UPF1_HANDOFF_IP"
docker exec clab-g7-transport-r1 ping -c 1 192.168.210.2
docker exec clab-g7-transport-r1 ping -c 1 192.168.220.2

docker exec clab-g7-transport-svc-s2 sh -lc 'curl -I --max-time 5 http://127.0.0.1/demo_long.mp4'
docker exec clab-g7-transport-svc-s1 sh -lc 'curl -I --max-time 5 http://127.0.0.1/demo_long.mp4'

validate_http "$UE_S2_VIDEO" "Slice 2 video UE" "$S2_SVC_IP"
validate_http "$UE_S2_LOAD"  "Slice 2 load UE"  "$S2_SVC_IP"
validate_http "$UE_S1_VIDEO" "Slice 1 video UE" "$S1_SVC_IP"
validate_http "$UE_S1_LOAD"  "Slice 1 load UE"  "$S1_SVC_IP"

echo "--- Route checks ---"
docker exec "$UE_S2_VIDEO" sh -lc "ip route get $S2_SVC_IP"
docker exec "$UE_S2_LOAD"  sh -lc "ip route get $S2_SVC_IP"
docker exec "$UE_S1_VIDEO" sh -lc "ip route get $S1_SVC_IP"
docker exec "$UE_S1_LOAD"  sh -lc "ip route get $S1_SVC_IP"

echo
echo "Starting VNC desktops in both video containers..."
start_vnc "$UE_S2_VIDEO"
start_vnc "$UE_S1_VIDEO"

echo "--- Slice 2 VNC listener check ---"
docker exec "$UE_S2_VIDEO" sh -lc 'ss -ltnp | egrep "5901|6080" || true'

echo "--- Slice 1 VNC listener check ---"
docker exec "$UE_S1_VIDEO" sh -lc 'ss -ltnp | egrep "5901|6080" || true'

echo
echo
echo "Transport network ready."
echo "Slice 2 shared-path cap: ${S2_TC_RATE} on svc-s2 eth1"
echo "Slice 1 path: unchanged / no cap"
echo
echo "=== DEMO COMMANDS ==="
echo "1) On your computer:"
echo "  ssh -L 6080:${S2_VIDEO_IP}:6080 -L 6081:${S1_VIDEO_IP}:6080 -l group7 134.117.92.142"
echo
echo "2) Open:"
echo "  http://localhost:6080/vnc_lite.html"
echo "  http://localhost:6081/vnc_lite.html"
echo "  VNC password: net4901*"
echo
echo "3) In the Slice 2 video desktop terminal:"
echo "  ffplay -fflags nobuffer -flags low_delay -framedrop -sync ext http://${S2_SVC_IP}/demo_long.mp4"
echo
echo "4) In the Slice 1 video desktop terminal:"
echo "  ffplay -fflags nobuffer -flags low_delay -framedrop -sync ext http://${S1_SVC_IP}/demo_long.mp4"
echo
echo "5) Let both videos play for 8-10 seconds before starting any load."
echo
echo "6) Shared-UPF load on Slice 2 (run as separate commands):"
echo "  docker exec -it ue-s2-load sh -lc 'stopload'"
echo "  docker exec -it ue-s2-load sh -lc 'checksvc ${S2_SVC_IP}'"
echo "  docker exec -it ue-s2-load sh -lc 'hitload 24 uesimtun0'"
echo "  sleep 2"
echo "  docker exec -it ue-s2-load sh -lc 'pgrep -a curl || true; echo; ss -tanp | grep \":80\" || true'"
echo "  # if needed: 32, 40, 48"
echo
echo "7) What good shared-UPF load looks like:"
echo "  - most or all sockets should be ESTAB to ${S2_SVC_IP}:80"
echo "  - a few transient SYN-SENT lines right after startup are OK if they become ESTAB on the next check"
echo
echo "8) Stop shared-UPF load:"
echo "  docker exec -it ue-s2-load sh -lc 'stopload'"
echo
echo "9) Optional separate-UPF local load on Slice 1:"
echo "  docker exec -it ue-s1-load sh -lc 'stopload'"
echo "  docker exec -it ue-s1-load sh -lc 'checksvc ${S1_SVC_IP}'"
echo "  docker exec -it ue-s1-load sh -lc 'hitload 24 uesimtun0'"
echo "  sleep 2"
echo "  docker exec -it ue-s1-load sh -lc 'pgrep -a curl || true; echo; ss -tanp | grep \":80\" || true'"
echo "  docker exec -it ue-s1-load sh -lc 'stopload'"
echo
echo "10) Quick CLI health checks:"
echo "  docker exec -it ue-s2-video sh -lc 'checksvc ${S2_SVC_IP}'"
echo "  docker exec -it ue-s2-load  sh -lc 'checksvc ${S2_SVC_IP}'"
echo "  docker exec -it ue-s1-video sh -lc 'checksvc ${S1_SVC_IP}'"
echo "  docker exec -it ue-s1-load  sh -lc 'checksvc ${S1_SVC_IP}'"
echo
echo "11) Quick resource snapshot during load:"
echo "  docker stats --no-stream upf-slice2 ue-s2-load ue-s2-video clab-g7-transport-svc-s2"
echo "  docker stats --no-stream upf-slice1 ue-s1-load ue-s1-video clab-g7-transport-svc-s1"
echo
echo "12) If any load UE fails checksvc, recover cleanly:"
echo "  ./start_ue.sh"
echo "  ./start_clab_transport.sh"
