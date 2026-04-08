# Secure Network and User Services on Virtual Sliced 5G Infrastructure

A capstone project by Group 7 — Carleton University (NET4901)

## Overview

This project deploys a fully functional 5G Standalone (SA) core network using open-source tools, demonstrating network slicing with true user-plane isolation. Two independent slices are provisioned, each with a dedicated SMF and UPF, connected through a simulated multi-hop transport network built with Containerlab. The demo validates that traffic flooding on one slice has zero impact on another.

## Team

- Patrick Schwilden
- Karar Alfaris
- Nicolas Gagnon
- Jahnvi Patel
- Jayden Côté
- Christina Ulett

**Supervisor:** Dr. Ashraf Matrawy — Carleton University

---

## Architecture

```
                          ┌─────────────────────────────────────┐
                          │           Free5GC Core               │
  UEs (UERANSIM)          │  AMF / NRF / UDM / AUSF / PCF / NSSF│
       │                  │                                       │
       ▼                  │  SMF-Slice1 ──N4──► UPF-Slice1       │
  gNB (UERANSIM) ─NGAP──► │                                       │
                          │  SMF-Slice2 ──N4──► UPF-Slice2       │
                          └────────────┬────────────┬────────────┘
                                       │            │
                              GTP-U    │            │ GTP-U
                                       ▼            ▼
                          ┌─────── Containerlab Transport ───────┐
                          │                                       │
                          │  UPF-Slice1 ──► r1 ──► r2-s1 ──► svc-s1 (192.168.220.2)
                          │  UPF-Slice2 ──► r1 ──► r2-s2 ──► svc-s2 (192.168.210.2)
                          │                                       │
                          └───────────────────────────────────────┘
```

### Network Slices

| Slice | SST | SD | UE Pool | UPF | Service Node |
|-------|-----|----|---------|-----|--------------|
| Slice 1 | 1 | 010203 | 10.60.0.0/16 | upf-slice1 | 192.168.220.2 |
| Slice 2 | 1 | 112233 | 10.61.0.0/16 | upf-slice2 | 192.168.210.2 |

### UE Containers

| Container | Role | Slice | Tunnel IP |
|-----------|------|-------|-----------|
| ue-s2-video | Video streaming UE | Slice 2 | 10.61.100.12 |
| ue-s2-load | Load generating UE | Slice 2 | 10.61.100.11 |
| ue-s1-video | Video streaming UE | Slice 1 | 10.60.100.13 |
| ue-s1-load | Load generating UE | Slice 1 | 10.60.100.14 |

---

## Technology Stack

| Component | Tool |
|-----------|------|
| 5G Core | Free5GC v4.1.0 |
| RAN / UE Emulation | UERANSIM |
| Transport Network | Containerlab (Alpine Linux routers) |
| Containerization | Docker / Docker Compose |
| Video Service | nginx + ffmpeg |
| Traffic Generation | curl (hitload script) |
| Video Playback | ffplay (via noVNC) |

---

## Prerequisites

- Ubuntu 22.04
- Docker and Docker Compose
- Containerlab
- Kernel module: gtp5g

---

## Setup

### 1. Start the 5G Core

```bash
docker compose up -d
```

### 2. Start UEs

```bash
./start_ue.sh
```

This script starts the gNB and all 4 UE containers, registers them with the core, brings up GTP tunnels, and installs the hitload/stopload tools.

### 3. Start Transport Network

```bash
./start_clab_transport.sh
```

This script deploys the Containerlab topology, configures per-slice routing, encodes the demo video, starts nginx and iperf3 on both service nodes, and launches noVNC desktops in both video UE containers.

### 4. SSH Tunnel (on your laptop)

```bash
ssh -L 6080:10.100.200.22:6080 -L 6081:10.100.200.19:6080 -l group7 134.117.92.142
```

Open:
- http://localhost:6080/vnc_lite.html — Slice 2 video UE
- http://localhost:6081/vnc_lite.html — Slice 1 video UE
- Password: `net4901*`

---

## Demo

### Start video playback

In Slice 2 noVNC terminal (6080):
```bash
ffplay -fflags nobuffer -flags low_delay -framedrop -sync ext http://192.168.210.2/demo_long.mp4
```

In Slice 1 noVNC terminal (6081):
```bash
ffplay -fflags nobuffer -flags low_delay -framedrop -sync ext http://192.168.220.2/demo_long.mp4
```

Let both videos play for 8-10 seconds before starting any load.

---

### Scenario 1 — Shared UPF (degradation)

Both the video UE and load UE are on Slice 2, sharing the same UPF. When the load UE generates traffic, it competes directly with the video UE for bandwidth.

```bash
docker exec -it ue-s2-load sh -lc 'hitload 24 uesimtun0'
```

**Result:** Slice 2 video stutters and degrades. Slice 1 is completely unaffected.

Stop the load:
```bash
docker exec -it ue-s2-load sh -lc 'stopload'
```

---

### Scenario 2 — Separate UPF (isolation)

The load UE is on Slice 1, which has its own dedicated UPF and independent transport path. Traffic on Slice 1 cannot affect Slice 2.

```bash
docker exec -it ue-s1-load sh -lc 'hitload 24 uesimtun0'
```

**Result:** Both videos remain smooth. Isolation is verified.

Stop the load:
```bash
docker exec -it ue-s1-load sh -lc 'stopload'
```

---

## Key Results

| Scenario | Slice 2 Throughput | Video Quality |
|----------|-------------------|---------------|
| Baseline (no load) | ~34 MB/s | Smooth |
| Shared UPF under load | Degraded | Stutters |
| Separate UPF under load | ~34 MB/s | Smooth |

---

## Recovery

If anything breaks:

```bash
./start_ue.sh
./start_clab_transport.sh
```

---

## Repository Structure

```
├── config/                    # Free5GC and UERANSIM config files
├── docker-compose.yaml        # Main 5G core stack
├── clab.yaml                  # Containerlab transport topology
├── start_ue.sh                # Start gNB and all 4 UEs
├── start_clab_transport.sh    # Deploy transport network and services
├── fix_vnc.sh                 # Fix VNC if desktop crashes
└── README.md
```
