# Repo Status

## Current State

This repo is the first clean split of the custom firmware work from the mixed reverse-engineering workspace.

High-confidence pieces now staged here:

- current dashboard/admin/login/metrics pages
- current OpenWrt CGI/admin plumbing
- current custom miner init/service wrapper
- current debug UART readback helper scripts
- current MCU firmware studio tool
- user-facing release docs

## Still Coupled To The Workspace

The copied release script still references assets that were historically built in the larger `C:\G1MiniReverse` workspace. That includes:

- vendor base images
- extracted rootfs trees
- locally compiled helper binaries
- bundled MCU profile binaries

## Immediate Goal

Keep the release path working while converting those remaining dependencies into:

1. documented local `inputs/`
2. reproducible helper binary builds
3. reproducible bundled profile generation

## Publishability Bar

Before public push, the repo should satisfy:

- no hardcoded `C:\G1MiniReverse` path assumptions in release scripts
- no dependency on generated binaries outside the repo without documentation
- no release artifacts checked in
- clear install, recovery, and profile docs
