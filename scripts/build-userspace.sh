#!/usr/bin/env bash
# ==============================================================================
# LINSI-OS · Fase 2 — "Espacio de Usuario"
# ------------------------------------------------------------------------------
# A diferencia de un LFS clásico, ACÁ NO SE CHROOTEA: el target
# (x86_64-linsi-linux-gnu) es la misma arquitectura que el host (x86_64), así
# que los binarios que se van generando se pueden probar corriendo directo
# contra su propio ld.so del sysroot, sin necesidad de armar y entrar a un
# chroot. Todo se instala con --prefix=/usr + DESTDIR="${LFS_SYSROOT}", igual
# que las cabeceras del kernel en Fase 0.
#
# Orden (cada paso depende del anterior — no saltear):
#   1. glibc       -> libc para el target, compilada con el GCC pass1 de Fase 0
#   2. libstdcxx   -> soporte C++
#   3. binutils2   -> binutils reconstruido ahora que existe glibc
#   4. gcc2        -> GCC "de verdad", puede enlazar contra libc
#   5. attr/acl/libcap/util-linux -> dependencias de systemd (libmount,
#      libblkid, libuuid, libcap, libacl) — sin esto instalado ANTES, meson
#      simplemente las auto-deshabilita en vez de fallar, así que si no están
#      systemd compila igual pero más pelado de lo que debería.
#   6. systemd     -> se compila con gcc2 y Meson+Ninja, sobre este sysroot
#   7. ncurses     -> terminal (edición de línea/colores/terminfo) para Zsh;
#      necesita un 'tic' nativo (corre en el host) además del cross-compilado
#   8. zsh         -> shell por defecto de LINSI-OS
#   9. uutils      -> reemplazo de coreutils clásico, en Rust, vía Cargo (no
#      autotools/meson: usa --target explícito + RUSTFLAGS para separar el
#      linker del host (build.rs) del linker cruzado (binario final)
#
# Uso:
#   scripts/build-userspace.sh glibc
#   scripts/build-userspace.sh verify
#   scripts/build-userspace.sh all        # corre todos los pasos implementados
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/lfs/scripts/env.sh
source "${SCRIPT_DIR}/env.sh"

log()  { printf '\n\033[1;35m[fase2]\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m[fase2][error]\033[0m %s\n' "$*" >&2; exit 1; }

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

# ------------------------------------------------------------------------------
# 1) glibc — libc para el target, compilada con el GCC pass1 de Fase 0
# ------------------------------------------------------------------------------
step_glibc() {
    require_toolchain
    log "glibc ${GLIBC_VERSION} para ${LFS_TGT}"

    cd "${LFS_SOURCES}"
    fetch "${GNU_MIRROR}/glibc/glibc-${GLIBC_VERSION}.tar.xz" \
          "glibc-${GLIBC_VERSION}.tar.xz"
    log_sha256 "${LFS_SOURCES}/glibc-${GLIBC_VERSION}.tar.xz"

    extract_once "${LFS_SOURCES}/glibc-${GLIBC_VERSION}.tar.xz" \
                 "${LFS_BUILD}/.extracted-glibc"

    local src="${LFS_BUILD}/glibc-${GLIBC_VERSION}"
    local bdir="${src}/build"
    mkdir -p "${bdir}"
    cd "${bdir}"

    # --enable-kernel=4.19 fija el PISO mínimo de kernel que esta glibc va a
    # soportar en runtime — no tiene que ver con la versión real del kernel
    # (7.2) que ya está compilado en Fase 1; es sólo un mínimo conservador y
    # ampliamente compatible. --with-headers sí apunta a las cabeceras reales
    # (las de Linux 7.2) que instalamos en el sysroot en Fase 0.
    ../configure \
        --prefix=/usr \
        --host="${LFS_TGT}" \
        --build="$(../scripts/config.guess)" \
        --enable-kernel=4.19 \
        --with-headers="${LFS_SYSROOT}/usr/include" \
        --disable-nscd \
        libc_cv_slibdir=/usr/lib

    make ${MAKEFLAGS}
    make DESTDIR="${LFS_SYSROOT}" install

    # El script `ldd` que instala glibc trae quemada la ruta de build; sin
    # este fix (estándar en cualquier build tipo LFS) apunta a rutas que no
    # existen en el sysroot final.
    if [[ -f "${LFS_SYSROOT}/usr/bin/ldd" ]]; then
        sed '/RTLDLIST=/s@/usr@@g' -i "${LFS_SYSROOT}/usr/bin/ldd"
    fi

    log "glibc instalada en ${LFS_SYSROOT}/usr"
}

# ------------------------------------------------------------------------------
# Verificación: a diferencia del verify de Fase 0 (que sólo compilaba a
# objeto, sin libc), ahora el GCC pass1 SÍ puede enlazar un ejecutable
# completo — su --with-sysroot ya apuntaba a $LFS desde Fase 0, y ahora que
# glibc existe ahí adentro, encuentra Scrt1.o/crti.o/-lc/crtn.o sin problema.
# ------------------------------------------------------------------------------
step_verify() {
    log "Verificación: link completo contra la glibc recién instalada"
    echo 'int main(void) { return 0; }' > /tmp/linsi-check2.c
    "${LFS_TOOLS}/bin/${LFS_TGT}-gcc" -o /tmp/linsi-check2 /tmp/linsi-check2.c
    "${LFS_TOOLS}/bin/${LFS_TGT}-readelf" -l /tmp/linsi-check2 | grep -i "interpreter"
    rm -f /tmp/linsi-check2 /tmp/linsi-check2.c
    log "OK: ${LFS_TGT}-gcc enlaza ejecutables completos contra la glibc del sysroot."
}

