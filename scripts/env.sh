#!/usr/bin/env bash
# ==============================================================================
# LINSI-OS · Fase 0 — Variables de entorno compartidas
# Se sourcea desde entrypoint.sh y desde cada script de build.
#
# IMPORTANTE: revisá las versiones antes de una build "real" — acá se fija un
# set conocido-bueno al momento de escribir esto, pero Binutils/GCC/kernel
# sacan releases seguido. https://ftp.gnu.org/gnu/binutils/  /gcc/  /kernel.org
# ==============================================================================
set -euo pipefail

# --- Versiones del cross-toolchain (Fase 0) ----------------------------------
export BINUTILS_VERSION="2.43.1"
export GCC_VERSION="14.2.0"
export LINUX_VERSION="7.2"             # kernel a usar tanto para las cabeceras (Fase 0) como el build completo (Fase 1)
export GMP_VERSION="6.3.0"
export MPFR_VERSION="4.2.1"
export MPC_VERSION="1.3.1"

# sha256 oficial de linux-7.2.tar.xz publicado en kernel.org/pub/linux/kernel/v7.x/sha256sums.asc
# (chequeado el 2026-08-22 — antes de una build "real" volvé a confirmarlo ahí mismo)
export LINUX_SHA256="f9fef3d14c0df53819026f4be74459835c2a0b0dcbf5b5bbd9ea19f0829402b3"

# --- Versiones del espacio de usuario (Fase 2) --------------------------------
# Chequeadas por búsqueda web el 2026-08-24 (últimas estables a esa fecha):
#   glibc   2.44  — sourceware.org/glibc, release 2026-07-25
#   systemd 261   — github.com/systemd/systemd/releases/tag/v261, release 2026-06-19
#   zsh     5.9   — zsh.sourceforge.io/News, sin release más nuevo desde 2022
# A diferencia del kernel, ninguno de estos tres publica un sha256sums.txt
# plano y fácil de verificar de forma automática (se firman por GPG). No se
# fija acá un hash inventado — verify_userspace_tarball() calcula el sha256
# real después de bajar cada uno y lo deja en el log para cotejar a mano
# contra la fuente oficial si querés esa garantía extra.
export GLIBC_VERSION="2.44"
export SYSTEMD_VERSION="261"
export ZSH_VERSION="5.9"

# Dependencias de systemd que hay que compilar antes (systemd las busca vía
# pkg-config contra el sysroot: sin esto, meson las auto-deshabilita en vez
# de fallar, así que si querés que systemd las use de verdad tienen que
# estar instaladas ANTES del paso systemd).
# Chequeadas por búsqueda web el 2026-08-25 (últimas estables a esa fecha):
#   util-linux 2.42.2 — kernel.org/pub/linux/utils/util-linux, release 2026-06-16
#   libcap     2.78   — kernel.org/pub/linux/libs/security/linux-privs/libcap2, release 2026-04-06
#   attr       2.6.0  — download-mirror.savannah.gnu.org/releases/attr, release 2026-06-29
#   acl        2.4.0  — confirmado por versión de paquete en Arch/Artix (2.4.0-1);
#                        no se pudo confirmar el nombre exacto del tarball en
#                        savannah por bloqueo de robots.txt en la búsqueda — si
#                        el .tar.xz de acl-2.4.0 no existe en el mirror, avisame
#                        con el error de wget y lo ajusto a .tar.gz.
export UTIL_LINUX_VERSION="2.42.2"
export LIBCAP_VERSION="2.78"
export ATTR_VERSION="2.6.0"
export ACL_VERSION="2.4.0"

# ncurses: lo necesita Zsh (edición de línea, colores, terminfo) — no estaba
# en la lista original de dependencias de systemd, se agrega acá porque Zsh
# sin ninguna librería de terminal no tiene mucho sentido como shell real.
# Chequeada por búsqueda web el 2026-08-25: última estable, ftp.gnu.org/gnu/ncurses.
export NCURSES_VERSION="6.6"

# uutils (coreutils en Rust) — se compila desde el tag de GitHub, no desde
# crates.io, porque el repo es un workspace con muchos crates (uu_ls, uu_cp,
# etc.) más el crate "coreutils" que arma el binario multicall tipo BusyBox;
# publicar eso reproducible vía crates.io individual sería mucho más frágil
# que bajar el tarball del tag directo. Chequeada el 2026-08-25: último
# release "0.9.0" (30/05/2026), 625 tests de la testsuite de GNU pasando.
export UUTILS_VERSION="0.9.0"

# --- Fase 3 ("El Escudo") -------------------------------------------------------
# nftables + sus dos librerías netlink de base. Chequeadas por búsqueda web el
# 2026-08-26 (últimas estables a esa fecha, netfilter.org/projects/*/downloads.html):
#   libmnl    1.0.5  — sin release nuevo desde 2022 (paquete chico y estable)
#   libnftnl  1.3.1  — 03/12/2025
#   nftables  1.1.6  — 05/12/2025
export LIBMNL_VERSION="1.0.5"
export LIBNFTNL_VERSION="1.3.1"
export NFTABLES_VERSION="1.1.6"

# libcap-ng: dependencia OPCIONAL de auditd/audisp para que sus plugins
# corran con el mínimo de capabilities posible en vez de con todo el root
# (coherente con el resto del hardening de esta fase, aunque no es
# estrictamente necesaria para que auditd funcione). Chequeada por búsqueda
# web el 2026-08-26: el release taggeado más nuevo en GitHub es 0.9.5
# (21/08/2024). El configure.ac de la rama master ya dice "0.9.6", pero eso
# es sólo el número que el propio proyecto sube ni bien taggea un release,
# para el PRÓXIMO (todavía sin tag ni tarball publicado) — mismo patrón que
# se repite con audit-userspace más abajo. Nos quedamos con el último tag
# REAL: 0.9.5.
export LIBCAP_NG_VERSION="0.9.5"

