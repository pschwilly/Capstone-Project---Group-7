#!/bin/bash
echo "Installing VNC dependencies..."
docker exec ueransim apt-get update -qq
docker exec ueransim apt-get install -y tightvncserver xfce4 xfce4-terminal novnc dbus-x11 ffmpeg curl python3 python3-pip

echo "Installing websockify..."
docker exec ueransim pip3 install websockify --break-system-packages

echo "Starting VNC server..."
docker exec ueransim sh -lc '
  export USER=root
  vncserver -kill :1 2>/dev/null || true
  rm -rf /tmp/.X1-lock /tmp/.X11-unix
  mkdir -p /tmp/.X11-unix /root/.vnc
  chmod 1777 /tmp/.X11-unix
  echo "net4901*" | vncpasswd -f > /root/.vnc/passwd
  chmod 600 /root/.vnc/passwd
  vncserver :1 -geometry 1280x720 -depth 24
'

sleep 3
echo "Starting desktop..."
docker exec -d ueransim sh -lc 'DISPLAY=:1 startxfce4'

sleep 5
echo "Starting websockify..."
docker exec -d ueransim sh -lc 'websockify --web /usr/share/novnc/ 6080 localhost:5901 >/tmp/websockify.log 2>&1'

sleep 3
echo "Copying subway.mp4 to svc..."
docker cp /home/group7/free5gc-compose/subway.mp4 clab-g7-transport-svc:/var/lib/nginx/html/subway.mp4

echo "Done. Open: http://localhost:6080/vnc.html"
