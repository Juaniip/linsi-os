# Guía de contribución — LINSI OS

## Conventional Commits

Este proyecto usa [Conventional Commits](https://www.conventionalcommits.org/). Cada commit debe tener el formato:

```
<tipo>(<scope>): <descripción corta en imperativo>

[cuerpo opcional — qué y por qué, no cómo]

[footer opcional — referencias a issues, breaking changes]
```

### Tipos permitidos

| Tipo | Cuándo usarlo |
|---|---|
| `feat` | Nueva funcionalidad o nuevo paquete agregado |
| `fix` | Corrección de bug o comportamiento incorrecto |
| `hardening` | Cambios de seguridad en el sistema (AppArmor, nftables, etc.) |
| `pkg` | Alta, baja o modificación de metapaquetes |
| `config` | Cambios en configuración de live-build o Calamares |
| `ci` | Cambios en GitHub Actions / pipeline |
| `docs` | Solo documentación, sin cambio de código |
| `chore` | Mantenimiento, actualizaciones de versiones, refactors sin impacto funcional |
| `revert` | Revertir un commit anterior |

### Scopes sugeridos

`base`, `security`, `dev`, `infra`, `crypto`, `gaming`, `media`, `comms`, `office`, `calamares`, `live-build`, `hardening`, `ci`, `docs`

### Ejemplos correctos

```
feat(pkg): agregar metapaquete lab-crypto con openssl y age

Incluye: openssl, gnupg2, age, libsodium-dev, hashdeep.
Ref: #12
```

```
hardening(base): habilitar AppArmor enforce en boot por defecto

Se agrega apparmor=1 security=apparmor a GRUB_CMDLINE_LINUX.
Perfiles: usr.sbin.sshd, usr.bin.firefox.
```

```
ci: agregar paso de Lynis audit en workflow de build

Score mínimo aceptable: 70. El build falla si está por debajo.
```

```
fix(live-build): corregir path de hooks en Ubuntu noble

live-build 20230612 cambió el directorio de hooks en modo ubuntu.
```

### Ejemplos incorrectos ❌

```
arregle cosas          ← sin tipo, sin scope, no imperativo
Update packages        ← demasiado vago
feat: fix bug          ← tipo contradice descripción
```

---

## Flujo de branches

```
main          ← siempre buildea, siempre produce ISO funcional
  └── develop ← integración, se mergea a main cuando hay release
        └── feat/nombre-corto    ← una feature por branch
        └── fix/descripcion-bug
        └── hardening/que-se-hardening
        └── pkg/nombre-del-paquete
```

**Reglas:**
- Nunca pushear directo a `main`
- `develop` → `main` solo por Pull Request con review
- Branches con nombre descriptivo en kebab-case
- Una sola responsabilidad por branch/PR

---

## Pull Requests

- Título en formato Conventional Commit
- Completar el template de PR (`.github/PULL_REQUEST_TEMPLATE.md`)
- La ISO debe buildear correctamente en CI antes de mergear
- Si modifica hardening: incluir output de Lynis antes/después

---

## Atomic commits

Cada commit debe:
- Hacer **una sola cosa**
- Ser reversible de forma segura con `git revert`
- No dejar el repo en estado roto

Si terminás el día con 5 cambios mezclados, usá `git add -p` para splitear en commits atómicos antes de pushear.
