#!/bin/bash
# ==============================================================================
# Home Assistant CUPS Add-on  —  Main Entrypoint  (v2.0.7)
#
# v2.0.7: Web UI on http://<HA-IP>:631/ returned 'Not Found'. cups-files.conf
# pointed DocumentRoot at /usr/share/cups/doc, but Alpine's cups package
# ships the HTML at /usr/share/cups/doc-root (built with
# --with-docdir=…/doc-root). cupsd answered 404 on '/' because index.html
# was nowhere along the configured path. Path is now auto-detected at boot
# and the self-heal block fixes existing cups-files.conf in place.
#
# v2.0.6: the actual root cause of the v2.0.0–v2.0.5 restart loop. The
# 'cupsd -t' diagnostic added in v2.0.5 finally surfaced it:
#
#   File or directory for "TempDir /var/spool/cups/tmp" on line 9 of
#   /etc/cups/cups-files.conf does not exist.
#
# cups-files.conf points TempDir at /var/spool/cups/tmp, which is the
# symlinked PERSIST_SPOOL. The script created PERSIST_SPOOL but never
# the 'tmp' subdir inside it, and CUPS 2.4 refuses to start cupsd if
# TempDir is missing. Fix: mkdir + chown lp:lp + chmod 1770 the tmp dir
# at boot. All the v2.0.3–v2.0.5 diagnostics are kept — they earned it.
#
# v2.0.5: the v2.0.4 logs proved that cupsd dies BEFORE it opens its own
# ErrorLog (no [CUPSD] lines, only the synthetic "cupsd exited with code 1"
# we added). That means the failure reason goes to stderr, which the script
# wasn't capturing. v2.0.5:
#   - runs 'cupsd -t' as a dry-run before the real launch and prefixes its
#     output with [CUPSD-TEST] so the exact bad directive surfaces in the
#     supervisor log, and
#   - redirects cupsd's stderr to /tmp/cupsd.stderr and tails that file
#     with a [CUPSD-STDERR] prefix, so early-init errors (the ones too
#     early for /var/log/cups/error_log) are no longer invisible.
#
# v2.0.4: surfaces cupsd's error log in the supervisor log. v2.0.3 fixed
# the most obvious config bugs but in some installs cupsd still dies
# silently within a few seconds of starting. Its errors go to
# /var/log/cups/error_log, which is invisible from outside the container;
# the script now tails that file with a [CUPSD] prefix and also logs the
# wait() exit code so the next restart loop is debuggable instead of mute.
#
# v2.0.3: two startup-crash fixes.
#   1. cupsd.conf no longer contains 'FileDevice' / 'SystemGroup' — those
#      are cups-files.conf-only directives in CUPS 2.4 and cupsd refuses to
#      load a cupsd.conf that has them. FileDevice now lives in
#      cups-files.conf where it belongs, and the self-heal block strips
#      them out of existing /data/cups/etc/cupsd.conf on upgrade.
#   2. start_avahi's 'return 1' on failure used to terminate the whole
#      script under 'set -e' (the AVAHI_OK=$? assignment was never reached,
#      so cupsd never started). The exit-code capture is now wrapped in an
#      if/else so a missing Avahi never kills the add-on.
#
# v2.0.2: bridged networking is now the default (host_network: false in
# config.yaml). cupsd binds inside the container's own network namespace
# and the supervisor forwards :631 / :8631 / :5353 from the host. This is
# more reliable than host networking, but mDNS/AirPrint discovery is
# limited because broadcasts don't traverse the docker bridge.
#
# v2.0.1: fixed the v2.0.0 "Listen localhost:631" regression and added
# v1.x → v2.x migration plus a startup listen sanity check. All of that
# is still in here; see the conditional self-heal in section 6.
# ==============================================================================
set -eu

