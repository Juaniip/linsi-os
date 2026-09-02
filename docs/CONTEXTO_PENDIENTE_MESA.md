# Contexto que faltaba volcar a PENDIENTES.md — Mesa, error LLVMSPIRVLib

Esto es lo único que quedó "solo en el chat" y todavía no está escrito en
ningún archivo del proyecto. Pegar como sección nueva dentro de
"Fase 6 — Parte 2" en `PENDIENTES.md`, o pasárselo tal cual a la tarea nueva
para que lo agregue.

## Duodécimo error real (2026-09-01/02), SIN RESOLVER TODAVÍA — decisión pendiente

Con `llvm-config` ya resuelto (declarado en el cross-file), Mesa avanzó
mucho más en el configure y falló en:

```
llvm-config found: YES (/lfs/usr/bin/llvm-config) 23.1.0
Run-time dependency LLVM (...) found: YES 23.1.0
Run-time dependency llvmspirvlib found: NO  (tried pkg-config)
meson.build:2078:21: ERROR: Dependency "LLVMSPIRVLib" not found (tried pkg-config)
```

**Causa raíz confirmada** (contra el `meson.build` real de Mesa, vía Fossies,
y contra un spec real de Fedora que lista las dependencias de build):

Mesa exige compilar `mesa-clc`/`intel_clc` (un compilador interno de OpenCL C
a SPIR-V que iris y anv usan para shaders/kernels internos) cuando cualquiera
de estos drivers está habilitado — es la variable `with_driver_using_cl` en
`meson.build`:

```
with_driver_using_cl = [
  with_gallium_iris, with_gallium_crocus, with_intel_vk, with_intel_hasvk,
  with_gallium_asahi, with_asahi_vk, with_tools.contains('asahi'),
  with_gallium_panfrost, with_panfrost_vk,
  with_nouveau_vk, with_imagination_vk, with_kosmickrisp_vk,
].contains(true)
```

**En nuestra config actual (`gallium-drivers=iris,radeonsi,nouveau,llvmpipe`,
`vulkan-drivers=amd,intel`), los ÚNICOS dos que están en esa lista son
`iris` y `intel_vk` (anv).** radeonsi, nouveau (gallium, no nouveau_vk),
llvmpipe y amd/radv NO necesitan nada de esto — compilan sin problema.

Para satisfacer esto hace falta, además de LLVM (que ya tenemos):
1. **Clang completo** (no alcanza con las librerías de LLVM que ya
   compilamos — confirmado contra un spec real de Fedora para Mesa, que
   lista `clang-devel` como BuildRequires explícito, no solo `llvm-devel`).
   Nuestro LLVM se compiló con `-DLLVM_ENABLE_PROJECTS=` vacío (sin clang),
   así que habría que agregar `clang` a esa lista y recompilar.
2. **libclc** (la librería estándar de OpenCL C de LLVM), versión matcheada
   a nuestro LLVM 23.1.0.
3. **SPIRV-LLVM-Translator** (KhronosGroup/SPIRV-LLVM-Translator — el que
   provee `LLVMSPIRVLib` que pide el error), también versión matcheada a
   LLVM 23.1.0, con su `.pc` de pkg-config instalado en el sysroot.

Compilar Clang completo es pesado (horas en una máquina con poca RAM/-j1;
mucho más rápido en la PC de escritorio con 48GB, donde `MAKEFLAGS` se
autoajusta más alto).

## Decisión que quedó sin cerrar — hay que elegir una

- **Opción A (la que yo recomendaba antes de cambiar de PC):** sacar `iris`
  de `-Dgallium-drivers` y `intel` de `-Dvulkan-drivers` en `step_mesa()`
  de `build-mesa.sh`. Mesa compila ya mismo con soporte completo para la
  RX7700 (radeonsi + radv) y la RTX3060 (nouveau, sólo OpenGL — NVK/Vulkan
  para Nvidia no está disponible, ya documentado en el proyecto). Intel
  integrada queda pendiente para una pasada aparte.
- **Opción B:** agregar Clang + libclc + SPIRV-LLVM-Translator al pipeline
  de build-mesa.sh ahora, para tener las 3 GPUs (incluida Intel) en esta
  misma pasada. Con 48GB de RAM en la PC de escritorio esto ya es mucho más
  viable que en la notebook.

El usuario no había elegido todavía entre A y B cuando se cortó el acceso a
la compu — quedó ahí la conversación, sin decidir.

---

## Otras cosas de contexto que SÍ ya están guardadas (no hace falta repetirlas)

- Los 11 bugs reales anteriores (falso positivo libdrm_intel, RPATH de
  llvm-config, swrast→llvmpipe, gallium-vdpau/osmesa removidos,
  glslangValidator x2, mako, yaml, llvm-config en el cross-file) están
  documentados en detalle en `PENDIENTES.md`, sección "Fase 6 — Parte 2".
- El historial de git (4 commits: inicial, docs de versionado, fix yaml,
  fix llvm-config) también documenta esto en los mensajes de commit.
- El resto del estado del proyecto (fases 0-5, Fase 6 Parte 1) está
  completo en `PENDIENTES.md` como siempre.

## Cosas que NO están en ningún archivo (preferencias de trabajo, no del
proyecto en sí) — si querés que la tarea nueva las respete, decíselas vos:

- No entregar archivos en .zip — trabajar con archivos sueltos directo.
- No auto-programarse checkeos — esperar a que vos avises "listo"/"termino"/
  "tiro error" antes de revisar logs.
- Identidad de git usada en los commits: `Juan Ignacio` /
  `juaniwilt@gmail.com` (por si hace falta reconfigurar `git config` en la
  PC de escritorio).
