# Installation

## Flashing

1. Write the release image to an SD card.
2. Power the miner off.
3. Insert the SD card.
4. Boot and allow the stock update path to write the image into SPI-NOR.
5. Remove the SD card after flashing completes.
6. Reboot the miner from internal flash.

## First Boot

The public image defaults to:

- network mode: `DHCP`
- login: `admin` / `admin`
- default profile: safe

Find the miner from your router or DHCP lease table, then open the dashboard in a browser.

## First Session Checklist

1. Open the dashboard and confirm live stats are updating.
2. Open the Admin page and log in with `admin` / `admin`.
3. Change the password.
4. Save pool settings.
5. Confirm the miner is running on the safe profile.
6. Confirm accepted shares increase.

## Optional Hardware-Dependent Checks

If your unit uses optional mods or supported extra telemetry paths:

- confirm PMBus input power updates if the bridge path is available
- confirm debug UART readback updates if the mod is installed and enabled

Neither path should be required for the miner to boot and mine.
