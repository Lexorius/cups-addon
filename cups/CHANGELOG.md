# Changelog

## 2.0.0 — Persistence & Raspberry Pi 4 driver overhaul

### Fixed
- **Printers no longer disappear after restart.** In v1.x only `cupsd.conf` was
  symlinked to `/data/`, while `printers.conf`, `subscriptions.conf`,
  `classes.conf` and per-printer `ppd/*.ppd` files were written to `/etc/cups`
  inside the (volatile) container. The fix moves the **entire** `/etc/cups`
  directory onto persistent storage at `/data/cups/etc` via a symlink that is
  established before `cupsd` starts.
- Print spool, cache and logs are now persistent too (`/var/spool/cups`,
  `/var/cache/cups`, `/var/log/cups`).
- `cupsd.conf` is no longer overwritten on every boot — user edits to the
  server config (e.g. via the CUPS web UI) are preserved. Only the `LogLevel`
  is synced from the add-on option each boot.

### Added
- **Comprehensive driver stack for Raspberry Pi 4 (aarch64 / armv7):**
  - `gutenprint` + `gutenprint-cups` (Epson, Canon, HP, Lexmark, ESC/P, PCL …)
  - `foomatic-db`, `foomatic-db-engine`, `foomatic-db-ppds` (10 000+ PPDs)
  - `hplip` + `hplip-cups` (HP) — soft-fails when not built for the arch
  - `printer-driver-brlaser` (Brother lasers, ARM-safe)
  - `printer-driver-splix` (Samsung / Xerox / Dell)
  - `printer-driver-ptouch`, `printer-driver-zedonk` (label printers)
  - `ghostscript`, `poppler-utils` (PDF/PS rendering pipeline)
- New add-on options:
  - `log_level` — pick CUPS verbosity from the add-on UI
  - `reset_config` — wipe persistent config on next boot (recovery switch)
- Drop-in folder for custom PPDs at `/data/cups/ppd-extra/`, automatically
  surfaced in CUPS as the **extra** vendor.
- `tini` as PID 1 for clean signal handling and graceful shutdown.

### Changed
- Default admin password moved from `admin` to `changeme` to nudge users
  toward setting their own.
- Dockerfile reorganised so a missing optional driver no longer fails the
  whole build.
- Logging cleaned up; clearer first-boot vs. subsequent-boot messages.

### Removed
- Old `run.sh` (bashio-based, never executed by the Dockerfile CMD).
- Hard-coded Dymo/Ricoh PPD downloads at runtime — these are covered by
  `foomatic-db-ppds` and the official drivers now, with no flaky network
  fetches at container start.

### Migration notes
- **First boot of v2.0.0 on an existing install:** any printers configured
  with v1.x are *not* automatically imported, because they only existed in
  the volatile container layer. Re-add them once via
  `http://<HA-IP>:631/admin` — they will then persist forever after.
- If you had a custom `cupsd.conf`, copy it into `/data/cups/etc/cupsd.conf`
  before starting v2.0.0 and it will be picked up.

---

## 1.6.2 (previous release)
- Initial fork from `arest/cups-addon` with USB printer support and Avahi.
