# Home Assistant CUPS Print Server Add-on

[![Version](https://img.shields.io/badge/version-2.0.0-blue.svg)](https://github.com/Lexorius/cups-addon)
[![aarch64](https://img.shields.io/badge/aarch64-yes-green.svg)](#)
[![armv7](https://img.shields.io/badge/armv7-yes-green.svg)](#)
[![armhf](https://img.shields.io/badge/armhf-yes-green.svg)](#)
[![amd64](https://img.shields.io/badge/amd64-yes-green.svg)](#)
[![i386](https://img.shields.io/badge/i386-yes-green.svg)](#)

A CUPS print server add-on for Home Assistant with a **persistent** printer
configuration and a **comprehensive driver stack** that works out of the box
on a Raspberry Pi 4.

> **v2.0.0 highlights** — Printer setup now survives restarts (the v1.x
> persistence bug is fixed) and the driver stack covers Gutenprint, Foomatic,
> HPLIP, brlaser, splix, ptouch and IPP Everywhere on aarch64 / armv7.

## Features

- **Persistent printer configuration** — printers, PPDs, queues and job
  history all live in `/data/cups/` and survive restarts and updates.
- **USB printer support** — direct passthrough of USB printers from the HA
  host.
- **Network printing & sharing** — IPP, LPD and HTTP available on the LAN.
- **AirPrint / Bonjour** via Avahi/mDNS.
- **Web interface** at `http://<HA-IP>:631`.
- **hass_ingress integration** via reverse proxy on port 8631 (CSP headers
  stripped).
- **Drivers preinstalled (and verified on Raspberry Pi 4):**
  - Gutenprint (Epson, Canon, HP, Lexmark, ESC/P, PCL …)
  - Foomatic database (10 000+ printer PPDs)
  - HPLIP (HP)
  - Brother laser (`brlaser`)
  - Samsung / Xerox / Dell (`splix`)
  - Brother / Dymo / Zebra label printers (`ptouch`, `zedonk`)
  - IPP Everywhere — driverless printing for any modern network printer

## Installation

1. **Settings → Add-ons → Add-on Store**
2. ⋮ menu → **Repositories** → add `https://github.com/Lexorius/cups-addon`
3. Install **CUPS Print Server**, set a real admin password in
   *Configuration*, then **Start**.
4. Open `http://<HA-IP>:631`.

## Add-on options

| Option           | Default     | Description                                                       |
| ---------------- | ----------- | ----------------------------------------------------------------- |
| `admin_username` | `admin`     | Username for the CUPS admin login.                                |
| `admin_password` | `changeme`  | **Change this!** Required for adding/modifying printers.          |
| `log_level`      | `warn`      | `debug2 \| debug \| info \| warn \| error \| none`.               |
| `reset_config`   | `false`     | Wipes `/data/cups/etc` on next boot (use only for recovery).      |

## Adding a printer

### USB
1. Plug the printer into the HA host.
2. Restart the add-on so it can enumerate USB devices (the boot log shows
   `lsusb` output).
3. `http://<HA-IP>:631/admin` → **Add Printer** → pick the USB device.

### Network (IPP / Socket / LPD)
1. `http://<HA-IP>:631/admin` → **Add Printer**.
2. For modern printers, select **IPP Everywhere** to get driverless setup —
   no PPD needed.
3. Otherwise pick the matching driver from Gutenprint / Foomatic / HPLIP.

### Custom PPDs
Drop your `.ppd` file into `/data/cups/ppd-extra/` (visible in
*Studio Code Server* / *File Editor* under `addon_configs/local_cups` or via
the Samba share). The new PPD shows up under the **extra** vendor in CUPS.

## Printing from clients

| OS      | How to add the queue                                                       |
| ------- | --------------------------------------------------------------------------- |
| Windows | Settings → Printers → *Add printer using TCP/IP* → `http://<HA-IP>:631/printers/<name>` |
| macOS   | System Settings → Printers → IP tab → IPP → `<HA-IP>` → queue `printers/<name>` |
| Linux   | `lpadmin -p MyPrinter -E -v ipp://<HA-IP>:631/printers/<name>`             |
| iOS / iPadOS | Auto-discovered via AirPrint when Avahi is up                          |

## hass_ingress (sidebar) integration

Install [hass_ingress](https://github.com/lovelylain/hass_ingress) via HACS,
then add to `configuration.yaml`:

```yaml
ingress:
  cups:
    title: CUPS Drucker
    icon: mdi:printer
    # Use the proxy port — CSP headers are stripped here so the iframe works
    url: http://<HA-IP>:8631
```

If you still see layout glitches, fall back to:
```yaml
ingress:
  cups:
    work_mode: auth
    title: CUPS Drucker
    icon: mdi:printer
    url: http://<HA-IP>:631
```

## Persistent storage layout

```
/data/cups/
├── etc/          ← bind-replaces /etc/cups (printers.conf, *.ppd, …)
├── spool/        ← print queue
├── cache/        ← CUPS cache
├── logs/         ← access_log, error_log, page_log
└── ppd-extra/    ← drop your own PPDs here
```

If you ever need to start fresh, set `reset_config: true` once and restart.

## Troubleshooting

**Printer is gone after a restart.** This was the v1.x bug. Update to
v2.0.0 and re-add the printer once — it will stick from then on. If it
*still* disappears, check that `/data/cups/etc` exists and is writable:
```bash
ha addons logs cups | grep -i persistent
```

**USB printer not detected.** The add-on logs `lsusb` and `/dev/usb/lp*` at
boot. If your printer is not in either list, the HA host itself can't see it
— check kernel modules (`usblp`) and cabling, and restart the add-on after
plugging it in.

**hass_ingress shows broken layout.** Use port `8631` (the proxy) instead
of `631`. The proxy strips CSP/X-Frame headers; raw CUPS doesn't.

**Avahi shows `INACTIVE` in the boot log.** Printing still works manually
via `ipp://<HA-IP>:631/printers/<name>`. AirPrint discovery requires
Avahi — check that port 5353/UDP isn't blocked and `host_network` is `true`.

## Credits

- Original add-on by [Andrea Restello](https://github.com/arest)
- USB and driver enhancements + persistence overhaul by
  [Lexorius](https://github.com/Lexorius)
- Built on [CUPS](https://www.cups.org/), [Gutenprint](http://gimp-print.sourceforge.net/),
  [Foomatic](https://www.openprinting.org/foomatic) and Alpine Linux.

## License

Apache License 2.0
