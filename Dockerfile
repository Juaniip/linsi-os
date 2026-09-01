# ==============================================================================
# LINSI-OS · Fase 0 — "El Taller"
# ------------------------------------------------------------------------------
# Entorno de construcción aislado y reproducible para no heredar dependencias
# del host. Aquí se compila el cross-toolchain (Binutils + GCC) y las
# cabeceras de Linux que luego se usan para forjar el resto de LINSI-OS
# (kernel, espacio de usuario, ISO) completamente desde cero.
# ==============================================================================
FROM debian:bookworm-slim

LABEL org.opencontainers.image.title="linsios-builder" \
      org.opencontainers.image.description="Entorno Fase 0 de LINSI-OS: cross-toolchain, kernel y empaquetado de ISO" \
      maintainer="Laboratorio LINSI"

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# ------------------------------------------------------------------------------
# Reintentos automáticos de apt: con una conexión que corta cada tanto (WiFi
# inestable, proxy que interrumpe descargas largas), un solo timeout tira
# abajo toda la capa. Con esto, un corte corto se resuelve solo reintentando
# esa descarga puntual en vez de matar el `apt-get install` completo.
# ------------------------------------------------------------------------------
RUN echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/80-retries \
    && echo 'Acquire::http::Timeout "30";' >> /etc/apt/apt.conf.d/80-retries \
    && echo 'Acquire::https::Timeout "30";' >> /etc/apt/apt.conf.d/80-retries

# ------------------------------------------------------------------------------
# El 403 Forbidden a deb.debian.org por HTTP es consistente e inmediato en
# todos los intentos — no es un corte intermitente, es un bloqueo real del
# puerto 80 hacia ese host en esta red (router/ISP/antivirus). El puerto 443
# sí conecta. Por eso hay que pasar TODO a HTTPS, incluido el primer paquete
# (ca-certificates) — pero ese primero es un huevo-y-gallina: *-slim no trae
# ca-certificates preinstalado, así que apt todavía no tiene con qué validar
# NINGÚN certificado HTTPS. Se resuelve bajando la verificación de
# certificado sólo para ese paquete puntual (la conexión igual va cifrada
# por TLS, sólo se salta la validación de la cadena de confianza), y se saca
# ese permiso enseguida — todo lo que se instale después ya valida
# certificados con normalidad.
# ------------------------------------------------------------------------------
RUN find /etc/apt -type f \( -name 'sources.list' -o -name '*.sources' \) \
        -exec sed -i 's|http://deb\.debian\.org|https://deb.debian.org|g' {} + \
    && echo 'Acquire::https::Verify-Peer "false";' > /etc/apt/apt.conf.d/99-bootstrap-insecure \
    && apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -f /etc/apt/apt.conf.d/99-bootstrap-insecure \
    && rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------------------------
