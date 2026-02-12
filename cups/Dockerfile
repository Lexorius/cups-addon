ARG BUILD_FROM
FROM ${BUILD_FROM}

# ==============================================================================
# CUPS Print Server with Avahi/mDNS support for Home Assistant
# Base: Alpine 3.23
# ==============================================================================

# Core packages: CUPS, Avahi, D-Bus, Nginx, drivers, tools
RUN apk add --no-cache \
    bash \
    jq \
    wget \
    cups \
    cups-filters \
    cups-libs \
    cups-client \
    avahi \
    avahi-libs \
    avahi-tools \
    dbus \
    nginx \
    gutenprint \
    hplip \
    usbutils \
    libusb \
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
