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

# Setup base system and CUPS
RUN \
    echo "http://dl-cdn.alpinelinux.org/alpine/v$(cat /etc/alpine-release | cut -d'.' -f1,2)/main" > /etc/apk/repositories && \
    echo "http://dl-cdn.alpinelinux.org/alpine/v$(cat /etc/alpine-release | cut -d'.' -f1,2)/community" >> /etc/apk/repositories && \
    apk update && \
    apk add --no-cache \
        cups \
        cups-filters \
        cups-dev \
        cups-libs \
        ghostscript \
        libjpeg-turbo \
        net-snmp \
        libusb \
        usbutils \
        epson-inkjet-printer-escpr \
        # Build dependencies for Dymo drivers
        build-base \
        git \
        autoconf \
        automake \
        libtool \
        cups-dev

# Clone and build Dymo CUPS drivers
RUN cd /tmp && \
    git clone https://github.com/matthiasbock/dymo-cups-drivers.git && \
    cd dymo-cups-drivers && \
    aclocal && \
    automake --add-missing || true && \
    autoreconf -i && \
    ./configure --prefix=/usr && \
    make && \
    make install && \
    # Copy PPD files to CUPS ppd directory
    mkdir -p /usr/share/ppd/dymo && \
    cp ppd/*.ppd /usr/share/ppd/dymo/ && \
    # Cleanup
    cd / && \
    rm -rf /tmp/dymo-cups-drivers

# Download Ricoh PPD files from OpenPrinting
RUN mkdir -p /usr/share/ppd/ricoh && \
    # Ricoh IM C3000 PPD
    wget -O /usr/share/ppd/ricoh/Ricoh-IM_C3000-PDF-Ricoh.ppd.gz \
        "https://www.openprinting.org/ppd-o-matic.php?driver=PDF-Ricoh&printer=Ricoh-IM_C3000&show=0" 2>/dev/null || \
    wget -O /usr/share/ppd/ricoh/Ricoh-IM_C3000-Postscript.ppd.gz \
        "https://www.openprinting.org/ppd-o-matic.php?driver=Postscript-Ricoh&printer=Ricoh-IM_C3000&show=0" 2>/dev/null || true && \
    # Ricoh Aficio MP C3000 PPD (alternative model)
    wget -O /usr/share/ppd/ricoh/Ricoh-Aficio_MP_C3000-Postscript.ppd.gz \
        "https://www.openprinting.org/ppd-o-matic.php?driver=Postscript-Ricoh&printer=Ricoh-Aficio_MP_C3000&show=0" 2>/dev/null || true && \
    # Decompress if gzipped
    gunzip /usr/share/ppd/ricoh/*.gz 2>/dev/null || true

# Remove build dependencies to reduce image size
RUN apk del --no-cache \
        build-base \
        git \
        autoconf \
        automake \
        libtool

# Copy data
COPY rootfs /

# Expose CUPS web interface port
EXPOSE 631

HEALTHCHECK \
    CMD lpstat -r || exit 1
