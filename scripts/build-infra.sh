#!/usr/bin/env bash
# ==============================================================================
# LINSI-OS · Fase 5 — "Infraestructura Autónoma" (parte 1: gestor de paquetes)
# ------------------------------------------------------------------------------
# Igual que Fases 2/3/4: no se chrootea, todo se instala con --prefix=/usr +
# DESTDIR="${LFS_SYSROOT}". Requiere que Fase 4 esté completa (apk-tools usa
# OpenSSL para verificar firmas RSA, y zlib para descomprimir los .apk):
#   scripts/build-comms.sh all
#
# IMPORTANTE — alcance real de este script: la guía describe Fase 5 con TRES
# piezas, y sólo la primera cabe en el patrón "poblar el sysroot" que vienen
# siguiendo Fases 0-4:
#   (a) apk-tools como gestor de paquetes            -> ESTO, acá abajo
#   (b) un servidor de repos en una Raspberry Pi 5,
#       detrás de un túnel Zero Trust de Cloudflare   -> hardware físico +
#       cuenta de Cloudflare del usuario, fuera del alcance de este
#       contenedor de build
#   (c) CI/CD que compila y despliega los paquetes
#       automáticamente                               -> plataforma de CI a
#       elección del usuario (GitHub Actions, la propia Pi, etc.), también
#       fuera de este contenedor
# (b) y (c) no son código que se pueda "correr acá adentro" -- son decisiones
# de infraestructura real (¿la Pi ya está andando? ¿qué CI usar?) que le
# quedan preguntadas al usuario aparte de este script.
#
# Orden (cada paso depende del anterior — no saltear):
#   1. apk-tools      -> el binario `apk` en sí (Meson, NO Makefile: la serie
#                        3.x lo migró, el Makefile legacy se elimina en 3.0)
#   2. apk-signing     -> NO es un paquete: genera el par de llaves RSA-4096
#                        que va a firmar el índice de paquetes, instala la
#                        PÚBLICA en ${LFS_SYSROOT}/etc/apk/keys/ (para que el
#                        sistema instalado sólo confíe en paquetes firmados
#                        con esa llave) y dice bien fuerte dónde queda la
#                        PRIVADA (nunca dentro del sysroot -- si viajara
#                        adentro de la ISO final, cualquiera que la arranque
#                        podría firmar paquetes maliciosos "de confianza").
#
# Uso:
#   scripts/build-infra.sh apk-tools
#   scripts/build-infra.sh all        # corre todos los pasos implementados
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/lfs/scripts/env.sh
source "${SCRIPT_DIR}/env.sh"

log()  { printf '\n\033[1;32m[fase5]\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m[fase5][error]\033[0m %s\n' "$*" >&2; exit 1; }

require_toolchain() {
    if ! command -v "${LFS_TGT}-gcc" >/dev/null 2>&1; then
        die "no se encontró ${LFS_TGT}-gcc en el PATH. Corré primero: scripts/build-cross-toolchain.sh all"
    fi
}

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

# Cross file de Meson — mismo formato que systemd (Fase 2) y Linux-PAM (Fase 4).
write_meson_crossfile() {
    local crossfile="$1"
    cat > "${crossfile}" <<EOF
[binaries]
c = '${LFS_TOOLS}/bin/${LFS_TGT}-gcc'
ar = '${LFS_TOOLS}/bin/${LFS_TGT}-ar'
strip = '${LFS_TOOLS}/bin/${LFS_TGT}-strip'
ranlib = '${LFS_TOOLS}/bin/${LFS_TGT}-ranlib'
pkg-config = 'pkg-config'

[host_machine]
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'

[properties]
sys_root = '${LFS_SYSROOT}'
pkg_config_libdir = '${LFS_SYSROOT}/usr/lib/pkgconfig'
EOF
}

