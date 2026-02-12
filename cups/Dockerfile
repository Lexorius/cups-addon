ARG BUILD_FROM
FROM ${BUILD_FROM}

# CUPS Print Server with Avahi/mDNS support for Home Assistant (Alpine 3.23)

RUN apk add --no-cache bash jq wget cups 
RUN apk add --no-cache cups-filters cups-libs cups-client 
RUN apk add --no-cache avahi avahi-libs avahi-tools 
RUN apk add --no-cache dbus nginx 
RUN apk add --no-cache gutenprint 
RUN apk add --no-cache hplip 
RUN apk add --no-cache usbutils 
RUN apk add --no-cache libusb 
RUN mkdir -p /var/run/avahi-daemon /var/run/dbus /var/run/cups /etc/avahi/services /run/nginx /var/log/nginx /var/log/cups

COPY rootfs/ /

RUN chmod a+x /etc/cont-init.d/cups.sh

EXPOSE 631/tcp
EXPOSE 8631/tcp
EXPOSE 5353/udp

CMD [ "/etc/cont-init.d/cups.sh" ]
