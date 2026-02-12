#!/usr/bin/env bashio
# ==============================================================================
# Home Assistant CUPS Add-on: run.sh
# Enhanced with Avahi/mDNS support and printer sharing
# ==============================================================================

# --- Configuration from HA Add-on options ---
ADMIN_USERNAME=$(bashio::config 'admin_username' 'admin')
ADMIN_PASSWORD=$(bashio::config 'admin_password' 'password')

# --- Persistent data directories ---
DATA_DIR="/data/cups"
CUPS_CONF_DIR="${DATA_DIR}/config"
CUPS_CACHE_DIR="${DATA_DIR}/cache"
CUPS_LOG_DIR="${DATA_DIR}/logs"
CUPS_STATE_DIR="${DATA_DIR}/state"
CUPS_PPD_DIR="${DATA_DIR}/ppd"

bashio::log.info "============================================"
bashio::log.info " CUPS Print Server Add-on (with Avahi)"
bashio::log.info "============================================"

# --- Create persistent directories ---
mkdir -p "${CUPS_CONF_DIR}" "${CUPS_CACHE_DIR}" "${CUPS_LOG_DIR}" "${CUPS_STATE_DIR}" "${CUPS_PPD_DIR}"

# --- Symlink persistent dirs into CUPS paths ---
# Config
if [ ! -L /etc/cups ] && [ -d /etc/cups ]; then
    # First run: copy default config, then symlink
    cp -rn /etc/cups/* "${CUPS_CONF_DIR}/" 2>/dev/null || true
    rm -rf /etc/cups
fi
ln -sf "${CUPS_CONF_DIR}" /etc/cups

# Cache
rm -rf /var/cache/cups
ln -sf "${CUPS_CACHE_DIR}" /var/cache/cups

# Logs
rm -rf /var/log/cups
ln -sf "${CUPS_LOG_DIR}" /var/log/cups

# State (spool)
mkdir -p "${CUPS_STATE_DIR}/spool"
rm -rf /var/spool/cups
ln -sf "${CUPS_STATE_DIR}/spool" /var/spool/cups

# PPD
mkdir -p /etc/cups/ppd 2>/dev/null || true
if [ -d "${CUPS_PPD_DIR}" ] && [ "$(ls -A ${CUPS_PPD_DIR})" ]; then
    cp -rn "${CUPS_PPD_DIR}"/* /etc/cups/ppd/ 2>/dev/null || true
fi

# --- Set admin user credentials ---
bashio::log.info "Setting up admin user: ${ADMIN_USERNAME}"
if id "${ADMIN_USERNAME}" &>/dev/null; then
    echo "${ADMIN_USERNAME}:${ADMIN_PASSWORD}" | chpasswd
else
    adduser -D -G lpadmin "${ADMIN_USERNAME}" 2>/dev/null || true
    echo "${ADMIN_USERNAME}:${ADMIN_PASSWORD}" | chpasswd
fi
# Ensure admin user is in lpadmin group
addgroup "${ADMIN_USERNAME}" lpadmin 2>/dev/null || true

# --- Write cupsd.conf ---
bashio::log.info "Writing CUPS configuration..."
cat > /etc/cups/cupsd.conf <<'CUPSCONF'
# CUPS Configuration for Home Assistant Add-on
# With Avahi/mDNS support and printer sharing enabled
#
# Access:
#   Direct: http://<HA-IP>:631
#   Printing: ipp://<HA-IP>:631/printers/<printer-name>

# Server settings
ServerName *
ServerAdmin root@localhost
ServerAlias *
HostNameLookups Off

# Listen on all interfaces on port 631
Port 631

# DISABLE ALL ENCRYPTION - required for hass_ingress proxy
DefaultEncryption Never
Encryption Never

# Enable web interface
WebInterface Yes

# =============================================
# PRINTER SHARING / BROWSING
# =============================================
Browsing On
BrowseLocalProtocols dnssd
BrowseWebIF Yes
DefaultShared Yes

# Log settings
LogLevel warn
PageLogFormat

# Allow access from all local networks
<Location />
  Order allow,deny
  Allow from 127.0.0.1
  Allow from 10.0.0.0/8
  Allow from 172.16.0.0/12
  Allow from 192.168.0.0/16
</Location>

# Admin access - allow from local networks
<Location /admin>
  Order allow,deny
  Allow from 127.0.0.1
  Allow from 10.0.0.0/8
  Allow from 172.16.0.0/12
  Allow from 192.168.0.0/16
</Location>

# Admin configuration pages
<Location /admin/conf>
  Order allow,deny
  Allow from 127.0.0.1
  Allow from 10.0.0.0/8
  Allow from 172.16.0.0/12
  Allow from 192.168.0.0/16
</Location>

# Job management permissions
<Location /jobs>
  Order allow,deny
  Allow from 127.0.0.1
  Allow from 10.0.0.0/8
  Allow from 172.16.0.0/12
  Allow from 192.168.0.0/16
</Location>

# Printer operations - allow from all for printing
<Location /printers>
  Order allow,deny
  Allow from all
</Location>

# IPP printing endpoint - allow from all
<Location /ipp>
  Order allow,deny
  Allow from all
</Location>

# Policy for operations - allow all without auth
<Policy default>
  JobPrivateAccess default
  JobPrivateValues default
  SubscriptionPrivateAccess default
  SubscriptionPrivateValues default

  <Limit Create-Job Print-Job Print-URI Validate-Job>
    Order deny,allow
    Allow all
  </Limit>

  <Limit Send-Document Send-URI Hold-Job Release-Job Restart-Job Purge-Jobs Set-Job-Attributes Create-Job-Subscription Renew-Subscription Cancel-Subscription Get-Notifications Reprocess-Job Cancel-Current-Job Suspend-Current-Job Resume-Job Cancel-My-Jobs Close-Job CUPS-Move-Job CUPS-Get-Document>
    Order deny,allow
    Allow all
  </Limit>

  <Limit CUPS-Add-Modify-Printer CUPS-Delete-Printer CUPS-Add-Modify-Class CUPS-Delete-Class CUPS-Set-Default CUPS-Get-Devices>
    Order deny,allow
    Allow all
  </Limit>

  <Limit Pause-Printer Resume-Printer Enable-Printer Disable-Printer Pause-Printer-After-Current-Job Hold-New-Jobs Release-Held-New-Jobs Deactivate-Printer Activate-Printer Restart-Printer Shutdown-Printer Startup-Printer Promote-Job Schedule-Job-After Cancel-Jobs CUPS-Accept-Jobs CUPS-Reject-Jobs>
    Order deny,allow
    Allow all
  </Limit>

  <Limit Cancel-Job CUPS-Authenticate-Job>
    Order deny,allow
    Allow all
  </Limit>

  <Limit All>
    Order deny,allow
    Allow all
  </Limit>
</Policy>

# Default settings - NO AUTHENTICATION
DefaultAuthType None
JobSheets none,none
PreserveJobHistory Off
PreserveJobFiles Off
MaxJobs 100
MaxJobsPerUser 25

# USB Backend settings
FileDevice Yes

# System group for admin access
SystemGroup lpadmin root wheel
CUPSCONF

bashio::log.info "cupsd.conf written successfully."

# ==============================================================================
# AVAHI / mDNS SETUP
# ==============================================================================
setup_avahi() {
    bashio::log.info "Setting up Avahi daemon for mDNS/DNS-SD printer discovery..."

    # Create required directories
    mkdir -p /var/run/avahi-daemon
    mkdir -p /etc/avahi/services

    # Determine hostname
    HOSTNAME=$(hostname)
    bashio::log.info "Using hostname: ${HOSTNAME}"

    # Write avahi-daemon.conf
    cat > /etc/avahi/avahi-daemon.conf <<AVAHICONF
[server]
host-name=${HOSTNAME}
domain-name=local
use-ipv4=yes
use-ipv6=yes
allow-interfaces=eth0,end0,wlan0,enp0s3
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
publish-aaaa-on-ipv4=yes
publish-a-on-ipv6=no

[reflector]
enable-reflector=no

[rlimits]
rlimit-core=0
rlimit-data=4194304
rlimit-fstack=4194304
rlimit-nofile=768
rlimit-nproc=3
AVAHICONF

    bashio::log.info "Avahi configuration written."
}

start_avahi() {
    if command -v avahi-daemon &>/dev/null; then
        bashio::log.info "Starting Avahi daemon..."

        # Kill any existing instance
        killall avahi-daemon 2>/dev/null || true
        sleep 1

        # Start avahi-daemon in background (no D-Bus mode)
        avahi-daemon --no-rlimits --daemonize 2>/dev/null

        if [ $? -eq 0 ]; then
            bashio::log.info "Avahi daemon started successfully."
            bashio::log.info "Printers will be advertised via mDNS/DNS-SD (Bonjour)."
        else
            bashio::log.warning "Avahi daemon failed to start. Printers will NOT be auto-discoverable."
            bashio::log.warning "Clients can still print manually via ipp://<HA-IP>:631/printers/<name>"

            # Try alternative: run in foreground without daemonize
            bashio::log.info "Attempting Avahi in no-drop-root mode..."
            avahi-daemon --no-rlimits --no-drop-root --daemonize 2>/dev/null || \
                bashio::log.warning "Avahi could not start in any mode."
        fi
    else
        bashio::log.warning "Avahi daemon not installed! Printers will NOT be auto-discoverable."
        bashio::log.warning "Install avahi-daemon in Dockerfile to enable mDNS."
    fi
}

# ==============================================================================
# ENABLE SHARING ON ALL EXISTING PRINTERS
# ==============================================================================
enable_printer_sharing() {
    bashio::log.info "Enabling sharing on all configured printers..."
    sleep 2  # Wait for cupsd to be ready

    # Get list of all printers
    PRINTERS=$(lpstat -p 2>/dev/null | awk '{print $2}')

    if [ -z "${PRINTERS}" ]; then
        bashio::log.info "No printers configured yet. New printers will be shared by default (DefaultShared Yes)."
        return
    fi

    for PRINTER in ${PRINTERS}; do
        bashio::log.info "Enabling sharing for printer: ${PRINTER}"
        lpadmin -p "${PRINTER}" -o printer-is-shared=true 2>/dev/null || \
            bashio::log.warning "Could not enable sharing for ${PRINTER}"
    done

    bashio::log.info "Printer sharing enabled."
}

# ==============================================================================
# MAIN STARTUP SEQUENCE
# ==============================================================================

# 1. Setup and start Avahi
setup_avahi
start_avahi

# 2. Start CUPS daemon
bashio::log.info "Starting CUPS daemon..."
cupsd -f &
CUPSD_PID=$!
bashio::log.info "CUPS daemon started (PID: ${CUPSD_PID})"

# 3. Enable sharing on existing printers (in background, waits for cupsd)
(
    sleep 3
    enable_printer_sharing

    # Also explicitly enable sharing via cupsctl
    cupsctl --share-printers 2>/dev/null || true
    bashio::log.info "cupsctl --share-printers executed."
) &

bashio::log.info "============================================"
bashio::log.info " CUPS is running on port 631"
bashio::log.info " Web UI: http://<HA-IP>:631"
bashio::log.info " Admin:  http://<HA-IP>:631/admin"
bashio::log.info " Avahi:  $(command -v avahi-daemon &>/dev/null && echo 'ACTIVE' || echo 'NOT AVAILABLE')"
bashio::log.info "============================================"

# Wait for CUPS process
wait ${CUPSD_PID}
