# Profile Guide

## `safe`

Conservative public baseline. Use for:

- first boot
- recovery
- long qualification runs
- unknown hardware state

Shipped values:

- DDR: `1872 MHz`
- Vddr: `1300 mV`
- Vcore: `1080 mV`

## `balanced`

Qualified performance profile intended for normal public use after validation.

Shipped values:

- DDR: `2004 MHz`
- Vddr: `1300 mV`
- Vcore: `1080 mV`

For many users, this should be the first profile tested against stock before moving into custom tuning.

## `experimental`

Opt-in profiles that may improve performance but are not part of the default public support envelope.

Experimental profiles are hidden by default in the admin UI.

Shipped values:

- DDR: `2100 MHz`
- Vddr: `1480 mV`
- Vcore: `1060 mV`

This profile is not a universal "best" setting. If you are trying to achieve above-stock performance, you should expect to test and tune your own MCU settings rather than assume the shipped experimental profile is optimal for your board.
