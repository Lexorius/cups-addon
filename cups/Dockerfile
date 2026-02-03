ARG BUILD_FROM
FROM $BUILD_FROM

# Add env
ENV LANG=C.UTF-8
# Set CUPS environment variables for data persistence
ENV CUPS_DATADIR=/data/cups
ENV CUPS_CACHEDIR=/data/cups/cache
ENV CUPS_LOGDIR=/data/cups/logs
ENV CUPS_STATEDIR=/data/cups/state
ENV CUPS_SERVERROOT=/data/cups/config

# Setup base system and CUPS with all necessary packages
RUN \
    echo "http://dl-cdn.alpinelinux.org/alpine/v$(cat /etc/alpine-release | cut -d'.' -f1,2)/main" > /etc/apk/repositories && \
    echo "http://dl-cdn.alpinelinux.org/alpine/v$(cat /etc/alpine-release | cut -d'.' -f1,2)/community" >> /etc/apk/repositories && \
    apk update && \
    apk add --no-cache \
        cups \
        cups-filters \
        cups-libs \
        cups-pdf \
        ghostscript \
        libjpeg-turbo \
        libpng \
        net-snmp \
        libusb \
        usbutils \
        wget \
        jq \
        poppler-utils \
        epson-inkjet-printer-escpr

# Create PPD directories
RUN mkdir -p /usr/share/cups/model/dymo \
             /usr/share/cups/model/ricoh

# Download Dymo PPD files directly
RUN wget -q -O /usr/share/cups/model/dymo/lw400.ppd \
    "https://raw.githubusercontent.com/matthiasbock/dymo-cups-drivers/master/ppd/lw400.ppd" && \
    wget -q -O /usr/share/cups/model/dymo/lw450.ppd \
    "https://raw.githubusercontent.com/matthiasbock/dymo-cups-drivers/master/ppd/lw450.ppd" && \
    wget -q -O /usr/share/cups/model/dymo/lw450turbo.ppd \
    "https://raw.githubusercontent.com/matthiasbock/dymo-cups-drivers/master/ppd/lw450turbo.ppd" && \
    echo "Dymo PPD files downloaded"

# Modify Dymo PPDs to use rastertolabel filter (generic CUPS filter)
RUN sed -i 's|raster2dymolw|rastertolabel|g' /usr/share/cups/model/dymo/*.ppd || true

# Copy data
COPY rootfs /

# Expose CUPS web interface port
EXPOSE 631

HEALTHCHECK \
    CMD lpstat -r || exit 1
