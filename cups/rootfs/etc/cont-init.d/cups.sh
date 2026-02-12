#!/bin/bash
# ==============================================================================
# Home Assistant CUPS Add-on - Main Entrypoint
# Pure bash (no bashio/S6 required) - runs on plain Alpine
# ==============================================================================
set -e

# --- Logging helpers ---
log_info()    { echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_warning() { echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_error()   { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*"; }

log_info "============================================"
log_info " CUPS Print Server Add-on"
log_info " with Avahi/mDNS & Printer Sharing"
log_info "============================================"

# ==============================================================================
# 1. READ HA ADD-ON OPTIONS
# ==============================================================================
OPTIONS_FILE="/data/options.json"
if [ -f "${OPTIONS_FILE}" ]; then
    ADMIN_USER=$(jq -r '.admin_username // "admin"' "${OPTIONS_FILE}")
    ADMIN_PASS=$(jq -r '.admin_password // "admin"' "${OPTIONS_FILE}")
else
    log_warning "No options.json found, using defaults"
    ADMIN_USER="admin"
    ADMIN_PASS="admin"
fi

# ==============================================================================
# 2. PERSISTENT DATA DIRECTORIES
# ==============================================================================
log_info "Setting up persistent data directories..."
mkdir -p /data/cups/cache
mkdir -p /data/cups/logs
mkdir -p /data/cups/state
mkdir -p /data/cups/config
mkdir -p /data/cups/ppd

# Set proper permissions
chown -R root:lp /data/cups 2>/dev/null || true
chmod -R 775 /data/cups

# Ensure /etc/cups exists
mkdir -p /etc/cups

# ==============================================================================
# 3. DOWNLOAD PPD FILES (first run only)
# ==============================================================================

# Dymo LabelWriter PPDs
if [ ! -f "/data/cups/ppd/dymo/lw400.ppd" ]; then
    log_info "Downloading Dymo PPD files..."
    mkdir -p /data/cups/ppd/dymo
    wget -q -O /data/cups/ppd/dymo/lw400.ppd \
        "https://raw.githubusercontent.com/matthiasbock/dymo-cups-drivers/master/ppd/lw400.ppd" 2>/dev/null || true
    wget -q -O /data/cups/ppd/dymo/lw450.ppd \
        "https://raw.githubusercontent.com/matthiasbock/dymo-cups-drivers/master/ppd/lw450.ppd" 2>/dev/null || true
    # Modify PPDs to use generic filter
    sed -i 's|raster2dymolw|rastertolabel|g' /data/cups/ppd/dymo/*.ppd 2>/dev/null || true
    log_info "Dymo PPD files ready"
fi

# Ricoh PPDs
if [ ! -f "/data/cups/ppd/ricoh/Ricoh_IM_C3000.ppd" ]; then
    log_info "Downloading Ricoh PPD files..."
    mkdir -p /data/cups/ppd/ricoh
    wget -q -O /data/cups/ppd/ricoh/Ricoh_IM_C3000.ppd \
        "https://www.openprinting.org/ppd-o-matic.php?driver=Postscript&printer=Ricoh-IM_C3000&show=0" 2>/dev/null || true
    wget -q -O /data/cups/ppd/ricoh/Ricoh_Aficio_MP_C3000.ppd \
        "https://www.openprinting.org/ppd-o-matic.php?driver=Postscript&printer=Ricoh-Aficio_MP_C3000&show=0" 2>/dev/null || true
    log_info "Ricoh PPD files ready"
fi

# Link PPDs into CUPS model directory
mkdir -p /usr/share/cups/model
ln -sf /data/cups/ppd/dymo /usr/share/cups/model/dymo 2>/dev/null || true
ln -sf /data/cups/ppd/ricoh /usr/share/cups/model/ricoh 2>/dev/null || true
ln -sf /data/cups/ppd /usr/share/cups/model/custom 2>/dev/null || true

log_info "=== Available PPD files ==="
ls -la /data/cups/ppd/dymo/ 2>/dev/null || echo "  No Dymo PPDs found"
ls -la /data/cups/ppd/ricoh/ 2>/dev/null || echo "  No Ricoh PPDs found"

# ==============================================================================
# 4. ADMIN USER SETUP
# ==============================================================================
log_info "Setting up admin user: ${ADMIN_USER}"
adduser -D -G lpadmin "${ADMIN_USER}" 2>/dev/null || true
addgroup "${ADMIN_USER}" lpadmin 2>/dev/null || true
echo "${ADMIN_USER}:${ADMIN_PASS}" | chpasswd

# ==============================================================================
# 5. LIST USB DEVICES
# ==============================================================================
log_info "=== Detected USB Devices ==="
lsusb 2>/dev/null || echo "  lsusb not available"
log_info "=== USB Printer Devices ==="
ls -la /dev/usb/lp* 2>/dev/null || echo "  No USB printer devices found at /dev/usb/"
ls -la /dev/bus/usb/ 2>/dev/null || echo "  No USB bus found"

# ==============================================================================
# 6. WRITE CUPS CONFIGURATION (with Sharing enabled!)
# ==============================================================================
log_info "Writing CUPS configuration with sharing enabled..."
cat > /data/cups/config/cupsd.conf << 'CUPSCONF'
# CUPS Configuration for Home Assistant Add-on
# With Avahi/mDNS support and printer sharing enabled
#
# Access:
#   Direct:   http://<HA-IP>:631
#   Ingress:  http://<HA-IP>:8631 (CSP headers removed)
#   Printing: ipp://<HA-IP>:631/printers/<printer-name>

# Server settings
ServerName localhost
ServerAdmin root@localhost
ServerAlias *
HostNameLookups Off

# Listen on all interfaces on port 631
Listen 0.0.0.0:631

# DISABLE ENCRYPTION - required for hass_ingress proxy
DefaultEncryption Never

# Enable web interface
WebInterface Yes

# =============================================
# PRINTER SHARING / BROWSING - IMPORTANT!
# Without these, CUPS shows "No network sharing"
# =============================================
Browsing On
BrowseLocalProtocols dnssd
BrowseWebIF Yes
DefaultShared Yes

# Log settings
LogLevel warn
PageLogFormat

# Allow access from local networks
<Location />
  Order allow,deny
  Allow all
</Location>

# Admin access
<Location /admin>
  Order allow,deny
  Allow all
  AuthType Basic
  Require user @SYSTEM
</Location>

# Admin configuration pages
<Location /admin/conf>
  AuthType Basic
  Require user @SYSTEM
  Order allow,deny
  Allow all
</Location>

# Job management
<Location /jobs>
  Order allow,deny
  Allow all
</Location>

# Printer operations
<Location /printers>
  Order allow,deny
  Allow all
</Location>

# IPP endpoint
<Location /ipp>
  Order allow,deny
  Allow all
</Location>

# Policy
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

# Default settings
DefaultAuthType Basic
JobSheets none,none
PreserveJobHistory Off
PreserveJobFiles Off
MaxJobs 100
MaxJobsPerUser 25

# USB Backend settings
FileDevice Yes

# System group
SystemGroup lpadmin root wheel
CUPSCONF

# Symlink config
ln -sf /data/cups/config/cupsd.conf /etc/cups/cupsd.conf

# Keep existing printers.conf if present
if [ -f /data/cups/config/printers.conf ]; then
    ln -sf /data/cups/config/printers.conf /etc/cups/printers.conf
fi

# Ensure USB backend has correct permissions
chmod 755 /usr/lib/cups/backend/usb 2>/dev/null || true

log_info "CUPS configuration written."

# ==============================================================================
# 7. AVAHI / mDNS SETUP
# ==============================================================================
setup_avahi() {
    log_info "Setting up Avahi daemon for mDNS/DNS-SD printer discovery..."

    # Create required directories
    mkdir -p /var/run/avahi-daemon
    mkdir -p /var/run/dbus
    mkdir -p /etc/avahi/services

    # Determine hostname
    AVAHI_HOST=$(hostname -s 2>/dev/null || echo "cups-server")
    log_info "Avahi hostname: ${AVAHI_HOST}"

    # Write avahi-daemon.conf
    cat > /etc/avahi/avahi-daemon.conf <<AVAHIEOF
[server]
host-name=${AVAHI_HOST}
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
enable-reflector=yes
reflect-ipv=no

[rlimits]
AVAHIEOF

    log_info "Avahi configuration written."
}

start_dbus() {
    log_info "Starting D-Bus system bus..."
    # Clean stale pid
    rm -f /var/run/dbus/pid
    rm -f /var/run/dbus/system_bus_socket
    # Generate machine-id if missing
    if [ ! -f /var/lib/dbus/machine-id ]; then
        dbus-uuidgen > /var/lib/dbus/machine-id 2>/dev/null || true
    fi
    # Start dbus
    dbus-daemon --system 2>/dev/null
    if [ $? -eq 0 ]; then
        log_info "D-Bus started successfully."
    else
        log_warning "D-Bus failed to start. Avahi may not work properly."
    fi
}

start_avahi() {
    if ! command -v avahi-daemon &>/dev/null; then
        log_warning "Avahi daemon not installed! Printers will NOT be auto-discoverable."
        log_warning "Clients can still print via ipp://<HA-IP>:631/printers/<name>"
        return 1
    fi

    log_info "Starting Avahi daemon..."

    # Kill any existing instance
    killall avahi-daemon 2>/dev/null || true
    sleep 1

    # Start avahi-daemon (daemonize into background)
    avahi-daemon --no-rlimits --daemonize 2>&1

    if [ $? -eq 0 ]; then
        log_info "Avahi daemon started successfully."
        log_info "Printers will be advertised via mDNS/DNS-SD (Bonjour/AirPrint)."
        return 0
    else
        log_warning "Avahi daemon failed to start (normal mode). Trying no-drop-root..."
        avahi-daemon --no-rlimits --no-drop-root --daemonize 2>&1
        if [ $? -eq 0 ]; then
            log_info "Avahi daemon started (no-drop-root mode)."
            return 0
        else
            log_warning "Avahi could not start. Printers will NOT be auto-discoverable."
            log_warning "Clients can still print via ipp://<HA-IP>:631/printers/<name>"
            return 1
        fi
    fi
}

# ==============================================================================
# 8. ENABLE SHARING ON EXISTING PRINTERS (runs after CUPS is up)
# ==============================================================================
enable_printer_sharing() {
    log_info "Waiting for CUPS to be ready..."
    # Wait until CUPS responds
    for i in $(seq 1 15); do
        if lpstat -r 2>/dev/null | grep -q "running"; then
            break
        fi
        sleep 1
    done

    log_info "Enabling sharing on all configured printers..."

    # Enable global sharing
    cupsctl --share-printers 2>/dev/null || true

    # Get list of all printers
    PRINTERS=$(lpstat -p 2>/dev/null | awk '{print $2}')

    if [ -z "${PRINTERS}" ]; then
        log_info "No printers configured yet. New printers will be shared by default (DefaultShared Yes)."
        return
    fi

    for PRINTER in ${PRINTERS}; do
        log_info "  Enabling sharing for: ${PRINTER}"
        lpadmin -p "${PRINTER}" -o printer-is-shared=true 2>/dev/null || \
            log_warning "  Could not enable sharing for ${PRINTER}"
    done

    log_info "Printer sharing configuration complete."
}

# ==============================================================================
# 9. START NGINX (for hass_ingress iframe proxy)
# ==============================================================================
start_nginx() {
    if command -v nginx &>/dev/null; then
        log_info "Starting nginx reverse proxy on port 8631..."
        mkdir -p /run/nginx
        nginx 2>/dev/null
        if [ $? -eq 0 ]; then
            log_info "Nginx started (port 8631 -> CUPS port 631, CSP headers removed)."
        else
            log_warning "Nginx failed to start. hass_ingress iframe embedding may not work."
        fi
    fi
}

# ==============================================================================
# 10. MAIN STARTUP SEQUENCE
# ==============================================================================

# Trap for clean shutdown
cleanup() {
    log_info "Shutting down..."
    killall cupsd 2>/dev/null || true
    killall avahi-daemon 2>/dev/null || true
    killall dbus-daemon 2>/dev/null || true
    killall nginx 2>/dev/null || true
    log_info "Shutdown complete."
    exit 0
}
trap cleanup SIGTERM SIGINT

# Start D-Bus (required for Avahi)
start_dbus

# Setup and start Avahi
setup_avahi
start_avahi
AVAHI_STATUS=$?

# Start Nginx proxy
start_nginx

# Start CUPS daemon in foreground (background it so we can run post-start tasks)
log_info "Starting CUPS daemon..."
/usr/sbin/cupsd -f &
CUPSD_PID=$!
log_info "CUPS daemon started (PID: ${CUPSD_PID})"

# Enable sharing on existing printers (background task)
(
    enable_printer_sharing
) &

# Summary
log_info "============================================"
log_info " CUPS Print Server running!"
log_info "--------------------------------------------"
log_info " Web UI:   http://<HA-IP>:631"
log_info " Admin:    http://<HA-IP>:631/admin"
log_info " Ingress:  http://<HA-IP>:8631"
log_info " IPP:      ipp://<HA-IP>:631/printers/<name>"
log_info " Admin:    ${ADMIN_USER} / ********"
if [ ${AVAHI_STATUS:-1} -eq 0 ]; then
    log_info " Avahi:    ACTIVE (Bonjour/AirPrint discovery)"
else
    log_info " Avahi:    INACTIVE (manual printer setup needed)"
fi
log_info "============================================"

# Wait for CUPS process (keeps container running)
wait ${CUPSD_PID}
