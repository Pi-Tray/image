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
# Creates or updates accounts from admin.txt on the boot drive, then deletes the file.
# Runs on every boot, so admin.txt can be added at any time, e.g. to reset a password, add a key or add a user.
#
# Everything before the first [section] is the main account. Each [name] section is an extra account.
# Global ssh settings (ssh_password_login, ssh_port) go before the first section.

set -uo pipefail

admin_file="/boot/firmware/admin.txt"
failed_file="$(dirname "$admin_file")/admin.failed.txt"
sudoers_dir="/etc/sudoers.d"

# ssh settings managed by this script. regenerated on every run, starting from what the last run left
# sorts before cloud-init's 50-cloud-init.conf, and sshd uses the first value it finds for most settings
sshd_managed_file="/etc/ssh/sshd_config.d/20-pi-tray-accounts.conf"

# the groups raspberry pi os gives its default user, for accounts with sudo
admin_groups="adm dialout cdrom audio users sudo video games plugdev input gpio spi i2c netdev render lpadmin"

[ -f "$admin_file" ] || exit 0

# overwrites before deleting, so passwords aren't trivially recoverable from the card
# flash storage can still keep old copies, which is why keys and force_password_change exist
remove_admin_file() {
    shred --zero --remove "$admin_file" 2>/dev/null || rm -f "$admin_file"
    sync
}

fail() {
    echo "admin setup failed: $1" >&2

    # tell the user what went wrong, without ever copying a password out of admin.txt
    {
        echo "Pi-Tray couldn't set up the accounts in admin.txt:"
        echo "  $1"
        echo
        echo "Fix it and save the file as admin.txt on the boot drive again, then reboot."
    } > "$failed_file"

    remove_admin_file
    exit 1
}

parse_yes_no() {
    case "$1" in
        yes|true) echo yes ;;
        no|false) echo no ;;
        *) return 1 ;;
    esac
}

# --- parse ---

# account names in the order they appear, the main account first if there is one
account_names=()
# initialised as empty, as under set -u a declared but never assigned array counts as unbound
declare -A account_password=() account_keys=() account_force_change=() account_sudo=() account_ssh=() account_is_main=()

main_username=""
global_password_login=""
global_port=""

# "" while reading the main account, otherwise the current section's account name
current_section=""
main_has_fields=false

while IFS= read -r line || [ -n "$line" ]; do
    # windows editors add carriage returns
    line="${line%$'\r'}"

    if [[ "$line" =~ ^[[:space:]]*(#|$) ]]; then
        continue
    fi

    if [[ "$line" =~ ^[[:space:]]*\[([^]]*)\][[:space:]]*$ ]]; then
        current_section="${BASH_REMATCH[1]}"

        if [[ ! "$current_section" =~ ^[a-z][a-z0-9-]{0,31}$ ]]; then
            fail "[$current_section] isn't a valid username, use lower-case letters, digits and hyphens, starting with a letter"
        fi

        if [ -n "${account_is_main[$current_section]+set}" ]; then
            fail "the account '$current_section' appears more than once"
        fi

        account_names+=("$current_section")
        account_is_main[$current_section]=no
        continue
    fi

    if [[ ! "$line" =~ ^[[:space:]]*([a-z_]+)[[:space:]]*:[[:space:]]*(.*)$ ]]; then
        fail "a line isn't in the form 'setting: value'"
    fi

    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"

    # drop trailing whitespace, editors often leave some
    value="${value%"${value##*[![:space:]]}"}"

    if [ -z "$current_section" ]; then
        case "$key" in
            username)
                main_username="$value"
                continue
                ;;
            ssh_password_login)
                global_password_login=$(parse_yes_no "$value") || fail "ssh_password_login must be yes or no"
                continue
                ;;
            ssh_port)
                if [[ ! "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
                    fail "ssh_port must be a number from 1 to 65535"
                fi
                global_port="$value"
                continue
                ;;
        esac

        # account settings before any section belong to the main account, named once username is read
        account_name="__main__"
        main_has_fields=true
    else
        case "$key" in
            username) fail "username only goes before the first section, sections are named by their [heading]" ;;
            ssh_password_login|ssh_port) fail "$key only goes before the first section, as it applies to all accounts" ;;
        esac

        account_name="$current_section"
    fi

    case "$key" in
        password) account_password[$account_name]="$value" ;;
        ssh_key) account_keys[$account_name]+="$value"$'\n' ;;
        force_password_change) account_force_change[$account_name]="$value" ;;
        sudo) account_sudo[$account_name]="$value" ;;
        ssh) account_ssh[$account_name]="$value" ;;
        *) fail "unknown setting '$key'" ;;
    esac
