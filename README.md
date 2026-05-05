# Home Assistant CUPS Print Server Add-on

[![Version](https://img.shields.io/badge/version-2.0.2-blue.svg)](https://github.com/Lexorius/cups-addon)
[![aarch64](https://img.shields.io/badge/aarch64-yes-green.svg)](#)
[![armv7](https://img.shields.io/badge/armv7-yes-green.svg)](#)
[![armhf](https://img.shields.io/badge/armhf-yes-green.svg)](#)
[![amd64](https://img.shields.io/badge/amd64-yes-green.svg)](#)
[![i386](https://img.shields.io/badge/i386-yes-green.svg)](#)

A CUPS print server add-on for Home Assistant with a **persistent** printer
configuration, **bridged networking with explicit port mapping** for
reliable Web UI reachability, and a **comprehensive driver stack** that
works out of the box on a Raspberry Pi 4.

> **v2.0.2 highlights** — Switched from host networking to bridged mode
> with explicit port mapping. The Web UI on `:631` is now reliably
> reachable even on hosts where something else competes for the port.
> Trade-off: AirPrint auto-discovery is limited in bridged mode (see
> [AirPrint section](#airprint--ios)).

## Features

- **Persistent printer configuration** — printers, PPDs, queues and job
  history all live in `/data/cups/` and survive restarts and updates.
- **USB printer support** — direct passthrough of USB printers from the HA
  host (independent of network mode).
- **Network printing & sharing** — IPP, LPD and HTTP available on the LAN.
- **Bridged networking, explicit port mapping** — `:631`, `:8631`, `:5353`
  forwarded by the supervisor, no port conflicts with the HA host.
- **Web interface** at `http://<HA-IP>:631`.
- **hass_ingress integration** via reverse proxy on port 8631 (CSP headers
  stripped).
- **Listen sanity check** at startup — if cupsd ever ends up bound to
  localhost, the log says so loudly instead of failing silently.
- **Drivers preinstalled (verified on Raspberry Pi 4):**
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

## AirPrint / iOS

In bridged networking mode (the v2.0.2 default), mDNS broadcasts don't
traverse the docker bridge, so iOS will not auto-discover the queue.
**Printing itself works** — you just have to add the printer manually
once on each device:

- iOS / iPadOS: install **Printopia** or any IPP-capable app, or use
  AirPrint Activator on a Mac on the same LAN to bridge the announcement.
  Direct printing from any IPP app: `ipp://<HA-IP>:631/printers/<name>`.
- If AirPrint auto-discovery is essential to you, you can revert to host
  networking by setting `host_network: true` in `config.yaml` and removing
  the `ports:` block — but this only works if nothing else on the HA host
  is bound to `:631`.

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

**Web UI on :631 is not reachable from the LAN.** Check the boot log for
`cupsd is listening on: …`. If it shows `127.0.0.1:631` or `::1:631`,
your `/data/cups/etc/cupsd.conf` was seeded with the broken Alpine default.
v2.0.1+ self-heals this on the next start; if you are stuck, set
`reset_config: true` once and restart, or edit
`/data/cups/etc/cupsd.conf` and replace the `Listen` line with `Port 631`.

**Printer is gone after a restart.** This was a v1.x bug. Update to v2.x
and re-add the printer once — it will stick from then on.

**USB printer not detected.** The add-on logs `lsusb` and `/dev/usb/lp*` at
boot. If your printer is not in either list, the HA host itself can't see it
— check kernel modules (`usblp`) and cabling, and restart the add-on after
plugging it in.

**hass_ingress shows broken layout.** Use port `8631` (the proxy) instead
of `631`. The proxy strips CSP/X-Frame headers; raw CUPS doesn't.

**iOS doesn't see the printer.** See the [AirPrint section](#airprint--ios)
above — this is expected in bridged mode.

## Credits

- Original add-on by [Andrea Restello](https://github.com/arest)
- USB and driver enhancements + persistence overhaul by
  [Lexorius](https://github.com/Lexorius)
- Built on [CUPS](https://www.cups.org/), [Gutenprint](http://gimp-print.sourceforge.net/),
  [Foomatic](https://www.openprinting.org/foomatic) and Alpine Linux.

## License

Apache License 2.0
