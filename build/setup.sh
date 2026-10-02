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

# raspberry pi os's first boot wizard takes over the screen asking for a keyboard layout and new username,
# which needs a keyboard and hides the kiosk. admin.txt or Imager's settings create an admin account instead
systemctl mask userconfig.service

# the kiosk account is for the screen only, never accept it over ssh
mkdir -p /etc/ssh/sshd_config.d
echo "DenyUsers pi-tray" > /etc/ssh/sshd_config.d/10-pi-tray.conf

# lets people without Imager create an admin account by putting admin.txt on the boot drive
# checked on every boot, so it can also be used later to reset a password or add a key
cat > /usr/local/sbin/pi-tray-admin-setup <<'SCRIPT'
#!/bin/bash
# Creates or updates an admin account from admin.txt on the boot drive, then deletes the file.
# Runs on every boot, so admin.txt can be added at any time, e.g. to reset a forgotten password or add a key.

set -uo pipefail

admin_file="/boot/firmware/admin.txt"
failed_file="$(dirname "$admin_file")/admin.failed.txt"
sudoers_dir="/etc/sudoers.d"

# the groups raspberry pi os gives its default user, so the account behaves like a normal admin
admin_groups="adm dialout cdrom audio users sudo video games plugdev input gpio spi i2c netdev render lpadmin"

[ -f "$admin_file" ] || exit 0

# overwrites before deleting, so the password isn't trivially recoverable from the card
# flash storage can still keep old copies, which is why keys and force_password_change exist
remove_admin_file() {
    shred --zero --remove "$admin_file" 2>/dev/null || rm -f "$admin_file"
    sync
}

fail() {
    echo "admin setup failed: $1" >&2

    # tell the user what went wrong, without ever copying the password out of admin.txt
    {
        echo "Pi-Tray couldn't set up the admin account:"
        echo "  $1"
        echo
        echo "Fix it and save the file as admin.txt on the boot drive again, then reboot."
    } > "$failed_file"

    remove_admin_file
    exit 1
}

username=""
password=""
force_password_change=""
ssh_keys=()

while IFS= read -r line || [ -n "$line" ]; do
    # windows editors add carriage returns
    line="${line%$'\r'}"

    if [[ "$line" =~ ^[[:space:]]*(#|$) ]]; then
        continue
    fi

    if [[ ! "$line" =~ ^[[:space:]]*([a-z_]+)[[:space:]]*:[[:space:]]*(.*)$ ]]; then
        fail "a line isn't in the form 'setting: value'"
    fi

    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"

    # drop trailing whitespace, editors often leave some
    value="${value%"${value##*[![:space:]]}"}"

    case "$key" in
        username) username="$value" ;;
        password) password="$value" ;;
        ssh_key) ssh_keys+=("$value") ;;
        force_password_change) force_password_change="$value" ;;
        *) fail "unknown setting '$key'" ;;
    esac
done < "$admin_file"

# --- validate everything before changing anything ---

if [[ ! "$username" =~ ^[a-z][a-z0-9-]{0,31}$ ]]; then
    fail "username must start with a letter and only use lower-case letters, digits and hyphens (up to 32)"
fi

case "$username" in
    root|pi-tray|nobody) fail "the username '$username' is reserved" ;;
esac

if [ -z "$password" ] && [ "${#ssh_keys[@]}" -eq 0 ]; then
    fail "add a password, an ssh_key, or both, otherwise the account can't be logged into"
fi

for ssh_key in "${ssh_keys[@]}"; do
    if [[ "$ssh_key" == *"PRIVATE KEY"* ]]; then
        fail "an ssh_key is a private key. Use the public one (the .pub file), and keep the private key secret"
    fi

    if [[ ! "$ssh_key" =~ ^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-[a-z0-9]+|sk-[a-z0-9@.-]+)[[:space:]]+[A-Za-z0-9+/=]+ ]]; then
        fail "an ssh_key doesn't look like a public key, it should start with something like ssh-ed25519 AAAA"
    fi
done

# values starting with $ are crypt hashes, e.g. from openssl passwd -6, and are stored as-is
password_is_hash=false
if [[ "$password" == '$'* ]]; then
    password_is_hash=true
fi

case "$force_password_change" in
    yes|true) force_change=true ;;
    no|false) force_change=false ;;
    "")
        # a plain password may be recoverable from the card, so by default it only works for the first login
        if [ -n "$password" ] && ! $password_is_hash; then
            force_change=true
        else
            force_change=false
        fi
        ;;
    *) fail "force_password_change must be yes or no" ;;
esac

if $force_change && [ -z "$password" ]; then
    fail "force_password_change needs a password to change"
fi

# --- create, rename or update the account ---

first_user=$(getent passwd 1000 | cut -d: -f1)
first_user_shell=$(getent passwd 1000 | cut -d: -f7)

if getent passwd "$username" > /dev/null; then
    if [ "$(id -u "$username")" -lt 1000 ]; then
        fail "'$username' is a system account and can't be used"
    fi

    echo "Updating the existing account $username"
elif [ -n "$first_user" ] && [[ "$first_user_shell" == */nologin ]] && [ -x /usr/lib/userconf-pi/userconf ]; then
    # the image's untouched default user, renamed the same way raspberry pi os's own first boot setup does it
    echo "Renaming the default user $first_user to $username"
    /usr/lib/userconf-pi/userconf "$username" "" || fail "renaming the default user failed"