# ------------------------------------------------------------------------------
# 1) apk-tools — el gestor de paquetes real. Meson (no autotools/CMake, y NO el
# Makefile legacy: apk-tools 3.0 lo discontinuó). "libfetch" (el cliente
# HTTP/HTTPS que usa `apk` para bajar paquetes de un repo remoto -- la Pi de la
# parte (b) de esta fase) va VENDORIZADO adentro del propio repo
# (subdir('libfetch'), no un paquete aparte) cuando url_backend=libfetch (el
# default) -- confirmado leyendo su meson.build real, no es una dependencia
# que haga falta compilar por separado. crypto_backend=openssl reusa el
# OpenSSL que ya instaló Fase 4. lua/help/docs/zstd/tests/python se apagan
# explícito (todos por defecto "auto": sin esto, si Meson encontrara algo
# parecido a Lua/scdoc dando vueltas se colaría solo, en vez de fallar con un
# error claro si realmente hiciera falta).
# ------------------------------------------------------------------------------
step_apk_tools() {
    require_toolchain
    log "apk-tools ${APK_TOOLS_VERSION} para ${LFS_TGT} — Meson+Ninja"

    cd "${LFS_SOURCES}"
    fetch "${APK_TOOLS_MIRROR}/v${APK_TOOLS_VERSION}.tar.gz" \
          "apk-tools-${APK_TOOLS_VERSION}.tar.gz"
    log_sha256 "${LFS_SOURCES}/apk-tools-${APK_TOOLS_VERSION}.tar.gz"
    extract_once "${LFS_SOURCES}/apk-tools-${APK_TOOLS_VERSION}.tar.gz" \
                 "${LFS_BUILD}/.extracted-apk-tools"

    local src="${LFS_BUILD}/apk-tools-${APK_TOOLS_VERSION}"
    cd "${src}"

    local crossfile="${LFS_BUILD}/meson-cross-linsi.ini"
    write_meson_crossfile "${crossfile}"

    local bdir="${src}/build"
    rm -rf "${bdir}"   # meson no tolera reconfigurar con flags distintos sobre un build-dir viejo

    meson setup "${bdir}" \
        --cross-file="${crossfile}" \
        --prefix=/usr \
        --libdir=lib \
        --sysconfdir=/etc \
        -Dcrypto_backend=openssl \
        -Durl_backend=libfetch \
        -Dlua=disabled \
        -Dhelp=disabled \
        -Ddocs=disabled \
        -Dzstd=disabled \
        -Dtests=disabled \
        -Dpython=disabled

    ninja -C "${bdir}" ${MAKEFLAGS}
    DESTDIR="${LFS_SYSROOT}" ninja -C "${bdir}" install

    log "apk-tools instalado en ${LFS_SYSROOT}/usr"
}

