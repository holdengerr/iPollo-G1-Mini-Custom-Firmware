# G1 Mini Custom Firmware

Custom firmware, web UI, MCU tooling, and release scripts for the iPollo G1 Mini.

This repository is for the custom stack only. Stock hardware analysis, stock firmware behavior, and reverse-engineering notes belong in the separate research repository.

## Scope

Included here:

- custom miner service and helper scripts
- custom dashboard, metrics page, login page, and admin UI
- OpenWrt CGI endpoints and init/service glue
- on-device MCU firmware generation and upload/apply flow
- release build scripts and release-facing documentation

Not included here:

- stock firmware dumps
- Ghidra projects
- raw UART captures
- generated release images
- vendor images or extracted root filesystems that cannot be redistributed

## Release Baseline

Current public release target:

- firmware version: `1.2.0`
- default login: `admin` / `admin`
- default network mode: `DHCP`
- RAM-backed miner history: up to `48h`

Bundled profiles:

- `safe`: `1872 MHz / Vddr 1300 / Vcore 1080`
- `balanced`: `2004 MHz / Vddr 1300 / Vcore 1080`
- `experimental`: `2100 MHz / Vddr 1480 / Vcore 1060`

## Main Features

- custom dashboard with 15m to 48h trend ranges
- separate metrics page backed by miner-side RAM history
- admin UI for pool, cooling, network, service, telemetry, recovery, and firmware management
- cookie-based login instead of token entry
- optional PMBus input power telemetry
- optional debug UART readback mod for live Vddr, Vcore, and core reset count
- on-device MCU firmware generator for voltage/frequency experiments
- firmware upload/apply flow for external MCU artifacts

## Quick Start

1. Build or obtain the SD flasher image.
2. Write it to an SD card.
3. Boot the miner from the SD card and let it flash internal SPI-NOR.
4. Remove the SD card and reboot from internal flash.
5. Find the miner on your LAN by DHCP lease.
6. Open the dashboard, then log in to the Admin page with `admin` / `admin`.
7. Change the password before wider deployment.
8. Configure pool settings and confirm the miner is accepting shares on the safe profile.

## Documentation

User documentation:

- [Installation](docs/user/installation.md)
- [Admin Guide](docs/user/admin-guide.md)
- [Profiles](docs/user/profile-guide.md)
- [Recovery](docs/user/recovery.md)
- [Safe Tuning Rules](docs/user/safe-tuning.md)
- [Support Matrix](docs/user/support-matrix.md)
- [Known Limitations](docs/user/known-limitations.md)

Developer documentation:

- [Build Notes](docs/developer/building.md)
- [Release Process](docs/developer/release-process.md)
- [Repo Status](docs/developer/repo-status.md)

## Repository Layout

```text
src/
  web/                dashboard, metrics, login, admin pages
  openwrt/
    cgi/              web endpoints
    bin/              helper scripts and generators
    init/             init/service entrypoints
  miner/
    custom-grin-miner.lua
    native/           helper binaries and sources

tools/
  mcu-firmware-studio/

scripts/
  build-release-image.sh

docs/
  user/
  developer/

inputs/
  local non-redistributable vendor inputs; not committed

dist/
  local build outputs; not committed
```

## Local Build Inputs

See [inputs/README.md](inputs/README.md).

At minimum, local release builds need:

- stock vendor SD flasher image
- stock squashfs rootfs image
- local helper binaries or a native helper build path
- local MCU firmware/profile binaries used by the public release

## Shipping Notes

This repo is intended to become the public custom-firmware repository. Before publishing a new release:

1. verify the exact image on hardware
2. verify Admin, Dashboard, and Metrics pages on multiple browsers
3. verify pool save, password change, profile apply, and recovery paths
4. verify PMBus and optional debug UART readback degrade cleanly when absent
5. record checksums and release notes
