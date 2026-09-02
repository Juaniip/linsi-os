# LINSI-OS — Pilares fundacionales

Documento de visión original del proyecto (armado por Juani al idear LINSI-OS,
antes de empezar la implementación técnica). Toda la arquitectura de las 8
fases no fue arbitraria: cada herramienta se eligió para sostener uno de estos
cinco pilares. Se deja acá tal cual se pensó al inicio, como referencia de
diseño — la nota de estado al final marca en qué quedó cada cosa a la fecha,
por si algún detalle puntual cambió en el camino.

Los cinco pilares fundacionales de LINSI-OS son **SEGURIDAD**, **PRIVACIDAD**,
**ROBUSTEZ**, **ESTÉTICA** y **VANGUARDIA**.

## 1. Seguridad

Es el núcleo duro del sistema, diseñado para resistir ataques tanto físicos
como lógicos en un entorno de laboratorio.

- **Fase 1 (Kernel y Arranque):** Kernel Lockdown para impedir que código
  malicioso se inyecte en la memoria, junto con KASLR y la desactivación de
  puertos físicos vulnerables (DMA). Secure Boot asegura que nadie altere el
  núcleo.
- **Fase 2 (Espacio de Usuario):** reemplazo de las utilidades clásicas en C
  por uutils (escritas en Rust), eliminando de raíz familias enteras de
  vulnerabilidades de memoria.
- **Fase 3 (Control y Auditoría):** SELinux con políticas estrictas para
  enjaular procesos — si un servicio de red es vulnerado, no puede tocar el
  resto del sistema. El firewall nftables bloquea todo por defecto, y auditd
  registra cualquier llamada sospechosa al sistema.
- **Fase 5 (Cadena de Suministro):** el gestor de paquetes exige firmas
  criptográficas irrompibles. Nadie puede inyectar actualizaciones
  maliciosas porque el sistema rechaza matemáticamente cualquier paquete que
  no esté firmado por la clave privada del laboratorio.
- **Fases 6 y 7 (Aislamiento):** Wayland aísla las ventanas gráficas
  (evitando el robo de pulsaciones de teclado que sufría X11) y Flatpak
  enjaula las aplicaciones cerradas, protegiendo los datos críticos del
  usuario.

## 2. Privacidad

Garantiza que tanto la navegación como los datos físicos del usuario y del
laboratorio permanezcan invisibles para terceros.

- **Fase 3 (Datos en Reposo):** disco completamente cifrado con LUKS2 y el
  algoritmo Argon2id. Si alguien extrae el disco físico de una máquina, los
  datos son inaccesibles y resisten ataques de fuerza bruta.
- **Fase 4 (Comunicaciones Anónimas):** systemd-networkd fuerza la
  aleatorización de la dirección MAC de las placas Wi-Fi en cada reinicio
  para evitar rastreo físico en redes públicas. systemd-resolved cifra todas
  las peticiones de navegación mediante DNS-over-TLS (DoT), evitando que el
  proveedor de internet lea qué dominios se visitan.
- **Fase 7 (Herramientas Diarias):** preinstalación de navegadores
  endurecidos (Firefox Hardened o Brave) con bloqueadores nativos y
  telemetría desactivada.

## 3. Robustez

Asegura que el sistema no colapse ante errores, dependencias rotas o tareas
intensivas, funcionando como un entorno fiable para ingeniería y desarrollo
diario.

- **Fases 0 y 5 (Infraestructura Autónoma):** la compilación del sistema se
  realiza en contenedores aislados (CI/CD) y se sirve desde infraestructura
  propia (la Raspberry Pi) protegida tras túneles Zero Trust de Cloudflare,
  garantizando altísima disponibilidad.
- **Fase 1 (Recuperación ante Desastres):** integración profunda con el
  sistema de archivos BTRFS, que permite tomar snapshots del disco en
  milisegundos — si algo se rompe, el sistema vuelve a un estado funcional
  inmediatamente.
