#!/usr/bin/env bash
# ==============================================================================
# LINSI-OS · Fase 6 — "Interfaz Moderna" (parte 2: Mesa + LLVM, drivers gráficos)
# ------------------------------------------------------------------------------
# Igual que fases anteriores: no se chrootea, todo se instala con --prefix=/usr
# + DESTDIR="${LFS_SYSROOT}". Requiere Fase 6 Parte 1 completa
# (scripts/build-desktop.sh all) -- en particular necesita el wayland-scanner
# NATIVO que ya dejó compilado step_wayland() ahí (no se reconstruye acá, se
# reusa vía el volumen persistente /lfs/build).
#
# Alcance elegido (2026-08-29, a pedido explícito: máquinas del lab con
# GPUs de cualquier tipo -- Nvidia RTX 3060, AMD RX 7700, Intel integrada):
#   - Gallium (OpenGL):  iris (Intel), radeonsi (AMD), nouveau (Nvidia libre),
#                        llvmpipe (software con JIT de LLVM, fallback
#                        universal -- "swrast" era el nombre viejo de esta
#                        opción en versiones antiguas de Mesa; en 26.2.1 el
#                        choice válido es "llvmpipe" -- ver corrección más
#                        abajo. El .so instalado sigue llamándose
#                        swrast_dri.so igual, eso no cambió.)
#   - Vulkan:            amd (RADV), intel (ANV)
#   - LLVM sólo con los targets X86 (lo necesita llvmpipe para JIT) y
#     AMDGPU (lo necesita radeonsi para compilar shaders) -- nada de ARM,
#     RISC-V, etc. que no vamos a usar nunca acá.
#
# Lo que se dejó AFUERA a propósito (ver PENDIENTES.md, no es un olvido):
#   - Vulkan por software (lavapipe, "vulkan-drivers=swrast" -- ese option sí
#     se sigue llamando "swrast", es un namespace de opciones separado de
#     "gallium-drivers"): según la documentación real de Mesa, necesita
#     Clang de verdad (no sólo las librerías de LLVM) --
#     LLVM_ENABLE_PROJECTS="clang" agregado a este mismo build cruzado el
#     día que haga falta.
#   - NVK (driver Vulkan nativo para Nvidia): a la fecha de este script ni
#     siquiera figura como choice válido en el meson_options.txt real de
#     Mesa -- nouveau (Gallium/OpenGL) es lo que hay disponible.
#   - VA-API/VDPAU (aceleración de decodificación de video): -Dgallium-va
#     queda en disabled -- necesita libva, que este proyecto todavía no
#     compiló. VDPAU es más simple todavía: CORRECCIÓN (post-build real,
#     2026-08-30) -- "gallium-vdpau" ni siquiera es un option válido en
#     Mesa 26.2.1 ("ERROR: Unknown option: gallium-vdpau"), Mesa upstream
#     lo sacó del todo (no es un rename a otro nombre, es soporte VDPAU
#     nativo eliminado de Gallium). Sacado del comando de meson -- no había
#     nada que "dejar en disabled", la opción no existe.
#   - glvnd (dispatcher multi-vendor de OpenGL): sólo hace falta si algún día
#     convive Mesa con un driver propietario de Nvidia -- no es el caso hoy.
#
# La parte MÁS delicada de todo esto es cómo LLVM resuelve su propio
# "llvm-config" durante el build de Mesa -- ver el comentario largo en
# step_llvm() antes de tocar nada ahí. Es voluntad expresa de este proyecto
# (y de quien pidió esto) no dar por sentado que esto va a salir a la
# primera: el propio PENDIENTES.md, desde antes de escribir este script, ya
# decía "cross-compilar LLVM es delicado y merece su propia pasada de
# research" -- research que se hizo (LLVM.org, Buildroot real, docs oficiales
# de Mesa sobre detección de LLVM, un issue real de Meson sobre esto mismo),
# pero sin poder correr nada en vivo hasta que tiren el build real.
#
# Orden (cada paso depende del anterior):
#   1. libdrm       -> bindings de espacio de usuario al DRM/GEM del kernel
#   2. llvm-native  -> build NATIVO mínimo (llvm-tblgen + llvm-config), no
#                      se instala nada del sistema final con esto
#   3. llvm         -> build CRUZADO real (libLLVM + headers), el que
#                      efectivamente queda en el sysroot
#   4. mesa         -> los drivers en sí, usa libdrm + LLVM + el
#                      wayland-scanner nativo de la Parte 1
#
# Uso:
#   scripts/build-mesa.sh libdrm
#   scripts/build-mesa.sh all        # corre todos los pasos
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/lfs/scripts/env.sh
source "${SCRIPT_DIR}/env.sh"

