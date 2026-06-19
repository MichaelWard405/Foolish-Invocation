#!/bin/bash
set -euo pipefail
#==================
#  Colour setting
#==================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
print_header() {
  echo -e "\n${BLUE}================================================${NC}"
  echo -e "${GREEN} $1 ${NC}"
  echo -e "${BLUE}================================================${NC}"
}
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
  exit 1
}

#=============
#  Parameters
#=============
TARGET_DISK="${1:-/dev/sda}"
GITHUB_RAW_URL="https://raw.githubusercontent.com/MichaelWard405/Foolish-Invocation/master/packages.json"
USERNAME="${INPUT_USER:-FOOL}"
GPU_PKGS=""
NVIDIA_PARAM=""

#=======================
#  Step 1: Credentials
#=======================
print_header "Step 1: System Credentials"
read -p "Enter Desired Username [default: FOOL]: " INPUT_USER
while true; do
  read -s -p "Enter Password For $USERNAME and root: " USER_PASSWORD
  echo ""
  read -s -p "Confirm Password: " USER_PASSWORD_CONOFIRM
  echo ""
  if [ "$USER_PASSWORD" == "$USER_PASSWORD_CONOFIRM" ] && [ -n "$USER_PASSWORD" ]; then
    log_info "Password [CONFIRMED]"
    break
  else
    echo -e "${RED}Password [FAILED]: Fields are empty or do not match. ${NC}"
  fi
done

#=====================
#  Step 2: Retrieval
#=====================
print_header "Step 2: Enviroment & Config Retrieval"
if ! command -v -jq &>/dev/null || ! command -v curl &>/dev/null; then
  pacman -Sy --noconfirm jq curl || log_error "Failed To install dependencies"
fi
curl -sL "$GITHUB_RAW_URL" -o "packages.json"
if [ ! -f "packages.json" ] || ! jq . "packages.json" >/dev/null 2>&1; then
  log_error "[FATAL] [ERROR]: Failed To Download Or Parse 'packages.json' From GitHub"
fi

#==============================
#  Step 2.1: Driver Selection
#==============================
print_header "Step 2.1: Graphic Driver Selection"
echo "Select Your GPU Drivers:"
echo "  [1] AMD"
echo "  [2] Intel"
echo "  [3] NVIDIA"
echo "  [4] VM / Generic"
read -p "Enter Choice [1-4]: " GPU_CHOICE
case $GPU_CHOICE in
1) GPU_PKGS="mesa vulkan-radeon xf86-video-amdgpu" ;;
2) GPU_PKGS="mesa vulkan-intel xf86-video-intel" ;;
3)
  GPU_PKGS="nvidia-utils"
  NVIDIA_PARAM="nvidia_drm.modeset=1"
  ;;
*) GPU_PKGS="mesa" ;;
esac
log_info "Selected GPU Packages: $GPU_PKGS"

