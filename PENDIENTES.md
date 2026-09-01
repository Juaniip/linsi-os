# LINSI-OS — Pendientes y deuda técnica

Registro vivo de lo que quedó abierto, sin confirmar, o pospuesto a propósito.
No existía este archivo hasta ahora — esto es la primera versión, armada
repasando todo lo hecho desde que empezamos. Lo voy actualizando a medida que
se resuelve o aparece algo nuevo.

## Fases 0 a 4 — estado real (repasado a fondo, no de memoria)

Fui a mirar directo los logs que hay guardados en tu carpeta para no
contestar de memoria. Resultado:

- **Fase 0 (cross-toolchain) y Fase 1 (kernel):** no hay un log dedicado sólo
  a Binutils/GCC pass 1 sueltos, pero `kernel-rebuild.log` (en la raíz de
  `linsi-os/`) es en realidad la corrida completa de `build-kernel.sh`, y
  termina con **todas** las opciones de hardening en `[OK]` (Lockdown, KASLR,
  IOMMU, BTRFS, EFI stub, SELinux, audit, nf_tables, dm-crypt, AES-NI) y el
  mensaje final `Fase 1 completa: kernel endurecido en /lfs/boot, módulos en
  /lfs/lib/modules`. Como compilar el kernel ya usa el cross-compiler de Fase
  0, esto confirma las dos fases juntas, aunque no haya un log con el nombre
  "toolchain" suelto. **No es deuda pendiente, sólo no está guardado bajo un
  nombre obvio** — lo aclaro para que sepas dónde mirar si alguna vez lo
  necesitás.
- **Fase 2 (Espacio de Usuario — glibc, libstdc++, binutils2, gcc2,
  attr/acl/libcap/util-linux, systemd, ncurses, uutils, zsh):** acá sí hay un
  hueco real. Sólo encontré log de **zsh** (`zsh-build.log`/`verify-zsh.log`)
  — nada de glibc, gcc2, systemd (el de esta fase), ncurses ni uutils tiene
  un log propio guardado. Todo indica que funcionó bien (Fase 3 y Fase 4 se
  construyen encima de ese mismo glibc/gcc2/systemd y están confirmadas), así
  que es más una laguna de *registro* que de *funcionamiento* — pero si algún
  día algo raro pasa en Fase 7/8 y no se entiende por qué, este es el primer
  lugar sin cobertura directa a revisar.
- **Fase 3 (Seguridad/SELinux):** bien cubierta — encontré log de build+verify
  para prácticamente cada uno de los 19 pasos (libmnl, libnftnl, nftables,
  libcap-ng, auditd, libargon2, popt, json-c, libaio, lvm2, cryptsetup, y el
  resto de SELinux junto en `fase3-selinux.log`). Nada pendiente acá.
- **Fase 4 (Comunicaciones):** 100% confirmada en la sesión anterior, log real
  con los 9 pasos + verifies en verde.

## Fase 5 — Infraestructura Autónoma

- **`build-infra.sh` (apk-tools + firma) nunca se confirmó.** Se entregó,
  `bash -n` limpio, pero no hay un log real ni un "listo" tuyo específico para
  este script. Puede haber corrido bien en algún momento sin que lo
  mencionaras — conviene correrlo (`scripts/build-infra.sh all`) y confirmar.
- **Raspberry Pi: `setup-repo-server.sh` sin confirmar ejecutado.** Te di la
  guía paso a paso por SSH, pero no hay confirmación de que hayas corrido el
  script en la Pi ni de que nginx haya quedado sirviendo en el puerto 8088.
- **Cloudflare Tunnel: `cloudflared-ingress-snippet.yml` sin confirmar
  mergeado.** No sé si ya agregaste esa regla a tu `config.yml` real del túnel
  ni si corriste `cloudflared tunnel route dns`.
- **Placeholder en `/etc/apk/repositories` dentro del sysroot.** Tiene un TODO
  con el hostname real pendiente — se actualiza recién cuando el repo de la Pi
  esté confirmado andando de verdad desde afuera (`curl -I
  https://tu-hostname/edge/main/x86_64/` devolviendo 200).
- **`.github/workflows/lint-scripts.yml` rechazado al escribir.** Las
  herramientas remotas no pueden tocar `.github/` (protección esperada) — te
  lo entregué en el chat, pendiente que lo copies vos a mano a
  `linsi-os\.github\workflows\lint-scripts.yml`.
- **CI/CD: pausado por decisión mutua, no resuelto.** Quedó sin definir qué
  runner usar (GitHub hosteado vs. self-hosted en tu PC o en la Pi). Ver la
  respuesta a tu pregunta de si hace falta tener la PC prendida 24/7, al final
  de este archivo.

## Fase 6 — Parte 1 (fundación no gráfica) — ✅ COMPLETA (confirmada 2026-08-29)

**Confirmado con log real, `build-desktop.sh all` de punta a punta sin
errores:** D-Bus/polkit, fuentes/2D (freetype/harfbuzz/fontconfig/pixman/
cairo), Wayland + wayland-protocols, entrada (mtdev/libevdev/
xkeyboard-config/libinput/libxkbcommon) y audio (alsa-lib/lua/pipewire/
wireplumber) — todo instalado y verificado en el sysroot. El log completo
de la corrida que cerró la fase es
`logs/20260829-200453_build-desktop_all.log`.

