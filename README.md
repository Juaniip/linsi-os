# LINSI OS

> Distribución Linux personalizada basada en Ubuntu 24.04 LTS, orientada a ciberseguridad, desarrollo, infraestructura y criptografía. Desarrollada en el laboratorio LINSI – UTN FRLP.
> 

---
## Equipo

| Rol | Persona |
|---|---|
| Founder & Lead | Wilt Juan Ignacio |
| Co-developer | Marini Alvaro |
| Faculty Advisor | Ricardo Martín Jorge |

## Características principales

- **Base**: Ubuntu 24.04 LTS (Noble Numbat)
- **Desktop**: Cinnamon (familiar, liviano, no invasivo)
- **Hardening**: AppArmor enforced, nftables default-deny, LUKS2, auditd, fail2ban, Secure Boot
- **Instalador**: Calamares con `packagechooser` — elegís qué instalar durante la instalación
- **Reproducible**: ISO generada 100% desde código vía GitHub Actions

## Estructura de paquetes

El instalador ofrece dos categorías opcionales sobre una base mínima hardenizada:

### 🔬 LAB Equipment
| Metapaquete | Contenido |
|---|---|
| `lab-security` | nmap, wireshark, metasploit, burpsuite, john, hashcat, aircrack-ng |
| `lab-dev` | git, docker, vscode, toolchains (python, node, rust) |
| `lab-infra` | ansible, terraform, kubectl, docker-compose, vagrant |
| `lab-crypto` | openssl, gnupg, age, libsodium-dev, hashdeep |

### 🎮 Personal Equipment
| Metapaquete | Contenido |
|---|---|
| `personal-gaming` | Steam, Proton-GE, GameMode, MangoHud |
| `personal-media` | VLC, OBS, GIMP, Inkscape, Spotify |
| `personal-comms` | Discord, Telegram, Thunderbird |
| `personal-office` | LibreOffice, Obsidian, Zotero |

---

## Requisitos para buildear

- Docker con `--privileged` (para loop devices)
- O simplemente hacer push — GitHub Actions buildea automáticamente

## Build local (Docker)

```bash
git clone https://github.com/tu-org/linsi-os
cd linsi-os
./scripts/setup-dev.sh   # instala dependencias en Docker
./scripts/build-iso.sh   # genera output/linsi-os.iso
```

## Build en CI

Cada push a `main` o `develop` dispara el workflow de GitHub Actions.
La ISO se publica como artifact descargable por 7 días.

---

## Documentación

- [Arquitectura del proyecto](docs/architecture.md)
- [Guía de paquetes](docs/packages.md)
- [Hardening aplicado](docs/hardening.md)
- [Cómo contribuir](CONTRIBUTING.md)
- [Changelog](CHANGELOG.md)

## Licencia

GPL-3.0 — ver [LICENSE](LICENSE).