done < "$admin_file"

# move the main account's settings under its real name, now the whole file has been read
if [ -n "$main_username" ] || $main_has_fields; then
    if [[ ! "$main_username" =~ ^[a-z][a-z0-9-]{0,31}$ ]]; then
        fail "username must start with a letter and only use lower-case letters, digits and hyphens (up to 32)"
    fi

    if [ -n "${account_is_main[$main_username]+set}" ]; then
        fail "the account '$main_username' appears more than once"
    fi

    for field_map in account_password account_keys account_force_change account_sudo account_ssh; do
        declare -n field_ref="$field_map"
        if [ -n "${field_ref[__main__]+set}" ]; then
            # these are associative arrays, shellcheck can't tell through the nameref
            # shellcheck disable=SC2004
            field_ref[$main_username]="${field_ref[__main__]}"
            unset 'field_ref[__main__]'
        fi
        unset -n field_ref
    done

    account_names=("$main_username" "${account_names[@]}")
    account_is_main[$main_username]=yes
fi

if [ "${#account_names[@]}" -eq 0 ] && [ -z "$global_password_login" ] && [ -z "$global_port" ]; then
    fail "there's nothing to set up, add a username or a [section]"
fi

# --- validate every account before changing anything ---

for account_name in "${account_names[@]}"; do
    case "$account_name" in
        root|pi-tray|nobody) fail "the username '$account_name' is reserved" ;;
    esac

    if getent passwd "$account_name" > /dev/null && [ "$(id -u "$account_name")" -lt 1000 ]; then
        fail "'$account_name' is a system account and can't be used"
    fi

    password="${account_password[$account_name]:-}"
    keys="${account_keys[$account_name]:-}"

    # new accounts need some way to log in, existing ones may just be changing a setting
    if ! getent passwd "$account_name" > /dev/null && [ -z "$password" ] && [ -z "$keys" ]; then
        fail "'$account_name' needs a password, an ssh_key, or both, otherwise it can't be logged into"
    fi

    while IFS= read -r ssh_key; do
        [ -n "$ssh_key" ] || continue

        if [[ "$ssh_key" == *"PRIVATE KEY"* ]]; then
            fail "an ssh_key for '$account_name' is a private key. Use the public one (the .pub file), and keep the private key secret"
        fi

        if [[ ! "$ssh_key" =~ ^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-[a-z0-9]+|sk-[a-z0-9@.-]+)[[:space:]]+[A-Za-z0-9+/=]+ ]]; then
            fail "an ssh_key for '$account_name' doesn't look like a public key, it should start with something like ssh-ed25519 AAAA"
        fi
    done <<< "$keys"

    # values starting with $ are crypt hashes, e.g. from openssl passwd -6, and are stored as-is
    password_is_hash=no
    [[ "$password" == '$'* ]] && password_is_hash=yes

    case "${account_force_change[$account_name]:-}" in
        yes|true) force_change=yes ;;
        no|false) force_change=no ;;
        "")
            # a plain password may be recoverable from the card, so by default it only works for the first login
            if [ -n "$password" ] && [ "$password_is_hash" = no ]; then
                force_change=yes
            else
                force_change=no
            fi
            ;;
        *) fail "force_password_change for '$account_name' must be yes or no" ;;
    esac

    if [ "$force_change" = yes ] && [ -z "$password" ]; then
        fail "force_password_change for '$account_name' needs a password to change"
    fi

    account_force_change[$account_name]="$force_change"

    # left out, sudo and ssh keep what an existing account already has, so adding a key doesn't change its rights
    # new accounts get defaults: the main account is an admin, extra accounts only when asked
    if [ -n "${account_sudo[$account_name]:-}" ]; then
        account_sudo[$account_name]=$(parse_yes_no "${account_sudo[$account_name]}") || fail "sudo for '$account_name' must be yes or no"
    elif getent passwd "$account_name" > /dev/null; then
        account_sudo[$account_name]=keep
    elif [ "${account_is_main[$account_name]}" = yes ]; then
        account_sudo[$account_name]=yes
    else
        account_sudo[$account_name]=no
    fi

    if [ -n "${account_ssh[$account_name]:-}" ]; then
        account_ssh[$account_name]=$(parse_yes_no "${account_ssh[$account_name]}") || fail "ssh for '$account_name' must be yes or no"
    elif getent passwd "$account_name" > /dev/null; then
        account_ssh[$account_name]=keep
    else
        account_ssh[$account_name]=yes
    fi