log()  { printf '\n\033[1;35m[fase6-2]\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m[fase6-2][error]\033[0m %s\n' "$*" >&2; exit 1; }

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

# Cross file de Meson -- copia exacta del de build-desktop.sh (Fase 6 Parte 1),
# ya con los dos fixes reales que costaron una ronda entera de debug ahí:
# pkg_config_libdir como LISTA (share/pkgconfig además de lib/pkgconfig, lo
# necesitan paquetes sin código compilado) y el parámetro extra_binaries para
# poder pisar find_program()s puntuales sin --native-file (find_program() sin
# native:true resuelve contra ACÁ, no contra el native file -- lección real de
# wireplumber/spa-json-dump, ver PENDIENTES.md).
write_meson_crossfile() {
    local crossfile="$1"
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
pkg_config_libdir = ['${LFS_SYSROOT}/usr/lib/pkgconfig', '${LFS_SYSROOT}/usr/share/pkgconfig']
growing_stack = false
have_strlcpy = false
have_c99_vsnprintf = true
have_c99_snprintf = true
va_val_copy = true
EOF
}

# Prefix del wayland-scanner NATIVO -- NO se reconstruye acá. Ya lo dejó
# compilado step_wayland() en build-desktop.sh (Fase 6 Parte 1), y como
# /lfs/build es un volumen persistente (linsios-build en docker-compose.yml),
# este script -- aunque es un proceso bash completamente aparte -- lo
# encuentra en el mismo lugar. Sólo se chequea que exista.
WAYLAND_SCANNER_NATIVE_PREFIX="${LFS_BUILD}/wayland-scanner-native"

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

# Toolchain file de CMake -- el equivalente del cross-file de Meson, pero
# para LLVM (CMake, no Meson). Patrón estándar de CMake para cross-compiling
# (CMAKE_SYSTEM_NAME distinto activa CMAKE_CROSSCOMPILING automáticamente):
# CMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER porque los programas de build
# (bison, python3, etc.) tienen que ser los del HOST, no buscarse adentro
# del sysroot; LIBRARY/INCLUDE/PACKAGE=ONLY porque esos sí tienen que salir
# del sysroot (ahí vive el resto de lo que ya compilamos: libdrm, etc.).
write_cmake_toolchain() {
    local toolchain="$1"
    cat > "${toolchain}" <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER ${LFS_TOOLS}/bin/${LFS_TGT}-gcc)
set(CMAKE_CXX_COMPILER ${LFS_TOOLS}/bin/${LFS_TGT}-g++)
set(CMAKE_SYSROOT ${LFS_SYSROOT})
set(CMAKE_FIND_ROOT_PATH ${LFS_SYSROOT})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF
}

# ------------------------------------------------------------------------------
# 1) libdrm — Meson. Bindings de espacio de usuario al DRM/GEM del kernel;
# necesario para que Mesa hable con /dev/dri/*. Receta mínima (udev+valgrind
# nada más) confirmada contra una receta real de LFS/BLFS para esta misma
# versión -- las cabeceras por-vendor de radeon/amdgpu/nouveau se instalan
# solas sin flags extra.
#
# CORRECCIÓN (post-build real, 2026-08-29): libdrm_intel NO se instala solo.
# Su detección depende de pciaccess (libpciaccess), que no está en el
# sysroot -- meson lo marca "NO" y desactiva silenciosamente el subdirectorio
# intel/ sin frenar el resto del build. Esto en un principio parecía un bug
# a arreglar, pero en realidad NO hace falta: libdrm_intel sólo lo usan el
# driver clásico i965/crocus (legado, pre-Gen8) y la DDX de X11
# (xf86-video-intel) -- ninguno de los dos está en el plan (elegimos el
# driver moderno `iris` para Mesa y este proyecto es Wayland puro, sin DDX de
# X11). Confirmado contra el meson.build real de iris en Mesa: sólo depende
# de `dep_libdrm` genérico, nunca de `libdrm_intel`/`intel_bufmgr`. Por eso
# step_verify_libdrm() de abajo lo trata como informativo, no como falla.
# ------------------------------------------------------------------------------
step_libdrm() {
    require_toolchain
    log "libdrm ${LIBDRM_VERSION} para ${LFS_TGT} — Meson+Ninja"

    cd "${LFS_SOURCES}"
    fetch "${LIBDRM_MIRROR}/libdrm-libdrm-${LIBDRM_VERSION}.tar.gz" \
          "libdrm-${LIBDRM_VERSION}.tar.gz"
    log_sha256 "${LFS_SOURCES}/libdrm-${LIBDRM_VERSION}.tar.gz"
    extract_once "${LFS_SOURCES}/libdrm-${LIBDRM_VERSION}.tar.gz" \
                 "${LFS_BUILD}/.extracted-libdrm"

    # Igual que con pipewire/wireplumber: gitlab.fd.o arma el tarball como
    # "<repo>-<tag>" -- acá el tag es "libdrm-${LIBDRM_VERSION}", así que el
    # directorio queda con el nombre duplicado.
    local src="${LFS_BUILD}/libdrm-libdrm-${LIBDRM_VERSION}"
    cd "${src}"

    local crossfile="${LFS_BUILD}/meson-cross-linsi.ini"
    write_meson_crossfile "${crossfile}"

    local bdir="${src}/build"
    rm -rf "${bdir}"

    meson setup "${bdir}" \
        --cross-file="${crossfile}" \
        --prefix=/usr \
        --libdir=lib \
        -Dudev=true \
        -Dvalgrind=disabled

    ninja -C "${bdir}" ${MAKEFLAGS}
    DESTDIR="${LFS_SYSROOT}" ninja -C "${bdir}" install

    log "libdrm instalado en ${LFS_SYSROOT}/usr"
}

