ARG BUILD_FROM
FROM ${BUILD_FROM}

# ==============================================================================
# CUPS Print Server with Avahi/mDNS support
# ==============================================================================

# Install CUPS, drivers, and Avahi for printer discovery
RUN apk add --no-cache \
    cups \
    cups-filters \
    cups-libs \
    cups-client \
    cups-pdf \
    # Avahi for mDNS/DNS-SD printer advertisement (Bonjour)
    avahi \
    avahi-libs \
    avahi-tools \
    # DBus (optional, avahi can run without it)
    dbus \
    # Printer drivers
    gutenprint \
    gutenprint-cups \
    hplip \
    # USB support
    usbutils \
    libusb \
    # Dymo LabelWriter support
    && mkdir -p /var/run/avahi-daemon \
    && mkdir -p /var/run/dbus \
    && mkdir -p /etc/avahi/services

# Install Ricoh PPD files if available
# (uncomment and adjust if you need specific PPDs)
# COPY ppd/ /usr/share/cups/model/

# Copy run script
COPY run.sh /
RUN chmod a+x /run.sh

# Expose CUPS port
EXPOSE 631/tcp

# Expose Avahi/mDNS port for printer discovery
EXPOSE 5353/udp

CMD [ "/run.sh" ]