Quedó un detalle chico para revisar más adelante, no bloqueante ahora:

- **Rutas systemd de wireplumber con `/lfs` duplicado.** El log muestra
  `Installing .../wireplumber.service to /lfs/lfs/usr/lib/systemd/user`
  (doble `/lfs`) en vez de `/lfs/usr/lib/systemd/user`. Probablemente la
  variable `systemduserunitdir` que wireplumber saca de `systemd.pc` ya
  viene con un `/lfs` de más desde cómo se configuró systemd en Fase 2, y
  al sumarle `DESTDIR=/lfs` queda duplicado. No rompe nada ahora (sysroot
  monolítico, sin booteo real todavía), pero si no se corrige antes de
  Fase 7/8, el `.service` de wireplumber va a terminar en el lugar
  equivocado cuando `/lfs` sea la raíz real. Vale la pena revisarlo cuando
  se llegue a empaquetar/bootear de verdad — no hace falta pararse a
  arreglarlo ahora.

Todo lo de abajo queda como registro histórico de los bugs reales que
aparecieron y cómo se resolvieron, por si algo parecido vuelve a pasar en
las Partes 2/3.

- **Bugs reales corregidos:** libffi (multilib →
  `--disable-multi-os-directory`), dbus (opción de meson inexistente
  `-Dsystemdsystemunitdir`), fontconfig (autotools → Meson por el bug de
  `va_copy` en cross-compiling), wayland (scanner nativo de bootstrap +
  `libexpat1-dev` agregado al Dockerfile), wayland-protocols (mismo problema
  del scanner nativo — la mitigación con `PKG_CONFIG_PATH` no alcanzó, hizo
  falta un `--native-file` explícito de Meson; ver el mecanismo compartido
  `write_meson_nativefile()` / `WAYLAND_SCANNER_NATIVE_PREFIX` en el script),
  y dos falsos positivos propios de verify (no bugs de build real):
  - `step_verify_wayland_protocols()` buscaba el `.pc` en `lib/pkgconfig`,
    pero Meson lo instala en `share/pkgconfig` para paquetes sin código
    compilado. Corregido también en el cross-file compartido, para que
    futuros pasos que necesiten `.pc` de ese tipo no tengan el mismo
    problema.
  - `step_verify_xkeyboard_config()` (2026-08-29) buscaba
    `/usr/share/X11/xkb/rules/base.xml`, pero `/usr/share/X11/xkb` se
    instala como **symlink absoluto** a `/usr/share/xkeyboard-config-2`. Como
    el proyecto nunca chrootea a `/lfs`, ese symlink resuelve contra la raíz
    real del contenedor y no contra el sysroot — da falso negativo aunque el
    build salió bien. Corregido para verificar directo
    `.../usr/share/xkeyboard-config-2/rules/base.xml`, sin pasar por el
    symlink.
- **libxkbcommon pedía libxml2 real (2026-08-29):** con
  `-Denable-xkbregistry=true` el build tira `Dependency "libxml-2.0" not
  found` — y libxml2 no está compilado en ningún lado del proyecto todavía.
  El núcleo de libxkbcommon (compilar keymaps, protocolo xkb de Wayland) NO
  necesita xkbregistry — esa API opcional es sólo para listar layouts
  disponibles (la usan selectores de teclado de un DE, ej. kxkbcommon en
  KDE). **Decisión:** se puso `-Denable-xkbregistry=false` por ahora, en vez
  de meter un `step_libxml2()` nuevo a mitad de Fase 6 Parte 1 sin
  necesitarlo todavía. **Queda pendiente para cuando arranque la Parte 3
  (Qt6/KDE):** agregar `step_libxml2()` cross-compilado (Meson) y volver a
  poner `-Denable-xkbregistry=true` — para entonces sí hace falta (kwin/System
  Settings necesitan listar layouts).
- **libxkbcommon, segunda vuelta (2026-08-29): mismo bug del scanner nativo
  que ya tuvimos con wayland y wayland-protocols.** Con
  `-Denable-wayland=true`, las herramientas `xkbcli ... wayland` piden un
  wayland-scanner NATIVO (`Build-time dependency wayland-scanner found: NO`)
  aparte de wayland-client/wayland-protocols del sysroot cruzado (esos dos sí
  se encontraban bien). Van tres paquetes seguidos con el mismo problema —
  cada vez que algo genera código a partir de XMLs de protocolo Wayland
  durante un build cruzado, hace falta el scanner nativo. **Fix:** se le
  agregó `--native-file` reusando `write_meson_nativefile()` /
  `WAYLAND_SCANNER_NATIVE_PREFIX`, igual que en los otros dos. Si el mismo
  error vuelve a aparecer en pipewire o wireplumber (ver "riesgo conocido"
  abajo), es el mismo fix de siempre: agregar `--native-file`.
- **Riesgo conocido, no confirmado:** pipewire/wireplumber (o pasos futuros de
  Mesa/Qt6) todavía podrían pedir el mismo "wayland-scanner nativo" que ya le
  hizo falta a wayland y wayland-protocols. Si tira el mismo error
  ("Dependency wayland-scanner not found"), el fix ya está listo para
  reusar: agregarle a ese paso `--native-file="${nativefile}"` con
  `write_meson_nativefile()`, como se hizo en los otros dos.
