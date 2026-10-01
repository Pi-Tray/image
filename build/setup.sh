#!/bin/bash
# Runs inside the image's chroot. Installs the kiosk and sets up autologin, but deliberately creates no
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

# no password, so it can only be used through the autologin on the screen
useradd --create-home --shell /bin/bash --groups video,input,render,audio pi-tray

mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<'CONF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin pi-tray --noclear %I $TERM
CONF

cat > /home/pi-tray/.bash_profile <<'CONF'
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec startx -- -nocursor
fi
CONF

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

chown pi-tray:pi-tray /home/pi-tray/.bash_profile /home/pi-tray/.xinitrc
chmod +x /home/pi-tray/.xinitrc

cat > /boot/firmware/pi-tray.txt <<'CONF'
# Address of the Pi-Tray server on your PC. Edit this from any computer by opening the SD card's boot drive.
# Lines starting with # are ignored.
ws://192.168.50.1:8080
CONF

chown -R root:root /opt/pi-tray
chmod -R a+rX /opt/pi-tray

# leave nothing behind that identifies the build machine or bloats the image
rm -f /usr/sbin/policy-rc.d
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -f /root/.bash_history