# audit-userspace (auditd + auparse + auditctl + reglas). Chequeada por
# búsqueda web el 2026-08-26 contra el ChangeLog real del repo (no contra la
# página de releases, que a veces no lista el más nuevo): el último release
# taggeado es 4.2.1 (29/07/2026). Igual que con libcap-ng, el audit.spec de
# master ya dice "4.2.2" (versión en preparación, sin tag todavía). Si para
# cuando corras esto ya existe un 4.2.2 (u otro más nuevo) publicado de
# verdad en https://github.com/linux-audit/audit-userspace/releases, avisame
# y lo actualizo — este es, de todo el proyecto, el número de versión que
# menos pude confirmar con certeza total.
export AUDIT_VERSION="4.2.1"

# --- Fase 3 (cont.) — cryptsetup/LUKS2 con Argon2id -----------------------------
# Versiones confirmadas contra las páginas de BLFS (Beyond Linux From Scratch,
# el mismo linaje de proyecto que esta guía) el 2026-08-26 — son la fuente
# más confiable para versiones/flags de un build LFS-style, mejor que
# adivinar desde cero como con libcap-ng/audit-userspace:
#   json-c      0.19        — linuxfromscratch.org/blfs/.../json-c.html
#   popt        1.19        — linuxfromscratch.org/blfs/.../popt.html
#   LVM2        2.03.42     — linuxfromscratch.org/blfs/.../lvm2.html
#   cryptsetup  2.8.7       — linuxfromscratch.org/blfs/.../cryptsetup.html
# libargon2 no está en BLFS (cryptsetup lo trata como opcional, BLFS no lo
# usa) — se confirmó aparte contra el repo de PHC: no tiene un release
# nuevo desde 2019 (20190702), lo cual es normal: es la implementación de
# referencia del algoritmo ganador del Password Hashing Competition, ya
# congelada/estable.
export LIBARGON2_VERSION="20190702"
export POPT_VERSION="1.19"
export JSON_C_VERSION="0.19"
export LVM2_VERSION="2.03.42"
export CRYPTSETUP_VERSION="2.8.7"

# libaio: agregado 2026-08-26 tras un intento real de LVM2 — hace falta
# incluso para el subconjunto mínimo "device-mapper" (lib/bcache.c del
# propio LVM2 lo necesita, no sólo el daemon opcional dmeventd). Versión
# confirmada contra el índice real de releases.pagure.org/libaio/: la
# 0.3.113 (14/04/2022) es la más nueva publicada ahí, sin release más
# reciente desde entonces — normal para una librería tan chica y estable.
export LIBAIO_VERSION="0.3.113"

# --- Fase 3 (cont.) — SELinux (paso 12, último de la fase) -----------------------
# libsepol/libselinux/libsemanage/checkpolicy/policycoreutils vienen del MISMO
# repo (github.com/SELinuxProject/selinux), taggeados y publicados todos juntos
# bajo el mismo número de versión — no son proyectos independientes con
# versiones propias. Chequeado contra la página de releases real el 2026-08-26:
# último tag "3.11" (01/07/2026). Cada componente sí publica su propio tarball
# de release "de verdad" (con Makefile listo, no un archive de git crudo).
export SELINUX_VERSION="3.11"

# bzip2: NUEVA dependencia agregada acá — libsemanage linkea contra -lbz2
# (comprime/descomprime el store de políticas). El "bzip2" que ya estaba en
# el Dockerfile es sólo el binario del HOST para descomprimir tarballs .bz2
# de las fuentes (libmnl, por ejemplo) — no sirve para linkear, hace falta
# esta copia cross-compilada aparte, con libbz2.so instalado en el sysroot.
# Última versión estable: 1.0.8, sin release nuevo desde 2019 (proyecto
# congelado/estable, es normal). URL confirmada: es el mismo tarball que usa
# LFS/BLFS desde hace años.
export BZIP2_VERSION="1.0.8"

# PCRE2: NUEVA dependencia agregada acá — libselinux usa PCRE2 (no la regex
# POSIX de glibc) para matchear los patrones de file_contexts (USE_PCRE2=y
# es el default del proyecto, y la alternativa USE_PCRE2=n cae a la libpcre1
# vieja/discontinuada en vez de a algo sin dependencias — mejor compilar
# PCRE2 de una vez). Confirmada por búsqueda web el 2026-08-26 contra los
# releases reales de github.com/PCRE2Project/pcre2: la 10.47 (21/10/2025) es
# la última — un research anterior había asumido "10.48" sin verificar
# contra la página real de releases, que no existe; quedó corregido acá
# antes de escribir el script, no después de un 404 real.
export PCRE2_VERSION="10.47"

# --- Fase 4 ("Comunicaciones") ---------------------------------------------------
# zlib -> OpenSSL -> libcbor -> libfido2 -> Linux-PAM -> pam_u2f -> recompilar
# systemd con soporte de PAM/SELinux/LUKS/DNS-over-TLS/FIDO2 -> config estática
# de red. Todas las versiones verificadas por búsqueda web + fetch directo de
# la página de releases real (no de memoria) el 2026-08-27.
#
# zlib: BLFS y el propio proyecto coinciden en 1.3.2 como última estable. Su
# propio dominio (zlib.net) resultó bloqueado desde el research sandbox, pero
# el mismo tarball está republicado como asset de GitHub Release (verificado
# 200, mismo tamaño) — se usa esa URL para no depender de si zlib.net responde
# desde la red del usuario.
export ZLIB_VERSION="1.3.2"

# OpenSSL: CORREGIDO tras verificar contra la página real de releases de
# github.com/openssl/openssl — la 3.5.7 (que se había asumido antes de
# verificar) ya fue superada por la 3.5.8 (25/08/2026, dos días antes de
# escribir esto). El bug de "make install en paralelo corrompe los .so" no
# aparece documentado en el INSTALL.md de esta versión (puede ser folklore de
# la comunidad, no un bug confirmado por upstream) — se instala en serie
# igual (-j1) por las dudas, ya que el costo extra es insignificante.
export OPENSSL_VERSION="3.5.8"

