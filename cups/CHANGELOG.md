# Changelog

## 2.0.1 — Web UI on :631 reachable again

### Fixed
- **cupsd was bound to localhost only after a fresh v2.0.0 install.**
  During first-run seeding, the Alpine package's default `cupsd.conf` —
  which contains `Listen localhost:631` — was copied to `/data/cups/etc/`,
  and the "only write defaults if the file is empty" guard then skipped the
  add-on's template. Net effect: the Web UI on `:631` was unreachable from
  the LAN.
  The fix:
  1. On first seed, `cupsd.conf` and `cups-files.conf` are explicitly
     dropped from the seeded files so the add-on's templates always take
     over on the first boot.
  2. The template now uses `Port 631` instead of `Listen 0.0.0.0:631`.
     `Port 631` survives CUPS' own config rewrites (Web UI → Server
     Settings → Save) reliably, while `Listen 0.0.0.0:631` was observed
     to be silently downgraded to `Listen localhost:631` on Alpine.
  3. **Self-heal for already broken installs:** on every boot, an existing
     `cupsd.conf` is scanned for `Listen localhost:631` and patched to
     `Port 631` in place. Existing v2.0.0 deployments are repaired by a
     simple add-on update — no `reset_config` needed.
- **v1.x → v2.x migration of printer configuration.** v1 stored CUPS
  config under `/data/cups/config/` (and the spool under
  `/data/cups/state/spool/`). v2 expects `/data/cups/etc/` and
  `/data/cups/spool/`. The first v2 boot now copies the legacy directories
  across so existing printers come back automatically.
- **Avahi `enable-dbus=no` (back to v1 behaviour).** v2.0.0 set this to
  `yes`, which silently broke Avahi when the system bus failed to come up.

### Added
- **Listen sanity check** at startup. After cupsd starts, a background job
  inspects `ss`/`netstat` (and falls back to a `curl` probe) and writes a
  loud `[ERROR]` block into the log if cupsd is bound to localhost only.
  This class of bug can no longer hide in plain sight.

### Removed
- The dead `cups/run.sh` and `cups/rootfs/usr/local/bin/run.sh` files.
  Neither is referenced by the Dockerfile (`CMD` points at
  `/etc/cont-init.d/cups.sh`); they were only causing confusion.

### Migration notes
- **Updating from v2.0.0:** just install v2.0.1 and restart the add-on.
  The self-heal patches your existing `cupsd.conf` on boot — look for the
  `WARN: Found 'Listen localhost:631' in existing cupsd.conf — patching to
  'Port 631'` line in the log to confirm.
- **Updating from v1.x:** your printers are migrated automatically from
  `/data/cups/config/` to `/data/cups/etc/` on first boot. The old
  directories are left untouched in case you want to roll back; remove
  them by hand once you are happy with v2.

---

## 2.0.0 — Persistence & Raspberry Pi 4 driver overhaul

### Fixed
- **Printers no longer disappear after restart.** In v1.x only `cupsd.conf`
  was symlinked to `/data/`, while `printers.conf`, `subscriptions.conf`,
  `classes.conf` and per-printer `ppd/*.ppd` files were written to
  `/etc/cups` inside the (volatile) container. The fix moves the **entire**
  `/etc/cups` directory onto persistent storage at `/data/cups/etc` via a
  symlink that is established before `cupsd` starts.
- Print spool, cache and logs are now persistent too (`/var/spool/cups`,
  `/var/cache/cups`, `/var/log/cups`).
- `cupsd.conf` is no longer overwritten on every boot — user edits to the
  server config (e.g. via the CUPS web UI) are preserved. Only the
  `LogLevel` is synced from the add-on option each boot.

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

---

## 1.6.2 (previous release)
- Initial fork from `arest/cups-addon` with USB printer support and Avahi.
