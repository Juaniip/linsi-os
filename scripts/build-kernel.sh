#!/usr/bin/env bash
# ==============================================================================
# LINSI-OS · Fase 1 — "El Núcleo"
# ------------------------------------------------------------------------------
# Compila el kernel puro con el cross-toolchain forjado en Fase 0 y le aplica
# el endurecimiento de scripts/kernel-hardening.config: Kernel Lockdown,
# KASLR, mitigación de DMA por puertos externos, BTRFS integrado y soporte
# EFI (para systemd-boot + Secure Boot en Fase 8).
#
# Requiere haber corrido antes: scripts/build-cross-toolchain.sh all
#
# Uso:
#   scripts/build-kernel.sh              # todos los pasos
#   scripts/build-kernel.sh configure     # extraer + defconfig + merge + olddefconfig
#   scripts/build-kernel.sh build         # compilar bzImage + módulos
#   scripts/build-kernel.sh modules       # instalar módulos en el sysroot
#   scripts/build-kernel.sh verify        # chequear que el hardening quedó activo
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/lfs/scripts/env.sh
source "${SCRIPT_DIR}/env.sh"

log()  { printf '\n\033[1;36m[fase1]\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m[fase1][error]\033[0m %s\n' "$*" >&2; exit 1; }

KERNEL_SRC="${LFS_BUILD}/linux-${LINUX_VERSION}"

require_toolchain() {
    if ! command -v "${LFS_TGT}-gcc" >/dev/null 2>&1; then
        die "no se encontró ${LFS_TGT}-gcc en el PATH. Corré primero: scripts/build-cross-toolchain.sh all"
    fi
}

step_extract() {
    if [[ -d "${KERNEL_SRC}" ]]; then
        log "fuente del kernel ya extraída en ${KERNEL_SRC}"
        return 0
    fi
    log "extrayendo linux-${LINUX_VERSION} (usa el tarball en ${LFS_SOURCES} si ya está — por ejemplo, el que dejaste en sources/)"
    if [[ ! -f "${LFS_SOURCES}/linux-${LINUX_VERSION}.tar.xz" ]]; then
        wget -c -O "${LFS_SOURCES}/linux-${LINUX_VERSION}.tar.xz.part" \
            "${KERNEL_MIRROR}/linux-${LINUX_VERSION}.tar.xz"
        mv "${LFS_SOURCES}/linux-${LINUX_VERSION}.tar.xz.part" "${LFS_SOURCES}/linux-${LINUX_VERSION}.tar.xz"
    fi
    verify_linux_tarball || die "sha256 del kernel no coincide, aborto (¿tarball incompleto o versión equivocada?)."
    tar -xf "${LFS_SOURCES}/linux-${LINUX_VERSION}.tar.xz" -C "${LFS_BUILD}"
}

step_configure() {
    require_toolchain
    step_extract
    cd "${KERNEL_SRC}"

    log "generando defconfig base para x86_64"
    make ARCH=x86_64 CROSS_COMPILE="${LFS_TGT}-" defconfig

    log "aplicando fragmento de hardening (scripts/kernel-hardening.config)"
    ./scripts/kconfig/merge_config.sh -m .config "${SCRIPT_DIR}/kernel-hardening.config"

    log "resolviendo dependencias de config (olddefconfig)"
    make ARCH=x86_64 CROSS_COMPILE="${LFS_TGT}-" olddefconfig
}

step_build() {
    require_toolchain
    [[ -f "${KERNEL_SRC}/.config" ]] || step_configure
    cd "${KERNEL_SRC}"

    log "compilando bzImage + módulos (${MAKEFLAGS})"
    # shellcheck disable=SC2086
    make ARCH=x86_64 CROSS_COMPILE="${LFS_TGT}-" ${MAKEFLAGS} all

    mkdir -p "${LFS}/boot"
    cp -v arch/x86/boot/bzImage "${LFS}/boot/vmlinuz-linsi-${LINUX_VERSION}"
    cp -v .config "${LFS}/boot/config-linsi-${LINUX_VERSION}"
    log "kernel instalado en ${LFS}/boot/vmlinuz-linsi-${LINUX_VERSION}"
}

step_modules() {
    cd "${KERNEL_SRC}"
    log "instalando módulos en ${LFS}/lib/modules"
    # shellcheck disable=SC2086
    make ARCH=x86_64 CROSS_COMPILE="${LFS_TGT}-" INSTALL_MOD_PATH="${LFS}" ${MAKEFLAGS} modules_install
}

step_verify() {
    local cfg="${KERNEL_SRC}/.config"
    [[ -f "${cfg}" ]] || die "no existe ${cfg} — corré 'configure' primero"

    log "verificando opciones de hardening en .config"
    local checks=(
        "CONFIG_SECURITY_LOCKDOWN_LSM=y"
        "CONFIG_LOCK_DOWN_KERNEL_FORCE_INTEGRITY=y"
        "CONFIG_MODULE_SIG=y"
        "CONFIG_MODULE_SIG_FORCE=y"
        "CONFIG_RANDOMIZE_BASE=y"
        "CONFIG_RANDOMIZE_MEMORY=y"
        "CONFIG_INTEL_IOMMU=y"
        "CONFIG_INTEL_IOMMU_DEFAULT_ON=y"
        "CONFIG_BTRFS_FS=y"
        "CONFIG_EFI_STUB=y"
        "CONFIG_SECURITY_SELINUX=y"
        "CONFIG_AUDIT=y"
        "CONFIG_AUDITSYSCALL=y"
        "CONFIG_NF_TABLES=y"
        "CONFIG_DM_CRYPT=y"
        "CONFIG_CRYPTO_AES_NI_INTEL=y"
    )
    local not_set_checks=(
        "CONFIG_THUNDERBOLT"
        "CONFIG_FIREWIRE"
    )

    local ok=1
    for c in "${checks[@]}"; do
        if grep -qxF "${c}" "${cfg}"; then
            echo "  [OK] ${c}"
        else
            echo "  [FALTA] ${c}"
            ok=0
        fi
    done
    for c in "${not_set_checks[@]}"; do
        if grep -qxF "# ${c} is not set" "${cfg}" || ! grep -q "^${c}=" "${cfg}"; then
            echo "  [OK] ${c} deshabilitado"
        else
            echo "  [ATENCION] ${c} sigue activo"
            ok=0
        fi
    done

    if [[ "${ok}" -eq 1 ]]; then
        log "Hardening de Fase 1 verificado correctamente."
    else
        die "faltan opciones de hardening — revisá kernel-hardening.config y volvé a correr 'configure'."
    fi
}

main() {
    local target="${1:-all}"
    case "${target}" in
        extract)   step_extract ;;
        configure) step_configure ;;
        build)     step_build ;;
        modules)   step_modules ;;
        verify)    step_verify ;;
        all)
            step_configure
            step_build
            step_modules
            step_verify
            log "Fase 1 completa: kernel endurecido en ${LFS}/boot, módulos en ${LFS}/lib/modules"
            ;;
        *)
            die "target desconocido: ${target} (usar: extract|configure|build|modules|verify|all)"
            ;;
    esac
}

main "$@"