# libcbor: 0.14.0 (18/07/2026). Sin tarball de "make dist" propio — sólo
# existe el archive/refs/tags crudo de GitHub, pero a diferencia de
# libcap-ng/audit-userspace esto SÍ alcanza sin autoreconf: es CMake puro
# (CMakeLists.txt ya está en el repo, no hay nada que generar).
export LIBCBOR_VERSION="0.14.0"

# libfido2: 1.17.0 (15/04/2026). Yubico publica un tarball de release real
# (no el archive crudo de GitHub) en developers.yubico.com — mismo dominio
# que ya usábamos para pam_u2f más abajo.
export LIBFIDO2_VERSION="1.17.0"

# Linux-PAM: 1.7.2. Desde ~1.6 el proyecto migró de autotools a Meson (mismo
# sistema que systemd) — el tarball de GitHub Release es el dist real
# (Linux-PAM-X.Y.Z.tar.xz, con nota explícita en el release de ignorar el
# "Source code" automático de GitHub).
export LINUX_PAM_VERSION="1.7.2"

# pam_u2f: 1.4.0 (25/03/2025, sigue siendo la última — confirmado porque el
# tab de Releases del repo de GitHub está vacío: Yubico sólo publica tarballs
# en su propio dominio, igual que libfido2).
export PAM_U2F_VERSION="1.4.0"

# libxcrypt: NUEVA dependencia agregada 2026-08-27 tras un error real de build
# (no anticipado en la investigación original de policycoreutils): glibc
# ${GLIBC_VERSION} ya no instala libcrypt.so/crypt.h (glibc lo removió a
# partir de la 2.38, delegando crypt(3) a una librería aparte) — el build
# real falló con "ld: cannot find -lcrypt" al linkear newrole/ (que cae a
# -lcrypt porque policycoreutils se compila con PAMH=n). libxcrypt es el
# reemplazo estándar. Verificado contra el release real de
# github.com/besser82/libxcrypt: el tag v4.5.2 (10/11/2025) es el último, con
# tarball de "make dist" de verdad (./configure ya generado, no un archive de
# git crudo) — confirmado bajando el tarball y corriendo
# ./configure+make+install nativo en este mismo contenedor antes de escribir
# el step, no a ciegas.
export LIBXCRYPT_VERSION="4.5.2"

# --- Fase 5 ("Infraestructura Autónoma") -----------------------------------------
# apk-tools: NUEVO hallazgo por research 2026-08-27 que cambia el plan original:
# desde la serie 3.0 apk-tools usa Meson, no el Makefile plano (el propio
# README del proyecto dice que el Makefile legacy "sólo sirve para targets
# musl-linux y se va a eliminar en el release 3.0"). Versión confirmada por
# fetch directo contra el archivo VERSION real del repo (no de memoria):
# "3.0.7" tanto en pkgs.alpinelinux.org (edge/main, build 28/07/2026) como en
# raw.githubusercontent.com/alpinelinux/apk-tools/master/VERSION.
export APK_TOOLS_VERSION="3.0.7"

# --- Fase 6 ("Interfaz Moderna"), parte 1: fundación no gráfica ------------------
# Wayland+Qt6+KDE es ENORME -- se parte en varios scripts. Esta primera parte
# cubre todo lo que hace falta ANTES de tocar Mesa/LLVM (los drivers gráficos,
# que van en su propio script por lo delicado que es cross-compilar LLVM) y
# antes de Qt6/KDE Frameworks (que van después de Mesa). Versiones
# confirmadas por fetch directo contra fuentes reales el 2026-08-27 (dos
# research pases: build systems verificados contra meson_options.txt/
# configure.ac reales vía mirrors de GitHub, no de memoria -- varios
# supuestos iniciales resultaron directamente incorrectos, ver comentarios
# puntuales en build-desktop.sh, ej. PipeWire NO tiene una opción
# "pipewire-pulseaudio", Wayland NO tiene "build-libwayland-server" separado).
#
# gitlab.freedesktop.org (donde vive el código real de dbus/polkit/wayland/
# wayland-protocols/libinput/pipewire/wireplumber/fontconfig) devolvió 403 en
# TODOS los intentos de verificación directa desde este sandbox -- mismo
# patrón que zlib.net/gitlab.alpinelinux.org en fases anteriores, no
# necesariamente algo de tu red real. Los ítems marcados "VERIFICAR" abajo
# usan la URL documentada por BLFS (el mismo linaje de proyecto que esta
# guía) o un mirror de GitHub cuando existe, pero no se pudieron confirmar
# con un 200 real -- si alguno da 404 en la build de verdad, avisame.
export LIBFFI_VERSION="3.6.0"
export EXPAT_VERSION="2.8.2"
export GLIB_VERSION="2.88.3"
export DBUS_VERSION="1.16.2"                # VERIFICAR: gitlab.fd.o bloqueado en el sandbox
export DUKTAPE_VERSION="2.7.0"               # VERIFICAR: duktape.org bloqueado en el sandbox; única dependencia dura de polkit para el motor de reglas JS
export LIBPNG_VERSION="1.6.58"
export POLKIT_VERSION="127"                  # VERIFICAR: tag-archive de GitHub, no un tarball de "make dist"
export FREETYPE_VERSION="2.14.3"
export HARFBUZZ_VERSION="14.4.0"
export FONTCONFIG_VERSION="2.18.3"           # VERIFICAR: gitlab.fd.o bloqueado en el sandbox
export PIXMAN_VERSION="0.46.4"
export CAIRO_VERSION="1.18.4"
export WAYLAND_VERSION="1.26.0"              # VERIFICAR: gitlab.fd.o bloqueado en el sandbox
export WAYLAND_PROTOCOLS_VERSION="1.49"      # VERIFICAR: gitlab.fd.o bloqueado en el sandbox
export MTDEV_VERSION="1.1.7"
export LIBEVDEV_VERSION="1.13.6"
export XKEYBOARD_CONFIG_VERSION="2.48"
export LIBINPUT_VERSION="1.31.3"             # VERIFICAR: gitlab.fd.o bloqueado en el sandbox
export LIBXKBCOMMON_VERSION="1.13.2"         # VERIFICAR: tag-archive de GitHub, no un tarball de "make dist"
export ALSA_LIB_VERSION="1.2.16.1"
export LUA_VERSION="5.4.8"
export PIPEWIRE_VERSION="1.6.8"              # VERIFICAR: gitlab.fd.o bloqueado en el sandbox
export WIREPLUMBER_VERSION="0.5.15"          # VERIFICAR: gitlab.fd.o bloqueado en el sandbox

