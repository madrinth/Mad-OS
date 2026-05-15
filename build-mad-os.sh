#!/usr/bin/env bash
set -euo pipefail
# Mad-OS ISO builder for Arch host -> Ubuntu 24.04 (noble) amd64, GNOME, Firefox, GNOME Software, fastfetch, codecs
# Usage: sudo ./build-mad-os.sh
if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo $0"; exit 1
fi

WORKDIR="${WORKDIR:-/root/mad-os-build}"
CHROOT="$WORKDIR/chroot"
ISO_DIR="$WORKDIR/iso"
OUTPUT_ISO="$WORKDIR/mad-os-24.04-amd64.iso"
MIRROR="http://archive.ubuntu.com/ubuntu"
CODENAME="noble"
ARCH="amd64"

rm -rf "$WORKDIR"
mkdir -p "$CHROOT" "$ISO_DIR/casper" "$ISO_DIR"/{boot,install,EFI,isolinux}

echo "Bootstrapping Ubuntu $CODENAME..."
debootstrap --arch="$ARCH" --variant=minbase "$CODENAME" "$CHROOT" "$MIRROR"

echo "Mounting pseudo-filesystems..."
mount --bind /dev "$CHROOT/dev"
mount --bind /dev/pts "$CHROOT/dev/pts"
mount -t proc /proc "$CHROOT/proc"
mount -t sysfs /sys "$CHROOT/sys"
cp /etc/resolv.conf "$CHROOT/etc/resolv.conf"

cat > /tmp/mad-chroot-setup.sh <<'CHROOT'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt update
apt -y upgrade

apt -y install --no-install-recommends \
 ubuntu-standard casper live-boot linux-image-generic shim-signed grub-efi-amd64 \
 systemd-sysv squashfs-tools initramfs-tools gnupg wget ca-certificates dpkg apt apt-utils

apt -y install --no-install-recommends \
 gnome-session gnome-shell gnome-terminal gnome-control-center gnome-software \
 gnome-tweaks xorg dbus-user-session dbus-x11 policykit-1 pulseaudio network-manager \
 nautilus file-roller

apt -y install --no-install-recommends gnome-software-plugin-flatpak gnome-software-plugin-snap

apt -y install --no-install-recommends firefox

apt -y install --no-install-recommends ubiquity ubiquity-frontend-gtk

apt -y install --no-install-recommends build-essential meson ninja python3 pkg-config libcurl4-openssl-dev libx11-dev libxrandr-dev libxinerama-dev libglib2.0-dev libgdk-pixbuf2.0-dev libpango1.0-dev git

cd /tmp
if [ -d /tmp/fastfetch ]; then rm -rf /tmp/fastfetch; fi
git clone --depth=1 https://github.com/LinusDierheimer/fastfetch.git
cd fastfetch
meson setup build
ninja -C build
ninja -C build install
cd /
rm -rf /tmp/fastfetch

apt -y install --no-install-recommends ubuntu-restricted-extras vlc

