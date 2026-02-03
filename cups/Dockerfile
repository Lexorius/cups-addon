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
RUN apk add --no-cache \
        cups \
        cups-filters \
        cups-libs \
        ghostscript \
        libusb \
        usbutils \
        wget \
        jq

# Copy data
COPY rootfs /

# Make run script executable
RUN chmod +x /usr/local/bin/run.sh

# Expose CUPS web interface port
EXPOSE 631

HEALTHCHECK \
    CMD lpstat -r || exit 1

CMD ["/usr/local/bin/run.sh"]