- **Fase 2 (Compatibilidad y Supervisión):** la adopción de glibc garantiza
  que el SO pueda correr todo el software necesario sin fricciones. Se
  acopla a systemd para manejar servicios concurrentes y reiniciar procesos
  caídos automáticamente.

## 4. Estética

El sistema debe sentirse profesional, pulido e invitar al usuario a
utilizarlo, alejándose de las interfaces toscas de las distribuciones de
ciberseguridad tradicionales.

- **Fase 2 (La Terminal):** reemplazo de la clásica terminal Bash por Zsh
  con prompts visualmente ricos (como Starship), brindando información
  contextual, colores y autocompletado inteligente.
- **Fase 6 (El Escritorio):** KDE Plasma 6 impulsado por Qt6. Se automatiza
  la creación de perfiles de usuario (`/etc/skel/`) para que, al instalarse,
  el sistema ya cuente con un tema oscuro unificado, íconos modernos y
  tipografías Nerd Fonts para código.
- **Fase 8 (La Instalación):** uso del framework Calamares modificado con
  QML para integrar la marca, los colores y los logotipos del LINSI,
  logrando que el primer contacto con el SO sea una experiencia impecable.

## 5. Vanguardia

Implementación de las tecnologías de software más modernas de la industria,
descartando código heredado y obsoleto.

- **Fase 4 (Identidad Moderna):** integración nativa de PAM con soporte para
  tokens físicos por hardware (FIDO2/YubiKey) para escalada de privilegios y
  login, el estándar actual en ciberseguridad corporativa.
- **Fase 6 (Pila Gráfica y Multimedia):** descarte total de X11 y
  PulseAudio. LINSI-OS opera exclusivamente sobre Wayland y PipeWire,
  logrando gráficos fluidos, latencia de audio nula y captura de pantalla
  hiper-segura.
- **Fase 7 (El Modelo Inmutable/Híbrido):** un núcleo base inalterable y
  limpio, separando las aplicaciones comerciales (Flatpak) y los entornos de
  desarrollo (Podman/Distrobox) en contenedores, logrando tener lo mejor de
  ambos mundos sin comprometer el rendimiento de hardware ni de la GPU.

---

## Nota de estado (situación real al 2026-09-02)

Para que este documento no quede desactualizado respecto de lo que
efectivamente se construyó, un mapeo rápido pilar por pilar contra el avance
real (ver `PENDIENTES.md` para el detalle completo):

- **Seguridad:** Fases 1, 2 y 3 completas y confirmadas (Lockdown, KASLR,
  uutils, SELinux, nftables, auditd). Secure Boot real (enrolado de clave)
  queda para la Fase 8, todavía no llegamos ahí. Fase 5 (firma de paquetes)
  escrita pero sin confirmar ejecutada. Wayland (Fase 6 Parte 1) completo;
  Flatpak (Fase 7) no empezado.
- **Privacidad:** Fases 3 y 4 completas y confirmadas (LUKS2+Argon2id,
  MAC random, DNS-over-TLS). Los navegadores endurecidos de Fase 7 todavía
  no se tocaron.
- **Robustez:** Fase 2 completa y confirmada. BTRFS está en el kernel desde
  Fase 1, pero el flujo de snapshots automatizado en sí no se armó todavía.
  La infraestructura autónoma de Fase 5 (Raspberry Pi + Cloudflare Tunnel)
  sigue sin confirmación real de estar levantada.
- **Estética:** todavía no se llegó a Zsh+Starship (Fase 2 se compiló con
  Zsh pero sin Starship configurado explícitamente) ni a KDE Plasma 6 (Fase
  6 Parte 3, no empezada) ni a Calamares (Fase 8, no empezada).
- **Vanguardia:** PAM+FIDO2 completo y confirmado (Fase 4). Wayland+PipeWire
  completo (Fase 6 Parte 1). El modelo Flatpak/Podman/Distrobox de Fase 7 no
  empezó.

En resumen: los pilares de Seguridad, Privacidad y Robustez tienen ya su
base técnica más sólida construida; Estética y Vanguardia dependen todavía
de fases que arrancan más adelante (6 Parte 3 en adelante).
