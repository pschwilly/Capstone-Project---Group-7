#!/bin/bash
set -euo pipefail

cd ~/free5gc-compose

GNB_CONT="gnb"

UE_S2_VIDEO="ue-s2-video"
UE_S2_LOAD="ue-s2-load"
UE_S1_VIDEO="ue-s1-video"
UE_S1_LOAD="ue-s1-load"

UE_CONTS=("$UE_S2_VIDEO" "$UE_S2_LOAD" "$UE_S1_VIDEO" "$UE_S1_LOAD")

S2_SVC_IP="192.168.210.2"
S1_SVC_IP="192.168.220.2"

SVC_S2_CONT="clab-g7-transport-svc-s2"
SVC_S1_CONT="clab-g7-transport-svc-s1"

wait_exec() {
  local c="$1"
  local i=1
  while [ "$i" -le 30 ]; do
    if docker exec "$c" sh -lc 'true' >/dev/null 2>&1; then
      return 0
    fi
    i=$((i+1))
    sleep 1
  done
  echo "ERROR: container $c did not become ready."
  exit 1
}

wait_for_gnb() {
  echo "Waiting for gNB process..."
  docker exec "$GNB_CONT" sh -lc '
    i=1
    while [ "$i" -le 30 ]; do
      if pgrep -x nr-gnb >/dev/null 2>&1; then
        exit 0
      fi
      i=$((i+1))
      sleep 1
    done
    echo "ERROR: nr-gnb did not come up."
    exit 1
  '
}