# --- Fase 6 Parte 2 (Mesa + LLVM) ----------------------------------------------
export LIBDRM_VERSION="2.4.134"              # VERIFICAR: gitlab.fd.o bloqueado en el sandbox
# LLVM: único caso de este proyecto que NO es gitlab.fd.o -- release real de
# GitHub, confirmado contra la página de assets de la versión (LLVM dejó de
# publicar tarballs por-componente hace unas versiones; hoy sólo hay
# "llvm-project-X.Y.Z.src.tar.xz", el monorepo completo -- de ahí adentro se
# compila sólo "llvm/", ver build-mesa.sh).
export LLVM_VERSION="23.1.0"
export MESA_VERSION="26.2.1"                 # VERIFICAR: gitlab.fd.o bloqueado en el sandbox, tag "mesa-X.Y.Z" no confirmado en vivo
# glslang (agregado 2026-08-31 tras un error real de build): Mesa 26.2.1
# exige "glslang >= 12.2" para compilar shaders internos con
# glslangValidator, y el glslang-tools de Debian bookworm queda por debajo
# de ese piso -- mismo motivo que ya llevó a instalar meson/rust por fuera
# de apt (Fase 2). Acá en vez de pip se compila glslang de fuente, NATIVO
# (nunca corre en el sysroot final, sólo genera código en tiempo de build),
# igual que LLVM. Release real de GitHub (KhronosGroup/glslang no está en
# gitlab.fd.o), confirmado contra la página de releases en vivo.
export GLSLANG_VERSION="16.3.0"

# --- Fase 6 Parte 2 (cont.) — Clang + SPIRV-Tools + SPIRV-LLVM-Translator ------
# Agregado 2026-09-02, decisión explícita (Opción B de CONTEXTO_PENDIENTE_MESA.md,
# tomada en la PC de escritorio con 48GB de RAM): el build real de Mesa
# ${MESA_VERSION} con iris+intel_vk habilitados (RTX3060/RX7700/Intel del lab)
# activa "with_driver_using_cl" en el meson.build real de Mesa -- necesita
# compilar mesa-clc/intel_clc (compilador interno de OpenCL C -> SPIR-V que
# iris/anv usan para shaders internos). El error real ya visto en la sesión
# anterior ("Dependency 'LLVMSPIRVLib' not found") es sólo la PRIMERA de varias
# dependencias nuevas que hace falta agregar -- lo siguiente está confirmado
# leyendo el meson.build REAL de mesa-${MESA_VERSION} (extraído del propio
# mesa-${MESA_VERSION}.tar.gz ya descargado en sources/, no de un mirror
# desactualizado) en vez de asumir contra la documentación genérica de Mesa:
#
#   - dep_clang (línea ~2095 del meson.build real): NO usa
#     dependency('clang', method:'cmake') como en versiones viejas de Mesa --
#     usa cpp.find_library('clang-cpp', dirs: llvm_libdir) primero, y sólo si
#     eso falla (o si LLVM no es shared) cae a linkear ~15 librerías estáticas
#     de clang una por una. Como ya compilamos LLVM con -Dshared-llvm=enabled
#     (shared-llvm=ON en Mesa), alcanza con que exista libclang-cpp.so en el
#     sysroot -- no hace falta el binario `clang` ni sus herramientas, sólo
#     las librerías (LLVM_ENABLE_PROJECTS=clang alcanza, libclang-cpp.so se
#     construye solo en Linux, confirmado contra clang/tools/CMakeLists.txt
#     real de la tag llvmorg-${LLVM_VERSION}: la condición es sólo "UNIX AND
#     NOT CYGWIN", no depende de ningún flag extra).
#   - dep_spirv_tools (línea ~2084): SPIRV-Tools (>= 2024.1) es OBLIGATORIO
#     apenas with_clc=true -- esto NO estaba mencionado en
#     CONTEXTO_PENDIENTE_MESA.md (esa nota se escribió antes de poder leer el
#     meson.build real). Es un componente nuevo, no sólo Clang+libclc+SPIRV-LLVM-
#     Translator como se había anotado ahí.
#   - dep_clc (libclc externo, línea ~985): CONFIRMADO que NO hace falta para
#     nuestra selección de drivers. Sólo se resuelve
#     "if with_gallium_rusticl or with_microsoft_clc" -- ninguno de los dos
#     está en nuestro -Dgallium-drivers=iris,radeonsi,nouveau,llvmpipe /
#     -Dvulkan-drivers=amd,intel. with_clc=true igual (por iris/intel_vk vía
#     with_driver_using_cl), pero eso sólo obliga a LLVM+clang+SPIRV-Tools+
#     LLVMSPIRVLib -- nir_load_libclc.c (el código que de verdad usa libclc)
#     sólo se agrega al build "if dep_clc.found()", y dep_clc nunca se resuelve
#     en nuestro caso. Confirmado además en
#     src/compiler/clc/meson.build real (mismo tarball). Esto SIMPLIFICA la
#     Opción B tal como se había descrito: no hace falta cross-compilar libclc
#     (la parte más pesada y delicada de compilar bitcode LLVM por-target que
#     se había anticipado) -- un componente entero menos.
#
# SPIRV-Headers: no tiene versión propia (es sólo headers + gramática JSON de
# Khronos) -- cada proyecto que lo usa fija su propio commit exacto vía su
# DEPS/config. SPIRV-Tools y SPIRV-LLVM-Translator piden commits DISTINTOS
# (confirmado leyendo el DEPS real de SPIRV-Tools y el spirv-headers-tag.conf
# real de SPIRV-LLVM-Translator, no asumiendo que son intercambiables) -- por
# eso hay dos variables separadas, una por consumidor, en vez de una sola.
export SPIRV_HEADERS_FOR_TOOLS_COMMIT="29981f65241605e08b0ede4cfeb999fe3b723c6a"      # = tag vulkan-sdk-1.4.357.0, pin real del DEPS de SPIRV-Tools v2026.3
export SPIRV_HEADERS_FOR_TRANSLATOR_COMMIT="575b6512579ebde466ed3dfc04e413439d14d95d" # pin real de spirv-headers-tag.conf en la rama llvm_release_230