step_verify_libdrm() {
    log "Verificación: libdrm y bindings por-vendor en el sysroot"
    local ok=1
    if ! find "${LFS_SYSROOT}/usr/lib" -maxdepth 1 -name 'libdrm.so*' 2>/dev/null | grep -q .; then
        echo "  [FALTA] libdrm.so en ${LFS_SYSROOT}/usr/lib"; ok=0
    else
        echo "  [OK] libdrm.so presente"
    fi
    local p
    for p in libdrm_amdgpu libdrm_nouveau; do
        if find "${LFS_SYSROOT}/usr/lib" -maxdepth 1 -name "${p}.so*" 2>/dev/null | grep -q .; then
            echo "  [OK] ${p}.so presente"
        else
            echo "  [FALTA] ${p}.so en ${LFS_SYSROOT}/usr/lib"; ok=0
        fi
    done
    # libdrm_intel: NO se cuenta como falla. Sólo la usan el driver clásico
    # i965/crocus y la DDX de X11 xf86-video-intel -- ninguno está en este
    # proyecto (usamos `iris`, que sólo depende de libdrm genérico). Se
    # desactiva solo porque falta pciaccess en el sysroot, y eso está bien.
    if find "${LFS_SYSROOT}/usr/lib" -maxdepth 1 -name 'libdrm_intel.so*' 2>/dev/null | grep -q .; then
        echo "  [OK] libdrm_intel.so presente (no hacía falta, pero está)"
    else
        echo "  [info] libdrm_intel.so no está -- esperado, sólo lo necesitan i965/crocus (legado) y xf86-video-intel, no iris"
    fi
    [[ "${ok}" -eq 1 ]] || die "falta algo de libdrm en el sysroot"
    log "OK: libdrm completo en el sysroot (para lo que este proyecto necesita)."
}