- **Lección general para los pasos que faltan:** ya van dos veces que un
  verify propio da falso positivo por asumir una convención de instalación
  de Meson que no era la real (`.pc` en `share/` en vez de `lib/`; symlink
  absoluto que no se puede seguir sin chroot). Antes de confiar en un `die`
  de verify, conviene mirar las líneas reales de `Installing ...` en el log
  del paso — no asumir la ruta "de manual" sin chequearla.
- **wireplumber pedía glib-compile-resources NATIVO de verdad (2026-08-29,
  variante nueva del mismo problema de fondo):** a diferencia de
  wayland-scanner (donde no existía ningún glib-compile-resources y hacía
  falta compilar uno native aparte), acá sí había uno en el PATH — pero era
  el CROSS-compilado en `${LFS_SYSROOT}/usr/bin` (Meson lo encuentra porque
  `env.sh` agrega ese directorio al PATH, al final). Al ejecutarlo sin
  chroot: `error while loading shared libraries: libgio-2.0.so.0: cannot
  open shared object file`. Es un binario linkeado contra el glibc
  CROSS-compilado de Fase 2, no contra el glibc real del contenedor —
  **misma arquitectura (x86_64) NO implica que un binario del sysroot se
  pueda ejecutar así de directo**; sólo funciona si no depende de librerías
  propias del sysroot (por eso pkg-config, que es del host, sí funciona
  bien; wayland-scanner necesitó su propio build nativo aparte). **Fix:**
  se instalaron `libglib2.0-bin` + `libglib2.0-dev-bin` de apt en el
  Dockerfile (mismo patrón que `libexpat1-dev` para wayland-scanner, pero
  acá alcanza con el paquete de Debian en vez de compilar desde cero) — el
  PATH ya prioriza `/usr/bin` (real) por sobre `${LFS_SYSROOT}/usr/bin`
  (agregado al final), así que una vez reconstruida la imagen Meson
  encuentra el nativo primero. **Corregido también el comentario en
  `env.sh`** que afirmaba (de forma ahora comprobada falsa) que "el binario
  cross-compilado corre perfecto en este mismo contenedor" sólo por ser la
  misma arquitectura — dejaba una trampa documentada para el próximo
  paquete de glib que hiciera falta (gdbus-codegen, glib-compile-schemas,
  que Qt6/KDE va a pedir).
- **wireplumber, tercera vuelta (2026-08-29): el mismo problema de fondo,
  variante todavía distinta.** Después del fix de glib-compile-resources, el
  build llegó a compilar TODO el código de wireplumber (wpctl, wpexec, el
  daemon, todos los módulos) y sólo falló en el último paso: generar
  `po/conf.pot`, que invoca `spa-json-dump` (herramienta chica y propia de
  PipeWire, sin paquete de Debian) sobre `wireplumber.conf`. El binario
  CROSS-compilado en `${LFS_SYSROOT}/usr/bin` tira `GLIBC_2.38' not found` —
  esta vez no es una librería faltante como con libgio, es un choque de
  VERSIÓN del propio glibc (el cross-compilado en Fase 2 es más nuevo que el
  de Debian bookworm del contenedor). **Fix:** en vez de otro paquete de apt
  (no existe uno para esta herramienta) o de LD_LIBRARY_PATH (más frágil
  todavía, mezclaría dos glibc distintos), se compila un `spa-json-dump`
  genuinamente NATIVO con un `gcc` directo (ni siquiera hace falta Meson acá
  -- confirmado contra el `meson.build`/`.c` reales de PipeWire que esta
  herramienta sólo necesita headers de SPA, sin nada para linkear), y se le
  pisa a Meson el binario vía `--native-file` (`[binaries] spa-json-dump =
  '...'`) en vez de dejar que lo encuentre solo por PATH. Ver
  `build_native_spa_json_dump()` en el script.
- **Bug propio (no de PipeWire/Meson) en el fix anterior, encontrado en la
  siguiente corrida (2026-08-29):** `build_native_spa_json_dump()` hacía
  `cd "${LFS_SOURCES}"` para bajar/extraer pipewire y nunca volvía al
  directorio del que la llamaban. Como `step_wireplumber()` ya había hecho
  `cd "${src}"` (el propio directorio fuente de wireplumber) antes de
  llamarla, el `meson setup` de wireplumber terminaba corriendo con el cwd
  equivocado (`/lfs/sources`) y tiraba `"Neither source directory ... nor
  build directory None contain a build file meson.build"` — ni siquiera
  llegaba a intentar compilar nada. **Corregido:** la función ahora guarda
  el cwd del que la llama al entrar y lo restaura antes de salir, pase lo
  que pase. Lección para cualquier helper nuevo que haga falta más adelante:
  si hace `cd` adentro, tiene que devolver el directorio como lo encontró.
- **spa-json-dump, segundo intento fallido (2026-08-29): el --native-file NO
  alcanzó, quedó exactamente el mismo error.** Investigando el
  `po/meson.build` real de wireplumber apareció el motivo: llama a
  `find_program('spa-json-dump', required: false)` SIN `native: true`. Sin
  ese kwarg, Meson resuelve el programa contra el `[binaries]` del CROSS
  FILE (lo que Meson llama "host machine" en su terminología invertida), NO
  contra el del native file -- ese sólo se consulta cuando el propio
  `find_program()` pide `native: true` explícito. Pisarlo en el nativefile
  no hacía nada; wireplumber seguía cayendo al fallback de PATH del cross
  file y volvía a agarrar el cross-compilado de siempre. **Fix real:**
  mover el override al `[binaries]` del cross-file (`write_meson_crossfile()`
  ahora acepta un segundo parámetro opcional `extra_binaries` para esto) --
  ya no hace falta `--native-file` en `step_wireplumber()`, sólo el
  cross-file de siempre con el binario nativo pisado adentro.
