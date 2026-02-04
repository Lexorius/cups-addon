#!/bin/sh

echo "=== CUPS Print Server Initialization ==="

# Create CUPS data directories for persistence
echo "Creating CUPS data directories..."
mkdir -p /data/cups/cache
mkdir -p /data/cups/logs
mkdir -p /data/cups/state
mkdir -p /data/cups/config
mkdir -p /data/cups/ppd

# Set proper permissions
chown -R root:lp /data/cups 2>/dev/null || true
chmod -R 775 /data/cups

# Create CUPS configuration directory if it doesn't exist
mkdir -p /etc/cups

# Get admin credentials from options
if [ -f /data/options.json ]; then
    ADMIN_USER=$(cat /data/options.json | jq -r '.admin_username // "admin"')
    ADMIN_PASS=$(cat /data/options.json | jq -r '.admin_password // "admin"')
else
    ADMIN_USER="admin"
    ADMIN_PASS="admin"
fi

# Create lpadmin group if not exists
addgroup -S lpadmin 2>/dev/null || true

# Create admin user for CUPS
echo "Setting up admin user: ${ADMIN_USER}"
adduser -D -G lpadmin "${ADMIN_USER}" 2>/dev/null || true
adduser "${ADMIN_USER}" lp 2>/dev/null || true
echo "${ADMIN_USER}:${ADMIN_PASS}" | chpasswd 2>/dev/null || true

# Copy custom PPD files to persistent storage if not already there
if [ ! -f "/data/cups/ppd/dymo/lw400.ppd" ]; then
    echo "Downloading Dymo PPD files..."
    mkdir -p /data/cups/ppd/dymo
    wget -q -O /data/cups/ppd/dymo/lw400.ppd \
        "https://raw.githubusercontent.com/matthiasbock/dymo-cups-drivers/master/ppd/lw400.ppd" 2>/dev/null || true
    wget -q -O /data/cups/ppd/dymo/lw450.ppd \
        "https://raw.githubusercontent.com/matthiasbock/dymo-cups-drivers/master/ppd/lw450.ppd" 2>/dev/null || true
    # Modify PPDs to use generic filter
    sed -i 's|raster2dymolw|rastertolabel|g' /data/cups/ppd/dymo/*.ppd 2>/dev/null || true
    echo "Dymo PPD files ready"
fi

# Download Ricoh PPD files
if [ ! -f "/data/cups/ppd/ricoh/Ricoh_IM_C3000.ppd" ]; then
    echo "Downloading Ricoh PPD files..."
    mkdir -p /data/cups/ppd/ricoh
    # Ricoh IM C3000 - PostScript PPD from OpenPrinting
    wget -q -O /data/cups/ppd/ricoh/Ricoh_IM_C3000.ppd \
        "https://www.openprinting.org/ppd-o-matic.php?driver=Postscript&printer=Ricoh-IM_C3000&show=0" 2>/dev/null || true
    # Ricoh Aficio MP C3000 (alternative/older model)
    wget -q -O /data/cups/ppd/ricoh/Ricoh_Aficio_MP_C3000.ppd \
        "https://www.openprinting.org/ppd-o-matic.php?driver=Postscript&printer=Ricoh-Aficio_MP_C3000&show=0" 2>/dev/null || true
    echo "Ricoh PPD files ready"
fi

# Link PPD directory to CUPS model directory
mkdir -p /usr/share/cups/model
ln -sf /data/cups/ppd/dymo /usr/share/cups/model/dymo 2>/dev/null || true
ln -sf /data/cups/ppd/ricoh /usr/share/cups/model/ricoh 2>/dev/null || true

# List USB devices for debugging
echo "=== Detected USB Devices ==="
lsusb 2>/dev/null || echo "lsusb not available"
echo "=== USB Printer Devices ==="
ls -la /dev/usb/lp* 2>/dev/null || echo "No USB printer devices found at /dev/usb/"

# List available PPD files
echo "=== Available PPD files ==="
ls -la /data/cups/ppd/dymo/ 2>/dev/null || echo "No Dymo PPDs found"
ls -la /data/cups/ppd/ricoh/ 2>/dev/null || echo "No Ricoh PPDs found"

# Basic CUPS configuration
echo "Creating CUPS configuration..."
cat > /data/cups/config/cupsd.conf << EOL
# CUPS Configuration for Home Assistant Add-on
# Direct access via host_network + hass_ingress for HA sidebar integration
#
# Access:
#   Direct: http://<HA-IP>:631
#   Via hass_ingress: configured in HA configuration.yaml
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
EOL

# Create symlinks from the default config location to our persistent location
ln -sf /data/cups/config/cupsd.conf /etc/cups/cupsd.conf

# Only create printers.conf symlink if file exists
if [ -f /data/cups/config/printers.conf ]; then
    ln -sf /data/cups/config/printers.conf /etc/cups/printers.conf
fi

# Ensure USB backend has correct permissions
chmod 755 /usr/lib/cups/backend/usb 2>/dev/null || true

# Create nginx directories
mkdir -p /run/nginx
mkdir -p /var/log/nginx

echo "=== Starting nginx proxy on port 8631 (removes CSP headers for iframe embedding) ==="
# Test nginx config first
nginx -t
if [ $? -eq 0 ]; then
    nginx
    echo "nginx started successfully"
else
    echo "ERROR: nginx config test failed!"
fi

echo "=== Starting CUPS daemon on port 631 ==="
echo ""
echo "Access URLs:"
echo "  Direct (no iframe):  http://<HA-IP>:631"
echo "  For hass_ingress:    http://<HA-IP>:8631  (CSP headers removed)"
echo "  Printing (IPP):      ipp://<HA-IP>:631/printers/<printer-name>"
echo ""
exec /usr/sbin/cupsd -f
