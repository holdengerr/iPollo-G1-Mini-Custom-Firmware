# Release Process

## Goal

Produce a release image that is:

- installable from SD card
- verified on real hardware
- documented enough for third-party operators
- identifiable by version, date, and checksum

## Release Checklist

1. Update release version strings in the build path.
2. Build the release image locally.
3. Flash the image onto a real G1 Mini.
4. Verify:
   - login works
   - DHCP default works
   - dashboard loads and populates
   - admin page loads and saves settings
   - metrics page loads and history graphs render
   - miner starts automatically
   - pool connectivity works
   - safe profile mines correctly
5. Verify optional features degrade cleanly:
   - PMBus absent
   - debug UART readback absent
6. Record:
   - version
   - build date
   - git commit
   - checksum
   - release notes

## Publish Set

Public release metadata should include:

- firmware version
- compatibility tag
- changelog / release notes
- flashing instructions
- recovery instructions
- known limitations

## Repo Hygiene

Do not publish:

- vendor images
- extracted stock rootfs trees
- raw captures
- large generated binaries inside git history

Keep those as local inputs or release artifacts outside the tracked source tree.
