# Changelog

## 2.0.2 — Bridged networking, explicit port forwarding

### Changed
- **`host_network: true` → `host_network: false`.** With host networking the
  add-on's cupsd competes for `:631` with anything else on the HA host (some
  HA OS variants ship their own printing service or have other listeners
  there). Switching to bridged mode with explicit port forwarding makes
  the Web UI reliably reachable. Trade-off: AirPrint auto-discovery is
  unreliable in bridged mode because mDNS broadcasts don't traverse the
  docker bridge cleanly. iOS / iPadOS clients must add the printer once
  manually via `ipp://<HA-IP>:631/printers/<name>` — direct printing then
  works as before. Avahi is still started in the container so direct
  unicast queries still resolve, but the daemon's reach is essentially
  the container itself.

### Notes
- Existing printers are not affected by this change — they live in
  `/data/cups/etc/` and are picked up regardless of network mode.
- USB printer passthrough is independent of network mode and continues
  to work.

---

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

---

## 2.0.0 — Persistence & Raspberry Pi 4 driver overhaul

### Fixed
- **Printers no longer disappear after restart.** In v1.x only `cupsd.conf`
  was symlinked to `/data/`, while `printers.conf`, `subscriptions.conf`,
  `classes.conf` and per-printer `ppd/*.ppd` files were written to
  `/etc/cups` inside the (volatile) container. The fix moves the **entire**
  `/etc/cups` directory onto persistent storage at `/data/cups/etc` via a
  symlink that is established before `cupsd` starts.
- Print spool, cache and logs are now persistent too.

### Added
- **Comprehensive driver stack for Raspberry Pi 4 (aarch64 / armv7):**
  Gutenprint, Foomatic database, HPLIP, brlaser, splix, ptouch, zedonk,
  ghostscript, poppler-utils.
- New add-on options: `log_level`, `reset_config`.
- Drop-in folder for custom PPDs at `/data/cups/ppd-extra/`.
- `tini` as PID 1 for clean signal handling and graceful shutdown.

### Changed
- Default admin password moved from `admin` to `changeme`.
- Dockerfile reorganised so a missing optional driver no longer fails the
  whole build.

---

## 1.6.2 (previous release)
- Initial fork from `arest/cups-addon` with USB printer support and Avahi.