step_verify_apk_tools() {
    log "Verificación: apk presente en el sysroot, linkeado contra libssl/libcrypto/libz"
    local bin="${LFS_SYSROOT}/usr/sbin/apk"
    [[ -e "${bin}" ]] || bin="${LFS_SYSROOT}/usr/bin/apk"   # sysconfdir/libdir según versión podría cambiar dónde cae el binario
    [[ -e "${bin}" ]] || die "no se encontró el binario apk en ${LFS_SYSROOT}/usr/{s,}bin/apk"
    echo "  [OK] ${bin}"
    file "${bin}"
    "${LFS_TOOLS}/bin/${LFS_TGT}-readelf" -d "${bin}" | grep -i "needed"
    log "OK: apk-tools completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 2) apk-signing — genera el par de llaves RSA-4096 que va a firmar el índice
# de paquetes (mismo tamaño y mecanismo que usa abuild-keygen de Alpine:
# openssl genrsa + openssl rsa -pubout). Convención real de Alpine para el
# nombre del archivo público: "<identidad>-<timestamp-hex>.rsa.pub" -- se usa
# "linsi-os" como identidad ya que no hay un mail/usuario real todavía.
#
# LA LLAVE PRIVADA NUNCA VA AL SYSROOT. Si terminara empaquetada dentro de la
# ISO final, cualquiera que arrancara LINSI-OS podría extraerla y firmar
# paquetes maliciosos que el propio sistema aceptaría como "de confianza" --
# el sentido entero de firmar el repo se pierde. Por eso esta función la deja
# en ${LFS_BUILD} (un volumen persistente de Podman, pero NUNCA un bind mount
# host-visible ni parte del sysroot que se empaqueta en Fase 8) y lo dice bien
# fuerte en el log. El destino final real de esa llave privada es donde sea
# que corra la firma de verdad (la Raspberry Pi o el runner de CI/CD de la
# parte (c) de esta fase) -- fuera del alcance de este contenedor de build.
# ------------------------------------------------------------------------------
step_apk_signing() {
    log "Generando el par de llaves RSA-4096 para firmar el repo de paquetes"

    local keydir="${LFS_BUILD}/apk-signing-keys"
    mkdir -p "${keydir}"

    # Convención real de Alpine (abuild-keygen): privada y pública comparten
    # el mismo nombre base "<identidad>-<timestamp-hex>" -- se busca primero
    # si ya existe un par (re-corrida) antes de generar uno nuevo, así este
    # paso queda idempotente sin duplicar llaves cada vez que se corre "all".
    local privkey pubkey
    privkey="$(find "${keydir}" -maxdepth 1 -name 'linsi-os-*.rsa' 2>/dev/null | head -n1)"

    if [[ -n "${privkey}" ]]; then
        pubkey="${privkey}.pub"
        log "ya existe un par de llaves en ${keydir} -- no se regenera (borrá ${keydir} a mano si querés una llave nueva)"
    else
        local ts
        ts="$(printf '%x' "$(date +%s)")"
        privkey="${keydir}/linsi-os-${ts}.rsa"
        pubkey="${privkey}.pub"
        openssl genrsa -out "${privkey}" 4096
        openssl rsa -in "${privkey}" -pubout -out "${pubkey}"
        chmod 600 "${privkey}"
    fi

    local keys_in_sysroot="${LFS_SYSROOT}/etc/apk/keys"
    mkdir -p "${keys_in_sysroot}"
    cp -f "${keydir}"/linsi-os-*.rsa.pub "${keys_in_sysroot}/"

    local repos_dir="${LFS_SYSROOT}/etc/apk"
    cat > "${repos_dir}/repositories" <<'EOF'
# LINSI-OS · Fase 5
# TODO: reemplazar por la URL real una vez que la Raspberry Pi 5 + túnel Zero
# Trust de Cloudflare (parte (b) de esta fase) estén levantados -- por ahora
# esto queda sin un repo real configurado a propósito, apk no va a encontrar
# nada hasta que se complete esa parte.
# https://<tu-hostname>.trycloudflare.com/linsi-os/edge/main
EOF

    log "  -> privada:  ${privkey}  (NO va al sysroot -- copiala a donde vaya a firmar de verdad, después BORRALA de acá)"
    log "  -> pública:  ${keys_in_sysroot}/$(basename "${pubkey}")"
    log "  -> ${repos_dir}/repositories (placeholder, falta la URL real de la Pi)"
}

step_verify_apk_signing() {
    log "Verificación: llave pública instalada en el sysroot, privada NO instalada"
    local pubcount
    pubcount="$(find "${LFS_SYSROOT}/etc/apk/keys" -maxdepth 1 -name '*.rsa.pub' 2>/dev/null | wc -l)"
    [[ "${pubcount}" -ge 1 ]] || die "no hay ninguna .rsa.pub en ${LFS_SYSROOT}/etc/apk/keys"
    echo "  [OK] ${pubcount} llave(s) pública(s) en ${LFS_SYSROOT}/etc/apk/keys"
    if find "${LFS_SYSROOT}" -name '*.rsa' -not -name '*.pub' 2>/dev/null | grep -q .; then
        die "SE COLÓ UNA LLAVE PRIVADA DENTRO DEL SYSROOT -- revisar step_apk_signing antes de seguir"
    fi
    echo "  [OK] ninguna llave privada dentro del sysroot"
    [[ -f "${LFS_SYSROOT}/etc/apk/repositories" ]] || die "falta ${LFS_SYSROOT}/etc/apk/repositories"
    echo "  [OK] ${LFS_SYSROOT}/etc/apk/repositories"
    log "OK: firma de paquetes configurada en el sysroot."
}

main() {
    local target="${1:-all}"
    case "${target}" in
        apk-tools)             step_apk_tools ;;
        verify-apk-tools)      step_verify_apk_tools ;;
        apk-signing)           step_apk_signing ;;
        verify-apk-signing)    step_verify_apk_signing ;;
        all)
            step_apk_tools
            step_verify_apk_tools
            step_apk_signing
            step_verify_apk_signing
            log "Fase 5 ('Infraestructura Autónoma'), parte 1 completa: apk-tools + firma de paquetes listos en el sysroot. Faltan las partes (b) Raspberry Pi/Cloudflare Tunnel y (c) CI/CD -- eso es infraestructura real fuera de este contenedor, ver el comentario del encabezado de este script."
            ;;
        *)
            die "target desconocido: ${target} (usar: apk-tools|verify-apk-tools|apk-signing|verify-apk-signing|all)"
            ;;
    esac
}

main "$@"