done

# --- work out the ssh settings, starting from what the last run left so unmentioned settings are kept ---

previous_denied=()
previous_password_login=""
previous_port=""

if [ -f "$sshd_managed_file" ]; then
    while read -r setting rest; do
        case "$setting" in
            DenyUsers) read -ra previous_denied <<< "$rest" ;;
            PasswordAuthentication) previous_password_login="$rest" ;;
            Port) previous_port="$rest" ;;
        esac
    done < "$sshd_managed_file"
fi

password_login="${global_password_login:-${previous_password_login:-yes}}"
ssh_port="${global_port:-${previous_port:-}}"

# accounts denied before stay denied unless this file says otherwise
declare -A denied_accounts=()
for account_name in "${previous_denied[@]}"; do
    denied_accounts[$account_name]=1
done

for account_name in "${account_names[@]}"; do
    case "${account_ssh[$account_name]}" in
        no) denied_accounts[$account_name]=1 ;;
        yes) unset 'denied_accounts[$account_name]' ;;
    esac
done

# --- lockout protection: at least one account must still be able to log in over ssh afterwards ---

has_usable_password() {
    local password_field
    password_field=$(getent shadow "$1" | cut -d: -f2)
    [ -n "$password_field" ] && [[ "$password_field" != '!'* ]] && [[ "$password_field" != '*'* ]]
}

has_existing_keys() {
    local home_dir
    home_dir=$(getent passwd "$1" | cut -d: -f6)
    [ -n "$home_dir" ] && [ -s "$home_dir/.ssh/authorized_keys" ]
}

if [ "${#account_names[@]}" -gt 0 ] || [ "$password_login" = no ]; then
    can_log_in=no

    # every regular account already on the pi that can log in at all, plus the ones in this file
    # (the image's untouched default user has a nologin shell, so it doesn't count)
    mapfile -t lockout_candidates < <(getent passwd | awk -F: '$3 >= 1000 && $1 != "nobody" && $7 !~ /(nologin|false)$/ { print $1 }')
    lockout_candidates+=("${account_names[@]}")

    any_allowed=no

    for account_name in "${lockout_candidates[@]}"; do
        [ -z "${denied_accounts[$account_name]+set}" ] || continue
        any_allowed=yes

        has_key=no
        if [ -n "${account_keys[$account_name]:-}" ] || has_existing_keys "$account_name"; then
            has_key=yes
        fi

        has_password=no
        if [ -n "${account_password[$account_name]:-}" ] || has_usable_password "$account_name"; then
            has_password=yes
        fi

        if [ "$has_key" = yes ] || { [ "$password_login" = yes ] && [ "$has_password" = yes ]; }; then
            can_log_in=yes
            break
        fi
    done

    if [ "$can_log_in" = no ]; then
        if [ "$any_allowed" = no ]; then
            fail "every account would be blocked from ssh, at least one needs ssh: yes and a password or ssh_key"
        elif [ "$password_login" = no ]; then
            fail "with ssh_password_login: no, at least one account needs an ssh_key and ssh: yes, otherwise nobody could log in over ssh"
        else
            fail "no account allowed over ssh has a password or ssh_key to log in with"
        fi
    fi
fi

# --- write and test the ssh settings first, so a bad config is caught before any account changes ---

previous_sshd_config=""
[ -f "$sshd_managed_file" ] && previous_sshd_config=$(cat "$sshd_managed_file")