# ------------------------------------------------------------------------------
# 2) y 3) LLVM — CMake, build en DOS ETAPAS. Esto es lo más delicado de todo
# el proyecto hasta ahora, así que va el razonamiento completo acá.
#
# LLVM_TARGETS_TO_BUILD="X86;AMDGPU" nada más -- lo necesita llvmpipe
# (JIT en X86) y radeonsi (compila shaders para AMDGPU). Nada de ARM/RISC-V/
# etc: no vamos a generar código para esas arquitecturas nunca en este
# proyecto. LLVM_ENABLE_PROJECTS vacío: sólo "llvm" (las librerías core),
# nada de clang/lld/mlir -- Mesa no los necesita para lo que vamos a activar
# (ver el aviso al principio del archivo sobre lavapipe, que sí pediría clang).
#
# ETAPA 1 (step_llvm_native, NATIVA, sin --cross-file): build de CMake
# mínimo (sólo los targets "llvm-tblgen" y "llvm-config", no "ninja install"
# de todo LLVM) usando el compilador nativo del contenedor. Confirmado contra
# la documentación real de LLVM (llvm.org/docs/CMake.html, variable
# LLVM_TABLEGEN: "Full path to a native TableGen executable... intended for
# cross-compiling") y una receta real de cross-compiling de LLVM en Buildroot
# (linuxembedded.fr/2018/07/llvmclang-integration-into-buildroot): un build
# cruzado de LLVM NECESITA un llvm-tblgen que corra YA, durante el build,
# para generar código a partir de los ".td" -- exactamente el mismo patrón
# de "herramienta de build-time que tiene que ser nativa" que ya vimos tres
# veces con wayland-scanner en la Parte 1, sólo que acá LLVM mismo ya lo
# tiene resuelto de fábrica con esta variable, no hace falta --native-file.
#
# El problema nuevo, específico de LLVM, es "llvm-config": Mesa lo necesita
# para preguntarle "¿dónde están tus headers, tus libs, tenés RTTI?" durante
# SU PROPIO configure -- y esa consulta tiene que poder EJECUTARSE (no sirve
# de nada un llvm-config cross-compilado tirado en el sysroot, va a fallar
# con el mismo problema de glibc que ya vimos con glib-compile-resources y
# spa-json-dump en wireplumber). Documentado en los docs oficiales de Mesa
# (docs.mesa3d.org/meson.html, sección de detección de LLVM) que el método
# estándar es un llvm-config real en el PATH (o pisado vía cross/native
# file) -- y un issue real de Meson (mesonbuild/meson#2921, "Cross-file
# binaries not being used for ConfigTool") confirma que Meson SÍ soporta
# pisarlo desde ahí (el bug que describía ese issue ya está resuelto en la
# versión de Meson que usamos, >=1.3).
#
# La solución (mismo patrón que Buildroot, adaptado a que acá build==target
# en arquitectura): compilar llvm-config NATIVO -- corre bien, misma
# arquitectura -- pero configurado con el MISMO --prefix que va a tener el
# LLVM cruzado de verdad (${LFS_SYSROOT}/usr, no un prefix nativo aparte),
# para que lo que imprime ("--includedir", "--libdir", etc) apunte a donde
# EFECTIVAMENTE van a estar los headers/libs cruzados de verdad (instalados
# por la ETAPA 2). Se copia ese binario nativo directo a
# ${LFS_SYSROOT}/usr/bin/llvm-config, pisando el cruzado (roto) que deja el
# "ninja install" de la Etapa 2. Mesa lo encuentra solo por PATH (no hace
# falta --native-file para esto: ${LFS_SYSROOT}/usr/bin ya está al final del
# PATH desde Fase 6 Parte 1, y no hay ningún otro "llvm-config" antes en el
# PATH que lo tape).
#
# CORRECCIÓN (post-build real, 2026-08-30): el prefix SÍ queda bien grabado
# en el binario (confirmado: llvm-config.cpp de LLVM compara su ubicación de
# ejecución contra una constante LLVM_OBJ_ROOT grabada en tiempo de
# compilación -- si NO coinciden, que es justo lo que pasa acá porque lo
# movimos fuera de ${LLVM_NATIVE_BUILD}, usa el CMAKE_INSTALL_PREFIX que le
# dimos, o sea ${LFS_SYSROOT}/usr -- exactamente lo que queríamos). El
# problema real fue otro, más básico: LLVM compila su tooling (llvm-config
# incluido) con un RPATH relativo a propósito ("$ORIGIN/../lib", para que
# las herramientas de LLVM sean relocalizables -- confirmado contra el
# historial real de cambios de AddLLVM.cmake en el repo de LLVM). Al copiar
# el binario nativo a ${LFS_SYSROOT}/usr/bin/llvm-config, ese RPATH relativo
# pasa a resolver a ${LFS_SYSROOT}/usr/lib -- que es la carpeta de
# librerías del SYSROOT (la glibc cross-compilada de Fase 2), no la del
# contenedor. Error real visto: "symbol lookup error:
# .../lib/libc.so.6: undefined symbol: __pointer_chk_guard, version
# GLIBC_PRIVATE" -- otra vuelta más del mismo problema de fondo que ya
# apareció 3 veces en la Parte 1 (mezclar binario y glibc de mundos
# distintos aunque sea "la misma arquitectura"), sólo que acá el binario SÍ
# es nativo -- lo que estaba mal era a qué librerías apuntaba por culpa de
# dónde lo copiamos, no el binario en sí.
#
# La solución: dejar que el binario reporte las rutas del sysroot (eso ya
# funciona, es independiente del RPATH -- son dos mecanismos separados: uno
# son strings grabados en tiempo de compilación, el otro es una entrada del
# header ELF que se puede reescribir después sin recompilar nada), pero
# usar `patchelf --set-rpath` para apuntar su RPATH al directorio de build
# NATIVO de LLVM (${LLVM_NATIVE_BUILD}/lib), que tiene una libLLVM.so
# compatible con el contenedor. step_verify_llvm() de abajo corre el
# llvm-config ya parcheado y CHEQUEA tanto que corra sin error como que
# --includedir devuelva algo adentro de ${LFS_SYSROOT}.
# ------------------------------------------------------------------------------
LLVM_NATIVE_BUILD="${LFS_BUILD}/llvm-native-build"
LLVM_TABLEGEN_NATIVE="${LLVM_NATIVE_BUILD}/bin/llvm-tblgen"

