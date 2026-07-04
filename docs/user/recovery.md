# Recovery

## Web recovery

Use the Admin page:

- `Restore Safe Profile + Restart`

## Manual fallback

If the web UI is unavailable:

1. Boot a known-good SD flasher image.
2. Reflash internal SPI-NOR.
3. Reboot and return to the supported admin flow.

## Recovery Philosophy

The current public release keeps recovery simple:

- safe profile is the single supported fallback
- there is no dynamic known-good slot in the supported UI flow
- operators doing aggressive tuning should expect to return to the safe profile when recovering