wait_for_tunnel_prefix() {
  local c="$1"
  local prefix="$2"
  local label="$3"
  local log="$4"

  docker exec "$c" sh -lc "
    i=1
    while [ \"\$i\" -le 35 ]; do
      if ip -o -4 addr show | grep -q '${prefix}'; then
        exit 0
      fi
      i=\$((i+1))
      sleep 1
    done
    echo 'ERROR: $label tunnel did not come up for prefix ${prefix}.'
    tail -n 80 $log 2>/dev/null || true
    exit 1
  "
}

pin_service_route_prefix() {
  local c="$1"
  local prefix="$2"
  local label="$3"
  local dst="$4"

  docker exec "$c" sh -lc "
    TUN=\$(ip -o -4 addr show | sed -n '/${prefix}/{s/^[0-9]\\+: \\([^ ]*\\).*/\\1/p;q}')
    if [ -z \"\$TUN\" ]; then
      echo 'ERROR: no active tunnel found for $label using prefix ${prefix}.'
      exit 1
    fi
    SRC=\$(ip -o -4 addr show \"\$TUN\" | sed -n 's/.* inet \\([0-9.]*\\)\\/.*/\\1/p')
    ip route replace ${dst}/32 dev \"\$TUN\" src \"\$SRC\"
    ip route flush cache 2>/dev/null || true
    echo '$label pinned ${dst} via' \"\$TUN\" 'src' \"\$SRC\"
    ip route get ${dst}
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

transport_service_present() {
  docker ps --format '{{.Names}}' | grep -qx "$SVC_S2_CONT" &&
  docker ps --format '{{.Names}}' | grep -qx "$SVC_S1_CONT"
}

start_one_ue() {
  local c="$1"
  docker exec -d "$c" sh -lc 'cd /ueransim && ./nr-ue -c ./config/uecfg.yaml >/tmp/ue.log 2>&1'
}

clean_ue_container() {
  local c="$1"
  docker exec "$c" sh -lc '
    stopload 2>/dev/null || true

    for p in $(ps -ef | awk "/ffplay|nr-ue/ && !/awk/ {print \$2}"); do
      kill -9 "$p" 2>/dev/null || true
    done

    rm -f /tmp/dl*.log /tmp/dl*.pid /tmp/ue.log /tmp/ue-*.log

    ip route del 192.168.200.2/32 2>/dev/null || true
    ip route del 192.168.210.2/32 2>/dev/null || true
    ip route del 192.168.220.2/32 2>/dev/null || true
    ip route del 192.168.200.0/24 2>/dev/null || true
    ip route del 192.168.210.0/24 2>/dev/null || true
    ip route del 192.168.220.0/24 2>/dev/null || true
    ip route flush cache 2>/dev/null || true

    for i in uesimtun0 uesimtun1 uesimtun2 uesimtun3 uesimtun4 uesimtun5; do
      ip link del "$i" 2>/dev/null || true
    done
  '
}

recover_one_ue() {
  local c="$1"
  local prefix="$2"
  local label="$3"
  local svc_ip="$4"
  local block_ip="$5"

  echo "Recovering $label with a clean reattach..."
  clean_ue_container "$c"
  sleep 1
  start_one_ue "$c"
  wait_for_tunnel_prefix "$c" "$prefix" "$label" "/tmp/ue.log"
  pin_service_route_prefix "$c" "$prefix" "$label" "$svc_ip"
  block_service_ip "$c" "$label" "$block_ip"
}

check_or_recover_service() {
  local c="$1"
  local label="$2"
  local prefix="$3"
  local svc_ip="$4"
  local block_ip="$5"

  echo "=== $label end-to-end service health ==="
  if docker exec "$c" sh -lc "/usr/local/bin/checksvc $svc_ip"; then
    echo "$label service health OK."
    return 0
  fi

  echo "WARN: $label failed end-to-end service health. Retrying once with a clean UE reattach..."
  recover_one_ue "$c" "$prefix" "$label" "$svc_ip" "$block_ip"

  echo "=== $label end-to-end service health after reattach ==="
  docker exec "$c" sh -lc "/usr/local/bin/checksvc $svc_ip"
  echo "$label service health OK after reattach."
}

install_helpers() {
  local tmpdir
  tmpdir="$(mktemp -d)"

  cat > "$tmpdir/hitload" <<'EOS'
#!/bin/sh
N="${1:-8}"
IFACE="${2:-}"
URL="${3:-}"

if [ -z "$IFACE" ]; then
  IFACE="$(ip -o link show | awk -F': ' '/uesimtun/{print $2; exit}')"
fi

if [ -z "$IFACE" ]; then
  echo "ERROR: no UE tunnel interface found."
  exit 1
fi

if [ -z "$URL" ]; then
  SRC="$(ip -o -4 addr show "$IFACE" | sed -n 's/.* inet \([0-9.]*\)\/.*/\1/p')"
  case "$SRC" in
    10.61.*) URL="http://192.168.210.2/file_2G.bin" ;;
    10.60.*) URL="http://192.168.220.2/file_2G.bin" ;;
    *)
      echo "ERROR: could not infer default load URL from source IP [$SRC] on [$IFACE]."
      echo "Use: hitload <flows> <iface> <url>"
      exit 1
      ;;
  esac
fi

HOST="$(echo "$URL" | sed -n 's#^http://\([^/]*\)/.*#\1#p')"
if [ -z "$HOST" ]; then
  echo "ERROR: could not parse host from URL [$URL]."
  exit 1
fi

echo "=== pre-load health check ==="
ping -c 2 -W 2 "$HOST" >/tmp/hitload_ping.log 2>&1 || {
  cat /tmp/hitload_ping.log 2>/dev/null || true
  echo "ERROR: $HOST is not reachable from $IFACE. Refusing to start load."
  exit 1
}

curl --interface "$IFACE" -I --max-time 5 "$URL" >/tmp/hitload_head.log 2>&1 || {
  cat /tmp/hitload_head.log 2>/dev/null || true
  echo "ERROR: $URL is not reachable from $IFACE. Refusing to start load."
  exit 1
}

echo "pre-load health OK on $IFACE -> $URL"

pkill -f "192.168.200.2/file_2G.bin" 2>/dev/null || true
pkill -f "192.168.210.2/file_2G.bin" 2>/dev/null || true
pkill -f "192.168.220.2/file_2G.bin" 2>/dev/null || true
pkill -f "file_2G.bin" 2>/dev/null || true
rm -f /tmp/dl*.log 2>/dev/null || true

i=1
while [ "$i" -le "$N" ]; do
  nohup sh -c "while :; do curl --interface \"$IFACE\" -L \"$URL\" -o /dev/null; done" \
    >/tmp/dl${i}.log 2>&1 </dev/null &
  i=$((i+1))
done

sleep 1
echo "=== active curl processes ==="
ps | grep "[c]url" || true
echo
echo "=== active HTTP sessions ==="
ss -tanp 2>/dev/null | grep ":80" || true
echo
echo "load-started with $N flows on $IFACE -> $URL"
EOS

  cat > "$tmpdir/stopload" <<'EOS'
#!/bin/sh

pkill -f "192.168.200.2/file_2G.bin" 2>/dev/null || true
pkill -f "192.168.210.2/file_2G.bin" 2>/dev/null || true
pkill -f "192.168.220.2/file_2G.bin" 2>/dev/null || true
pkill -f "file_2G.bin" 2>/dev/null || true
pkill -f "while :; do curl" 2>/dev/null || true
pkill -f "curl --interface" 2>/dev/null || true
pkill -x curl 2>/dev/null || true
pkill -x wget 2>/dev/null || true
pkill -x aria2c 2>/dev/null || true

rm -f /tmp/dl*.log /tmp/dl*.pid /tmp/hitload_ping.log /tmp/hitload_head.log 2>/dev/null || true
ip route flush cache 2>/dev/null || true

i=1
while [ "$i" -le 20 ]; do
  CURL_LEFT="$(ps | grep "[c]url" || true)"
  HTTP_LEFT="$(ss -tanp 2>/dev/null | grep ":80" || true)"
  if [ -z "$CURL_LEFT" ] && [ -z "$HTTP_LEFT" ]; then
    break
  fi
  sleep 0.25
  i=$((i+1))
done

echo "=== remaining curl processes ==="
ps | grep "[c]url" || true
echo
echo "=== remaining HTTP sessions ==="
ss -tanp 2>/dev/null | grep ":80" || true
echo
echo load-stopped
EOS

  cat > "$tmpdir/checksvc" <<'EOS'
#!/bin/sh
SVC_IP="${1:-}"
IFACE="${2:-}"

if [ -z "$IFACE" ]; then
  IFACE="$(ip -o link show | awk -F': ' '/uesimtun/{print $2; exit}')"
fi

if [ -z "$IFACE" ]; then
  echo "ERROR: no UE tunnel interface found."
  exit 1
fi

if [ -z "$SVC_IP" ]; then
  SRC="$(ip -o -4 addr show "$IFACE" | sed -n 's/.* inet \([0-9.]*\)\/.*/\1/p')"
  case "$SRC" in
    10.61.*) SVC_IP="192.168.210.2" ;;
    10.60.*) SVC_IP="192.168.220.2" ;;
    *)
      echo "ERROR: could not infer service IP from source IP [$SRC] on [$IFACE]."
      echo "Use: checksvc <service-ip> [iface]"
      exit 1
      ;;
  esac