apt -y autoremove
apt clean
rm -rf /var/lib/apt/lists/*
CHROOT

cp /tmp/mad-chroot-setup.sh "$CHROOT/root/"
chmod +x "$CHROOT/root/mad-chroot-setup.sh"
chroot "$CHROOT" /root/mad-chroot-setup.sh
rm -f "$CHROOT/root/mad-chroot-setup.sh" /tmp/mad-chroot-setup.sh

echo "Create live user and autologin..."
chroot "$CHROOT" /bin/bash -c "useradd -m -s /bin/bash liveuser || true"
chroot "$CHROOT" /bin/bash -c "echo 'liveuser:live' | chpasswd || true"

mkdir -p "$CHROOT/etc/systemd/system/getty@tty1.service.d"
cat > "$CHROOT/etc/systemd/system/getty@tty1.service.d/override.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin liveuser --noclear %I $TERM
EOF

echo "Add first-run script to /etc/skel..."
cat > "$CHROOT/usr/local/bin/mad-os-first-run.sh" <<'EOF'
#!/usr/bin/env bash
if command -v gnome-terminal >/dev/null 2>&1; then
  gnome-terminal -- bash -lc "fastfetch; echo; read -p 'Press Enter to continue...'"
elif command -v xterm >/dev/null 2>&1; then
  xterm -hold -e "fastfetch; echo; read -p 'Press Enter to continue...'"
fi
rm -f ~/.config/autostart/mad-os-first-run.desktop
EOF
chmod +x "$CHROOT/usr/local/bin/mad-os-first-run.sh"

mkdir -p "$CHROOT/etc/skel/.config/autostart"
cat > "$CHROOT/etc/skel/.config/autostart/mad-os-first-run.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Exec=/usr/local/bin/mad-os-first-run.sh
Hidden=false
X-GNOME-Autostart-enabled=true
Name=Mad-OS First Run
EOF

echo "Add ASCII motd..."
cat > "$CHROOT/etc/motd" <<'EOF'
 __  __     _     ____   ____  
|  \/  | __| | ___|  _ \ / ___| 
| |\/| |/ _` |/ _ \ |_) | |     
| |  | | (_| |  __/  __/| |___  
|_|  |_|\__,_|\___|_|    \____| 

Mad-OS - Welcome
EOF

cat >> "$CHROOT/etc/skel/.bashrc" <<'EOF'

if [ -f /etc/motd ]; then
  cat /etc/motd
fi
EOF

echo "Set hostname and locale..."
chroot "$CHROOT" /bin/bash -c "echo 'mad-os' > /etc/hostname || true"
chroot "$CHROOT" /bin/bash -c "ln -sf /usr/share/zoneinfo/UTC /etc/localtime || true"
chroot "$CHROOT" /bin/bash -c "echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen || true"
chroot "$CHROOT" /bin/bash -c "locale-gen || true"

echo "Unmounting pseudo-filesystems..."
umount -l "$CHROOT/dev/pts" || true
umount -l "$CHROOT/dev" || true
umount -l "$CHROOT/proc" || true
umount -l "$CHROOT/sys" || true

echo "Create squashfs..."
mksquashfs "$CHROOT" "$ISO_DIR/casper/filesystem.squashfs" -e boot

echo "Copy kernel and initrd if present..."
KERNEL=$(ls -1 "$CHROOT/boot"/*vmlinuz* 2>/dev/null | head -n1 || true)
INITRD=$(ls -1 "$CHROOT/boot"/*initrd* 2>/dev/null | head -n1 || true)
if [ -n "$KERNEL" ] && [ -n "$INITRD" ]; then
  cp "$KERNEL" "$ISO_DIR/casper/vmlinuz"
  cp "$INITRD" "$ISO_DIR/casper/initrd"
else
  echo "Warning: kernel/initrd not found. Install linux-image-generic in chroot and re-run if live boot fails."
fi

du -sx --block-size=1 "$CHROOT" | cut -f1 > "$ISO_DIR/casper/filesystem.size" || true
chroot "$CHROOT" dpkg-query -W --showformat='${Package} ${Version}\n' > "$ISO_DIR/casper/filesystem.manifest" || true
cp "$ISO_DIR/casper/filesystem.manifest" "$ISO_DIR/casper/filesystem.manifest-desktop" || true

cat > "$ISO_DIR/isolinux/isolinux.cfg" <<'EOF'
UI vesamenu.c32
DEFAULT live
LABEL live
  MENU LABEL Start Mad-OS Live
  KERNEL /casper/vmlinuz
  APPEND initrd=/casper/initrd boot=casper quiet splash ---
EOF

mkdir -p "$ISO_DIR/boot/grub"
cat > "$ISO_DIR/boot/grub/grub.cfg" <<'EOF'
set default=0
set timeout=10
menuentry "Start Mad-OS Live" {
  linux /casper/vmlinuz boot=casper quiet splash ---
  initrd /casper/initrd
}
EOF

echo "Building ISO..."
grub-mkrescue -o "$OUTPUT_ISO" "$ISO_DIR" --compress=xz || {
  echo "grub-mkrescue failed; trying xorriso fallback..."
  xorriso -as mkisofs -r -J -l -b isolinux/isolinux.bin -c isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table -o "$OUTPUT_ISO" "$ISO_DIR"
}

echo "ISO created at: $OUTPUT_ISO"
echo "Cleanup chroot & iso staging (kept for debugging if you want to inspect, remove if desired)"
rm -rf "$CHROOT"
rm -rf "$ISO_DIR"
echo "Done. Test with QEMU: qemu-system-x86_64 -m 4096 -cdrom '$OUTPUT_ISO' -boot d"
