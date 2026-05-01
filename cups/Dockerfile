ARG BUILD_FROM
FROM ${BUILD_FROM}

# ==============================================================================
# CUPS Print Server for Home Assistant
# Optimised for ARM (Raspberry Pi 4 - aarch64 / armv7) and amd64 / i386
# Alpine 3.23 base
# ==============================================================================

# Enable community + testing repositories (foomatic-db, gutenprint, hplip live there)
RUN set -eux; \
    echo "https://dl-cdn.alpinelinux.org/alpine/v3.23/main"        >  /etc/apk/repositories; \
    echo "https://dl-cdn.alpinelinux.org/alpine/v3.23/community"   >> /etc/apk/repositories; \
    echo "https://dl-cdn.alpinelinux.org/alpine/edge/testing"      >> /etc/apk/repositories

# ------------------------------------------------------------------------------
# Core packages (must work on every supported arch)
# ------------------------------------------------------------------------------
RUN set -eux; \
    apk update; \
    apk add --no-cache \
        bash jq curl wget tini \
        ca-certificates tzdata \
        cups cups-client cups-filters cups-libs cups-pdf \
        ghostscript ghostscript-fonts \
        poppler-utils \
        avahi avahi-libs avahi-tools \
        dbus \
        nginx \
        usbutils libusb \
        sed grep coreutils findutils \
        ;

# ------------------------------------------------------------------------------
# Printer drivers — install per-package with graceful fallback so that
# the build does NOT fail if a single optional package is missing on a given
# architecture (this used to break Raspberry Pi builds).
# ------------------------------------------------------------------------------
RUN set -eux; \
    # Gutenprint covers Epson, Canon, HP, Lexmark, Olympus, PCL, ESC/P, ...
    apk add --no-cache gutenprint gutenprint-cups || echo "WARN: gutenprint not available";  \
    # Foomatic database — thousands of PPDs for legacy and current printers
    apk add --no-cache foomatic-db foomatic-db-engine foomatic-db-ppds || echo "WARN: foomatic-db not available"; \
    # HPLIP — HP printers/scanners (on ARM only the lite variant is sometimes built)
    apk add --no-cache hplip       || echo "WARN: hplip not available on this arch"; \
    apk add --no-cache hplip-cups  || echo "WARN: hplip-cups not available on this arch"; \
    # Brother laser printers (community-maintained, pure-CUPS filter, runs on ARM)
    apk add --no-cache printer-driver-brlaser || echo "WARN: brlaser not available"; \
    # Samsung / Xerox / Dell laser
    apk add --no-cache printer-driver-splix   || echo "WARN: splix not available"; \
    # Zebra / DYMO / EPL2 label printers (ARM-safe, builds from source in Alpine)
    apk add --no-cache printer-driver-ptouch  || echo "WARN: ptouch not available"; \
    apk add --no-cache printer-driver-zedonk  || echo "WARN: zedonk not available"; \
    # Generic / fallback driverless support helpers
    apk add --no-cache printer-driver-postscript-hp || echo "WARN: postscript-hp not available"

# ------------------------------------------------------------------------------
# Runtime directories. /etc/cups is intentionally LEFT alone here — it gets
# replaced by a symlink to /data/cups/etc on first start so it is persistent.
# ------------------------------------------------------------------------------
RUN set -eux; \
    mkdir -p \
        /var/run/avahi-daemon \
        /var/run/dbus \
        /var/run/cups \
        /etc/avahi/services \
        /run/nginx \
        /var/log/nginx \
        /var/log/cups \
        /var/spool/cups \
        /var/cache/cups

COPY rootfs/ /

RUN chmod +x /etc/cont-init.d/cups.sh

EXPOSE 631/tcp
EXPOSE 8631/tcp
EXPOSE 5353/udp

# tini = clean PID 1 + signal forwarding (so docker stop is graceful)
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/etc/cont-init.d/cups.sh"]