sshd_tmp=$(mktemp)
{
    echo "# Managed by pi-tray-admin-setup from admin.txt. Changes here are overwritten the next time admin.txt is used."
    if [ "${#denied_accounts[@]}" -gt 0 ]; then
        echo "DenyUsers ${!denied_accounts[*]}"
    fi
    echo "PasswordAuthentication $password_login"
    if [ -n "$ssh_port" ]; then
        echo "Port $ssh_port"
    fi
} > "$sshd_tmp" || fail "couldn't write the ssh settings"
install -m 644 "$sshd_tmp" "$sshd_managed_file"
rm -f "$sshd_tmp"

if ! sshd -t; then
    if [ -n "$previous_sshd_config" ]; then
        printf '%s\n' "$previous_sshd_config" > "$sshd_managed_file"
    else
        rm -f "$sshd_managed_file"
    fi

    fail "the ssh settings were rejected by sshd"
fi

# --- create, rename or update each account ---

first_user=$(getent passwd 1000 | cut -d: -f1)
first_user_shell=$(getent passwd 1000 | cut -d: -f7)

for account_name in "${account_names[@]}"; do
    password="${account_password[$account_name]:-}"
    keys="${account_keys[$account_name]:-}"

    if getent passwd "$account_name" > /dev/null; then
        echo "Updating the existing account $account_name"
    elif [ "${account_is_main[$account_name]}" = yes ] && [ -n "$first_user" ] && [[ "$first_user_shell" == */nologin ]] && [ -x /usr/lib/userconf-pi/userconf ]; then
        # the image's untouched default user, renamed the same way raspberry pi os's own first boot setup does it
        echo "Renaming the default user $first_user to $account_name"
        /usr/lib/userconf-pi/userconf "$account_name" "" || fail "renaming the default user failed"
        first_user="$account_name"
        first_user_shell="/bin/bash"
    else
        echo "Creating the account $account_name"
        useradd --create-home --shell /bin/bash "$account_name" || fail "creating the account $account_name failed"
    fi

    # the default user ships with a nologin shell
    if [ "$(getent passwd "$account_name" | cut -d: -f7)" != "/bin/bash" ]; then
        usermod --shell /bin/bash "$account_name"
    fi

    if [ "${account_sudo[$account_name]}" = yes ]; then
        for group_name in $admin_groups; do
            if getent group "$group_name" > /dev/null; then
                usermod --append --groups "$group_name" "$account_name"
            fi
        done
    elif [ "${account_sudo[$account_name]}" = no ]; then
        # sudo: no takes admin rights away from an account that had them
        if id -nG "$account_name" | tr ' ' '\n' | grep -qx sudo; then
            gpasswd --delete "$account_name" sudo > /dev/null
        fi
    fi

    if [ -n "$password" ]; then
        if [[ "$password" == '$'* ]]; then
            printf '%s:%s\n' "$account_name" "$password" | chpasswd --encrypted || fail "the password hash for $account_name wasn't accepted"
        else
            printf '%s:%s\n' "$account_name" "$password" | chpasswd || fail "setting the password for $account_name failed"
        fi

        if [ "${account_force_change[$account_name]}" = yes ]; then
            chage --lastday 0 "$account_name"
        fi
    fi

    if [ -n "$keys" ]; then
        home_dir=$(getent passwd "$account_name" | cut -d: -f6)
        primary_group=$(id -gn "$account_name")
        authorized_keys="$home_dir/.ssh/authorized_keys"

        install -d -m 700 -o "$account_name" -g "$primary_group" "$home_dir/.ssh"
        touch "$authorized_keys"

        while IFS= read -r ssh_key; do
            [ -n "$ssh_key" ] || continue

            # only add keys that aren't already there, so re-adding admin.txt doesn't duplicate them
            grep -qxF "$ssh_key" "$authorized_keys" || echo "$ssh_key" >> "$authorized_keys"
        done <<< "$keys"

        chown "$account_name:$primary_group" "$authorized_keys"
        chmod 600 "$authorized_keys"
    fi

    # sudo rules: passwordless only for admins with no password to type, e.g. key-only accounts
    nopasswd_file="$sudoers_dir/010_${account_name}-nopasswd"

    is_admin=no
    if id -nG "$account_name" | tr ' ' '\n' | grep -qx sudo; then
        is_admin=yes
    fi

    if [ "$is_admin" = yes ] && ! has_usable_password "$account_name"; then
        nopasswd_tmp=$(mktemp)
        echo "$account_name ALL=(ALL) NOPASSWD: ALL" > "$nopasswd_tmp"

        if visudo -cqf "$nopasswd_tmp"; then
            install -m 440 "$nopasswd_tmp" "$nopasswd_file"
            rm -f "$nopasswd_tmp"
        else
            rm -f "$nopasswd_tmp"
            fail "couldn't write the sudo rule for $account_name"
        fi
    else
        rm -f "$nopasswd_file"

        # the default user's passwordless rule follows it through a rename, so remove it once there's a password
        if grep -qs "^$account_name " "$sudoers_dir/010_pi-nopasswd"; then
            rm -f "$sudoers_dir/010_pi-nopasswd"
        fi
    fi