else
    echo "Creating the account $username"
    useradd --create-home --shell /bin/bash "$username" || fail "creating the account failed"
fi

for group_name in $admin_groups; do
    if getent group "$group_name" > /dev/null; then
        usermod --append --groups "$group_name" "$username"
    fi
done

# the default user ships with a nologin shell
if [ "$(getent passwd "$username" | cut -d: -f7)" != "/bin/bash" ]; then
    usermod --shell /bin/bash "$username"
fi

if [ -n "$password" ]; then
    if $password_is_hash; then
        printf '%s:%s\n' "$username" "$password" | chpasswd --encrypted || fail "the password hash wasn't accepted"
    else
        printf '%s:%s\n' "$username" "$password" | chpasswd || fail "setting the password failed"
    fi

    if $force_change; then
        chage --lastday 0 "$username"
    fi
fi

if [ "${#ssh_keys[@]}" -gt 0 ]; then
    home_dir=$(getent passwd "$username" | cut -d: -f6)
    primary_group=$(id -gn "$username")
    authorized_keys="$home_dir/.ssh/authorized_keys"

    install -d -m 700 -o "$username" -g "$primary_group" "$home_dir/.ssh"
    touch "$authorized_keys"

    for ssh_key in "${ssh_keys[@]}"; do
        # only add keys that aren't already there, so re-adding admin.txt doesn't duplicate them
        grep -qxF "$ssh_key" "$authorized_keys" || echo "$ssh_key" >> "$authorized_keys"
    done

    chown "$username:$primary_group" "$authorized_keys"
    chmod 600 "$authorized_keys"
fi

# --- sudo ---

nopasswd_file="$sudoers_dir/010_${username}-nopasswd"
password_field=$(getent shadow "$username" | cut -d: -f2)

if [[ "$password_field" == '!'* ]] || [[ "$password_field" == '*'* ]] || [ -z "$password_field" ]; then
    # no usable password, e.g. a key-only account, so sudo couldn't ask for one
    nopasswd_tmp=$(mktemp)
    echo "$username ALL=(ALL) NOPASSWD: ALL" > "$nopasswd_tmp"

    if visudo -cqf "$nopasswd_tmp"; then
        install -m 440 "$nopasswd_tmp" "$nopasswd_file"
    else
        rm -f "$nopasswd_tmp"
        fail "couldn't write the sudo rule"
    fi

    rm -f "$nopasswd_tmp"
else
    # has a password, so sudo asks for it, including the default user's old passwordless rule if it was renamed
    rm -f "$nopasswd_file"

    if grep -qs "^$username " "$sudoers_dir/010_pi-nopasswd"; then
        rm -f "$sudoers_dir/010_pi-nopasswd"
    fi
fi

# --- ssh ---

systemctl enable --now --no-block ssh || fail "couldn't enable ssh"

remove_admin_file
rm -f "$failed_file"

echo "Admin account $username is ready"
SCRIPT
chmod 755 /usr/local/sbin/pi-tray-admin-setup

cat > /etc/systemd/system/pi-tray-admin.service <<'CONF'
[Unit]
Description=Set up an admin account from admin.txt on the boot drive
# host keys must exist before ssh is enabled, and cloud-init may be creating a user from Imager's settings
# cloud-init creates Imager's user in its network stage, cloud-init.service on older versions
After=boot-firmware.mount regenerate_ssh_host_keys.service cloud-init.service cloud-init-network.service
ConditionPathExists=/boot/firmware/admin.txt

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pi-tray-admin-setup

[Install]
WantedBy=multi-user.target
CONF

echo "enable pi-tray-admin.service" >> /etc/systemd/system-preset/10-pi-tray.preset
systemctl enable pi-tray-admin.service

cat > /boot/firmware/admin.example.txt <<'CONF'
# Optional: an admin account for SSH and sudo. The touchscreen works without one.
#
# Copy this file to admin.txt, fill it in, and boot the Pi. admin.txt is read on boot and then deleted.
# You can add it again at any time, e.g. to reset a forgotten password or add another key.
# If something is wrong, admin.failed.txt appears here instead, explaining why.
#
# username               required. lower-case letters, digits and hyphens, starting with a letter
# password               optional. a plain password, or a hash starting with $ (e.g. from: openssl passwd -6)
# ssh_key                optional, can be repeated. your PUBLIC key, e.g. the contents of id_ed25519.pub
# force_password_change  optional, yes or no. defaults to yes for plain passwords, so the one written here
#                        only works for the first login. defaults to no for hashes
#
# You need a password, an ssh_key, or both. An account with only keys gets sudo without a password.
# Keys are the safest choice, as nothing secret has to be written on the card.

username: admin
#password: change-me
#ssh_key: ssh-ed25519 AAAA... you@your-pc
CONF

cat > /home/pi-tray/.xinitrc <<'CONF'
#!/bin/sh
xset s off
xset s noblank
xset -dpms

unclutter -idle 0.5 -root &

# the server address lives on the boot partition so it can be changed from any computer
# tr strips the carriage returns windows editors add, and comment lines are ignored
# don't forget the BOM
server_url=$(sed '1s/^\xEF\xBB\xBF//' /boot/firmware/pi-tray.txt 2>/dev/null | grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*\r\?$' | head -n 1 | tr -d '\r[:space:]')

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