# ------------------------------------------------------------------------------
# Logging helpers
# ------------------------------------------------------------------------------
log_info()    { echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_warning() { echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_error()   { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }

log_info "============================================"
log_info " CUPS Print Server Add-on  v2.0.7"
log_info " Bridged networking, persistent config"
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
    ADMIN_USER=$(jq  -r '.admin_username // "admin"'    "${OPTIONS_FILE}")
    ADMIN_PASS=$(jq  -r '.admin_password // "changeme"' "${OPTIONS_FILE}")
    LOG_LEVEL=$(jq   -r '.log_level      // "warn"'     "${OPTIONS_FILE}")
    RESET_CONFIG=$(jq -r '.reset_config  // false'      "${OPTIONS_FILE}")
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

# v1.x location (used only for the one-time migration)
LEGACY_V1_CONF="${DATA_ROOT}/config"
LEGACY_V1_SPOOL="${DATA_ROOT}/state/spool"

log_info "Preparing persistent storage in ${DATA_ROOT}"
# NOTE: ${PERSIST_SPOOL}/tmp must exist on disk — cups-files.conf points
# TempDir at /var/spool/cups/tmp (which is the symlinked PERSIST_SPOOL),
# and CUPS 2.4's config validator refuses to start cupsd if TempDir is
# missing. That was the root cause of the v2.0.0–v2.0.5 restart loop.
mkdir -p "${PERSIST_ETC}" "${PERSIST_SPOOL}" "${PERSIST_SPOOL}/tmp" \
         "${PERSIST_CACHE}" "${PERSIST_LOGS}" "${PERSIST_PPD_EXTRA}"

# Optional: nuke persistent config when the user toggles reset_config: true
if [ "${RESET_CONFIG}" = "true" ]; then
    log_warning "reset_config=true → wiping ${PERSIST_ETC}"
    rm -rf "${PERSIST_ETC}"
    mkdir -p "${PERSIST_ETC}"
fi

# ------------------------------------------------------------------------------
# 3. Migration from v1.x  (only on first v2 boot)
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
    rm -f "${PERSIST_ETC}/cupsd.conf" \
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

# Same trick for spool, cache, logs (so jobs and history survive too)
[ -L /var/spool/cups ] || { rm -rf /var/spool/cups; ln -sfn "${PERSIST_SPOOL}" /var/spool/cups; }
[ -L /var/cache/cups ] || { rm -rf /var/cache/cups; ln -sfn "${PERSIST_CACHE}" /var/cache/cups; }
[ -L /var/log/cups   ] || { rm -rf /var/log/cups;   ln -sfn "${PERSIST_LOGS}"  /var/log/cups;   }

chown -R root:lp     "${PERSIST_ETC}"   2>/dev/null || true
chmod -R u+rwX,g+rwX "${PERSIST_ETC}"
chown -R lp:lp       "${PERSIST_SPOOL}" 2>/dev/null || true
# TempDir wants sticky-bit world-readable (matches Alpine's default cupsd
# permissions for /var/spool/cups/tmp).
chmod 1770           "${PERSIST_SPOOL}/tmp" 2>/dev/null || true

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

# NOTE: FileDevice and SystemGroup intentionally live in cups-files.conf only.
# In CUPS 2.4 (Alpine 3.23) putting them here causes cupsd to refuse the
# config with "Bad directive ... must be in cups-files.conf instead." That
# regression silently bricked v2.0.0–v2.0.2 on some hosts.

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

# Alpine builds CUPS with --with-docdir=/usr/share/cups/doc-root, but
# upstream CUPS uses /usr/share/cups/doc. Detect at runtime so the Web UI
# root '/' actually serves index.html instead of returning 'Not Found'.
detect_cups_docroot() {
    local d
    for d in /usr/share/cups/doc-root /usr/share/cups/doc; do
        if [ -d "${d}" ] && [ -f "${d}/index.html" ]; then
            echo "${d}"
            return
        fi
    done
    # Fallback: first dir that simply exists
    for d in /usr/share/cups/doc-root /usr/share/cups/doc; do
        if [ -d "${d}" ]; then
            echo "${d}"
            return
        fi
    done
    echo "/usr/share/cups/doc-root"
}
CUPS_DOCROOT="$(detect_cups_docroot)"
log_info "CUPS DocumentRoot: ${CUPS_DOCROOT}"

write_default_cups_files_conf() {
    log_info "Writing default cups-files.conf"
    cat > /etc/cups/cups-files.conf <<CFCONF
# Generated by HA CUPS add-on
SystemGroup lpadmin root wheel
FileDevice Yes
ServerRoot   /etc/cups
ServerBin    /usr/lib/cups
DataDir      /usr/share/cups
DocumentRoot ${CUPS_DOCROOT}
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

if [ "${FIRST_SEED}" = "true" ] || [ ! -s /etc/cups/cupsd.conf ]; then
    write_default_cupsd_conf
else
    if grep -qE '^[[:space:]]*LogLevel[[:space:]]' /etc/cups/cupsd.conf; then
        sed -i -E "s/^[[:space:]]*LogLevel[[:space:]].*/LogLevel ${LOG_LEVEL}/" /etc/cups/cupsd.conf
    fi
    # Self-heal: replace 'Listen localhost:631' if a previous v2.0.0 install
    # left that broken line behind.
    if grep -qE '^[[:space:]]*Listen[[:space:]]+localhost:631' /etc/cups/cupsd.conf; then
        log_warning "Found 'Listen localhost:631' in existing cupsd.conf — patching to 'Port 631'"
        sed -i -E 's/^[[:space:]]*Listen[[:space:]]+localhost:631[[:space:]]*$/Port 631/' /etc/cups/cupsd.conf
    fi
    if ! grep -qE '^[[:space:]]*(Port[[:space:]]+631|Listen[[:space:]]+(0\.0\.0\.0|\*):631)' /etc/cups/cupsd.conf; then
        log_warning "No external Listen directive found — prepending 'Port 631'"
        sed -i '1i Port 631' /etc/cups/cupsd.conf
    fi
    # Self-heal: in CUPS 2.4 the directives FileDevice and SystemGroup MUST be
    # in cups-files.conf — cupsd refuses a cupsd.conf that contains them. The
    # v2.0.0–v2.0.2 templates wrongly wrote them here, which prevented cupsd
    # from starting on existing installs. Strip them in place; the equivalent
    # values are (or will be) written to cups-files.conf below.
    if grep -qE '^[[:space:]]*(FileDevice|SystemGroup)[[:space:]]' /etc/cups/cupsd.conf; then
        log_warning "Stripping cups-files.conf-only directives (FileDevice/SystemGroup) from cupsd.conf"
        sed -i -E '/^[[:space:]]*(FileDevice|SystemGroup)[[:space:]]/d' /etc/cups/cupsd.conf
    fi
    log_info "Existing cupsd.conf kept (LogLevel synced, listen + cups-files-only directives sanity-checked)."
fi

if [ "${FIRST_SEED}" = "true" ] || [ ! -s /etc/cups/cups-files.conf ]; then
    write_default_cups_files_conf
else
    # Self-heal: make sure FileDevice ends up in cups-files.conf (it was
    # misplaced in cupsd.conf in v2.0.0-v2.0.2 — see note above).
    if ! grep -qE '^[[:space:]]*FileDevice[[:space:]]' /etc/cups/cups-files.conf; then
        log_warning "FileDevice missing in cups-files.conf — appending"
        echo "FileDevice Yes" >> /etc/cups/cups-files.conf
    fi
    # Self-heal: v2.0.3–v2.0.6 hard-coded DocumentRoot to /usr/share/cups/doc,
    # but Alpine's cups package installs the Web UI at /usr/share/cups/doc-root.
    # The result was HTTP 404 on '/'. Replace stale paths with the auto-detected
    # one so existing installs heal without reset_config.
    if grep -qE '^[[:space:]]*DocumentRoot[[:space:]]' /etc/cups/cups-files.conf; then
        CURRENT_DOCROOT=$(awk '/^[[:space:]]*DocumentRoot[[:space:]]/ {print $2; exit}' /etc/cups/cups-files.conf)
        if [ -n "${CURRENT_DOCROOT}" ] && [ ! -f "${CURRENT_DOCROOT}/index.html" ]; then
            log_warning "DocumentRoot ${CURRENT_DOCROOT} has no index.html — repointing to ${CUPS_DOCROOT}"
            sed -i -E "s|^[[:space:]]*DocumentRoot[[:space:]].*|DocumentRoot ${CUPS_DOCROOT}|" /etc/cups/cups-files.conf
        fi
    else
        log_warning "DocumentRoot missing in cups-files.conf — appending ${CUPS_DOCROOT}"
        echo "DocumentRoot ${CUPS_DOCROOT}" >> /etc/cups/cups-files.conf
    fi
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
echo "${ADMIN_USER}:${ADMIN_PASS}" | chpasswd 2>/dev/null || \
    log_warning "chpasswd failed — admin password may be stale; Web UI login could fail"

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
#
# In bridged mode (host_network: false) Avahi can only really respond to
# unicast queries directed at the container's IP — broadcasts don't escape
# the docker bridge. That's expected; printing itself works regardless.
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
        log_info "Avahi running (limited reach in bridged mode)"
        return 0
    fi

    log_warning "Avahi standard start failed — retrying with --no-drop-root"
    if avahi-daemon --no-rlimits --no-drop-root --daemonize 2>/dev/null; then
        log_info "Avahi running (no-drop-root, limited reach in bridged mode)"
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
# 11. Post-start: enable sharing, sanity-check listen
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
    local listening=""
    if command -v ss >/dev/null 2>&1; then
        listening=$(ss -ltn 2>/dev/null | awk '$4 ~ /:631$/ {print $4}')
    elif command -v netstat >/dev/null 2>&1; then
        listening=$(netstat -ltn 2>/dev/null | awk '$4 ~ /:631$/ {print $4}')
    fi

    if [ -z "${listening}" ]; then
        log_warning "Could not enumerate sockets (no ss/netstat) — falling back to curl probe"
        if curl -sS --max-time 2 http://127.0.0.1:631/ >/dev/null 2>&1; then
            log_info "cupsd answers on 127.0.0.1:631"
        else
            log_error "cupsd does NOT answer on 127.0.0.1:631 — see log above"
        fi
        return
    fi

    log_info "cupsd is listening on: ${listening}"
    if echo "${listening}" | grep -qE '^(127\.0\.0\.1|::1):631$'; then
        log_error "============================================================"
        log_error " cupsd is bound to localhost ONLY — Web UI will NOT be"
        log_error " reachable. Check /data/cups/etc/cupsd.conf for a 'Listen'"
        log_error " line. The expected directive is:   Port 631"
        log_error " Or set reset_config: true once and restart."
        log_error "============================================================"
    fi
}

# ------------------------------------------------------------------------------
# 12. Graceful shutdown
# ------------------------------------------------------------------------------
TAIL_PID=""
TAIL_STDERR_PID=""
cleanup() {
    log_info "Shutting down…"
    killall -TERM cupsd        2>/dev/null || true
    killall -TERM avahi-daemon 2>/dev/null || true
    killall -TERM dbus-daemon  2>/dev/null || true
    killall -TERM nginx        2>/dev/null || true
    [ -n "${TAIL_PID}" ]        && kill -TERM "${TAIL_PID}"        2>/dev/null || true
    [ -n "${TAIL_STDERR_PID}" ] && kill -TERM "${TAIL_STDERR_PID}" 2>/dev/null || true
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

# Avahi failure must NOT abort the boot — printing works without mDNS.
# (Plain 'start_avahi; AVAHI_OK=$?' tripped 'set -e' on the 'return 1' path
# in <=v2.0.2 and killed the script before cupsd was even launched.)
AVAHI_OK=1
if start_avahi; then
    AVAHI_OK=0
fi

start_nginx

# Dry-run the config FIRST. 'cupsd -t' parses cups-files.conf + cupsd.conf
# with the same checks the real daemon applies and prints any complaint to
# stdout/stderr before exiting. In v2.0.4 cupsd died with code 1 inside a
# second of starting and never wrote to /var/log/cups/error_log, which means
# the daemon never got far enough to OPEN that file — the cause was on
# stderr. The dry-run forces the reason into the supervisor log up front.
log_info "Validating cupsd configuration (dry run: cupsd -t)"
CUPSD_TEST_RC=0
CUPSD_TEST_OUT=$(/usr/sbin/cupsd -t 2>&1) || CUPSD_TEST_RC=$?
if [ -n "${CUPSD_TEST_OUT}" ]; then
    while IFS= read -r line; do
        echo "[CUPSD-TEST] ${line}"
    done <<< "${CUPSD_TEST_OUT}"
fi
if [ "${CUPSD_TEST_RC}" -ne 0 ]; then
    log_error "cupsd configuration is INVALID (cupsd -t returned ${CUPSD_TEST_RC}) — see [CUPSD-TEST] lines above for the offending directive"
else
    log_info "cupsd configuration valid"
fi

# Two log channels to surface anything cupsd says:
#   1) /var/log/cups/error_log — populated once cupsd's ErrorLog is open
#   2) /tmp/cupsd.stderr       — captures stderr BEFORE that, i.e. fatal
#      config / permission errors during initialisation. v2.0.4 missed this
#      and the user only saw "cupsd exited with code 1" with no reason.
mkdir -p /var/log/cups
touch /var/log/cups/error_log
( tail -n 0 -F /var/log/cups/error_log 2>/dev/null | \
    while IFS= read -r line; do echo "[CUPSD] ${line}"; done ) &
TAIL_PID=$!

CUPSD_STDERR=/tmp/cupsd.stderr
: > "${CUPSD_STDERR}"
( tail -n 0 -F "${CUPSD_STDERR}" 2>/dev/null | \
    while IFS= read -r line; do echo "[CUPSD-STDERR] ${line}"; done ) &
TAIL_STDERR_PID=$!

log_info "Starting cupsd (foreground)"
/usr/sbin/cupsd -f 2>>"${CUPSD_STDERR}" &
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
    log_info "  Avahi  :  ACTIVE (bridged mode — discovery limited)"
else
    log_info "  Avahi  :  INACTIVE (manual setup needed on clients)"
fi
log_info "  Storage:  ${PERSIST_ETC}  ←  printers persist here"
log_info "============================================"

# Don't let set -e swallow cupsd's exit code — we want to log it.
CUPSD_EXIT=0
wait ${CUPSD_PID} || CUPSD_EXIT=$?
log_error "cupsd exited with code ${CUPSD_EXIT} — see [CUPSD] lines above for the actual reason"
# Give the background tail a beat to flush any final error_log lines before
# the script (and the container with it) goes away.
sleep 2
exit ${CUPSD_EXIT}
