#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
  echo -e "\n${BLUE}================================================================${NC}"
  echo -e "${GREEN}  $1 ${NC}"
  echo -e "${BLUE}================================================================${NC}"
}

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
  exit 1
}

TARGET_DISK="${1:-/dev/sda}"
FORMAT_EFI="true"
GITHUB_RAW_URL="https://raw.githubusercontent.com/MichaelWard405/Foolish-Invocation/master/packages.json"

print_header "Step 1: System Credentials"
read -p "Enter desired username [default: archuser]: " INPUT_USER
USERNAME="${INPUT_USER:-archuser}"
while true; do
  read -s -p "Enter password for $USERNAME and root: " USER_PASSWORD
  echo ""
  read -s -p "Confirm password: " USER_PASSWORD_CONFIRM
  echo ""
  if [ "$USER_PASSWORD" == "$USER_PASSWORD_CONFIRM" ] && [ -n "$USER_PASSWORD" ]; then
    log_info "Password confirmed."
    break
  else
    echo -e "${RED}[ERROR] Passwords do not match or are empty. Try again.${NC}"
  fi
done

print_header "Step 2: Environment & Config Retrieval"
if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null; then
  pacman -Sy --noconfirm jq curl || log_error "Failed to install dependencies."
fi
curl -sL "$GITHUB_RAW_URL" -o "packages.json"
if [ ! -f "packages.json" ] || ! jq . "packages.json" >/dev/null 2>&1; then
  log_error "FATAL: Failed to download or parse packages.json from GitHub."
fi

print_header "Step 3: Disk & Partition Selection"
lsblk -dno NAME,SIZE,MODEL | grep -v "loop"
read -p "Enter target disk path [default: $TARGET_DISK]: " DISK_PATH
TARGET_DISK="${DISK_PATH:-$TARGET_DISK}"

