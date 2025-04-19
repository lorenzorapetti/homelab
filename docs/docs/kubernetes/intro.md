---
sidebar_position: 1
sidebar_label: Introduction
---

# Kubernetes

This document introduces my Kubernetes cluster setup in my homelab. I use **k3s** as a lightweight Kubernetes distribution, **Traefik** as the ingress controller for managing external access, and **Longhorn** for distributed block storage to handle persistent volumes efficiently.

## Hardware

I have three HP EliteDesk 800 G4 mini PCs, each equipped with an Intel i5-8500T CPU, 16GB of RAM, and a 1TB SSD.

## Software

All three PCs have Proxmox installed, and I run k3s on top of it using three VMs, one master and two workers.
All VMs are configured with 10GB of RAM and 4 CPU cores.
