# Pi-Tray Image

A ready-to-flash Raspberry Pi OS Lite image that boots straight into the [Pi-Tray client](https://github.com/Pi-Tray/client) in kiosk mode.

It runs well on a 1GB Pi: there's no desktop, just Chromium on a bare X server. You can of course skip this image and set up Pi-Tray Client however you like, but the image is a convenient and lightweight way to get going.

You'll also need [Pi-Tray Server](https://github.com/Pi-Tray/server) running on the PC you want to control.

## What's in the image

- Raspberry Pi OS Lite (64-bit), with all updates available at build time
- The Pi-Tray client, served from the SD card, so the Pi doesn't need internet access
- Chromium in kiosk mode, started on the screen by a service that restarts it if it ever crashes, with the cursor hidden and screen blanking disabled
- A screen-only `pi-tray` account with no password, which SSH refuses
- Optional admin account setup through Raspberry Pi Imager or an `admin.txt` file

The image deliberately contains **no** admin account, passwords, SSH keys or Wi-Fi details. You add your own if you want them, so nobody else's credentials end up on your Pi.

## Flashing

There are two ways to flash it. Both give you a working touchscreen. They differ in whether Raspberry Pi Imager can set up an admin account, SSH and Wi-Fi for you.

### Option 1: through Pi-Tray's repository (recommended)

This lets Imager apply your settings.

1. Open [Raspberry Pi Imager](https://www.raspberrypi.com/software/). In its app options, set a custom repository to:
   ```
   https://github.com/Pi-Tray/image/releases/latest/download/os_list.json
   ```
   Or start Imager with `rpi-imager --repo <that address>`.
2. Choose your Pi model, then pick **Pi-Tray** from the OS list.
3. Choose your SD card, then select **Edit Settings** when Imager asks about OS customisation:
   - **General:** set a username and password (this is your admin account), and Wi-Fi if you want it.
   - **Services:** enable SSH. Public-key authentication is recommended. Paste in your public key.
4. Write the card.

### Option 2: Use Custom

1. Download the latest `.img.xz` from [Releases](../../releases). There's no need to unzip it.
2. In Imager, choose your Pi model, then **Choose OS → Use Custom** and select the file.
3. Choose your SD card and write it.

Imager doesn't apply its settings to images chosen through **Use Custom**, even if it shows them. The Pi still boots straight into Pi-Tray, but with no admin account or SSH. To add one, see [Admin account](#admin-account-optional) below. To set up Wi-Fi, edit `network-config` on the bootfs drive before the first boot. The file has commented examples, and the [direct ethernet](#direct-ethernet-connection-optional) section shows the format.

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

## Admin accounts (optional)

You only need an admin account for SSH access and system changes. The touchscreen works without one.

If you didn't set one up in Imager, or you want to change things later, copy `admin.example.txt` on the bootfs drive to `admin.txt`, fill it in, and boot the Pi:

    username: admin
    password: change-me
    ssh_key: ssh-ed25519 AAAA... you@your-pc

`admin.txt` is read on boot and then deleted, and SSH is turned on. It's checked on every boot, so you can add it again at any time to reset a forgotten password, add a key, or add another account. If something's wrong with the file, nothing is changed and an `admin.failed.txt` appears in its place explaining why.

### Account settings

Everything before the first `[section]` is the main account. Each `[name]` section adds another account, named by its heading.

- **username** is the main account's name. Use lower-case letters, digits and hyphens, starting with a letter. Sections don't need it, as the heading is the name.
- **password** is optional. Use a plain password, or a hash starting with `$` (for example from `openssl passwd -6`).
- **ssh_key** is optional and can be repeated. Use your **public** key, such as the contents of `id_ed25519.pub`. Keys that are already there aren't added twice.
- **force_password_change** is optional (`yes` or `no`). It defaults to `yes` for plain passwords, so the one in the file only works for the first login. It defaults to `no` for hashes.
- **sudo** is optional (`yes` or `no`). New main accounts default to `yes`, and new extra accounts to `no`.
- **ssh** is optional (`yes` or `no`). It defaults to `yes` for new accounts. `no` keeps the account but blocks it from SSH.

New accounts need a password, an `ssh_key`, or both. Admins with only keys get sudo without a password, as there's no password for sudo to ask for.

Leaving `sudo` or `ssh` out keeps an existing account's current setting, so a file that only adds a key doesn't change anything else about that account.

### SSH settings

These go before the first `[section]` and apply to all accounts. They're kept until a later `admin.txt` changes them.

- **ssh_password_login** is optional (`yes` or `no`). With `no`, only keys can log in over SSH.
- **ssh_port** is optional, and sets the port SSH listens on. The default is 22.

Any change that would leave no way to log in over SSH is refused. For example, `ssh_password_login: no` is only accepted if some account that's allowed over SSH has a key. A mistake can't lock you out.

### Example

A main account that can't log in over SSH, a separate SSH account with admin rights, keys only, and a non-standard port:

    ssh_password_login: no
    ssh_port: 2244

    username: admin
    password: change-me
    ssh_key: ssh-ed25519 AAAA... you@your-pc
    ssh: no

    [sshuser]
    ssh_key: ssh-ed25519 AAAA... you@your-pc
    sudo: yes

Keys are the safest choice, as nothing secret has to be written on the card.

## First boot

The first boot can take a couple of minutes while the Pi sets itself up. After that, Pi-Tray opens on its own and connects to the server.

While it starts, the screen shows a short message with the Pi's IP address. If that message stays on screen, the kiosk couldn't start. Press **Ctrl+Alt+F2** to log in on the Pi itself, or connect over SSH and run `journalctl -u pi-tray-kiosk -b` to see why.

If the screen shows **Connecting...** and stays there:

- Check the server is running, and listening on an address the Pi can reach (`--host=` matching your PC's IP, not `127.0.0.1`).
- Check your PC's firewall allows the server's port. Windows blocks inbound connections on networks marked Public by default, which includes direct ethernet connections.
- Check the address in `pi-tray.txt`.

## Screens

- **HDMI and official DSI touchscreens (or compatible third-party clones)** work without setup.
- **Other DSI or SPI screens** may need a `dtoverlay=` line in `config.txt` on the bootfs drive. Check your screen maker's instructions.
- **DSI screens need to be connected when the Pi boots.** The kiosk keeps retrying until a screen is available, so an HDMI screen can be plugged in later.

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

Every build runs `build/check-image.sh`. It fails the build if the image contains SSH host keys, `authorized_keys`, password hashes, a machine ID, shell history, Wi-Fi passwords or an `admin.txt`, or if any part of the kiosk or its first-boot setup is missing.