# SPIRV-Tools: el propio README dice "GitHub releases are deprecated" -- no hay
# tarball de "make dist", se usa el archive/refs/tags crudo (mismo patrón que
# libcap-ng/audit-userspace/libcbor/polkit/libxkbcommon en este proyecto).
# Versión confirmada por `git ls-remote --tags` en vivo contra el repo real
# (no de memoria): último tag real "v2026.3" (2026-09), sobra para el piso
# ">= 2024.1" que pide Mesa. CMake real de esta tag confirmado además:
# SPIRV_SKIP_EXECUTABLES=ON implica SPIRV_SKIP_TESTS=ON y evita necesitar
# googletest/effcee/re2/protobuf/abseil (sólo hacen falta para los tests) --
# sólo se compila la librería, que es todo lo que Mesa necesita.
export SPIRV_TOOLS_VERSION="2026.3"

# SPIRV-LLVM-Translator: NO usa un esquema de tags con fecha como SPIRV-Tools
# -- usa branches "llvm_release_XXX" (uno por versión mayor de LLVM), y el
# wiki de releases del repo está desactualizado (se dejó de mantener después
# de la v11). Confirmado por `git ls-remote --heads` en vivo: existe
# "llvm_release_230" (LLVM 23.x), y su CMakeLists.txt real fija
# BASE_LLVM_VERSION=23.1.0 -- coincide EXACTO con nuestro LLVM_VERSION, así
# que es la rama correcta, no una suposición por continuidad numérica. Se fija
# el commit exacto que esa rama tenía en el momento de este research (en vez
# de "la punta de la rama", que se puede mover) -- mismo criterio de
# reproducibilidad que el resto de este proyecto.
export SPIRV_LLVM_TRANSLATOR_COMMIT="c808623558686b7b285cabfa71542a93a5390f55" # HEAD de llvm_release_230 al momento de este research (2026-09-02)

# --- Rutas --------------------------------------------------------------------
export LFS="${LFS:-/lfs}"
export LFS_SOURCES="${LFS}/sources"
export LFS_TOOLS="${LFS}/tools"
export LFS_BUILD="${LFS}/build"
# Logs: agregado 2026-08-27 a pedido — bind mount nuevo (./logs:/lfs/logs en
# docker-compose.yml, a diferencia de /lfs/tools, /lfs/build, /lfs/usr, que
# son volúmenes con nombre de Podman, sin ruta directa en Windows) para que
# cada corrida quede guardada como archivo normal dentro de
# C:\Users\...\LINSIOS\linsi-os\logs\ — entrypoint.sh es quien arma el nombre
# del archivo y hace el tee, no cada script individual, así queda una sola
# vez para las cuatro fases (Fase 0 a 3) y para cualquier fase futura.
export LFS_LOGS="${LFS}/logs"

# --- Triplet del cross-compiler propio de LINSI-OS -----------------------------
export LFS_TGT="${LFS_TGT:-x86_64-linsi-linux-gnu}"

# --- PATH: el cross-toolchain recién compilado tiene prioridad -----------------
export PATH="${LFS_TOOLS}/bin:${PATH}"

# --- PATH (agregado Fase 6, 2026-08-27): binarios ya instalados en el sysroot --
# A partir de Fase 6 empiezan a aparecer herramientas que son A LA VEZ parte
# del sistema final Y necesarias en tiempo de BUILD para paquetes posteriores
# (wayland-scanner genera código a partir de los XML de wayland-protocols,
# glib-compile-resources/gdbus-codegen los va a pedir Qt6/KDE más adelante,
# etc.) -- el patrón "GLib necesita glib-genmarshal del BUILD machine" que
# describe la propia documentación de cross-compiling de Meson.
#
# CORREGIDO (2026-08-29) -- la idea original de este comentario era: "en un
# cross-compile real (arquitecturas distintas) esas herramientas del build
# machine se compilan aparte, nativas; acá no hace falta ese lío porque
# LFS_TGT es la MISMA arquitectura que el host (x86_64), así que el propio
# binario recién cross-compilado corre perfecto en este mismo contenedor".
# Un build real de wireplumber demostró que eso es FALSO en general: un
# binario cross-compilado (glib-compile-resources) SÍ se pudo ejecutar
# (misma arquitectura, el exec no falla), pero reventó al cargar sus
# librerías ("libgio-2.0.so.0: cannot open shared object file") porque
# están linkeadas contra el glibc CROSS-compilado de Fase 2, que vive en
# ${LFS_SYSROOT}, no contra el glibc real del contenedor -- y como nunca se
# chrootea a /lfs, el linker dinámico real del contenedor no las encuentra.
# Misma arquitectura no implica mismo glibc ni mismo entorno de carga; sólo
# funciona sin dramas para binarios que no dependen de librerías del propio
# sysroot (por eso wayland-scanner sí se resuelve, pero como build NATIVO
# aparte -- ver step_wayland() -- no ejecutando el cross-compilado).
#
# Esta entrada de PATH se deja igual (no molesta, y hace falta para que
# Meson encuentre herramientas del sysroot que si son seguras de ejecutar
# así), pero la lección es: si una herramienta de build falla con "error
# while loading shared libraries" al correr desde ${LFS_SYSROOT}/usr/bin, la
# solución NO es tocar LD_LIBRARY_PATH -- es conseguir una versión
# genuinamente nativa (paquete de apt, como libglib2.0-dev-bin, o un build
# nativo aparte, como wayland-scanner) que el PATH encuentre primero (por
# eso este PATH se agrega DESPUÉS de todo lo demás, ${LFS_TOOLS}/bin
# incluido: para que una alternativa nativa siempre gane si existe).
export PATH="${PATH}:${LFS_SYSROOT:-${LFS:-/lfs}}/usr/bin"

