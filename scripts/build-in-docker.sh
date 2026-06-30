#!/usr/bin/env bash
#
# scripts/build-in-docker.sh
#
# Runs the full ISO build inside an ephemeral Docker container.
# Use this when building from Windows (WSL2/Git Bash) or macOS.
#
# Requirements: Docker with --privileged support (Docker Desktop satisfies this).
#
# Usage:
#   ./scripts/build-in-docker.sh [--clean]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="ubuntu:24.04"
CONTAINER_NAME="linsi-os-build"

CLEAN_FLAG=""
if [[ "${1:-}" == "--clean" ]]; then
    CLEAN_FLAG="--clean"
fi

echo "[docker-build] Starting build container..."
echo "[docker-build] Repository: ${REPO_ROOT}"
echo "[docker-build] Image: ${IMAGE}"

docker run \
    --rm \
    --name "${CONTAINER_NAME}" \
    --privileged \
    --volume "${REPO_ROOT}:/workspace" \
    --workdir /workspace \
    "${IMAGE}" \
    bash -c "
        set -euo pipefail
        export DEBIAN_FRONTEND=noninteractive

        echo '[container] Installing build dependencies...'
        apt-get update -q
        apt-get install -y --no-install-recommends \
            live-build \
            debootstrap \
            equivs \
            xorriso \
            isolinux \
            syslinux-efi \
            grub-efi-amd64-bin \
            grub-pc-bin \
            mtools \
            dosfstools \
            ca-certificates \
            curl \
            wget \
            gpg \
            apt-utils

        echo '[container] Running build...'
        cd /workspace
        bash build/build.sh ${CLEAN_FLAG}
    "

echo "[docker-build] Done. ISO is in output/"
