#!/bin/bash
set -e

clear
echo "================================================================"
echo "          FOOLISH INVOCATION - ARCH LINUX DEPLOYMENT            "
echo "================================================================"
echo ""

# Ensure jq is available in the live USB to parse our packages.json
if ! command -v jq &>/dev/null; then
  echo "==> Installing 'jq' on live USB to read packages.json..."
  pacman -Sy --noconfirm jq
fi

# Parse packages.json into a single space-separated string
if [ ! -f "packages.json" ]; then
  echo "FATAL: packages.json not found in the current directory."
  exit 1
fi
INSTALL_PKGS=$(jq -r '.[] | .[]' packages.json | tr '\n' ' ')

echo "----------------------------------------------------------------"
echo "Available storage drives:"
lsblk -dno NAME,SIZE,MODEL | grep -v "loop"
echo "----------------------------------------------------------------"
read -p "Enter target disk path (e.g., /dev/nvme0n1 or /dev/sda): " TARGET_DISK

read -p "Enter desired Username: " USERNAME
read -s -p "Enter desired Password: " USER_PASS
echo ""

echo "----------------------------------------------------------------"
mapfile -t PART_PATHS < <(lsblk -rno NAME,TYPE "$TARGET_DISK" | awk '$2=="part" {print "/dev/"$1}')

echo "Existing partitions on $TARGET_DISK:"
for i in "${!PART_PATHS[@]}"; do
  PART_INFO=$(lsblk -dno SIZE,FSTYPE,LABEL "${PART_PATHS[$i]}" | tr -s ' ')
  echo "  [$((i + 1))] ${PART_PATHS[$i]}  ->  ($PART_INFO)"
done

read -p "Select ROOT partition (WARNING: WILL BE FORMATTED!): " ROOT_IDX
ROOT_PART="${PART_PATHS[$((ROOT_IDX - 1))]}"

read -p "Select EFI partition (500MB FAT32): " EFI_IDX
EFI_PART="${PART_PATHS[$((EFI_IDX - 1))]}"

if [ "$ROOT_PART" == "$EFI_PART" ]; then
  echo "FATAL ERROR: Root and EFI partitions cannot be the same."
  exit 1
fi

read -p "Format EFI partition ($EFI_PART)? (y/N): " FORMAT_EFI_CHOICE

echo "==> Formatting ROOT ($ROOT_PART)..."
mkfs.ext4 -F "$ROOT_PART"

if [[ "$FORMAT_EFI_CHOICE" =~ ^[Yy]$ ]]; then
  echo "==> Formatting EFI ($EFI_PART)..."
  mkfs.fat -F32 "$EFI_PART"
  sleep 2
fi

echo "==> Mounting partitions..."
mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot/efi
mount -t vfat "$EFI_PART" /mnt/boot/efi

echo "==> Optimizing Arch Mirrors..."
reflector --latest 15 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
pacman -Sy --noconfirm archlinux-keyring

echo "==> Bootstrap installing modular packages from JSON..."
# Notice how clean this is now:
pacstrap -K /mnt $INSTALL_PKGS

genfstab -U /mnt >>/mnt/etc/fstab

echo "==> Configuring Core System..."
arch-chroot /mnt /bin/bash <<EOF
    set -e
    ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
    hwclock --systohc
    sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    locale-gen
    echo "LANG=en_US.UTF-8" > /etc/locale.conf
    echo "arch-hyprland" > /etc/hostname
    systemctl enable NetworkManager

    useradd -m -G wheel -s /bin/bash "$USERNAME"
    echo "$USERNAME:$USER_PASS" | chpasswd
    echo "root:$USER_PASS" | chpasswd
    echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" >> /etc/sudoers

    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
    grub-mkconfig -o /boot/grub/grub.cfg

    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

    # Set up TTY Auto-login for flawless first-boot into Hyprland
    mkdir -p /etc/systemd/system/getty@tty1.service.d
    echo -e "[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin $USERNAME --noclear %I \\\$TERM" > /etc/systemd/system/getty@tty1.service.d/override.conf
    echo -e "\nif [ -z \"\\\$DISPLAY\" ] && [ \"\\\$XDG_VTNR\" -eq 1 ]; then\n  exec Hyprland\nfi" >> /home/$USERNAME/.bash_profile

    # Clone Foolish Alteration to the user's config directory
    su - "$USERNAME" -c "git clone https://github.com/MichaelWard405/Foolish-Alteration.git ~/.config/Foolish-Alteration 2>/dev/null || echo 'WARNING: Alteration repo fetch failed'"
    su - "$USERNAME" -c "mkdir -p ~/.config/hypr ~/.local/bin"
    
    # Symlink the app so the user can type 'foolish-alteration' anywhere in the terminal later
    su - "$USERNAME" -c "ln -s ~/.config/Foolish-Alteration/foolish-alteration.sh ~/.local/bin/foolish-alteration"
EOF

# Create the Bootstrap Hyprland config to auto-launch Foolish Alteration TUI on first boot
cat <<'EOF' >/mnt/home/$USERNAME/.config/hypr/hyprland.conf
monitor=,preferred,auto,auto
misc {
    disable_hyprland_logo = true
    force_default_wallpaper = 0
}
# Auto-launch the TUI. When closed, it reloads Hyprland natively.
exec-once = kitty -e bash -c "~/.config/Foolish-Alteration/foolish-alteration.sh; exec bash"
EOF

arch-chroot /mnt chown -R "$USERNAME:$USERNAME" /home/"$USERNAME"

echo "==> Deployment Complete. Dismantling hooks..."
umount -R /mnt
echo "SUCCESS! Pull your USB and reboot. Foolish Alteration will launch automatically."
