#!/usr/bin/env bash
# ==============================================================================
# LINSI-OS · Fase 4 — "Comunicaciones"
# ------------------------------------------------------------------------------
# Igual que Fases 2/3: no se chrootea, todo se instala con --prefix=/usr +
# DESTDIR="${LFS_SYSROOT}". Requiere que Fase 3 ("El Escudo") ya esté completa
# (varios pasos de acá dependen de que SELinux/cryptsetup ya existan en el
# sysroot para poder recompilar systemd con esas features encendidas):
#   scripts/build-security.sh all
#
# Orden (cada paso depende del anterior — no saltear):
#   1. zlib        -> compresión genérica. La usa systemd (journald) y de acá
#                     en más cualquier paquete de fases futuras que la pida.
#   2. openssl     -> backend de cripto (libcrypto/libssl) para DNS-over-TLS
#                     de systemd-resolved y para libfido2/pam_u2f.
#   3. libcbor     -> serialización CBOR, la usa libfido2 para hablar CTAP2
#                     con los tokens FIDO2 por HID.
#   4. libfido2    -> librería cliente FIDO2/U2F (Yubico), sobre libcbor+openssl.
#   5. linux-pam   -> Linux-PAM propiamente dicho (Meson, no autotools desde
#                     ~1.6) — trae pam_unix/pam_faillock/pam_permit/pam_deny/
#                     pam_limits ya incluidos, sin paquete aparte.
#   6. pam_u2f     -> módulo PAM de Yubico que exige el token FIDO2/U2F físico
#                     en el login, sobre libfido2+Linux-PAM.
#   7. pam-config  -> NO es un paquete: deja /etc/pam.d/common-auth y
#                     /etc/security/faillock.conf en el sysroot, cableando
#                     pam_faillock (bloqueo tras intentos fallidos) + pam_u2f
#                     (token físico) en la cadena real de autenticación.
#   8. systemd-rebuild -> RECOMPILA el systemd de Fase 2 (que había quedado con
#                     pam/selinux/libcryptsetup/dns-over-tls/libfido2 en 'auto'
#                     -> deshabilitados en silencio, porque en Fase 2 ninguna
#                     de esas librerías existía todavía) ahora que sí existen.
#   9. network-config -> NO es un paquete: deja el .link de aleatorización de
#                     MAC (systemd-networkd) y resolved.conf con DNS-over-TLS
#                     forzado (DNSOverTLS=yes, no "opportunistic") en el sysroot.
#
# "Alta entropía" (mencionada en la guía) queda cubierta acá sólo por
# obscure+minlen=12 de pam_unix — un chequeo real de calidad de contraseña
# (zxcvbn/pam_pwquality) es un paquete nuevo, fuera del alcance decidido para
# esta fase; si se quiere subir el nivel más adelante, es un paso más para
# agregar, no un cambio de lo ya construido acá.
#
# Uso:
#   scripts/build-comms.sh zlib
#   scripts/build-comms.sh all        # corre todos los pasos implementados
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/lfs/scripts/env.sh
source "${SCRIPT_DIR}/env.sh"

log()  { printf '\n\033[1;36m[fase4]\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m[fase4][error]\033[0m %s\n' "$*" >&2; exit 1; }

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

build_triplet() {
    "${LFS_BUILD}/binutils-${BINUTILS_VERSION}/config.guess"
}

# Toolchain file de CMake, compartido por libcbor y libfido2 — mismo patrón
# que step_json_c() en build-security.sh.
write_cmake_toolchain() {
    local toolchain_file="$1"
    cat > "${toolchain_file}" <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER ${LFS_TGT}-gcc)
set(CMAKE_FIND_ROOT_PATH ${LFS_SYSROOT})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF
}

