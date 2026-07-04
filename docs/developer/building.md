# Building

## Inputs

The release image is assembled from:

- this repo's web, CGI, init, and miner sources
- vendor base firmware inputs kept locally under `inputs/`
- local helper binaries or reproducible helper build outputs
- bundled MCU firmware/profile artifacts used by the release

## Builder

- [scripts/build-release-image.sh](../../scripts/build-release-image.sh)

## Current State

The build path is usable, but still transitional.

It has already been tightened to prefer repo-local source files for shipped assets, but some vendor and helper dependencies still come from the broader private workspace or local inputs.

## Expected Local Requirements

At a minimum:

- vendor base image
- vendor squashfs image
- helper binaries or native helper build outputs
- bundled MCU binaries used by the public profile set

## Output Policy

Generated images, manifests, checksums, and support artifacts belong under `dist/` locally and should not be committed.

## Before Shipping a Build

1. build the image locally
2. flash it to a real miner
3. verify dashboard, admin, metrics, login, and recovery paths
4. verify pool save and profile apply
5. verify DHCP first-boot behavior
6. record the release checksum and notes
