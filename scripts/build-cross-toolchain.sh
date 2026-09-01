#!/usr/bin/env bash
# ==============================================================================
# LINSI-OS · Fase 0 — "El Taller"
# ------------------------------------------------------------------------------
# Compila el cross-compiler (Binutils + GCC) y las cabeceras de la API de Linux,
# tal como describe la Fase 0 de la guía: binarios completamente independientes
# del host, listos para forjar el kernel (Fase 1) y el espacio de usuario
# (Fase 2) de LINSI-OS.
#
# Sigue el enfoque estándar tipo LFS (Linux From Scratch), capítulo 5:
#   1. Binutils (pass 1)      -> ensamblador/linker cruzados
#   2. Cabeceras API de Linux -> para que glibc sepa hablar con el kernel
#   3. GCC (pass 1)           -> compilador cruzado "sólo C", sin libc todavía
#
# Uso:
#   scripts/build-cross-toolchain.sh              # corre los 3 pasos
#   scripts/build-cross-toolchain.sh binutils     # corre un paso puntual
#   scripts/build-cross-toolchain.sh headers
#   scripts/build-cross-toolchain.sh gcc
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/lfs/scripts/env.sh
source "${SCRIPT_DIR}/env.sh"

log()  { printf '\n\033[1;36m[fase0]\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m[fase0][error]\033[0m %s\n' "$*" >&2; exit 1; }

mkdir -p "${LFS_SOURCES}" "${LFS_TOOLS}" "${LFS_BUILD}"
cd "${LFS_SOURCES}"

# ------------------------------------------------------------------------------
# Descarga (con reintento simple + skip si ya existe)
# ------------------------------------------------------------------------------
fetch() {
    local url="$1" out="$2"
    if [[ -f "${out}" ]]; then
        log "ya descargado: ${out}"
        return 0
    fi
    log "descargando ${out}"
    wget -c -O "${out}.part" "${url}"
    mv "${out}.part" "${out}"
}

extract_once() {
    local tarball="$1" marker="$2"
    if [[ -f "${marker}" ]]; then
        log "ya extraído: ${tarball}"
        return 0
    fi
    log "extrayendo ${tarball}"
    tar -xf "${tarball}" -C "${LFS_BUILD}"
    touch "${marker}"
}

step_download() {
    log "Descargando fuentes del cross-toolchain"
    fetch "${GNU_MIRROR}/binutils/binutils-${BINUTILS_VERSION}.tar.xz" \
          "binutils-${BINUTILS_VERSION}.tar.xz"
    fetch "https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.xz" \
          "gcc-${GCC_VERSION}.tar.xz"
    fetch "${KERNEL_MIRROR}/linux-${LINUX_VERSION}.tar.xz" \
          "linux-${LINUX_VERSION}.tar.xz"
    fetch "${GNU_MIRROR}/gmp/gmp-${GMP_VERSION}.tar.xz" \
          "gmp-${GMP_VERSION}.tar.xz"
    fetch "${GNU_MIRROR}/mpfr/mpfr-${MPFR_VERSION}.tar.xz" \
          "mpfr-${MPFR_VERSION}.tar.xz"
    fetch "${GNU_MIRROR}/mpc/mpc-${MPC_VERSION}.tar.gz" \
          "mpc-${MPC_VERSION}.tar.gz"
}

# ------------------------------------------------------------------------------
# 1) Binutils pass 1
# ------------------------------------------------------------------------------
step_binutils() {
    log "Binutils ${BINUTILS_VERSION} (pass 1) para ${LFS_TGT}"
    extract_once "${LFS_SOURCES}/binutils-${BINUTILS_VERSION}.tar.xz" \
                 "${LFS_BUILD}/.extracted-binutils"

    local src="${LFS_BUILD}/binutils-${BINUTILS_VERSION}"
    local bdir="${src}/build-pass1"
    mkdir -p "${bdir}"
    cd "${bdir}"

    ../configure \
        --prefix="${LFS_TOOLS}" \
        --with-sysroot="${LFS}" \
        --target="${LFS_TGT}" \
        --disable-nls \
        --enable-gprofng=no \
        --disable-werror \
        --enable-default-hash-style=gnu

    make ${MAKEFLAGS}
    make install
    log "Binutils pass 1 instalado en ${LFS_TOOLS}"
}

