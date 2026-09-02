#!/usr/bin/env bash
# ==============================================================================
# LINSI-OS · Fase 6 — "Interfaz Moderna" (parte 1: fundación no gráfica)
# ------------------------------------------------------------------------------
# Igual que fases anteriores: no se chrootea, todo se instala con --prefix=/usr
# + DESTDIR="${LFS_SYSROOT}". Requiere Fase 5 completa (necesita OpenSSL,
# zlib, systemd con PAM/logind, PCRE2, apk-tools):
#   scripts/build-infra.sh all
#
# Wayland + Qt6 + KDE Plasma 6 es ENORME -- se parte en varios scripts. Este
# es sólo la PARTE 1: todo lo que hace falta ANTES de tocar Mesa/LLVM (los
# drivers gráficos van en su propio script aparte, cross-compilar LLVM es
# delicado y merece su propia pasada de research) y antes de Qt6/KDE
# Frameworks (que dependen de Mesa para Vulkan/OpenGL). Esta parte deja lista
# la base: D-Bus/polkit, el stack de fuentes/2D (freetype/harfbuzz/
# fontconfig/cairo), Wayland en sí, entrada (libinput/libxkbcommon) y audio
# (PipeWire/WirePlumber).
#
# Dos pasos NO son un paquete con build system propio -- se compilan a mano,
# directo con el cross-gcc, señalado bien claro en cada uno:
#   - duktape: distribución "amalgamada" (un solo .c/.h), sin autotools/meson.
#   - Lua: su Makefile propio arma también el binario interactivo (linkeado
#     contra readline, que no construimos) -- se compila sólo la librería.
# Si algo de estos dos no lo encuentra bien un paso posterior (polkit busca
# duktape, WirePlumber busca Lua), avisame y ajusto el .pc a mano.
#
# CORREGIDO tras un error real de build (2026-08-27): libffi instaló en
# /usr/lib64 en vez de /usr/lib -- mismo síntoma que el bug de OpenSSL en
# Fase 4 (viene de su parentesco con la configury multilib de GCC, no de
# nada específico de este triplet). Ese paso ya tiene el fix + limpieza de
# lib64; de paso se agregó --libdir=/usr/lib explícito a TODOS los pasos
# autotools de este script (no sólo libffi), para no arriesgarse a pisar el
# mismo pozo paquete por paquete.
#
# Orden (cada paso depende del anterior — no saltear):
#   1.  libffi          -> lo necesitan GLib y Wayland
#   2.  expat            -> parser XML, lo necesitan D-Bus y wayland-scanner
#   3.  glib             -> GObject/GLib, lo necesitan PipeWire/WirePlumber/polkit
#   4.  dbus             -> IPC de sesión/sistema, base de polkit/PipeWire/KDE
#   5.  duktape          -> motor JS embebido, ÚNICA dependencia dura del
#                          intérprete de reglas de polkit (no es opcional)
#   6.  libpng            -> lo necesita cairo para el backend PNG
#   7.  polkit            -> autorización de acciones privilegiadas del escritorio
#   8.  freetype           -> rasterizado de fuentes (con --with-harfbuzz=dynamic:
#                          sin dependencia circular, un solo paso alcanza)
#   9.  harfbuzz            -> shaping de texto, sobre freetype
#   10. fontconfig            -> catálogo de fuentes del sistema
#   11. pixman                 -> composición 2D de bajo nivel, la usa cairo
#   12. cairo                   -> gráficos 2D, los usa Qt6/KDE más adelante
#   13. wayland                  -> la librería del protocolo en sí (cliente+servidor)
#   14. wayland-protocols          -> definiciones XML de protocolos extra
#   15. mtdev                       -> filtrado de eventos multitouch, lo usa libinput
#   16. libevdev                     -> acceso a /dev/input/event*, lo usa libinput
#   17. xkeyboard-config              -> datos de layouts de teclado (sin código)
#   18. libinput                       -> entrada de mouse/teclado/touchpad para kwin
#   19. libxkbcommon                    -> mapeo de teclado en tiempo real
#   20. alsa-lib                         -> backend ALSA que usa PipeWire
#   21. lua                               -> motor de scripting embebido de WirePlumber
#   22. pipewire                           -> servidor multimedia (audio+video)
#   23. wireplumber                         -> el "session manager" real de PipeWire
#                                             (pipewire-media-session está descontinuado)
#
# Uso:
#   scripts/build-desktop.sh libffi
#   scripts/build-desktop.sh all        # corre todos los pasos implementados
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/lfs/scripts/env.sh
source "${SCRIPT_DIR}/env.sh"

log()  { printf '\n\033[1;34m[fase6]\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m[fase6][error]\033[0m %s\n' "$*" >&2; exit 1; }

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

# Cross file de Meson -- mismo formato que fases anteriores, PERO con el
# bloque [properties] extra que pide GLib para cross-compilar (ver
# docs/reference/glib/cross-compiling.md real del proyecto): sin esto, Meson
# no puede EJECUTAR los programas de prueba (misma arquitectura o no, un
# cross file siempre desactiva las corridas) y GLib pediría estos valores a
# mano. Como LFS_TGT es glibc x86_64 real, son valores conocidos y seguros
# (no hace falta adivinar): growing_stack=false y have_strlcpy=false son
# correctos para glibc x86_64, have_c99_vsnprintf/snprintf=true porque glibc
# moderna cumple C99 en esas dos, va_val_copy no importa con GCC (tiene
# va_copy real) pero se deja en true, que es el propio default documentado.
# Es inofensivo para el resto de los paquetes que no leen estas properties.
write_meson_crossfile() {
    local crossfile="$1"
    # extra_binaries (2026-08-29, ver comentario largo de spa-json-dump más
    # abajo): texto crudo opcional para sumar entradas al [binaries] de ACÁ
    # -- no al de write_meson_nativefile(). find_program('algo') sin
    # native: true (el caso normal, el que usa wireplumber para
    # spa-json-dump) resuelve contra el binaries del CROSS FILE, no el del
    # native file -- el native file sólo se consulta para find_program(...,
    # native: true) o dependencias explícitamente nativas.
    local extra_binaries="${2:-}"
    cat > "${crossfile}" <<EOF
[binaries]
c = '${LFS_TOOLS}/bin/${LFS_TGT}-gcc'
cpp = '${LFS_TOOLS}/bin/${LFS_TGT}-g++'
ar = '${LFS_TOOLS}/bin/${LFS_TGT}-ar'
strip = '${LFS_TOOLS}/bin/${LFS_TGT}-strip'
ranlib = '${LFS_TOOLS}/bin/${LFS_TGT}-ranlib'
pkg-config = 'pkg-config'
${extra_binaries}

[host_machine]
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'

[properties]
sys_root = '${LFS_SYSROOT}'
# Lista, no un solo string -- CORREGIDO 2026-08-29 tras confirmar que
# wayland-protocols (sin código compilado, sólo XML) instala su .pc en
# "share/pkgconfig", no en "lib/pkgconfig" como los paquetes con librerías
# reales. Con un solo directorio acá, un futuro paso que necesite
# dependency('wayland-protocols') (u otro .pc "arch-independent" similar) no
# lo iba a encontrar nunca vía este cross-file compartido.
pkg_config_libdir = ['${LFS_SYSROOT}/usr/lib/pkgconfig', '${LFS_SYSROOT}/usr/share/pkgconfig']
growing_stack = false
have_strlcpy = false
have_c99_vsnprintf = true
have_c99_snprintf = true
va_val_copy = true
EOF
}

# Prefix del build NATIVO (no cruzado) de wayland-scanner -- ver el
# comentario largo en step_wayland() para el porqué hace falta. CUALQUIER
# paso que necesite invocar wayland-scanner DURANTE su propio build cruzado
# (no sólo linkear contra libwayland-client/-server, sino generar código a
# partir de XMLs de protocolo) necesita el --native-file que arma
# write_meson_nativefile() más abajo -- wayland-protocols ya lo necesita
# (CORREGIDO 2026-08-29: "Dependency wayland-scanner not found" ahí también,
# el export de PKG_CONFIG_PATH del paso de wayland NO alcanza para el
# contexto "native" de Meson en un build cruzado -- hace falta el
# --native-file explícito, no un env var ambiente). Si pipewire, wireplumber
# o un script futuro de Mesa/Qt6 tira el mismo error, el fix es el mismo:
# sumarle su propio --native-file="${nativefile}" apuntando acá.
WAYLAND_SCANNER_NATIVE_PREFIX="${LFS_BUILD}/wayland-scanner-native"

# write_meson_nativefile(): arma el --native-file compartido. El segundo
# argumento (opcional) es texto crudo extra para la sección [binaries] --
# para paquetes que además necesiten un binario nativo puntual apuntado a
# mano (ver build_native_spa_json_dump() más abajo / step_wireplumber()),
# sin tener que duplicar el bloque [properties] de pkg_config_libdir.
write_meson_nativefile() {
    local nativefile="$1"
    local extra_binaries="${2:-}"
    cat > "${nativefile}" <<EOF
[properties]
pkg_config_libdir = '${WAYLAND_SCANNER_NATIVE_PREFIX}/lib/pkgconfig'
EOF
    if [[ -n "${extra_binaries}" ]]; then
        {
            echo ""
            echo "[binaries]"
            echo "${extra_binaries}"
        } >> "${nativefile}"
    fi
}

# spa-json-dump NATIVO (2026-08-29, error real de build en wireplumber): a
# diferencia de wayland-scanner/glib-compile-resources, para este no alcanza
# ni con --native-file de pkgconfig ni con un paquete de apt -- spa-json-dump
# es una herramienta chica y propia de PipeWire (parte de spa/tools/), sin
# paquete de Debian, y el binario CROSS-compilado en ${LFS_SYSROOT}/usr/bin
# (el que instala step_pipewire()) tira, al ejecutarlo sin chroot:
# "/lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.38' not found" -- el
# glibc cross-compilado en Fase 2 es más nuevo que el glibc real de Debian
# bookworm del contenedor (2.36), y un binario pedile símbolos de versión
# que ese loader real no tiene. Ni siquiera es un problema de "falta la
# librería" como con libgio -- es un choque de VERSIÓN del mismo glibc, así
# que "arreglarlo" con LD_LIBRARY_PATH sería aún más frágil.
#
# La buena noticia (confirmado leyendo spa/tools/meson.build y
# spa-json-dump.c reales de PipeWire): esta herramienta sólo necesita headers
# de SPA (spa/include, spa/include-private, todos "static inline", sin nada
# para linkear) más la libc -- ni siquiera hace falta levantar Meson para
# compilarla nativa, alcanza con invocar el compilador nativo del contenedor
# directo sobre spa-json-dump.c. Mucho más simple que el prebuild nativo de
# wayland-scanner. El propio meson.build de PipeWire ya define una variante
# "native: true" de este mismo ejecutable con la misma idea (para uso
# interno del build de PipeWire), pero esa no queda expuesta para que la use
# un proyecto aparte como wireplumber -- por eso hace falta la nuestra.
#
# CORREGIDO (2026-08-29, segundo intento -- el primero con --native-file NO
# alcanzó): el `po/meson.build` real de wireplumber busca la herramienta con
# `find_program('spa-json-dump', required: false)`, SIN `native: true`. Sin
# ese kwarg, Meson resuelve el programa contra el [binaries] del CROSS FILE
# (lo que Meson llama "host machine" -- el target cruzado), NO contra el del
# native file (ese sólo se consulta para find_program(..., native: true)).
# Por eso pisarlo en el nativefile no hacía nada -- wireplumber lo seguía
# encontrando por el fallback a PATH del cross file y volvía a agarrar el
# cross-compilado de siempre. El override tiene que ir en el [binaries] de
# write_meson_crossfile() (parámetro extra_binaries), no en el nativefile.
SPA_JSON_DUMP_NATIVE_DIR="${LFS_BUILD}/spa-json-dump-native"
SPA_JSON_DUMP_NATIVE="${SPA_JSON_DUMP_NATIVE_DIR}/spa-json-dump"

