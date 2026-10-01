#!/bin/bash
# Fails if the built image contains anything identifying or secret, or is missing a kiosk piece.
# Usage: ./build/check-image.sh <mounted root dir>

set -uo pipefail

root_dir="$1"
failures=0

fail() {
    echo "FAIL: $1"
    failures=$((failures + 1))
}

# --- nothing secret or machine-specific ---

if compgen -G "$root_dir/etc/ssh/ssh_host_*" > /dev/null; then
    fail "ssh host keys are present, they must be generated on first boot"
fi

if find "$root_dir/home" "$root_dir/root" -name authorized_keys 2>/dev/null | grep -q .; then
    fail "an authorized_keys file is present"
fi

# every account should have a locked or empty password field, anything longer is a real hash
while IFS=: read -r user_name password_field _rest; do
    if [ ${#password_field} -gt 2 ] && [[ "$password_field" != "!"* ]] && [[ "$password_field" != "*"* ]]; then
        fail "user $user_name has a password set"
    fi
done < "$root_dir/etc/shadow"

if [ -s "$root_dir/etc/machine-id" ] && [ "$(cat "$root_dir/etc/machine-id")" != "uninitialized" ]; then
    fail "/etc/machine-id is set, every device must generate its own"
fi

if find "$root_dir/home" "$root_dir/root" -name ".bash_history" 2>/dev/null | grep -q .; then
    fail "shell history is present"
fi

if grep -rqs "psk=" "$root_dir/etc/NetworkManager/system-connections"; then
    fail "a wifi password is present"
fi

# --- the kiosk is complete ---

[ -f "$root_dir/opt/pi-tray/client/index.html" ] || fail "client index.html is missing"
[ -x "$root_dir/home/pi-tray/.xinitrc" ] || fail ".xinitrc is missing or not executable"
[ -f "$root_dir/etc/systemd/system/getty@tty1.service.d/autologin.conf" ] || fail "autologin override is missing"
[ -f "$root_dir/boot/firmware/pi-tray.txt" ] || fail "pi-tray.txt is missing from the boot partition"

for binary in chromium startx unclutter xset; do
    chroot "$root_dir" /bin/sh -c "command -v $binary" > /dev/null || fail "$binary is not installed"
done

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi

echo "All checks passed"