fi

echo "=== route ==="
ip route get "$SVC_IP" || exit 1
echo
echo "=== ping ==="
ping -c 2 -W 2 "$SVC_IP" || exit 1
echo
echo "=== curl HEAD ==="
curl --interface "$IFACE" -I --max-time 5 "http://$SVC_IP/file_2G.bin" || exit 1
echo
echo "service-health OK on $IFACE -> $SVC_IP"
EOS

  for c in "${UE_CONTS[@]}"; do
    docker cp "$tmpdir/hitload" "$c:/usr/local/bin/hitload"
    docker cp "$tmpdir/stopload" "$c:/usr/local/bin/stopload"
    docker cp "$tmpdir/checksvc" "$c:/usr/local/bin/checksvc"
    docker exec "$c" sh -lc 'chmod +x /usr/local/bin/hitload /usr/local/bin/stopload /usr/local/bin/checksvc'
  done

  rm -rf "$tmpdir"
}

show_one_ue() {
  local c="$1"
  local label="$2"
  echo "=== $label processes ==="
  docker exec "$c" sh -lc 'ps -ef | egrep "nr-ue" | grep -v grep || true'
  echo "=== $label tunnel summary ==="
  docker exec "$c" sh -lc 'ip -br addr | egrep "uesimtun|eth|lo" || true'
  echo "=== $label route summary ==="
  docker exec "$c" sh -lc 'ip route || true'
  echo "=== $label service path checks ==="
  docker exec "$c" sh -lc "ip route get ${S2_SVC_IP} 2>/dev/null || true; ip route get ${S1_SVC_IP} 2>/dev/null || true"
  echo "=== $label log tail ==="
  docker exec "$c" sh -lc 'tail -n 25 /tmp/ue.log 2>/dev/null || true'
  echo
}

echo "Ensuring gNB + 4 UE containers are up..."
docker compose up -d gnb ue-s2-video ue-s2-load ue-s1-video ue-s1-load >/dev/null

echo "Restarting control-plane containers for a clean UE bring-up..."
docker restart smf-slice1 smf-slice2 amf gnb >/dev/null
sleep 8

wait_exec "$GNB_CONT"
for c in "${UE_CONTS[@]}"; do
  wait_exec "$c"
done

wait_for_gnb

echo "Installing hitload/stopload/checksvc helpers into UE containers..."
install_helpers

echo "Cleaning old UE state..."
for c in "${UE_CONTS[@]}"; do
  clean_ue_container "$c"
done
sleep 2

echo "Starting Slice 2 video UE..."
start_one_ue "$UE_S2_VIDEO"

echo "Starting Slice 2 load UE..."
start_one_ue "$UE_S2_LOAD"

echo "Starting Slice 1 video UE..."
start_one_ue "$UE_S1_VIDEO"

echo "Starting Slice 1 load UE..."
start_one_ue "$UE_S1_LOAD"

echo "Waiting for Slice 2 video tunnel..."
wait_for_tunnel_prefix "$UE_S2_VIDEO" '10\.61\.' "Slice 2 video UE" "/tmp/ue.log"

echo "Waiting for Slice 2 load tunnel..."
wait_for_tunnel_prefix "$UE_S2_LOAD" '10\.61\.' "Slice 2 load UE" "/tmp/ue.log"

echo "Waiting for Slice 1 video tunnel..."
wait_for_tunnel_prefix "$UE_S1_VIDEO" '10\.60\.' "Slice 1 video UE" "/tmp/ue.log"

