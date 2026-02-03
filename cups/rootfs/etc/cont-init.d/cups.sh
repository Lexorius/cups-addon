#!/usr/bin/with-contenv bash

echo "=== CUPS Print Server Initialization ==="

# Create CUPS data directories for persistence
echo "Creating CUPS data directories..."
mkdir -p /data/cups/cache
mkdir -p /data/cups/logs
mkdir -p /data/cups/state
mkdir -p /data/cups/config
mkdir -p /data/cups/ppd

# Set proper permissions
chown -R root:lp /data/cups
chmod -R 775 /data/cups

# Create CUPS configuration directory if it doesn't exist
mkdir -p /etc/cups

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

# Link PPD directory to CUPS model directory
mkdir -p /usr/share/cups/model
ln -sf /data/cups/ppd/dymo /usr/share/cups/model/dymo 2>/dev/null || true

# List available PPD files
echo "=== Available PPD files ==="
ls -la /data/cups/ppd/dymo/ 2>/dev/null || echo "No Dymo PPDs found"

# Get admin credentials from options
if [ -f /data/options.json ]; then
    ADMIN_USER=$(jq -r '.admin_username // "admin"' /data/options.json)
    ADMIN_PASS=$(jq -r '.admin_password // "admin"' /data/options.json)
else
    ADMIN_USER="admin"
    ADMIN_PASS="admin"
fi

# Create admin user for CUPS
echo "Setting up admin user: ${ADMIN_USER}"
adduser -D -G lpadmin "${ADMIN_USER}" 2>/dev/null || true
echo "${ADMIN_USER}:${ADMIN_PASS}" | chpasswd

# List USB devices for debugging
echo "=== Detected USB Devices ==="
lsusb 2>/dev/null || echo "lsusb not available"
echo "=== USB Printer Devices ==="
ls -la /dev/usb/lp* 2>/dev/null || echo "No USB printer devices found at /dev/usb/"
ls -la /dev/bus/usb/ 2>/dev/null || echo "No USB bus found"

# Basic CUPS configuration
echo "Creating CUPS configuration..."
cat > /data/cups/config/cupsd.conf << EOL
# CUPS Configuration for Home Assistant Add-on
# Generated automatically - manual changes will be overwritten on restart

# Server settings
ServerName localhost
ServerAdmin root@localhost

# Listen on all interfaces
Listen 0.0.0.0:631

# Enable web interface
WebInterface Yes

# Log settings
LogLevel warn
PageLogFormat

# Allow access from local network
<Location />
  Order allow,deny
  Allow localhost
  Allow 10.0.0.0/8
  Allow 172.16.0.0/12
  Allow 192.168.0.0/16
  Allow @LOCAL
</Location>

# Admin access
<Location /admin>
  Order allow,deny
  Allow localhost
  Allow 10.0.0.0/8
  Allow 172.16.0.0/12
  Allow 192.168.0.0/16
  Allow @LOCAL
  AuthType Basic
  Require user @SYSTEM
</Location>

# Admin configuration pages
<Location /admin/conf>
  AuthType Basic
  Require user @SYSTEM
  Order allow,deny
  Allow localhost
  Allow 10.0.0.0/8
  Allow 172.16.0.0/12
  Allow 192.168.0.0/16
  Allow @LOCAL
</Location>

# Job management permissions
<Location /jobs>
  Order allow,deny
  Allow localhost
  Allow 10.0.0.0/8
  Allow 172.16.0.0/12
  Allow 192.168.0.0/16
  Allow @LOCAL
</Location>

# Printer operations
<Location /printers>
  Order allow,deny
  Allow localhost
  Allow 10.0.0.0/8
  Allow 172.16.0.0/12
  Allow 192.168.0.0/16
  Allow @LOCAL
</Location>

# Policy for operations
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
EOL

# Create symlinks from the default config location to our persistent location
ln -sf /data/cups/config/cupsd.conf /etc/cups/cupsd.conf

# Only create printers.conf symlink if file exists
if [ -f /data/cups/config/printers.conf ]; then
    ln -sf /data/cups/config/printers.conf /etc/cups/printers.conf
fi

# Link PPD directories
ln -sf /data/cups/ppd /usr/share/cups/model/custom 2>/dev/null || true

# Ensure USB backend has correct permissions
chmod 755 /usr/lib/cups/backend/usb 2>/dev/null || true

echo "=== Starting CUPS daemon ==="
exec /usr/sbin/cupsd -f
