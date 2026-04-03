FROM free5gc/ueransim:latest

USER root
RUN apt-get update && \
    apt-get install -y iperf3 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*