#======================
#  Step 3: Partioning
#======================
print_header "step 3: Disk & Partition Selection"
lsblk -dno NAME,SIZE,MODEL | grep -v "loop"
read -p "Enter Target Disk Path [Default: $TARGET_DISK]: " DISK_PATH
TARGET_DISK="${DISK_PATH:-$TARGET_DISK}"
mapfile -t PART_PATHS < <(lsblk -rno NAME,TYPE "$TARGET_DISK" | awk '$2=="part" {print "/dev/$1"}')
if [ ${#PART_PATHS[@]} -eq 0 ]; then
  log_error "No Partitions Found On $TARGET_DISK"
fi
for i in "${!PART_PATHS[@]}"; do
  PART_INFO=$(lsblk -dno SIZE,FSTYLE,LABEL "${PART_PATHS[$i]}" | tr -s ' ')
  echo "  [$((i + 1))] ${PART_PATHS[$i]} -> ($PART_INFO)"
done
read -p "Select ROOT Partition [BTRFS]: " ROOT_IDX
ROOT_PART="${PART_PATHS[$((ROOT_IDX - 1))]}"
read -p "Select EFI Partition [FAT32]: " EFI_IDX
EFI_PART="${PART_PATHS[$((EFI_IDX - 1))]}"
if [ "$ROOT_PART" == "$EFI_PART" ]; then
  log_error "Root & EFI Partitions Cannot Be The Same Device"
fi

#=================================
#  Step 4: Formatting & Mounting
#=================================
print_header "Step 4: Formatting & Mounting"
umount -q "$ROOT_PART" 2>/dev/null || true
umount -q "$EFI_PART" 2>/dev/null || true
mkfs.btrfs -f "$ROOT_PART"
mkfs.fat -F 32 -n "BOOT" "$EFI_PART"
mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot/efi
mount -t vfat "$EFI_PART" /mnt/boot/efi

#==========================================
#  Step 5: Bootstrapping Base Arch System
#==========================================
print_header "Step 5: Bootstrapping Base Arch System"
pacstrap -K /mnt base base-devel linux linux-firmware networkmanager git zsh jq curl python btrfs-progs refind ly niri $GPU_PKGS
genfstab -U /mnt >>/mnt/etc/fstab
cp packages.json /mnt/root/
echo "$USERNAME:$USER_PASSWORD" >/mnt/root/credentials.txt
echo "root:$USER_PASSWORD" >>/mnt/root/credentials.txt
chmod 600 /mnt/root/credentials.txt

#=========================
#  Step 6: Chroot Config
#=========================
print_header "Step 6: Chroot Enviroment Configuration"
arch-chroot /mnt /bin/bash <<EOF
set -e
ln -sF /usr/share/zoneinfo/Australia/Brisbane /etc/localtime
hwclock --systohc
sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8' /etc/locale.gen
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
"Boot to Niri"      "root=UUID=\${TARGET_UUID} rw initrd=/boot/initramfs-linux.img $NVIDIA_PARAM"
"Boot Fallback"     "root=UUID=\${TARGET_UUID} rw initrd=/boot/initramfs-linux-fallback.img $NVIDIA_PARAM"
EOF_REFIND
git clone https://github.com/CriticalPulsar/refind-efifetch /boot/efi/EFI/refind/themes/refind-efifetch
echo "include themes/refind-efifetch/theme.conf" >> /boot/efi/EFI/refind/refind.conf
sudo -u "$USERNAME" bash -c "cd ~ && git clone https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si --noconfirm"
PACKAGES_FILE="/root/packages.json"
if [ -f "\$PACKAGES_FILE" ]; then
    ALL_PKGS=\$(jq -r '.[]' "\$PACKAGES_FILE" | tr '\n' ' ')
    sudo -u "$USERNAME" yay -S --needed --noconfirm \$ALL_PKGS
fi
mkdir -p "/home/$USERNAME/Foolish-Alteration"
if ! curl -fsLo "/home/$USERNAME/Foolish-Alteration/Foolish_Alteration.py" "https://raw.githubusercontent.com/MichaelWard405/Foolish-Alteration/master/Foolish_Alteration.py"; then
    echo "print('[ERROR]: The online script failed to download. Please check your repository URL!')" > "/home/$USERNAME/Foolish-Alteration/Foolish_Alteration.py"
fi
chmod +x "/home/$USERNAME/Foolish-Alteration/Foolish_Alteration.py"
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/Foolish-Alteration"
#[NIRI Config]
mkdir -p "/home/$USERNAME/Foolish-Alteration"
if ! curl -fsLo "/home/$USERNAME/Foolish-Alteration/Foolish_Alteration.py" "https://raw.githubusercontent.com/MichaelWard405/Foolish-Alteration/main/Foolish_Alteration.py"; then
    echo "print('ERROR: The online script failed to download. Please check your repository URL!')" > "/home/$USERNAME/Foolish-Alteration/Foolish_Alteration.py"
fi
chmod +x "/home/$USERNAME/Foolish-Alteration/Foolish_Alteration.py"
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/Foolish-Alteration"
mkdir -p "/home/$USERNAME/.config/niri"
cat << EOF_NIRI > "/home/$USERNAME/.config/niri/config.kdl"
input {
    keyboard {
        xkb {
            layout "us"
        }
    }
}

layout {
    gaps 5
    border {
        width 2
        active-color "#33ccff"
        inactive-color "#595959"
    }
}

spawn-at-startup "waybar"
spawn-at-startup "kitty" "--hold" "-e" "python3" "/home/$USERNAME/Foolish-Alteration/Foolish_Alteration.py"

binds {}
EOF_NIRI
#[SystemCTL]
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.config"
systemctl daemon-reload
systemctl enable NetworkManager
systemctl enable ly@tty2.service
systemctl disable getty@tty2.service
EOF

#======================
#  Step 7: Finalizing
#======================
print_header "Step 7: Finalizing & Unmounting"
rm -f packages.json
umount -R /mnt
log_info"Install [Completed]"
echo -e "${GREEN} You Can Now 'Reboot' into your Operating System"
