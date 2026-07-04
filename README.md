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

## Repo Structure vs Releases

This repository is meant to support both of these workflows:

1. inspect the live, up-to-date source files that make up the firmware image
2. download a ready-to-flash image without rebuilding anything

To make that clear:

- `src/`, `scripts/`, `tools/`, and `firmware-images/` are the inspectable source/composition view
- `releases/` contains tracked release metadata, notes, and checksums
- the actual ready-to-flash image files are published in the GitHub **Releases** tab

That gives users a clean download path without hiding how the image is built.

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

## Support And Feedback

If you hit a bug, regression, hardware-compatibility problem, or unclear behavior, please open a GitHub issue in this repository.

Useful issue attachments:

- dashboard screenshot
- admin screenshot
- support bundle
- miner log excerpt
- debug UART excerpt
- PMBus telemetry excerpt

The project benefits much more from a clean issue with evidence than from off-platform reports with partial context.

## Quick Start

1. Build or obtain the release image.
2. Write it to an SD card.
3. Boot the miner from the SD card and let it flash internal SPI-NOR.
4. Remove the SD card and reboot from internal flash.
5. Find the miner on your LAN by DHCP lease.
6. Open the dashboard, then log in to the Admin page with `admin` / `admin`.
7. Change the password before wider deployment.
8. Configure pool settings and confirm the miner is accepting shares on the safe profile.

## Performance Expectations

The bundled public profiles are meant to provide a usable baseline, not guarantee the absolute best result on every unit.

If your goal is to beat stock performance consistently, it is critical to try self-overclocking on your own hardware. Board variance, cooling, silicon behavior, and pool conditions all matter. Use the safe and balanced profiles as a starting point, then use the on-device MCU generator and measured validation runs to find what your miner will actually hold.

## Documentation

User documentation:

- [Installation](docs/user/installation.md)
- [Admin Guide](docs/user/admin-guide.md)
- [Profiles](docs/user/profile-guide.md)
- [Recovery](docs/user/recovery.md)
- [Safe Tuning Rules](docs/user/safe-tuning.md)
- [Support Matrix](docs/user/support-matrix.md)
- [Known Limitations](docs/user/known-limitations.md)
- [Firmware Images](firmware-images/README.md)
- [Release Metadata](releases/README.md)

Developer documentation:

- [Build Notes](docs/developer/building.md)
- [Release Process](docs/developer/release-process.md)

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

firmware-images/
  release composition notes and bundled profile metadata

releases/
  release notes, checksums, metadata; binary flash images live in GitHub Releases

docs/
  user/
  developer/

inputs/
  local non-redistributable vendor inputs

dist/
  local build outputs
```

## Local Build Inputs

See [inputs/README.md](inputs/README.md).

At minimum, local builds need:

- stock vendor base image
- stock squashfs rootfs image
- local helper binaries or a native helper build path
- local MCU firmware/profile binaries used by the public release
