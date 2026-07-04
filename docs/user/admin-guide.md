# Admin Guide

This page describes the supported control surface exposed by `admin.html`.

## Login

- default username: `admin`
- default password: `admin`
- login is cookie-based in the browser
- change the password after first boot

## Pool

You can edit:

- coin
- pool URL
- wallet / worker user
- password

Supported actions:

- `Save Pool`
- `Save + Restart Miner`

## Cooling

Configurable values:

- target temperature
- hard temperature
- minimum fan percent
- maximum fan percent

Current public defaults:

- target temp: `65 C`
- min fan: `50%`

## Network

Supported modes:

- `DHCP` by default
- `static` if explicitly configured

Static mode allows:

- IP address
- netmask
- gateway
- DNS

## Telemetry

Two independent telemetry paths can be configured:

1. rail telemetry:
   - PMBus bridge / input power path
2. debug UART readback:
   - optional hardware mod path for live Vddr/Vcore/reset readback

Debug UART readback defaults to the original method being disabled, so the firmware remains usable on unmodified miners.

## Profiles

The public UI exposes bundled profiles directly from the admin page.

Public default visibility:

- `safe`
- `balanced`

Optional visibility:

- `experimental` behind the toggle

Applying a profile restarts the miner.

## Recovery

The supported recovery action is:

- `Restore Safe Profile + Restart`

This intentionally resets the miner to the bundled safe profile rather than using a dynamic known-good slot.

## Firmware Upload

Two firmware workflows are present in the UI:

1. upload external MCU firmware + manifest, then apply
2. generate MCU firmware on-device from entered DDR / Vddr / Vcore values

Current public support boundary:

- custom uploaded MCU firmware is not yet a supported path
- the supported tuning path is the on-device generator
- debug UART bridge instructions are still pending and are not documented here yet

The generator path is intended to reduce file juggling during tuning.

## Service Controls

The admin UI supports:

- start miner
- stop miner
- restart miner
- reboot system

## Support Bundle

The support bundle is the preferred field-diagnostics artifact.

It is intended to include:

- recent miner logs
- current config
- current state
- current stats
- telemetry snapshot
- stored miner history buffer
