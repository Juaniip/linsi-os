# LINSI-OS

LINSI-OS es una distribución GNU/Linux construida desde el código fuente, siguiendo la metodología de Linux From Scratch, pensada para el uso del Laboratorio LINSI en tareas de docencia, investigación y desarrollo de software. Este repositorio contiene los scripts de compilación, la configuración del entorno de build y la documentación técnica del proyecto.

La idea no partió de una lista de paquetes para instalar, sino de cinco principios de diseño definidos antes de escribir el primer script: **seguridad**, **privacidad**, **robustez**, **estética** y **vanguardia**. Cada herramienta que termina formando parte del sistema se elige porque sostiene alguno de esos cinco pilares, no por conveniencia o popularidad. El documento fundacional del proyecto, con el detalle completo de esta idea, está en [`docs/LINSI-OS.pdf`](docs/LINSI-OS.pdf).

## Por qué desde el código fuente

Instalar y ajustar una distribución ya armada (Debian, Arch, alguna orientada a seguridad como Kali) da un control limitado sobre lo que termina entrando al sistema: no se sabe con certeza qué opciones de compilación se usaron ni qué superficie de ataque se está heredando de decisiones tomadas por otro equipo. Acá cada componente —desde el compilador cruzado hasta el entorno gráfico— se descarga en su forma de código fuente, se verifica contra su suma de verificación oficial y se compila específicamente para el sistema de destino (triplete `x86_64-linsi-linux-gnu`), sin heredar nada del sistema anfitrión usado para compilar.

## Organización del desarrollo

El desarrollo se divide en ocho fases, cada una responsable de una capa del sistema y dependiente de los artefactos que deja la anterior:

| Fase | Nombre | Contenido |
|---|---|---|
| 0 | El Taller | Compilador cruzado (Binutils, GCC, Clang) y cabeceras de Linux |
| 1 | El Núcleo | Kernel Linux endurecido (Lockdown, KASLR, BTRFS, Secure Boot) |
| 2 | Espacio de usuario | glibc, systemd, uutils (Rust), Zsh |
| 3 | El Escudo | LUKS2+Argon2id, SELinux, nftables, auditd |
| 4 | Comunicaciones | systemd-networkd, DNS-over-TLS, PAM con FIDO2 |
| 5 | Infraestructura autónoma | apk-tools, firma de paquetes, servidor propio |
| 6 | Interfaz moderna | Wayland, Mesa/LLVM, Qt6 y KDE Plasma 6 |
| 7 | Contenerización | Flatpak, Podman/Distrobox |
| 8 | ISO y distribución | Imagen SquashFS + instalador Calamares |

Cada fase tiene su propio script en `scripts/` (`build-cross-toolchain.sh`, `build-kernel.sh`, `build-userspace.sh`, `build-security.sh`, `build-comms.sh`, `build-infra.sh`, `build-desktop.sh`, `build-mesa.sh`), autocontenido y sin depender de los demás. Cada script expone sus pasos por separado además de un modo `all` que corre la fase completa, y cada paso relevante termina con una verificación automática antes de pasar al siguiente.

## Estado del desarrollo

Fases 0 a 4 completas y verificadas. Dentro de la Fase 6, la Parte 1 (fundación no gráfica: D-Bus, Wayland, entrada, audio) está completa; la Parte 2 (Mesa + LLVM, drivers gráficos) está en curso. La Fase 5 está escrita pero todavía no tiene confirmación empírica de ejecución, y las Fases 6 Parte 3 (Qt6/KDE), 7 y 8 todavía no arrancaron. El detalle de cada corrección técnica real, con su causa raíz, queda documentado en [`docs/PENDIENTES.md`](docs/PENDIENTES.md) a medida que se resuelve.

## Cómo compilar

Todo el proceso corre dentro de un contenedor, para no depender de lo que haya instalado en la máquina de quien compila. Hace falta tener Podman y `podman-compose` instalados (el proyecto se pensó originalmente sobre Docker Desktop, pero se migró por incompatibilidades con parte del hardware del laboratorio; Docker Desktop con `docker-compose` también debería funcionar).

```bash
# Construir la imagen del contenedor de build
podman-compose build

# Correr cada fase en orden (cada una depende de la anterior)
podman-compose run --rm builder scripts/build-cross-toolchain.sh all
podman-compose run --rm builder scripts/build-kernel.sh all
podman-compose run --rm builder scripts/build-userspace.sh all
podman-compose run --rm builder scripts/build-security.sh all
podman-compose run --rm builder scripts/build-comms.sh all
podman-compose run --rm builder scripts/build-desktop.sh all
podman-compose run --rm builder scripts/build-mesa.sh all
```

Cada corrida deja un log con marca temporal en `logs/`, que no se sube al repositorio pero queda disponible localmente para diagnosticar cualquier error de compilación.

## Estructura del repositorio

```
linsi-os/
├── Dockerfile              # Imagen del contenedor de build
├── docker-compose.yml      # Orquestación del contenedor y sus volúmenes
├── scripts/                # Un script por fase, más env.sh (versiones y mirrors)
├── patches/                # Parches aplicados a paquetes de terceros, si hacen falta
├── sources/                # Tarballs descargados (no versionado, se re-descarga solo)
├── logs/                   # Logs de cada corrida (no versionado)
└── docs/                   # Documentación del proyecto
```

## Documentación

Todo lo que no es código está en [`docs/`](docs): el documento fundacional en PDF, los cinco pilares desarrollados en detalle, la bitácora técnica completa del desarrollo y los README de cada fase.

## Equipo

| Rol | Persona |
|---|---|
| Founder & Lead | Juan Ignacio Wilt |
| Soporte | Alvaro Marini |
| Soporte | Ricardo Martín Jorge |

Ingeniería en Sistemas de Información, UTN FRLP — Laboratorio LINSI.
