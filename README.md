# Home Assistant CUPS Print Server Add-on

[![Version](https://img.shields.io/badge/version-1.4.0-blue.svg)](https://github.com/Lexorius/cups-addon)
[![Supports aarch64 Architecture](https://img.shields.io/badge/aarch64-yes-green.svg)](https://github.com/Lexorius/cups-addon)
[![Supports amd64 Architecture](https://img.shields.io/badge/amd64-yes-green.svg)](https://github.com/Lexorius/cups-addon)
[![Supports armhf Architecture](https://img.shields.io/badge/armhf-yes-green.svg)](https://github.com/Lexorius/cups-addon)
[![Supports armv7 Architecture](https://img.shields.io/badge/armv7-yes-green.svg)](https://github.com/Lexorius/cups-addon)
[![Supports i386 Architecture](https://img.shields.io/badge/i386-yes-green.svg)](https://github.com/Lexorius/cups-addon)

This Home Assistant add-on provides a CUPS (Common Unix Printing System) print server with **USB printer support** and pre-installed drivers for popular printer brands.

## Features

- **USB Printer Support**: Direct support for USB printers connected to your Home Assistant host
- **Network Printing**: Share printers across your local network using CUPS/IPP
- **Web Interface**: Access the CUPS administration panel at `http://<your-ha-ip>:631`
- **hass_ingress Integration**: Integrate CUPS into Home Assistant sidebar
- **Pre-installed Drivers**:
  - **Dymo LabelWriter** (400, 450, etc.)
  - **Ricoh** (IM C3000, Aficio MP C3000)
  - Generic PostScript and PCL drivers
- **Lightweight**: Built on Alpine Linux for minimal resource usage
- **Data Persistence**: Printer settings persist across restarts

## Installation

### From Home Assistant Add-on Store

1. Navigate to your Home Assistant instance
2. Go to **Settings** → **Add-ons** → **Add-on Store**
3. Click the 3-dot menu in the top right corner and select **Repositories**
4. Add `https://github.com/Lexorius/cups-addon` as a repository
5. Find the "CUPS Print Server" add-on in the store and click it
6. Click **Install**

## Access

After starting the add-on:

| Type | URL |
|------|-----|
| Web Interface | `http://<your-ha-ip>:631` |
| Admin Panel | `http://<your-ha-ip>:631/admin` |
| IPP Printing | `ipp://<your-ha-ip>:631/printers/<printer-name>` |

## Home Assistant Sidebar Integration (hass_ingress)

To integrate CUPS into your Home Assistant sidebar, install the [hass_ingress](https://github.com/lovelylain/hass_ingress) integration via HACS.

Then add this to your `configuration.yaml`:

```yaml
ingress:
  cups:
    title: CUPS Drucker
    icon: mdi:printer
    url: http://<HA-IP>:631
    rewrite:
      # Rewrite absolute URLs in CUPS responses
      - mode: body
        match: 'href="/'
        replace: 'href="$http_x_ingress_path/'
      - mode: body
        match: 'action="/'
        replace: 'action="$http_x_ingress_path/'
      - mode: body
        match: 'src="/'
        replace: 'src="$http_x_ingress_path/'
```

**Replace `<HA-IP>` with your Home Assistant IP address** (e.g., `192.168.1.100`).

After adding, restart Home Assistant or reload INGRESS from Developer Tools → YAML.

### Alternative: Auth Mode

If URL rewriting doesn't work perfectly, use auth mode:

```yaml
ingress:
  cups:
    work_mode: auth
    title: CUPS Drucker
    icon: mdi:printer
    url: http://<HA-IP>:631
```

## Adding Printers

### USB Printer

1. Connect your USB printer to the Home Assistant host
2. Go to `http://<your-ha-ip>:631/admin`
3. Click **Add Printer**
4. Select your USB printer from the list
5. Choose the appropriate driver

### Network Printer

1. Go to `http://<your-ha-ip>:631/admin`
2. Click **Add Printer**
3. Enter the printer's address (IPP, Socket, LPD)
4. Select the appropriate driver

## Printing from Network Clients

### Windows
1. Settings → Printers & Scanners → Add Printer
2. "Add a printer using TCP/IP address"
3. Enter: `http://<your-ha-ip>:631/printers/<printer-name>`

### macOS
1. System Preferences → Printers & Scanners
2. Click "+" → IP tab
3. Protocol: Internet Printing Protocol (IPP)
4. Address: `<your-ha-ip>:631`
5. Queue: `printers/<printer-name>`

### Linux
```bash
lpadmin -p MyPrinter -E -v ipp://<your-ha-ip>:631/printers/<printer-name>
```

## Configuration

```yaml
admin_username: admin
admin_password: your_secure_password
```

## Supported Printers

| Brand | Models |
|-------|--------|
| Dymo | LabelWriter 400, 450, 4XL |
| Ricoh | IM C3000, Aficio MP C3000 |
| Generic | PostScript, PCL, IPP Everywhere |

Additional PPD files: https://www.openprinting.org/drivers/

## Troubleshooting

### USB Printer Not Detected
- Check add-on logs for USB device detection
- Verify printer appears in `lsusb` output
- Restart add-on after connecting printer

### hass_ingress Shows Broken Layout
- Use direct access for admin tasks: `http://<HA-IP>:631`
- Try `work_mode: auth` instead of URL rewriting
- CUPS generates many absolute URLs that may not all be rewritten

### Printer Not Accessible from Network
- Verify `host_network: true` in add-on config
- Check firewall allows port 631
- Ensure client is on same network

## Data Persistence

All CUPS data is stored in `/data/cups/`:
- `config/` - Configuration files
- `ppd/` - Custom PPD files
- `cache/`, `logs/`, `state/`

## License

Apache License 2.0

## Credits

- Original add-on by [Andrea Restello](https://github.com/arest)
- USB and driver enhancements by [Lexorius](https://github.com/Lexorius)
- Powered by [Home Assistant](https://www.home-assistant.io/) and [CUPS](https://www.cups.org/)
