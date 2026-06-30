# Arquitectura de LINSI OS

## Visión general

```
Ubuntu 24.04 LTS (Noble)
└── live-build
    ├── Base mínima + hardening (siempre)
    └── Calamares (instalador)
        ├── LAB Equipment  [opcional]
        │   ├── lab-security
        │   ├── lab-dev
        │   ├── lab-infra
        │   └── lab-crypto
        └── Personal Equipment  [opcional]
            ├── personal-gaming
            ├── personal-media
            ├── personal-comms
            └── personal-office
```

## Decisiones de diseño

| Decisión | Elección | Razón |
|---|---|---|
| Base | Ubuntu 24.04 LTS | Drivers modernos, gaming support, compatibilidad con repos Kali |
| Desktop | Cinnamon | Familiar (Mint-like), liviano, estable |
| Instalador | Calamares + packagechooser | Interfaz gráfica, soporte nativo de selección de paquetes |
| Build tool | live-build | Herramienta más madura para derivadas Debian/Ubuntu |
| Firewall | nftables | Moderno, sucesor de iptables, mejor performance |
| MAC | AppArmor | Soporte nativo Ubuntu, perfiles listos para la mayoría de apps |

## Flujo de build

```
git push
    │
    └── GitHub Actions (ubuntu-24.04 runner)
          ├── lb config       ← aplica auto/config
          ├── lb build        ← debootstrap → chroot → hooks → squashfs → ISO
          │     ├── instala base.list.chroot
          │     ├── corre 0100-hardening.hook.chroot
          │     └── corre 0200-cleanup.hook.chorch
          ├── Lynis audit     ← QA de seguridad
          └── upload artifact → linsi-os-vX.Y.Z.iso
```

## Estructura del repo

```
linsi-os/
├── auto/
│   └── config              ← parámetros de live-build
├── config/
│   ├── package-lists/      ← un .list.chroot por metapaquete
│   ├── hooks/
│   │   └── normal/         ← scripts que corren en el chroot
│   ├── includes.chroot/    ← archivos que van directo al FS del sistema
│   └── apt/                ← pinning y repos extra
├── scripts/
│   ├── build-iso.sh        ← build local (Linux/Docker)
│   └── setup-dev.sh        ← build via Docker desde Windows
├── .github/
│   └── workflows/
│       └── build-iso.yml   ← CI/CD pipeline
└── docs/                   ← documentación del proyecto
```
