# Pi-Tray Image

A ready-to-flash Raspberry Pi OS Lite image that boots straight into the [Pi-Tray client](https://github.com/Pi-Tray/client) in kiosk mode.

It runs well on a 1GB Pi: there's no desktop, just Chromium on a bare X server. You of course can skip this image and manually setup Pi-Tray Client how you wish, but the image serves as a convenient and lightweight way to get going.

You'll also need [Pi-Tray Server](https://github.com/Pi-Tray/server) running on the PC you want to control.

## What's in the image

- Raspberry Pi OS Lite (64-bit), with all updates available at build time
- The Pi-Tray client, served from the SD card, so the Pi doesn't need internet access
- A `pi-tray` user that logs in automatically on the screen and has no password, so it can't be logged into over the network
- Chromium in kiosk mode, with the cursor hidden and screen blanking disabled

The image deliberately contains **no** admin account, passwords, SSH keys or Wi-Fi details. You add your own when flashing, so nobody else's credentials end up on your Pi.

## Flashing

1. Download the latest `.img.xz` from [Releases](../../releases). There's no need to unzip it.
2. Open [Raspberry Pi Imager](https://www.raspberrypi.com/software/), choose your Pi model, then **Choose OS → Use Custom** and select the file.
3. Choose your SD card, then select **Edit Settings** when Imager asks about OS customisation:
   - **General:** set a username and password (this is your admin account), Wi-Fi if you want it, and your time zone and keyboard layout.
   - **Services:** enable SSH. Public-key authentication is recommended. Paste in your public key.
4. Write the card.

> **Tip:** to list Pi-Tray in Imager's normal OS menu, start Imager with
> `rpi-imager --repo https://github.com/Pi-Tray/image/releases/latest/download/os_list.json`.

## Pointing it at your PC

Before booting, open the SD card's **bootfs** drive on any computer and edit `pi-tray.txt`. Set it to your PC's address and the server's port:

```
ws://192.168.1.50:8080
```

Use `wss://` only if you've set up TLS on the server. Lines starting with `#` are ignored.

You can change this later the same way, or over SSH with `sudo nano /boot/firmware/pi-tray.txt`, then reboot.

### Direct ethernet connection (optional)

If the Pi is plugged straight into your PC rather than a router, there's nothing to hand out an IP address, so give the Pi a fixed one. Before the **first** boot, open `network-config` on the bootfs drive. Add this under `version: 2`, using spaces rather than tabs:

```yaml
  ethernets:
    eth0:
      dhcp4: false
      optional: true
      addresses:
        - 192.168.50.2/24
```

Then give your PC's ethernet adapter `192.168.50.1` with subnet mask `255.255.255.0`, and set `pi-tray.txt` to `ws://192.168.50.1:8080`.

This file is only read on the first boot. To change it afterwards, reflash or use `nmtui` over SSH.

## First boot

The first boot takes a couple of minutes and reboots once while it applies your settings. After that, Pi-Tray opens on its own and connects to the server.

If the screen shows **Connecting...** and stays there:

- Check the server is running, and listening on an address the Pi can reach (`--host=` matching your PC's IP, not `127.0.0.1`).
- Check your PC's firewall allows the server's port. Windows blocks inbound connections on networks marked Public by default, which includes direct ethernet connections.
- Check the address in `pi-tray.txt`.

## Screens

- **HDMI and official DSI touchscreens** work without setup.
- **Other DSI or SPI screens** may need a `dtoverlay=` line in `config.txt` on the bootfs drive. Check your screen maker's instructions.
- **A screen must be connected when the Pi boots**, otherwise the kiosk won't start until the next reboot.

## Building it yourself

Images are built by GitHub Actions on native arm64 runners. A build runs:

- on every `v*` tag, which publishes a release
- weekly, building and releasing automatically whenever Raspberry Pi publishes a new OS Lite image
- manually from the Actions tab, which produces a downloadable artifact without a release

To build the image locally you need an **arm64 Linux** machine, such as a Pi 4 or 5 with plenty of free space, or an arm64 VM:

```bash
git clone https://github.com/Pi-Tray/client
cd client && npm ci && npm run build && cd ..

sudo apt install parted xz-utils
sudo bash ./build/build-image.sh client/dist out
```

The image and `os_list.json` end up in `out/`.

Every build runs `build/check-image.sh`, which fails the build if the image contains SSH host keys, `authorized_keys`, password hashes, a machine ID, shell history or Wi-Fi passwords, or if any part of the kiosk is missing.
