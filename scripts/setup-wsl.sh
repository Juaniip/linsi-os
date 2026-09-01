#!/usr/bin/env bash
# ==============================================================================
# LINSI-OS · Fase 0 — Alternativa sin Docker: WSL2 (Ubuntu)
# ------------------------------------------------------------------------------
# La guía plantea el "Taller" como un contenedor Docker para NO heredar
# dependencias del host. Si preferís trabajar directo en WSL2 (sin Docker),
# este script te deja el mismo entorno de compilación dentro de tu propia
# distro Ubuntu de WSL — al costo de que ya no está 100% aislado del resto
# de tu sistema Windows/WSL (paquetes que ya tengas instalados sí influyen).
#
# Requisitos previos (en Windows, PowerShell como administrador):
#   wsl --install -d Ubuntu-24.04
#
# Uso (adentro de la distro WSL):
#   chmod +x setup-wsl.sh
#   ./setup-wsl.sh
# ==============================================================================
set -euo pipefail

if ! grep -qi microsoft /proc/version 2>/dev/null; then
    echo "Aviso: esto no parece ser WSL. Podés seguir igual, pero está pensado" >&2
    echo "para correr dentro de una distro WSL2 (Ubuntu)." >&2
fi

echo "==> Instalando dependencias de build (equivalentes al Dockerfile de Fase 0)"
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
    build-essential bison flex gawk m4 texinfo help2man gperf \
    autoconf automake libtool pkg-config patch rsync cpio bc file \
    python3 python3-pip \
    libncurses-dev libssl-dev libelf-dev zlib1g-dev \
    xz-utils bzip2 unzip wget curl git ca-certificates \
    squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin mtools dosfstools \
    clang lld

# --- Estructura del "taller" ---------------------------------------------------
# En Docker esto vive en /lfs; en WSL lo dejamos en $HOME para no pelear con
# permisos de root en el filesystem de la distro.
export LFS="${LFS:-$HOME/linsi-os-lfs}"
mkdir -p "${LFS}/sources" "${LFS}/tools" "${LFS}/build"

echo
echo "==> Entorno WSL listo."
echo "    LFS=${LFS}"
echo
echo "    Para compilar el cross-toolchain (Binutils + cabeceras + GCC), corré:"
echo "      LFS=${LFS} LFS_TGT=x86_64-linsi-linux-gnu ./build-cross-toolchain.sh"
echo
echo "    Nota: build-cross-toolchain.sh y env.sh son los mismos scripts que"
echo "    usa la imagen Docker — no hay que duplicar lógica, sólo cambia dónde"
echo "    corren (contenedor vs. tu distro WSL) y el valor de \$LFS."