LLVM_CMAKE_COMMON_FLAGS=(
    -DCMAKE_BUILD_TYPE=Release
    -DLLVM_ENABLE_PROJECTS=
    "-DLLVM_TARGETS_TO_BUILD=X86;AMDGPU"
    -DLLVM_TARGET_ARCH=X86
    -DLLVM_INCLUDE_TESTS=OFF
    -DLLVM_INCLUDE_EXAMPLES=OFF
    -DLLVM_INCLUDE_BENCHMARKS=OFF
    -DLLVM_INCLUDE_DOCS=OFF
    -DLLVM_ENABLE_TERMINFO=OFF
    -DLLVM_ENABLE_ZLIB=OFF
    -DLLVM_ENABLE_ZSTD=OFF
    -DLLVM_ENABLE_LIBXML2=OFF
    -DLLVM_ENABLE_LIBEDIT=OFF
    -DLLVM_ENABLE_RTTI=ON
    -DLLVM_BUILD_LLVM_DYLIB=ON
    -DLLVM_LINK_LLVM_DYLIB=ON
)

_llvm_fetch_extract() {
    cd "${LFS_SOURCES}"
    fetch "${LLVM_MIRROR}/llvm-project-${LLVM_VERSION}.src.tar.xz" \
          "llvm-project-${LLVM_VERSION}.src.tar.xz"
    log_sha256 "${LFS_SOURCES}/llvm-project-${LLVM_VERSION}.src.tar.xz"
    extract_once "${LFS_SOURCES}/llvm-project-${LLVM_VERSION}.src.tar.xz" \
                 "${LFS_BUILD}/.extracted-llvm-project"
}

step_llvm_native() {
    log "LLVM ${LLVM_VERSION} — build NATIVO (llvm-tblgen + llvm-config, para el build cruzado)"
    _llvm_fetch_extract

    local src="${LFS_BUILD}/llvm-project-${LLVM_VERSION}.src"
    rm -rf "${LLVM_NATIVE_BUILD}"

    cmake -S "${src}/llvm" -B "${LLVM_NATIVE_BUILD}" -G Ninja \
        -DCMAKE_INSTALL_PREFIX="${LFS_SYSROOT}/usr" \
        "${LLVM_CMAKE_COMMON_FLAGS[@]}"

    ninja -C "${LLVM_NATIVE_BUILD}" ${MAKEFLAGS} llvm-tblgen llvm-config

    [[ -x "${LLVM_TABLEGEN_NATIVE}" ]] || die "no se compiló llvm-tblgen nativo"
    [[ -x "${LLVM_NATIVE_BUILD}/bin/llvm-config" ]] || die "no se compiló llvm-config nativo"
    log "LLVM nativo listo: llvm-tblgen en ${LLVM_TABLEGEN_NATIVE}"
}

step_llvm() {
    require_toolchain
    [[ -x "${LLVM_TABLEGEN_NATIVE}" ]] \
        || die "no está el llvm-tblgen NATIVO en ${LLVM_NATIVE_BUILD}/bin -- corré primero: scripts/build-mesa.sh llvm-native"

    log "LLVM ${LLVM_VERSION} para ${LFS_TGT} — build CRUZADO (usa el llvm-tblgen nativo)"
    _llvm_fetch_extract

    local src="${LFS_BUILD}/llvm-project-${LLVM_VERSION}.src"
    local toolchain="${LFS_BUILD}/cmake-cross-linsi.cmake"
    write_cmake_toolchain "${toolchain}"

    local bdir="${LFS_BUILD}/llvm-cross-build"
    rm -rf "${bdir}"

    cmake -S "${src}/llvm" -B "${bdir}" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="${toolchain}" \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DLLVM_TABLEGEN="${LLVM_TABLEGEN_NATIVE}" \
        -DLLVM_DEFAULT_TARGET_TRIPLE="${LFS_TGT}" \
        -DLLVM_HOST_TRIPLE="${LFS_TGT}" \
        "${LLVM_CMAKE_COMMON_FLAGS[@]}"

    ninja -C "${bdir}" ${MAKEFLAGS}
    DESTDIR="${LFS_SYSROOT}" ninja -C "${bdir}" install

    # Pisar el llvm-config cruzado (instalado recién por el "ninja install"
    # de arriba, pero NO ejecutable acá sin chroot) con el nativo -- ver el
    # comentario largo más arriba.
    install -Dm755 "${LLVM_NATIVE_BUILD}/bin/llvm-config" "${LFS_SYSROOT}/usr/bin/llvm-config"

    # El binario recién copiado trae un RPATH relativo ("$ORIGIN/../lib")
    # que, en su nueva ubicación, resuelve a ${LFS_SYSROOT}/usr/lib -- la
    # glibc CRUZADA, no la del contenedor (ver el comentario largo arriba de
    # este bloque). Se reescribe con patchelf para que apunte al build
    # nativo de LLVM, que tiene su propia libLLVM.so compatible. Esto NO
    # toca las rutas que imprime llvm-config (--includedir, etc.) -- esas
    # están grabadas aparte, en tiempo de compilación.
    command -v patchelf >/dev/null 2>&1 \
        || die "falta patchelf en el contenedor -- agregalo al Dockerfile (apt-get install patchelf) y correé 'podman-compose build' de nuevo"
    patchelf --set-rpath "${LLVM_NATIVE_BUILD}/lib" "${LFS_SYSROOT}/usr/bin/llvm-config"

    log "LLVM instalado en ${LFS_SYSROOT}/usr (libLLVM compartida + llvm-config nativo pisado encima, RPATH corregido con patchelf)"
}

