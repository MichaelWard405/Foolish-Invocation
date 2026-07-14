#!/bin/bash
set -euo pipefail

#=======================
# Colour Parameters [1]
#=======================
#[COLOUR SETTING] [A]
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'
#[COLOURED HELPER FUNCTIONS] [B]
print_header() {
  echo -e "\n${BLUE}==========================================${NC}"
  echo -e "${GREEN} $1 ${NC}"
  echo -e "${BLUE}==========================================${NC}"
}
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
  exit 1
}

#================
# Parameters [2]
#================
#[Selected Disk] [A]
TARGET_DISK="${1:-/dev/sda}"
#[RAW GITHUB PACKAGE JSON] [B]
RAW_GITHUB_URL="https://raw.githubusercontent.com/MichaelWard405/Foolish-Invocation/master/packages.json"
#[GPU SELECTION] [C]
GPU_PKGS=""
NVIDIA_PARAM=""
#[USER DETAILS] [D]
USERNAME="FOOL"
USER_PASSWORD=""
#[WIFI DETAILS] [E]
WIFI_SSID=""
WIFI_PASSWORD=""
#[LOCATION] [F]
TIMEZONE="Australia/Brisbane"

#==========================
# Step 1 - Credentials [3]
#==========================
print_header"Step 1: Credentials"
#[SET USER DETAILS] [A]
#[Set UserName]
read -p "Enter Desired Name Default: [FOOL]: " INPUT_USER
USERNAME="${INPUT_USER:-FOOL}"
#[Set PassWord]
while true; do
  read -s -p "Enter Desired PassWord for $USERNAME & ROOT: " USER_PASSWORD
  echo ""
  read -s -p "Confirm Stated PassWord: " USER_PASSWORD_CONFIRM
  echo ""
  if [ "$USER_PASSWORD" == "$USER_PASSWORD_CONFIRM" ] && [ -n "$USER_PASSWORD" ]; then
    log_info "PassWord [CONFIRMED]"
    break
  else
    echo -e "${RED}PassWord [FAILED] ${NC}"
  fi
done
echo ""

#[TIMEZONE SELECTION] [B]
echo "Select TimeZone:"
echo "  [1] Australia/Brisbane"
echo "  [2] Asia/Tokyo"
echo "  [3] Custom"
read -p "Enter SELECTION: " TZ_CHOICE
case ${TZ_CHOICE:-1} in
1) TIMEZONE="Australia/Brisbane" ;;
2) TIMEZONE="Asia/Tokyo" ;;
3) read -p "Enter Your TimeZone: " TIMEZONE ;;
*) TIMEZONE="Australia/Brisbane" ;;
esac
log_info "TIMEZONE: $TIMEZONE"
echo ""

#[SET WIFI DETAILS] [C]
log_info "[OPTIONAL] Wireless Setup"
read -p "Enter WIFI Name [SSID]: " WIFI_SSID
if [ -n "$WIFI_SSID" ]; then
  read -s -p "Enter WIFI PassWord: " WIFI_PASSWORD
  echo ""
  log_info "WIFI Credentials Saved for Deployment"
fi

#==============================
# Step 2 - Retrieval & GPU [4]
#==============================
print_header "Step 2: Retrieval"
#[SYSTEM PACKAGE INSTALL] [A]
if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null; then
  pacman -Sy --noconfirm jq curl || log_error "Failed To Install Dependencies"
fi
curl -sL "$RAW_GITHUB_URL" -o "packages.json"
if [ ! -f "packages.json" ] || ! jq . "packages.json" >/dev/null 2>&1; then
  log_error "[ERROR] Failed to Install Packages"
fi
#[GPU SELECTION] [B]
print_header "Step 2.1: GPU Driver selection"
echo "Select Your GPU drivers"
echo "  [1] AMD"
echo "  [2] Intel"
echo "  [3] NVIDIA"
echo "  [4] VM / Generic"
read -p "Enter Selection: " GPU_CHOICE
case $GPU_CHOICE in
1) GPU_PKGS="mesa vulkan-radeon xf86-video-amdgpu" ;;
2) GPU_PKGS="mesa vulkan-intel xf86-video-intel" ;;
3)
  GPU_PKGS="nvidia-dkms nvidia-utils linux-headers"
  NVIDIA_PARAM="nvidia_drm.modeset=1"
  ;;
*) GPU_PKGS="mesa" ;;
esac
log_info "Selected: $GPU_PKGS"

#==================================
# Step 3 - Partition Selection [5]
#==================================
print_header "Step 3: Partition Selection"
#[USER PARTITION SELECTION] [A]
lsblk -dno NAME,SIZE,MODEL | grep -v "loop"
read -p "Enter Target Disk: " DISK_PATH
TARGET_DISK="${DISK_PATH:-$TARGET_DISK}"

#[PARTITION VERIFY] [B]
mapfile -t PART_PATH < <(lsblk -rno NAME,TYPE "$TARGET_DISK" | awk '$2=="part" {print "/dev/"$1}')
if [ ${#PART_PATH[@]} -eq 0 ]; then
  log_error "No Partition Found On $TARGET_DISK"
fi
for i in "${!PART_PATH[@]}"; do
  PART_INFO=$(lsblk -dno SIZE,FSTYLE,LABEL "${PART_PATH[$i]}" | tr -s ' ')
  echo "  [$((i + 1))] ${PART_PATH[$1]} -> ($PART_INFO)"
done

#[PARTITION DESIGNATION] [C]
read -p "Select ROOT Partition [BTRFS]: " ROOT_IDX
ROOT_PART="${PART_PATHS[$((ROOT_IDX - 1))]}"
read -p "Select EFI Partition [FAT32]: " EFI_IDX
EFI_PART="${PART_PATHS[$((EFI_IDX - 1))]}"
if [ "$ROOT_PART" == "$EFI_PART" ]; then
  log_error "Root & EFI Partitions Cannot Be The Same Device"
fi

#====================================
# Step 4 - Formatting & Mounting [6]
#====================================
print_header "Step 4: Formatting & Mounting"
#[UNMOUNT] [A]
umount -q -R /mnt 2>/dev/null || true
umount -q "$EFI_PART" 2/dev/null || true

#[MAKE DIRECTORY] [B]
mkfs.btrfs -f "ROOT_PART"
mkfs.fat -F 32 -n "BOOT" "$EFI_PART"

#[SUBVOLUME CREATION] [C]
mount "$ROOT_PART" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@pkg
btrfs subvolume create /mnt/@snapshots
umount /mnt
BTRFS_OPTS="noatime,compress=zstd,space_cache=v2"

#[SUBVOLUME MOUNTING] [D]
mount -o "BTRFS_OPTS",subvol=@ "ROOT_PART" /mnt
mkdir -p /mnt/{home,var/log,var/cache/pacman/pkg,.snapshots,boot/efi}
mount -o "$BTRFS_OPTS",subvol=@home "$ROOT_PART" /mnt/home
mount -o "$BTRFS_OPTS",subvol=@log "$ROOT_PART" /mnt/var/log
mount -o "$BTRFS_OPTS",subvol=@pkg "$ROOT_PART" /mnt/var/cache/pacman/pkg
mount -o "$BTRFS_OPTS",subvol=@snapshots "$ROOT_PART" /mnt/.snapshots
mount -t vfat "$EFI_PART" /mnt/boot/efi
