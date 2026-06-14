#!/bin/bash
set -e

clear
echo "================================================================"
echo "          FOOLISH INVOCATION - ARCH LINUX DEPLOYMENT            "
echo "================================================================"
echo ""

if ! command -v jq &>/dev/null; then
  echo "==> Installing 'jq' on live USB to read packages.json..."
  pacman -Sy --noconfirm jq
fi

if [ ! -f "packages.json" ]; then
  echo "FATAL: packages.json not found in the current directory."
  exit 1
fi
INSTALL_PKGS=$(jq -r '.[] | .[]' packages.json | tr '\n' ' ')

echo "----------------------------------------------------------------"
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

    # 1. FIXED: Create directories FIRST, then clone.
    su - "$USERNAME" -c "mkdir -p ~/.config/hypr ~/.local/bin"
    su - "$USERNAME" -c "git clone https://github.com/MichaelWard405/Foolish-Alteration.git ~/.config/Foolish-Alteration"
    su - "$USERNAME" -c "chmod +x ~/.config/Foolish-Alteration/foolish-alteration.sh"
    su - "$USERNAME" -c "ln -s ~/.config/Foolish-Alteration/foolish-alteration.sh ~/.local/bin/foolish-alteration"

    # 2. SECURE FIRST-BOOT PIPELINE: Auto-login to TTY1 ONLY for the first run
    mkdir -p /etc/systemd/system/getty@tty1.service.d
    echo -e "[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin $USERNAME --noclear %I \\\$TERM" > /etc/systemd/system/getty@tty1.service.d/override.conf

    # We touch a flag file so the system knows it's the first boot
    su - "$USERNAME" -c "touch ~/.config/hypr/.first_run"
EOF

# 3. Create the Bash Profile to launch restricted Hyprland if the flag exists
cat <<'EOF' >/mnt/home/$USERNAME/.bash_profile
if [ -z "$DISPLAY" ] && [ "$XDG_VTNR" -eq 1 ]; then
    if [ -f "$HOME/.config/hypr/.first_run" ]; then
        exec Hyprland -c ~/.config/hypr/first-boot.conf
    fi
    # If not first run, we do nothing. Ly Greeter handles standard logins.
fi
EOF

# 4. Create the strictly restricted Hyprland config (No keybinds, no waybar)
cat <<'EOF' >/mnt/home/$USERNAME/.config/hypr/first-boot.conf
monitor=,preferred,auto,auto
misc {
    disable_hyprland_logo = true
    force_default_wallpaper = 0
    disable_splash_rendering = true
}
# NO KEYBINDS DEFINED. The user cannot escape this setup screen.
exec-once = kitty --maximized -e bash -c "foolish-alteration; exec bash"
EOF

arch-chroot /mnt chown -R "$USERNAME:$USERNAME" /home/"$USERNAME"

echo "==> Deployment Complete. Dismantling hooks..."
umount -R /mnt
echo "SUCCESS! Pull your USB and reboot. The secure setup environment will launch."