step_verify_llvm() {
    log "Verificación: LLVM en el sysroot + llvm-config nativo funcional"
    local ok=1
    if ! find "${LFS_SYSROOT}/usr/lib" -maxdepth 1 -name 'libLLVM*.so*' 2>/dev/null | grep -q .; then
        echo "  [FALTA] libLLVM*.so en ${LFS_SYSROOT}/usr/lib"; ok=0
    else
        echo "  [OK] libLLVM*.so presente"
    fi
    local lc="${LFS_SYSROOT}/usr/bin/llvm-config"
    if [[ ! -x "${lc}" ]]; then
        echo "  [FALTA] ${lc}"; ok=0
    else
        local includedir
        if ! includedir="$("${lc}" --includedir 2>&1)"; then
            echo "  [FALTA] ${lc} no corrió bien: ${includedir}"; ok=0
        elif [[ "${includedir}" != "${LFS_SYSROOT}"* ]]; then
            echo "  [ADVERTENCIA] ${lc} --includedir devolvió '${includedir}' -- no arranca con ${LFS_SYSROOT}, Mesa probablemente NO va a encontrar los headers/libs correctos. Avisame si ves esto, es el punto más incierto de todo el script (ver comentario largo arriba de step_llvm)."
            ok=0
        else
            echo "  [OK] ${lc} --includedir = ${includedir}"
        fi
    fi
    [[ "${ok}" -eq 1 ]] || die "falta algo de LLVM en el sysroot (ver arriba)"
    log "OK: LLVM completo y llvm-config funcional."
}

# ------------------------------------------------------------------------------
# 4) glslang — CMake, build 100% NATIVO (sin cross-file, sin sysroot).
#
# CORRECCIÓN (post-build real, 2026-08-31, en dos pasos): Mesa necesita
# glslangValidator en tiempo de build para compilar shaders internos
# (GLSL -> SPIR-V). Primer error real: no estaba instalado -- se agregó
# glslang-tools al Dockerfile (apt). Segundo error real, con el paquete de
# apt ya instalado: "ERROR: glslang >= 12.2 is required" -- el glslang de
# Debian bookworm queda por debajo de ese piso (mismo motivo que ya llevó a
# instalar meson por pip y rust por rustup en vez de apt, Fase 2). Acá no
# hay pip/rustup equivalente para glslang, así que se compila de fuente,
# igual que LLVM más arriba -- pero mucho más simple: glslangValidator
# SÓLO genera código en tiempo de build, nunca corre en el sysroot final,
# así que no hace falta NADA de lo que hizo delicado a LLVM (ni dos etapas,
# ni RPATH, ni CMAKE_INSTALL_PREFIX apuntando al sysroot) -- un build
# nativo derecho, con un prefix nativo cualquiera, alcanza.
# -DENABLE_OPT=OFF evita necesitar SPIRV-Tools como dependencia externa
# (confirmado contra el CMakeLists.txt real de glslang: con ENABLE_OPT=OFF
# no hace falta ningún submódulo/dependencia externa) -- Mesa sólo necesita
# el compilador de shaders, no el optimizador de SPIR-V.
# ------------------------------------------------------------------------------
GLSLANG_NATIVE_BUILD="${LFS_BUILD}/glslang-native-build"
GLSLANG_NATIVE_INSTALL="${LFS_BUILD}/glslang-native-install"
GLSLANG_NATIVE_BIN="${GLSLANG_NATIVE_INSTALL}/bin/glslangValidator"