build_native_spa_json_dump() {
    if [[ -x "${SPA_JSON_DUMP_NATIVE}" ]]; then
        log "spa-json-dump nativo ya compilado en ${SPA_JSON_DUMP_NATIVE}"
        return 0
    fi
    log "Compilando spa-json-dump NATIVO (lo necesita wireplumber para generar po/conf.pot)"

    # OJO: esta función hace `cd` para bajar/extraer pipewire -- hay que
    # devolver el cwd del que llama tal cual estaba (CORREGIDO 2026-08-29
    # tras un error real: step_wireplumber() ya había hecho `cd "${src}"`
    # antes de llamar a esto, y al no restaurar el directorio acá, el
    # `meson setup` de wireplumber corría con cwd en ${LFS_SOURCES} en vez
    # de en el propio directorio fuente de wireplumber -- Meson interpreta
    # el cwd como sourcedir implícito cuando no se lo pasás aparte, así que
    # tiraba "Neither source directory ... nor build directory None contain
    # a build file meson.build").
    local caller_pwd
    caller_pwd="$(pwd)"

    cd "${LFS_SOURCES}"
    fetch "${PIPEWIRE_MIRROR}/pipewire-${PIPEWIRE_VERSION}.tar.bz2" \
          "pipewire-${PIPEWIRE_VERSION}.tar.bz2"
    log_sha256 "${LFS_SOURCES}/pipewire-${PIPEWIRE_VERSION}.tar.bz2"
    extract_once "${LFS_SOURCES}/pipewire-${PIPEWIRE_VERSION}.tar.bz2" \
                 "${LFS_BUILD}/.extracted-pipewire"

    local pwsrc="${LFS_BUILD}/pipewire-${PIPEWIRE_VERSION}"
    mkdir -p "${SPA_JSON_DUMP_NATIVE_DIR}"
    cc -O2 \
        -I"${pwsrc}/spa/include" \
        -I"${pwsrc}/spa/include-private" \
        "${pwsrc}/spa/tools/spa-json-dump.c" \
        -o "${SPA_JSON_DUMP_NATIVE}"

    cd "${caller_pwd}"

    [[ -x "${SPA_JSON_DUMP_NATIVE}" ]] || die "no se pudo compilar spa-json-dump nativo"
    log "spa-json-dump nativo listo en ${SPA_JSON_DUMP_NATIVE}"
}

# ------------------------------------------------------------------------------
# 1) libffi — autotools estándar, lo necesitan GLib (invocación de callbacks
# dinámicos) y Wayland.
# ------------------------------------------------------------------------------
step_libffi() {
    require_toolchain
    log "libffi ${LIBFFI_VERSION} para ${LFS_TGT}"

    cd "${LFS_SOURCES}"
    fetch "${LIBFFI_MIRROR}/libffi-${LIBFFI_VERSION}.tar.gz" \
          "libffi-${LIBFFI_VERSION}.tar.gz"
    log_sha256 "${LFS_SOURCES}/libffi-${LIBFFI_VERSION}.tar.gz"
    extract_once "${LFS_SOURCES}/libffi-${LIBFFI_VERSION}.tar.gz" \
                 "${LFS_BUILD}/.extracted-libffi"

    local src="${LFS_BUILD}/libffi-${LIBFFI_VERSION}"
    local bdir="${src}/build"
    mkdir -p "${bdir}"
    cd "${bdir}"

    # CORREGIDO tras un segundo intento real fallido (2026-08-27): --libdir=
    # NO alcanza para libffi. Confirmado leyendo su configure.ac real: define
    # una variable PROPIA ("toolexeclibdir", herencia directa de cuando
    # libffi vivía adentro del árbol de fuentes de GCC) que IGNORA --libdir a
    # propósito y en cambio le pregunta a nuestro propio cross-gcc con
    # "-print-multi-os-directory" -- que devuelve "../lib64" porque el
    # toolchain de Fase 0 quedó con soporte multilib estilo Red Hat/SUSE, no
    # porque haga falta acá. libffi expone exactamente un flag para apagar
    # esa lógica: --disable-multi-os-directory. Con eso, toolexeclibdir cae
    # recién ahí a "${libdir}" de verdad -- por eso --libdir=/usr/lib solo
    # (sin este flag) no alcanzaba. Limpieza del intento anterior por las dudas.
    rm -rf "${LFS_SYSROOT}/usr/lib64"

    ../configure \
        --host="${LFS_TGT}" \
        --build="$(build_triplet)" \
        --prefix=/usr \
        --libdir=/usr/lib \
        --disable-multi-os-directory \
        --disable-static \
        --disable-docs

    make ${MAKEFLAGS}
    make DESTDIR="${LFS_SYSROOT}" install
    find "${LFS_SYSROOT}/usr/lib" -maxdepth 1 -name 'libffi*.la' -delete 2>/dev/null || true

    log "libffi instalado en ${LFS_SYSROOT}/usr"
}