# --- Paralelismo de compilación ------------------------------------------------
# GCC pass1 (Fase 0) compila unidades pesadas —genautomata, c-family/c-common.cc,
# gimple-match-N.cc, generic-match-N.cc— que solas pueden pisar 1.5-2.5 GB de RAM
# cada una. Si se lanzan tantos jobs como cores (-j$(nproc)) pero la VM de
# Podman/Docker Desktop tiene poca RAM, el kernel mata esos procesos (OOM,
# "Killed signal terminated program cc1plus", exit 137) a mitad de compilación.
#
# Por eso el techo de jobs sale del mínimo entre nproc y (RAM disponible / 2GB),
# nunca menos de 1. Se puede pisar a mano si hace falta más o menos margen:
#   docker compose run --rm -e MAKEFLAGS=-j2 builder scripts/build-cross-toolchain.sh all
if [[ -z "${MAKEFLAGS:-}" ]]; then
    NPROC="$(nproc)"
    MEM_KB="$(awk '/MemAvailable/{print $2; exit} /MemTotal/{t=$2} END{if (!$0 && t) print t}' /proc/meminfo 2>/dev/null || echo 0)"
    [[ -z "${MEM_KB}" || "${MEM_KB}" -le 0 ]] && MEM_KB=2097152   # fallback: asumí 2GB si no se puede leer
    MEM_GB=$(( MEM_KB / 1024 / 1024 ))
    JOBS_BY_MEM=$(( MEM_GB / 2 ))
    if [[ "${JOBS_BY_MEM}" -lt 1 ]]; then
        JOBS_BY_MEM=1
    fi
    JOBS="${NPROC}"
    if [[ "${JOBS_BY_MEM}" -lt "${JOBS}" ]]; then
        JOBS="${JOBS_BY_MEM}"
    fi
    export MAKEFLAGS="-j${JOBS}"
    echo "[env] RAM disponible ~${MEM_GB}GB, ${NPROC} cores -> MAKEFLAGS=${MAKEFLAGS} (pisalo con -e MAKEFLAGS=-jN si hace falta)" >&2
else
    export MAKEFLAGS="${MAKEFLAGS}"
fi

# Mirrors de descarga (con fallback a GNU si el mirror falla)
export GNU_MIRROR="https://ftpmirror.gnu.org"
export KERNEL_MIRROR="https://cdn.kernel.org/pub/linux/kernel/v7.x"
export SYSTEMD_MIRROR="https://github.com/systemd/systemd/archive/refs/tags"
export ZSH_MIRROR="https://downloads.sourceforge.net/project/zsh/zsh"
export UTIL_LINUX_MIRROR="https://www.kernel.org/pub/linux/utils/util-linux/v${UTIL_LINUX_VERSION%.*}"
export LIBCAP_MIRROR="https://www.kernel.org/pub/linux/libs/security/linux-privs/libcap2"
export SAVANNAH_MIRROR="https://download-mirror.savannah.gnu.org/releases"
export UUTILS_MIRROR="https://github.com/uutils/coreutils/archive/refs/tags"
export LIBMNL_MIRROR="https://www.netfilter.org/projects/libmnl/files"
export LIBNFTNL_MIRROR="https://www.netfilter.org/projects/libnftnl/files"
export NFTABLES_MIRROR="https://www.netfilter.org/projects/nftables/files"
# CORREGIDO 2026-08-26: probé primero releases/download/vX.Y/<nombre>-X.Y.tar.gz
# asumiendo un tarball "de verdad" (con ./configure ya generado vía "make
# dist", como systemd/uutils NO hacen falta pero GNU/netfilter sí publican) —
# dio 404 en la build real del usuario. Confirmé después contra la propia
# página de assets de cada release (releases/expanded_assets/vX.Y) que NI
# libcap-ng NI audit-userspace suben un tarball propio: sólo existen los dos
# "Source code (zip/tar.gz)" que GitHub genera automático del propio tag, es
# decir, el archive/refs/tags crudo — mismo mecanismo que ya usamos para
# systemd y uutils. La diferencia importante es que ESE tarball NO trae un
# ./configure generado (a diferencia de libmnl/libnftnl/nftables, que sí
# publican un dist real): por eso step_libcap_ng()/step_audit() corren
# autoreconf antes de ./configure (ambos proyectos confirman en su propio
# README que así se construye desde fuente de git: libcap-ng con
# "./autogen.sh", audit-userspace con "autoreconf -f --install" — y el
# Dockerfile de Fase 0 ya tiene autoconf/automake/libtool instalados).
export LIBCAP_NG_MIRROR="https://github.com/stevegrubb/libcap-ng/archive/refs/tags"
export AUDIT_MIRROR="https://github.com/linux-audit/audit-userspace/archive/refs/tags"

# libargon2: igual que libcap-ng/audit-userspace, sólo existe el archive
# crudo de GitHub (no publica un tarball de "make dist") — pero a diferencia
# de esos dos, NO hace falta autoreconf: es un Makefile plano (CC=/PREFIX=/
# DESTDIR=), no autotools.
export LIBARGON2_MIRROR="https://github.com/P-H-C/phc-winner-argon2/archive/refs/tags"
# popt, LVM2 y cryptsetup sí publican tarballs de release "de verdad" (con
# ./configure ya generado) — mirrors confirmados contra BLFS.
export POPT_MIRROR="https://ftp.osuosl.org/pub/rpm/popt/releases/popt-1.x"
export LVM2_MIRROR="https://sourceware.org/ftp/lvm2"
export CRYPTSETUP_MIRROR="https://www.kernel.org/pub/linux/utils/cryptsetup/v${CRYPTSETUP_VERSION%.*}"
# json-c: CMake, no autotools — confirmado contra BLFS.
export JSON_C_MIRROR="https://s3.amazonaws.com/json-c_releases/releases"
# libaio: tarball de release real (con Makefile listo, no un archive de
# git) — confirmado contra el índice de releases.pagure.org/libaio/. A
# diferencia de casi todo el resto de este proyecto, su Makefile NO
# respeta DESTDIR (ver step_libaio en build-security.sh): prefix/
# includedir/libdir se pisan directo apuntando adentro del sysroot.
export LIBAIO_MIRROR="https://releases.pagure.org/libaio"