- **Lección para la lista de "riesgo conocido" de abajo:** no alcanza con
  saber "esto necesita un binario nativo" -- también hay que fijarse CÓMO lo
  busca el proyecto consumidor (`find_program()` con o sin `native: true`,
  `dependency()`, una variable de pkg-config, un path hardcodeado). El
  mecanismo de override correcto depende de eso, y adivinarlo (probar
  primero con --native-file porque fue lo que funcionó con
  wayland/wayland-protocols) puede no alcanzar, como pasó acá.
- **Patrón que se repite y conviene tener presente para lo que falta (Mesa,
  Qt6/KDE):** "misma arquitectura" (x86_64 cross == x86_64 host) NO
  garantiza que un binario cross-compilado se pueda ejecutar directo sin
  chroot. Van tres casos reales distintos de esto en Fase 6 Parte 1: (1)
  wayland-scanner -- ni existía nativo, hubo que compilar uno aparte; (2)
  glib-compile-resources -- existía pero le faltaban librerías (glibc
  cross-compilado, no el del contenedor); (3) spa-json-dump -- existía,
  encontraba sus librerías, pero pedía símbolos de una versión de glibc más
  nueva que la del contenedor. Los tres se resuelven igual: conseguir un
  binario NATIVO de verdad (apt si hay paquete, compilarlo aparte si no) y
  asegurarse de que Meson lo use en vez del cross-compilado (--native-file o
  PATH bien ordenado) -- nunca parchear con variables de entorno tipo
  LD_LIBRARY_PATH.
- **Flags de Meson dejados en default a propósito** en `step_dbus()` y
  `step_wayland_protocols()` — no pude confirmar esos nombres exactos contra
  el `meson_options.txt` real de esas versiones puntuales, y preferí no
  arriesgar un "Unknown option" adivinando. Si falta alguna funcionalidad más
  adelante, revisar ahí primero.

## Fase 6 — Parte 2 (Mesa + LLVM, drivers gráficos) — 🟡 script escrito, SIN CORRER TODAVÍA (2026-08-29)

- **Script nuevo:** `scripts/build-mesa.sh` (independiente de
  `build-desktop.sh`, mismo patrón de siempre: se basta a sí mismo, no
  sourcea otros scripts de fase). Targets: `libdrm`, `verify-libdrm`,
  `llvm-native`, `llvm`, `verify-llvm`, `mesa`, `verify-mesa`, `all`.
- **Alcance de hardware, confirmado por vos:** el laboratorio tiene máquinas
  mixtas (Nvidia RTX 3060, AMD RX 7700, gráfica integrada Intel, "etc"), o
  sea que no se puede asumir una sola marca — el driver stack tiene que
  cubrir las tres.
- **Decisiones de drivers tomadas** (confirmadas contra el
  `meson_options.txt` real de Mesa, vía el mirror de GitHub porque
  `gitlab.freedesktop.org` está bloqueado por robots.txt en este sandbox):
  - `gallium-drivers = iris,radeonsi,nouveau,swrast` → iris (Intel), radeonsi
    (AMD OpenGL), nouveau (Nvidia open-source), swrast (fallback por
    software si no hay GPU soportada).
  - `vulkan-drivers = amd,intel` → RADV (AMD) y ANV (Intel). **Nvidia/nouveau
    todavía no tiene una opción de Vulkan en Mesa** (no existe NVK como
    opción de build estable en esta versión), así que en la 3060 vamos a
    tener OpenGL vía nouveau pero no Vulkan nativo por ahora — es una
    limitación real de Mesa, no algo que nos falte compilar.
  - LLVM se compila con `LLVM_TARGETS_TO_BUILD="X86;AMDGPU"` — hace falta
    como librería para radeonsi/RADV y como motor del fallback por software
    (llvmpipe), aunque no estemos compilando Clang.
- **Quedó deliberadamente afuera de esta primera pasada** (no es que se
  olvidó, es scope recortado a propósito):
  - **Vulkan por software (lavapipe / `vulkan-drivers=swrast`)** — confirmado
    contra una guía real de GLFS que esto necesita un build completo de
    Clang (no sólo las librerías de LLVM), y eso es mucho más scope. Si algún
    día hace falta correr apps Vulkan sin GPU compatible, es la próxima
    pieza a agregar.
  - **VA-API / VDPAU** (aceleración de video) — necesitan libva/libvdpau, que
    todavía no están compilados.
  - **glvnd** (selector de driver GL multi-vendor) — sólo hace falta si en
    algún momento se suma un driver propietario de Nvidia además de nouveau.
  - **NVK** (el driver Vulkan nativo que Nvidia/Mesa están desarrollando para
    su propia GPU) — todavía no es una opción de build estable en la versión
    de Mesa que estamos usando.
