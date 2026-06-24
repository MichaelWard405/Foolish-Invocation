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
GPU_PKGS=""
NVIDIA_PARAM=""

#=======================
#  Step 1: Credentials
#=======================
print_header "Step 1: System Credentials"
read -p "Enter Desired Username [default: FOOL]: " INPUT_USER
USERNAME="${INPUT_USER:-FOOL}"

while true; do
  read -s -p "Enter Password For $USERNAME and root: " USER_PASSWORD
  echo ""
  read -s -p "Confirm Password: " USER_PASSWORD_CONFIRM
  echo ""
  if [ "$USER_PASSWORD" == "$USER_PASSWORD_CONFIRM" ] && [ -n "$USER_PASSWORD" ]; then
    log_info "Password [CONFIRMED]"
    break
  else
    echo -e "${RED}Password [FAILED]: Fields are empty or do not match. ${NC}"
  fi
done

echo ""
log_info "Wireless Setup (Optional)"
read -p "Enter Wi-Fi Name (SSID) [Leave blank to skip]: " WIFI_SSID
WIFI_PASS=""
if [ -n "$WIFI_SSID" ]; then
  read -s -p "Enter Wi-Fi Password: " WIFI_PASS
  echo ""
  log_info "Wi-Fi credentials saved for deployment."
fi

#=====================
#  Step 2: Retrieval
#=====================
print_header "Step 2: Environment & Config Retrieval"
if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null; then
  pacman -Sy --noconfirm jq curl || log_error "Failed To install dependencies"
fi
curl -sL "$GITHUB_RAW_URL" -o "packages.json"
if [ ! -f "packages.json" ] || ! jq . "packages.json" >/dev/null 2>&1; then
  log_error "[FATAL] [ERROR]: Failed To Download Or Parse 'packages.json' From GitHub"
fi

#==============================
#  Step 2.1: Graphic Driver Selection
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
  GPU_PKGS="nvidia nvidia-utils"
  NVIDIA_PARAM="nvidia_drm.modeset=1"
  ;;
*) GPU_PKGS="mesa" ;;
esac
log_info "Selected GPU Packages: $GPU_PKGS"

#======================
#  Step 3: Partitioning
#======================
print_header "Step 3: Disk & Partition Selection"
lsblk -dno NAME,SIZE,MODEL | grep -v "loop"
read -p "Enter Target Disk Path [Default: $TARGET_DISK]: " DISK_PATH
TARGET_DISK="${DISK_PATH:-$TARGET_DISK}"

