# Safe Tuning Rules

- Do not raise DDR, Vddr, or Vcore outside the policy bounds enforced by the image.
- Use the on-device generator for controlled experiments instead of hand-editing artifacts whenever possible.
- Promote a profile to public use only after:
  - cold boot pass
  - warm restart pass
  - 8h run
  - overnight run
- Judge profiles by:
  - accepted shares/min over time
  - duplicate rate trend
  - reject trend
  - recovery behavior after restart
- Telemetry is advisory. A profile must remain mineable even when rail telemetry is unavailable.
- Debug UART readback is optional. A profile must not depend on it to function.
- If your goal is to exceed stock performance, self-overclocking is not optional in practice. You should expect to test your own DDR, Vddr, and Vcore combinations and validate them with long-run share and duplicate behavior on your specific hardware.