- **La parte más delicada / menos verificada de todo el proyecto hasta
  ahora: cómo se resuelve `llvm-config` dentro del sysroot.** LLVM se
  compila dos veces: una nativa (sólo para sacar `llvm-tblgen` y
  `llvm-config` utilizables dentro del contenedor) y otra cross (la que
  termina en el sysroot). El problema es el mismo que ya vimos tres veces en
  Parte 1 (wayland-scanner, glib-compile-resources, spa-json-dump): un
  binario cross-compilado para x86_64 no anda necesariamente en el
  contenedor aunque sea "la misma arquitectura", porque la glibc no es la
  misma. La solución acá es: compilar `llvm-config` NATIVO pero configurado
  con el prefix real del sysroot (`${LFS_SYSROOT}/usr`), y al final del
  build cross de LLVM, pisar el `llvm-config` cross-compilado (roto) con ese
  binario nativo. `step_verify_llvm()` corre ese `llvm-config` ya pisado y
  chequea que `--includedir` devuelva una ruta que empiece con el sysroot —
  si eso falla, el problema está ahí, no en Mesa. **Esto no se pudo probar
  contra un build real todavía — es la apuesta de diseño más incierta de
  todo el proyecto y hay que estar atento a esa verificación específica.**
- **Cómo correrlo:** `podman-compose run --rm builder scripts/build-mesa.sh
  all`. A diferencia del fix de glib-compile-resources en Parte 1, **esta
  vez no hizo falta tocar el Dockerfile**, así que no hace falta
  `podman-compose build` antes — el contenedor ya tiene todo lo necesario.
  Es totalmente esperable que este paso necesite una o más vueltas de
  ida y vuelta con errores reales, igual que pasó con wayland-scanner en
  Parte 1.
- **Bug propio encontrado y corregido antes de entregar el script:** el
  array de flags de CMake para LLVM tenía
  `-DLLVM_TARGETS_TO_BUILD=X86;AMDGPU` sin comillas — el `;` sin comillas
  corta el comando en bash (síntoma: `syntax error near unexpected token
  ';'`). Se corrigió comillando todo el flag:
  `"-DLLVM_TARGETS_TO_BUILD=X86;AMDGPU"`. Confirmado con `bash -n` antes de
  entregarlo.
- **Primer error real (2026-08-29), ya corregido: `libdrm_intel.so` faltante
  frenaba `step_verify_libdrm()`.** Log real:
  `Run-time dependency pciaccess found: NO` → meson desactiva sola la
  compilación de `intel/` dentro de libdrm (no hace falta pciaccess salvo
  para eso), y el script moría en la verificación siguiente porque yo había
  puesto `libdrm_intel` en la lista de "obligatorios" sin chequear si
  realmente hacía falta. Investigado contra el `meson.build` real de `iris`
  en Mesa: **iris sólo depende de `libdrm` genérico, nunca de
  `libdrm_intel`/`intel_bufmgr`** — eso es exclusivo del driver clásico
  i965/crocus (pre-Gen8, no lo usamos) y de la DDX de X11 xf86-video-intel
  (no aplica, este proyecto es Wayland puro). Como no hace falta, no tiene
  sentido cross-compilar libpciaccess sólo para tenerlo — sería scope
  creep sin beneficio real, mismo criterio que ya se usó para dejar afuera
  lavapipe/VA-API/glvnd. Se corrigió `step_verify_libdrm()` para tratar
  `libdrm_intel.so` como informativo (no frena el build) y se corrigió el
  comentario de la Parte 1 de este bloque, que decía (mal) que las
  cabeceras por-vendor "se instalan solas sin flags extra".
- **Segundo error real (2026-08-30), ya corregido — justo la parte que ya
  había avisado como más incierta de todo el proyecto: `llvm-config`
  reventaba al ejecutarlo.** Log real:
  `/lfs/usr/bin/llvm-config: symbol lookup error:
  /lfs/usr/bin/../lib/libc.so.6: undefined symbol: __pointer_chk_guard,
  version GLIBC_PRIVATE`. Investigado a fondo contra el código real de LLVM
  (llvm-config.cpp y el historial de AddLLVM.cmake en llvm/llvm-project):
  el prefix SÍ quedaba bien grabado en el binario (eso funcionaba), pero
  LLVM compila su tooling con un RPATH relativo a propósito
  (`$ORIGIN/../lib`, para que sea relocalizable) — y al copiar el
  `llvm-config` nativo a `${LFS_SYSROOT}/usr/bin/`, ese RPATH relativo pasó
  a apuntar a `${LFS_SYSROOT}/usr/lib`, la carpeta de librerías del
  SYSROOT (la glibc cruzada de Fase 2), no la del contenedor. Es la cuarta
  vuelta del mismo problema de fondo de toda Fase 6 (mezclar binario y
  glibc de mundos distintos aunque sea "la misma arquitectura"), pero acá
  el binario en sí SÍ era nativo — lo que estaba mal era a qué librerías
  terminaba apuntando por culpa de dónde lo copiamos. Se corrigió
  reescribiendo el RPATH del binario ya copiado con **patchelf**
  (`patchelf --set-rpath "${LLVM_NATIVE_BUILD}/lib" .../llvm-config`), que
  apunta al build nativo de LLVM (con su propia libLLVM.so compatible) sin
  tocar las rutas que reporta `llvm-config` (esas están grabadas aparte, en
  tiempo de compilación, y ya estaban bien). **Esto agregó `patchelf` al
  Dockerfile (apt, capa de paquetes base) — hace falta `podman-compose
  build` antes de volver a correr `build-mesa.sh`, a diferencia del fix de
  libdrm de más arriba.**
