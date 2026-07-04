# G1 Mini Public Release Checklist

- Build image and record version, build date, and source commit or `nogit`.
- Generate release directory with image, compressed image, checksums, manifest, and operator docs.
- Validate clean boot, miner start, admin page load, and dashboard load.
- Validate first-boot login with default `admin` / `admin`, then password change.
- Validate pool save, profile apply, and safe recovery.
- Validate telemetry settings save and restart behavior.
- Validate uploaded MCU firmware rejection for malformed manifest and acceptance for valid manifest.
- Validate support bundle download.
- Run at least one 8h default-profile test and one overnight default-profile test.
- Confirm no false fault LED on healthy runs.
- Confirm rail telemetry absence does not block miner startup.
- Record qualification results in `public-release/qualification-matrix.md`.