# Cross file de Meson, compartido por linux-pam y systemd-rebuild — mismo
# formato que step_systemd() en build-userspace.sh (Fase 2).
write_meson_crossfile() {
    local crossfile="$1"
    cat > "${crossfile}" <<EOF
[binaries]
c = '${LFS_TOOLS}/bin/${LFS_TGT}-gcc'
cpp = '${LFS_TOOLS}/bin/${LFS_TGT}-g++'
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
# 1) zlib — compresión genérica. ./configure propio (no autotools): la única
# forma de cross-compilar es la variable CHOST (no existe --host=), que
# deriva CROSS_PREFIX="${CHOST}-" para armar "${CHOST}-gcc"/ar/ranlib. No
# soporta out-of-tree build de forma confiable -> se compila directo en el
# directorio extraído, mismo patrón que documenta BLFS.
# ------------------------------------------------------------------------------
step_zlib() {
    require_toolchain
    log "zlib ${ZLIB_VERSION} para ${LFS_TGT}"

    cd "${LFS_SOURCES}"
    fetch "${ZLIB_MIRROR}/zlib-${ZLIB_VERSION}.tar.gz" \
          "zlib-${ZLIB_VERSION}.tar.gz"
    log_sha256 "${LFS_SOURCES}/zlib-${ZLIB_VERSION}.tar.gz"
    extract_once "${LFS_SOURCES}/zlib-${ZLIB_VERSION}.tar.gz" \
                 "${LFS_BUILD}/.extracted-zlib"

    local src="${LFS_BUILD}/zlib-${ZLIB_VERSION}"
    cd "${src}"

    CHOST="${LFS_TGT}" ./configure --prefix=/usr

    make ${MAKEFLAGS}
    make DESTDIR="${LFS_SYSROOT}" install
    find "${LFS_SYSROOT}/usr/lib" -maxdepth 1 -name 'libz.la' -delete 2>/dev/null || true

    log "zlib instalado en ${LFS_SYSROOT}/usr"
}

step_verify_zlib() {
    log "Verificación: libz.so + zlib.h en el sysroot"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/usr/lib/libz.so" "${LFS_SYSROOT}/usr/include/zlib.h"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    [[ "${ok}" -eq 1 ]] || die "falta algo de zlib en el sysroot"
    log "OK: zlib completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 2) OpenSSL — backend de cripto para DNS-over-TLS (systemd-resolved) y para
# libfido2/pam_u2f. Build system propio (./Configure, con C mayúscula), no
# autotools/CMake. "linux-x86_64" es la entrada de arquitectura (independiente
# del nombre del triplet); --cross-compile-prefix es lo que realmente cruza.
# BUG CONOCIDO (folklore ampliamente reportado, no documentado por upstream en
# esta versión): "make install" en paralelo puede corromper los .so por una
# carrera entre sub-makes escribiendo symlinks al mismo tiempo -> el paso de
# instalación va siempre en serie (-j1), aunque la compilación sí sea paralela.
# ------------------------------------------------------------------------------
step_openssl() {
    require_toolchain
    log "OpenSSL ${OPENSSL_VERSION} para ${LFS_TGT}"

    cd "${LFS_SOURCES}"
    fetch "${OPENSSL_MIRROR}/openssl-${OPENSSL_VERSION}.tar.gz" \
          "openssl-${OPENSSL_VERSION}.tar.gz"
    log_sha256 "${LFS_SOURCES}/openssl-${OPENSSL_VERSION}.tar.gz"
    extract_once "${LFS_SOURCES}/openssl-${OPENSSL_VERSION}.tar.gz" \
                 "${LFS_BUILD}/.extracted-openssl"

    local src="${LFS_BUILD}/openssl-${OPENSSL_VERSION}"
    cd "${src}"

    # Limpieza de un intento anterior (2026-08-27, error real de build): el
    # target "linux-x86_64" de OpenSSL usa lib64 por default (convención
    # estilo Fedora/RHEL, no algo específico de este triplet) salvo que se
    # fuerce --libdir=lib -- sin eso, todo (libssl.so, libcrypto.so,
    # openssl.pc, etc.) queda en ${LFS_SYSROOT}/usr/lib64 en vez de
    # .../usr/lib, y los pasos siguientes (libfido2, pam_u2f) no encuentran
    # openssl.pc vía PKG_CONFIG_LIBDIR=.../usr/lib/pkgconfig. Se borra
    # cualquier resto de ese intento antes de reinstalar bien, para que este
    # paso quede idempotente incluso si ya corrió mal una vez.
    rm -rf "${LFS_SYSROOT}/usr/lib64"

    ./Configure linux-x86_64 \
        --cross-compile-prefix="${LFS_TGT}-" \
        --prefix=/usr \
        --libdir=lib \
        --openssldir=/etc/ssl \
        shared

    make ${MAKEFLAGS}
    make -j1 DESTDIR="${LFS_SYSROOT}" install_sw

    log "OpenSSL instalado en ${LFS_SYSROOT}/usr"
}

step_verify_openssl() {
    log "Verificación: libssl.so/libcrypto.so + openssl/ssl.h en el sysroot"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/usr/lib/libssl.so" "${LFS_SYSROOT}/usr/lib/libcrypto.so" "${LFS_SYSROOT}/usr/include/openssl/ssl.h"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    [[ "${ok}" -eq 1 ]] || die "falta algo de OpenSSL en el sysroot"
    log "OK: OpenSSL completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 3) libcbor — serialización CBOR que usa libfido2 para hablar CTAP2 con los
# tokens FIDO2/U2F. CMake puro, sin dist propio (sólo el archive/refs/tags
# crudo de GitHub) pero eso alcanza acá: el CMakeLists.txt ya está en el repo,
# no hace falta autoreconf ni nada por el estilo.
# ------------------------------------------------------------------------------
step_libcbor() {
    require_toolchain
    log "libcbor ${LIBCBOR_VERSION} para ${LFS_TGT}"

    cd "${LFS_SOURCES}"
    fetch "${LIBCBOR_MIRROR}/v${LIBCBOR_VERSION}.tar.gz" \
          "libcbor-${LIBCBOR_VERSION}.tar.gz"
    log_sha256 "${LFS_SOURCES}/libcbor-${LIBCBOR_VERSION}.tar.gz"
    extract_once "${LFS_SOURCES}/libcbor-${LIBCBOR_VERSION}.tar.gz" \
                 "${LFS_BUILD}/.extracted-libcbor"

    local src="${LFS_BUILD}/libcbor-${LIBCBOR_VERSION}"
    local bdir="${src}/build"
    mkdir -p "${bdir}"

    local toolchain_file="${LFS_BUILD}/cmake-toolchain-linsi.txt"
    write_cmake_toolchain "${toolchain_file}"

    cmake -S "${src}" -B "${bdir}" -G "Unix Makefiles" \
        -DCMAKE_TOOLCHAIN_FILE="${toolchain_file}" \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=ON \
        -DWITH_EXAMPLES=OFF \
        -DSANITIZE=OFF \
        -Wno-dev

    cmake --build "${bdir}" -- ${MAKEFLAGS}
    DESTDIR="${LFS_SYSROOT}" cmake --install "${bdir}"

    log "libcbor instalado en ${LFS_SYSROOT}/usr"
}

step_verify_libcbor() {
    log "Verificación: libcbor.so + cbor.h en el sysroot"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/usr/lib/libcbor.so" "${LFS_SYSROOT}/usr/include/cbor.h"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    [[ "${ok}" -eq 1 ]] || die "falta algo de libcbor en el sysroot"
    log "OK: libcbor completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 4) libfido2 — librería cliente FIDO2/U2F de Yubico, sobre libcbor+OpenSSL.
# A diferencia de libcbor, sí usa pkg-config de verdad para encontrar libcbor
# y libcrypto -> hace falta PKG_CONFIG_LIBDIR/PKG_CONFIG_SYSROOT_DIR (mismo
# patrón que libnftnl/nftables en Fase 3), además del toolchain file de CMake.
# USE_PCSC=OFF: PCSC/NFC tirarían de libpcsclite del HOST si estuviera
# instalada (no cross-compilada) -> se deja afuera, sólo queda el transporte
# HID (USB), que es el que importa para un token físico FIDO2 típico.
# ------------------------------------------------------------------------------
step_libfido2() {
    require_toolchain
    log "libfido2 ${LIBFIDO2_VERSION} para ${LFS_TGT}"

    cd "${LFS_SOURCES}"
    fetch "${LIBFIDO2_MIRROR}/libfido2-${LIBFIDO2_VERSION}.tar.gz" \
          "libfido2-${LIBFIDO2_VERSION}.tar.gz"
    log_sha256 "${LFS_SOURCES}/libfido2-${LIBFIDO2_VERSION}.tar.gz"
    extract_once "${LFS_SOURCES}/libfido2-${LIBFIDO2_VERSION}.tar.gz" \
                 "${LFS_BUILD}/.extracted-libfido2"

    local src="${LFS_BUILD}/libfido2-${LIBFIDO2_VERSION}"
    local bdir="${src}/build"
    mkdir -p "${bdir}"

    local toolchain_file="${LFS_BUILD}/cmake-toolchain-linsi.txt"
    write_cmake_toolchain "${toolchain_file}"

    PKG_CONFIG_LIBDIR="${LFS_SYSROOT}/usr/lib/pkgconfig" \
    PKG_CONFIG_SYSROOT_DIR="${LFS_SYSROOT}" \
    cmake -S "${src}" -B "${bdir}" -G "Unix Makefiles" \
        -DCMAKE_TOOLCHAIN_FILE="${toolchain_file}" \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=ON \
        -DBUILD_STATIC_LIBS=OFF \
        -DBUILD_TESTS=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_MANPAGES=OFF \
        -DBUILD_TOOLS=OFF \
        -DUSE_PCSC=OFF \
        -Wno-dev

    cmake --build "${bdir}" -- ${MAKEFLAGS}
    DESTDIR="${LFS_SYSROOT}" cmake --install "${bdir}"

    log "libfido2 instalado en ${LFS_SYSROOT}/usr"
}

step_verify_libfido2() {
    log "Verificación: libfido2.so + fido.h en el sysroot, linkeado contra libcbor/libcrypto"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/usr/lib/libfido2.so" "${LFS_SYSROOT}/usr/include/fido.h"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    [[ "${ok}" -eq 1 ]] || die "falta algo de libfido2 en el sysroot"
    "${LFS_TOOLS}/bin/${LFS_TGT}-readelf" -d "${LFS_SYSROOT}/usr/lib/libfido2.so" | grep -i "needed"
    log "OK: libfido2 completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 5) Linux-PAM — desde ~1.6 usa Meson (no autotools), mismo mecanismo de cross
# file que systemd. --libdir=lib explícito: el auto-detectado por Meson puede
# resolver a "lib/x86_64-linux-gnu" (multiarch, convención de Debian) en vez
# de "lib" a secas, lo que rompe dónde busca módulos /usr/lib/security y dónde
# esperamos encontrarlos en pam-config más abajo. docs=disabled evita tirar de
# docbook/xmlto/w3m (no instalados). logind=disabled: pam_systemd (login vía
# systemd-logind) queda fuera de alcance de esta fase — no lo pide la guía y
# evita sumar otra dependencia pkg-config (libsystemd) a verificar ahora.
# ------------------------------------------------------------------------------
step_linux_pam() {
    require_toolchain
    log "Linux-PAM ${LINUX_PAM_VERSION} para ${LFS_TGT} — Meson+Ninja"

    cd "${LFS_SOURCES}"
    fetch "${LINUX_PAM_MIRROR}/Linux-PAM-${LINUX_PAM_VERSION}.tar.xz" \
          "Linux-PAM-${LINUX_PAM_VERSION}.tar.xz"
    log_sha256 "${LFS_SOURCES}/Linux-PAM-${LINUX_PAM_VERSION}.tar.xz"
    extract_once "${LFS_SOURCES}/Linux-PAM-${LINUX_PAM_VERSION}.tar.xz" \
                 "${LFS_BUILD}/.extracted-linux-pam"

    local src="${LFS_BUILD}/Linux-PAM-${LINUX_PAM_VERSION}"
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
        -Ddocs=disabled \
        -Dexamples=false \
        -Dlogind=disabled

    ninja -C "${bdir}" ${MAKEFLAGS}
    DESTDIR="${LFS_SYSROOT}" ninja -C "${bdir}" install

    log "Linux-PAM instalado en ${LFS_SYSROOT}/usr"
}

step_verify_linux_pam() {
    log "Verificación: libpam.so + pam_unix.so/pam_faillock.so en el sysroot"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/usr/lib/libpam.so" "${LFS_SYSROOT}/usr/lib/security/pam_unix.so" "${LFS_SYSROOT}/usr/lib/security/pam_faillock.so" "${LFS_SYSROOT}/usr/include/security/pam_appl.h"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    [[ "${ok}" -eq 1 ]] || die "falta algo de Linux-PAM en el sysroot"
    log "OK: Linux-PAM completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 6) pam_u2f — módulo PAM de Yubico que exige el token FIDO2/U2F físico,
# sobre libfido2+Linux-PAM. Autotools con tarball de dist real. --with-pam-dir
# apunta al mismo /usr/lib/security que usa Linux-PAM (ver --libdir=lib del
# paso anterior). --disable-man evita necesitar asciidoc/a2x (no instalados).
# ------------------------------------------------------------------------------
step_pam_u2f() {
    require_toolchain
    log "pam_u2f ${PAM_U2F_VERSION} para ${LFS_TGT}"

    cd "${LFS_SOURCES}"
    fetch "${PAM_U2F_MIRROR}/pam_u2f-${PAM_U2F_VERSION}.tar.gz" \
          "pam_u2f-${PAM_U2F_VERSION}.tar.gz"
    log_sha256 "${LFS_SOURCES}/pam_u2f-${PAM_U2F_VERSION}.tar.gz"
    extract_once "${LFS_SOURCES}/pam_u2f-${PAM_U2F_VERSION}.tar.gz" \
                 "${LFS_BUILD}/.extracted-pam_u2f"

    local src="${LFS_BUILD}/pam_u2f-${PAM_U2F_VERSION}"
    local bdir="${src}/build"
    mkdir -p "${bdir}"
    cd "${bdir}"

    PKG_CONFIG_LIBDIR="${LFS_SYSROOT}/usr/lib/pkgconfig" \
    PKG_CONFIG_SYSROOT_DIR="${LFS_SYSROOT}" \
    ../configure \
        --host="${LFS_TGT}" \
        --build="$(build_triplet)" \
        --prefix=/usr \
        --sysconfdir=/etc \
        --with-pam-dir=/usr/lib/security \
        --with-sconf-dir=/etc/security \
        --disable-man

    make ${MAKEFLAGS}
    make DESTDIR="${LFS_SYSROOT}" install
    find "${LFS_SYSROOT}/usr/lib/security" -maxdepth 1 -name 'pam_u2f.la' -delete 2>/dev/null || true

    log "pam_u2f instalado en ${LFS_SYSROOT}/usr/lib/security"
}

step_verify_pam_u2f() {
    log "Verificación: pam_u2f.so en el sysroot, linkeado contra libfido2"
    local p="${LFS_SYSROOT}/usr/lib/security/pam_u2f.so"
    if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else die "falta ${p}"; fi
    "${LFS_TOOLS}/bin/${LFS_TGT}-readelf" -d "${p}" | grep -i "needed"
    log "OK: pam_u2f completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 7) pam-config — NO compila nada: deja la cadena de autenticación real en el
# sysroot. pam_faillock en modo "deny=5 unlock_time=900" (bloquea 15 min tras
# 5 intentos fallidos, contadores en /var/run/faillock vía faillock.conf) +
# pam_u2f (token físico FIDO2/U2F obligatorio) + pam_unix con obscure+minlen=12
# como piso mínimo de entropía (ver nota al principio del archivo sobre por
# qué no hay pam_pwquality acá). El layout de archivo es "common-auth" al
# estilo Debian (un solo archivo incluido por login/sshd/sudo/etc., no un
# system-auth monolítico al estilo Fedora) porque el resto del toolchain base
# de LINSI-OS viene de un host Debian.
# ------------------------------------------------------------------------------
step_pam_config() {
    log "Configuración estática de PAM: pam_faillock + pam_u2f en la cadena de autenticación"

    local pamd_dir="${LFS_SYSROOT}/etc/pam.d"
    mkdir -p "${pamd_dir}"
    cat > "${pamd_dir}/common-auth" <<'EOF'
# LINSI-OS · Fase 4 — cadena de autenticación real:
#   1. pam_faillock (preauth): si la cuenta ya está bloqueada, corta acá.
#   2. pam_u2f: exige el token físico FIDO2/U2F.
#   3. pam_unix: contraseña (obscure+minlen=12 se define en /etc/pam.d/common-password).
#   4. pam_faillock (authfail/authsucc): cuenta el intento fallido o limpia el contador.
auth    required                        pam_faillock.so preauth silent deny=5 unlock_time=900
auth    required                        pam_u2f.so cue
auth    [success=1 default=bad]         pam_unix.so try_first_pass
auth    [default=die]                   pam_faillock.so authfail deny=5 unlock_time=900
auth    sufficient                      pam_faillock.so authsucc
auth    required                        pam_deny.so
EOF

    cat > "${pamd_dir}/common-account" <<'EOF'
# LINSI-OS · Fase 4
account required    pam_unix.so
account required    pam_faillock.so
EOF

    cat > "${pamd_dir}/common-password" <<'EOF'
# LINSI-OS · Fase 4 — obscure+minlen=12 como piso mínimo de entropía (ver
# comentario al principio de build-comms.sh: un chequeo real de calidad tipo
# pam_pwquality queda fuera de alcance de esta fase).
password requisite  pam_unix.so obscure minlen=12 sha512
password required   pam_permit.so
EOF

    cat > "${pamd_dir}/common-session" <<'EOF'
# LINSI-OS · Fase 4
session required    pam_unix.so
session required    pam_limits.so
EOF

    local security_dir="${LFS_SYSROOT}/etc/security"
    mkdir -p "${security_dir}"
    cat > "${security_dir}/faillock.conf" <<'EOF'
# LINSI-OS · Fase 4 — mismos valores que las líneas deny=/unlock_time= de
# common-auth (quedan acá también porque pam_faillock los toma de este
# archivo si no se pasan como argumento, y varias herramientas de diagnóstico
# como faillock(1) sólo leen de acá).
deny = 5
unlock_time = 900
EOF

    log "  -> ${pamd_dir}/common-{auth,account,password,session}"
    log "  -> ${security_dir}/faillock.conf"
}

step_verify_pam_config() {
    log "Verificación: archivos de configuración de PAM presentes en el sysroot"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/etc/pam.d/common-auth" "${LFS_SYSROOT}/etc/pam.d/common-account" \
             "${LFS_SYSROOT}/etc/pam.d/common-password" "${LFS_SYSROOT}/etc/pam.d/common-session" \
             "${LFS_SYSROOT}/etc/security/faillock.conf"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    [[ "${ok}" -eq 1 ]] || die "falta algo de la configuración de PAM en el sysroot"
    grep -q "pam_faillock.so" "${LFS_SYSROOT}/etc/pam.d/common-auth" || die "common-auth no tiene pam_faillock.so"
    grep -q "pam_u2f.so" "${LFS_SYSROOT}/etc/pam.d/common-auth" || die "common-auth no tiene pam_u2f.so"
    log "OK: cadena de PAM configurada en el sysroot."
}

# ------------------------------------------------------------------------------
# 8) systemd-rebuild — RECOMPILA el mismo systemd ${SYSTEMD_VERSION} que ya
# instaló Fase 2 (build-userspace.sh), esta vez con pam/selinux/libcryptsetup/
# dns-over-tls/libfido2 habilitados a mano: en Fase 2 esas cinco opciones
# quedaron en su default "auto" y, como NINGUNA de esas librerías existía
# todavía en el sysroot en ese momento, Meson las auto-deshabilitó en
# silencio (sin error) — ver el comentario largo arriba de step_systemd() en
# build-userspace.sh, que ya anticipaba este mismo paso.
# dns-over-tls=openssl (no "gnutls", que quedó deprecado y se remapea a
# "auto") fuerza específicamente el backend OpenSSL en vez de dejarlo a
# elección automática. homed se deja en su default "auto" (fuera de alcance
# de la guía para esta fase). Build dir separado ("build-fase4") del que dejó
# Fase 2 ("build") para no pisar nada por si hace falta comparar/depurar.
# ------------------------------------------------------------------------------
step_systemd_rebuild() {
    require_toolchain
    log "systemd ${SYSTEMD_VERSION} — recompilación de Fase 4 (pam/selinux/libcryptsetup/dns-over-tls/libfido2)"

    cd "${LFS_SOURCES}"
    fetch "${SYSTEMD_MIRROR}/v${SYSTEMD_VERSION}.tar.gz" \
          "systemd-${SYSTEMD_VERSION}.tar.gz"
    extract_once "${LFS_SOURCES}/systemd-${SYSTEMD_VERSION}.tar.gz" \
                 "${LFS_BUILD}/.extracted-systemd"

    local src="${LFS_BUILD}/systemd-${SYSTEMD_VERSION}"
    cd "${src}"

    local crossfile="${LFS_BUILD}/meson-cross-linsi.ini"
    write_meson_crossfile "${crossfile}"

    local bdir="${src}/build-fase4"
    rm -rf "${bdir}"   # meson no tolera reconfigurar con flags distintos sobre un build-dir viejo

    meson setup "${bdir}" \
        --cross-file="${crossfile}" \
        --prefix=/usr \
        --sysconfdir=/etc \
        --localstatedir=/var \
        -Dmode=release \
        -Dacl=enabled \
        -Dblkid=enabled \
        -Dlibmount=enabled \
        -Dman=disabled \
        -Dhtml=disabled \
        -Dtests=false \
        -Dpam=enabled \
        -Dselinux=enabled \
        -Dlibcryptsetup=enabled \
        -Ddns-over-tls=openssl \
        -Dlibfido2=enabled

    ninja -C "${bdir}" ${MAKEFLAGS}
    DESTDIR="${LFS_SYSROOT}" ninja -C "${bdir}" install

    log "systemd recompilado con soporte de Fase 4 instalado en ${LFS_SYSROOT}/usr"
}

step_verify_systemd_rebuild() {
    # CORREGIDO tras la build real del 2026-08-27: el binario chico
    # /usr/lib/systemd/systemd casi no linkea nada directo (sólo
    # libsystemd-core-${SYSTEMD_VERSION}.so y libsystemd-shared-${SYSTEMD_VERSION}.so)
    # -- systemd empaqueta casi todo su código, PAM/SELinux/cryptsetup/FIDO2
    # incluidos, DENTRO de esas dos librerías "gordas", no como dependencias
    # directas del ejecutable. Por eso el chequeo real va contra
    # libsystemd-shared, no contra el binario.
    log "Verificación: libsystemd-shared linkeado contra libpam/libselinux/libcryptsetup/libfido2/libssl tras la recompilación"
    local bin="${LFS_SYSROOT}/usr/lib/systemd/systemd"
    local shared="${LFS_SYSROOT}/usr/lib/systemd/libsystemd-shared-${SYSTEMD_VERSION}.so"
    [[ -e "${bin}" ]] || die "no está ${bin}"
    [[ -e "${shared}" ]] || die "no está ${shared}"
    file "${bin}"
    local needed
    needed="$("${LFS_TOOLS}/bin/${LFS_TGT}-readelf" -d "${shared}" | grep -i "needed")"
    echo "${needed}"
    local ok=1
    local lib
    for lib in libpam.so libselinux.so libcryptsetup.so libfido2.so libssl.so; do
        echo "${needed}" | grep -q "${lib}" || { echo "  [FALTA] ${lib} no aparece como NEEDED de libsystemd-shared"; ok=0; }
    done
    [[ "${ok}" -eq 1 ]] || die "systemd se recompiló sin alguna de las features de Fase 4 -- revisá el resumen 'enabled/disabled features' que imprime meson setup, más arriba en este mismo log"
    log "OK: systemd recompilado con PAM/SELinux/libcryptsetup/libfido2/OpenSSL enlazados."
}

# ------------------------------------------------------------------------------
# 9) network-config — NO compila nada: deja en el sysroot el .link de
# aleatorización de MAC de systemd-networkd y el resolved.conf con
# DNS-over-TLS forzado. MACAddressPolicy=random va en la sección [Link] de un
# archivo .link (NO existe "RandomizedMACAddress=" en un .network, se
# confirmó contra el man real). DNSOverTLS=yes (estricto, no "opportunistic")
# exige la sesión cifrada siempre; address#servername es la sintaxis de SNI
# que resuelve necesita para poder validar el certificado TLS del servidor.
# ------------------------------------------------------------------------------
step_network_config() {
    log "Configuración estática: aleatorización de MAC (systemd-networkd) + DNS-over-TLS forzado (systemd-resolved)"

    local link_dir="${LFS_SYSROOT}/usr/lib/systemd/network"
    mkdir -p "${link_dir}"
    cat > "${link_dir}/10-mac-randomize.link" <<'EOF'
[Match]
OriginalName=*

[Link]
MACAddressPolicy=random
EOF

    local resolved_dir="${LFS_SYSROOT}/etc/systemd"
    mkdir -p "${resolved_dir}"
    cat > "${resolved_dir}/resolved.conf" <<'EOF'
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com 9.9.9.9#dns.quad9.net
DNSOverTLS=yes
EOF

    log "  -> ${link_dir}/10-mac-randomize.link"
    log "  -> ${resolved_dir}/resolved.conf"
}

step_verify_network_config() {
    log "Verificación: archivos de configuración de red presentes en el sysroot"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/usr/lib/systemd/network/10-mac-randomize.link" "${LFS_SYSROOT}/etc/systemd/resolved.conf"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    [[ "${ok}" -eq 1 ]] || die "falta algo de la configuración de red en el sysroot"
    grep -q "MACAddressPolicy=random" "${LFS_SYSROOT}/usr/lib/systemd/network/10-mac-randomize.link" || die "10-mac-randomize.link no tiene MACAddressPolicy=random"
    grep -q "DNSOverTLS=yes" "${LFS_SYSROOT}/etc/systemd/resolved.conf" || die "resolved.conf no tiene DNSOverTLS=yes"
    log "OK: MAC randomization + DNS-over-TLS configurados. Fase 4 ('Comunicaciones') completa: MAC aleatoria, DNS-over-TLS forzado y PAM con faillock+FIDO2 listos en el sysroot."
}

main() {
    local target="${1:-all}"
    case "${target}" in
        zlib)                   step_zlib ;;
        verify-zlib)            step_verify_zlib ;;
        openssl)                step_openssl ;;
        verify-openssl)         step_verify_openssl ;;
        libcbor)                step_libcbor ;;
        verify-libcbor)         step_verify_libcbor ;;
        libfido2)                step_libfido2 ;;
        verify-libfido2)         step_verify_libfido2 ;;
        linux-pam)               step_linux_pam ;;
        verify-linux-pam)        step_verify_linux_pam ;;
        pam-u2f)                 step_pam_u2f ;;
        verify-pam-u2f)          step_verify_pam_u2f ;;
        pam-config)              step_pam_config ;;
        verify-pam-config)       step_verify_pam_config ;;
        systemd-rebuild)         step_systemd_rebuild ;;
        verify-systemd-rebuild)  step_verify_systemd_rebuild ;;
        network-config)          step_network_config ;;
        verify-network-config)   step_verify_network_config ;;
        all)
            step_zlib
            step_verify_zlib
            step_openssl
            step_verify_openssl
            step_libcbor
            step_verify_libcbor
            step_libfido2
            step_verify_libfido2
            step_linux_pam
            step_verify_linux_pam
            step_pam_u2f
            step_verify_pam_u2f
            step_pam_config
            step_verify_pam_config
            step_systemd_rebuild
            step_verify_systemd_rebuild
            step_network_config
            step_verify_network_config
            log "Fase 4 ('Comunicaciones') completa: MAC aleatoria, DNS-over-TLS forzado y PAM con pam_faillock+FIDO2 listos en el sysroot."
            ;;
        *)
            die "target desconocido: ${target} (usar: zlib|verify-zlib|openssl|verify-openssl|libcbor|verify-libcbor|libfido2|verify-libfido2|linux-pam|verify-linux-pam|pam-u2f|verify-pam-u2f|pam-config|verify-pam-config|systemd-rebuild|verify-systemd-rebuild|network-config|verify-network-config|all)"
            ;;
    esac
}

main "$@"