mapfile -t PART_PATHS < <(lsblk -rno NAME,TYPE "$TARGET_DISK" | awk '$2=="part" {print "/dev/"$1}')
if [ ${#PART_PATHS[@]} -eq 0 ]; then
  log_error "No partitions found on $TARGET_DISK."
fi

for i in "${!PART_PATHS[@]}"; do
  PART_INFO=$(lsblk -dno SIZE,FSTYPE,LABEL "${PART_PATHS[$i]}" | tr -s ' ')
  echo "  [$((i + 1))] ${PART_PATHS[$i]}  ->  ($PART_INFO)"
done

read -p "Select ROOT partition index (BTRFS): " ROOT_IDX
ROOT_PART="${PART_PATHS[$((ROOT_IDX - 1))]}"
read -p "Select EFI partition index (FAT32): " EFI_IDX
EFI_PART="${PART_PATHS[$((EFI_IDX - 1))]}"

if [ "$ROOT_PART" == "$EFI_PART" ]; then
  log_error "Root and EFI partitions cannot be the same device."
fi

print_header "Step 4: Formatting & Mounting"
umount -q "$ROOT_PART" 2>/dev/null || true
umount -q "$EFI_PART" 2>/dev/null || true

mkfs.btrfs -f "$ROOT_PART"
mkfs.fat -F 32 -n "BOOT" "$EFI_PART"

mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot/efi
mount -t vfat "$EFI_PART" /mnt/boot/efi

print_header "Step 5: Bootstrapping Base Arch System"
pacstrap -K /mnt base base-devel linux linux-firmware networkmanager git zsh jq curl python btrfs-progs refind

genfstab -U /mnt >>/mnt/etc/fstab
cp packages.json /mnt/root/
echo "$USERNAME:$USER_PASSWORD" >/mnt/root/credentials.txt
echo "root:$USER_PASSWORD" >>/mnt/root/credentials.txt
chmod 600 /mnt/root/credentials.txt

print_header "Step 6: Chroot Environment Configuration"
arch-chroot /mnt /bin/bash <<EOF
set -e
ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
hwclock --systohc
sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "Foolish" > /etc/hostname

useradd -m -G wheel -s /bin/zsh "$USERNAME"
chpasswd < /root/credentials.txt
rm /root/credentials.txt
echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" >> /etc/sudoers
touch "/home/$USERNAME/.zshrc"
chown "$USERNAME:$USERNAME" "/home/$USERNAME/.zshrc"

refind-install
mkdir -p /boot/efi/EFI/refind/drivers_x64
if [ -f /usr/share/refind/drivers_x64/btrfs_x64.efi ]; then
    cp /usr/share/refind/drivers_x64/btrfs_x64.efi /boot/efi/EFI/refind/drivers_x64/
fi

TARGET_UUID=\$(blkid -s UUID -o value "$ROOT_PART")
cat << EOF_REFIND > /boot/refind_linux.conf
"Boot to Hyprland"  "root=UUID=\${TARGET_UUID} rw initrd=initramfs-linux.img"
"Boot to Console"   "root=UUID=\${TARGET_UUID} rw initrd=initramfs-linux.img 3"
"Boot Fallback"     "root=UUID=\${TARGET_UUID} rw initrd=initramfs-linux-fallback.img"
EOF_REFIND

git clone https://github.com/CriticalPulsar/refind-efifetch /boot/efi/EFI/refind/themes/refind-efifetch
echo "include themes/refind-efifetch/theme.conf" >> /boot/efi/EFI/refind/refind.conf

sudo -u "$USERNAME" bash -c "cd ~ && git clone https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si --noconfirm"

PACKAGES_FILE="/root/packages.json"
if [ -f "\$PACKAGES_FILE" ]; then
    ALL_PKGS=\$(jq -r '.[]' "\$PACKAGES_FILE" | tr '\n' ' ')
    sudo -u "$USERNAME" yay -S --needed --noconfirm \$ALL_PKGS
fi

sudo -u "$USERNAME" yay -S --needed --noconfirm ly

mkdir -p "/home/$USERNAME/.config/hypr"

cat << 'EOF_FIRST_BOOT' > "/home/$USERNAME/.config/hypr/first_boot.sh"
#!/bin/bash
if [ -f ~/.cache/foolish_ran ]; then exit 0; fi

mkdir -p ~/.cache ~/Foolish-Alteration
kitty --hold -e bash -c "curl -sLo ~/Foolish-Alteration/Foolish_Alteration.py https://raw.githubusercontent.com/MichaelWard405/Foolish-Alteration/main/Foolish_Alteration.py && chmod +x ~/Foolish-Alteration/Foolish_Alteration.py && python3 ~/Foolish-Alteration/Foolish_Alteration.py"

touch ~/.cache/foolish_ran
EOF_FIRST_BOOT

chmod +x "/home/$USERNAME/.config/hypr/first_boot.sh"

cat << 'EOF_HYPR' > "/home/$USERNAME/.config/hypr/hyprland.conf"
monitor=,preferred,auto,auto
\$mainMod = SUPER
bind = \$mainMod, Q, exec, kitty
bind = \$mainMod, C, killactive,
bind = \$mainMod, M, exit,
bind = \$mainMod, R, exec, wofi --show drun
input {
    kb_layout = us
    follow_mouse = 1
}
general {
    gaps_in = 5
    gaps_out = 10
    border_size = 2
    col.active_border = rgba(33ccffee) rgba(00ff99ee) 45deg
    col.inactive_border = rgba(595959aa)
    layout = dwindle
}
decoration {
    rounding = 10
    blur {
        enabled = true
        size = 3
        passes = 1
    }
}
dwindle {
    preserve_split = true
}
misc {
    force_default_wallpaper = 0
    disable_hyprland_logo = true
    disable_splash_rendering = true
}
exec-once = ~/.config/hypr/first_boot.sh
EOF_HYPR

chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.config"
systemctl enable NetworkManager
systemctl enable ly@tty2.service
systemctl disable getty@tty2.service
EOF

print_header "Step 7: Finalizing & Unmounting"
rm -f packages.json
umount -R /mnt

log_info "Installation Complete!"
echo -e "${GREEN}You can now reboot. rEFInd will load with your theme, BTRFS will mount, and your Python script will execute cleanly in Kitty on first login.${NC}"