- **Tercer error real (2026-08-30), ya corregido: `-Dgallium-drivers=...,
  swrast` no es un choice válido en Mesa 26.2.1.** Log real: `ERROR: Value
  "swrast" for option "gallium-drivers" is not in allowed choices: "all,
  auto, asahi, crocus, d3d12, ethosu, etnaviv, freedreno, i915, iris, lima,
  llvmpipe, nouveau, panfrost, r300, r600, radeonsi, rocket, softpipe,
  svga, tegra, v3d, vc4, virgl, zink"`. "swrast" era el nombre viejo de la
  opción en versiones antiguas de Mesa; hoy está separada en `llvmpipe`
  (software con JIT de LLVM, la que realmente queríamos, ya que compilamos
  LLVM justo para esto) y `softpipe` (software puro, sin LLVM). Se corrigió
  a `-Dgallium-drivers=iris,radeonsi,nouveau,llvmpipe`. Importante: el
  archivo `.so` que termina instalado sigue llamándose `swrast_dri.so`
  igual que antes (confirmado contra el `meson.build` real del target dri
  de Mesa) — por eso `step_verify_mesa()` NO cambió, sigue buscando
  `swrast_dri.so`, eso no era el bug. Nota aparte: `vulkan-drivers=swrast`
  (para lavapipe, ya fuera de scope) es una opción DIFERENTE que si sigue
  llamándose así — no confundir los dos namespaces.
  No hizo falta tocar el Dockerfile para este fix.
- **Cuarto error real (2026-08-30), ya corregido: `-Dgallium-vdpau=disabled`
  ya no es un option válido en Mesa 26.2.1.** Log real: `ERROR: Unknown
  option: "gallium-vdpau"`. A diferencia del error de `swrast` (que era un
  rename), este es una eliminación lisa y llana: Mesa upstream sacó el
  soporte nativo de VDPAU de Gallium (confirmado contra un reporte de bug
  real de Gentoo, "gallium-vdpau option removed from upstream" — no hay
  ningún nombre nuevo al que migrar, la funcionalidad ya no está). Como
  VDPAU/VA-API ya estaban fuera de scope de este primer pase (ver arriba,
  necesitan libva/libvdpau que no compilamos), la opción simplemente se
  sacó del comando de `meson setup` en vez de "dejarla en disabled" — no
  hay nada que deshabilitar si la opción no existe. `-Dgallium-va=disabled`
  sí se mantuvo (esa opción todavía existe y el build real la aceptó sin
  problema). De paso se corrigió un warning real no fatal en el mismo log
  (`DEPRECATION: Option "gles2" value 'true' is replaced by 'enabled'`):
  `-Dgles2=true` → `-Dgles2=enabled`.
  No hizo falta tocar el Dockerfile para este fix tampoco.
- **Quinto error real (2026-08-30), ya corregido: `-Dosmesa=false` tampoco
  es un option válido en Mesa 26.2.1.** Log real: `ERROR: Unknown option:
  "osmesa"`. Mismo patrón exacto que `gallium-vdpau`: OSMesa (renderizado
  3D off-screen, sin display/GPU real) fue eliminado de Mesa upstream, no
  renombrado (confirmado por reportes reales de otros proyectos afectados,
  ej. conda-forge/mesalib-feedstock issue "OSMesa removed upstream from
  Mesa project"). Como este proyecto nunca lo necesitó (siempre hay GPU
  real o llvmpipe de fallback, nunca off-screen puro) y ya lo queríamos en
  `false`, sacar la flag no cambia nada — se sacó del comando de `meson
  setup` igual que gallium-vdpau. No hizo falta tocar el Dockerfile.
  **Patrón que se repite:** de los 5 errores reales de Fase 6 Parte 2 hasta
  ahora, 3 fueron opciones de Meson de Mesa que cambiaron de nombre o
  desaparecieron entre la versión que yo tenía en mente al escribir el
  script y la 26.2.1 real (swrast→llvmpipe, gallium-vdpau eliminada, osmesa
  eliminada) — nada de esto se puede prevenir de antemano sin acceso al
  `meson_options.txt` real de esa versión exacta (gitlab.fd.o bloqueado en
  el sandbox); el patrón de "correr, leer el error real, corregir" sigue
  siendo el único camino confiable acá.
- **Sexto error real (2026-08-31), ya corregido, distinto a los anteriores:
  falta `glslangValidator` en el contenedor.** Log real: `Program
  'glslangValidator' not found or not executable`. Mesa lo usa en tiempo de
  build para compilar shaders internos (GLSL -> SPIR-V). A diferencia de
  los cinco errores anteriores (todos sobre nombres/existencia de opciones
  de Meson), este es una herramienta nativa que directamente faltaba
  instalar -- pero, a diferencia de wayland-scanner o llvm-config, es el
  caso SIMPLE: glslangValidator sólo genera código en tiempo de build,
  nunca corre en el sysroot final, así que no hace falta cross-compilar
  nada ni pisar binarios ni tocar RPATH -- alcanza con el paquete de apt
  `glslang-tools` (confirmado que existe en Debian bookworm). Se agregó al
  Dockerfile (con su propio comentario numerado, ítem 10) y se agregó un
  chequeo defensivo en `step_mesa()` (`command -v glslangValidator`) que
  avisa claro si falta, en vez de dejar que Meson tire el error genérico.
  **Esto sí requiere `podman-compose build` antes de reintentar** (a
  diferencia de los fixes de swrast/vdpau/osmesa de más arriba, que sólo
  tocaban el script).
