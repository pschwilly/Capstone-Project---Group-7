#!/bin/bash
echo "Starting UE1 (slice 1)..."
docker exec -d ueransim sh -lc './nr-ue -c ./config/uecfg.yaml > /tmp/ue1.log 2>&1'
sleep 3
echo "Starting UE2 (slice 2 - video)..."
docker exec -d ueransim sh -lc './nr-ue -c ./config/uecfg-video.yaml > /tmp/ue2.log 2>&1'
sleep 3
echo "Checking tunnels..."
docker exec ueransim ip addr show | grep uesimtun
echo "Done."
