# LINSI-OS · Fase 1 — "El Núcleo"

Compila el kernel puro de Linux **7.2** (release del 16-ago-2026, la que
vamos a usar en todo el proyecto) con el cross-toolchain forjado en la
Fase 0 (`x86_64-linsi-linux-gnu-gcc`) y le aplica el endurecimiento que
describe la guía. Requiere haber corrido antes `make toolchain` (Fase 0).

## Antes de arrancar: poné el tarball del kernel en `sources/`

Ya lo tenés descargado (`linux-7.2.tar.xz`, ~153 MB) en la carpeta `LINSIOS`.
Movelo (no hace falta bajarlo nada de nuevo) a:

```powershell
Move-Item "C:\Users\juani\Desktop\LINSIOS\linux-7.2.tar.xz" `
          "C:\Users\juani\Desktop\LINSIOS\linsi-os\sources\linux-7.2.tar.xz"
```

`sources/` está bind-mounteada en `/lfs/sources` dentro del contenedor (ver
`docker-compose.yml`), así que el build lo encuentra ahí directo — no lo
vuelve a descargar. Lo único que hace es verificarle el sha256 contra el
oficial de kernel.org (`scripts/env.sh`, `LINUX_SHA256`) antes de compilar.

## Comandos

```bash
# 1. (si no lo hiciste ya) Fase 0: cross-toolchain
make image
make toolchain

# 2. Fase 1: kernel endurecido
make kernel
```

Equivalente sin Makefile (por ejemplo desde PowerShell):

```powershell
docker compose build
docker compose run --rm builder scripts/build-cross-toolchain.sh all
docker compose run --rm builder scripts/build-kernel.sh all
```

Al terminar, `docker compose run --rm builder scripts/build-kernel.sh verify`
imprime un check de cada opción de hardening (OK/FALTA) para confirmar que
quedaron aplicadas.

## Qué hace `build-kernel.sh`

1. **extract** — descomprime `linux-<versión>.tar.xz` (reusa el tarball que
   ya bajó Fase 0 para las cabeceras; si no está, lo descarga).
2. **configure** — `defconfig` de x86_64 + mergea
   `scripts/kernel-hardening.config` con `merge_config.sh` + `olddefconfig`
   para resolver dependencias.
3. **build** — compila `bzImage` y módulos con `CROSS_COMPILE=x86_64-linsi-linux-gnu-`
   (nuestro propio compilador, no el del host) y copia el resultado a
   `/lfs/boot/vmlinuz-linsi-<versión>` (volumen `linsios-boot`).
4. **modules** — instala los módulos en `/lfs/lib/modules` (dentro del
   sysroot, volumen `linsios-sysroot`).
5. **verify** — chequea en `.config` que cada opción de hardening haya quedado
   activa (o desactivada, en el caso de Thunderbolt/FireWire).

Pasos sueltos: `build-kernel.sh extract|configure|build|modules|verify`.

## Hardening aplicado (`scripts/kernel-hardening.config`) y por qué

| Guía dice | Config | Efecto |
|---|---|---|
| Kernel Lockdown, ni root modifica memoria | `SECURITY_LOCKDOWN_LSM`, `LOCK_DOWN_KERNEL_FORCE_INTEGRITY` | Bloquea `/dev/mem`, kexec/módulos sin firmar, hibernación, escritura de MSRs — incluso para root. |
| — (requisito técnico del punto anterior) | `MODULE_SIG`, `MODULE_SIG_FORCE`, `MODULE_SIG_SHA512` | Lockdown en modo integrity exige módulos firmados; si no, no cargan. |
| KASLR | `RANDOMIZE_BASE`, `RANDOMIZE_MEMORY` | Aleatoriza direcciones del kernel en cada boot. |
| Deshabilitar puertos DMA | `INTEL_IOMMU(_DEFAULT_ON)`, `AMD_IOMMU`, `IOMMU_DEFAULT_DMA_STRICT` + Thunderbolt/FireWire apagados | Cualquier dispositivo externo con DMA queda confinado por el IOMMU; se elimina el vector de ataque tipo Thunderclap. |
| BTRFS en el núcleo | `BTRFS_FS`, `BTRFS_FS_POSIX_ACL` | Sistema de archivos con snapshots disponible desde el kernel (btrfs-progs en espacio de usuario viene en Fase 2). |
| systemd-boot + Secure Boot | `EFI`, `EFI_STUB` | El `bzImage` queda arrancable directo por UEFI. El enrolado de clave Secure Boot (MOK/`db`) y la firma con `sbsign` se hacen en Fase 8, cuando exista el árbol de instalación/ISO real. |
| *(extra, no pedido explícitamente)* | `STRICT_KERNEL_RWX`, `STRICT_MODULE_RWX`, `SLAB_FREELIST_HARDENED` | Endurecimiento de memoria estándar que suele ir de la mano con Lockdown/KASLR, sin costo de compatibilidad. Si preferís no incluirlos, sacalos del `.config`. |

`LOCK_DOWN_KERNEL_FORCE_INTEGRITY` es el modo recomendado para el laboratorio
(bloquea manipulación pero deja algo de debugging). Si en algún momento
quieren el modo más estricto (bloquea también lectura de memoria del kernel y
tracing), el fragmento tiene un comentario con el cambio a
`FORCE_CONFIDENTIALITY`.

## Cómo se pasan archivos al contenedor para compilar

No hace falta copiar nada a mano — `docker-compose.yml` monta carpetas del
proyecto como *bind mount*, así que cualquier cambio en tu Windows se ve al
instante adentro del contenedor:

- `./scripts` → `/lfs/scripts` (de sólo lectura): si editás `kernel-hardening.config`
  o cualquier `.sh`, el próximo `docker compose run` ya usa la versión nueva.
- `./patches` → `/lfs/patches` (de sólo lectura, hoy vacía): si más adelante
  necesitás parchear el kernel, dejás el `.patch` ahí y lo aplicás con
  `patch -p1 < /lfs/patches/tu-patch.patch` desde dentro del contenedor
  (`make shell` para entrar).
- `./sources` → `/lfs/sources` (lectura/escritura): acá va `linux-7.2.tar.xz`
  (ver arriba). Binutils y GCC, si no los dejás vos también, se descargan
  solos ahí adentro la primera vez y quedan cacheados para las próximas.

## Qué queda listo para Fase 2

- Kernel comprimido: `/lfs/boot/vmlinuz-linsi-<versión>` (volumen `linsios-boot`).
- Módulos: `/lfs/lib/modules/<versión>` (volumen `linsios-sysroot`, junto con
  las cabeceras de Fase 0).
- `.config` usado, guardado como `/lfs/boot/config-linsi-<versión>` — sirve de
  referencia si Fase 2 necesita saber qué syscalls/flags tiene habilitados el
  kernel al compilar glibc/systemd.

## Próximo paso sugerido

Fase 2 (Espacio de Usuario): glibc como libc, systemd para gobernar servicios,
uutils (Rust) reemplazando las utilidades clásicas, Zsh como shell por
defecto — todo compilado contra este kernel y sus cabeceras.