- **CORRECCIÓN al error anterior + séptimo error real (2026-08-31): el
  glslang-tools de apt SÍ se encuentra, pero es DEMASIADO VIEJO.** Log
  real: `ERROR: Problem encountered: glslang >= 12.2 is required.` — con
  `Program glslangValidator found: YES (/usr/bin/glslangValidator)`
  confirmando que sí lo encontró, sólo que la versión no alcanza. Debian
  bookworm quedó congelado en una versión de glslang de 2022; Mesa 26.2.1
  (mucho más nueva) pide algo más reciente. Mismo motivo de fondo que ya
  llevó a instalar meson por pip y Rust por rustup en vez de apt (Fase 2:
  "no depender de qué tan vieja sea la de apt") — pero acá no hay
  pip/rustup equivalente para glslang, así que se compila de fuente,
  NATIVO, con CMake+Ninja (mismo patrón que LLVM, pero mucho más simple:
  glslangValidator sólo genera código en tiempo de build, nunca corre en
  el sysroot final, así que no hace falta nada de lo que hizo delicado a
  LLVM -- ni dos etapas, ni RPATH, ni prefix apuntando al sysroot).
  `-DENABLE_OPT=OFF` evita necesitar SPIRV-Tools como dependencia externa
  (confirmado contra el CMakeLists.txt real de glslang). Se agregó
  `step_glslang_native()` (target nuevo `glslang-native`) a
  `build-mesa.sh`, y `step_mesa()` ahora pisa `glslangValidator` vía
  `extra_binaries` del cross-file (mismo mecanismo ya probado con
  spa-json-dump en build-desktop.sh) para que Mesa use el compilado nuevo
  en vez del de apt. El paquete `glslang-tools` de apt se deja instalado
  igual (no molesta, y puede servir para otra cosa más adelante) pero ya
  no es lo que Mesa termina usando. Agregado a `env.sh`:
  `GLSLANG_VERSION="16.3.0"` (release real de GitHub, KhronosGroup/glslang
  no está en gitlab.fd.o) y `GLSLANG_MIRROR`. No hizo falta tocar el
  Dockerfile para este fix (glslang se compila con las mismas herramientas
  nativas -- cmake, ninja, gcc -- que ya estaban instaladas para LLVM).
- **Octavo error real (2026-09-01), ya corregido: el glslangValidator nativo
  recién compilado NO se usó -- Mesa siguió encontrando el de apt.** Log
  real: `Program glslangValidator found: YES (/usr/bin/glslangValidator)`
  seguido otra vez de `ERROR: glslang >= 12.2 is required` -- confirmando
  que el glslangValidator nuevo (compilado en el paso anterior) SÍ existe y
  funciona, pero el override que le pusimos a `write_meson_crossfile()`
  (mismo mecanismo que funcionó con spa-json-dump en build-desktop.sh) no
  tuvo efecto acá. A diferencia de spa-json-dump -- donde confirmamos
  leyendo el `po/meson.build` REAL de wireplumber que su `find_program()`
  no usa `native: true`, por eso el cross-file era el lugar correcto --
  esta vez no se pudo confirmar en vivo si el `find_program('glslangValidator')`
  de Mesa 26.2.1 usa `native: true` o no (dos fuentes de un mismo mirror de
  GitHub se contradijeron entre sí y con el comportamiento real). En vez de
  seguir adivinando cuál mecanismo usa Mesa, se pisó el binario en LOS DOS
  archivos a la vez -- `write_meson_crossfile()` Y `write_meson_nativefile()`
  -- con el mismo `extra_binaries`. No cuesta nada extra y cubre cualquiera
  de los dos caminos que Meson termine tomando. No hizo falta tocar el
  Dockerfile.
- **Noveno error real (2026-08-31/09-01), ya corregido -- el mensaje de
  error era ENGAÑOSO.** Con glslangValidator ya resuelto, el siguiente
  error fue `meson.build:1136:2: ERROR: Problem encountered: Python >= 3.10
  not found`, a pesar de que el mismo log mostraba
  `Program python3.11 found: YES 3.11.2` -- ¡3.11.2 sí es >= 3.10! El texto
  resumido de la terminal no alcanzaba para entender qué pasaba, así que
  esta vez pedí el `meson-log.txt` completo en vez de seguir adivinando
  (`podman-compose run --rm builder bash -c "tail -100
  /lfs/build/mesa-mesa-26.2.1/build/meson-logs/meson-log.txt"` -- ese
  archivo vive adentro del volumen de Podman, no se puede leer directo
  desde afuera). Ahí se vio el comando real que Meson corre para validar
  cada candidato de Python:
  ```
  python3.11 -c '... try: import mako \n except: sys.exit(1) ...'
  ```
  Ese `import mako` fallaba (el módulo no está instalado) -- Mesa genera
  gran parte de su código fuente con plantillas Mako en tiempo de build, y
  Meson resume CUALQUIER falla de esa validación combinada
  (versión+módulos) con el mismo mensaje genérico de versión, sin
  mencionar que en realidad era el módulo el que faltaba. Mismo patrón ya
  documentado como un problema conocido de Meson (issue real de
  mesonbuild/meson sobre mensajes de detección de Python engañosos). Se
  agregó `python3-mako` al Dockerfile (ítem 11) -- acá SÍ alcanza con apt
  sin drama de versión, Mesa sólo pide mako >=0.8.0 (de 2013), un piso
  bajísimo a diferencia de meson/glslang. **Esto sí requiere
  `podman-compose build` antes de reintentar.**
  **Lección para la próxima vez que un error no tenga sentido:** pedir el
  `meson-log.txt` completo (o el log equivalente de la herramienta que
  esté fallando) ANTES de ponerse a investigar con búsquedas web sobre el
  código fuente del proyecto -- tiene el comando exacto que se corrió y su
  salida real, mucho más confiable que reconstruir la lógica leyendo
  mirrors de GitHub que pueden no coincidir con la versión exacta en uso.