mapfile -t PART_PATHS < <(lsblk -rno NAME,TYPE "$TARGET_DISK" | awk '$2=="part" {print "/dev/"$1}')
if [ ${#PART_PATHS[@]} -eq 0 ]; then
  log_error "No Partitions Found On $TARGET_DISK"
fi

for i in "${!PART_PATHS[@]}"; do
  PART_INFO=$(lsblk -dno SIZE,FSTYPE,LABEL "${PART_PATHS[$i]}" | tr -s ' ')
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
pacstrap -K /mnt base base-devel linux linux-firmware btrfs-progs git jq curl $GPU_PKGS
genfstab -U /mnt >>/mnt/etc/fstab
cp packages.json /mnt/root/
echo "$USERNAME:$USER_PASSWORD" >/mnt/root/credentials.txt
echo "root:$USER_PASSWORD" >>/mnt/root/credentials.txt
chmod 600 /mnt/root/credentials.txt

#=========================
#  Step 6: Chroot Config
#=========================
print_header "Step 6: Chroot Environment Configuration"
arch-chroot /mnt /bin/bash <<EOF
set -e

# Localization
ln -sf /usr/share/zoneinfo/Australia/Brisbane /etc/localtime
hwclock --systohc
sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "Foolish" > /etc/hostname

# Temporary User Creation (Bash used until ZSH is installed via yay)
useradd -m -G wheel -s /bin/bash "$USERNAME"
chpasswd < /root/credentials.txt
rm /root/credentials.txt
echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" >> /etc/sudoers

# Setup Yay
sudo -u "$USERNAME" bash -c "cd ~ && git clone https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si --noconfirm"

# Install Packages from packages.json
PACKAGES_FILE="/root/packages.json"
if [ -f "\$PACKAGES_FILE" ]; then
    ALL_PKGS=\$(jq -r '.[]' "\$PACKAGES_FILE" | tr '\n' ' ')
    sudo -u "$USERNAME" yay -S --needed --noconfirm \$ALL_PKGS
fi

# Change shell to ZSH now that it is installed
chsh -s /usr/bin/zsh "$USERNAME"
touch "/home/$USERNAME/.zshrc"
chown "$USERNAME:$USERNAME" "/home/$USERNAME/.zshrc"

# Bootloader Config (rEFInd)
refind-install
mkdir -p /boot/efi/EFI/refind/drivers_x64
if [ -f /usr/share/refind/drivers_x64/btrfs_x64.efi ]; then
    cp /usr/share/refind/drivers_x64/btrfs_x64.efi /boot/efi/EFI/refind/drivers_x64/
fi

TARGET_UUID=\$(blkid -s UUID -o value "$ROOT_PART")
cat << EOF_REFIND > /boot/refind_linux.conf
"Boot to SwayFX"    "root=UUID=\${TARGET_UUID} rw initrd=/boot/initramfs-linux.img $NVIDIA_PARAM"
"Boot Fallback"     "root=UUID=\${TARGET_UUID} rw initrd=/boot/initramfs-linux-fallback.img $NVIDIA_PARAM"
EOF_REFIND

git clone https://github.com/CriticalPulsar/refind-efifetch /boot/efi/EFI/refind/themes/refind-efifetch
echo "include themes/refind-efifetch/theme.conf" >> /boot/efi/EFI/refind/refind.conf

# Python Script Deployment
mkdir -p "/home/$USERNAME/Foolish-Alteration"
if ! curl -fsLo "/home/$USERNAME/Foolish-Alteration/Foolish_Alteration.py" "https://raw.githubusercontent.com/MichaelWard405/Foolish-Alteration/master/Foolish_Alteration.py"; then
    echo "print('ERROR: The online script failed to download. Please check your repository URL or Branch Name!')" > "/home/$USERNAME/Foolish-Alteration/Foolish_Alteration.py"
fi
chmod +x "/home/$USERNAME/Foolish-Alteration/Foolish_Alteration.py"
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/Foolish-Alteration"

# SWAYFX Configuration Setup
mkdir -p "/home/$USERNAME/.config/sway"
cat << 'EOF_SWAY' > "/home/$USERNAME/.config/sway/config"
# ==================================================
#  SwayFX Global Visuals & Eye-Candy Configuration
# ==================================================
blur enable
blur_passes 3
blur_radius 5
corner_radius 10
shadows enable
shadow_blur_radius 15
shadow_color #0000007F

# Window decorations & Borders
default_border pixel 2
default_floating_border pixel 2
client.focused          #33ccff #33ccff #ffffff #33ccff #33ccff
client.focused_inactive #595959 #595959 #ffffff #595959 #595959
client.unfocused        #595959 #595959 #ffffff #595959 #595959

# ==================================================
#  Custom Variable Layout & Hyprland Mapping Match
# ==================================================
set \$mod Mod4
set \$terminal kitty
set \$fileManager thunar
set \$menu wofi --show drun
set \$browser flatpak run app.zen_browser.zen
set \$steam flatpak run com.valvesoftware.Steam
set \$discord discord
set \$Screenshot grim -g "\$(slurp)" - | wl-copy
set \$logout wlogout
set \$Ide nvim
set \$git lazygit

# Core Interactive System Execution Hooks
bindsym \$mod+q exec \$terminal
bindsym \$mod+c kill
bindsym \$mod+m exec swaymsg exit
bindsym \$mod+e exec \$fileManager
bindsym \$mod+f floating toggle
bindsym \$mod+r exec \$menu
bindsym \$mod+b exec \$browser
bindsym \$mod+s exec \$steam
bindsym \$mod+d exec \$discord
bindsym \$mod+Print exec \$Screenshot
bindsym \$mod+w exec \$logout
bindsym \$mod+v exec \$terminal -e \$Ide
bindsym \$mod+g exec \$terminal -e \$git

# Focus / Window Target Tracking Management
bindsym \$mod+Left focus left
bindsym \$mod+Right focus right
bindsym \$mod+Up focus up
bindsym \$mod+Down focus down

# Moving Tiling Containers Configuration 
bindsym \$mod+Shift+Left move left
bindsym \$mod+Shift+Right move right
bindsym \$mod+Shift+Up move up
bindsym \$mod+Shift+Down move down

# Desktop Management Workspaces
bindsym \$mod+1 workspace number 1
bindsym \$mod+2 workspace number 2
bindsym \$mod+3 workspace number 3
bindsym \$mod+4 workspace number 4
bindsym \$mod+5 workspace number 5

bindsym \$mod+Shift+1 move container to workspace number 1
bindsym \$mod+Shift+2 move container to workspace number 2
bindsym \$mod+Shift+3 move container to workspace number 3
bindsym \$mod+Shift+4 move container to workspace number 4
bindsym \$mod+Shift+5 move container to workspace number 5

# Local Input Strategy
input * {
    xkb_layout "us"
}

# Session Environment Daemon Initialization
exec waybar
exec nm-applet --indicator

# Dynamic Application Execution Context Fix (Corrects Tkinter file path lookup)
exec sh -c "sleep 2 && kitty --hold -e bash -c 'cd /home/FOOL/Foolish-Alteration/ && python3 Foolish_Alteration.py'"
EOF_SWAY

# Dynamic replacement of the hardcoded username placeholder inside the Sway config
sed -i "s/FOOL/$USERNAME/g" "/home/$USERNAME/.config/sway/config"
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.config"

# NetworkManager Profiles
mkdir -p /etc/NetworkManager/system-connections
cat << EOF_NM > /etc/NetworkManager/system-connections/Wired-Fallback.nmconnection
[connection]
id=Wired-Fallback
type=ethernet
autoconnect=true
[ipv4]
method=auto
[ipv6]
method=auto
EOF_NM
chmod 600 /etc/NetworkManager/system-connections/Wired-Fallback.nmconnection

if [ -n "$WIFI_SSID" ]; then
cat << EOF_WIFI > /etc/NetworkManager/system-connections/${WIFI_SSID}.nmconnection
[connection]
id=${WIFI_SSID}
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=${WIFI_SSID}

[wifi-security]
auth-alg=open
key-mgmt=wpa-psk
psk=${WIFI_PASS}

[ipv4]
method=auto

[ipv6]
method=auto
EOF_WIFI
chmod 600 /etc/NetworkManager/system-connections/${WIFI_SSID}.nmconnection
fi

# SystemCTL Services
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
log_info "Install [Completed]"
echo -e "${GREEN} You Can Now 'Reboot' into your custom SwayFX environment ${NC}"
