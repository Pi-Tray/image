#!/bin/bash
# Runs inside the image's chroot. Installs the kiosk and its startup service, but deliberately creates no
# admin user, passwords, ssh keys or wifi details: Raspberry Pi Imager adds those per person at flash time.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# stop packages trying to start services inside the chroot
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

apt-get update

# bake in updates released since the base image, as the kiosk never updates itself
apt-get full-upgrade -y

apt-get install -y --no-install-recommends xserver-xorg xinit x11-xserver-utils unclutter chromium

# a system account (uid below 1000): raspberry pi os's first boot setup counts every regular user and
# falls back to its interactive rename wizard if there's more than the one Imager renames into your admin
# no password, so it can only be used by the kiosk service on the screen
useradd --system --create-home --home-dir /home/pi-tray --shell /bin/bash --groups video,input,render,audio pi-tray

# shown on screen just before the kiosk starts, and left there if it can't start
cat > /usr/local/bin/pi-tray-boot-message <<'CONF'
#!/bin/sh
addresses=$(hostname -I 2>/dev/null)

{
    # clear the screen and move to the top, without needing TERM set like clear does
    printf '\033[2J\033[H'
    echo
    echo "  Pi-Tray is starting..."
    echo
    echo "  If this stays on screen, the kiosk couldn't start."
    echo "  Press Ctrl+Alt+F2 to log in here, or connect over SSH and run:"
    echo "    journalctl -u pi-tray-kiosk -b"
    echo
    echo "  This Pi's address: ${addresses:-not connected yet}"
} > /dev/tty1
CONF
chmod +x /usr/local/bin/pi-tray-boot-message

# runs the kiosk as its own service on tty1, rather than autologin on a getty
cat > /etc/systemd/system/pi-tray-kiosk.service <<'CONF'
[Unit]
Description=Pi-Tray kiosk
After=systemd-user-sessions.service plymouth-quit-wait.service getty@tty1.service
Conflicts=getty@tty1.service
# never give up restarting, a kiosk that stays dead is worse than one that keeps retrying
StartLimitIntervalSec=0

[Service]
User=pi-tray
WorkingDirectory=/home/pi-tray
# a real login session on tty1, which lets X start without root
PAMName=login
# system accounts get a cut-down "user-light" session by default, with no per-user service manager,
# so ask for a full one like a normal desktop login
Environment=XDG_SESSION_CLASS=user
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
StandardInput=tty
UtmpIdentifier=tty1
UtmpMode=user
# the + runs it as root, as the kiosk user can't write to tty1 before its session starts
ExecStartPre=+/usr/local/bin/pi-tray-boot-message
ExecStart=/usr/bin/startx -- vt1 -keeptty -nocursor
# comes back by itself if chromium or X ever crash
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
CONF

# keeps the kiosk enabled even if systemd re-applies unit presets on first boot
mkdir -p /etc/systemd/system-preset
echo "enable pi-tray-kiosk.service" > /etc/systemd/system-preset/10-pi-tray.preset
systemctl enable pi-tray-kiosk.service

# first boot's user rename (userconf-pi's cancel-rename) enables and starts getty@tty1, which would take the
# screen from the kiosk. masking makes that fail harmlessly. autovt is the getty logind starts for a free vt
systemctl mask getty@tty1.service autovt@tty1.service

cat > /home/pi-tray/.xinitrc <<'CONF'
#!/bin/sh
xset s off
xset s noblank
xset -dpms

unclutter -idle 0.5 -root &

# the server address lives on the boot partition so it can be changed from any computer
# tr strips the carriage returns windows editors add, and comment lines are ignored
server_url=$(grep -v '^[[:space:]]*#' /boot/firmware/pi-tray.txt 2>/dev/null | tr -d '\r[:space:]' | head -n 1)

exec chromium \
    --kiosk \
    --noerrdialogs \
    --disable-infobars \
    --disable-session-crashed-bubble \
    --check-for-update-interval=31536000 \
    --incognito \
    --force-dark-mode \
    --allow-file-access-from-files \
    "file:///opt/pi-tray/client/index.html?ws=${server_url}"
CONF

chown pi-tray:pi-tray /home/pi-tray/.xinitrc
chmod +x /home/pi-tray/.xinitrc

cat > /boot/firmware/pi-tray.txt <<'CONF'
# Address of the Pi-Tray server on your PC. Edit this from any computer by opening the SD card's boot drive.
# Lines starting with # are ignored.
ws://192.168.50.1:8080
CONF

chown -R root:root /opt/pi-tray
chmod -R a+rX /opt/pi-tray

# quiet boot: no kernel text or blinking cursor on screen before the kiosk appears
sed -i '1 s/$/ quiet loglevel=3 logo.nologo vt.global_cursor_default=0/' /boot/firmware/cmdline.txt

# leave nothing behind that identifies the build machine or bloats the image
rm -f /usr/sbin/policy-rc.d
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -f /root/.bash_history