# ------------------------------------------------------------------------------
# 2) Cabeceras de la API de Linux
# ------------------------------------------------------------------------------
step_headers() {
    log "Cabeceras API de Linux ${LINUX_VERSION}"
    verify_linux_tarball || die "sha256 del kernel no coincide, aborto."
    extract_once "${LFS_SOURCES}/linux-${LINUX_VERSION}.tar.xz" \
                 "${LFS_BUILD}/.extracted-linux"

    local src="${LFS_BUILD}/linux-${LINUX_VERSION}"
    cd "${src}"

    make mrproper
    make headers
    find usr/include -type f ! -name '*.h' -delete
    mkdir -p "${LFS}/usr/include"
    cp -rv usr/include/. "${LFS}/usr/include/"
    log "Cabeceras instaladas en ${LFS}/usr/include"
}

# ------------------------------------------------------------------------------
# 3) GCC pass 1 (sólo C, sin libc — "--without-headers")
# ------------------------------------------------------------------------------
step_gcc() {
    log "GCC ${GCC_VERSION} (pass 1) para ${LFS_TGT}"
    extract_once "${LFS_SOURCES}/gcc-${GCC_VERSION}.tar.xz" \
                 "${LFS_BUILD}/.extracted-gcc"
    extract_once "${LFS_SOURCES}/gmp-${GMP_VERSION}.tar.xz" \
                 "${LFS_BUILD}/.extracted-gmp"
    extract_once "${LFS_SOURCES}/mpfr-${MPFR_VERSION}.tar.xz" \
                 "${LFS_BUILD}/.extracted-mpfr"
    extract_once "${LFS_SOURCES}/mpc-${MPC_VERSION}.tar.gz" \
                 "${LFS_BUILD}/.extracted-mpc"

    local src="${LFS_BUILD}/gcc-${GCC_VERSION}"

    # GCC compila gmp/mpfr/mpc como parte de su propio árbol de fuentes
    [[ -d "${src}/gmp"  ]] || ln -sfv "../gmp-${GMP_VERSION}"   "${src}/gmp"
    [[ -d "${src}/mpfr" ]] || ln -sfv "../mpfr-${MPFR_VERSION}" "${src}/mpfr"
    [[ -d "${src}/mpc"  ]] || ln -sfv "../mpc-${MPC_VERSION}"   "${src}/mpc"

    local bdir="${src}/build-pass1"
    mkdir -p "${bdir}"
    cd "${bdir}"

    ../configure \
        --target="${LFS_TGT}" \
        --prefix="${LFS_TOOLS}" \
        --with-sysroot="${LFS}" \
        --with-newlib \
        --without-headers \
        --enable-default-pie \
        --enable-default-ssp \
        --disable-nls \
        --disable-shared \
        --disable-multilib \
        --disable-threads \
        --disable-libatomic \
        --disable-libgomp \
        --disable-libquadmath \
        --disable-libssp \
        --disable-libvtv \
        --disable-libstdcxx \
        --enable-languages=c,c++

    make ${MAKEFLAGS}
    make install
    log "GCC pass 1 instalado en ${LFS_TOOLS}"
}

step_verify() {
    log "Verificación rápida del cross-toolchain"
    echo 'int main(void) { return 0; }' > /tmp/linsi-check.c

    # GCC pass 1 se compiló con --without-headers: es un compilador "sólo C"
    # sin libc todavía (eso llega en Fase 2 con glibc). Por eso acá NO se
    # intenta enlazar un ejecutable completo (necesitaría Scrt1.o/crti.o/
    # crtn.o/-lc, que todavía no existen) — sólo se confirma que compila a
    # un objeto ELF válido para el target x86_64-linsi-linux-gnu.
    "${LFS_TOOLS}/bin/${LFS_TGT}-gcc" -c -o /tmp/linsi-check.o /tmp/linsi-check.c
    "${LFS_TOOLS}/bin/${LFS_TGT}-readelf" -h /tmp/linsi-check.o | grep -E "Machine|Type"
    rm -f /tmp/linsi-check.o /tmp/linsi-check.c
    log "OK: ${LFS_TGT}-gcc compila código objeto ELF válido para el target."
    log "(el link completo contra libc se prueba en Fase 2, una vez instalada glibc)"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        download) step_download ;;
        binutils) step_download; step_binutils ;;
        headers)  step_download; step_headers ;;
        gcc)      step_download; step_gcc ;;
        verify)   step_verify ;;
        all)
            step_download
            step_binutils
            step_headers
            step_gcc
            step_verify
            log "Fase 0 completa: cross-toolchain ${LFS_TGT} listo en ${LFS_TOOLS}"
            ;;
        *)
            die "target desconocido: ${target} (usar: download|binutils|headers|gcc|verify|all)"
            ;;
    esac
}

main "$@"
