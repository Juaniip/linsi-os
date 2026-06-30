# Build guide

## Prerequisites

The build runs inside Docker. The only requirement on the host machine is:

- Docker (or Docker Desktop on Windows/macOS)
- At least 20 GB of free disk space
- At least 4 GB of RAM

No build tools need to be installed on the host.

## Local build

```bash
git clone https://github.com/your-org/linsi-os.git
cd linsi-os
./scripts/build-in-docker.sh
```

The script pulls the build container, mounts the repository, and runs
`build/build.sh` inside it. The ISO is written to `output/linsi-os-<version>.iso`.

Build time is roughly 15-30 minutes depending on network speed and the number
of packages configured.

## What the build does

1. `lb config` configures live-build with the Ubuntu noble mirror and the
   package lists defined in `build/config/package-lists/`.
2. `lb build` runs in three stages:
   - **bootstrap** — installs the minimal Ubuntu system via debootstrap.
   - **chroot** — installs packages, runs hooks, applies hardening.
   - **binary** — assembles the squashfs, installs the bootloader (GRUB EFI),
     and produces the hybrid ISO.

## Hooks

Hooks in `build/config/hooks/live/` run inside the chroot during the build.
They are numbered to control execution order:

| File | Purpose |
|---|---|
| `0010-repos.hook.chroot` | Adds Kali and third-party APT sources |
| `0020-hardening.hook.chroot` | Applies sysctl, nftables, AppArmor |
| `0030-cinnamon.hook.chroot` | Configures the default desktop session |
| `0040-installer.hook.chroot` | Installs and configures Calamares |

## Adding packages to the base image

The base package list is at `build/config/package-lists/base.list.chroot`.
Packages listed here are installed in every build, regardless of installer
choices. Keep this list minimal. If a package is optional, it belongs in a
metapackage under `packages/`, not here.

## Building metapackages

Each metapackage in `packages/` is a control file for `equivs`. To build all
of them:

```bash
cd packages
make all
```

To build a single one:

```bash
cd packages
equivs-build lab-security.control
```

The resulting `.deb` files are placed in a local APT repository used during
`lb build`. The `Makefile` handles this automatically.

## CI build

The GitHub Actions workflow at `.github/workflows/build.yml` runs automatically
on every push to `develop` and every tag on `main`.

To trigger a build manually:

1. Go to Actions > Build ISO.
2. Click "Run workflow".
3. Select the branch.

The ISO artifact is available for download from the workflow run for 7 days.
Tagged builds (`main`) also publish the ISO as a GitHub Release.

## Versioning

Versions follow `MAJOR.MINOR.PATCH`:

- `PATCH` — bugfix, package update, documentation change.
- `MINOR` — new metapackage, new installer option, new hardening control.
- `MAJOR` — base distribution upgrade (e.g., Ubuntu 24.04 → 26.04).

The version is set in `build/VERSION`. It is embedded in the ISO filename and
in `/etc/linsi-release` inside the built system.
