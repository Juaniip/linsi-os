# Hardening aplicado — LINSI OS

Resumen de todas las medidas de seguridad aplicadas en la imagen base.
Todas son obligatorias y no pueden desactivarse desde el instalador.

## AppArmor

- Habilitado en modo `enforce` por defecto via parámetros de kernel en GRUB: `apparmor=1 security=apparmor`
- Todos los perfiles disponibles en `/etc/apparmor.d/` se setean a `enforce` durante el build

## SSH

Configuración en `/etc/ssh/sshd_config.d/99-linsi-hardening.conf`:
- `PermitRootLogin no`
- `PasswordAuthentication no` — solo autenticación por clave pública
- `MaxAuthTries 3`
- `X11Forwarding no`
- `AllowTcpForwarding no`

## nftables (firewall)

Política por defecto: **DROP en input y forward, ACCEPT en output**.
Reglas permitidas de entrada: loopback, conexiones establecidas, ICMP limitado, SSH.

## fail2ban

Jail `sshd` activo: banea IPs con más de 3 intentos fallidos en 10 minutos por 1 hora.

## auditd

Reglas en `/etc/audit/rules.d/99-linsi.rules`:
- Cambios en `/etc/passwd`, `/etc/shadow`, `/etc/group`
- Cambios en `/etc/sudoers`
- Ejecución de `insmod`, `rmmod`, `modprobe`
- Acceso a configuración SSH

## Kernel (sysctl)

Parámetros en `/etc/sysctl.d/99-linsi-hardening.conf`:
- `ip_forward = 0`
- `randomize_va_space = 2` (ASLR completo)
- `dmesg_restrict = 1`
- `kptr_restrict = 2`
- `ptrace_scope = 1`
- `protected_hardlinks = 1`
- `protected_symlinks = 1`
- SYN cookies habilitados

## Política de contraseñas (PAM)

- Longitud mínima: 12 caracteres
- Requiere 3 de 4 clases de caracteres (mayúsculas, minúsculas, dígitos, especiales)
- Máximo 3 caracteres repetidos consecutivos

## Servicios deshabilitados y maskeados

- `avahi-daemon` (mDNS — attack surface innecesaria)
- `cups` (impresión — no aplica en lab)
- `bluetooth` (reducción de superficie)

## UMASK

`027` — archivos nuevos sin permisos de lectura para "otros"

## Referencia

Basado en el CIS Ubuntu 24.04 Benchmark.
Verificación automática con Lynis en cada build de CI.