step_glslang_native() {
    if [[ -x "${GLSLANG_NATIVE_BIN}" ]]; then
        log "glslangValidator nativo ya compilado en ${GLSLANG_NATIVE_BIN}"
        return 0
    fi
    log "glslang ${GLSLANG_VERSION} — build NATIVO (glslangValidator, Mesa exige >=12.2)"

    cd "${LFS_SOURCES}"
    fetch "${GLSLANG_MIRROR}/${GLSLANG_VERSION}.tar.gz" "glslang-${GLSLANG_VERSION}.tar.gz"
    log_sha256 "${LFS_SOURCES}/glslang-${GLSLANG_VERSION}.tar.gz"
    extract_once "${LFS_SOURCES}/glslang-${GLSLANG_VERSION}.tar.gz" \
                 "${LFS_BUILD}/.extracted-glslang"

    local src="${LFS_BUILD}/glslang-${GLSLANG_VERSION}"
    rm -rf "${GLSLANG_NATIVE_BUILD}"

    cmake -S "${src}" -B "${GLSLANG_NATIVE_BUILD}" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${GLSLANG_NATIVE_INSTALL}" \
        -DENABLE_OPT=OFF \
        -DENABLE_GLSLANG_BINARIES=ON \
        -DBUILD_TESTING=OFF

    ninja -C "${GLSLANG_NATIVE_BUILD}" ${MAKEFLAGS}
    ninja -C "${GLSLANG_NATIVE_BUILD}" install

    [[ -x "${GLSLANG_NATIVE_BIN}" ]] || die "no se compiló glslangValidator nativo"
    log "glslangValidator nativo listo en ${GLSLANG_NATIVE_BIN}"
}

# ------------------------------------------------------------------------------
# 5) Mesa — Meson. Drivers elegidos para cubrir Intel/AMD/Nvidia reales del
# lab (ver el aviso al principio del archivo). --native-file hace falta
# porque Mesa también invoca wayland-scanner en tiempo de build (protocolo
# linux-dmabuf/wayland-drm para la plataforma EGL wayland) -- mismo problema
# que ya resolvimos tres veces en la Parte 1, acá se reusa el mismo scanner
# nativo en vez de reconstruirlo. Mismo mecanismo para glslangValidator, con
# una vuelta más: CORRECCIÓN (post-build real, 2026-09-01) -- pisarlo sólo
# en el cross-file (el patrón que funcionó con spa-json-dump en
# build-desktop.sh) NO alcanzó acá; Meson lo siguió resolviendo contra el
# de apt (/usr/bin/glslangValidator, muy viejo). A diferencia de
# spa-json-dump (que confirmamos leyendo el meson.build real de wireplumber
# que NO usa native:true), no pude confirmar en vivo si el find_program()
# de glslangValidator en el meson.build real de Mesa 26.2.1 usa
# native:true o no -- las dos fuentes que miré (mirror de GitHub) no
# coinciden entre sí ni con el comportamiento real observado. En vez de
# seguir adivinando, se pisa en LOS DOS archivos (--cross-file y
# --native-file) -- no cuesta nada extra y cubre cualquiera de los dos
# mecanismos que Mesa termine usando.
# ------------------------------------------------------------------------------
step_mesa() {
    require_toolchain
    [[ -x "${LFS_SYSROOT}/usr/bin/llvm-config" ]] \
        || die "no está LLVM en el sysroot -- corré primero: scripts/build-mesa.sh llvm"
    if ! find "${LFS_SYSROOT}/usr/lib" -maxdepth 1 -name 'libdrm.so*' 2>/dev/null | grep -q .; then
        die "no está libdrm en el sysroot -- corré primero: scripts/build-mesa.sh libdrm"
    fi
    [[ -x "${WAYLAND_SCANNER_NATIVE_PREFIX}/bin/wayland-scanner" ]] \
        || die "no está el wayland-scanner NATIVO en ${WAYLAND_SCANNER_NATIVE_PREFIX}/bin -- corré primero: scripts/build-desktop.sh wayland (Fase 6 Parte 1)"
    [[ -x "${GLSLANG_NATIVE_BIN}" ]] \
        || die "no está glslangValidator NATIVO en ${GLSLANG_NATIVE_BIN} -- corré primero: scripts/build-mesa.sh glslang-native"

    log "Mesa ${MESA_VERSION} para ${LFS_TGT} — Meson+Ninja (gallium: iris/radeonsi/nouveau/llvmpipe, vulkan: amd/intel)"

    cd "${LFS_SOURCES}"
    fetch "${MESA_MIRROR}/mesa-mesa-${MESA_VERSION}.tar.gz" "mesa-${MESA_VERSION}.tar.gz"
    log_sha256 "${LFS_SOURCES}/mesa-${MESA_VERSION}.tar.gz"
    extract_once "${LFS_SOURCES}/mesa-${MESA_VERSION}.tar.gz" \
                 "${LFS_BUILD}/.extracted-mesa"

    # Mismo patrón "<repo>-<tag>" duplicado de gitlab.fd.o que libdrm/pipewire.
    local src="${LFS_BUILD}/mesa-mesa-${MESA_VERSION}"
    cd "${src}"

    local crossfile="${LFS_BUILD}/meson-cross-linsi.ini"
    write_meson_crossfile "${crossfile}" "glslangValidator = '${GLSLANG_NATIVE_BIN}'"

    local nativefile="${LFS_BUILD}/meson-native-linsi.ini"
    write_meson_nativefile "${nativefile}" "glslangValidator = '${GLSLANG_NATIVE_BIN}'"

    local bdir="${src}/build"
    rm -rf "${bdir}"

    # No hay "-Dosmesa=..." acá: CORRECCIÓN (post-build real, 2026-08-30) --
    # "osmesa" (renderizado off-screen sin GPU/display) fue eliminado de
    # Mesa upstream (mismo patrón que gallium-vdpau más abajo: no es un
    # rename, la opción no existe más). Como igual la queríamos en "false"
    # (no la necesitamos, este proyecto siempre tiene GPU real o llvmpipe),
    # sacarla del comando no cambia nada funcionalmente.
    meson setup "${bdir}" \
        --cross-file="${crossfile}" \
        --native-file="${nativefile}" \
        --prefix=/usr \
        --libdir=lib \
        --buildtype=release \
        -Dplatforms=wayland \
        -Dgallium-drivers=iris,radeonsi,nouveau,llvmpipe \
        -Dvulkan-drivers=amd,intel \
        -Dllvm=enabled \
        -Dshared-llvm=enabled \
        -Dvalgrind=disabled \
        -Dgbm=enabled \
        -Degl=enabled \
        -Dglx=disabled \
        -Dopengl=true \
        -Dgles2=enabled \
        -Dglvnd=disabled \
        -Dgallium-va=disabled

    ninja -C "${bdir}" ${MAKEFLAGS}
    DESTDIR="${LFS_SYSROOT}" ninja -C "${bdir}" install

    log "Mesa instalado en ${LFS_SYSROOT}/usr"
}

