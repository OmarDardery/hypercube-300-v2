# HyperCube 300 V2

Klipper host setup and a base printer configuration for a 300 mm HyperCube CoreXY using a BIGTREETECH SKR Mini E3 V3.0.

## Proxmox installation

Run on the Proxmox host as root:

```bash
curl -fsSL https://raw.githubusercontent.com/OmarDardery/hypercube-300-v2/main/create-klipper-lxc.sh -o /root/create-klipper-lxc.sh && bash /root/create-klipper-lxc.sh
```

The installer creates a new unprivileged Debian LXC with Klipper, Moonraker, Mainsail and nginx. Defaults: local storage, vmbr0, 192.168.1.246/24, gateway from the host default route, 2 cores, 2048 MiB RAM and 12 GiB disk. It chooses an unused container ID and refuses to overwrite existing containers. Change the IP if using this on another network.

To import a completed config already on the Proxmox host:

```bash
PRINTER_CFG=/root/printer.cfg bash /root/create-klipper-lxc.sh
```

Open http://192.168.1.246 after installation. USB device passthrough is a separate step. Set the actual board serial path inside the container in `[mcu]` and restart Klipper.

If a guest installation fails, the container is retained. Fix the reported problem and resume with:

```bash
pct exec CONTAINER_ID -- bash /root/setup-klipper.sh
```

Logs are at `/root/klipper-install.log` inside the container. Config files live at `/home/klipper/printer_data/config/`.

## Printer configuration

`printer.base.cfg` uses CoreXY kinematics, nominal 300 mm travel, two Z motors sharing one driver, TMC2209 UART control and three fan outputs. It is a template, not a calibrated printer profile. Replace its explicit placeholders and verify assumptions before enabling heaters or homing. The installer copies this base as a reference; without an imported finished config it uses a staging config with no motors or heaters.

Confirm thermistor types, Z leadscrew lead, extruder rotation distance, motor direction/current, endstop locations, travel limits and any probe electrical interface. Do not infer leadscrew lead from thread pitch alone. An inductive sensor output must be compatible with the board's logic input; never apply 24 V to a signal pin.

There is no independent Z tilt with both Z sockets sharing the board's single Z driver.

## Board flashing

For SKR Mini E3 V3.0, compile Klipper for STM32G0B1, 8 KiB bootloader and USB communication, checking the current official board example. Copy the resulting `klipper.bin` to a FAT32 microSD card as `firmware.bin`, then power-cycle the board with the card inserted. Connect it to the host using a Micro-USB data cable. This repository does not include a prebuilt firmware image.

The host must remain running and USB-connected during printing. Hardware commissioning and calibration remain necessary.

## Validation and upstream sources

Bash syntax, generated config syntax and storage-selection logic were checked during development. No live Proxmox deployment or physical-printer validation has been performed.

- [Klipper board example](https://github.com/Klipper3d/klipper/blob/master/config/generic-bigtreetech-skr-mini-e3-v3.0.cfg)
- [Klipper documentation](https://www.klipper3d.org/)
- [Moonraker](https://github.com/Arksine/moonraker)
- [Mainsail](https://github.com/mainsail-crew/mainsail)
- [Mainsail client configuration](https://github.com/mainsail-crew/mainsail-config)

Official upstream software retains its own licenses. This is an independent printer setup repository, not an official BIGTREETECH project.
