# Known Limitations

- Rail telemetry depends on the delayed helper path and may be unavailable or stale on some boards.
- Debug UART readback is optional and requires the physical mod plus the software toggle.
- DDR readback should be treated as backend-derived rather than assumed to come directly from the debug UART parser in every state.
- Experimental profiles are not part of the public support baseline.
- The stock LuCI surface remains installed as a fallback utility path, but the supported interface is the custom dashboard/admin UI.
- MCU firmware upload is operator-controlled and requires a matching validated manifest.
