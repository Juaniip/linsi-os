#!/usr/bin/env bash
# ==============================================================================
# LINSI-OS · Fase 3 — "El Escudo"
# ------------------------------------------------------------------------------
# Igual que Fase 2: no se chrootea, todo se instala con --prefix=/usr +
# DESTDIR="${LFS_SYSROOT}". Requiere que el kernel de Fase 1 ya tenga el
# hardening extra de esta fase (SELinux/audit/nftables/dm-crypt en
# kernel-hardening.config) — si no, correr primero:
#   scripts/build-kernel.sh
#
# Orden (cada paso depende del anterior — no saltear):
#   1.  libmnl      -> librería netlink genérica de base
#   2.  libnftnl    -> librería netlink específica de nf_tables, sobre libmnl
#   3.  nftables    -> el binario `nft`, sobre libmnl+libnftnl
#   4.  libcap-ng   -> dependencia opcional de auditd para bajar privilegios
#   5.  auditd      -> auditoría inmutable (auditd, auparse, auditctl, reglas)
#   6.  libargon2   -> KDF Argon2id para LUKS2 (implementación de referencia PHC)
#   7.  popt        -> parseo de argumentos de línea de comandos, lo necesita cryptsetup
#   8.  json-c      -> metadata JSON de LUKS2 (primer paquete con CMake, no autotools)
#   9.  libaio      -> AIO nativo de Linux, lo necesita LVM2 (bcache) incluso sin dmeventd
#   10. lvm2        -> libdevmapper/liblvm2cmd completo, cryptsetup habla con dm-crypt vía esto
#   11. cryptsetup  -> LUKS2 + Argon2id, backend de cripto "kernel" (AF_ALG, sin libgcrypt/openssl)
#   12. bzip2       -> NUEVA dependencia: libsemanage linkea contra -lbz2
#   13. pcre2       -> NUEVA dependencia: libselinux matchea file_contexts con PCRE2, no POSIX regex
#   14. libsepol    -> capa más baja de SELinux: binary policy + CIL embebido, sin dependencias
#   15. libselinux  -> API de SELinux para el resto del userspace, sobre libsepol+pcre2
#   16. libsemanage -> gestión de políticas/módulos instalados, sobre libselinux+libsepol+audit+bzip2
#   17. checkpolicy -> compilador de políticas (checkpolicy/checkmodule) — NATIVO, no va al sysroot
#   18. libxcrypt   -> NUEVA dependencia: glibc ${GLIBC_VERSION} ya no trae libcrypt, y newrole/run_init
#                      de policycoreutils (PAMH=n) linkean contra -lcrypt
#   19. policycoreutils -> semodule/setfiles/restorecon/load_policy/sestatus/etc., el toolset real de SELinux
#
# SELinux queda con las librerías/binarios necesarios en el sysroot, pero SIN
# cargar ninguna política (eso es trabajo de refpolicy, fuera del alcance de
# esta fase de "poblar el sysroot": ver el comentario largo arriba de
# step_checkpolicy). Cargar/aplicar una política real queda para el primer
# arranque del sistema ya instalado.
#
# Uso:
#   scripts/build-security.sh libmnl
#   scripts/build-security.sh all        # corre todos los pasos implementados
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/lfs/scripts/env.sh
source "${SCRIPT_DIR}/env.sh"

log()  { printf '\n\033[1;33m[fase3]\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m[fase3][error]\033[0m %s\n' "$*" >&2; exit 1; }

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

# Cualquier ./configure que use PKG_CHECK_MODULES (a diferencia de un simple
# AC_CHECK_LIB con -lalgo) necesita que pkg-config busque en el SYSROOT, no en
# el host — si no, o no encuentra nada (falso negativo) o, peor, encuentra un
# .pc del host que no tiene nada que ver con nuestro cross-build. Es la primera
# vez en el proyecto que hace falta esto: attr/acl/libcap/util-linux/zsh usaban
# AC_CHECK_LIB (el propio cross-gcc, con su --sysroot de siempre, alcanza), pero
# libnftnl y nftables sí buscan a su hermano recién compilado (libmnl) vía
# pkg-config de verdad. Se pasan como prefijo de variables al propio comando
# (mismo patrón que "PATH=... make ..." en util-linux), NO como función con
# command substitution — una función que sólo hace asignaciones no imprime
# nada por stdout, así que "$(func)" se expandiría a vacío y perdería las
# variables sin avisar.
#   PKG_CONFIG_LIBDIR   -> dónde están los .pc (reemplaza la ruta del host)
#   PKG_CONFIG_SYSROOT_DIR -> antepone esta ruta a los -I/-L que trae cada .pc
#     (los .pc de nuestro sysroot dicen "prefix=/usr", no "/lfs/usr")

# ------------------------------------------------------------------------------
# 1) libmnl — wrapper mínimo de netlink, base de libnftnl. Autotools estándar,
# mismo patrón que attr/acl.
# ------------------------------------------------------------------------------
step_libmnl() {
    require_toolchain
    log "libmnl ${LIBMNL_VERSION} para ${LFS_TGT}"

    cd "${LFS_SOURCES}"
    fetch "${LIBMNL_MIRROR}/libmnl-${LIBMNL_VERSION}.tar.bz2" \
          "libmnl-${LIBMNL_VERSION}.tar.bz2"
    log_sha256 "${LFS_SOURCES}/libmnl-${LIBMNL_VERSION}.tar.bz2"
    extract_once "${LFS_SOURCES}/libmnl-${LIBMNL_VERSION}.tar.bz2" \
                 "${LFS_BUILD}/.extracted-libmnl"

    local src="${LFS_BUILD}/libmnl-${LIBMNL_VERSION}"
    local bdir="${src}/build"
    mkdir -p "${bdir}"
    cd "${bdir}"

    ../configure \
        --host="${LFS_TGT}" \
        --build="$(build_triplet)" \
        --prefix=/usr \
        --disable-static

    make ${MAKEFLAGS}
    make DESTDIR="${LFS_SYSROOT}" install
    find "${LFS_SYSROOT}/usr/lib" -maxdepth 1 -name 'libmnl*.la' -delete 2>/dev/null || true

    log "libmnl instalado en ${LFS_SYSROOT}/usr"
}