step_verify_mesa() {
    log "Verificación: drivers de Mesa (Gallium + Vulkan) en el sysroot"
    local ok=1
    local p
    # swrast_dri.so es el nombre correcto del .so instalado por la opción de
    # meson "llvmpipe" (confirmado contra el meson.build real de Mesa,
    # target dri) -- el nombre del archivo no cambió aunque el nombre de la
    # opción sí, no es una inconsistencia.
    for p in \
        "${LFS_SYSROOT}/usr/lib/dri/iris_dri.so" \
        "${LFS_SYSROOT}/usr/lib/dri/radeonsi_dri.so" \
        "${LFS_SYSROOT}/usr/lib/dri/nouveau_dri.so" \
        "${LFS_SYSROOT}/usr/lib/dri/swrast_dri.so"
    do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    for p in \
        "${LFS_SYSROOT}/usr/lib/libvulkan_radeon.so" \
        "${LFS_SYSROOT}/usr/lib/libvulkan_intel.so"
    do
        if [[ -e "${p}" ]]; then echo "  [OK] ${p}"; else echo "  [FALTA] ${p}"; ok=0; fi
    done
    if ! find "${LFS_SYSROOT}/usr/lib" -maxdepth 1 -name 'libEGL.so*' 2>/dev/null | grep -q .; then
        echo "  [FALTA] libEGL.so en ${LFS_SYSROOT}/usr/lib"; ok=0
    else
        echo "  [OK] libEGL.so presente"
    fi
    [[ "${ok}" -eq 1 ]] || die "falta algo de Mesa en el sysroot"
    log "OK: Mesa completo en el sysroot."
}

main() {
    local target="${1:-all}"
    case "${target}" in
        libdrm)         step_libdrm ;;
        verify-libdrm)  step_verify_libdrm ;;
        llvm-native)    step_llvm_native ;;
        llvm)           step_llvm ;;
        verify-llvm)    step_verify_llvm ;;
        glslang-native) step_glslang_native ;;
        mesa)           step_mesa ;;
        verify-mesa)    step_verify_mesa ;;
        all)
            step_libdrm;      step_verify_libdrm
            step_llvm_native
            step_llvm;        step_verify_llvm
            step_glslang_native
            step_mesa;        step_verify_mesa
            log "Fase 6 parte 2 ('Mesa + LLVM') completa: libdrm, LLVM (X86+AMDGPU) y Mesa (iris/radeonsi/nouveau/llvmpipe + Vulkan amd/intel) listos en el sysroot. Falta Qt6/KDE Frameworks -- va en su propio script."
            ;;
        *)
            die "target desconocido: ${target} (usar: libdrm|llvm-native|llvm|glslang-native|mesa|all, cada uno con su verify-<paso> salvo llvm-native/glslang-native)"
            ;;
    esac
}

main "$@"