# ------------------------------------------------------------------------------
# 2) libstdc++ — soporte C++, del mismo árbol fuente de GCC que ya usamos para
# el pass1 (Fase 0). Se compila aparte (no como parte de un GCC completo)
# porque el pass1 se configuró con --disable-libstdcxx a propósito: en ese
# momento no existía glibc todavía. Ahora sí existe, así que se puede armar
# esta pieza sola, sin tener que rehacer todo GCC.
# ------------------------------------------------------------------------------
step_libstdcxx() {
    require_toolchain
    log "libstdc++ (de gcc-${GCC_VERSION}) para ${LFS_TGT}"

    local src="${LFS_BUILD}/gcc-${GCC_VERSION}"
    [[ -d "${src}" ]] || die "no está extraído ${src} — corré primero scripts/build-cross-toolchain.sh gcc"

    local bdir="${src}/build-libstdcxx"
    mkdir -p "${bdir}"
    cd "${bdir}"

    # --with-gxx-include-dir tiene que ser la ruta RELATIVA a lo que después
    # antepone DESTDIR (LFS_TOOLS#LFS = "/tools"), NO la ruta absoluta ya
    # resuelta (LFS_TOOLS = "/lfs/tools") — si no, DESTDIR=/lfs la duplica a
    # /lfs/lfs/tools/... y el compilador (que sí busca en /lfs/tools/..., la
    # ruta real) no encuentra los headers. Este es justo el bug del intento
    # anterior.
    ../libstdc++-v3/configure \
        --host="${LFS_TGT}" \
        --build="$(../config.guess)" \
        --prefix=/usr \
        --disable-multilib \
        --disable-nls \
        --disable-libstdcxx-pch \
        --with-gxx-include-dir="${LFS_TOOLS#"${LFS}"}/${LFS_TGT}/include/c++/${GCC_VERSION}"

    make ${MAKEFLAGS}
    make DESTDIR="${LFS_SYSROOT}" install

    # Los .la de libtool traen rutas de build quemadas — no sirven en el
    # sysroot final y libtool moderno no los necesita para nada.
    find "${LFS_SYSROOT}/usr/lib" -maxdepth 1 -name 'libstdc++*.la' -delete 2>/dev/null || true

    log "libstdc++ instalada en ${LFS_SYSROOT}/usr"
}

step_verify_cxx() {
    log "Verificación: compilar y enlazar un .cpp contra la libstdc++ recién instalada"
    cat > /tmp/linsi-checkxx.cpp <<'EOF'
#include <iostream>
int main() { std::cout << "ok"; return 0; }
EOF
    "${LFS_TOOLS}/bin/${LFS_TGT}-g++" -o /tmp/linsi-checkxx /tmp/linsi-checkxx.cpp
    "${LFS_TOOLS}/bin/${LFS_TGT}-readelf" -d /tmp/linsi-checkxx | grep -i "libstdc++"
    rm -f /tmp/linsi-checkxx /tmp/linsi-checkxx.cpp
    log "OK: ${LFS_TGT}-g++ compila y enlaza C++ contra la libstdc++ del sysroot."
}

# ------------------------------------------------------------------------------
# 3) Binutils pass 2 — se reconstruye ahora que existe glibc, targeteando el
# sysroot directamente (--prefix=/usr + DESTDIR) en vez del prefijo temporal
# $LFS_TOOLS del pass1. Estos binarios van a terminar siendo el binutils
# "de verdad" del sistema final (Fase 8), no una herramienta de bootstrap.
# ------------------------------------------------------------------------------
step_binutils2() {
    require_toolchain
    log "Binutils ${BINUTILS_VERSION} (pass 2) para ${LFS_TGT}"

    local src="${LFS_BUILD}/binutils-${BINUTILS_VERSION}"
    [[ -d "${src}" ]] || die "no está extraído ${src} — corré primero scripts/build-cross-toolchain.sh binutils"

    local bdir="${src}/build-pass2"
    mkdir -p "${bdir}"
    cd "${bdir}"

    # Sin --with-system-zlib a propósito: ese flag le pediría a Binutils que
    # use el zlib del sysroot TARGET, que todavía no existe (no lo compilamos
    # en ningún paso de Fase 2 — no está en el plan). Sin el flag, Binutils
    # usa su propia copia de zlib empaquetada en el propio código fuente,
    # justo para este caso de bootstrap sin dependencias externas.
    ../configure \
        --prefix=/usr \
        --build="$(../config.guess)" \
        --host="${LFS_TGT}" \
        --disable-nls \
        --enable-shared \
        --enable-gprofng=no \
        --disable-werror \
        --enable-64-bit-bfd

    make ${MAKEFLAGS}
    make DESTDIR="${LFS_SYSROOT}" install

    # Los .a/.la estáticos de las libs internas de binutils no hacen falta en
    # el sysroot final (sólo los binarios ld/as/etc. y las .so).
    rm -fv "${LFS_SYSROOT}"/usr/lib/lib{bfd,ctf,ctf-nobfd,opcodes,sframe}.{a,la} 2>/dev/null || true

    log "Binutils pass 2 instalado en ${LFS_SYSROOT}/usr"
}

