#!/bin/bash
# ==============================================================================
# Home Assistant CUPS Add-on  —  Main Entrypoint  (v2.0.0)
#
# Key changes vs. v1.x
#   * /etc/cups is FULLY persisted to /data/cups/etc (not just cupsd.conf).
#     This is what made printers disappear on restart in earlier versions:
#     CUPS writes printers.conf, ppd/*.ppd, subscriptions.conf, classes.conf
#     into /etc/cups, which is part of the container layer (volatile).
#   * cupsd.conf is only seeded on first run; user changes are preserved.
#   * Optional `reset_config: true` add-on option performs a clean re-seed.
#   * Drivers installed by Dockerfile cover Raspberry Pi 4 (aarch64/armv7).
# ==============================================================================
set -eu

# ------------------------------------------------------------------------------
# Logging helpers
# ------------------------------------------------------------------------------
log_info()    { echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_warning() { echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_error()   { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }

log_info "============================================"
log_info " CUPS Print Server Add-on  v2.0.0"
log_info " Persistent config + ARM driver stack"
log_info "============================================"

# ------------------------------------------------------------------------------
# 1. Read add-on options
# ------------------------------------------------------------------------------
OPTIONS_FILE="/data/options.json"
ADMIN_USER="admin"
ADMIN_PASS="changeme"
LOG_LEVEL="warn"
RESET_CONFIG="false"

if [ -f "${OPTIONS_FILE}" ]; then
    ADMIN_USER=$(jq -r '.admin_username // "admin"'    "${OPTIONS_FILE}")
    ADMIN_PASS=$(jq -r '.admin_password // "changeme"' "${OPTIONS_FILE}")
    LOG_LEVEL=$(jq  -r '.log_level      // "warn"'     "${OPTIONS_FILE}")
    RESET_CONFIG=$(jq -r '.reset_config // false'      "${OPTIONS_FILE}")
else
    log_warning "No options.json found — using defaults"
fi

log_info "Admin user:        ${ADMIN_USER}"
log_info "CUPS log level:    ${LOG_LEVEL}"
log_info "Reset on boot:     ${RESET_CONFIG}"

# ------------------------------------------------------------------------------
# 2. Persistent storage layout
#
#    /data/cups/
#      ├─ etc/          → bind-replaces /etc/cups        (THE fix for printers)
#      ├─ spool/        → bind-replaces /var/spool/cups  (print queue)
#      ├─ cache/        → bind-replaces /var/cache/cups
#      ├─ logs/         → bind-replaces /var/log/cups
#      └─ ppd-extra/    → user-supplied PPDs, linked into /usr/share/cups/model
# ------------------------------------------------------------------------------
DATA_ROOT="/data/cups"
PERSIST_ETC="${DATA_ROOT}/etc"
PERSIST_SPOOL="${DATA_ROOT}/spool"
PERSIST_CACHE="${DATA_ROOT}/cache"
PERSIST_LOGS="${DATA_ROOT}/logs"
PERSIST_PPD_EXTRA="${DATA_ROOT}/ppd-extra"

log_info "Preparing persistent storage in ${DATA_ROOT}"
mkdir -p "${PERSIST_ETC}" "${PERSIST_SPOOL}" "${PERSIST_CACHE}" \
         "${PERSIST_LOGS}" "${PERSIST_PPD_EXTRA}"

# Optional: nuke persistent config when the user toggles reset_config: true
if [ "${RESET_CONFIG}" = "true" ]; then
    log_warning "reset_config=true → wiping ${PERSIST_ETC}"
    rm -rf "${PERSIST_ETC}"
    mkdir -p "${PERSIST_ETC}"
fi

# ------------------------------------------------------------------------------
# 3. Seed /data/cups/etc on first run, then make /etc/cups a symlink to it
#
#    This is the central fix: every file CUPS writes during normal operation
#    (printers.conf, classes.conf, subscriptions.conf, ppd/*.ppd) lives in
#    /etc/cups. By symlinking /etc/cups to /data/cups/etc BEFORE cupsd starts,
#    everything CUPS writes survives a container restart.
# ------------------------------------------------------------------------------
if [ ! -f "${PERSIST_ETC}/.seeded" ]; then
    log_info "First run: seeding default CUPS config from image"
    if [ -d /etc/cups ] && [ ! -L /etc/cups ]; then
        # Copy package defaults across (incl. mime types, default policies, ...)
        cp -an /etc/cups/. "${PERSIST_ETC}/" 2>/dev/null || true
    fi
    mkdir -p "${PERSIST_ETC}/ppd" "${PERSIST_ETC}/ssl" "${PERSIST_ETC}/interfaces"
    touch "${PERSIST_ETC}/.seeded"
fi

# Replace /etc/cups with a symlink to the persistent location
if [ ! -L /etc/cups ]; then
    rm -rf /etc/cups
fi
ln -sfn "${PERSIST_ETC}" /etc/cups

# Same trick for spool, cache, logs (so jobs and history survive too)
[ -L /var/spool/cups ] || { rm -rf /var/spool/cups; ln -sfn "${PERSIST_SPOOL}" /var/spool/cups; }
[ -L /var/cache/cups ] || { rm -rf /var/cache/cups; ln -sfn "${PERSIST_CACHE}" /var/cache/cups; }
[ -L /var/log/cups   ] || { rm -rf /var/log/cups;   ln -sfn "${PERSIST_LOGS}"  /var/log/cups;   }

# Permissions — CUPS runs as root but writes as lp/lpadmin
chown -R root:lp "${PERSIST_ETC}"   2>/dev/null || true
chmod -R u+rwX,g+rwX "${PERSIST_ETC}"
chown -R lp:lp   "${PERSIST_SPOOL}" 2>/dev/null || true

log_info "Persistent storage ready."

# ------------------------------------------------------------------------------
# 4. Extra PPDs (user-supplied)  →  /usr/share/cups/model/extra
# ------------------------------------------------------------------------------
mkdir -p /usr/share/cups/model
ln -sfn "${PERSIST_PPD_EXTRA}" /usr/share/cups/model/extra

log_info "Drop additional PPD files into ${PERSIST_PPD_EXTRA} and they will appear in CUPS."

# ------------------------------------------------------------------------------
# 5. Default cupsd.conf — only written if missing or empty (preserves edits!)
# ------------------------------------------------------------------------------
write_default_cupsd_conf() {
    log_info "Writing default cupsd.conf"
    cat > /etc/cups/cupsd.conf <<CUPSCONF
# CUPS configuration generated by Home Assistant CUPS add-on
# This file is created on first run; later edits are preserved.

ServerName localhost
ServerAdmin root@localhost
ServerAlias *
HostNameLookups Off

Listen 0.0.0.0:631
Listen /run/cups/cups.sock

DefaultEncryption Never
WebInterface Yes

# Sharing / browsing
Browsing On
BrowseLocalProtocols dnssd
BrowseWebIF Yes
DefaultShared Yes

# Logging
LogLevel ${LOG_LEVEL}
PageLogFormat
MaxLogSize 1m

# Job retention — keep history so the web UI shows recent jobs
PreserveJobHistory Yes
PreserveJobFiles  No
MaxJobs 200
MaxJobsPerUser 50

FileDevice Yes
SystemGroup lpadmin root wheel

<Location />
  Order allow,deny
  Allow all
</Location>

<Location /admin>
  AuthType Basic
  Require user @SYSTEM
  Order allow,deny
  Allow all
</Location>

<Location /admin/conf>
  AuthType Basic
  Require user @SYSTEM
  Order allow,deny
  Allow all
</Location>

<Location /jobs>
  Order allow,deny
  Allow all
</Location>

<Location /printers>
  Order allow,deny
  Allow all
</Location>

<Location /ipp>
  Order allow,deny
  Allow all
</Location>

<Policy default>
  JobPrivateAccess default
  JobPrivateValues default
  SubscriptionPrivateAccess default
  SubscriptionPrivateValues default

  <Limit Create-Job Print-Job Print-URI Validate-Job>
    Order deny,allow
  </Limit>

  <Limit Send-Document Send-URI Hold-Job Release-Job Restart-Job Purge-Jobs Set-Job-Attributes Create-Job-Subscription Renew-Subscription Cancel-Subscription Get-Notifications Reprocess-Job Cancel-Current-Job Suspend-Current-Job Resume-Job Cancel-My-Jobs Close-Job CUPS-Move-Job CUPS-Get-Document>
    Order deny,allow
  </Limit>

  <Limit CUPS-Add-Modify-Printer CUPS-Delete-Printer CUPS-Add-Modify-Class CUPS-Delete-Class CUPS-Set-Default CUPS-Get-Devices>
    AuthType Basic
    Require user @SYSTEM
    Order deny,allow
  </Limit>

  <Limit Pause-Printer Resume-Printer Enable-Printer Disable-Printer Pause-Printer-After-Current-Job Hold-New-Jobs Release-Held-New-Jobs Deactivate-Printer Activate-Printer Restart-Printer Shutdown-Printer Startup-Printer Promote-Job Schedule-Job-After Cancel-Jobs CUPS-Accept-Jobs CUPS-Reject-Jobs>
    AuthType Basic
    Require user @SYSTEM
    Order deny,allow
  </Limit>

  <Limit Cancel-Job CUPS-Authenticate-Job>
    Order deny,allow
  </Limit>

  <Limit All>
    Order deny,allow
  </Limit>
</Policy>

DefaultAuthType Basic
JobSheets none,none
CUPSCONF
}

if [ ! -s /etc/cups/cupsd.conf ]; then
    write_default_cupsd_conf
else
    # Update the LogLevel each boot if the user changed the add-on option,
    # without clobbering anything else they may have edited.
    if grep -qE '^[[:space:]]*LogLevel[[:space:]]' /etc/cups/cupsd.conf; then
        sed -i -E "s/^[[:space:]]*LogLevel[[:space:]].*/LogLevel ${LOG_LEVEL}/" /etc/cups/cupsd.conf
    fi
    log_info "Existing cupsd.conf kept (only LogLevel synced to add-on option)."
fi

# Ensure cups-files.conf exists with sane defaults
if [ ! -s /etc/cups/cups-files.conf ]; then
    cat > /etc/cups/cups-files.conf <<'CFCONF'
# Generated by HA CUPS add-on
SystemGroup lpadmin root wheel
ServerRoot   /etc/cups
ServerBin    /usr/lib/cups
DataDir      /usr/share/cups
DocumentRoot /usr/share/cups/doc
RequestRoot  /var/spool/cups
TempDir      /var/spool/cups/tmp
CacheDir     /var/cache/cups
StateDir     /run/cups
LogFileGroup lp
AccessLog    /var/log/cups/access_log
ErrorLog     /var/log/cups/error_log
PageLog      /var/log/cups/page_log
CFCONF
fi

# ------------------------------------------------------------------------------
# 6. Admin user
# ------------------------------------------------------------------------------
log_info "Configuring admin user '${ADMIN_USER}'"
if ! id "${ADMIN_USER}" >/dev/null 2>&1; then
    adduser -D -G lpadmin "${ADMIN_USER}" 2>/dev/null || true
fi
addgroup "${ADMIN_USER}" lpadmin 2>/dev/null || true
addgroup "${ADMIN_USER}" lp      2>/dev/null || true
echo "${ADMIN_USER}:${ADMIN_PASS}" | chpasswd

# ------------------------------------------------------------------------------
# 7. USB diagnostics (helpful in support tickets)
# ------------------------------------------------------------------------------
log_info "=== USB devices visible to the container ==="
lsusb 2>/dev/null || echo "  lsusb not available"
log_info "=== USB printer character devices ==="
ls -la /dev/usb/lp* 2>/dev/null || echo "  No /dev/usb/lp* devices found"
ls -la /dev/bus/usb 2>/dev/null || echo "  No /dev/bus/usb tree found"

# Make sure the USB backend is executable
chmod 755 /usr/lib/cups/backend/usb 2>/dev/null || true

# ------------------------------------------------------------------------------
# 8. Avahi / mDNS  (so AirPrint and Bonjour clients discover the printer)
# ------------------------------------------------------------------------------
setup_avahi() {
    log_info "Configuring Avahi"
    mkdir -p /var/run/avahi-daemon /var/run/dbus /etc/avahi/services

    local avahi_host
    avahi_host=$(hostname -s 2>/dev/null || echo "cups-server")

    cat > /etc/avahi/avahi-daemon.conf <<AVAHI
[server]
host-name=${avahi_host}
domain-name=local
use-ipv4=yes
use-ipv6=no
enable-dbus=yes
ratelimit-interval-usec=1000000
ratelimit-burst=1000

[wide-area]
enable-wide-area=yes

[publish]
publish-hinfo=no
publish-workstation=no
publish-addresses=yes
publish-domain=yes

[reflector]
enable-reflector=no

[rlimits]
AVAHI
}

start_dbus() {
    log_info "Starting D-Bus"
    rm -f /var/run/dbus/pid /var/run/dbus/system_bus_socket
    if [ ! -f /var/lib/dbus/machine-id ]; then
        mkdir -p /var/lib/dbus
        dbus-uuidgen > /var/lib/dbus/machine-id 2>/dev/null || true
    fi
    dbus-daemon --system 2>/dev/null && \
        log_info "D-Bus running" || \
        log_warning "D-Bus failed to start — Avahi may run in standalone mode"
}

start_avahi() {
    if ! command -v avahi-daemon >/dev/null 2>&1; then
        log_warning "avahi-daemon not installed — printers will not auto-discover"
        return 1
    fi

    killall avahi-daemon 2>/dev/null || true
    sleep 1

    if avahi-daemon --no-rlimits --daemonize 2>/dev/null; then
        log_info "Avahi running"
        return 0
    fi

    log_warning "Avahi standard start failed — retrying with --no-drop-root"
    if avahi-daemon --no-rlimits --no-drop-root --daemonize 2>/dev/null; then
        log_info "Avahi running (no-drop-root)"
        return 0
    fi

    log_warning "Avahi could not start — printing still works via ipp://<HA-IP>:631/printers/<name>"
    return 1
}

# ------------------------------------------------------------------------------
# 9. Nginx proxy on :8631 (for hass_ingress iframe embedding)
# ------------------------------------------------------------------------------
start_nginx() {
    if ! command -v nginx >/dev/null 2>&1; then
        return
    fi
    log_info "Starting nginx proxy on :8631"
    mkdir -p /run/nginx
    nginx 2>/dev/null && log_info "nginx running" || log_warning "nginx failed to start"
}

# ------------------------------------------------------------------------------
# 10. Post-start: enable sharing on existing printers
# ------------------------------------------------------------------------------
enable_printer_sharing() {
    # Wait for cupsd to accept connections
    for _ in $(seq 1 20); do
        if lpstat -r 2>/dev/null | grep -q "running"; then
            break
        fi
        sleep 1
    done

    cupsctl --share-printers 2>/dev/null || true

    local printers
    printers=$(lpstat -p 2>/dev/null | awk '/^printer/ {print $2}')
    if [ -z "${printers}" ]; then
        log_info "No printers configured yet — new ones will be shared by default."
        return
    fi
    for p in ${printers}; do
        lpadmin -p "${p}" -o printer-is-shared=true 2>/dev/null && \
            log_info "Sharing enabled for ${p}" || \
            log_warning "Could not enable sharing for ${p}"
    done
}

# ------------------------------------------------------------------------------
# 11. Graceful shutdown
# ------------------------------------------------------------------------------
cleanup() {
    log_info "Shutting down…"
    killall -TERM cupsd        2>/dev/null || true
    killall -TERM avahi-daemon 2>/dev/null || true
    killall -TERM dbus-daemon  2>/dev/null || true
    killall -TERM nginx        2>/dev/null || true
    # Give services a moment to flush state to /data/cups/etc
    sleep 1
    log_info "Bye."
    exit 0
}
trap cleanup SIGTERM SIGINT

# ------------------------------------------------------------------------------
# 12. Boot sequence
# ------------------------------------------------------------------------------
start_dbus
setup_avahi
start_avahi
AVAHI_OK=$?

start_nginx

log_info "Starting cupsd (foreground)"
/usr/sbin/cupsd -f &
CUPSD_PID=$!
log_info "cupsd PID: ${CUPSD_PID}"

( enable_printer_sharing ) &

log_info "============================================"
log_info " CUPS Print Server is up"
log_info "  Web UI :  http://<HA-IP>:631"
log_info "  Admin  :  http://<HA-IP>:631/admin"
log_info "  Ingress:  http://<HA-IP>:8631   (hass_ingress)"
log_info "  IPP    :  ipp://<HA-IP>:631/printers/<name>"
log_info "  Login  :  ${ADMIN_USER} / ********"
if [ "${AVAHI_OK}" -eq 0 ]; then
    log_info "  Avahi  :  ACTIVE  (AirPrint / Bonjour)"
else
    log_info "  Avahi  :  INACTIVE (manual setup needed on clients)"
fi
log_info "  Storage:  ${PERSIST_ETC}  ←  printers persist here"
log_info "============================================"

# Block on cupsd; trap above handles signals
wait ${CUPSD_PID}