# Paquetes base del host de compilación, partidos en varias capas a propósito
# (no por prolijidad — es para resistir cortes de red). Cada RUN es una capa
# de Docker/Podman independiente: si se corta la conexión en la capa 3, las
# capas 1 y 2 ya descargadas quedan cacheadas y `podman compose build` sólo
# reintenta desde donde se cortó, no desde cero.
#   1) Toolchain estándar tipo LFS (build-essential, bison, flex, gawk, m4,
#      texinfo, gperf, autotools) para poder compilar Binutils/GCC desde fuente.
#   2) Cabeceras y librerías que Binutils/GCC/Kernel necesitan (ncurses, ssl,
#      elf, zlib) + Python.
#   3) Herramientas de red/archivo y utilidades varias.
#   4) Empaquetado de ISO (Fase 8), instalado ya en esta capa para no
#      reconstruir la imagen más adelante.
#   5) Clang/LLD como toolchain alternativo (la guía menciona "Binutils, GCC/Clang").
#   6) gettext (agregado 2026-08-27 tras un error real de build): msgfmt hace
#      falta para compilar los catálogos de traducción (po/*.po -> *.mo) de
#      policycoreutils (Fase 3) — sin este paquete el build fallaba con
#      "msgfmt: No such file or directory". Es de esperar que haga falta de
#      nuevo más adelante (cualquier paquete con soporte NLS/po/ lo pide),
#      así que va acá con el resto del toolchain base en vez de agregarlo
#      recién cuando vuelva a romper.
#   7) libexpat1-dev (agregado 2026-08-29 tras un error real de build, Fase 6):
#      wayland necesita compilar wayland-scanner dos veces -- una para el
#      TARGET (cross) y otra NATIVA, para el propio contenedor, porque Meson
#      exige un wayland-scanner que corra YA, durante el build, para generar
#      código de los protocolos (no alcanza con el que se cross-compila en la
#      misma pasada). Esa build nativa necesita expat de verdad instalado acá
#      -- sin este paquete, "meson setup" del wayland-scanner nativo falla con
#      "Dependency 'expat' not found". Ver el comentario largo en
#      step_wayland() de scripts/build-desktop.sh para el detalle completo.
#   8) libglib2.0-bin + libglib2.0-dev-bin (agregado 2026-08-29 tras un error
#      real de build, Fase 6, wireplumber): a diferencia de wayland-scanner,
#      acá el problema NO era que faltara compilar una versión nativa aparte
#      -- ya existía en PATH un glib-compile-resources, pero era el
#      CROSS-compilado en ${LFS_SYSROOT}/usr/bin (Meson lo encuentra ahí
#      porque env.sh agrega ese directorio al PATH). Al ejecutarlo directo
#      (sin chroot) tira "error while loading shared libraries:
#      libgio-2.0.so.0: cannot open shared object file" -- son librerías de
#      OTRO glibc (el cross-compilado en Fase 2), y aunque la arquitectura es
#      la misma (x86_64), mezclar ese binario con el linker dinámico real del
#      contenedor es undefined behavior, no algo para parchear con
#      LD_LIBRARY_PATH. La solución real es la misma que con wayland-scanner:
#      un binario NATIVO de verdad. Acá alcanza con instalarlo de apt en vez
#      de compilarlo -- son las herramientas de glib-compile-resources/
#      gdbus-codegen (libglib2.0-dev-bin) y glib-compile-schemas
#      (libglib2.0-bin), que Qt6/KDE (Fase 6 Parte 3) también va a necesitar
#      más adelante (GSettings). Ver el comentario largo en
#      step_wireplumber() de scripts/build-desktop.sh.
#   9) patchelf (agregado 2026-08-30 tras un error real de build, Fase 6
#      Parte 2, LLVM): llvm-config se compila NATIVO (con el gcc del propio
#      contenedor) para que sea ejecutable, pero configurado con
#      -DCMAKE_INSTALL_PREFIX apuntando al sysroot para que reporte las
#      rutas correctas de Mesa (--includedir, --libdir, etc.). El problema:
#      LLVM compila sus herramientas con un RPATH relativo
#      ("$ORIGIN/../lib", a propósito, para que el tooling de LLVM sea
#      relocalizable) -- y al copiar ese binario nativo a
#      ${LFS_SYSROOT}/usr/bin/llvm-config, ese RPATH relativo pasa a
#      apuntar a ${LFS_SYSROOT}/usr/lib, que es la carpeta de librerías del
#      SYSROOT (glibc cross-compilada de Fase 2, no la del contenedor).
#      Resultado real: "symbol lookup error: .../libc.so.6: undefined
#      symbol: __pointer_chk_guard, version GLIBC_PRIVATE" -- el mismo tipo
#      de mezcla-de-glibc-por-RPATH ya visto con glib-compile-resources,
#      pero al revés (acá el binario SÍ es nativo; lo que está mal es a qué
#      librerías apunta por culpa de dónde lo copiamos). patchelf permite
#      reescribir el RPATH del binario ya copiado para que apunte al
#      directorio de build nativo de LLVM (que sí tiene una libLLVM
#      compatible con el contenedor), sin tocar las rutas que reporta
#      llvm-config (esas quedan grabadas en el binario en tiempo de
#      compilación vía CMAKE_INSTALL_PREFIX, independientes del RPATH). Ver
#      el comentario largo en step_llvm() de scripts/build-mesa.sh.
#   10) glslang-tools (agregado 2026-08-31 tras un error real de build, Fase
#      6 Parte 2, Mesa): Mesa usa glslangValidator en tiempo de build para
#      compilar shaders internos (GLSL -> SPIR-V, para cosas como el Vulkan
#      overlay layer y helpers de meta-ops) -- "Program 'glslangValidator'
#      not found or not executable". CORRECCIÓN (mismo día, error
#      siguiente): el de apt SÍ se encuentra pero es de 2022 y Mesa exige
#      >=12.2 -- terminó compilándose de fuente NATIVO en build-mesa.sh
#      (step_glslang_native(), ver comentario ahí). Este paquete se deja
#      instalado igual (no molesta, sirve como fallback/dev tooling) pero
#      ya no es el que Mesa termina usando.
#   11) python3-mako (agregado 2026-08-31 tras un error real de build, Fase
#      6 Parte 2, Mesa): Mesa genera muchísimo código fuente (tablas de
#      formato, marshalling, etc.) con plantillas Mako en tiempo de build,
#      y lo valida con un chequeo de Python bastante enredado que Meson
#      resume como "ERROR: Python >= 3.10 not found" -- un mensaje
#      ENGAÑOSO: Python 3.11.2 estaba perfecto (>=3.10), lo que en
#      realidad fallaba era "import mako" dentro del script de chequeo
#      (confirmado leyendo el meson-log.txt real, no sólo la salida
#      resumida de la terminal -- el mismo patrón raro ya documentado en
#      issues reales de meson: el error que se imprime no siempre es el
#      motivo real). python3-mako de Debian alcanza de sobra acá -- Mesa
#      sólo pide mako >=0.8.0 (de 2013), un piso bajísimo, nada que ver
#      con los pisos de versión que sí nos obligaron a compilar de fuente
#      (meson, glslang).
# ------------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        bison \
        flex \
        gawk \
        m4 \
        texinfo \
        help2man \
        gperf \
        autoconf \
        automake \
        libtool \
        pkg-config \
        patch \
        rsync \
        cpio \
        bc \
        file \
        kmod \
        gettext \
        libexpat1-dev \
        libglib2.0-bin \
        libglib2.0-dev-bin \
        patchelf \
        glslang-tools \
        python3-mako \
    && rm -rf /var/lib/apt/lists/*

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 \
        python3-pip \
        libncurses-dev \
        libssl-dev \
        libelf-dev \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

RUN apt-get update && apt-get install -y --no-install-recommends \
        xz-utils \
        bzip2 \
        unzip \
        wget \
        curl \
        git \
        sudo \
        vim \
    && rm -rf /var/lib/apt/lists/*

RUN apt-get update && apt-get install -y --no-install-recommends \
        squashfs-tools \
        xorriso \
        grub-pc-bin \
        grub-efi-amd64-bin \
        mtools \
        dosfstools \
    && rm -rf /var/lib/apt/lists/*

RUN apt-get update && apt-get install -y --no-install-recommends \
        clang \
        lld \
    && rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------------------------
# CMake (Fase 3, json-c): primer paquete del proyecto que no usa autotools ni
# Meson sino CMake puro. json-c (para el metadata JSON de LUKS2, dependencia
# de cryptsetup) sólo se compila con esto.
# ------------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        cmake \
    && rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------------------------
# systemd (Fase 2) usa Meson+Ninja, no autotools — y genera bastante código C a
# partir de plantillas Jinja2 en tiempo de build (unit files, tablas de
# syscalls, etc.), de ahí python3-jinja2. El meson de bookworm alcanza el piso
# que pide systemd 261 (>=0.62.0 según su meson.build), pero para no depender
# de qué tan nueva sea la versión empaquetada en Debian en el momento en que
# esto se construya, se instala la última de PyPI con pip — así queda
# garantizado por encima de ese piso sin tener que andar comprobando versiones
# de apt cada vez.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ninja-build \
        python3-jinja2 \
    && rm -rf /var/lib/apt/lists/* \
    && pip3 install --break-system-packages --no-cache-dir "meson>=1.3"

# ------------------------------------------------------------------------------
# Usuario no privilegiado: el cross-toolchain y todo lo que compilemos NUNCA
# se construye como root (evita contaminar rutas del sistema y refleja cómo
# se hace en un build LFS real).
# ------------------------------------------------------------------------------
ARG BUILD_UID=1000
ARG BUILD_GID=1000
RUN groupadd -g ${BUILD_GID} linsi \
    && useradd -m -u ${BUILD_UID} -g ${BUILD_GID} -s /bin/bash linsi \
    && echo "linsi ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers \
    && mkdir -p /lfs/sources /lfs/tools /lfs/build /lfs/usr /lfs/boot \
    && chown -R linsi:linsi /lfs

WORKDIR /lfs
COPY --chown=linsi:linsi scripts/ /lfs/scripts/
RUN chmod +x /lfs/scripts/*.sh

USER linsi

# ------------------------------------------------------------------------------
# Rust (Fase 2, uutils): se instala como el usuario "linsi" (no root), vía
# rustup, con el mismo criterio que meson por pip más arriba — la última
# stable disponible, sin depender de qué tan vieja sea la de apt (Debian
# bookworm ni siquiera trae rustc/cargo en esta imagen). Perfil "minimal":
# sólo rustc+cargo+std del HOST (x86_64-unknown-linux-gnu) — no hace falta
# "rustup target add" para el target propio de LINSI-OS
# (x86_64-linsi-linux-gnu): no es un target conocido de rustup, así que
# build-userspace.sh lo cruza distinto (ver step_uutils) usando el linker
# del cross-toolchain propio en vez de agregar un target de rustup.
# --profile minimal se salta rustfmt/clippy/rust-docs, que no hacen falta acá.
# ------------------------------------------------------------------------------
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
        --profile minimal \
        --default-toolchain stable \
    && rm -rf "${HOME}/.rustup/tmp" "${HOME}/.rustup/downloads"

# LFS = raíz del "taller". LFS_TGT = triplet del cross-compiler propio de
# LINSI-OS (permite distinguirlo de un GCC del host en cualquier `file`/`gcc -v`).
# /usr/local/bin va ANTES que /usr/bin: ahí es donde pip3 deja los ejecutables
# (meson, en particular) al instalar con --break-system-packages en Debian —
# sin esto en el PATH, "meson: command not found" aunque el paquete esté
# instalado y el pip install haya corrido bien durante el build de la imagen.
# /home/linsi/.cargo/bin es donde rustup deja los shims de cargo/rustc.
ENV LFS=/lfs \
    LFS_TGT=x86_64-linsi-linux-gnu \
    PATH=/lfs/tools/bin:/home/linsi/.cargo/bin:/usr/local/bin:/usr/bin:/bin

ENTRYPOINT ["/lfs/scripts/entrypoint.sh"]
CMD ["bash"]