- **Décimo error real (2026-09-01), ya corregido -- mismo mensaje engañoso
  que el noveno, pero otra causa distinta.** Después de reconstruir la
  imagen con `python3-mako` (ítem 11), volvió a salir el mismo
  `meson.build:1136:2: ERROR: Problem encountered: Python >= 3.10 not
  found` con `python3.11` encontrado igual. Como ya habíamos visto que este
  mensaje puede tapar cualquier cosa, fui directo al `meson-log.txt`
  completo de nuevo en vez de asumir que era mako otra vez. El log mostró
  que el chequeo de mako ahora SÍ pasaba, pero el siguiente paso del mismo
  script (`python3 -c 'import yaml'`) fallaba con
  `ModuleNotFoundError: No module named 'yaml'` -- Mesa también usa PyYAML
  en tiempo de build (genera código de tablas de formato/extensiones desde
  YAML). Se agregó `python3-yaml` al Dockerfile (ítem 12), mismo patrón que
  mako: apt alcanza sin drama de versión. **Requiere `podman-compose
  build` antes de reintentar.**
  **Confirma la lección del error anterior:** un mismo mensaje resumido de
  Meson puede esconder más de una causa real distinta en pasos sucesivos —
  conviene revisar el `meson-log.txt` de nuevo cada vez que el mensaje
  resumido no cierre, en vez de asumir que es la misma causa ya conocida.

## Fase 6 — Parte 3 (no empezada)

- **Parte 3 — Qt6 + KDE Frameworks/kwin/plasma-workspace + tema oscuro/Nerd
  Fonts desde `/etc/skel/`:** no empezada, depende de la Parte 2. **Ya
  sabemos que va a necesitar libxml2** (ver más arriba, libxkbcommon
  compilado en Parte 1 sin xkbregistry por esto mismo) — cross-compilarlo y
  reactivar `-Denable-xkbregistry=true` en `step_libxkbcommon()` es un
  prerequisito de esta parte, no algo nuevo a descubrir ahí.

## Infraestructura de build

- **Docker Desktop reemplazado por `podman-compose`** (2026-08-29) — Docker
  Desktop no arrancaba en tu máquina, así que se sacó la dependencia por
  completo. De acá en más usá `podman-compose` (con guion) para todo, no
  `docker-compose.exe` ni `podman compose` (sin guion).
- **Versionado con git inicializado recién ahora (2026-09-01)** — hasta este
  punto todo el trabajo (Fases 0 a 6 Parte 2, con todos los fixes de Mesa
  incluidos) se venía escribiendo directo en tu carpeta sin ningún repo git
  atrás — ni un commit. Se armó recién: `git init -b main`, un `.gitignore`
  que excluye `sources/` (~765MB de tarballs de upstream, se re-descargan
  solos con `fetch()`) y `logs/`/`*.log` (se regeneran en cada build), y un
  commit inicial (`ff27b17`) con las 23 fuentes reales del proyecto
  (Dockerfile, docker-compose.yml, todos los scripts de fase, env.sh,
  este mismo archivo, los READMEs de fase y el workflow de `.github`).
  El repo queda **local únicamente** — el push a GitHub lo hace Juani
  directamente, no yo. De acá en adelante, cada fix real de build (como los
  9 de Mesa+LLVM de esta sesión) debería ir en su propio commit chico en vez
  de acumularse todo suelto — así el historial queda útil para volver atrás
  si algo se rompe.

## Decisiones ya tomadas (no son deuda, quedan acá como referencia)

- **Empaquetado:** sysroot monolítico hasta el final de Fase 6. Recién en
  Fase 7/8 se arma `.apk` real por paquete.
- **CI/CD — respuesta pendiente que nunca te di:** "¿si te doy mi PC de
  escritorio [como runner self-hosted], tengo que tenerla prendida 24/7?" —
  No, no hace falta. Un runner self-hosted sólo necesita estar *online* en el
  momento en que querés que corra un job: si hacés push con la PC apagada, el
  job de GitHub Actions queda en cola esperando, sin fallar, hasta que
  prendas la PC y el servicio del runner se reconecte. La única desventaja es
  que no tenés feedback de CI hasta ese momento. (Esto sigue sin resolver la
  discusión de fondo: la Pi es ARM64 y el build es x86_64, así que un runner
  en la Pi necesitaría QEMU y sería mucho más lento — la PC de escritorio no
  tiene ese problema por ser la misma arquitectura.)
