# Supported Hardware Matrix

## Default support target

| Area | Status | Notes |
|---|---|---|
| Host board | Supported | Allwinner `H3_REF_DDR3_16X1_4L_V1.0` style host board documented in research repo. |
| Hashboard | Supported | Single-board G1 Mini hashboard with Mini-G22 MCU path and tested PMBus bridge path. |
| Stock boot/storage layout | Supported | Vendor stock SD-based SPI-NOR update path. |
| Rail telemetry helper present | Optional | Miner must still boot and mine if telemetry helper is unavailable. |
| PMBus rail readout valid | Optional | Public default profile must not require PMBus. |
| Debug UART readback mod | Optional | Live Vddr/Vcore/core-reset readback only when the mod is installed and enabled. |

## Public profile exposure rules

| Profile class | Default in UI | Expected use |
|---|---|---|
| `safe` | shown | first boot, recovery, public default |
| `balanced` | shown | qualified performance alternative |
| `experimental` | hidden by default | opt-in testing only |

## Required release gates

- Successful cold boot on the default public profile.
- Successful warm restart of miner service.
- Successful reboot with preserved config.
- Successful safe-profile recovery from the admin page.
- Successful overnight run on the public default profile.
