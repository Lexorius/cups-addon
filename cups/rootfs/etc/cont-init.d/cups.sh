#!/bin/bash
# ==============================================================================
# Home Assistant CUPS Add-on  —  Main Entrypoint  (v2.0.1)
#
# Fixes vs. 2.0.0
#   * cupsd was listening only on localhost after first boot, because the
#     Alpine package default cupsd.conf got copied into /data/cups/etc/ during
#     seeding and then the "only write if empty"-guard skipped the override.
#     We now always (re-)write cupsd.conf on first seed, and we use `Port 631`
#     instead of `Listen 0.0.0.0:631` so CUPS' own config rewrites can't break
#     external reachability later.
#   * Migration path from v1.x: /data/cups/config/  ->  /data/cups/etc/.
#     Existing printers from v1 are imported on first v2 boot.
#   * Sanity check after start: log a clear error if cupsd is not listening on
#     all interfaces, so this class of bug can't hide silently again.
# ==============================================================================
set -eu

# ------------------------------------------------------------------------------
# Logging helpers
# ------------------------------------------------------------------------------
log_info()    { echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_warning() { echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_error()   { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }

log_info "============================================"
log_info " CUPS Print Server Add-on  v2.0.1"
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
# ------------------------------------------------------------------------------
DATA_ROOT="/data/cups"
PERSIST_ETC="${DATA_ROOT}/etc"
PERSIST_SPOOL="${DATA_ROOT}/spool"
PERSIST_CACHE="${DATA_ROOT}/cache"
PERSIST_LOGS="${DATA_ROOT}/logs"
PERSIST_PPD_EXTRA="${DATA_ROOT}/ppd-extra"

# v1.x location (for migration only)
LEGACY_V1_CONF="${DATA_ROOT}/config"
LEGACY_V1_SPOOL="${DATA_ROOT}/state/spool"

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
# 3. Migration from v1.x  (only on first v2 boot)
#
#    v1 stored config at /data/cups/config/, spool at /data/cups/state/spool/.
#    v2 expects /data/cups/etc/ and /data/cups/spool/. Pull the user's
#    existing printers across so they are not lost on update.
# ------------------------------------------------------------------------------
if [ ! -f "${PERSIST_ETC}/.seeded" ] && [ -d "${LEGACY_V1_CONF}" ]; then
    log_info "Detected v1.x layout → migrating ${LEGACY_V1_CONF}/ → ${PERSIST_ETC}/"
    cp -an "${LEGACY_V1_CONF}/." "${PERSIST_ETC}/" 2>/dev/null || true
    if [ -d "${LEGACY_V1_SPOOL}" ]; then
        log_info "Migrating v1.x spool → ${PERSIST_SPOOL}/"
        cp -an "${LEGACY_V1_SPOOL}/." "${PERSIST_SPOOL}/" 2>/dev/null || true
    fi
    log_info "Migration done. Old v1 directories left in place — remove manually if you want."
fi

# ------------------------------------------------------------------------------
# 4. Seed /data/cups/etc on first run
#
#    IMPORTANT: we deliberately drop cupsd.conf and cups-files.conf from the
#    package defaults — those are the files that contained `Listen localhost:631`
#    and broke external reachability in v2.0.0. They are regenerated below.
# ------------------------------------------------------------------------------
FIRST_SEED="false"
if [ ! -f "${PERSIST_ETC}/.seeded" ]; then
    FIRST_SEED="true"
    log_info "First run: seeding default CUPS config from image"
    if [ -d /etc/cups ] && [ ! -L /etc/cups ]; then
        cp -an /etc/cups/. "${PERSIST_ETC}/" 2>/dev/null || true
    fi
    mkdir -p "${PERSIST_ETC}/ppd" "${PERSIST_ETC}/ssl" "${PERSIST_ETC}/interfaces"

    # Drop the Alpine-shipped server configs so our own templates take over.
    # Everything else (mime types, default policies, …) stays as seeded.
    rm -f "${PERSIST_ETC}/cupsd.conf"      \
          "${PERSIST_ETC}/cups-files.conf" \
          "${PERSIST_ETC}/cupsd.conf.default" \
          "${PERSIST_ETC}/cups-files.conf.default"

    touch "${PERSIST_ETC}/.seeded"
fi

# Replace /etc/cups with a symlink to the persistent location
if [ ! -L /etc/cups ]; then
    rm -rf /etc/cups
fi
ln -sfn "${PERSIST_ETC}" /etc/cups

# Same trick for spool, cache, logs
[ -L /var/spool/cups ] || { rm -rf /var/spool/cups; ln -sfn "${PERSIST_SPOOL}" /var/spool/cups; }
[ -L /var/cache/cups ] || { rm -rf /var/cache/cups; ln -sfn "${PERSIST_CACHE}" /var/cache/cups; }
[ -L /var/log/cups   ] || { rm -rf /var/log/cups;   ln -sfn "${PERSIST_LOGS}"  /var/log/cups;   }

chown -R root:lp "${PERSIST_ETC}"   2>/dev/null || true
chmod -R u+rwX,g+rwX "${PERSIST_ETC}"
chown -R lp:lp   "${PERSIST_SPOOL}" 2>/dev/null || true

log_info "Persistent storage ready."

# ------------------------------------------------------------------------------
# 5. Extra PPDs (user-supplied)
# ------------------------------------------------------------------------------
mkdir -p /usr/share/cups/model
ln -sfn "${PERSIST_PPD_EXTRA}" /usr/share/cups/model/extra
log_info "Drop additional PPD files into ${PERSIST_PPD_EXTRA} and they will appear in CUPS."

# ------------------------------------------------------------------------------
# 6. Default cupsd.conf — written on first seed, otherwise only LogLevel synced
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

# Use the simple 'Port' form. cupsd's own config writer (Web UI 'Save') keeps
# this intact; 'Listen 0.0.0.0:631' has been observed to be silently rewritten
# to 'Listen localhost:631' on Alpine, which kills external access.
Port 631
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

# Job retention
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

write_default_cups_files_conf() {
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
}

# Always (re-)write on first seed. On later boots, preserve user edits and
# only sync LogLevel from the add-on option.
if [ "${FIRST_SEED}" = "true" ] || [ ! -s /etc/cups/cupsd.conf ]; then
    write_default_cupsd_conf
else
    if grep -qE '^[[:space:]]*LogLevel[[:space:]]' /etc/cups/cupsd.conf; then
        sed -i -E "s/^[[:space:]]*LogLevel[[:space:]].*/LogLevel ${LOG_LEVEL}/" /etc/cups/cupsd.conf
    fi
    # Defensive sweep: if a previous v2.0.0 install left us with the broken
    # 'Listen localhost:631' line, replace it. This is what brings existing
    # 2.0.0 deployments back to life without a reset_config.
    if grep -qE '^[[:space:]]*Listen[[:space:]]+localhost:631' /etc/cups/cupsd.conf; then
        log_warning "Found 'Listen localhost:631' in existing cupsd.conf — patching to 'Port 631'"
        sed -i -E 's/^[[:space:]]*Listen[[:space:]]+localhost:631[[:space:]]*$/Port 631/' /etc/cups/cupsd.conf
    fi
    if ! grep -qE '^[[:space:]]*(Port[[:space:]]+631|Listen[[:space:]]+(0\.0\.0\.0|\*):631)' /etc/cups/cupsd.conf; then
        log_warning "No external Listen directive found — adding 'Port 631'"
        sed -i '1i Port 631' /etc/cups/cupsd.conf
    fi
    log_info "Existing cupsd.conf kept (LogLevel synced, listen sanity-checked)."
fi

if [ "${FIRST_SEED}" = "true" ] || [ ! -s /etc/cups/cups-files.conf ]; then
    write_default_cups_files_conf
fi

# ------------------------------------------------------------------------------
# 7. Admin user
# ------------------------------------------------------------------------------
log_info "Configuring admin user '${ADMIN_USER}'"
if ! id "${ADMIN_USER}" >/dev/null 2>&1; then
    adduser -D -G lpadmin "${ADMIN_USER}" 2>/dev/null || true
fi
addgroup "${ADMIN_USER}" lpadmin 2>/dev/null || true
addgroup "${ADMIN_USER}" lp      2>/dev/null || true
echo "${ADMIN_USER}:${ADMIN_PASS}" | chpasswd

# ------------------------------------------------------------------------------
# 8. USB diagnostics
# ------------------------------------------------------------------------------
log_info "=== USB devices visible to the container ==="
lsusb 2>/dev/null || echo "  lsusb not available"
log_info "=== USB printer character devices ==="
ls -la /dev/usb/lp* 2>/dev/null || echo "  No /dev/usb/lp* devices found"
ls -la /dev/bus/usb 2>/dev/null || echo "  No /dev/bus/usb tree found"

chmod 755 /usr/lib/cups/backend/usb 2>/dev/null || true

# ------------------------------------------------------------------------------
# 9. Avahi / mDNS
# ------------------------------------------------------------------------------
setup_avahi() {
    log_info "Configuring Avahi"
    mkdir -p /var/run/avahi-daemon /var/run/dbus /etc/avahi/services

    local avahi_host
    avahi_host=$(hostname -s 2>/dev/null || echo "cups-server")

    # enable-dbus=no — works without a running system bus, which is the
    # situation in this container. v2.0.0 had enable-dbus=yes which silently
    # broke Avahi when dbus failed to come up.
    cat > /etc/avahi/avahi-daemon.conf <<AVAHI
[server]
host-name=${avahi_host}
domain-name=local
use-ipv4=yes
use-ipv6=no
enable-dbus=no
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
        log_warning "D-Bus failed to start — Avahi runs in standalone mode (this is fine)"
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
# 10. Nginx proxy on :8631 (for hass_ingress)
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
# 11. Post-start: enable sharing on existing printers, sanity-check listen
# ------------------------------------------------------------------------------
enable_printer_sharing() {
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

verify_listen() {
    sleep 3
    # Try ss first, fall back to netstat, then to a connection probe
    local listening=""
    if command -v ss >/dev/null 2>&1; then
        listening=$(ss -ltn 2>/dev/null | awk '$4 ~ /:631$/ {print $4}')
    elif command -v netstat >/dev/null 2>&1; then
        listening=$(netstat -ltn 2>/dev/null | awk '$4 ~ /:631$/ {print $4}')
    fi

    if [ -z "${listening}" ]; then
        log_warning "Could not verify listen state (no ss/netstat) — trying curl"
        if curl -sS --max-time 2 http://127.0.0.1:631/ >/dev/null 2>&1; then
            log_info "cupsd answers on 127.0.0.1:631"
        else
            log_error "cupsd does NOT answer on 127.0.0.1:631 — check the log above"
        fi
        return
    fi

    log_info "cupsd is listening on: ${listening}"
    if echo "${listening}" | grep -qE '^(127\.0\.0\.1|::1):631$'; then
        log_error "============================================================"
        log_error " cupsd is bound to localhost ONLY — Web UI will not be"
        log_error " reachable from the LAN. This is the v2.0.0 bug."
        log_error " Set reset_config: true in the add-on options once and"
        log_error " restart, OR edit /data/cups/etc/cupsd.conf and replace"
        log_error " the Listen line with:   Port 631"
        log_error "============================================================"
    fi
}

# ------------------------------------------------------------------------------
# 12. Graceful shutdown
# ------------------------------------------------------------------------------
cleanup() {
    log_info "Shutting down…"
    killall -TERM cupsd        2>/dev/null || true
    killall -TERM avahi-daemon 2>/dev/null || true
    killall -TERM dbus-daemon  2>/dev/null || true
    killall -TERM nginx        2>/dev/null || true
    sleep 1
    log_info "Bye."
    exit 0
}
trap cleanup SIGTERM SIGINT

# ------------------------------------------------------------------------------
# 13. Boot sequence
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
( verify_listen )          &

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

wait ${CUPSD_PID}
