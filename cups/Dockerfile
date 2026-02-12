ARG BUILD_FROM
FROM ${BUILD_FROM}

# ==============================================================================
# CUPS Print Server with Avahi/mDNS support for Home Assistant
# Base: Alpine 3.19
# ==============================================================================

RUN apk add --no-cache \
    bash \
    jq \
    # CUPS
    cups \
    cups-filters \
    cups-libs \
    cups-client \
    cups-pdf \
    # Avahi for mDNS/DNS-SD printer advertisement (Bonjour/AirPrint)
    avahi \
    avahi-libs \
    avahi-tools \
    # DBus (required by avahi)
    dbus \
    # Nginx reverse proxy (for hass_ingress CSP header removal)
    nginx \
    # Printer drivers
    gutenprint \
    gutenprint-cups \
    hplip \
    # USB support
    usbutils \
    libusb \
    # Network tools for debugging
    wget \
    && mkdir -p /var/run/avahi-daemon \
    && mkdir -p /var/run/dbus \
    && mkdir -p /var/run/cups \
    && mkdir -p /etc/avahi/services \
    && mkdir -p /run/nginx \
    && mkdir -p /var/log/nginx \
    && mkdir -p /var/log/cups

# Copy rootfs overlay (configs, scripts)
COPY rootfs/ /

# Make scripts executable
RUN chmod a+x /etc/cont-init.d/cups.sh

# Expose CUPS port and nginx proxy port
EXPOSE 631/tcp
EXPOSE 8631/tcp

# Expose Avahi/mDNS port for printer discovery
EXPOSE 5353/udp

# Entrypoint
CMD [ "/etc/cont-init.d/cups.sh" ]
