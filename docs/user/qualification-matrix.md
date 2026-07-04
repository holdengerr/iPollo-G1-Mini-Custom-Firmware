# Qualification Matrix

Use this file to record each release candidate before public distribution.

| Candidate | Profile | Telemetry | Boot | Restart | 8h run | Overnight | Shares/min | Duplicate rate | Result |
|---|---|---:|---|---|---|---|---:|---:|---|
| pending | `stable-1872-v1080` | off/optional | pending | pending | pending | pending | pending | pending | pending |
| pending | `perf-1992-vddr1200-vcore1080` | optional | pending | pending | pending | pending | pending | pending | pending |

## Minimum pass criteria

- No false fault LED during a healthy run.
- No boot loop on three consecutive bad starts; safe recovery must engage.
- No malformed firmware upload may replace the active running artifact.
- Dashboard and admin page must render sane values when telemetry is unavailable or stale.