echo "Waiting for Slice 1 load tunnel..."
wait_for_tunnel_prefix "$UE_S1_LOAD" '10\.60\.' "Slice 1 load UE" "/tmp/ue.log"

echo "Re-applying per-slice service route pinning..."
pin_service_route_prefix "$UE_S2_VIDEO" '10\.61\.' "S2 VIDEO" "$S2_SVC_IP"
pin_service_route_prefix "$UE_S2_LOAD"  '10\.61\.' "S2 LOAD"  "$S2_SVC_IP"
pin_service_route_prefix "$UE_S1_VIDEO" '10\.60\.' "S1 VIDEO" "$S1_SVC_IP"
pin_service_route_prefix "$UE_S1_LOAD"  '10\.60\.' "S1 LOAD"  "$S1_SVC_IP"

echo "Blocking opposite-slice service fallback on eth0..."
block_service_ip "$UE_S2_VIDEO" "S2 VIDEO" "$S1_SVC_IP"
block_service_ip "$UE_S2_LOAD"  "S2 LOAD"  "$S1_SVC_IP"
block_service_ip "$UE_S1_VIDEO" "S1 VIDEO" "$S2_SVC_IP"
block_service_ip "$UE_S1_LOAD"  "S1 LOAD"  "$S2_SVC_IP"

if transport_service_present; then
  echo
  echo "Transport/service containers detected. Running end-to-end service health gate..."
  check_or_recover_service "$UE_S2_VIDEO" "S2 VIDEO" '10\.61\.' "$S2_SVC_IP" "$S1_SVC_IP"
  check_or_recover_service "$UE_S2_LOAD"  "S2 LOAD"  '10\.61\.' "$S2_SVC_IP" "$S1_SVC_IP"
  check_or_recover_service "$UE_S1_VIDEO" "S1 VIDEO" '10\.60\.' "$S1_SVC_IP" "$S2_SVC_IP"
  check_or_recover_service "$UE_S1_LOAD"  "S1 LOAD"  '10\.60\.' "$S1_SVC_IP" "$S2_SVC_IP"
else
  echo
  echo "Transport/service containers are not up yet."
  echo "Skipping end-to-end ping/curl health checks for now."
  echo "After ./start_clab_transport.sh, run the printed checksvc commands before starting the demo."
fi

echo "=== gNB process summary ==="
docker exec "$GNB_CONT" sh -lc 'ps -ef | egrep "nr-gnb" | grep -v grep || true'
echo "=== gNB interface summary ==="
docker exec "$GNB_CONT" sh -lc 'ip -br addr | egrep "eth|lo" || true'
echo

show_one_ue "$UE_S2_VIDEO" "Slice 2 VIDEO"
show_one_ue "$UE_S2_LOAD" "Slice 2 LOAD"
show_one_ue "$UE_S1_VIDEO" "Slice 1 VIDEO"
show_one_ue "$UE_S1_LOAD" "Slice 1 LOAD"

echo
echo "=== PRE-DEMO HEALTH GATE ==="
echo "After ./start_clab_transport.sh, run:"
echo "  docker exec -it ue-s2-video sh -lc 'checksvc $S2_SVC_IP'"
echo "  docker exec -it ue-s2-load  sh -lc 'checksvc $S2_SVC_IP'"
echo "  docker exec -it ue-s1-video sh -lc 'checksvc $S1_SVC_IP'"
echo "  docker exec -it ue-s1-load  sh -lc 'checksvc $S1_SVC_IP'"
echo
echo "Only start load if the checksvc command passes."

echo
echo "=== SAFE LOAD USAGE ==="
echo "Slice 2 load:"
echo "  docker exec -it ue-s2-load sh -lc 'stopload'"
echo "  docker exec -it ue-s2-load sh -lc 'checksvc $S2_SVC_IP'"
echo "  docker exec -it ue-s2-load sh -lc 'hitload 24 uesimtun0'"
echo "  docker exec -it ue-s2-load sh -lc 'pgrep -a curl || true; echo; ss -tanp | grep \":80\" || true'"
echo "  docker exec -it ue-s2-load sh -lc 'stopload'"
echo
echo "Slice 1 load:"
echo "  docker exec -it ue-s1-load sh -lc 'stopload'"
echo "  docker exec -it ue-s1-load sh -lc 'checksvc $S1_SVC_IP'"
echo "  docker exec -it ue-s1-load sh -lc 'hitload 24 uesimtun0'"
echo "  docker exec -it ue-s1-load sh -lc 'pgrep -a curl || true; echo; ss -tanp | grep \":80\" || true'"
echo "  docker exec -it ue-s1-load sh -lc 'stopload'"
echo
echo "Next:"
echo "  ./start_clab_transport.sh"
echo
echo "start_ue.sh completed."
