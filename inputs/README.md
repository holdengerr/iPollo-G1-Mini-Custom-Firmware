# Local Inputs

This directory is intentionally untracked except for this file.

Place local, non-redistributable build inputs here:

## Vendor Base Images

- `iPolloG1-TFcard-sysupgrade-squashfs-firmware.img`
- `root_squashfs.img`

## Optional Extracted Trees

- `owrt25-rootfs-extracted/`

## Prebuilt Helper Binaries

If the release build still depends on local compiled helpers, store them under a predictable local path here rather than committing them.

## Bundled MCU Profile Binaries

If you are bundling pre-generated MCU firmware binaries for a release, keep the source local copy here until the profile generation path is fully reproducible inside this repo.