step_verify_libmnl() {
    log "Verificación: libmnl.pc + libmnl.so en el sysroot"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/usr/lib/pkgconfig/libmnl.pc" "${LFS_SYSROOT}/usr/lib/libmnl.so"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    [[ "${ok}" -eq 1 ]] || die "falta algo de libmnl en el sysroot"
    log "OK: libmnl completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 2) libnftnl — API netlink específica de nf_tables, sobre libmnl. Primer
# paquete del proyecto que necesita pkg-config apuntado al sysroot (ver
# pkgconf_env arriba) en vez de alcanzar con el --sysroot que ya trae de
# fábrica el cross-gcc.
# ------------------------------------------------------------------------------
step_libnftnl() {
    require_toolchain
    log "libnftnl ${LIBNFTNL_VERSION} para ${LFS_TGT}"

    cd "${LFS_SOURCES}"
    fetch "${LIBNFTNL_MIRROR}/libnftnl-${LIBNFTNL_VERSION}.tar.xz" \
          "libnftnl-${LIBNFTNL_VERSION}.tar.xz"
    log_sha256 "${LFS_SOURCES}/libnftnl-${LIBNFTNL_VERSION}.tar.xz"
    extract_once "${LFS_SOURCES}/libnftnl-${LIBNFTNL_VERSION}.tar.xz" \
                 "${LFS_BUILD}/.extracted-libnftnl"

    local src="${LFS_BUILD}/libnftnl-${LIBNFTNL_VERSION}"
    local bdir="${src}/build"
    mkdir -p "${bdir}"
    cd "${bdir}"

    PKG_CONFIG_LIBDIR="${LFS_SYSROOT}/usr/lib/pkgconfig" \
    PKG_CONFIG_SYSROOT_DIR="${LFS_SYSROOT}" \
    ../configure \
        --host="${LFS_TGT}" \
        --build="$(build_triplet)" \
        --prefix=/usr \
        --disable-static

    make ${MAKEFLAGS}
    make DESTDIR="${LFS_SYSROOT}" install
    find "${LFS_SYSROOT}/usr/lib" -maxdepth 1 -name 'libnftnl*.la' -delete 2>/dev/null || true

    log "libnftnl instalado en ${LFS_SYSROOT}/usr"
}

step_verify_libnftnl() {
    log "Verificación: libnftnl.pc + libnftnl.so en el sysroot"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/usr/lib/pkgconfig/libnftnl.pc" "${LFS_SYSROOT}/usr/lib/libnftnl.so"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    [[ "${ok}" -eq 1 ]] || die "falta algo de libnftnl en el sysroot"
    log "OK: libnftnl completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 3) nftables — el binario `nft` en sí. --with-mini-gmp usa la implementación
# de bignum EMPAQUETADA adentro del propio nftables en vez de pedir libgmp del
# sistema — así evitamos tener que cross-compilar GMP para el sysroot sólo
# para esto (GMP ya existe como librería del HOST, de Fase 0, pero esa copia
# es para compilar GCC, no sirve para linkear contra el target).
# --without-cli apaga el shell interactivo de `nft` (edición de línea con
# libreadline) — no lo tenemos cross-compilado y no hace falta: `nft` sigue
# aplicando reglas/scripts perfectamente sin el modo interactivo, que es lo
# único que se pierde.
# ------------------------------------------------------------------------------
step_nftables() {
    require_toolchain
    log "nftables ${NFTABLES_VERSION} para ${LFS_TGT}"

    cd "${LFS_SOURCES}"
    fetch "${NFTABLES_MIRROR}/nftables-${NFTABLES_VERSION}.tar.xz" \
          "nftables-${NFTABLES_VERSION}.tar.xz"
    log_sha256 "${LFS_SOURCES}/nftables-${NFTABLES_VERSION}.tar.xz"
    extract_once "${LFS_SOURCES}/nftables-${NFTABLES_VERSION}.tar.xz" \
                 "${LFS_BUILD}/.extracted-nftables"

    local src="${LFS_BUILD}/nftables-${NFTABLES_VERSION}"
    local bdir="${src}/build"
    mkdir -p "${bdir}"
    cd "${bdir}"

    PKG_CONFIG_LIBDIR="${LFS_SYSROOT}/usr/lib/pkgconfig" \
    PKG_CONFIG_SYSROOT_DIR="${LFS_SYSROOT}" \
    ../configure \
        --host="${LFS_TGT}" \
        --build="$(build_triplet)" \
        --prefix=/usr \
        --sbindir=/usr/sbin \
        --disable-static \
        --with-mini-gmp \
        --without-cli

    make ${MAKEFLAGS}
    make DESTDIR="${LFS_SYSROOT}" install
    find "${LFS_SYSROOT}/usr/lib" -maxdepth 1 -name 'libnftables*.la' -delete 2>/dev/null || true

    log "nftables instalado en ${LFS_SYSROOT}/usr"
}

step_verify_nftables() {
    log "Verificación: binario nft presente y linkeado contra libmnl/libnftnl/libc del sysroot"
    local bin="${LFS_SYSROOT}/usr/sbin/nft"
    [[ -f "${bin}" ]] || die "no está ${bin} — falló la instalación"
    file "${bin}"
    "${LFS_TOOLS}/bin/${LFS_TGT}-readelf" -d "${bin}" | grep -i "needed"
    log "OK: nft compilado para ${LFS_TGT}."
}

# ------------------------------------------------------------------------------
# 4) libcap-ng — librería chica para manejar POSIX capabilities sin necesitar
# root para todo. auditd/audisp la usan (de forma opcional: LIBCAP_NG_PATH en
# su configure.ac) para que sus plugins corran con el mínimo privilegio en
# vez de con todo el root — coherente con el resto del hardening de Fase 3,
# aunque auditd compila igual sin esto. --without-python: no tenemos (ni
# queremos todavía) un Python3 cross-compilado para el target — sin este
# flag, configure puede detectar el python3 del HOST y romper el link.
# ------------------------------------------------------------------------------
step_libcap_ng() {
    require_toolchain
    log "libcap-ng ${LIBCAP_NG_VERSION} para ${LFS_TGT}"

    cd "${LFS_SOURCES}"
    fetch "${LIBCAP_NG_MIRROR}/v${LIBCAP_NG_VERSION}.tar.gz" \
          "libcap-ng-${LIBCAP_NG_VERSION}.tar.gz"
    log_sha256 "${LFS_SOURCES}/libcap-ng-${LIBCAP_NG_VERSION}.tar.gz"
    extract_once "${LFS_SOURCES}/libcap-ng-${LIBCAP_NG_VERSION}.tar.gz" \
                 "${LFS_BUILD}/.extracted-libcap-ng"

    local src="${LFS_BUILD}/libcap-ng-${LIBCAP_NG_VERSION}"

    # El tarball de GitHub (archive/refs/tags) es el árbol de git crudo: NO
    # trae un ./configure pre-generado como sí traen libmnl/libnftnl/nftables
    # (esos publican un dist real). El propio README de libcap-ng dice cómo
    # generarlo desde fuente: ./autogen.sh (llama a autoreconf puertas
    # adentro). autoconf/automake/libtool ya están instalados en la imagen
    # (Dockerfile, capa del toolchain LFS).
    if [[ ! -x "${src}/configure" ]]; then
        log "generando ./configure con autogen.sh (tarball crudo de git, sin configure pre-generado)"
        (cd "${src}" && ./autogen.sh)
    fi

    local bdir="${src}/build"
    mkdir -p "${bdir}"
    cd "${bdir}"

    ../configure \
        --host="${LFS_TGT}" \
        --build="$(build_triplet)" \
        --prefix=/usr \
        --disable-static \
        --without-python

    make ${MAKEFLAGS}
    make DESTDIR="${LFS_SYSROOT}" install
    find "${LFS_SYSROOT}/usr/lib" -maxdepth 1 -name 'libcap-ng*.la' -delete 2>/dev/null || true

    log "libcap-ng instalado en ${LFS_SYSROOT}/usr"
}

step_verify_libcap_ng() {
    log "Verificación: libcap-ng.so + cap-ng.h en el sysroot"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/usr/lib/libcap-ng.so" "${LFS_SYSROOT}/usr/include/cap-ng.h"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    [[ "${ok}" -eq 1 ]] || die "falta algo de libcap-ng en el sysroot"
    log "OK: libcap-ng completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 5) audit-userspace — auditd (el daemon), auparse (parseo de logs), auditctl
# (carga de reglas), audisp (plugins de despacho). Igual que libnftnl/nftables,
# necesita PKG_CONFIG apuntado al sysroot: detecta libnftnl vía pkg-config
# para --with-nftables (activado por defecto, ya lo tenemos de los pasos 2-3
# de esta fase) y systemd.pc para la ruta de las unidades (ya lo tenemos de
# Fase 2). --without-python3/--without-golang: no tenemos Python3 ni Go
# cross-compilados para el target — sin esto, configure puede detectar el
# del HOST y romper el link (bug conocido, linux-audit/audit-userspace issue
# #87). --disable-zos-remote: plugin audisp para IBM z/OS, viene HABILITADO
# por defecto y necesita OpenLDAP (lber.h/-llber) que no compilamos en el
# sysroot — sin apagarlo, configure aborta ahí mismo. --disable-gssapi-krb5/--disable-tls quedan explícitos aunque ya
# vienen apagados por defecto, para dejar documentado que es a propósito:
# todavía no compilamos krb5 ni OpenSSL en el sysroot, así que por ahora
# auditd sólo hace logging LOCAL, no remoto cifrado — se puede sumar más
# adelante si el laboratorio lo necesita.
# ------------------------------------------------------------------------------
step_audit() {
    require_toolchain
    log "audit-userspace ${AUDIT_VERSION} para ${LFS_TGT}"

    cd "${LFS_SOURCES}"
    fetch "${AUDIT_MIRROR}/v${AUDIT_VERSION}.tar.gz" \
          "audit-userspace-${AUDIT_VERSION}.tar.gz"
    log_sha256 "${LFS_SOURCES}/audit-userspace-${AUDIT_VERSION}.tar.gz"
    extract_once "${LFS_SOURCES}/audit-userspace-${AUDIT_VERSION}.tar.gz" \
                 "${LFS_BUILD}/.extracted-audit"

    # El repo se llama "audit-userspace" (no "audit"): GitHub nombra el
    # directorio del archive/refs/tags como "<repo>-<version>", así que la
    # carpeta extraída es "audit-userspace-${AUDIT_VERSION}", no "audit-...".
    local src="${LFS_BUILD}/audit-userspace-${AUDIT_VERSION}"

    # Igual que libcap-ng: este tarball es el árbol de git crudo, sin
    # ./configure pre-generado. El propio README dice "autoreconf -f
    # --install" para construir desde fuente.
    if [[ ! -x "${src}/configure" ]]; then
        log "generando ./configure con autoreconf (tarball crudo de git, sin configure pre-generado)"
        (cd "${src}" && autoreconf -f --install)
    fi

    local bdir="${src}/build"
    mkdir -p "${bdir}"
    cd "${bdir}"

    # CORREGIDO 2026-08-26 tras un intento real: "--without-python" no existe
    # (el flag se llama --with-python3/--without-python3, ver configure.ac) y
    # "zos remote" (plugin audisp para IBM z/OS) viene HABILITADO por
    # defecto y necesita OpenLDAP (lber.h/-llber), que no compilamos en el
    # sysroot — sin --disable-zos-remote, configure aborta ahí mismo. No
    # tiene sentido para un laboratorio Linux normal, así que se apaga.
    #
    # SEGUNDA CORRECCIÓN 2026-08-26: con esos flags, configure y la mayoría
    # del build (libaudit, libauparse, libauplugin) anduvieron bien, pero
    # falló linkeando el plugin audisp-af_unix: "libauparse.so.0 ... not
    # found (try using -rpath or -rpath-link)". Este proyecto tiene un árbol
    # de subdirectorios (lib -> auparse -> auplugin -> audisp/plugins/*)
    # donde el link final de cada plugin depende de .so de hermanos que
    # TODAVÍA no están instalados en el sysroot (recién se instalan al final
    # con "make install") — el linker cruzado, a diferencia de un ld nativo
    # con ldconfig, no encuentra solo esas rutas intermedias del árbol de
    # build. Se le pasan explícitas por -rpath-link vía LDFLAGS (es lo que
    # el propio mensaje de error sugiere), para las tres carpetas con .so
    # reales: lib (libaudit), auparse (libauparse), auplugin (libauplugin).
    PKG_CONFIG_LIBDIR="${LFS_SYSROOT}/usr/lib/pkgconfig" \
    PKG_CONFIG_SYSROOT_DIR="${LFS_SYSROOT}" \
    LDFLAGS="-Wl,-rpath-link,${bdir}/lib/.libs -Wl,-rpath-link,${bdir}/auparse/.libs -Wl,-rpath-link,${bdir}/auplugin/.libs" \
    ../configure \
        --host="${LFS_TGT}" \
        --build="$(build_triplet)" \
        --prefix=/usr \
        --sbindir=/usr/sbin \
        --sysconfdir=/etc \
        --localstatedir=/var \
        --disable-static \
        --without-python3 \
        --without-golang \
        --with-libcap-ng=yes \
        --disable-gssapi-krb5 \
        --disable-tls \
        --disable-experimental \
        --disable-zos-remote

    make ${MAKEFLAGS}
    make DESTDIR="${LFS_SYSROOT}" install
    find "${LFS_SYSROOT}/usr/lib" -maxdepth 1 \( -name 'libaudit*.la' -o -name 'libauparse*.la' \) -delete 2>/dev/null || true

    log "audit-userspace instalado en ${LFS_SYSROOT}/usr"
}

step_verify_audit() {
    log "Verificación: auditd/auditctl presentes y linkeados contra libaudit/libcap-ng del sysroot"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/usr/sbin/auditd" "${LFS_SYSROOT}/usr/sbin/auditctl" "${LFS_SYSROOT}/usr/lib/libaudit.so"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    [[ "${ok}" -eq 1 ]] || die "falta algo de audit-userspace en el sysroot"
    file "${LFS_SYSROOT}/usr/sbin/auditd"
    "${LFS_TOOLS}/bin/${LFS_TGT}-readelf" -d "${LFS_SYSROOT}/usr/sbin/auditd" | grep -i "needed"
    log "OK: auditd compilado para ${LFS_TGT}."
}

# ------------------------------------------------------------------------------
# 6) libargon2 — implementación de referencia del algoritmo ganador del
# Password Hashing Competition (Argon2id, el KDF que cryptsetup usa para
# derivar la clave simétrica de LUKS2 a partir de la passphrase). A
# diferencia de libcap-ng/audit-userspace, el tarball de GitHub de este
# proyecto NO necesita autoreconf/autogen: es un Makefile plano de toda la
# vida, sin autotools/CMake de por medio (confirmado: no hay configure.ac
# ni CMakeLists.txt en el repo).
#
# Dos variables del Makefile hay que pisar sí o sí, si no el build queda mal:
#   - LIBRARY_REL: por defecto se calcula con `uname -s`/`uname -m` del HOST
#     de build (Linux-x86_64 -> "lib/x86_64-linux-gnu", ruta multiarch estilo
#     Debian) — no tiene nada que ver con el sysroot LFS-style de este
#     proyecto (que usa simplemente /usr/lib). Sin pisarla, todo se instala
#     en una ruta que ningún .pc/ld.so.conf de acá espera.
#   - OPTTARGET: por defecto "native" — el Makefile compila un fragmento de
#     prueba con `$(CC) -march=$(OPTTARGET)` para decidir si usar la
#     implementación optimizada (src/opt.c) o la de referencia (src/ref.c).
#     Como el cross-gcc SÍ sabe compilar para x86_64 real (el triplet propio
#     es sólo un nombre, la ISA de destino es la misma), ese test-compile
#     anda bien solo — pero "native" grabaría en el binario final las
#     instrucciones específicas de la CPU de ESTA máquina de build (AVX2,
#     BMI2, etc.), lo cual es un problema de portabilidad para un sistema
#     operativo pensado para correr en otro hardware. Se fuerza a la
#     baseline genérica "x86-64" en su lugar.
#
# La receta de "ar rcs $@ $^" para la librería estática está hardcodeada en
# el Makefile (no usa $(AR) aunque se le pase por la línea de comandos) —
# no hace falta parchearla: "ar" simplemente empaqueta objetos ya
# compilados por el cross-gcc en un .a, no le importa para qué arquitectura
# son esos objetos, así que el "ar" nativo del host alcanza sin problema.
#
# CORREGIDO 2026-08-26 tras un intento real de "all" completo (segunda vez
# que corre este paso sobre el MISMO sysroot persistente, con libargon2.so
# ya instalado de una corrida anterior): el "install" de este Makefile hace
# "ln -s libargon2.so.1 libargon2.so" SIN "-f" — a diferencia de libtool
# (que sí usa "ln -s -f" siempre, visto en los logs de libmnl/libnftnl/etc.
# más arriba), un "ln -s" a secas se rompe si el symlink de destino ya
# existe ("File exists"), en vez de pisarlo. Esto no se nota en el primer
# build de un sysroot vacío — sólo aparece al volver a correr "scripts/
# build-security.sh all" sobre un /lfs que persiste entre corridas (volumen
# de Podman) y que ya tenía este paso instalado de antes. Se saca el
# symlink viejo a mano ANTES de "make install" para que la corrida sea
# repetible sin tener que borrar todo el sysroot.
# ------------------------------------------------------------------------------
step_libargon2() {
    require_toolchain
    log "libargon2 ${LIBARGON2_VERSION} para ${LFS_TGT}"

    cd "${LFS_SOURCES}"
    fetch "${LIBARGON2_MIRROR}/${LIBARGON2_VERSION}.tar.gz" \
          "libargon2-${LIBARGON2_VERSION}.tar.gz"
    log_sha256 "${LFS_SOURCES}/libargon2-${LIBARGON2_VERSION}.tar.gz"
    extract_once "${LFS_SOURCES}/libargon2-${LIBARGON2_VERSION}.tar.gz" \
                 "${LFS_BUILD}/.extracted-libargon2"

    # El repo se llama "phc-winner-argon2": GitHub nombra el directorio del
    # archive/refs/tags como "<repo>-<tag>".
    local src="${LFS_BUILD}/phc-winner-argon2-${LIBARGON2_VERSION}"
    cd "${src}"

    make ${MAKEFLAGS} \
        CC="${LFS_TGT}-gcc" \
        LIBRARY_REL=lib \
        OPTTARGET=x86-64 \
        ARGON2_VERSION="${LIBARGON2_VERSION}"

    rm -f "${LFS_SYSROOT}/usr/lib/libargon2.so"

    make DESTDIR="${LFS_SYSROOT}" PREFIX=/usr \
        CC="${LFS_TGT}-gcc" \
        LIBRARY_REL=lib \
        OPTTARGET=x86-64 \
        ARGON2_VERSION="${LIBARGON2_VERSION}" \
        install

    log "libargon2 instalado en ${LFS_SYSROOT}/usr"
}

step_verify_libargon2() {
    log "Verificación: libargon2.so + argon2.h en el sysroot"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/usr/lib/libargon2.so" "${LFS_SYSROOT}/usr/include/argon2.h"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    [[ "${ok}" -eq 1 ]] || die "falta algo de libargon2 en el sysroot"
    log "OK: libargon2 completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 7) popt — parseo de argumentos de línea de comandos estilo getopt_long
# extendido, lo necesita el binario `cryptsetup` (no la librería
# libcryptsetup en sí). Autotools estándar sin sorpresas: no tiene ningún
# check de tipo AC_TRY_RUN y su única dependencia (gettext/iconv) ya la
# provee glibc de por sí, así que no hace falta ningún paquete adicional en
# el sysroot.
# ------------------------------------------------------------------------------
step_popt() {
    require_toolchain
    log "popt ${POPT_VERSION} para ${LFS_TGT}"

    cd "${LFS_SOURCES}"
    fetch "${POPT_MIRROR}/popt-${POPT_VERSION}.tar.gz" \
          "popt-${POPT_VERSION}.tar.gz"
    log_sha256 "${LFS_SOURCES}/popt-${POPT_VERSION}.tar.gz"
    extract_once "${LFS_SOURCES}/popt-${POPT_VERSION}.tar.gz" \
                 "${LFS_BUILD}/.extracted-popt"

    local src="${LFS_BUILD}/popt-${POPT_VERSION}"
    local bdir="${src}/build"
    mkdir -p "${bdir}"
    cd "${bdir}"

    ../configure \
        --host="${LFS_TGT}" \
        --build="$(build_triplet)" \
        --prefix=/usr \
        --disable-static

    make ${MAKEFLAGS}
    make DESTDIR="${LFS_SYSROOT}" install
    find "${LFS_SYSROOT}/usr/lib" -maxdepth 1 -name 'libpopt*.la' -delete 2>/dev/null || true

    log "popt instalado en ${LFS_SYSROOT}/usr"
}

step_verify_popt() {
    log "Verificación: libpopt.so + popt.pc en el sysroot"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/usr/lib/libpopt.so" "${LFS_SYSROOT}/usr/lib/pkgconfig/popt.pc"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    [[ "${ok}" -eq 1 ]] || die "falta algo de popt en el sysroot"
    log "OK: popt completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 8) json-c — serialización JSON que usa cryptsetup para la metadata de
# LUKS2 (a diferencia de LUKS1, el header ya no es un formato binario fijo
# sino un blob JSON). Primer paquete de todo el proyecto que se compila con
# CMake en vez de autotools/Meson: necesita su propio "toolchain file" para
# cross-compilar, equivalente al --host de ./configure. Se genera acá mismo
# (no como archivo aparte en scripts/) porque es chico y sólo lo necesita
# este paso.
# CMAKE_SYSTEM_NAME es lo que activa el modo cross-compiling de CMake (sin
# esto, CMake asume que estás compilando PARA esta misma máquina aunque le
# des un compilador distinto). Los FIND_ROOT_PATH_MODE_* separan: programas
# de ayuda (PROGRAM) se siguen buscando en el host (NEVER = nunca en el
# sysroot), pero librerías/headers (LIBRARY/INCLUDE) SÓLO en el sysroot
# (ONLY = nunca en el host) — mismo espíritu que PKG_CONFIG_SYSROOT_DIR para
# autotools.
# ------------------------------------------------------------------------------
step_json_c() {
    require_toolchain
    log "json-c ${JSON_C_VERSION} para ${LFS_TGT}"

    if ! command -v cmake >/dev/null 2>&1; then
        die "no se encontró cmake en el PATH — hace falta reconstruir la imagen (podman compose build) después de agregar 'cmake' al Dockerfile."
    fi

    cd "${LFS_SOURCES}"
    fetch "${JSON_C_MIRROR}/json-c-${JSON_C_VERSION}.tar.gz" \
          "json-c-${JSON_C_VERSION}.tar.gz"
    log_sha256 "${LFS_SOURCES}/json-c-${JSON_C_VERSION}.tar.gz"
    extract_once "${LFS_SOURCES}/json-c-${JSON_C_VERSION}.tar.gz" \
                 "${LFS_BUILD}/.extracted-json-c"

    local src="${LFS_BUILD}/json-c-${JSON_C_VERSION}"
    local toolchain_file="${LFS_BUILD}/.cmake-toolchain-linsi.cmake"

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

    local bdir="${src}/build"
    mkdir -p "${bdir}"

    cmake -S "${src}" -B "${bdir}" -G "Unix Makefiles" \
        -DCMAKE_TOOLCHAIN_FILE="${toolchain_file}" \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=ON \
        -DBUILD_STATIC_LIBS=OFF \
        -DBUILD_TESTING=OFF \
        -DBUILD_APPS=OFF \
        -Wno-dev

    make -C "${bdir}" ${MAKEFLAGS}
    make -C "${bdir}" DESTDIR="${LFS_SYSROOT}" install

    log "json-c instalado en ${LFS_SYSROOT}/usr"
}

step_verify_json_c() {
    log "Verificación: libjson-c.so + json-c.pc en el sysroot"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/usr/lib/libjson-c.so" "${LFS_SYSROOT}/usr/lib/pkgconfig/json-c.pc"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    [[ "${ok}" -eq 1 ]] || die "falta algo de json-c en el sysroot"
    log "OK: json-c completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 9) libaio — AIO nativo de Linux (io_setup/io_submit/etc. en espacio de
# usuario). NO es dmeventd lo que lo necesita (ese sigue apagado): es la
# capa de caché de bloques (bcache) del núcleo mismo de LVM2, usada
# incluso por el subconjunto mínimo "device-mapper". Sin esto, lib/
# no compila ("device/bcache.c: fatal error: libaio.h: No such file or
# directory").
#
# CORREGIDO 2026-08-26 tras DOS intentos reales: primero se intentó evitar
# libaio compilando sólo el subconjunto `make [install_]device-mapper`
# que el propio configure de LVM2 sugiere para este caso — compiló bien,
# pero el `make install` de esa ruta angosta se rompió con un error
# oscuro ("install: target '.../libdevmapper.so.1.02': No such file or
# directory") que no reproduce el camino normal de instalación completa
# (`make install`, sin acotar a un target). En vez de seguir peleando con
# una ruta de instalación menos transitada de LVM2, es más simple y más
# confiable cross-compilar esta librería chica (Makefile plano, sin
# autotools) y hacer el build COMPLETO de LVM2 (con --enable-cmdlib, el
# camino que usan BLFS/Buildroot/Yocto de verdad).
#
# El Makefile de libaio (a diferencia de casi todo el resto de este
# proyecto) NO respeta DESTDIR — hay que pisar prefix/includedir/libdir
# directo, apuntándolos ya dentro del sysroot.
#
# Mismo cuidado agregado 2026-08-26 que en libargon2 (ver ese comentario):
# como es otro Makefile plano de estilo viejo, por las dudas se sacan los
# symlinks .so/.so.1 a mano antes de "make install" — así una segunda
# corrida de "all" sobre el mismo sysroot persistente no se rompe si el
# propio "ln -s" del Makefile no lleva "-f" (no se confirmó el bug acá
# como sí en libargon2, pero el "rm -f" no hace nada si el symlink no
# existe, así que no cuesta nada dejarlo de entrada).
# ------------------------------------------------------------------------------
step_libaio() {
    require_toolchain
    log "libaio ${LIBAIO_VERSION} para ${LFS_TGT}"

    cd "${LFS_SOURCES}"
    fetch "${LIBAIO_MIRROR}/libaio-${LIBAIO_VERSION}.tar.gz" \
          "libaio-${LIBAIO_VERSION}.tar.gz"
    log_sha256 "${LFS_SOURCES}/libaio-${LIBAIO_VERSION}.tar.gz"
    extract_once "${LFS_SOURCES}/libaio-${LIBAIO_VERSION}.tar.gz" \
                 "${LFS_BUILD}/.extracted-libaio"

    local src="${LFS_BUILD}/libaio-${LIBAIO_VERSION}"
    cd "${src}"

    rm -f "${LFS_SYSROOT}/usr/lib/libaio.so" "${LFS_SYSROOT}/usr/lib/libaio.so.1"

    make ${MAKEFLAGS} \
        CC="${LFS_TGT}-gcc" \
        AR="${LFS_TGT}-ar" \
        RANLIB="${LFS_TGT}-ranlib"

    make install \
        CC="${LFS_TGT}-gcc" \
        AR="${LFS_TGT}-ar" \
        RANLIB="${LFS_TGT}-ranlib" \
        prefix="${LFS_SYSROOT}/usr" \
        includedir="${LFS_SYSROOT}/usr/include" \
        libdir="${LFS_SYSROOT}/usr/lib"

    log "libaio instalado en ${LFS_SYSROOT}/usr"
}

step_verify_libaio() {
    log "Verificación: libaio.so + libaio.h en el sysroot"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/usr/lib/libaio.so" "${LFS_SYSROOT}/usr/include/libaio.h"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    [[ "${ok}" -eq 1 ]] || die "falta algo de libaio en el sysroot"
    log "OK: libaio completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 10) LVM2/device-mapper — cryptsetup habla con dm-crypt (el módulo del
# kernel que hace el cifrado real de bloques) a través de libdevmapper, no
# directamente. Con libaio ya en el sysroot (paso anterior), se hace el
# build COMPLETO (--enable-cmdlib: liblvm2cmd + el binario `lvm` con
# lvcreate/vgcreate/etc.), el camino normal/más probado de LVM2 en vez
# del subconjunto "device-mapper" que falló al instalar en el intento
# anterior. --disable-selinux/--disable-readline: no tenemos libselinux
# ni libreadline en el sysroot todavía (SELinux es el próximo — y
# último — paso de Fase 3), así que se apagan explícitos en vez de dejar
# que el autodetect de configure se tope con algo raro.
# ac_cv_path_MODPROBE_CMD se fija a mano porque el configure.ac de este
# proyecto busca el binario "modprobe" con una lista de rutas pensada
# para el HOST de build (AC_PATH_TOOL) y graba esa ruta hardcodeada en el
# binario final — sin esto, quedaría grabada la ruta de ESTA máquina de
# build en vez de la ruta real del sistema final. El propio proyecto (a
# diferencia de libcap-ng/audit-userspace) NO propaga el compilador
# cruzado al `make` automáticamente más allá de lo que configure ya
# detectó — por eso CC/AR/RANLIB se le vuelven a pasar explícitos en el
# paso de make.
#
# CORREGIDO 2026-08-26 tras un intento real: acá SÍ pasábamos también
# STRIP="${LFS_TGT}-strip" (mismo patrón que CC/AR/RANLIB), y eso rompía
# la instalación con un error muy confuso ("install: target
# '.../libdevmapper.so.1.02': No such file or directory"). Causa real,
# confirmada con `make -n` + probando el comando `install` a mano: en el
# make.tmpl de LVM2, $(STRIP) NO es "la ruta al binario strip" como en
# casi todo el resto de este proyecto — es un token suelto que se pega
# LITERAL al final de la línea de instalación
# (`INSTALL_PROGRAM = $(INSTALL) $(M_INSTALL_PROGRAM) $(STRIP)`),
# pensado para quedar vacío o ser un flag tipo "-s". Al pisarlo con la
# ruta completa del strip cruzado, `install` terminaba viendo TRES
# argumentos posicionales en vez de dos (source + dest) y pasaba al modo
# "instalar varios archivos DENTRO de un directorio" — con el propio
# archivo de destino mal interpretado como ese directorio, que claro que
# no existe. Sacamos STRIP= del todo acá (el Makefile ya lo deja vacío
# por defecto, así que no se pierde nada real).
# ------------------------------------------------------------------------------
step_lvm2() {
    require_toolchain
    log "LVM2 ${LVM2_VERSION} para ${LFS_TGT} (build completo, con libaio)"

    cd "${LFS_SOURCES}"
    fetch "${LVM2_MIRROR}/LVM2.${LVM2_VERSION}.tgz" \
          "LVM2.${LVM2_VERSION}.tgz"
    log_sha256 "${LFS_SOURCES}/LVM2.${LVM2_VERSION}.tgz"
    extract_once "${LFS_SOURCES}/LVM2.${LVM2_VERSION}.tgz" \
                 "${LFS_BUILD}/.extracted-lvm2"

    local src="${LFS_BUILD}/LVM2.${LVM2_VERSION}"
    cd "${src}"

    PKG_CONFIG_LIBDIR="${LFS_SYSROOT}/usr/lib/pkgconfig" \
    PKG_CONFIG_SYSROOT_DIR="${LFS_SYSROOT}" \
    ./configure \
        --host="${LFS_TGT}" \
        --build="$(build_triplet)" \
        --prefix=/usr \
        --enable-cmdlib \
        --enable-pkgconfig \
        --enable-udev_sync \
        --disable-dmeventd \
        --disable-selinux \
        --disable-readline \
        ac_cv_path_MODPROBE_CMD=/usr/sbin/modprobe

    make ${MAKEFLAGS} \
        CC="${LFS_TGT}-gcc" \
        AR="${LFS_TGT}-ar" \
        RANLIB="${LFS_TGT}-ranlib"

    make DESTDIR="${LFS_SYSROOT}" \
        CC="${LFS_TGT}-gcc" \
        AR="${LFS_TGT}-ar" \
        RANLIB="${LFS_TGT}-ranlib" \
        install

    find "${LFS_SYSROOT}/usr/lib" -maxdepth 1 \( -name 'libdevmapper*.la' -o -name 'liblvm2cmd*.la' \) -delete 2>/dev/null || true

    log "LVM2 instalado en ${LFS_SYSROOT}/usr"
}

step_verify_lvm2() {
    log "Verificación: lvm/dmsetup presentes y libdevmapper/devmapper.pc en el sysroot"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/usr/sbin/lvm" "${LFS_SYSROOT}/usr/sbin/dmsetup" "${LFS_SYSROOT}/usr/lib/libdevmapper.so" "${LFS_SYSROOT}/usr/lib/pkgconfig/devmapper.pc"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    [[ "${ok}" -eq 1 ]] || die "falta algo de LVM2 en el sysroot"
    file "${LFS_SYSROOT}/usr/sbin/lvm"
    log "OK: LVM2/device-mapper completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 10) cryptsetup — LUKS2 con Argon2id. --with-crypto_backend=kernel: habla
# directo con la API de cripto en espacio de usuario del kernel (AF_ALG, ya
# habilitada en kernel-hardening.config de Fase 1 con
# CONFIG_CRYPTO_USER_API_SKCIPHER/HASH) en vez de necesitar libgcrypt,
# OpenSSL, nettle o mbedTLS cross-compilados en el sysroot — el cifrado
# real de los bloques (AES-XTS) siempre lo termina haciendo dm-crypt en el
# kernel de todos modos, así que este backend sólo cubre operaciones
# puntuales de userspace (hashes, autotest). --enable-libargon2: sin esto,
# cryptsetup cae a su implementación de Argon2 interna/embebida (más lenta,
# "reference" en vez de "optimized") — como sí compilamos libargon2 en el
# paso 6, se usa esa. --disable-asciidoc: no tenemos asciidoctor en la
# imagen, y sin este flag configure lo exige para regenerar las páginas de
# manual (el tarball ya las trae generadas). --disable-ssh-token: el plugin
# de token vía SSH necesita libssh, que no está en el sysroot, y viene
# habilitado por defecto. --disable-external-tokens: apaga la carga de
# plugins externos de token (fido2/pkcs11/systemd-cryptenroll) por completo
# — no están compilados y no hacen falta para LUKS2 con passphrase.
# --disable-nls: evita depender de msgfmt/gettext del toolchain cruzado
# para los mensajes traducidos, que no compilamos.
# ------------------------------------------------------------------------------
step_cryptsetup() {
    require_toolchain
    log "cryptsetup ${CRYPTSETUP_VERSION} para ${LFS_TGT}"

    cd "${LFS_SOURCES}"
    fetch "${CRYPTSETUP_MIRROR}/cryptsetup-${CRYPTSETUP_VERSION}.tar.xz" \
          "cryptsetup-${CRYPTSETUP_VERSION}.tar.xz"
    log_sha256 "${LFS_SOURCES}/cryptsetup-${CRYPTSETUP_VERSION}.tar.xz"
    extract_once "${LFS_SOURCES}/cryptsetup-${CRYPTSETUP_VERSION}.tar.xz" \
                 "${LFS_BUILD}/.extracted-cryptsetup"

    local src="${LFS_BUILD}/cryptsetup-${CRYPTSETUP_VERSION}"
    local bdir="${src}/build"
    mkdir -p "${bdir}"
    cd "${bdir}"

    PKG_CONFIG_LIBDIR="${LFS_SYSROOT}/usr/lib/pkgconfig" \
    PKG_CONFIG_SYSROOT_DIR="${LFS_SYSROOT}" \
    ../configure \
        --host="${LFS_TGT}" \
        --build="$(build_triplet)" \
        --prefix=/usr \
        --sbindir=/usr/sbin \
        --disable-static \
        --with-crypto_backend=kernel \
        --enable-libargon2 \
        --disable-asciidoc \
        --disable-ssh-token \
        --disable-external-tokens \
        --disable-nls

    make ${MAKEFLAGS}
    make DESTDIR="${LFS_SYSROOT}" install
    find "${LFS_SYSROOT}/usr/lib" -maxdepth 1 -name 'libcryptsetup*.la' -delete 2>/dev/null || true

    log "cryptsetup instalado en ${LFS_SYSROOT}/usr"
}

step_verify_cryptsetup() {
    log "Verificación: cryptsetup/veritysetup/integritysetup presentes y linkeados contra libargon2/libjson-c/libdevmapper/libpopt del sysroot"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/usr/sbin/cryptsetup" "${LFS_SYSROOT}/usr/sbin/veritysetup" "${LFS_SYSROOT}/usr/sbin/integritysetup" "${LFS_SYSROOT}/usr/lib/libcryptsetup.so"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    [[ "${ok}" -eq 1 ]] || die "falta algo de cryptsetup en el sysroot"
    file "${LFS_SYSROOT}/usr/sbin/cryptsetup"
    "${LFS_TOOLS}/bin/${LFS_TGT}-readelf" -d "${LFS_SYSROOT}/usr/sbin/cryptsetup" | grep -i "needed"
    log "OK: cryptsetup compilado para ${LFS_TGT}. LUKS2 + Argon2id listo en el sysroot."
}

# ------------------------------------------------------------------------------
# 12) bzip2 — libsemanage lo necesita (-lbz2, comprime el store de políticas
# instaladas). El "bzip2" que ya está en el Dockerfile es sólo el binario del
# HOST para descomprimir tarballs .bz2 de fuentes (libmnl) — no sirve para
# linkear, hace falta esta copia cross-compilada aparte con libbz2.so en el
# sysroot.
#
# A diferencia de casi todo el resto del proyecto, el Makefile de bzip2 NO
# respeta DESTDIR (ni lo menciona) — PREFIX se pisa directo apuntando ya
# adentro del sysroot. Y la librería COMPARTIDA está en un Makefile aparte
# (Makefile-libbz2_so, sin target de instalación propio): el `make install`
# normal sólo deja la .a estática + headers + binarios estáticos, hay que
# compilar y copiar el .so a mano, con sus symlinks de soname (mismo patrón
# que usa BLFS para esto desde siempre).
#
# Nunca "make"/"make all" a secas: ese target arrastra "test", que EJECUTA
# el bzip2 recién compilado (arquitectura del target) contra archivos de
# prueba — rompería bajo cross-compile. "make install" sólo depende de
# "bzip2 bzip2recover" (compilar, no correr nada), así que ir directo ahí es
# seguro.
#
# CORREGIDO 2026-08-27 tras un intento real: el orden de acá abajo importa
# y el original estaba al revés. El Makefile plano compila los .o SIN
# -fPIC (son para el .a estático y el CLI estático); Makefile-libbz2_so
# necesita esos mismos archivos .c compilados CON -fPIC para poder armar
# una librería compartida. El problema es que "make" no distingue esto por
# nombre de target — si el .o ya existe y es más nuevo que el .c, lo
# reusa tal cual esté (con o sin -fPIC). Correr primero el Makefile plano
# (como se hacía acá) deja objetos sin -fPIC en el directorio, y el link de
# la .so se rompe después con "relocation ... can not be used when making a
# shared object; recompile with -fPIC". La receta real de BLFS arma
# primero la .so (objetos frescos, con -fPIC), hace "make clean" (que
# borra esos .o pero NO toca los .so ya generados — no están en su target
# "clean"), y RECIÉN AHÍ compila lo estático (objetos frescos sin -fPIC).
# Se agrega además un "make clean" bien al principio: como esta carpeta de
# fuente vive en un volumen que persiste entre corridas del contenedor, un
# intento previo fallido puede haber dejado objetos viejos dando vueltas.
# ------------------------------------------------------------------------------
step_bzip2() {
    require_toolchain
    log "bzip2 ${BZIP2_VERSION} para ${LFS_TGT}"

    cd "${LFS_SOURCES}"
    fetch "${BZIP2_MIRROR}/bzip2-${BZIP2_VERSION}.tar.gz" \
          "bzip2-${BZIP2_VERSION}.tar.gz"
    log_sha256 "${LFS_SOURCES}/bzip2-${BZIP2_VERSION}.tar.gz"
    extract_once "${LFS_SOURCES}/bzip2-${BZIP2_VERSION}.tar.gz" \
                 "${LFS_BUILD}/.extracted-bzip2"

    local src="${LFS_BUILD}/bzip2-${BZIP2_VERSION}"
    cd "${src}"

    make clean >/dev/null 2>&1 || true

    make -f Makefile-libbz2_so CC="${LFS_TGT}-gcc"

    make clean

    make CC="${LFS_TGT}-gcc" AR="${LFS_TGT}-ar" RANLIB="${LFS_TGT}-ranlib" \
        PREFIX="${LFS_SYSROOT}/usr" install

    install -d "${LFS_SYSROOT}/usr/lib"
    install -m755 "libbz2.so.${BZIP2_VERSION}" "${LFS_SYSROOT}/usr/lib/"
    ln -sf "libbz2.so.${BZIP2_VERSION}" "${LFS_SYSROOT}/usr/lib/libbz2.so.1.0"
    ln -sf "libbz2.so.${BZIP2_VERSION}" "${LFS_SYSROOT}/usr/lib/libbz2.so"

    log "bzip2 instalado en ${LFS_SYSROOT}/usr"
}

step_verify_bzip2() {
    log "Verificación: libbz2.so + bzlib.h en el sysroot"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/usr/lib/libbz2.so" "${LFS_SYSROOT}/usr/include/bzlib.h"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    [[ "${ok}" -eq 1 ]] || die "falta algo de bzip2 en el sysroot"
    log "OK: bzip2 completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 13) PCRE2 — libselinux lo necesita para matchear los patrones de
# file_contexts (USE_PCRE2=y es el default del propio proyecto SELinux; la
# alternativa USE_PCRE2=n no cae a la regex POSIX de glibc como se podría
# suponer, sino a la libpcre1 vieja y discontinuada desde 2021 — mejor
# compilar PCRE2 de una vez que agregar una dependencia peor). Autotools
# estándar, sin sorpresas de cross-compile: la tabla de caracteres
# (chartables) viene pre-generada en el tarball y se copia tal cual — el
# generador que SÍ ejecutaría un binario (pcre2_dftables) sólo entra en
# juego con --enable-rebuild-chartables, que no se usa acá.
# --enable-pcre2-8/--disable-pcre2-16/--disable-pcre2-32: sólo hace falta la
# variante de 8 bits (la que usa libselinux) — son los valores por defecto,
# se dejan explícitos para que quede documentado que es a propósito.
# ------------------------------------------------------------------------------
step_pcre2() {
    require_toolchain
    log "PCRE2 ${PCRE2_VERSION} para ${LFS_TGT}"

    cd "${LFS_SOURCES}"
    fetch "${PCRE2_MIRROR}/pcre2-${PCRE2_VERSION}.tar.gz" \
          "pcre2-${PCRE2_VERSION}.tar.gz"
    log_sha256 "${LFS_SOURCES}/pcre2-${PCRE2_VERSION}.tar.gz"
    extract_once "${LFS_SOURCES}/pcre2-${PCRE2_VERSION}.tar.gz" \
                 "${LFS_BUILD}/.extracted-pcre2"

    local src="${LFS_BUILD}/pcre2-${PCRE2_VERSION}"
    local bdir="${src}/build"
    mkdir -p "${bdir}"
    cd "${bdir}"

    ../configure \
        --host="${LFS_TGT}" \
        --build="$(build_triplet)" \
        --prefix=/usr \
        --disable-static \
        --enable-pcre2-8 \
        --disable-pcre2-16 \
        --disable-pcre2-32

    make ${MAKEFLAGS}
    make DESTDIR="${LFS_SYSROOT}" install
    find "${LFS_SYSROOT}/usr/lib" -maxdepth 1 -name 'libpcre2*.la' -delete 2>/dev/null || true

    log "PCRE2 instalado en ${LFS_SYSROOT}/usr"
}

step_verify_pcre2() {
    log "Verificación: libpcre2-8.so + libpcre2-8.pc en el sysroot"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/usr/lib/libpcre2-8.so" "${LFS_SYSROOT}/usr/lib/pkgconfig/libpcre2-8.pc"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    [[ "${ok}" -eq 1 ]] || die "falta algo de PCRE2 en el sysroot"
    log "OK: PCRE2 completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 14) libsepol — la capa más baja de SELinux: manejo de binary policy +
# compilador CIL embebido (lo que usa libsemanage/semodule en runtime para
# cargar módulos, sin necesitar el checkpolicy externo). Sin dependencias
# propias. Igual que casi todo Fase 3: Makefile plano, sin autotools, con
# DESTDIR sí respetado (a diferencia de libaio/bzip2).
#
# SHLIBDIR pisado a mano: por defecto vale el ABSOLUTO "/lib" (no relativo a
# PREFIX como todo lo demás) — dejarlo default instalaría el .so en
# /lib mientras el .a y el .pc quedan en /usr/lib, roto en un sistema
# merged-/usr como este (--prefix=/usr en todos los demás pasos). Buildroot
# tiene exactamente este mismo parche documentado en su libsepol.mk.
# ------------------------------------------------------------------------------
step_libsepol() {
    require_toolchain
    log "libsepol ${SELINUX_VERSION} para ${LFS_TGT}"

    cd "${LFS_SOURCES}"
    fetch "${SELINUX_MIRROR}/libsepol-${SELINUX_VERSION}.tar.gz" \
          "libsepol-${SELINUX_VERSION}.tar.gz"
    log_sha256 "${LFS_SOURCES}/libsepol-${SELINUX_VERSION}.tar.gz"
    extract_once "${LFS_SOURCES}/libsepol-${SELINUX_VERSION}.tar.gz" \
                 "${LFS_BUILD}/.extracted-libsepol"

    local src="${LFS_BUILD}/libsepol-${SELINUX_VERSION}"
    cd "${src}"

    make ${MAKEFLAGS} \
        CC="${LFS_TGT}-gcc" AR="${LFS_TGT}-ar" RANLIB="${LFS_TGT}-ranlib"

    make install \
        DESTDIR="${LFS_SYSROOT}" PREFIX=/usr SHLIBDIR=/usr/lib \
        CC="${LFS_TGT}-gcc" AR="${LFS_TGT}-ar" RANLIB="${LFS_TGT}-ranlib"

    log "libsepol instalado en ${LFS_SYSROOT}/usr"
}

step_verify_libsepol() {
    log "Verificación: libsepol.so + libsepol.pc en el sysroot"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/usr/lib/libsepol.so" "${LFS_SYSROOT}/usr/lib/pkgconfig/libsepol.pc"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    [[ "${ok}" -eq 1 ]] || die "falta algo de libsepol en el sysroot"
    log "OK: libsepol completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 15) libselinux — la API real de SELinux (is_selinux_enabled, getcon,
# matchpathcon, etc.) que usa el resto del userspace. Sobre libsepol (link
# directo, alcanza con el --sysroot de fábrica del cross-gcc) y PCRE2 (vía
# pkg-config de verdad, por eso el mismo PKG_CONFIG_LIBDIR/SYSROOT_DIR que ya
# se usa para libnftnl/nftables/audit). Mismo SHLIBDIR=/usr/lib que
# libsepol, mismo motivo.
#
# Las bindings de Python/SWIG (pywrap) son un target APARTE, no incluido en
# el "all"/"install" por defecto — no hace falta ningún flag para apagarlas,
# simplemente nunca se invoca "make pywrap"/"make install-pywrap".
# DISABLE_RPM=y: no compilamos rpm/librpm en el sysroot, y sin esto configure
# puede detectar algo del HOST y romper el link.
# ------------------------------------------------------------------------------
step_libselinux() {
    require_toolchain
    log "libselinux ${SELINUX_VERSION} para ${LFS_TGT}"

    cd "${LFS_SOURCES}"
    fetch "${SELINUX_MIRROR}/libselinux-${SELINUX_VERSION}.tar.gz" \
          "libselinux-${SELINUX_VERSION}.tar.gz"
    log_sha256 "${LFS_SOURCES}/libselinux-${SELINUX_VERSION}.tar.gz"
    extract_once "${LFS_SOURCES}/libselinux-${SELINUX_VERSION}.tar.gz" \
                 "${LFS_BUILD}/.extracted-libselinux"

    local src="${LFS_BUILD}/libselinux-${SELINUX_VERSION}"
    cd "${src}"

    PKG_CONFIG_LIBDIR="${LFS_SYSROOT}/usr/lib/pkgconfig" \
    PKG_CONFIG_SYSROOT_DIR="${LFS_SYSROOT}" \
    make ${MAKEFLAGS} \
        CC="${LFS_TGT}-gcc" AR="${LFS_TGT}-ar" RANLIB="${LFS_TGT}-ranlib" \
        DISABLE_RPM=y

    PKG_CONFIG_LIBDIR="${LFS_SYSROOT}/usr/lib/pkgconfig" \
    PKG_CONFIG_SYSROOT_DIR="${LFS_SYSROOT}" \
    make install \
        DESTDIR="${LFS_SYSROOT}" PREFIX=/usr SHLIBDIR=/usr/lib \
        CC="${LFS_TGT}-gcc" AR="${LFS_TGT}-ar" RANLIB="${LFS_TGT}-ranlib" \
        DISABLE_RPM=y

    log "libselinux instalado en ${LFS_SYSROOT}/usr"
}

step_verify_libselinux() {
    log "Verificación: libselinux.so + selinux/selinux.h + libselinux.pc en el sysroot"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/usr/lib/libselinux.so" "${LFS_SYSROOT}/usr/include/selinux/selinux.h" "${LFS_SYSROOT}/usr/lib/pkgconfig/libselinux.pc"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    [[ "${ok}" -eq 1 ]] || die "falta algo de libselinux en el sysroot"
    log "OK: libselinux completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 16) libsemanage — gestión de políticas/módulos instalados (lo que usa
# `semodule` de policycoreutils, el próximo paso). Linkea directo contra
# libsepol, libselinux, libaudit y libbz2 (-lsepol -laudit -lselinux -lbz2,
# ninguno vía pkg-config para sí mismos, el --sysroot de fábrica del
# cross-gcc alcanza) — el PKG_CONFIG_LIBDIR/SYSROOT_DIR de acá es sólo por
# consistencia con el resto del proyecto, no hace falta que algo lo use de
# verdad. Nota ya confirmada por investigación: la vieja dependencia "ustr"
# que aparece en guías antiguas de libsemanage NO existe más en el código
# actual — no hace falta agregar ningún paquete para eso.
# ------------------------------------------------------------------------------
step_libsemanage() {
    require_toolchain
    log "libsemanage ${SELINUX_VERSION} para ${LFS_TGT}"

    cd "${LFS_SOURCES}"
    fetch "${SELINUX_MIRROR}/libsemanage-${SELINUX_VERSION}.tar.gz" \
          "libsemanage-${SELINUX_VERSION}.tar.gz"
    log_sha256 "${LFS_SOURCES}/libsemanage-${SELINUX_VERSION}.tar.gz"
    extract_once "${LFS_SOURCES}/libsemanage-${SELINUX_VERSION}.tar.gz" \
                 "${LFS_BUILD}/.extracted-libsemanage"

    local src="${LFS_BUILD}/libsemanage-${SELINUX_VERSION}"
    cd "${src}"

    PKG_CONFIG_LIBDIR="${LFS_SYSROOT}/usr/lib/pkgconfig" \
    PKG_CONFIG_SYSROOT_DIR="${LFS_SYSROOT}" \
    make ${MAKEFLAGS} \
        CC="${LFS_TGT}-gcc" AR="${LFS_TGT}-ar" RANLIB="${LFS_TGT}-ranlib"

    PKG_CONFIG_LIBDIR="${LFS_SYSROOT}/usr/lib/pkgconfig" \
    PKG_CONFIG_SYSROOT_DIR="${LFS_SYSROOT}" \
    make install \
        DESTDIR="${LFS_SYSROOT}" PREFIX=/usr SHLIBDIR=/usr/lib \
        CC="${LFS_TGT}-gcc" AR="${LFS_TGT}-ar" RANLIB="${LFS_TGT}-ranlib"

    log "libsemanage instalado en ${LFS_SYSROOT}/usr"
}

step_verify_libsemanage() {
    log "Verificación: libsemanage.so + semanage/semanage.h + libsemanage.pc en el sysroot"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/usr/lib/libsemanage.so" "${LFS_SYSROOT}/usr/include/semanage/semanage.h" "${LFS_SYSROOT}/usr/lib/pkgconfig/libsemanage.pc"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    [[ "${ok}" -eq 1 ]] || die "falta algo de libsemanage en el sysroot"
    log "OK: libsemanage completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 17) checkpolicy — el COMPILADOR de políticas (binarios `checkpolicy` y
# `checkmodule`, que traducen texto .te/.conf a binary policy). A propósito
# NO se cross-compila ni se instala en el sysroot del target: un sistema
# SELinux en funcionamiento nunca lo ejecuta — cargar/actualizar módulos en
# runtime pasa por libsemanage (`semodule`), que ya trae su propio
# compilador CIL embebido adentro de libsepol. checkpolicy/checkmodule sólo
# hacen falta para COMPILAR políticas fuente (por ejemplo refpolicy, que
# queda fuera del alcance de esta fase — ver más abajo), y esa compilación
# se puede hacer en cualquier momento, en la máquina de build, con la
# política resultante (binaria, independiente de arquitectura) copiada al
# sysroot recién cuando exista. Por eso se compila con el gcc NATIVO del
# contenedor (no ${LFS_TGT}-gcc) y se instala en ${LFS_TOOLS} (ya está en el
# PATH, mismo lugar que el cross-toolchain de Fase 0) en vez de con
# DESTDIR="${LFS_SYSROOT}".
#
# checkpolicy linkea libsepol.a de forma ESTÁTICA (necesita símbolos
# internos que la .so no expone). Como se está compilando NATIVO, no sirve
# reusar el libsepol.a cross-compilado del sysroot (pensado para el glibc
# del target, no necesariamente compatible con el glibc del propio
# contenedor aunque la arquitectura coincida) — se recompila libsepol una
# segunda vez, nativo, en un prefix descartable aparte, sólo para este paso.
# El Makefile de checkpolicy no asume ningún layout de directorios hermanos:
# LIBSEPOLA/CPPFLAGS/LDFLAGS son variables normales que se le pueden pasar
# apuntando a cualquier libsepol ya instalado.
# ------------------------------------------------------------------------------
step_checkpolicy() {
    log "checkpolicy ${SELINUX_VERSION} — NATIVO (compilador de políticas, no va al sysroot del target)"

    if ! command -v gcc >/dev/null 2>&1; then
        die "no se encontró gcc nativo en el PATH"
    fi

    cd "${LFS_SOURCES}"
    fetch "${SELINUX_MIRROR}/libsepol-${SELINUX_VERSION}.tar.gz" \
          "libsepol-${SELINUX_VERSION}.tar.gz"
    fetch "${SELINUX_MIRROR}/checkpolicy-${SELINUX_VERSION}.tar.gz" \
          "checkpolicy-${SELINUX_VERSION}.tar.gz"
    log_sha256 "${LFS_SOURCES}/checkpolicy-${SELINUX_VERSION}.tar.gz"
    extract_once "${LFS_SOURCES}/checkpolicy-${SELINUX_VERSION}.tar.gz" \
                 "${LFS_BUILD}/.extracted-checkpolicy"

    # libsepol nativo: se extrae aparte (no en el mismo directorio que usa
    # step_libsepol para el build cross) para no mezclar objetos .o de dos
    # toolchains distintas en el mismo árbol de fuente.
    local sepol_native_src="${LFS_BUILD}/.native-libsepol-src"
    local sepol_native_prefix="${LFS_BUILD}/.native-libsepol-prefix"
    rm -rf "${sepol_native_src}"
    mkdir -p "${sepol_native_src}"
    tar -xf "${LFS_SOURCES}/libsepol-${SELINUX_VERSION}.tar.gz" \
        -C "${sepol_native_src}" --strip-components=1
    (
        cd "${sepol_native_src}"
        make ${MAKEFLAGS}
        make install PREFIX="${sepol_native_prefix}" SHLIBDIR="${sepol_native_prefix}/lib"
    )

    local src="${LFS_BUILD}/checkpolicy-${SELINUX_VERSION}"
    cd "${src}"

    make ${MAKEFLAGS} \
        CPPFLAGS="-I${sepol_native_prefix}/include" \
        LDFLAGS="-L${sepol_native_prefix}/lib" \
        LIBSEPOLA="${sepol_native_prefix}/lib/libsepol.a"

    make install PREFIX="${LFS_TOOLS}" \
        CPPFLAGS="-I${sepol_native_prefix}/include" \
        LDFLAGS="-L${sepol_native_prefix}/lib" \
        LIBSEPOLA="${sepol_native_prefix}/lib/libsepol.a"

    log "checkpolicy/checkmodule instalados en ${LFS_TOOLS}/bin (herramientas de build, no van al target)"
}

step_verify_checkpolicy() {
    log "Verificación: checkpolicy/checkmodule nativos presentes"
    local ok=1
    local p
    for p in "${LFS_TOOLS}/bin/checkpolicy" "${LFS_TOOLS}/bin/checkmodule"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    [[ "${ok}" -eq 1 ]] || die "falta checkpolicy/checkmodule en ${LFS_TOOLS}/bin"
    file "${LFS_TOOLS}/bin/checkpolicy"
    log "OK: checkpolicy/checkmodule (nativos) listos."
}

# ------------------------------------------------------------------------------
# 18) libxcrypt — NUEVA dependencia, encontrada por un error real de build (no
# anticipada por la investigación inicial): policycoreutils se compila con
# PAMH=n (todavía no tenemos Linux-PAM cross-compilado), así que newrole/ y
# run_init/ caen a su rama "sin PAM", que linkea contra -lcrypt para verificar
# la contraseña del usuario (crypt(3) clásico). El supuesto original era que
# esa rama "no rompía el build" — pero eso asumía que -lcrypt existe.
#
# A partir de glibc 2.38 (y en ${GLIBC_VERSION}, que usa este proyecto),
# glibc DEJÓ de instalar libcrypt.so/crypt.h: el propio glibc lo marcó
# obsoleto y lo removió, delegando crypt(3) a una librería aparte. El error
# real fue: "ld: cannot find -lcrypt" al linkear newrole. libxcrypt (el
# reemplazo estándar, mismo que usan las distros reales para este caso) es la
# solución: reinstala /usr/lib/libcrypt.so + /usr/include/crypt.h en el
# sysroot, así que restaura exactamente el fallback que policycoreutils ya
# esperaba usar.
#
# --enable-obsolete-api=glibc: sin esto, libxcrypt expone únicamente su propia
# ABI moderna (símbolos XCRYPT_*) y NO los símbolos con versionado
# GLIBC_2.2.5 que es justo lo que el binario final espera resolver en
# tiempo de link/ejecución al pedir -lcrypt "a la vieja usanza". Con este
# flag, libxcrypt genera esos símbolos de compatibilidad además de los
# propios.
#
# 100% autotools estándar (out-of-tree en build/, como pcre2): sin
# dependencias externas (solo libc), por lo que no hace falta
# PKG_CONFIG_LIBDIR/PKG_CONFIG_SYSROOT_DIR acá. Probado en este mismo
# contenedor de forma nativa antes de escribir el step: el install es
# 100% vía libtool (todos los symlinks se crean con "ln -s -f"), así que,
# a diferencia de libargon2, NO tiene el bug de re-ejecución — no hace
# falta ningún "rm -f" defensivo antes del install.
#
# --enable-hashes=glibc: CORREGIDO 2026-08-27 tras un error real de build (el
# primer intento, sin este flag, rompió acá mismo). Por default (--enable-
# hashes=all, lo que hubiera quedado sin este cambio) libxcrypt compila TODOS
# los algoritmos de hash que soporta, incluido gost_yescrypt (GOST3411-2012 +
# yescrypt, una combinación rusa, no la necesitamos para nada acá). El
# archivo de ESE algoritmo (lib/crypt-gost-yescrypt.c) tiene un bug propio de
# upstream (confirmado en su repo real: sigue igual en la rama master, no es
# nada de nuestro cross-compile) que con este gcc/glibc dispara
# "-Werror=discarded-qualifiers" en un strchr() sobre un puntero const — y
# libxcrypt compila con -Werror por default, así que ese warning rompe TODO
# el build, no sólo ese hash.
#
# La solución NO es bajar el nivel de warnings (--disable-werror), sino ni
# siquiera compilar ese algoritmo: --enable-hashes=glibc selecciona sólo el
# grupo de hashes que el propio hashes.conf marca "GLIBC" (descrypt,
# md5crypt, sha256crypt, sha512crypt — los mismos que glibc siempre soportó
# de forma nativa), que es exactamente lo que hace falta para que newrole/
# run_init verifiquen una contraseña con crypt(3) clásico. Confirmado
# compilando nativo en este contenedor (con y sin el flag, para ver el bug
# real primero) que las fuentes de gost_yescrypt quedan afuera de la
# compilación real (crypt-hashes.h generado define "INCLUDE_gost_yescrypt 0",
# así que el cuerpo de la función entera queda bajo un "#if 0" y ni se
# compila) y que el símbolo "crypt" final sigue exportado con versionado
# GLIBC_2.2.5 (además de XCRYPT_2.0) — exactamente lo que hace falta para
# resolver el -lcrypt de policycoreutils.
# ------------------------------------------------------------------------------
step_libxcrypt() {
    require_toolchain
    log "libxcrypt ${LIBXCRYPT_VERSION} para ${LFS_TGT}"

    cd "${LFS_SOURCES}"
    fetch "${LIBXCRYPT_MIRROR}/libxcrypt-${LIBXCRYPT_VERSION}.tar.xz" \
          "libxcrypt-${LIBXCRYPT_VERSION}.tar.xz"
    log_sha256 "${LFS_SOURCES}/libxcrypt-${LIBXCRYPT_VERSION}.tar.xz"
    extract_once "${LFS_SOURCES}/libxcrypt-${LIBXCRYPT_VERSION}.tar.xz" \
                 "${LFS_BUILD}/.extracted-libxcrypt"

    local src="${LFS_BUILD}/libxcrypt-${LIBXCRYPT_VERSION}"
    local bdir="${src}/build"
    mkdir -p "${bdir}"
    cd "${bdir}"

    ../configure \
        --host="${LFS_TGT}" \
        --build="$(build_triplet)" \
        --prefix=/usr \
        --disable-static \
        --enable-obsolete-api=glibc \
        --enable-hashes=glibc

    make ${MAKEFLAGS}
    make DESTDIR="${LFS_SYSROOT}" install
    find "${LFS_SYSROOT}/usr/lib" -maxdepth 1 -name 'libcrypt.la' -delete 2>/dev/null || true

    log "libxcrypt instalado en ${LFS_SYSROOT}/usr (provee -lcrypt, removido de glibc ${GLIBC_VERSION})"
}
step_verify_libxcrypt() {
    log "Verificación: libcrypt.so + crypt.h en el sysroot"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/usr/lib/libcrypt.so" "${LFS_SYSROOT}/usr/include/crypt.h"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    [[ "${ok}" -eq 1 ]] || die "falta algo de libxcrypt en el sysroot"
    log "OK: libxcrypt completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 19) policycoreutils — el toolset real de SELinux para un sistema en
# funcionamiento: semodule (carga/gestiona módulos vía libsemanage),
# setfiles/restorecon (aplica file_contexts a un filesystem), load_policy,
# sestatus, newrole/run_init, setsebool. A diferencia de checkpolicy, esto
# SÍ va al sysroot del target (--host=${LFS_TGT} de nuevo).
#
# Las herramientas en Python (semanage CLI, audit2allow, sepolgen) NO viven
# en este paquete — están en un directorio "python/" aparte, separado, del
# mismo repo, que este proyecto no toca: policycoreutils en sí es 100% C,
# cero dependencia de Python.
#
# Dos gotchas reales de cross-compile encontrados leyendo los Makefiles:
#   - AUDITH/PAMH: varios subdirs (setfiles, run_init, newrole) autodetectan
#     libaudit/PAM probando si el HEADER existe en una ruta HARDCODEADA del
#     HOST (/usr/include/libaudit.h, literal, ignorando el sysroot) — el
#     autodetect miente bajo cross-compile. Se pasan explícitos: AUDITH=y
#     (sí tenemos audit-userspace en el sysroot, Fase 3 paso 5) y PAMH=n (no
#     tenemos Linux-PAM cross-compilado todavía — newrole/run_init caen a
#     -lcrypt en vez de romper el build).
#   - SBINDIR: todos los subdirs derivan el binario final de $(PREFIX)/sbin
#     salvo setfiles/Makefile, que trae "SBINDIR ?= /sbin" hardcodeado (no
#     relativo a PREFIX) — sin pisarlo, setfiles/restorecon quedarían en
#     /sbin mientras todo lo demás (con --prefix=/usr, sistema merged-/usr)
#     queda en /usr/sbin. Se fuerza SBINDIR=/usr/sbin en la línea de
#     comandos: como es una asignación de la línea de comandos de make, gana
#     sobre el "?=" del Makefile aunque ese subdir en particular lo redefina.
# ------------------------------------------------------------------------------
step_policycoreutils() {
    require_toolchain
    log "policycoreutils ${SELINUX_VERSION} para ${LFS_TGT}"

    cd "${LFS_SOURCES}"
    fetch "${SELINUX_MIRROR}/policycoreutils-${SELINUX_VERSION}.tar.gz" \
          "policycoreutils-${SELINUX_VERSION}.tar.gz"
    log_sha256 "${LFS_SOURCES}/policycoreutils-${SELINUX_VERSION}.tar.gz"
    extract_once "${LFS_SOURCES}/policycoreutils-${SELINUX_VERSION}.tar.gz" \
                 "${LFS_BUILD}/.extracted-policycoreutils"

    local src="${LFS_BUILD}/policycoreutils-${SELINUX_VERSION}"
    cd "${src}"

    PKG_CONFIG_LIBDIR="${LFS_SYSROOT}/usr/lib/pkgconfig" \
    PKG_CONFIG_SYSROOT_DIR="${LFS_SYSROOT}" \
    make ${MAKEFLAGS} \
        CC="${LFS_TGT}-gcc" AR="${LFS_TGT}-ar" RANLIB="${LFS_TGT}-ranlib" \
        AUDITH=y PAMH=n SBINDIR=/usr/sbin

    PKG_CONFIG_LIBDIR="${LFS_SYSROOT}/usr/lib/pkgconfig" \
    PKG_CONFIG_SYSROOT_DIR="${LFS_SYSROOT}" \
    make install \
        DESTDIR="${LFS_SYSROOT}" PREFIX=/usr SBINDIR=/usr/sbin \
        CC="${LFS_TGT}-gcc" AR="${LFS_TGT}-ar" RANLIB="${LFS_TGT}-ranlib" \
        AUDITH=y PAMH=n

    log "policycoreutils instalado en ${LFS_SYSROOT}/usr"
}

step_verify_policycoreutils() {
    log "Verificación: semodule/setfiles/load_policy/sestatus presentes y linkeados contra libsemanage/libselinux/libsepol del sysroot"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/usr/sbin/semodule" "${LFS_SYSROOT}/usr/sbin/setfiles" "${LFS_SYSROOT}/usr/sbin/load_policy" "${LFS_SYSROOT}/usr/sbin/sestatus"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    [[ "${ok}" -eq 1 ]] || die "falta algo de policycoreutils en el sysroot"
    file "${LFS_SYSROOT}/usr/sbin/semodule"
    "${LFS_TOOLS}/bin/${LFS_TGT}-readelf" -d "${LFS_SYSROOT}/usr/sbin/semodule" | grep -i "needed"
    log "OK: policycoreutils compilado para ${LFS_TGT}. Fase 3 completa: SELinux listo en el sysroot (política pendiente de cargar en el primer arranque)."
}

main() {
    local target="${1:-all}"
    case "${target}" in
        libmnl)              step_libmnl ;;
        verify-libmnl)        step_verify_libmnl ;;
        libnftnl)             step_libnftnl ;;
        verify-libnftnl)      step_verify_libnftnl ;;
        nftables)             step_nftables ;;
        verify-nftables)      step_verify_nftables ;;
        libcap-ng)            step_libcap_ng ;;
        verify-libcap-ng)     step_verify_libcap_ng ;;
        audit)                step_audit ;;
        verify-audit)         step_verify_audit ;;
        libargon2)            step_libargon2 ;;
        verify-libargon2)     step_verify_libargon2 ;;
        popt)                 step_popt ;;
        verify-popt)          step_verify_popt ;;
        json-c)               step_json_c ;;
        verify-json-c)        step_verify_json_c ;;
        libaio)               step_libaio ;;
        verify-libaio)        step_verify_libaio ;;
        lvm2)                 step_lvm2 ;;
        verify-lvm2)          step_verify_lvm2 ;;
        cryptsetup)           step_cryptsetup ;;
        verify-cryptsetup)    step_verify_cryptsetup ;;
        bzip2)                step_bzip2 ;;
        verify-bzip2)         step_verify_bzip2 ;;
        pcre2)                step_pcre2 ;;
        verify-pcre2)         step_verify_pcre2 ;;
        libsepol)             step_libsepol ;;
        verify-libsepol)      step_verify_libsepol ;;
        libselinux)           step_libselinux ;;
        verify-libselinux)    step_verify_libselinux ;;
        libsemanage)          step_libsemanage ;;
        verify-libsemanage)   step_verify_libsemanage ;;
        checkpolicy)          step_checkpolicy ;;
        verify-checkpolicy)   step_verify_checkpolicy ;;
        libxcrypt)            step_libxcrypt ;;
        verify-libxcrypt)     step_verify_libxcrypt ;;
        policycoreutils)      step_policycoreutils ;;
        verify-policycoreutils) step_verify_policycoreutils ;;
        all)
            step_libmnl
            step_verify_libmnl
            step_libnftnl
            step_verify_libnftnl
            step_nftables
            step_verify_nftables
            step_libcap_ng
            step_verify_libcap_ng
            step_audit
            step_verify_audit
            step_libargon2
            step_verify_libargon2
            step_popt
            step_verify_popt
            step_json_c
            step_verify_json_c
            step_libaio
            step_verify_libaio
            step_lvm2
            step_verify_lvm2
            step_cryptsetup
            step_verify_cryptsetup
            step_bzip2
            step_verify_bzip2
            step_pcre2
            step_verify_pcre2
            step_libsepol
            step_verify_libsepol
            step_libselinux
            step_verify_libselinux
            step_libsemanage
            step_verify_libsemanage
            step_checkpolicy
            step_verify_checkpolicy
            step_libxcrypt
            step_verify_libxcrypt
            step_policycoreutils
            step_verify_policycoreutils
            log "Fase 3 ('El Escudo') completa: nftables, auditd, LUKS2+Argon2id y SELinux listos en el sysroot."
            ;;
        *)
            die "target desconocido: ${target} (usar: libmnl|verify-libmnl|libnftnl|verify-libnftnl|nftables|verify-nftables|libcap-ng|verify-libcap-ng|audit|verify-audit|libargon2|verify-libargon2|popt|verify-popt|json-c|verify-json-c|libaio|verify-libaio|lvm2|verify-lvm2|cryptsetup|verify-cryptsetup|bzip2|verify-bzip2|pcre2|verify-pcre2|libsepol|verify-libsepol|libselinux|verify-libselinux|libsemanage|verify-libsemanage|checkpolicy|verify-checkpolicy|libxcrypt|verify-libxcrypt|policycoreutils|verify-policycoreutils|all)"
            ;;
    esac
}

main "$@"
