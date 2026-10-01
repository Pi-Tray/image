#!/bin/bash
# Builds a Pi-Tray kiosk image from the official Raspberry Pi OS Lite (64-bit) image.
# Usage: sudo ./build/build-image.sh <client dist dir> <output dir>
# Must run on an arm64 host (e.g. GitHub's ubuntu-24.04-arm runners) so the chroot runs natively.

set -euo pipefail

client_dist_dir=$(realpath "$1")
output_dir=$(realpath -m "$2")
script_dir=$(dirname "$(realpath "$0")")

# CI passes the exact url it checked, otherwise use whatever is latest
base_image_url="${3:-https://downloads.raspberrypi.com/raspios_lite_arm64_latest}"

# chromium and X need roughly 600MB on top of the base image, the rest is headroom
extra_space="1536M"

work_dir=$(mktemp -d)
root_mount="$work_dir/root"
loop_device=""

cleanup() {
    # undo everything in reverse, ignoring failures so a half-finished build still cleans up
    for mount_point in "$root_mount/boot/firmware" "$root_mount/dev/pts" "$root_mount/dev" "$root_mount/proc" "$root_mount/sys" "$root_mount"; do
        umount "$mount_point" 2>/dev/null || true
    done

    if [ -n "$loop_device" ]; then
        losetup -d "$loop_device" 2>/dev/null || true
    fi

    rm -rf "$work_dir"
}
trap cleanup EXIT

mkdir -p "$output_dir" "$root_mount"

echo "==> Downloading base image"
curl --fail --location --silent --show-error "$base_image_url" --output "$work_dir/base.img.xz"
xz --decompress "$work_dir/base.img.xz"
image_path="$work_dir/base.img"

echo "==> Growing image by $extra_space"
truncate --size="+$extra_space" "$image_path"
parted --script "$image_path" resizepart 2 100%

loop_device=$(losetup --find --show --partscan "$image_path")
e2fsck -f -y "${loop_device}p2"
resize2fs "${loop_device}p2"

echo "==> Mounting"
mount "${loop_device}p2" "$root_mount"
mount "${loop_device}p1" "$root_mount/boot/firmware"
mount --bind /dev "$root_mount/dev"
mount --bind /dev/pts "$root_mount/dev/pts"
mount -t proc proc "$root_mount/proc"
mount -t sysfs sysfs "$root_mount/sys"

echo "==> Copying in the client"
mkdir -p "$root_mount/opt/pi-tray/client"
cp -r "$client_dist_dir/." "$root_mount/opt/pi-tray/client/"

echo "==> Configuring inside the image"
cp "$script_dir/setup.sh" "$root_mount/tmp/setup.sh"

# the image's resolv.conf is a symlink into systemd's runtime dir, which doesn't exist in a chroot
resolv_backup="$work_dir/resolv.conf.original"
cp --no-dereference "$root_mount/etc/resolv.conf" "$resolv_backup"
rm -f "$root_mount/etc/resolv.conf"
cp /etc/resolv.conf "$root_mount/etc/resolv.conf"

chroot "$root_mount" /bin/bash /tmp/setup.sh

rm -f "$root_mount/tmp/setup.sh" "$root_mount/etc/resolv.conf"
cp --no-dereference "$resolv_backup" "$root_mount/etc/resolv.conf"

echo "==> Checking for leaked secrets and missing pieces"
"$script_dir/check-image.sh" "$root_mount"

echo "==> Unmounting"
cleanup_partitions() {
    for mount_point in "$root_mount/boot/firmware" "$root_mount/dev/pts" "$root_mount/dev" "$root_mount/proc" "$root_mount/sys" "$root_mount"; do
        umount "$mount_point"
    done
}
cleanup_partitions
e2fsck -f -y "${loop_device}p2" || [ $? -le 1 ]
losetup -d "$loop_device"
loop_device=""

echo "==> Compressing"
image_name="pi-tray-$(date +%Y-%m-%d).img"
mv "$image_path" "$output_dir/$image_name"
extract_size=$(stat --format=%s "$output_dir/$image_name")
extract_sha256=$(sha256sum "$output_dir/$image_name" | cut -d " " -f 1)
xz --threads=0 -6 "$output_dir/$image_name"

# lets Raspberry Pi Imager list the image, with OS customisation applied via cloud-init
cat > "$output_dir/os_list.json" <<JSON
{
    "os_list": [
        {
            "name": "Pi-Tray",
            "description": "Raspberry Pi OS Lite running the Pi-Tray kiosk",
            "url": "PLACEHOLDER_URL/$image_name.xz",
            "extract_size": $extract_size,
            "extract_sha256": "$extract_sha256",
            "image_download_size": $(stat --format=%s "$output_dir/$image_name.xz"),
            "release_date": "$(date +%Y-%m-%d)",
            "init_format": "cloudinit"
        }
    ]
}
JSON

echo "==> Done: $output_dir/$image_name.xz"
