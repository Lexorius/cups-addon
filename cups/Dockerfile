ARG BUILD_FROM
FROM ${BUILD_FROM}

# CUPS Print Server with Avahi/mDNS support for Home Assistant (Alpine 3.23)

# Enable community repository for hplip and gutenprint
RUN echo "https://dl-cdn.alpinelinux.org/alpine/v3.23/community" >> /etc/apk/repositories

# Install all packages in one layer
RUN apk add --no-cache bash jq wget cups cups-filters cups-libs cups-client avahi avahi-libs avahi-tools dbus nginx gutenprint usbutils libusb && apk add --no-cache hplip || echo "WARN: hplip not available, skipping HP driver support"

# Create required runtime directories
RUN mkdir -p /var/run/avahi-daemon /var/run/dbus /var/run/cups /etc/avahi/services /run/nginx /var/log/nginx /var/log/cups

COPY rootfs/ /

RUN chmod a+x /etc/cont-init.d/cups.sh

EXPOSE 631/tcp
EXPOSE 8631/tcp
EXPOSE 5353/udp

CMD [ "/etc/cont-init.d/cups.sh" ]
