# Catálogo de paquetes — LINSI OS

Documento de referencia para el contenido de cada metapaquete.
Para agregar/quitar paquetes: editar el `.list.chroot` correspondiente y abrir un PR con tipo `pkg`.

## 🔬 LAB Equipment

### lab-security
Herramientas de ciberseguridad ofensiva y defensiva.

| Paquete | Función |
|---|---|
| nmap | Port scanner y detección de servicios |
| masscan | Scanner de puertos masivo y rápido |
| wireshark / tshark | Análisis de tráfico de red |
| tcpdump | Captura de paquetes CLI |
| nikto | Web vulnerability scanner |
| dnsenum | Enumeración DNS |
| sqlmap | SQL injection automatizado |
| dirb / gobuster | Directory brute-forcing |
| john / hashcat | Password cracking |
| hydra | Brute-force de servicios |
| aircrack-ng | Auditoría de redes WiFi |
| metasploit-framework | Framework de explotación |
| binwalk / foremost | Análisis forense de binarios |
| volatility3 | Análisis de memoria RAM |
| exiftool | Metadatos de archivos |

### lab-dev
Herramientas de desarrollo de software.

| Paquete | Función |
|---|---|
| git + git-lfs | Control de versiones |
| build-essential | Compiladores GCC, make, etc. |
| python3 + pip + venv | Ecosistema Python |
| nodejs + npm | Ecosistema Node.js |
| docker.io + compose | Contenedores Docker |
| podman + buildah + skopeo | Contenedores rootless |
| code (VSCode) | Editor principal |
| gh | GitHub CLI |
| gdb | Debugger |
| jq | Procesamiento JSON |

### lab-infra
Herramientas de infraestructura y DevOps.

| Paquete | Función |
|---|---|
| ansible + ansible-lint | Configuration management |
| terraform | Infrastructure as Code |
| kubectl + helm | Orquestación Kubernetes |
| vagrant | VMs reproducibles |
| awscli | CLI de Amazon Web Services |

### lab-crypto
Herramientas de criptografía y PKI.

| Paquete | Función |
|---|---|
| openssl | TLS, certificados, cifrado |
| gnupg2 + gpg-agent | Cifrado y firma GPG |
| age | Cifrado de archivos moderno |
| libssl-dev / libsodium-dev | Libs de desarrollo |
| hashdeep / rhash / b3sum | Verificación de integridad |
| steghide | Esteganografía |

## 🎮 Personal Equipment

### personal-gaming
| Paquete | Función |
|---|---|
| steam | Plataforma de juegos |
| lutris | Launcher multi-plataforma |
| wine + wine32 + winetricks | Compatibilidad Windows |
| gamemode | Optimización de rendimiento |
| mangohud | Overlay de métricas |
| retroarch | Emuladores |

### personal-media
VLC, OBS Studio, GIMP, Inkscape, Audacity, Handbrake, ffmpeg

### personal-comms
Thunderbird (email), Discord, Telegram

### personal-office
LibreOffice, Obsidian (notas), Zotero (bibliografía)