step_verify_binutils2() {
    log "Verificación: binarios de Binutils pass 2 presentes en el sysroot"
    local ok=1
    for b in ld as ar nm objcopy objdump ranlib readelf strip; do
        local p="${LFS_SYSROOT}/usr/bin/${b}"
        if [[ -f "${p}" ]]; then
            file "${p}"
        else
            echo "  [FALTA] ${p}"
            ok=0
        fi
    done
    [[ "${ok}" -eq 1 ]] || die "faltan binarios de binutils pass 2 en el sysroot"
    log "OK: binutils pass 2 completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 4) GCC pass 2 — el compilador "de verdad". Se reconstruye EN EL MISMO LUGAR
# que el pass1 (--prefix=$LFS_TOOLS, sin DESTDIR), no como haría un LFS con
# chroot (--prefix=/usr + --host=$LFS_TGT pensado para correr nativo adentro
# del chroot). Como acá no chrooteamos, mantenerlo en $LFS_TOOLS es lo que
# permite seguir invocándolo directo, sin trucos de ld.so ni privilegios de
# montaje. La diferencia real con el pass1 no es la ubicación — es que se le
# sacan las restricciones que existían sólo porque en Fase 0 no había glibc
# todavía (--without-headers, --disable-shared, --disable-threads, etc.).
# Con esto, $LFS_TOOLS/bin/$LFS_TGT-gcc queda actualizado in-place: reemplaza
# al pass1 como "el" compilador para todo lo que sigue (systemd, uutils, zsh).
# ------------------------------------------------------------------------------
step_gcc2() {
    require_toolchain
    log "GCC ${GCC_VERSION} (pass 2) para ${LFS_TGT} — el paso más pesado de Fase 2"

    local src="${LFS_BUILD}/gcc-${GCC_VERSION}"
    [[ -d "${src}" ]] || die "no está extraído ${src} — corré primero scripts/build-cross-toolchain.sh gcc"

    # Mismos symlinks de gmp/mpfr/mpc que en Fase 0 (deberían seguir estando
    # del pass1, pero por las dudas si algo se limpió).
    [[ -d "${src}/gmp"  ]] || ln -sfv "../gmp-${GMP_VERSION}"   "${src}/gmp"
    [[ -d "${src}/mpfr" ]] || ln -sfv "../mpfr-${MPFR_VERSION}" "${src}/mpfr"
    [[ -d "${src}/mpc"  ]] || ln -sfv "../mpc-${MPC_VERSION}"   "${src}/mpc"

    local bdir="${src}/build-pass2"
    mkdir -p "${bdir}"
    cd "${bdir}"

    # --disable-libsanitizer: libsanitizer (soporte ASan/TSan/UBSan, que
    # --enable-languages=c,c++ arrastra por defecto) espera encontrar
    # cabeceras UAPI de Linux bastante oscuras y específicas de arquitectura
    # (p.ej. linux/scc.h, para hardware serial Z8530 legacy) que nuestras
    # cabeceras "make headers" de Fase 0 no instalan — ese `find ... -delete`
    # sólo se queda con los .h que el propio kernel considera parte de la API
    # pública para espacio de usuario, y varias de las que libsanitizer
    # rastrea quedan afuera a propósito. No usamos ASan/TSan/UBSan en este
    # toolchain, así que en vez de andar parchando cabeceras del kernel para
    # complacer a libsanitizer, se lo desactiva directamente: es la solución
    # estándar en builds LFS-adyacentes que pegan contra este mismo problema.
    ../configure \
        --target="${LFS_TGT}" \
        --prefix="${LFS_TOOLS}" \
        --with-sysroot="${LFS}" \
        --enable-default-pie \
        --enable-default-ssp \
        --disable-nls \
        --disable-multilib \
        --disable-libsanitizer \
        --enable-languages=c,c++

    make ${MAKEFLAGS}
    make install

    log "GCC pass 2 instalado en ${LFS_TOOLS} (reemplaza al pass1)"
}

step_verify_gcc2() {
    log "Verificación: GCC pass 2 compila y enlaza una librería compartida (el pass1 no podía — --disable-shared)"
    local d
    d="$(mktemp -d)"
    cd "${d}"
    echo 'int linsi_add(int a, int b) { return a + b; }' > lib.c
    cat > main.c <<'EOF'
#include <stdio.h>
int linsi_add(int, int);
int main(void) { printf("%d\n", linsi_add(2, 3)); return 0; }
EOF
    "${LFS_TOOLS}/bin/${LFS_TGT}-gcc" -shared -fPIC -o liblinsicheck.so lib.c
    "${LFS_TOOLS}/bin/${LFS_TGT}-gcc" -o maincheck main.c -L. -llinsicheck
    "${LFS_TOOLS}/bin/${LFS_TGT}-readelf" -d maincheck | grep -i "needed\|linsicheck"
    cd - >/dev/null
    rm -rf "${d}"
    log "OK: GCC pass 2 compila y enlaza librerías compartidas."
}

# ------------------------------------------------------------------------------
# Triplet de "build machine" reusado por todos los pasos de acá en adelante
# (attr/acl/util-linux) para --build en su configure. En vez de confiar en que
# CADA tarball chiquito de savannah/kernel.org venga con su propio
# config.guess embebido (glibc/binutils/gcc sí lo garantizan; attr/acl no
# tanto), se reusa el config.guess que YA sabemos que existe y funciona: el
# que trae Binutils desde Fase 0.
# ------------------------------------------------------------------------------
build_triplet() {
    "${LFS_BUILD}/binutils-${BINUTILS_VERSION}/config.guess"
}

# ------------------------------------------------------------------------------
# 5a) attr — atributos extendidos (xattr), lo pide acl para compilar.
# ------------------------------------------------------------------------------
step_attr() {
    require_toolchain
    log "attr ${ATTR_VERSION} para ${LFS_TGT}"

    cd "${LFS_SOURCES}"
    fetch "${SAVANNAH_MIRROR}/attr/attr-${ATTR_VERSION}.tar.xz" \
          "attr-${ATTR_VERSION}.tar.xz"
    extract_once "${LFS_SOURCES}/attr-${ATTR_VERSION}.tar.xz" \
                 "${LFS_BUILD}/.extracted-attr"

    local src="${LFS_BUILD}/attr-${ATTR_VERSION}"
    local bdir="${src}/build"
    mkdir -p "${bdir}"
    cd "${bdir}"

    ../configure \
        --host="${LFS_TGT}" \
        --build="$(build_triplet)" \
        --prefix=/usr \
        --disable-static \
        --sysconfdir=/etc \
        --docdir=/usr/share/doc/attr-${ATTR_VERSION}

    make ${MAKEFLAGS}
    make DESTDIR="${LFS_SYSROOT}" install
    find "${LFS_SYSROOT}/usr/lib" -maxdepth 1 -name 'libattr*.la' -delete 2>/dev/null || true

    log "attr instalado en ${LFS_SYSROOT}/usr"
}

# ------------------------------------------------------------------------------
# 5b) acl — listas de control de acceso POSIX, depende de attr.
# ------------------------------------------------------------------------------
step_acl() {
    require_toolchain
    log "acl ${ACL_VERSION} para ${LFS_TGT}"

    [[ -f "${LFS_SYSROOT}/usr/lib/pkgconfig/libattr.pc" ]] || \
        die "no está attr instalado en el sysroot — corré primero: $0 attr"

    cd "${LFS_SOURCES}"
    fetch "${SAVANNAH_MIRROR}/acl/acl-${ACL_VERSION}.tar.xz" \
          "acl-${ACL_VERSION}.tar.xz"
    extract_once "${LFS_SOURCES}/acl-${ACL_VERSION}.tar.xz" \
                 "${LFS_BUILD}/.extracted-acl"

    local src="${LFS_BUILD}/acl-${ACL_VERSION}"
    local bdir="${src}/build"
    mkdir -p "${bdir}"
    cd "${bdir}"

    ../configure \
        --host="${LFS_TGT}" \
        --build="$(build_triplet)" \
        --prefix=/usr \
        --disable-static \
        --docdir=/usr/share/doc/acl-${ACL_VERSION}

    make ${MAKEFLAGS}
    make DESTDIR="${LFS_SYSROOT}" install
    find "${LFS_SYSROOT}/usr/lib" -maxdepth 1 -name 'libacl*.la' -delete 2>/dev/null || true

    log "acl instalado en ${LFS_SYSROOT}/usr"
}

# ------------------------------------------------------------------------------
# 5c) libcap — capacidades POSIX (lo que systemd usa para no correr todo como
# root puro). A diferencia de todo lo anterior, NO usa autotools: es un
# Makefile a mano, así que en vez de --host/--build hay que pisar CC a mano.
# Ojo con BUILD_CC: libcap compila un generador de tablas (_makenames) que
# tiene que correr EN EL HOST durante el build (no en el target), por eso
# CC apunta al cross-compiler pero BUILD_CC se deja en el gcc del host.
# RAISE_SETFCAP=no evita que el build intente aplicarle una capability al
# binario recién compilado con el setcap del target (no tiene sentido acá,
# sin chroot, y no hace falta para lo que estamos armando).
# ------------------------------------------------------------------------------
step_libcap() {
    require_toolchain
    log "libcap ${LIBCAP_VERSION} para ${LFS_TGT}"

    cd "${LFS_SOURCES}"
    fetch "${LIBCAP_MIRROR}/libcap-${LIBCAP_VERSION}.tar.xz" \
          "libcap-${LIBCAP_VERSION}.tar.xz"
    extract_once "${LFS_SOURCES}/libcap-${LIBCAP_VERSION}.tar.xz" \
                 "${LFS_BUILD}/.extracted-libcap"

    local src="${LFS_BUILD}/libcap-${LIBCAP_VERSION}"
    cd "${src}"

    # No instalamos las .a estáticas (mismo criterio que en libstdc++/binutils2).
    sed -i '/install -m.*STA/d' libcap/Makefile 2>/dev/null || true

    local capmake=(
        make
        CC="${LFS_TGT}-gcc"
        BUILD_CC=cc
        AR="${LFS_TGT}-ar"
        RANLIB="${LFS_TGT}-ranlib"
        prefix=/usr
        lib=lib
        RAISE_SETFCAP=no
        SHARED=yes
    )

    "${capmake[@]}" ${MAKEFLAGS}
    "${capmake[@]}" DESTDIR="${LFS_SYSROOT}" install

    log "libcap instalado en ${LFS_SYSROOT}/usr"
}

# ------------------------------------------------------------------------------
# 5d) util-linux — de acá salen libmount/libblkid/libuuid, que systemd
# necesita para manejar unidades .mount y auto-detectar filesystems. La lista
# de --disable-* de abajo es la misma que usa LFS para su build completo del
# sistema base (probada, no inventada acá): apaga utilidades que dependen de
# PAM/login (chfn/chsh/login/su/runuser/setpriv — todavía no compilamos PAM,
# eso es Fase 4) y de Python (pylibmount), pero deja intactos mount/umount/
# blkid/losetup/lsblk/etc. y sobre todo las tres librerías compartidas que
# nos interesan.
# ------------------------------------------------------------------------------
step_util_linux() {
    require_toolchain
    log "util-linux ${UTIL_LINUX_VERSION} para ${LFS_TGT}"

    cd "${LFS_SOURCES}"
    fetch "${UTIL_LINUX_MIRROR}/util-linux-${UTIL_LINUX_VERSION}.tar.xz" \
          "util-linux-${UTIL_LINUX_VERSION}.tar.xz"
    extract_once "${LFS_SOURCES}/util-linux-${UTIL_LINUX_VERSION}.tar.xz" \
                 "${LFS_BUILD}/.extracted-util-linux"

    local src="${LFS_BUILD}/util-linux-${UTIL_LINUX_VERSION}"
    local bdir="${src}/build"
    mkdir -p "${bdir}"
    cd "${bdir}"

    ../configure \
        --host="${LFS_TGT}" \
        --build="$(build_triplet)" \
        --prefix=/usr \
        --bindir=/usr/bin \
        --libdir=/usr/lib \
        --runstatedir=/run \
        --sbindir=/usr/sbin \
        --disable-chfn-chsh \
        --disable-login \
        --disable-nologin \
        --disable-su \
        --disable-setpriv \
        --disable-runuser \
        --disable-pylibmount \
        --disable-liblastlog2 \
        --disable-static \
        --without-python \
        --without-systemd \
        --without-systemdsystemunitdir \
        --without-tinfo \
        ADJTIME_PATH=/var/lib/hwclock/adjtime \
        --docdir=/usr/share/doc/util-linux-${UTIL_LINUX_VERSION}

    make ${MAKEFLAGS}

    # Varios install-exec-hook de util-linux (wall, mount, ...) hacen
    # `chgrp tty ...` / `chown root:root ...` a mano, sin flag de configure
    # para saltearlos, para dejar los bits setgid/setuid clásicos. Eso
    # necesita ser root — y acá adentro somos el usuario "linsi" sin
    # privilegios a propósito. En vez de romper esa regla, se le pasan al
    # install un chgrp y un chown de mentira (no hacen nada, salen con
    # éxito) sólo para este comando puntual: los binarios igual quedan
    # instalados en el sysroot, sólo que con el dueño/grupo de build en vez
    # de tty/root — la titularidad real se termina de fijar en Fase 8 al
    # armar la ISO/imagen final, no acá en este build de bootstrap.
    local fakebin
    fakebin="$(mktemp -d)"
    printf '#!/bin/sh\nexit 0\n' > "${fakebin}/chgrp"
    printf '#!/bin/sh\nexit 0\n' > "${fakebin}/chown"
    chmod +x "${fakebin}/chgrp" "${fakebin}/chown"

    PATH="${fakebin}:${PATH}" make DESTDIR="${LFS_SYSROOT}" install
    rm -rf "${fakebin}"

    find "${LFS_SYSROOT}/usr/lib" -maxdepth 1 -name '*.la' \
        \( -name 'libmount*' -o -name 'libblkid*' -o -name 'libuuid*' -o -name 'libsmartcols*' -o -name 'libfdisk*' \) \
        -delete 2>/dev/null || true

    log "util-linux instalado en ${LFS_SYSROOT}/usr"
}

step_verify_libs() {
    log "Verificación: librerías de systemd presentes en el sysroot (.pc + .so)"
    # Sólo informativo — NO frena la build acá. acl/blkid/libmount son los
    # únicos que step_systemd fuerza con -Denabled (esos si van a hacer
    # fallar el meson setup fuerte si faltan). libcap y uuid quedan en "auto"
    # en systemd a propósito (ver comentario en step_systemd) porque no está
    # confirmado si systemd 261 expone un toggle para libcap puntualmente —
    # así que acá se los reporta para que los revises a mano, sin cortar el
    # pipeline por una duda que en realidad se resuelve sola en el paso
    # siguiente (si falta algo obligatorio, meson lo va a decir explícito).
    # Ojo con los nombres: util-linux instala sus .pc SIN el prefijo "lib"
    # (mount.pc, no libmount.pc — es justo lo que busca systemd internamente
    # vía dependency('mount')/dependency('blkid')), mientras que attr/acl SÍ
    # lo llevan (libattr.pc, libacl.pc).
    local pc
    for pc in libcap mount blkid uuid libacl; do
        local p="${LFS_SYSROOT}/usr/lib/pkgconfig/${pc}.pc"
        if [[ -f "${p}" ]]; then
            echo "  [OK] ${p}"
        else
            echo "  [no encontrado, puede ser normal] ${p}"
        fi
    done
    log "Verificación de libs terminada (informativa) — el chequeo real pasa en 'systemd' (meson setup)."
}

# ------------------------------------------------------------------------------
# 6) systemd — a diferencia de todo lo anterior, se compila con Meson+Ninja en
# vez de autotools, así que necesita su propio "cross file" (el equivalente
# de --host/--build/--with-sysroot pero en formato .ini que entiende Meson).
#
# Sobre los flags -D: se fuerzan a "enabled" sólo acl/blkid/libmount, que son
# justo lo que acabamos de compilar en los pasos anteriores — si por lo que
# sea no los encuentra, mejor que la build falle fuerte acá a que siga
# calladita sin ellos. Todo lo demás (pam, audit, selinux, apparmor,
# libcryptsetup, dbus, kmod, elfutils, gcrypt/openssl, idn2, pcre2, fido2,
# tpm2, p11kit, qrencode, microhttpd, homed...) se deja en su default "auto":
# como ninguna de esas librerías existe todavía en el sysroot (varias son de
# Fase 3/4/5 — LUKS, SELinux, FIDO2, etc.), Meson las va a auto-desactivar
# solo, sin que haga falta listar a mano una por una veinte flags cuyo nombre
# exacto no está 100% confirmado para systemd 261 puntualmente (encadenar un
# nombre de opción viejo/nuevo mal ahí sí frena la build con un error de
# "unknown option", y no hace falta arriesgarse a eso pudiendo dejar que auto
# resuelva solo). man/html/tests sí se apagan explícito porque no tenemos
# docbook/xsltproc instalados y no queremos correr su test suite acá.
# ------------------------------------------------------------------------------
step_systemd() {
    require_toolchain
    log "systemd ${SYSTEMD_VERSION} para ${LFS_TGT} — Meson+Ninja"

    cd "${LFS_SOURCES}"
    fetch "${SYSTEMD_MIRROR}/v${SYSTEMD_VERSION}.tar.gz" \
          "systemd-${SYSTEMD_VERSION}.tar.gz"
    extract_once "${LFS_SOURCES}/systemd-${SYSTEMD_VERSION}.tar.gz" \
                 "${LFS_BUILD}/.extracted-systemd"

    local src="${LFS_BUILD}/systemd-${SYSTEMD_VERSION}"
    cd "${src}"

    local crossfile="${LFS_BUILD}/meson-cross-linsi.ini"
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
    log "cross file de Meson generado en ${crossfile}"

    local bdir="${src}/build"
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
        -Dtests=false

    ninja -C "${bdir}" ${MAKEFLAGS}
    DESTDIR="${LFS_SYSROOT}" ninja -C "${bdir}" install

    log "systemd instalado en ${LFS_SYSROOT}/usr"
}

step_verify_systemd() {
    log "Verificación: binario systemd presente y linkeado contra libc/libcap/libmount del sysroot"
    local bin="${LFS_SYSROOT}/usr/lib/systemd/systemd"
    [[ -f "${bin}" ]] || die "no está ${bin} — falló la instalación"
    file "${bin}"
    "${LFS_TOOLS}/bin/${LFS_TGT}-readelf" -d "${bin}" | grep -i "needed"
    log "OK: systemd compilado para ${LFS_TGT}."
}

# ------------------------------------------------------------------------------
# 7) ncurses — no estaba en la lista original de dependencias de systemd; se
# agrega acá porque Zsh (el siguiente paso) sin ninguna librería de terminal
# no tiene mucho sentido como shell de verdad (edición de línea, colores,
# terminfo). A diferencia de todo lo anterior, ncurses necesita un 'tic'
# NATIVO (que corra en EL HOST) antes de poder cross-compilar el target: la
# instalación del target usa tic para compilar la base de terminfo, y el tic
# cross-compilado para x86_64-linsi-linux-gnu no se puede ejecutar acá. Se
# arma un build nativo aparte sólo para sacar ese binario — exactamente el
# mismo truco que usa LFS para su propio /tools, y el mismo motivo por el que
# libcap necesitaba BUILD_CC además de CC.
# ------------------------------------------------------------------------------
step_ncurses() {
    require_toolchain
    log "ncurses ${NCURSES_VERSION} para ${LFS_TGT} (+ tic nativo)"

    cd "${LFS_SOURCES}"
    fetch "${GNU_MIRROR}/ncurses/ncurses-${NCURSES_VERSION}.tar.gz" \
          "ncurses-${NCURSES_VERSION}.tar.gz"
    log_sha256 "${LFS_SOURCES}/ncurses-${NCURSES_VERSION}.tar.gz"
    extract_once "${LFS_SOURCES}/ncurses-${NCURSES_VERSION}.tar.gz" \
                 "${LFS_BUILD}/.extracted-ncurses"

    local src="${LFS_BUILD}/ncurses-${NCURSES_VERSION}"

    # --- tic nativo: sin --host, compila y corre en el HOST -------------------
    local ndir="${src}/build-native-tic"
    mkdir -p "${ndir}"
    cd "${ndir}"
    ../configure --prefix="${LFS_TOOLS}" AWK=gawk
    make -C include
    make -C progs tic
    install -v progs/tic "${LFS_TOOLS}/bin"

    # --- ncurses de verdad, cross-compilado para el sysroot -------------------
    # Flags calcados de la build "final" de LFS (con soporte wide-char/UTF-8
    # integrado por default en el ncurses moderno) + --host/--build de cruce.
    # No se pasa --with-term-lib: se deja que el propio configure la
    # autodetecte, mismo criterio que las ~20 dependencias opcionales de
    # systemd que se dejaron en "auto".
    local cdir="${src}/build-cross"
    mkdir -p "${cdir}"
    cd "${cdir}"
    ../configure \
        --prefix=/usr \
        --host="${LFS_TGT}" \
        --build="$(build_triplet)" \
        --mandir=/usr/share/man \
        --with-shared \
        --without-debug \
        --without-normal \
        --with-cxx-shared \
        --without-ada \
        --disable-stripping \
        --enable-pc-files \
        --with-pkg-config-libdir=/usr/lib/pkgconfig \
        AWK=gawk

    make ${MAKEFLAGS}
    make DESTDIR="${LFS_SYSROOT}" install

    # ncurses moderno compila con wide-char integrado a libncursesw*, pero no
    # deja los alias "libncurses.so"/.pc de siempre — sin esto, cualquier
    # ./configure de un paquete posterior que busque -lncurses a secas (en
    # vez de -lncursesw) no la encuentra.
    local lib
    for lib in ncurses form panel menu; do
        ln -sfv "lib${lib}w.so" "${LFS_SYSROOT}/usr/lib/lib${lib}.so"
        ln -sfv "${lib}w.pc" "${LFS_SYSROOT}/usr/lib/pkgconfig/${lib}.pc"
    done
    sed -e 's/^#if.*XOPEN.*$/#if 1/' -i "${LFS_SYSROOT}/usr/include/curses.h"

    log "ncurses instalado en ${LFS_SYSROOT}/usr"
}

step_verify_ncurses() {
    log "Verificación: libncursesw + alias libncurses en el sysroot"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/usr/lib/libncursesw.so" "${LFS_SYSROOT}/usr/lib/libncurses.so" "${LFS_SYSROOT}/usr/lib/pkgconfig/ncursesw.pc"; do
        if [[ -e "${p}" ]]; then
            echo "  [OK] ${p}"
        else
            echo "  [FALTA] ${p}"
            ok=0
        fi
    done
    [[ "${ok}" -eq 1 ]] || die "falta algo de ncurses en el sysroot"
    log "OK: ncurses completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 8) Zsh — shell por defecto de LINSI-OS. Autotools estándar, nada de Meson ni
# de Makefiles a mano. La única detección de ./configure que depende de
# EJECUTAR un binario de prueba (no sólo compilarlo) — y por eso no se puede
# resolver cross-compilando — es zsh_cv_shared_environ; se la pre-semilla en
# "yes", que es el valor correcto para glibc/x86_64 (así resuelve la propia
# receta de cross-compilación de zsh que usa OpenEmbedded/Yocto, probada en
# producción). --disable-dynamic evita módulos cargables en runtime (.so vía
# zmodload) para no tener que lidiar con dlopen contra un sysroot que todavía
# no está "vivo" — quedan compilados adentro del binario principal en cambio.
#
# Bug conocido (no nuestro: reportado en Debian #1075708, Gentoo #919001,
# Arch, OpenWrt — zsh 5.9 contra cualquier GCC/ncurses moderno, cruzado o no):
# el propio ./configure de zsh generado para el release 5.9 tiene un test mal
# escrito para decidir si usa las tablas boolcodes/numcodes/strcodes (y sus
# variantes *names) que YA vienen en el <term.h> de ncurses moderno, en vez
# de declarar las suyas propias (que colisionan). El test hace:
#     char **test = boolcodes; puts(*test);
# — sin cast — y el ncurses moderno expone boolcodes como
# "const char * const[]", así que ese test NUNCA linkea (error de tipos) y
# ./configure concluye (mal) que ncurses no las tiene, dejando que termcap.c
# declare las suyas propias, que sí chocan de verdad contra las de term.h.
# Debian arregla esto agregándole el cast `(char **)` al test — no es un
# problema de nuestro cross-toolchain, hay que parchear el 'configure' ya
# generado que trae el tarball (no hay autoreconf en la imagen, y tampoco
# hace falta: alcanza con el sed de abajo sobre las 6 variables).
# ------------------------------------------------------------------------------
step_zsh() {
    require_toolchain
    log "Zsh ${ZSH_VERSION} para ${LFS_TGT}"

    # Se fuerza una extracción limpia siempre: el intento anterior (antes del
    # parche de abajo) pudo haber dejado Makefiles/objetos a medio generar en
    # este mismo árbol, y no vale la pena arriesgarse a un estado mixto.
    rm -rf "${LFS_BUILD}/zsh-${ZSH_VERSION}" "${LFS_BUILD}/.extracted-zsh"

    cd "${LFS_SOURCES}"
    fetch "${ZSH_MIRROR}/${ZSH_VERSION}/zsh-${ZSH_VERSION}.tar.xz" \
          "zsh-${ZSH_VERSION}.tar.xz"
    log_sha256 "${LFS_SOURCES}/zsh-${ZSH_VERSION}.tar.xz"
    extract_once "${LFS_SOURCES}/zsh-${ZSH_VERSION}.tar.xz" \
                 "${LFS_BUILD}/.extracted-zsh"

    local src="${LFS_BUILD}/zsh-${ZSH_VERSION}"
    cd "${src}"

    grep -q 'test = boolcodes;' configure \
        || die "el texto esperado en 'configure' no está — puede que esta versión de zsh ya tenga el bug arreglado, o que el formato haya cambiado. Revisá a mano antes de seguir."

    sed -i \
        -e 's/test = boolcodes;/test = (char **)boolcodes;/' \
        -e 's/test = numcodes;/test = (char **)numcodes;/' \
        -e 's/test = strcodes;/test = (char **)strcodes;/' \
        -e 's/test = boolnames;/test = (char **)boolnames;/' \
        -e 's/test = numnames;/test = (char **)numnames;/' \
        -e 's/test = strnames;/test = (char **)strnames;/' \
        configure

    ./configure \
        --prefix=/usr \
        --host="${LFS_TGT}" \
        --build="$(build_triplet)" \
        --sysconfdir=/etc/zsh \
        --enable-etcdir=/etc/zsh \
        --enable-cap \
        --enable-multibyte \
        --with-tcsetpgrp \
        --disable-dynamic \
        zsh_cv_shared_environ=yes

    make ${MAKEFLAGS}
    make DESTDIR="${LFS_SYSROOT}" install

    log "Zsh instalado en ${LFS_SYSROOT}/usr"
}

step_verify_zsh() {
    log "Verificación: binario zsh presente y linkeado contra libc/libcap/libncursesw del sysroot"
    local bin="${LFS_SYSROOT}/usr/bin/zsh"
    [[ -f "${bin}" ]] || die "no está ${bin} — falló la instalación"
    file "${bin}"
    "${LFS_TOOLS}/bin/${LFS_TGT}-readelf" -d "${bin}" | grep -i "needed"
    log "OK: Zsh compilado para ${LFS_TGT}."
}

# ------------------------------------------------------------------------------
# 9) uutils (coreutils en Rust) — a diferencia de TODO lo anterior, esto no es
# C/autotools/meson: es Cargo, y cruzarlo tiene un problema propio. Cargo
# compila DOS cosas distintas en la misma corrida: los binarios finales
# (coreutils) para el TARGET, y los build.rs/proc-macros de las dependencias,
# que corren DURANTE el build y por eso tienen que quedar linkeados para el
# HOST (si Cargo los linkea con el cross-gcc por error, esos binarios no
# arrancan y el build entero explota a mitad de camino).
#
# La solución (validada a mano antes de escribir esto, no es un supuesto):
# pasarle a Cargo --target x86_64-unknown-linux-gnu de forma EXPLÍCITA. Aunque
# ese triplet coincide en el nombre con el del host (rustup no conoce el
# nombre "x86_64-linsi-linux-gnu" — no hace falta que lo conozca: la ABI es
# idéntica, sólo cambia el sysroot/linker), el simple hecho de pasar --target
# de forma explícita activa en Cargo la separación real host/target: los
# build.rs se compilan y linkean con el CC nativo de siempre, mientras que
# SÓLO el artefacto final (--target x86_64-unknown-linux-gnu) recibe el
# override de RUSTFLAGS con el linker cruzado. -fuse-ld=bfd fuerza a que el
# propio ${LFS_TGT}-gcc use SU bfd-ld de siempre (el mismo binutils cruzado
# que usa todo lo demás en este script) en vez del lld que rustc intenta
# imponer por default — evita mezclar el sysroot propio con un linker que no
# lo conoce.
# ------------------------------------------------------------------------------
require_rust() {
    command -v cargo >/dev/null 2>&1 || die "no se encontró cargo en el PATH. Reconstruí la imagen (podman compose build) después de agregar rustup al Dockerfile."
    command -v rustc >/dev/null 2>&1 || die "no se encontró rustc en el PATH."
}

step_uutils() {
    require_toolchain
    require_rust
    log "uutils/coreutils ${UUTILS_VERSION} para ${LFS_TGT} — vía Cargo"

    mkdir -p "${CARGO_HOME}"

    cd "${LFS_SOURCES}"
    fetch "${UUTILS_MIRROR}/${UUTILS_VERSION}.tar.gz" \
          "coreutils-${UUTILS_VERSION}.tar.gz"
    extract_once "${LFS_SOURCES}/coreutils-${UUTILS_VERSION}.tar.gz" \
                 "${LFS_BUILD}/.extracted-uutils"

    local src="${LFS_BUILD}/coreutils-${UUTILS_VERSION}"
    cd "${src}"

    RUSTFLAGS="-C linker=${LFS_TGT}-gcc -C link-arg=-fuse-ld=bfd" \
        cargo build --release --locked --target x86_64-unknown-linux-gnu

    local bin="${src}/target/x86_64-unknown-linux-gnu/release/coreutils"
    [[ -f "${bin}" ]] || die "no se generó ${bin} — falló el build de Cargo"

    install -v -m755 -D "${bin}" "${LFS_SYSROOT}/usr/bin/coreutils"

    # uutils arma UN binario multicall tipo BusyBox: cada utilidad se invoca
    # según el nombre con el que se lo llama (argv[0]), así que hacen falta
    # symlinks — uno por utilidad — apuntando todos al mismo binario. Esta es
    # una lista curada de las utilidades clásicas de GNU coreutils (no la
    # lista completa/exhaustiva de uutils, que puede tener más) — alcanza
    # para "erradicar fallos de memoria" reemplazando lo clásico, tal como
    # pide la guía; se puede ampliar más adelante sin volver a compilar nada.
    local utils="arch base32 base64 basename cat cksum comm cp csplit cut date dd df dircolors dirname du echo env expand expr factor false fmt fold groups head hostid id install join link ln logname ls md5sum mkdir mkfifo mknod mktemp mv nice nl nohup nproc numfmt od paste pathchk pinky pr printenv printf pwd readlink realpath rm rmdir runcon seq sha1sum sha224sum sha256sum sha384sum sha512sum shred shuf sleep sort split stat stdbuf stty sum sync tac tail tee test timeout touch tr true truncate tsort tty uname unexpand uniq unlink uptime users wc who whoami yes"
    local u
    for u in ${utils}; do
        ln -sfv coreutils "${LFS_SYSROOT}/usr/bin/${u}"
    done

    log "uutils instalado en ${LFS_SYSROOT}/usr (binario multicall + symlinks)"
}

step_verify_uutils() {
    log "Verificación: binario coreutils (uutils) presente y linkeado contra libc del sysroot"
    local bin="${LFS_SYSROOT}/usr/bin/coreutils"
    [[ -f "${bin}" ]] || die "no está ${bin} — falló la instalación"
    file "${bin}"
    "${LFS_TOOLS}/bin/${LFS_TGT}-readelf" -d "${bin}" | grep -i "needed"
    local sample
    for sample in ls cp mv rm cat; do
        [[ -L "${LFS_SYSROOT}/usr/bin/${sample}" ]] || die "falta el symlink ${sample} -> coreutils"
    done
    log "OK: uutils compilado para ${LFS_TGT}, symlinks de utilidades presentes."
}

main() {
    local target="${1:-all}"
    case "${target}" in
        glibc)             step_glibc ;;
        verify)             step_verify ;;
        libstdcxx)          step_libstdcxx ;;
        verify-cxx)         step_verify_cxx ;;
        binutils2)          step_binutils2 ;;
        verify-binutils2)   step_verify_binutils2 ;;
        gcc2)               step_gcc2 ;;
        verify-gcc2)        step_verify_gcc2 ;;
        attr)               step_attr ;;
        acl)                step_acl ;;
        libcap)              step_libcap ;;
        util-linux)          step_util_linux ;;
        verify-libs)         step_verify_libs ;;
        systemd)              step_systemd ;;
        verify-systemd)       step_verify_systemd ;;
        ncurses)               step_ncurses ;;
        verify-ncurses)        step_verify_ncurses ;;
        zsh)                    step_zsh ;;
        verify-zsh)             step_verify_zsh ;;
        uutils)                 step_uutils ;;
        verify-uutils)          step_verify_uutils ;;
        all)
            step_glibc
            step_verify
            step_libstdcxx
            step_verify_cxx
            step_binutils2
            step_verify_binutils2
            step_gcc2
            step_verify_gcc2
            step_attr
            step_acl
            step_libcap
            step_util_linux
            step_verify_libs
            step_systemd
            step_verify_systemd
            step_ncurses
            step_verify_ncurses
            step_zsh
            step_verify_zsh
            step_uutils
            step_verify_uutils
            log "Fase 2 completa: glibc + libstdc++ + binutils pass2 + GCC pass2 + attr/acl/libcap/util-linux + systemd + ncurses + Zsh + uutils listos en el sysroot."
            ;;
        *)
            die "target desconocido: ${target} (usar: glibc|verify|libstdcxx|verify-cxx|binutils2|verify-binutils2|gcc2|verify-gcc2|attr|acl|libcap|util-linux|verify-libs|systemd|verify-systemd|ncurses|verify-ncurses|zsh|verify-zsh|uutils|verify-uutils|all)"
            ;;
    esac
}

main "$@"
