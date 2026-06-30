#!/bin/bash
# scripts/setup-dev.sh — Prepara el entorno de desarrollo local via Docker
# Uso desde Windows/Linux: ./scripts/setup-dev.sh

set -euo pipefail

IMAGE="linsi-os-builder"
CONTAINER="linsi-build"

echo "[*] Construyendo imagen Docker de build..."
docker build -t "$IMAGE" - << 'DOCKERFILE'
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y \
    live-build \
    debootstrap \
    squashfs-tools \
    xorriso \
    syslinux-utils \
    isolinux \
    git \
    make \
    sudo \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /workspace
DOCKERFILE

echo "[*] Iniciando contenedor de build..."
docker run --rm -it \
    --privileged \
    --name "$CONTAINER" \
    -v "$(pwd):/workspace" \
    "$IMAGE" \
    bash -c "cd /workspace && bash scripts/build-iso.sh"
