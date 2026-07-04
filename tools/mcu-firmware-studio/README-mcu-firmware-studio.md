# G1 MCU Firmware Studio

Launch on Windows:

```bat
tools\mcu-firmware-studio\run-g1-mcu-firmware-studio.bat
```

Or directly:

```powershell
py -3 tools\mcu-firmware-studio\g1_mcu_firmware_studio.py
```

It opens a native desktop window. There is no local browser UI anymore.

What it does:

- generates patched `Mini-G22.bin` files on your PC
- writes a matching JSON manifest beside each generated firmware

What it does not do:

- it does not upload to the miner
- it does not automatically flash or activate firmware on the miner

Upload is now handled separately from the miner admin page, which stores uploaded artifacts under `/root/uploaded-firmware`.

Current patch set:

- DDR startup target and governor guard bytes
- DDR VMAX startup bytes on the ISL-visible `0xc0:0x24` path
- ISL-visible Vddr payload bytes and print arguments
- active Mini-board Vddr startup payload and print argument on the `0x62:0x21` path
- Vcore profile initializer bytes
- optional Vcore runtime payload patch at `0xed14`
- optional read-only PMBus bridge telemetry patch

Important limitation:

- This tool only generates firmware files.
- The voltage paths in firmware are still partly under investigation, so use generated files as controlled test artifacts, not as guaranteed-live rail truth.
- For this board, `Vddr` is not controlled by a single patch site. Stable application required patching:
  - the DDR VMAX write block around `0xe67a/0xe682`
  - the ISL-visible Vddr block around `0xe6cc/0xe6d4`
  - the active Mini startup Vddr payload at `0xec12`