done

# --- ssh ---

# reload picks up port and login changes if ssh was already running, start covers when it wasn't
systemctl enable --now --no-block ssh || fail "couldn't enable ssh"
systemctl reload-or-restart --no-block ssh

remove_admin_file
rm -f "$failed_file"

echo "Accounts in admin.txt are set up"
SCRIPT
chmod 755 /usr/local/sbin/pi-tray-admin-setup

cat > /etc/systemd/system/pi-tray-admin.service <<'CONF'
[Unit]
Description=Set up an admin account from admin.txt on the boot drive
# host keys must exist before ssh is enabled, and cloud-init may be creating a user from Imager's settings
# cloud-init creates that user in its network stage, cloud-init.service on older versions. not cloud-final.service,
# which runs after multi-user.target and would make an ordering cycle
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
# Optional: admin accounts for SSH and sudo. The touchscreen works without any.
#
# Copy this file to admin.txt, fill it in, and boot the Pi. admin.txt is read on boot and then deleted.
# You can add it again at any time, e.g. to reset a password, add a key, or add another account.
# If something is wrong, nothing is changed and admin.failed.txt appears here instead, explaining why.
#
# Everything before the first [section] is the main account. Each [name] section adds another account.
#
# Account settings:
#   username               main account only, required for it. sections are named by their [heading]
#                          lower-case letters, digits and hyphens, starting with a letter
#   password               optional. a plain password, or a hash starting with $ (e.g. from: openssl passwd -6)
#   ssh_key                optional, can be repeated. your PUBLIC key, e.g. the contents of id_ed25519.pub
#   force_password_change  optional, yes or no. defaults to yes for plain passwords, so the one written here
#                          only works for the first login. defaults to no for hashes
#   sudo                   optional, yes or no. new main accounts default to yes, new extra accounts to no
#   ssh                    optional, yes or no. defaults to yes for new accounts. no blocks that account from ssh
#
# Left out, sudo and ssh keep what an existing account already has, so adding a key doesn't change its rights.
# New accounts need a password, an ssh_key, or both. Admins with only keys get sudo without a password.
#
# SSH settings, before the first [section], kept until changed:
#   ssh_password_login     optional, yes or no. no means only keys can log in over ssh
#   ssh_port               optional, the port ssh listens on (22 is the default)
#
# Changes that would leave no way to log in over ssh are refused, so a mistake can't lock you out.
# Keys are the safest choice, as nothing secret has to be written on the card.

username: admin
#password: change-me
#ssh_key: ssh-ed25519 AAAA... you@your-pc

# Example: an extra account with the same key and admin rights, with the main account kept off ssh
#[sshuser]
#ssh_key: ssh-ed25519 AAAA... you@your-pc
#sudo: yes
CONF

cat > /home/pi-tray/.xinitrc <<'CONF'
#!/bin/sh
xset s off
xset s noblank
xset -dpms

unclutter -idle 0.5 -root &

# the server address lives on the boot partition so it can be changed from any computer
# sed strips a byte order mark some windows editors add, comment and blank lines are skipped,
# and tr strips the carriage returns windows editors add. only the first address is used
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