# SELinux: un solo mirror para los cinco componentes (mismo repo, mismo tag),
# assets reales de GitHub Release, no un archive/refs/tags crudo.
export SELINUX_MIRROR="https://github.com/SELinuxProject/selinux/releases/download/${SELINUX_VERSION}"

# bzip2: el mismo tarball "de toda la vida" que usa LFS/BLFS.
export BZIP2_MIRROR="https://sourceware.org/pub/bzip2"

# PCRE2: asset real de GitHub Release (tag "pcre2-X.Y", no sólo "X.Y").
export PCRE2_MIRROR="https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}"

# libxcrypt: asset real de GitHub Release (tag "vX.Y.Z").
export LIBXCRYPT_MIRROR="https://github.com/besser82/libxcrypt/releases/download/v${LIBXCRYPT_VERSION}"

# --- Fase 4 ("Comunicaciones") --------------------------------------------------
# zlib: mismo tarball, republicado como asset de GitHub Release (ver comentario
# de versión más arriba sobre por qué no se usa zlib.net directo).
export ZLIB_MIRROR="https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}"
# OpenSSL: asset real de GitHub Release (tag "openssl-X.Y.Z", no sólo "X.Y.Z").
export OPENSSL_MIRROR="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}"
# libcbor: sin dist propio — archive/refs/tags crudo (alcanza: es CMake puro,
# ver comentario de versión más arriba).
export LIBCBOR_MIRROR="https://github.com/PJK/libcbor/archive/refs/tags"
# libfido2: tarball de release real de Yubico (no el archive crudo de GitHub).
export LIBFIDO2_MIRROR="https://developers.yubico.com/libfido2/Releases"
# Linux-PAM: asset real de GitHub Release (tag "vX.Y.Z").
export LINUX_PAM_MIRROR="https://github.com/linux-pam/linux-pam/releases/download/v${LINUX_PAM_VERSION}"
# pam_u2f: tarball de release real de Yubico (el tab de Releases de GitHub
# está vacío para este proyecto).
export PAM_U2F_MIRROR="https://developers.yubico.com/pam-u2f/Releases"

# --- Fase 5 ("Infraestructura Autónoma") ----------------------------------------
# apk-tools: el repo canónico se mudó a gitlab.alpinelinux.org, pero ese host
# devolvió 403 al verificarlo en vivo desde este sandbox (bloqueo de red del
# propio sandbox de research, no necesariamente algo del build real -- mismo
# patrón que ya vimos con zlib.net). Se usa el mirror de sólo lectura de
# GitHub, mismo formato archive/refs/tags que systemd/uutils/libcbor en este
# mismo proyecto -- si "v${APK_TOOLS_VERSION}.tar.gz" da 404 en la build real,
# avisame y lo cambio a la URL de GitLab.
export APK_TOOLS_MIRROR="https://github.com/alpinelinux/apk-tools/archive/refs/tags"

# --- Fase 6, parte 1 -------------------------------------------------------------
export LIBFFI_MIRROR="https://github.com/libffi/libffi/releases/download/v${LIBFFI_VERSION}"
export EXPAT_MIRROR="https://github.com/libexpat/libexpat/releases/download/R_${EXPAT_VERSION//./_}"
# GNOME: convención "MAJOR.MINOR/nombre-VERSION.tar.xz", rama estable = minor par.
export GLIB_MIRROR="https://download.gnome.org/sources/glib/${GLIB_VERSION%.*}"
export DBUS_MIRROR="https://dbus.freedesktop.org/releases/dbus"
# Duktape: distribución "amalgamada" (un solo .c/.h) -- no se instala con
# make/autotools de terceros, build-desktop.sh lo compila directo con el
# cross-gcc (ver comentario largo en step_duktape).
export DUKTAPE_MIRROR="https://duktape.org"
export LIBPNG_MIRROR="https://downloads.sourceforge.net/libpng"
# polkit: sin tarball de "make dist" -- archive/refs/tags crudo de GitHub,
# mismo patrón que libcap-ng/audit-userspace/libcbor en fases anteriores.
export POLKIT_MIRROR="https://github.com/polkit-org/polkit/archive/refs/tags"
export FREETYPE_MIRROR="https://downloads.sourceforge.net/freetype"
export HARFBUZZ_MIRROR="https://github.com/harfbuzz/harfbuzz/releases/download/${HARFBUZZ_VERSION}"
# fontconfig: publica en el registro de paquetes genéricos de GitLab, no en
# una carpeta releases/ tradicional (confirmado contra BLFS).
export FONTCONFIG_MIRROR="https://gitlab.freedesktop.org/api/v4/projects/890/packages/generic/fontconfig/${FONTCONFIG_VERSION}"
export PIXMAN_MIRROR="https://www.cairographics.org/releases"
export CAIRO_MIRROR="https://www.cairographics.org/releases"
export WAYLAND_MIRROR="https://gitlab.freedesktop.org/wayland/wayland/-/releases/${WAYLAND_VERSION}/downloads"
export WAYLAND_PROTOCOLS_MIRROR="https://gitlab.freedesktop.org/wayland/wayland-protocols/-/releases/${WAYLAND_PROTOCOLS_VERSION}/downloads"
export MTDEV_MIRROR="https://bitmath.org/code/mtdev"
export LIBEVDEV_MIRROR="https://www.freedesktop.org/software/libevdev"
export XKEYBOARD_CONFIG_MIRROR="https://xorg.freedesktop.org/archive/individual/data/xkeyboard-config"
export LIBINPUT_MIRROR="https://gitlab.freedesktop.org/libinput/libinput/-/archive/${LIBINPUT_VERSION}"
# libxkbcommon: sin tarball de "make dist" -- archive/refs/tags crudo de GitHub.
export LIBXKBCOMMON_MIRROR="https://github.com/xkbcommon/libxkbcommon/archive/refs/tags"
export ALSA_LIB_MIRROR="https://www.alsa-project.org/files/pub/lib"
export LUA_MIRROR="https://www.lua.org/ftp"
export PIPEWIRE_MIRROR="https://gitlab.freedesktop.org/pipewire/pipewire/-/archive/${PIPEWIRE_VERSION}"
export WIREPLUMBER_MIRROR="https://gitlab.freedesktop.org/pipewire/wireplumber/-/archive/${WIREPLUMBER_VERSION}"
export LIBDRM_MIRROR="https://gitlab.freedesktop.org/mesa/libdrm/-/archive/libdrm-${LIBDRM_VERSION}"
# LLVM: release real de GitHub (no gitlab.fd.o) -- confirmado el nombre exacto
# del asset contra la página de la release llvmorg-${LLVM_VERSION}.
export LLVM_MIRROR="https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}"
export MESA_MIRROR="https://gitlab.freedesktop.org/mesa/mesa/-/archive/mesa-${MESA_VERSION}"
# glslang: release real de GitHub (KhronosGroup/glslang no está en
# gitlab.fd.o), mismo patrón de URL que LIBXKBCOMMON_MIRROR de más arriba.
export GLSLANG_MIRROR="https://github.com/KhronosGroup/glslang/archive/refs/tags"