step_verify_libffi() {
    log "Verificación: libffi.so + ffi.h en el sysroot"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/usr/lib/libffi.so" "${LFS_SYSROOT}/usr/include/ffi.h"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    [[ "${ok}" -eq 1 ]] || die "falta algo de libffi en el sysroot"
    log "OK: libffi completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 2) expat — autotools estándar, parser XML sin dependencias. Lo usan D-Bus
# (parsea su config XML) y wayland-scanner (parsea los protocolos).
# ------------------------------------------------------------------------------
step_expat() {
    require_toolchain
    log "expat ${EXPAT_VERSION} para ${LFS_TGT}"

    cd "${LFS_SOURCES}"
    fetch "${EXPAT_MIRROR}/expat-${EXPAT_VERSION}.tar.xz" \
          "expat-${EXPAT_VERSION}.tar.xz"
    log_sha256 "${LFS_SOURCES}/expat-${EXPAT_VERSION}.tar.xz"
    extract_once "${LFS_SOURCES}/expat-${EXPAT_VERSION}.tar.xz" \
                 "${LFS_BUILD}/.extracted-expat"

    local src="${LFS_BUILD}/expat-${EXPAT_VERSION}"
    local bdir="${src}/build"
    mkdir -p "${bdir}"
    cd "${bdir}"

    ../configure \
        --host="${LFS_TGT}" \
        --build="$(build_triplet)" \
        --prefix=/usr \
        --libdir=/usr/lib \
        --disable-static

    make ${MAKEFLAGS}
    make DESTDIR="${LFS_SYSROOT}" install
    find "${LFS_SYSROOT}/usr/lib" -maxdepth 1 -name 'libexpat*.la' -delete 2>/dev/null || true

    log "expat instalado en ${LFS_SYSROOT}/usr"
}

step_verify_expat() {
    log "Verificación: libexpat.so + expat.h en el sysroot"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/usr/lib/libexpat.so" "${LFS_SYSROOT}/usr/include/expat.h"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    [[ "${ok}" -eq 1 ]] || die "falta algo de expat en el sysroot"
    log "OK: expat completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 3) glib — Meson. introspection/tests/documentation/man-pages apagados: no
# tenemos gobject-introspection ni herramientas de docs, y no hacen falta acá.
# ------------------------------------------------------------------------------
step_glib() {
    require_toolchain
    log "glib ${GLIB_VERSION} para ${LFS_TGT} — Meson+Ninja"

    cd "${LFS_SOURCES}"
    fetch "${GLIB_MIRROR}/glib-${GLIB_VERSION}.tar.xz" \
          "glib-${GLIB_VERSION}.tar.xz"
    log_sha256 "${LFS_SOURCES}/glib-${GLIB_VERSION}.tar.xz"
    extract_once "${LFS_SOURCES}/glib-${GLIB_VERSION}.tar.xz" \
                 "${LFS_BUILD}/.extracted-glib"

    local src="${LFS_BUILD}/glib-${GLIB_VERSION}"
    cd "${src}"

    local crossfile="${LFS_BUILD}/meson-cross-linsi.ini"
    write_meson_crossfile "${crossfile}"

    local bdir="${src}/build"
    rm -rf "${bdir}"

    meson setup "${bdir}" \
        --cross-file="${crossfile}" \
        --prefix=/usr \
        --libdir=lib \
        --sysconfdir=/etc \
        --localstatedir=/var \
        -Dintrospection=disabled \
        -Dtests=false \
        -Ddocumentation=false \
        -Dman-pages=disabled

    ninja -C "${bdir}" ${MAKEFLAGS}
    DESTDIR="${LFS_SYSROOT}" ninja -C "${bdir}" install

    log "glib instalado en ${LFS_SYSROOT}/usr"
}

step_verify_glib() {
    log "Verificación: libglib-2.0.so + libgobject-2.0.so en el sysroot"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/usr/lib/libglib-2.0.so" "${LFS_SYSROOT}/usr/lib/libgobject-2.0.so"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    [[ "${ok}" -eq 1 ]] || die "falta algo de glib en el sysroot"
    log "OK: glib completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 4) dbus — Meson (la serie 1.16 ya no tiene autotools). x11_autolaunch
# apagado: este proyecto no tiene X11 en ningún lado. systemd=enabled porque
# ya tenemos systemd completo -- deja que dbus arranque vía socket-activation
# en vez de su propio init script.
# ------------------------------------------------------------------------------
step_dbus() {
    require_toolchain
    log "D-Bus ${DBUS_VERSION} para ${LFS_TGT} — Meson+Ninja"

    cd "${LFS_SOURCES}"
    fetch "${DBUS_MIRROR}/dbus-${DBUS_VERSION}.tar.xz" \
          "dbus-${DBUS_VERSION}.tar.xz"
    log_sha256 "${LFS_SOURCES}/dbus-${DBUS_VERSION}.tar.xz"
    extract_once "${LFS_SOURCES}/dbus-${DBUS_VERSION}.tar.xz" \
                 "${LFS_BUILD}/.extracted-dbus"

    local src="${LFS_BUILD}/dbus-${DBUS_VERSION}"
    cd "${src}"

    local crossfile="${LFS_BUILD}/meson-cross-linsi.ini"
    write_meson_crossfile "${crossfile}"

    local bdir="${src}/build"
    rm -rf "${bdir}"

    # CORREGIDO tras un build real fallido (2026-08-27): "-Dsystemdsystemunitdir="
    # NO existe como opción de meson_options.txt de dbus -- meson tiró
    # "ERROR: Unknown option: systemdsystemunitdir" de una. Confirmado
    # comparando contra dos recetas reales de dbus 1.16.2 con meson (Alpine
    # APKBUILD y Void Linux template): ninguna de las dos pasa esa opción --
    # Alpine ni siquiera toca -Dsystemd, Void pasa "-Dsystemd=disabled" (usan
    # elogind, no systemd) pero confirma que "-Dsystemd" SÍ es una opción
    # real (feature bool), sin ningún override de directorio.
    # Con -Dsystemd=enabled, dbus resuelve solo la ruta de las unidades vía
    # pkg-config contra el "systemd.pc" real (variable "systemdsystemunitdir"
    # que el propio systemd de Fase 4 ya instala) -- por eso agregamos acá el
    # mismo prefijo PKG_CONFIG_LIBDIR/PKG_CONFIG_SYSROOT_DIR que ya usa
    # step_polkit(), para que ese pkg-config apunte al sysroot y no al host.
    PKG_CONFIG_LIBDIR="${LFS_SYSROOT}/usr/lib/pkgconfig:${LFS_SYSROOT}/usr/share/pkgconfig" \
    PKG_CONFIG_SYSROOT_DIR="${LFS_SYSROOT}" \
    meson setup "${bdir}" \
        --cross-file="${crossfile}" \
        --prefix=/usr \
        --libdir=lib \
        --sysconfdir=/etc \
        --localstatedir=/var \
        -Dsystem_pid_file=/run/dbus/pid \
        -Dsystem_socket=/run/dbus/system_bus_socket \
        -Dsystemd=enabled \
        -Dx11_autolaunch=disabled

    # NOTA: no se agregan acá flags de tests/docs (-Dtests=/-Ddoxygen_docs=/
    # etc.) porque el research no pudo confirmar esos nombres exactos contra
    # el meson_options.txt real de esta versión -- un nombre de opción
    # inventado hace que "meson setup" falle DE UNA con "ERROR: Unknown
    # option(s)", así que se prefiere dejarlos en su default (son
    # 'feature'/auto en la gran mayoría de estos proyectos: si falta la
    # herramienta que necesitan -doxygen, etc.- se autodesactivan solos, sin
    # romper el build) antes que arriesgar un nombre mal escrito.

    ninja -C "${bdir}" ${MAKEFLAGS}
    DESTDIR="${LFS_SYSROOT}" ninja -C "${bdir}" install

    log "D-Bus instalado en ${LFS_SYSROOT}/usr"
}

step_verify_dbus() {
    log "Verificación: dbus-daemon + libdbus-1.so en el sysroot"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/usr/bin/dbus-daemon" "${LFS_SYSROOT}/usr/lib/libdbus-1.so"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    [[ "${ok}" -eq 1 ]] || die "falta algo de D-Bus en el sysroot"
    log "OK: D-Bus completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 5) duktape — distribución "amalgamada" (un solo src/duktape.c + duktape.h,
# sin autotools/meson/CMake propio, todo el proyecto está diseñado alrededor
# de esa idea). Se compila directo con el cross-gcc en vez de confiar en un
# Makefile.sharedlibrary que no se pudo verificar con certeza desde el
# sandbox de research. Es la ÚNICA dependencia dura de polkit para su motor
# de reglas en JavaScript (polkit.meson.build cae a esto si no encuentra
# duktape por pkg-config -- por eso se genera también un duktape.pc a mano).
# ------------------------------------------------------------------------------
step_duktape() {
    require_toolchain
    log "duktape ${DUKTAPE_VERSION} para ${LFS_TGT} (dependencia de polkit)"

    cd "${LFS_SOURCES}"
    fetch "${DUKTAPE_MIRROR}/duktape-${DUKTAPE_VERSION}.tar.xz" \
          "duktape-${DUKTAPE_VERSION}.tar.xz"
    log_sha256 "${LFS_SOURCES}/duktape-${DUKTAPE_VERSION}.tar.xz"
    extract_once "${LFS_SOURCES}/duktape-${DUKTAPE_VERSION}.tar.xz" \
                 "${LFS_BUILD}/.extracted-duktape"

    local src="${LFS_BUILD}/duktape-${DUKTAPE_VERSION}"
    cd "${src}"

    local major="${DUKTAPE_VERSION%%.*}"
    local sysroot_usr="${LFS_SYSROOT}/usr"
    mkdir -p "${sysroot_usr}/lib" "${sysroot_usr}/include" "${sysroot_usr}/lib/pkgconfig"

    "${LFS_TGT}-gcc" -fPIC -shared -O2 -Wl,-soname,"libduktape.so.${major}" \
        -o "${sysroot_usr}/lib/libduktape.so.${DUKTAPE_VERSION}" \
        src/duktape.c -lm
    ln -sf "libduktape.so.${DUKTAPE_VERSION}" "${sysroot_usr}/lib/libduktape.so.${major}"
    ln -sf "libduktape.so.${major}" "${sysroot_usr}/lib/libduktape.so"
    cp -f src/duktape.h src/duk_config.h "${sysroot_usr}/include/"

    cat > "${sysroot_usr}/lib/pkgconfig/duktape.pc" <<EOF
prefix=/usr
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: duktape
Description: Duktape embeddable Javascript engine
Version: ${DUKTAPE_VERSION}
Libs: -L\${libdir} -lduktape -lm
Cflags: -I\${includedir}
EOF

    log "duktape instalado en ${sysroot_usr} (compilado a mano, sin Makefile propio)"
}

step_verify_duktape() {
    log "Verificación: libduktape.so + duktape.h + duktape.pc en el sysroot"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/usr/lib/libduktape.so" "${LFS_SYSROOT}/usr/include/duktape.h" "${LFS_SYSROOT}/usr/lib/pkgconfig/duktape.pc"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    [[ "${ok}" -eq 1 ]] || die "falta algo de duktape en el sysroot"
    log "OK: duktape completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 6) libpng — autotools, lo necesita cairo para el backend PNG (íconos,
# capturas, etc.). Depende de zlib (Fase 4).
# ------------------------------------------------------------------------------
step_libpng() {
    require_toolchain
    log "libpng ${LIBPNG_VERSION} para ${LFS_TGT}"

    cd "${LFS_SOURCES}"
    fetch "${LIBPNG_MIRROR}/libpng-${LIBPNG_VERSION}.tar.xz" \
          "libpng-${LIBPNG_VERSION}.tar.xz"
    log_sha256 "${LFS_SOURCES}/libpng-${LIBPNG_VERSION}.tar.xz"
    extract_once "${LFS_SOURCES}/libpng-${LIBPNG_VERSION}.tar.xz" \
                 "${LFS_BUILD}/.extracted-libpng"

    local src="${LFS_BUILD}/libpng-${LIBPNG_VERSION}"
    local bdir="${src}/build"
    mkdir -p "${bdir}"
    cd "${bdir}"

    ../configure \
        --host="${LFS_TGT}" \
        --build="$(build_triplet)" \
        --prefix=/usr \
        --libdir=/usr/lib \
        --disable-static

    make ${MAKEFLAGS}
    make DESTDIR="${LFS_SYSROOT}" install
    find "${LFS_SYSROOT}/usr/lib" -maxdepth 1 -name 'libpng*.la' -delete 2>/dev/null || true

    log "libpng instalado en ${LFS_SYSROOT}/usr"
}

step_verify_libpng() {
    log "Verificación: libpng.so + png.h en el sysroot"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/usr/include/png.h"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    if ! find "${LFS_SYSROOT}/usr/lib" -maxdepth 1 -name 'libpng*.so*' 2>/dev/null | grep -q .; then
        echo "  [FALTA] libpng*.so en ${LFS_SYSROOT}/usr/lib"; ok=0
    else
        echo "  [OK] libpng*.so presente"
    fi
    [[ "${ok}" -eq 1 ]] || die "falta algo de libpng en el sysroot"
    log "OK: libpng completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 7) polkit — Meson. authfw=pam porque ya tenemos Linux-PAM (Fase 4), no
# ConsoleKit clásico. session_tracking=logind porque tenemos systemd-logind
# completo (Fase 2/4), no elogind. Necesita: dbus, glib, duktape, expat, pam.
# La creación del usuario/grupo "polkitd" del sistema (useradd) queda para
# Fase 8 (poblado de /etc/passwd del sistema instalado), no acá.
# ------------------------------------------------------------------------------
step_polkit() {
    require_toolchain
    log "polkit ${POLKIT_VERSION} para ${LFS_TGT} — Meson+Ninja"

    cd "${LFS_SOURCES}"
    fetch "${POLKIT_MIRROR}/${POLKIT_VERSION}.tar.gz" \
          "polkit-${POLKIT_VERSION}.tar.gz"
    log_sha256 "${LFS_SOURCES}/polkit-${POLKIT_VERSION}.tar.gz"
    extract_once "${LFS_SOURCES}/polkit-${POLKIT_VERSION}.tar.gz" \
                 "${LFS_BUILD}/.extracted-polkit"

    local src="${LFS_BUILD}/polkit-${POLKIT_VERSION}"
    cd "${src}"

    local crossfile="${LFS_BUILD}/meson-cross-linsi.ini"
    write_meson_crossfile "${crossfile}"

    local bdir="${src}/build"
    rm -rf "${bdir}"

    PKG_CONFIG_LIBDIR="${LFS_SYSROOT}/usr/lib/pkgconfig:${LFS_SYSROOT}/usr/share/pkgconfig" \
    PKG_CONFIG_SYSROOT_DIR="${LFS_SYSROOT}" \
    meson setup "${bdir}" \
        --cross-file="${crossfile}" \
        --prefix=/usr \
        --libdir=lib \
        --sysconfdir=/etc \
        --localstatedir=/var \
        -Dauthfw=pam \
        -Dsession_tracking=logind \
        -Dexamples=false \
        -Dtests=false \
        -Dintrospection=false \
        -Dgtk_doc=false \
        -Dman=false

    ninja -C "${bdir}" ${MAKEFLAGS}
    DESTDIR="${LFS_SYSROOT}" ninja -C "${bdir}" install

    log "polkit instalado en ${LFS_SYSROOT}/usr"
}

step_verify_polkit() {
    log "Verificación: polkitd + libpolkit-gobject-1.so en el sysroot"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/usr/lib/polkit-1/polkitd" "${LFS_SYSROOT}/usr/lib/libpolkit-gobject-1.so"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    [[ "${ok}" -eq 1 ]] || die "falta algo de polkit en el sysroot"
    "${LFS_TOOLS}/bin/${LFS_TGT}-readelf" -d "${LFS_SYSROOT}/usr/lib/polkit-1/polkitd" | grep -i "needed"
    log "OK: polkit completo en el sysroot (revisá arriba que aparezca libduktape.so)."
}

# ------------------------------------------------------------------------------
# 8) freetype — autotools. --with-harfbuzz=dynamic (agregado en 2.14.0) evita
# el viejo baile de "compilar freetype dos veces": con dynamic, freetype hace
# dlopen() de harfbuzz en tiempo de EJECUCIÓN y ni siquiera necesita sus
# headers en el configure -- un solo paso alcanza, y harfbuzz se compila
# DESPUÉS, tranquilo, sobre este freetype ya instalado.
# ------------------------------------------------------------------------------
step_freetype() {
    require_toolchain
    log "FreeType ${FREETYPE_VERSION} para ${LFS_TGT}"

    cd "${LFS_SOURCES}"
    fetch "${FREETYPE_MIRROR}/freetype-${FREETYPE_VERSION}.tar.xz" \
          "freetype-${FREETYPE_VERSION}.tar.xz"
    log_sha256 "${LFS_SOURCES}/freetype-${FREETYPE_VERSION}.tar.xz"
    extract_once "${LFS_SOURCES}/freetype-${FREETYPE_VERSION}.tar.xz" \
                 "${LFS_BUILD}/.extracted-freetype"

    local src="${LFS_BUILD}/freetype-${FREETYPE_VERSION}"
    local bdir="${src}/build"
    mkdir -p "${bdir}"
    cd "${bdir}"

    ../configure \
        --host="${LFS_TGT}" \
        --build="$(build_triplet)" \
        --prefix=/usr \
        --libdir=/usr/lib \
        --disable-static \
        --with-harfbuzz=dynamic \
        --enable-freetype-config

    make ${MAKEFLAGS}
    make DESTDIR="${LFS_SYSROOT}" install
    find "${LFS_SYSROOT}/usr/lib" -maxdepth 1 -name 'libfreetype*.la' -delete 2>/dev/null || true

    log "FreeType instalado en ${LFS_SYSROOT}/usr"
}

step_verify_freetype() {
    log "Verificación: libfreetype.so + freetype2/ft2build.h en el sysroot"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/usr/lib/libfreetype.so" "${LFS_SYSROOT}/usr/include/freetype2/ft2build.h"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    [[ "${ok}" -eq 1 ]] || die "falta algo de FreeType en el sysroot"
    log "OK: FreeType completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 9) harfbuzz — Meson, sobre freetype.
# ------------------------------------------------------------------------------
step_harfbuzz() {
    require_toolchain
    log "HarfBuzz ${HARFBUZZ_VERSION} para ${LFS_TGT} — Meson+Ninja"

    cd "${LFS_SOURCES}"
    fetch "${HARFBUZZ_MIRROR}/harfbuzz-${HARFBUZZ_VERSION}.tar.xz" \
          "harfbuzz-${HARFBUZZ_VERSION}.tar.xz"
    log_sha256 "${LFS_SOURCES}/harfbuzz-${HARFBUZZ_VERSION}.tar.xz"
    extract_once "${LFS_SOURCES}/harfbuzz-${HARFBUZZ_VERSION}.tar.xz" \
                 "${LFS_BUILD}/.extracted-harfbuzz"

    local src="${LFS_BUILD}/harfbuzz-${HARFBUZZ_VERSION}"
    cd "${src}"

    local crossfile="${LFS_BUILD}/meson-cross-linsi.ini"
    write_meson_crossfile "${crossfile}"

    local bdir="${src}/build"
    rm -rf "${bdir}"

    meson setup "${bdir}" \
        --cross-file="${crossfile}" \
        --prefix=/usr \
        --libdir=lib \
        -Dfreetype=enabled \
        -Dintrospection=disabled \
        -Ddocs=disabled \
        -Dtests=disabled

    ninja -C "${bdir}" ${MAKEFLAGS}
    DESTDIR="${LFS_SYSROOT}" ninja -C "${bdir}" install

    log "HarfBuzz instalado en ${LFS_SYSROOT}/usr"
}

step_verify_harfbuzz() {
    log "Verificación: libharfbuzz.so en el sysroot, linkeado contra libfreetype"
    local p="${LFS_SYSROOT}/usr/lib/libharfbuzz.so"
    [[ -e "${p}" ]] || die "no está ${p}"
    echo "  [OK] ${p}"
    "${LFS_TOOLS}/bin/${LFS_TGT}-readelf" -d "${p}" | grep -i "needed"
    log "OK: HarfBuzz completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 10) fontconfig — Meson, catálogo de fuentes del sistema. Sobre freetype +
# expat.
#
# CORREGIDO tras un build real fallido (2026-08-27): con autotools (./configure
# --host=...), fontconfig muere duro en "checking for va_copy() function...
# configure: error: cannot run test program while cross compiling" -- un
# chequeo interno (vía la infraestructura de gettext/NLS que arrastra
# AC_RUN_IFELSE sin acción por defecto para cross-compiling) que necesita
# EJECUTAR un binario de prueba, algo que autoconf rehúsa a intentar apenas ve
# --host distinto de --build, aunque en nuestro caso el binario cross-compilado
# sí podría correr perfecto (misma arquitectura x86_64). Reescribir el cache de
# autoconf a mano para saltear ese chequeo puntual es fragil (el nombre exacto
# de la variable de cache no está confirmado). En cambio, research confirmó que
# fontconfig expone un build system Meson real y activamente usado para cross-
# compilación -- vcpkg (que sí cross-compila fontconfig para Windows/ARM64/iOS)
# lo arma exclusivamente con Meson, nunca autotools, con estas mismas opciones
# (vcpkg_configure_meson: -Diconv=, -Dnls=, -Dtools=, -Ddoc=disabled,
# -Dcache-build=disabled, -Dxml-backend=expat, -Dtests=disabled) -- confirmado
# además contra el meson_options.txt real del proyecto. Meson evita el problema
# de raíz: no ejecuta binarios de prueba a ciegas en un cross build.
# nls=disabled porque no queremos arrastrar gettext/traducciones para un SO
# mínimo. cache-build=disabled porque ese paso corre fc-cache (ya cross-
# compilado) durante el propio "ninja install", algo que no vale la pena forzar
# a través del exe_wrapper de meson por una sola corrida de cacheo no esencial
# -- se puede correr fc-cache a mano más adelante, ya en el sistema instalado.
# ------------------------------------------------------------------------------
step_fontconfig() {
    require_toolchain
    log "fontconfig ${FONTCONFIG_VERSION} para ${LFS_TGT} — Meson+Ninja"

    cd "${LFS_SOURCES}"
    fetch "${FONTCONFIG_MIRROR}/fontconfig-${FONTCONFIG_VERSION}.tar.xz" \
          "fontconfig-${FONTCONFIG_VERSION}.tar.xz"
    log_sha256 "${LFS_SOURCES}/fontconfig-${FONTCONFIG_VERSION}.tar.xz"
    extract_once "${LFS_SOURCES}/fontconfig-${FONTCONFIG_VERSION}.tar.xz" \
                 "${LFS_BUILD}/.extracted-fontconfig"

    local src="${LFS_BUILD}/fontconfig-${FONTCONFIG_VERSION}"
    cd "${src}"

    local crossfile="${LFS_BUILD}/meson-cross-linsi.ini"
    write_meson_crossfile "${crossfile}"

    local bdir="${src}/build"
    rm -rf "${bdir}"

    PKG_CONFIG_LIBDIR="${LFS_SYSROOT}/usr/lib/pkgconfig:${LFS_SYSROOT}/usr/share/pkgconfig" \
    PKG_CONFIG_SYSROOT_DIR="${LFS_SYSROOT}" \
    meson setup "${bdir}" \
        --cross-file="${crossfile}" \
        --prefix=/usr \
        --libdir=lib \
        --sysconfdir=/etc \
        --localstatedir=/var \
        -Diconv=disabled \
        -Dnls=disabled \
        -Dtools=enabled \
        -Dtests=disabled \
        -Ddoc=disabled \
        -Dcache-build=disabled \
        -Dxml-backend=expat

    ninja -C "${bdir}" ${MAKEFLAGS}
    DESTDIR="${LFS_SYSROOT}" ninja -C "${bdir}" install

    log "fontconfig instalado en ${LFS_SYSROOT}/usr"
}

step_verify_fontconfig() {
    log "Verificación: libfontconfig.so + fontconfig.h en el sysroot"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/usr/lib/libfontconfig.so" "${LFS_SYSROOT}/usr/include/fontconfig/fontconfig.h"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    [[ "${ok}" -eq 1 ]] || die "falta algo de fontconfig en el sysroot"
    log "OK: fontconfig completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 11) pixman — Meson, composición 2D de bajo nivel que usa cairo.
# ------------------------------------------------------------------------------
step_pixman() {
    require_toolchain
    log "pixman ${PIXMAN_VERSION} para ${LFS_TGT} — Meson+Ninja"

    cd "${LFS_SOURCES}"
    fetch "${PIXMAN_MIRROR}/pixman-${PIXMAN_VERSION}.tar.gz" \
          "pixman-${PIXMAN_VERSION}.tar.gz"
    log_sha256 "${LFS_SOURCES}/pixman-${PIXMAN_VERSION}.tar.gz"
    extract_once "${LFS_SOURCES}/pixman-${PIXMAN_VERSION}.tar.gz" \
                 "${LFS_BUILD}/.extracted-pixman"

    local src="${LFS_BUILD}/pixman-${PIXMAN_VERSION}"
    cd "${src}"

    local crossfile="${LFS_BUILD}/meson-cross-linsi.ini"
    write_meson_crossfile "${crossfile}"

    local bdir="${src}/build"
    rm -rf "${bdir}"

    meson setup "${bdir}" \
        --cross-file="${crossfile}" \
        --prefix=/usr \
        --libdir=lib \
        --buildtype=release \
        -Dtests=disabled \
        -Ddemos=disabled

    ninja -C "${bdir}" ${MAKEFLAGS}
    DESTDIR="${LFS_SYSROOT}" ninja -C "${bdir}" install

    log "pixman instalado en ${LFS_SYSROOT}/usr"
}

step_verify_pixman() {
    log "Verificación: libpixman-1.so en el sysroot"
    local p="${LFS_SYSROOT}/usr/lib/libpixman-1.so"
    [[ -e "${p}" ]] || die "no está ${p}"
    echo "  [OK] ${p}"
    log "OK: pixman completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 12) cairo — Meson. xlib/xcb apagados (sin X11 en este proyecto). No existe
# un backend "cairo-wayland" -- los clientes Wayland le pasan a cairo
# superficies de memoria compartida normales (image backend, siempre
# incluido), por eso sólo hace falta habilitar png/freetype/fontconfig acá.
# ------------------------------------------------------------------------------
step_cairo() {
    require_toolchain
    log "cairo ${CAIRO_VERSION} para ${LFS_TGT} — Meson+Ninja"

    cd "${LFS_SOURCES}"
    fetch "${CAIRO_MIRROR}/cairo-${CAIRO_VERSION}.tar.xz" \
          "cairo-${CAIRO_VERSION}.tar.xz"
    log_sha256 "${LFS_SOURCES}/cairo-${CAIRO_VERSION}.tar.xz"
    extract_once "${LFS_SOURCES}/cairo-${CAIRO_VERSION}.tar.xz" \
                 "${LFS_BUILD}/.extracted-cairo"

    local src="${LFS_BUILD}/cairo-${CAIRO_VERSION}"
    cd "${src}"

    local crossfile="${LFS_BUILD}/meson-cross-linsi.ini"
    write_meson_crossfile "${crossfile}"

    local bdir="${src}/build"
    rm -rf "${bdir}"

    meson setup "${bdir}" \
        --cross-file="${crossfile}" \
        --prefix=/usr \
        --libdir=lib \
        -Dxlib=disabled \
        -Dxcb=disabled \
        -Dpng=enabled \
        -Dfreetype=enabled \
        -Dfontconfig=enabled \
        -Dzlib=enabled \
        -Dtests=disabled \
        -Dgtk_doc=false

    ninja -C "${bdir}" ${MAKEFLAGS}
    DESTDIR="${LFS_SYSROOT}" ninja -C "${bdir}" install

    log "cairo instalado en ${LFS_SYSROOT}/usr"
}

step_verify_cairo() {
    log "Verificación: libcairo.so en el sysroot, linkeado contra libpixman/libfreetype/libfontconfig/libpng"
    local p="${LFS_SYSROOT}/usr/lib/libcairo.so"
    [[ -e "${p}" ]] || die "no está ${p}"
    echo "  [OK] ${p}"
    "${LFS_TOOLS}/bin/${LFS_TGT}-readelf" -d "${p}" | grep -i "needed"
    log "OK: cairo completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 13) wayland — Meson. "libraries" es UN flag que compila cliente+servidor+
# cursor juntos (no existen flags separados para cada librería, a diferencia
# de lo que asumía la primera pasada de research de este proyecto).
# dtd_validation=false evita necesitar libxml2 sólo para validar el propio
# XML de protocolos en tiempo de build.
# ------------------------------------------------------------------------------
step_wayland() {
    require_toolchain
    log "wayland ${WAYLAND_VERSION} para ${LFS_TGT} — Meson+Ninja"

    cd "${LFS_SOURCES}"
    fetch "${WAYLAND_MIRROR}/wayland-${WAYLAND_VERSION}.tar.xz" \
          "wayland-${WAYLAND_VERSION}.tar.xz"
    log_sha256 "${LFS_SOURCES}/wayland-${WAYLAND_VERSION}.tar.xz"
    extract_once "${LFS_SOURCES}/wayland-${WAYLAND_VERSION}.tar.xz" \
                 "${LFS_BUILD}/.extracted-wayland"

    local src="${LFS_BUILD}/wayland-${WAYLAND_VERSION}"
    cd "${src}"

    # CORREGIDO tras un build real fallido (2026-08-29): "Dependency
    # 'wayland-scanner' not found (tried pkg-config and cmake)". Leyendo el
    # src/meson.build real de wayland: apenas Meson detecta que es un cross
    # build (meson.is_cross_build()), SIEMPRE exige un "wayland-scanner"
    # NATIVO externo -- vía dependency('wayland-scanner', native: true) -- para
    # generar el código de los protocolos DURANTE este mismo build, sin
    # importar que -Dscanner=true esté compilando también un wayland-scanner
    # cross para el target en la misma pasada (ese binario cross, para Meson,
    # no cuenta como "ejecutable ya mismo en la máquina de build", aunque acá
    # en la práctica sí lo sea por ser la misma arquitectura x86_64).
    # No hay forma de saltear esto sin parchear wayland-scanner.c: hace falta
    # un wayland-scanner NATIVO de verdad, instalado ANTES del build cruzado.
    # Se resuelve en dos pasos:
    #   1) build nativo aparte (sin --cross-file, con el gcc del propio
    #      contenedor) de SOLO wayland-scanner, a un prefix descartable.
    #   2) el build cruzado real, con un --native-file que le dice a Meson
    #      dónde buscar el .pc de ese scanner nativo (pkg_config_libdir
    #      scopeado sólo al contexto "native", sin tocar el cross-file ni
    #      pisar PKG_CONFIG_LIBDIR/SYSROOT_DIR que usan otros pasos).
    # El scanner nativo necesita expat de verdad instalado en el contenedor
    # (libexpat1-dev, agregado al Dockerfile en este mismo fix) -- si el
    # "meson setup" del paso 1 tira "Dependency 'expat' not found", hace
    # falta `podman compose build` de nuevo para levantar esa capa.

    local native_bdir="${src}/build-native"
    local native_prefix="${WAYLAND_SCANNER_NATIVE_PREFIX}"
    rm -rf "${native_bdir}"

    meson setup "${native_bdir}" \
        --prefix="${native_prefix}" \
        --libdir=lib \
        -Dscanner=true \
        -Dlibraries=false \
        -Ddocumentation=false \
        -Ddtd_validation=false \
        -Dtests=false

    ninja -C "${native_bdir}" ${MAKEFLAGS}
    ninja -C "${native_bdir}" install

    [[ -x "${native_prefix}/bin/wayland-scanner" ]] \
        || die "el wayland-scanner NATIVO no quedó en ${native_prefix}/bin -- revisá el log de ninja arriba"
    log "wayland-scanner nativo listo: ${native_prefix}/bin/wayland-scanner"

    local crossfile="${LFS_BUILD}/meson-cross-linsi.ini"
    write_meson_crossfile "${crossfile}"

    local nativefile="${LFS_BUILD}/meson-native-linsi.ini"
    write_meson_nativefile "${nativefile}"

    local bdir="${src}/build"
    rm -rf "${bdir}"

    meson setup "${bdir}" \
        --cross-file="${crossfile}" \
        --native-file="${nativefile}" \
        --prefix=/usr \
        --libdir=lib \
        -Dlibraries=true \
        -Dscanner=true \
        -Ddocumentation=false \
        -Ddtd_validation=false \
        -Dtests=false

    ninja -C "${bdir}" ${MAKEFLAGS}
    DESTDIR="${LFS_SYSROOT}" ninja -C "${bdir}" install

    log "wayland instalado en ${LFS_SYSROOT}/usr (wayland-scanner queda en el PATH vía \${LFS_SYSROOT}/usr/bin, ver env.sh)"
}

step_verify_wayland() {
    log "Verificación: libwayland-{client,server}.so + wayland-scanner en el sysroot"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/usr/lib/libwayland-client.so" "${LFS_SYSROOT}/usr/lib/libwayland-server.so" "${LFS_SYSROOT}/usr/bin/wayland-scanner"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    [[ "${ok}" -eq 1 ]] || die "falta algo de wayland en el sysroot"
    command -v wayland-scanner >/dev/null 2>&1 || die "wayland-scanner no está en el PATH -- revisá el PATH en env.sh"
    log "OK: wayland completo en el sysroot, wayland-scanner encontrado en el PATH ($(command -v wayland-scanner))."
}

# ------------------------------------------------------------------------------
# 14) wayland-protocols — Meson, prácticamente sin flags: son sólo XML +
# un .pc, no hay código para compilar.
# ------------------------------------------------------------------------------
step_wayland_protocols() {
    require_toolchain
    log "wayland-protocols ${WAYLAND_PROTOCOLS_VERSION} para ${LFS_TGT} — Meson+Ninja"

    cd "${LFS_SOURCES}"
    fetch "${WAYLAND_PROTOCOLS_MIRROR}/wayland-protocols-${WAYLAND_PROTOCOLS_VERSION}.tar.xz" \
          "wayland-protocols-${WAYLAND_PROTOCOLS_VERSION}.tar.xz"
    log_sha256 "${LFS_SOURCES}/wayland-protocols-${WAYLAND_PROTOCOLS_VERSION}.tar.xz"
    extract_once "${LFS_SOURCES}/wayland-protocols-${WAYLAND_PROTOCOLS_VERSION}.tar.xz" \
                 "${LFS_BUILD}/.extracted-wayland-protocols"

    local src="${LFS_BUILD}/wayland-protocols-${WAYLAND_PROTOCOLS_VERSION}"
    cd "${src}"

    # CORREGIDO tras un build real fallido (2026-08-29): mismo problema que
    # wayland -- wayland-protocols también necesita un wayland-scanner NATIVO
    # (dependency('wayland-scanner', native: true) con fallback a un
    # subproject que acá no existe) para generar código a partir de sus XMLs
    # de protocolo. La mitigación anterior (exportar PKG_CONFIG_PATH desde
    # step_wayland() para el resto del proceso) NO alcanzó: Meson, en un
    # build cruzado, no confía en el ambiente para resolver dependencias del
    # contexto "native", necesita el --native-file explícito. Se reusa el
    # mismo scanner nativo que ya construyó step_wayland() (no hace falta
    # repetir ese build).
    [[ -x "${WAYLAND_SCANNER_NATIVE_PREFIX}/bin/wayland-scanner" ]] \
        || die "no está el wayland-scanner NATIVO en ${WAYLAND_SCANNER_NATIVE_PREFIX}/bin -- corré primero: scripts/build-desktop.sh wayland"

    local crossfile="${LFS_BUILD}/meson-cross-linsi.ini"
    write_meson_crossfile "${crossfile}"

    local nativefile="${LFS_BUILD}/meson-native-linsi.ini"
    write_meson_nativefile "${nativefile}"

    local bdir="${src}/build"
    rm -rf "${bdir}"

    # Sin -Dtests= a propósito: el research no confirmó que esa opción
    # exista para este paquete puntual (a diferencia de wayland, que sí la
    # tiene) -- wayland-protocols es "prácticamente sin flags" según lo
    # verificado, así que se deja así de mínimo para no arriesgar un
    # "Unknown option" que frene meson de una.
    meson setup "${bdir}" \
        --cross-file="${crossfile}" \
        --native-file="${nativefile}" \
        --prefix=/usr \
        --libdir=lib

    ninja -C "${bdir}" ${MAKEFLAGS}
    DESTDIR="${LFS_SYSROOT}" ninja -C "${bdir}" install

    log "wayland-protocols instalado en ${LFS_SYSROOT}/usr"
}

step_verify_wayland_protocols() {
    log "Verificación: wayland-protocols.pc en el sysroot"
    # CORREGIDO tras un build real fallido (2026-08-29): wayland-protocols no
    # tiene código compilado (sólo XML + un .pc), así que Meson lo instala en
    # "${datadir}/pkgconfig" (/usr/share/pkgconfig), NO en "${libdir}/pkgconfig"
    # como los paquetes con librerías reales -- confirmado directo en el log
    # ("Installing .../wayland-protocols.pc to /lfs/usr/share/pkgconfig"). El
    # build en sí había salido bien; este `die` era un falso positivo por
    # buscar en la ruta equivocada.
    local p="${LFS_SYSROOT}/usr/share/pkgconfig/wayland-protocols.pc"
    [[ -e "${p}" ]] || die "no está ${p}"
    echo "  [OK] ${p}"
    log "OK: wayland-protocols completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 15) mtdev — autotools, filtrado de eventos multitouch para libinput.
# ------------------------------------------------------------------------------
step_mtdev() {
    require_toolchain
    log "mtdev ${MTDEV_VERSION} para ${LFS_TGT}"

    cd "${LFS_SOURCES}"
    fetch "${MTDEV_MIRROR}/mtdev-${MTDEV_VERSION}.tar.bz2" \
          "mtdev-${MTDEV_VERSION}.tar.bz2"
    log_sha256 "${LFS_SOURCES}/mtdev-${MTDEV_VERSION}.tar.bz2"
    extract_once "${LFS_SOURCES}/mtdev-${MTDEV_VERSION}.tar.bz2" \
                 "${LFS_BUILD}/.extracted-mtdev"

    local src="${LFS_BUILD}/mtdev-${MTDEV_VERSION}"
    local bdir="${src}/build"
    mkdir -p "${bdir}"
    cd "${bdir}"

    ../configure \
        --host="${LFS_TGT}" \
        --build="$(build_triplet)" \
        --prefix=/usr \
        --libdir=/usr/lib \
        --disable-static

    make ${MAKEFLAGS}
    make DESTDIR="${LFS_SYSROOT}" install
    find "${LFS_SYSROOT}/usr/lib" -maxdepth 1 -name 'libmtdev*.la' -delete 2>/dev/null || true

    log "mtdev instalado en ${LFS_SYSROOT}/usr"
}

step_verify_mtdev() {
    log "Verificación: libmtdev.so en el sysroot"
    local p="${LFS_SYSROOT}/usr/lib/libmtdev.so"
    [[ -e "${p}" ]] || die "no está ${p}"
    echo "  [OK] ${p}"
    log "OK: mtdev completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 16) libevdev — autotools (build system no verificado con certeza total
# desde el sandbox de research -- si esto da error de "configure: not found"
# en la build real, avisame y lo cambio a Meson).
# ------------------------------------------------------------------------------
step_libevdev() {
    require_toolchain
    log "libevdev ${LIBEVDEV_VERSION} para ${LFS_TGT}"

    cd "${LFS_SOURCES}"
    fetch "${LIBEVDEV_MIRROR}/libevdev-${LIBEVDEV_VERSION}.tar.xz" \
          "libevdev-${LIBEVDEV_VERSION}.tar.xz"
    log_sha256 "${LFS_SOURCES}/libevdev-${LIBEVDEV_VERSION}.tar.xz"
    extract_once "${LFS_SOURCES}/libevdev-${LIBEVDEV_VERSION}.tar.xz" \
                 "${LFS_BUILD}/.extracted-libevdev"

    local src="${LFS_BUILD}/libevdev-${LIBEVDEV_VERSION}"
    local bdir="${src}/build"
    mkdir -p "${bdir}"
    cd "${bdir}"

    ../configure \
        --host="${LFS_TGT}" \
        --build="$(build_triplet)" \
        --prefix=/usr \
        --libdir=/usr/lib \
        --disable-static \
        --disable-documentation

    make ${MAKEFLAGS}
    make DESTDIR="${LFS_SYSROOT}" install
    find "${LFS_SYSROOT}/usr/lib" -maxdepth 1 -name 'libevdev*.la' -delete 2>/dev/null || true

    log "libevdev instalado en ${LFS_SYSROOT}/usr"
}

step_verify_libevdev() {
    log "Verificación: libevdev.so en el sysroot"
    local p="${LFS_SYSROOT}/usr/lib/libevdev.so"
    [[ -e "${p}" ]] || die "no está ${p}"
    echo "  [OK] ${p}"
    log "OK: libevdev completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 17) xkeyboard-config — Meson, SIN código: sólo datos de layouts de teclado
# + traducciones (usa el gettext que ya instalamos en el Dockerfile para
# policycoreutils, Fase 3). Con prefix=/usr, los datos caen solos en
# /usr/share/X11/xkb -- el mismo lugar donde libxkbcommon los busca por
# default (no hace falta pasarle la ruta a mano si se instala ANTES).
# ------------------------------------------------------------------------------
step_xkeyboard_config() {
    require_toolchain
    log "xkeyboard-config ${XKEYBOARD_CONFIG_VERSION} para ${LFS_TGT} — Meson+Ninja"

    cd "${LFS_SOURCES}"
    fetch "${XKEYBOARD_CONFIG_MIRROR}/xkeyboard-config-${XKEYBOARD_CONFIG_VERSION}.tar.xz" \
          "xkeyboard-config-${XKEYBOARD_CONFIG_VERSION}.tar.xz"
    log_sha256 "${LFS_SOURCES}/xkeyboard-config-${XKEYBOARD_CONFIG_VERSION}.tar.xz"
    extract_once "${LFS_SOURCES}/xkeyboard-config-${XKEYBOARD_CONFIG_VERSION}.tar.xz" \
                 "${LFS_BUILD}/.extracted-xkeyboard-config"

    local src="${LFS_BUILD}/xkeyboard-config-${XKEYBOARD_CONFIG_VERSION}"
    cd "${src}"

    local crossfile="${LFS_BUILD}/meson-cross-linsi.ini"
    write_meson_crossfile "${crossfile}"

    local bdir="${src}/build"
    rm -rf "${bdir}"

    meson setup "${bdir}" \
        --cross-file="${crossfile}" \
        --prefix=/usr

    ninja -C "${bdir}" ${MAKEFLAGS}
    DESTDIR="${LFS_SYSROOT}" ninja -C "${bdir}" install

    log "xkeyboard-config instalado en ${LFS_SYSROOT}/usr/share"
}

step_verify_xkeyboard_config() {
    log "Verificación: datos de xkeyboard-config en el sysroot"
    # OJO: /usr/share/X11/xkb se instala como symlink ABSOLUTO a
    # /usr/share/xkeyboard-config-2 (confirmado en el log real de install:
    # "Installing symlink pointing to /usr/share/xkeyboard-config-2 to
    # ${LFS_SYSROOT}/usr/share/X11/xkb"). Como este proyecto nunca chrootea a
    # /lfs, ese symlink absoluto se resuelve contra la raíz REAL del
    # contenedor (no contra ${LFS_SYSROOT}) y un chequeo por
    # .../X11/xkb/rules/base.xml da falso negativo aunque el build haya
    # salido bien. Se verifica en cambio el archivo real, sin pasar por el
    # symlink -- el mismo tipo de falso positivo que ya se corrigió en
    # step_verify_wayland_protocols() (.pc en share/pkgconfig en vez de
    # lib/pkgconfig). El symlink va a funcionar bien una vez que /lfs sea la
    # raíz de arranque real (Fase 8) o si algún día se chrootea para probar.
    local p="${LFS_SYSROOT}/usr/share/xkeyboard-config-2/rules/base.xml"
    [[ -e "${p}" ]] || die "no está ${p}"
    echo "  [OK] ${p}"
    log "OK: xkeyboard-config completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 18) libinput — Meson. libwacom (tabletas gráficas) y debug-gui (necesita
# GTK) apagados a propósito, no los construimos. udev-dir apuntado al lugar
# real de systemd-udev (ya en el sysroot desde Fase 2).
# ------------------------------------------------------------------------------
step_libinput() {
    require_toolchain
    log "libinput ${LIBINPUT_VERSION} para ${LFS_TGT} — Meson+Ninja"

    cd "${LFS_SOURCES}"
    fetch "${LIBINPUT_MIRROR}/libinput-${LIBINPUT_VERSION}.tar.gz" \
          "libinput-${LIBINPUT_VERSION}.tar.gz"
    log_sha256 "${LFS_SOURCES}/libinput-${LIBINPUT_VERSION}.tar.gz"
    extract_once "${LFS_SOURCES}/libinput-${LIBINPUT_VERSION}.tar.gz" \
                 "${LFS_BUILD}/.extracted-libinput"

    local src="${LFS_BUILD}/libinput-${LIBINPUT_VERSION}"
    cd "${src}"

    local crossfile="${LFS_BUILD}/meson-cross-linsi.ini"
    write_meson_crossfile "${crossfile}"

    local bdir="${src}/build"
    rm -rf "${bdir}"

    meson setup "${bdir}" \
        --cross-file="${crossfile}" \
        --prefix=/usr \
        --libdir=lib \
        -Dudev-dir=/usr/lib/udev \
        -Ddocumentation=false \
        -Dtests=false \
        -Dlibwacom=false \
        -Ddebug-gui=false

    ninja -C "${bdir}" ${MAKEFLAGS}
    DESTDIR="${LFS_SYSROOT}" ninja -C "${bdir}" install

    log "libinput instalado en ${LFS_SYSROOT}/usr"
}

step_verify_libinput() {
    log "Verificación: libinput.so en el sysroot, linkeado contra libmtdev/libevdev/libudev"
    local p="${LFS_SYSROOT}/usr/lib/libinput.so"
    [[ -e "${p}" ]] || die "no está ${p}"
    echo "  [OK] ${p}"
    "${LFS_TOOLS}/bin/${LFS_TGT}-readelf" -d "${p}" | grep -i "needed"
    log "OK: libinput completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 19) libxkbcommon — Meson. enable-wayland requiere enable-tools=true (según
# su propio meson.options: el código de compose/cursor de Wayland vive
# adentro de "tools"). x11 apagado, sin X11 en este proyecto.
# ------------------------------------------------------------------------------
step_libxkbcommon() {
    require_toolchain
    log "libxkbcommon ${LIBXKBCOMMON_VERSION} para ${LFS_TGT} — Meson+Ninja"

    cd "${LFS_SOURCES}"
    fetch "${LIBXKBCOMMON_MIRROR}/xkbcommon-${LIBXKBCOMMON_VERSION}.tar.gz" \
          "libxkbcommon-${LIBXKBCOMMON_VERSION}.tar.gz"
    log_sha256 "${LFS_SOURCES}/libxkbcommon-${LIBXKBCOMMON_VERSION}.tar.gz"
    extract_once "${LFS_SOURCES}/libxkbcommon-${LIBXKBCOMMON_VERSION}.tar.gz" \
                 "${LFS_BUILD}/.extracted-libxkbcommon"

    # El tag real en GitHub es "xkbcommon-${LIBXKBCOMMON_VERSION}" (no
    # "v${LIBXKBCOMMON_VERSION}"), así que el archive de GitHub NO pisa el
    # "v" (sólo lo hace con tags que arrancan con "v") -- el directorio que
    # arma el .tar.gz es "libxkbcommon-xkbcommon-${LIBXKBCOMMON_VERSION}",
    # no "libxkbcommon-${LIBXKBCOMMON_VERSION}" como en el resto de los
    # paquetes de este proyecto que sí taggean con "v".
    local src="${LFS_BUILD}/libxkbcommon-xkbcommon-${LIBXKBCOMMON_VERSION}"
    cd "${src}"

    # CORREGIDO tras un build real fallido (2026-08-29): mismo problema que
    # wayland/wayland-protocols -- con -Denable-wayland=true, libxkbcommon
    # compila las herramientas "xkbcli ... wayland" (meson.build:757), que
    # necesitan un wayland-scanner NATIVO además de wayland-client/
    # wayland-protocols del sysroot cruzado (esos dos sí se encontraban
    # bien). Se reusa el mismo scanner nativo que ya construyó step_wayland()
    # -- no hace falta repetir ese build.
    [[ -x "${WAYLAND_SCANNER_NATIVE_PREFIX}/bin/wayland-scanner" ]] \
        || die "no está el wayland-scanner NATIVO en ${WAYLAND_SCANNER_NATIVE_PREFIX}/bin -- corré primero: scripts/build-desktop.sh wayland"

    local crossfile="${LFS_BUILD}/meson-cross-linsi.ini"
    write_meson_crossfile "${crossfile}"

    local nativefile="${LFS_BUILD}/meson-native-linsi.ini"
    write_meson_nativefile "${nativefile}"

    local bdir="${src}/build"
    rm -rf "${bdir}"

    # enable-xkbregistry=false a propósito (2026-08-29): esa API opcional
    # (para listar layouts disponibles, la usan cosas como el selector de
    # teclado de un DE) pide libxml2 real en tiempo de build
    # ("Dependency libxml-2.0 not found", meson.build:532) -- y libxml2 no
    # está compilado en ningún lado del proyecto todavía. El núcleo de
    # libxkbcommon (compilar keymaps, protocolo xkb de Wayland -- lo que
    # necesitan wayland/libinput/pipewire/wireplumber en esta Fase 6 Parte 1)
    # NO depende de xkbregistry. Se pospone a Fase 6 Parte 3 (Qt6/KDE), que
    # es quien realmente va a necesitar listar layouts (kxkbcommon/kwin) --
    # ahí hace falta agregar un step_libxml2() cross-compilado y recién
    # entonces volver a poner esto en true. Ver docs/PENDIENTES.md.
    meson setup "${bdir}" \
        --cross-file="${crossfile}" \
        --native-file="${nativefile}" \
        --prefix=/usr \
        --libdir=lib \
        -Denable-wayland=true \
        -Denable-tools=true \
        -Denable-docs=false \
        -Denable-x11=false \
        -Denable-xkbregistry=false

    ninja -C "${bdir}" ${MAKEFLAGS}
    DESTDIR="${LFS_SYSROOT}" ninja -C "${bdir}" install

    log "libxkbcommon instalado en ${LFS_SYSROOT}/usr"
}

step_verify_libxkbcommon() {
    log "Verificación: libxkbcommon.so en el sysroot"
    local p="${LFS_SYSROOT}/usr/lib/libxkbcommon.so"
    [[ -e "${p}" ]] || die "no está ${p}"
    echo "  [OK] ${p}"
    log "OK: libxkbcommon completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 20) alsa-lib — autotools, backend de audio de bajo nivel que usa PipeWire.
# ------------------------------------------------------------------------------
step_alsa_lib() {
    require_toolchain
    log "alsa-lib ${ALSA_LIB_VERSION} para ${LFS_TGT}"

    cd "${LFS_SOURCES}"
    fetch "${ALSA_LIB_MIRROR}/alsa-lib-${ALSA_LIB_VERSION}.tar.bz2" \
          "alsa-lib-${ALSA_LIB_VERSION}.tar.bz2"
    log_sha256 "${LFS_SOURCES}/alsa-lib-${ALSA_LIB_VERSION}.tar.bz2"
    extract_once "${LFS_SOURCES}/alsa-lib-${ALSA_LIB_VERSION}.tar.bz2" \
                 "${LFS_BUILD}/.extracted-alsa-lib"

    local src="${LFS_BUILD}/alsa-lib-${ALSA_LIB_VERSION}"
    local bdir="${src}/build"
    mkdir -p "${bdir}"
    cd "${bdir}"

    ../configure \
        --host="${LFS_TGT}" \
        --build="$(build_triplet)" \
        --prefix=/usr \
        --libdir=/usr/lib \
        --disable-static

    make ${MAKEFLAGS}
    make DESTDIR="${LFS_SYSROOT}" install
    find "${LFS_SYSROOT}/usr/lib" -maxdepth 1 -name 'libasound*.la' -delete 2>/dev/null || true

    log "alsa-lib instalado en ${LFS_SYSROOT}/usr"
}

step_verify_alsa_lib() {
    log "Verificación: libasound.so en el sysroot"
    local p="${LFS_SYSROOT}/usr/lib/libasound.so"
    [[ -e "${p}" ]] || die "no está ${p}"
    echo "  [OK] ${p}"
    log "OK: alsa-lib completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 21) Lua — el Makefile propio de Lua arma TAMBIÉN los binarios lua/luac,
# linkeados contra readline/history (que no construimos en este proyecto, y
# no hacen falta: WirePlumber sólo embebe la LIBRERÍA). Por eso se compilan
# los .o a mano con el cross-gcc, se excluyen lua.o/luac.o (tienen main())
# del archivo estático, y se arma también un .so + lua5.4.pc a mano --
# WirePlumber busca "lua5.4" por pkg-config con system-lua-version=5.4.
# ------------------------------------------------------------------------------
step_lua() {
    require_toolchain
    log "Lua ${LUA_VERSION} para ${LFS_TGT} (sólo librería, sin lua/luac)"

    cd "${LFS_SOURCES}"
    fetch "${LUA_MIRROR}/lua-${LUA_VERSION}.tar.gz" \
          "lua-${LUA_VERSION}.tar.gz"
    log_sha256 "${LFS_SOURCES}/lua-${LUA_VERSION}.tar.gz"
    extract_once "${LFS_SOURCES}/lua-${LUA_VERSION}.tar.gz" \
                 "${LFS_BUILD}/.extracted-lua"

    local src="${LFS_BUILD}/lua-${LUA_VERSION}"
    cd "${src}/src"

    local minor="${LUA_VERSION%.*}"   # "5.4" de "5.4.8"

    "${LFS_TGT}-gcc" -fPIC -O2 -DLUA_USE_LINUX -c ./*.c -I.
    rm -f lua.o luac.o   # tienen main() -- son de los binarios, no de la librería
    "${LFS_TGT}-ar" rcu liblua.a ./*.o
    "${LFS_TGT}-ranlib" liblua.a
    "${LFS_TGT}-gcc" -shared -fPIC -Wl,-soname,"liblua-${minor}.so" \
        -o "liblua-${minor}.so" ./*.o -lm -ldl

    local sysroot_usr="${LFS_SYSROOT}/usr"
    mkdir -p "${sysroot_usr}/lib" "${sysroot_usr}/include" "${sysroot_usr}/lib/pkgconfig"
    cp -f liblua.a "${sysroot_usr}/lib/"
    cp -f "liblua-${minor}.so" "${sysroot_usr}/lib/"
    ln -sf "liblua-${minor}.so" "${sysroot_usr}/lib/liblua.so"
    cp -f lua.h luaconf.h lualib.h lauxlib.h lua.hpp "${sysroot_usr}/include/"

    cat > "${sysroot_usr}/lib/pkgconfig/lua${minor}.pc" <<EOF
prefix=/usr
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: lua${minor}
Description: Lua language engine
Version: ${LUA_VERSION}
Libs: -L\${libdir} -llua
Cflags: -I\${includedir}
EOF

    log "Lua instalado en ${sysroot_usr} (lua${minor}.pc para que WirePlumber lo encuentre)"
}

step_verify_lua() {
    log "Verificación: liblua.so + lua5.4.pc en el sysroot"
    local minor="${LUA_VERSION%.*}"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/usr/lib/liblua.so" "${LFS_SYSROOT}/usr/lib/pkgconfig/lua${minor}.pc" "${LFS_SYSROOT}/usr/include/lua.h"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    [[ "${ok}" -eq 1 ]] || die "falta algo de Lua en el sysroot"
    log "OK: Lua completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 22) pipewire — Meson. bluez5 apagado (no construimos bluez en este
# proyecto). libpulse apagado explícito: no tenemos la librería real de
# PulseAudio, y no hace falta -- el servidor de compatibilidad
# "pipewire-pulse" (el que hace que las apps vean un PulseAudio de verdad) se
# compila siempre, sin flag propio. session-managers=[] a propósito: el
# session manager es WirePlumber, un paso aparte, no el viejo
# pipewire-media-session (descontinuado).
# ------------------------------------------------------------------------------
step_pipewire() {
    require_toolchain
    log "PipeWire ${PIPEWIRE_VERSION} para ${LFS_TGT} — Meson+Ninja"

    cd "${LFS_SOURCES}"
    fetch "${PIPEWIRE_MIRROR}/pipewire-${PIPEWIRE_VERSION}.tar.bz2" \
          "pipewire-${PIPEWIRE_VERSION}.tar.bz2"
    log_sha256 "${LFS_SOURCES}/pipewire-${PIPEWIRE_VERSION}.tar.bz2"
    extract_once "${LFS_SOURCES}/pipewire-${PIPEWIRE_VERSION}.tar.bz2" \
                 "${LFS_BUILD}/.extracted-pipewire"

    local src="${LFS_BUILD}/pipewire-${PIPEWIRE_VERSION}"
    cd "${src}"

    local crossfile="${LFS_BUILD}/meson-cross-linsi.ini"
    write_meson_crossfile "${crossfile}"

    local bdir="${src}/build"
    rm -rf "${bdir}"

    meson setup "${bdir}" \
        --cross-file="${crossfile}" \
        --prefix=/usr \
        --libdir=lib \
        --sysconfdir=/etc \
        --localstatedir=/var \
        -Dudevrulesdir=/usr/lib/udev/rules.d \
        -Dpipewire-alsa=enabled \
        -Dpipewire-jack=enabled \
        -Dlibpulse=disabled \
        -Dbluez5=disabled \
        "-Dsession-managers=[]" \
        -Dsystemd-user-service=enabled \
        -Dsystemd-system-service=disabled \
        -Dtests=disabled \
        -Ddocs=disabled \
        -Dexamples=disabled

    ninja -C "${bdir}" ${MAKEFLAGS}
    DESTDIR="${LFS_SYSROOT}" ninja -C "${bdir}" install

    log "PipeWire instalado en ${LFS_SYSROOT}/usr"
}

step_verify_pipewire() {
    log "Verificación: libpipewire y pipewire (daemon) en el sysroot"
    local ok=1
    local p
    for p in "${LFS_SYSROOT}/usr/bin/pipewire" "${LFS_SYSROOT}/usr/bin/pipewire-pulse"; do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    if ! find "${LFS_SYSROOT}/usr/lib" -maxdepth 1 -name 'libpipewire-*.so*' 2>/dev/null | grep -q .; then
        echo "  [FALTA] libpipewire-*.so en ${LFS_SYSROOT}/usr/lib"; ok=0
    else
        echo "  [OK] libpipewire-*.so presente"
    fi
    [[ "${ok}" -eq 1 ]] || die "falta algo de PipeWire en el sysroot"
    log "OK: PipeWire completo en el sysroot."
}

# ------------------------------------------------------------------------------
# 23) WirePlumber — Meson. system-lua=true + system-lua-version=5.4 para que
# use el Lua que acabamos de compilar (paso 21) en vez de la copia
# empaquetada adentro del propio WirePlumber. systemd=enabled/elogind=
# disabled porque tenemos systemd completo, no elogind.
# ------------------------------------------------------------------------------
step_wireplumber() {
    require_toolchain
    log "WirePlumber ${WIREPLUMBER_VERSION} para ${LFS_TGT} — Meson+Ninja"

    cd "${LFS_SOURCES}"
    fetch "${WIREPLUMBER_MIRROR}/wireplumber-${WIREPLUMBER_VERSION}.tar.bz2" \
          "wireplumber-${WIREPLUMBER_VERSION}.tar.bz2"
    log_sha256 "${LFS_SOURCES}/wireplumber-${WIREPLUMBER_VERSION}.tar.bz2"
    extract_once "${LFS_SOURCES}/wireplumber-${WIREPLUMBER_VERSION}.tar.bz2" \
                 "${LFS_BUILD}/.extracted-wireplumber"

    local src="${LFS_BUILD}/wireplumber-${WIREPLUMBER_VERSION}"
    cd "${src}"

    # CORREGIDO tras un build real fallido (2026-08-29, primera vuelta): el
    # problema era que glib-compile-resources sólo existía CROSS-compilado
    # en ${LFS_SYSROOT}/usr/bin (Meson lo encontraba por el PATH que agrega
    # env.sh) y, al ejecutarlo directo sin chroot, fallaba con "error while
    # loading shared libraries: libgio-2.0.so.0". Es un binario de OTRO
    # glibc (el cross-compilado de Fase 2) -- misma arquitectura no alcanza
    # para correrlo así de directo. El fix real fue instalar
    # libglib2.0-bin/libglib2.0-dev-bin de apt en el Dockerfile: un
    # glib-compile-resources genuinamente NATIVO en /usr/bin, que el PATH
    # encuentra ANTES que el de ${LFS_SYSROOT}/usr/bin (env.sh lo agrega al
    # final a propósito).
    #
    # CORREGIDO (segunda vuelta, mismo día): pasado ese, apareció el mismo
    # problema de fondo con OTRA herramienta -- spa-json-dump, que wireplumber
    # invoca para generar po/conf.pot a partir de wireplumber.conf. Acá no
    # hay paquete de apt (es propio de PipeWire) y el choque es de VERSIÓN de
    # glibc, no de librería faltante ("GLIBC_2.38 not found"). Se resuelve
    # con build_native_spa_json_dump() (ver el comentario largo ahí arriba,
    # cerca de write_meson_nativefile()).
    #
    # CORREGIDO (tercera vuelta, mismo día -- el --native-file de la segunda
    # vuelta NO alcanzó, quedó igual el error): el `po/meson.build` real de
    # wireplumber busca la herramienta con `find_program('spa-json-dump',
    # required: false)`, SIN `native: true` -- eso hace que Meson resuelva
    # contra el [binaries] del CROSS FILE (lo que Meson llama "host
    # machine"), no contra el del native file. El override va en
    # write_meson_crossfile() (parámetro extra_binaries), no en
    # write_meson_nativefile(). Por eso wireplumber no necesita
    # --native-file para esto -- sólo el cross-file de siempre, con el
    # binario nativo pisado adentro.
    build_native_spa_json_dump

    local crossfile="${LFS_BUILD}/meson-cross-linsi.ini"
    write_meson_crossfile "${crossfile}" "spa-json-dump = '${SPA_JSON_DUMP_NATIVE}'"

    local bdir="${src}/build"
    rm -rf "${bdir}"

    meson setup "${bdir}" \
        --cross-file="${crossfile}" \
        --prefix=/usr \
        --libdir=lib \
        --sysconfdir=/etc \
        -Dsystem-lua=true \
        -Dsystem-lua-version=5.4 \
        -Dsystemd=enabled \
        -Delogind=disabled \
        -Dintrospection=disabled \
        -Ddoc=disabled \
        -Dtests=false \
        -Ddbus-tests=false

    ninja -C "${bdir}" ${MAKEFLAGS}
    DESTDIR="${LFS_SYSROOT}" ninja -C "${bdir}" install

    log "WirePlumber instalado en ${LFS_SYSROOT}/usr"
}

step_verify_wireplumber() {
    log "Verificación: wireplumber (daemon) en el sysroot, linkeado contra libpipewire/liblua"
    local p="${LFS_SYSROOT}/usr/bin/wireplumber"
    [[ -e "${p}" ]] || die "no está ${p}"
    echo "  [OK] ${p}"
    "${LFS_TOOLS}/bin/${LFS_TGT}-readelf" -d "${p}" | grep -i "needed"
    log "OK: WirePlumber completo en el sysroot. Fase 6 parte 1 ('fundación no gráfica') completa."
}

main() {
    local target="${1:-all}"
    case "${target}" in
        libffi)                  step_libffi ;;
        verify-libffi)           step_verify_libffi ;;
        expat)                   step_expat ;;
        verify-expat)            step_verify_expat ;;
        glib)                    step_glib ;;
        verify-glib)             step_verify_glib ;;
        dbus)                    step_dbus ;;
        verify-dbus)             step_verify_dbus ;;
        duktape)                 step_duktape ;;
        verify-duktape)          step_verify_duktape ;;
        libpng)                  step_libpng ;;
        verify-libpng)           step_verify_libpng ;;
        polkit)                  step_polkit ;;
        verify-polkit)           step_verify_polkit ;;
        freetype)                step_freetype ;;
        verify-freetype)         step_verify_freetype ;;
        harfbuzz)                step_harfbuzz ;;
        verify-harfbuzz)         step_verify_harfbuzz ;;
        fontconfig)               step_fontconfig ;;
        verify-fontconfig)        step_verify_fontconfig ;;
        pixman)                   step_pixman ;;
        verify-pixman)            step_verify_pixman ;;
        cairo)                    step_cairo ;;
        verify-cairo)             step_verify_cairo ;;
        wayland)                  step_wayland ;;
        verify-wayland)           step_verify_wayland ;;
        wayland-protocols)        step_wayland_protocols ;;
        verify-wayland-protocols) step_verify_wayland_protocols ;;
        mtdev)                    step_mtdev ;;
        verify-mtdev)             step_verify_mtdev ;;
        libevdev)                 step_libevdev ;;
        verify-libevdev)          step_verify_libevdev ;;
        xkeyboard-config)         step_xkeyboard_config ;;
        verify-xkeyboard-config)  step_verify_xkeyboard_config ;;
        libinput)                 step_libinput ;;
        verify-libinput)          step_verify_libinput ;;
        libxkbcommon)             step_libxkbcommon ;;
        verify-libxkbcommon)      step_verify_libxkbcommon ;;
        alsa-lib)                 step_alsa_lib ;;
        verify-alsa-lib)          step_verify_alsa_lib ;;
        lua)                      step_lua ;;
        verify-lua)               step_verify_lua ;;
        pipewire)                  step_pipewire ;;
        verify-pipewire)           step_verify_pipewire ;;
        wireplumber)                step_wireplumber ;;
        verify-wireplumber)         step_verify_wireplumber ;;
        all)
            step_libffi;               step_verify_libffi
            step_expat;                step_verify_expat
            step_glib;                 step_verify_glib
            step_dbus;                 step_verify_dbus
            step_duktape;              step_verify_duktape
            step_libpng;               step_verify_libpng
            step_polkit;               step_verify_polkit
            step_freetype;             step_verify_freetype
            step_harfbuzz;             step_verify_harfbuzz
            step_fontconfig;           step_verify_fontconfig
            step_pixman;               step_verify_pixman
            step_cairo;                step_verify_cairo
            step_wayland;              step_verify_wayland
            step_wayland_protocols;    step_verify_wayland_protocols
            step_mtdev;                step_verify_mtdev
            step_libevdev;             step_verify_libevdev
            step_xkeyboard_config;     step_verify_xkeyboard_config
            step_libinput;             step_verify_libinput
            step_libxkbcommon;         step_verify_libxkbcommon
            step_alsa_lib;             step_verify_alsa_lib
            step_lua;                  step_verify_lua
            step_pipewire;             step_verify_pipewire
            step_wireplumber;          step_verify_wireplumber
            log "Fase 6 parte 1 ('fundación no gráfica') completa: D-Bus/polkit, fuentes/2D, Wayland, entrada y audio listos en el sysroot. Falta Mesa/LLVM (drivers gráficos) y Qt6/KDE Frameworks -- van en scripts aparte."
            ;;
        *)
            die "target desconocido: ${target} (usar: libffi|expat|glib|dbus|duktape|libpng|polkit|freetype|harfbuzz|fontconfig|pixman|cairo|wayland|wayland-protocols|mtdev|libevdev|xkeyboard-config|libinput|libxkbcommon|alsa-lib|lua|pipewire|wireplumber|all, cada uno con su verify-<paso>)"
            ;;
    esac
}

main "$@"