# SPIRV-Headers: archive crudo por commit exacto (no hay tags propios que
# nos sirvan -- ver comentario largo de versión más arriba). GitHub arma el
# directorio del tarball como "SPIRV-Headers-<sha-completo>" -- confirmado
# por convención real de codeload.github.com para archives por commit (no
# por tag), igual que ya se documentó para otros archives crudos de este
# proyecto (libcbor, polkit, etc.) con tags en vez de shas.
export SPIRV_HEADERS_MIRROR="https://github.com/KhronosGroup/SPIRV-Headers/archive"
# SPIRV-Tools: archive/refs/tags crudo -- ver comentario de versión más
# arriba (README real: "GitHub releases are deprecated").
export SPIRV_TOOLS_MIRROR="https://github.com/KhronosGroup/SPIRV-Tools/archive/refs/tags"
# SPIRV-LLVM-Translator: archive crudo por commit exacto, mismo motivo que
# SPIRV-Headers -- fijamos un commit puntual de la rama llvm_release_230, no
# la rama en sí (que se mueve).
export SPIRV_LLVM_TRANSLATOR_MIRROR="https://github.com/KhronosGroup/SPIRV-LLVM-Translator/archive"

# --- Cargo (Fase 2, uutils) ----------------------------------------------------
# CARGO_HOME por default es ~/.cargo (home del usuario "linsi" dentro del
# contenedor), y ese directorio NO está en ningún volumen del compose — cada
# `podman compose run` es un contenedor efímero, así que sin esto cada intento
# de compilar uutils re-descargaría TODOS los crates de crates.io de cero
# (con la conexión que se corta seguido, un dolor de cabeza evitable). Se
# redirige sólo el caché de registry/config de Cargo a /lfs/build, que sí es
# un volumen persistente (linsios-build) — esto no toca dónde vive el propio
# toolchain de rustup (~/.rustup, ~/.cargo/bin), que ya quedó instalado
# adentro de la imagen en el Dockerfile y no necesita persistir por volumen.
export CARGO_HOME="${LFS_BUILD}/.cargo-home"

# --- Sysroot del sistema final (Fase 2 en adelante) ---------------------------
# Todo lo de espacio de usuario (glibc, systemd, zsh, uutils) se instala acá
# con --prefix=/usr + DESTDIR="${LFS}" — igual que las cabeceras del kernel en
# Fase 0 — para no chrootear: como el target es x86_64 igual que el host, los
# binarios se pueden probar corriéndolos directo contra su propio ld.so del
# sysroot (ver step_verify en build-userspace.sh), sin necesidad de chroot.
export LFS_SYSROOT="${LFS}"

# ------------------------------------------------------------------------------
# Verificación de integridad del tarball del kernel (sha256 contra LINUX_SHA256).
# La llaman tanto build-cross-toolchain.sh (Fase 0, cabeceras) como
# build-kernel.sh (Fase 1, build completo) sobre el mismo archivo.
# ------------------------------------------------------------------------------
verify_linux_tarball() {
    local tarball="${LFS_SOURCES}/linux-${LINUX_VERSION}.tar.xz"
    [[ -f "${tarball}" ]] || { echo "[env] no existe ${tarball}" >&2; return 1; }

    local got
    got="$(sha256sum "${tarball}" | awk '{print $1}')"
    if [[ "${got}" != "${LINUX_SHA256}" ]]; then
        echo "[env][error] sha256 de ${tarball} no coincide." >&2
        echo "  esperado: ${LINUX_SHA256}" >&2
        echo "  obtenido: ${got}" >&2
        echo "  Verificá el hash oficial en https://www.kernel.org/pub/linux/kernel/v7.x/sha256sums.asc" >&2
        echo "  antes de seguir — puede ser una descarga corrupta o el archivo equivocado." >&2
        return 1
    fi
    echo "[env] sha256 de linux-${LINUX_VERSION}.tar.xz verificado OK"
}

# ------------------------------------------------------------------------------
# glibc/systemd/zsh no publican un sha256sums.txt plano (se firman por GPG, no
# por hash). En vez de fijar un hash que no puedo respaldar, esto calcula el
# sha256 real del tarball ya descargado y lo deja bien visible en el log para
# que lo compares a mano contra la fuente oficial si querés esa garantía.
# ------------------------------------------------------------------------------
log_sha256() {
    local tarball="$1"
    [[ -f "${tarball}" ]] || { echo "[env] no existe ${tarball}" >&2; return 1; }
    local got
    got="$(sha256sum "${tarball}" | awk '{print $1}')"
    echo "[env] sha256 de $(basename "${tarball}"): ${got}"
}
