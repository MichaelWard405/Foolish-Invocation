#!/bin/bash
set -euo pipefail # Exit on error, unset variables, or pipeline failure

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MNT_DIR="/mnt"
USERNAME="${1:-archuser}"
TARGET_DISK="${2:-/dev/nvme0n1}" # Default to NVMe, can change to /dev/sda
FORMAT_EFI="true"
AUTO_REBOOT=1

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Helper Functions ---
print_header() {
  echo -e "${GREEN}=========================================${NC}"
  echo "$1"
  echo -e "${GREEN}=========================================${NC}"
}

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
  exit 1
}

# --- Step 1: Verify & Install Dependencies (Citation 1) ---
print_header "FOOLISH INVOCATION - ARCH LINUX DEPLOYMENT"
echo ""
if ! command -v jq &>/dev/null; then
  log_info "jq not found. Installing on live USB..."
  pacman -Sy --noconfirm jq || log_error "Failed to install jq. Cannot read packages.json."
fi

# Check for packages.json in script directory
if [ ! -f "$SCRIPT_DIR/packages.json" ]; then
  log_error "FATAL: packages.json not found in $(pwd). Please create it first."
fi

# --- Step 2: List Disks and Partitions (Enhanced Partition Logic from Older System) ---
print_header "Disk & Partition Discovery"
echo -e "${YELLOW}[INFO] Scanning for bootable drives...${NC}"

# List disks with partitions (exclude loopback)
DISK_INFO=""
while IFS= read -r line; do
  if [[ "$line" == *"/dev/nvme"* ]] || [[ "$line" == *"/dev/sda"* ]]; then
    DISK_INFO="$line"
  fi
done < <(lsblk -dno NAME,SIZE,MODEL -e 103 | grep -E "nvme|sda")

if [ -z "$DISK_INFO" ]; then
  log_warn "No NVMe or SATA drive found. Defaulting to $(findmnt -ro TARGET,FSTYPE -o target | head -1)"
fi

# Ask user for specific disk path if needed (from older system logic)
read -p "Enter target disk path [default: $TARGET_DISK]: " DISK_PATH
TARGET_DISK="${DISK_PATH:-/dev/nvme0n1}"

echo ""
echo -e "${GREEN}Available partitions on ${TARGET_DISK}:${NC}"
printf "%-20s %-7s %-8s %-6s\n" "NAME" "SIZE" "TYPE" "MOUNT"
lsblk -ro NAME,SIZE,FSTYPE,MOUNTPOINT -o NAME,SIZE,FSTYPE,MOUNTPOINT "$TARGET_DISK" 2>/dev/null || lsblk -n -o NAME,SIZE,FSTYPE "$TARGET_DISK"

# --- Step 3: Partition Selection (Enhanced Index Logic from Older System) ---
print_header "Partition Selection"
echo -e "${YELLOW}[WARNING] This script will FORMAT selected partitions.${NC}"
read -p "Select ROOT partition index (usually 2 or higher, e.g., nvme0n1p2): " ROOT_IDX
read -p "Select EFI partition index (usually 1, e.g., nvme0n1p1): " EFI_IDX

# --- Step 4: Build Partition Paths Safely ---
PARTITION_DEVICES=()
while IFS= read -r part_line; do
  # Extract just the device path from lsblk output
  PART_NAME=$(echo "$part_line" | awk '{print $1}')
  if [[ ! "$PARTITION_DEVICES" =~ "$PART_NAME" ]]; then
    PARTITION_DEVICES+=("$PART_NAME")
  fi
done < <(lsblk -n -o NAME -d 0 -D "$TARGET_DISK")

# Ensure we have at least 2 partitions for safety
if [ "${#PARTITION_DEVICES[@]}" -lt 2 ]; then
  log_error "Not enough partitions detected. Ensure you have EFI and Root partitions."
fi

ROOT_PART="${PARTITION_DEVICES[$((ROOT_IDX - 1))]}"
EFI_PART="${PARTITION_DEVICES[$((EFI_IDX - 1))]}"

echo ""
echo -e "${GREEN}Selected ROOT Partition: ${ROOT_PART}${NC}"
echo -e "${YELLOW}Selected EFI Partition:  ${EFI_PART}${NC}"

if [ "$ROOT_PART" == "$EFI_PART" ]; then
  log_error "FATAL ERROR: Root and EFI partitions cannot be the same device."
fi

# --- Step 5: Format Partitions (Btrfs for Root, FAT32 for EFI) ---
print_header "Step 1: Formatting Partitions"

log_info "Unmounting any existing mounts..."
for part in "$ROOT_PART" "$EFI_PART"; do
  umount "/mnt/$part" 2>/dev/null || true
done

# Format Root as Btrfs (Citation 1 & 3)
log_info "Formatting ${ROOT_PART} to BTRFS..."
mkfs.btrfs -f -L root "$ROOT_PART"

# Format EFI as FAT32
if [ "$FORMAT_EFI" == "true" ]; then
  log_info "Formatting ${EFI_PART} to FAT32 (BOOT)..."
  mkfs.fat -F 32 -n "BOOT" "$EFI_PART"
else
  log_warn "Skipping EFI formatting. Ensure UUIDs are valid if you're adding Windows later."
fi

# --- Step 6: Mount Hierarchy (Citation 1 & 2) ---
print_header "Step 2: Mounting Hierarchy"

mkdir -p /mnt/boot/efi
mkdir -p /home/"$USERNAME"
mkdir -p /var/log

mount "$ROOT_PART" /mnt
mount "$EFI_PART" /mnt/boot/efi

# Create Btrfs Subvolumes (Crucial for Hyprland/Swap/Home)
log_info "Creating BTRFS Subvolumes..."
btrfs subvolume create /home
btrfs subvolume create /var/log
echo -e "${GREEN}[OK] BTRFS Subvolumes created.${NC}"

# --- Step 7: Chroot and Install (Packages.json Logic from Older System) ---
print_header "Step 3: Installing Base System"

mount -t proc /proc /mnt/proc
mount -t sysfs /sys /mnt/sys
mount -t dev dev /mnt/dev

chroot /mnt /bin/bash <<'EOF'
set -e

# Sync pacman mirrors (Standard Arch Practice)
pacman-key --init
pacman-key --populate archlinux
pacman -Sy --noconfirm || true

# Install core utilities and JSON dependencies
pacman -S --noconfirm base-devel linux-firmware zsh networkmanager git jq

# --- AUR Helper Setup: Use 'ly' or 'yay-bin' fallback (Citation 1) ---
# Check if 'ly' is available, otherwise install yay-bin as backup
if command -v ly &>/dev/null; then
    echo "Using 'ly' as AUR helper"
    # Install additional AUR helper packages for hyprland dependencies
    ly -Sy --noconfirm 2>/dev/null || true
else
    echo "'ly' not found. Attempting yay-bin installation..."
    pacman -S --noconfirm yay-bin 2>/dev/null || true
fi

# --- Install Packages from JSON File (Older System Logic) ---
PACKAGES_FILE="/root/packages.json"
if [ -f "$PACKAGES_FILE" ]; then
    echo "==> Installing modular packages from JSON..."
    while IFS= read -r pkg; do
        if [[ ! -z "$pkg" ]]; then
            # Try AUR via 'ly' or 'yay', fallback to pacman for official repos
            if command -v yay &>/dev/null || command -v ly &>/dev/null; then
                yay -S --noconfirm "$pkg" 2>/dev/null || true
            else
                pacman -S --noconfirm "$pkg" 2>/dev/null || true
            fi
        fi
    done < <(cat "$PACKAGES_FILE")
else
    log_warn "packages.json not found in /root/. Installing core Hyprland manually."
fi

# --- Additional Hyprland Essentials ---
pacman -S --noconfirm hyprland-wayland-wlroots-libva-vulkan-utils vulkan-intel-filesystem 2>/dev/null || true

# --- Set System Locale, Hostname, and Root User ---
ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
hwclock --systohc
sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "arch-hyprland" > /etc/hostname

# --- Create User ---
useradd -m -G wheel -s /bin/zsh "$USERNAME" 2>/dev/null || true
passwd "$USERNAME" | passwd --stdin "$USERNAME" 2>/dev/null || true

# --- Configure NetworkManager for Wi-Fi (Optional) ---
systemctl enable NetworkManager

echo "==> Deployment Complete. Dismantling chroot mounts..."
exit 0
EOF

# --- Step 8: Cleanup and Reboot ---
print_header "Finalizing"
umount /mnt/dev
umount /mnt/sys
umount /mnt/proc
umount /mnt/boot/efi
umount /mnt

log_info "Installation Complete!"
echo -e "${GREEN}Pausing for ${NC}${BLUE}10 seconds...${NC}"
sleep 10

sync
poweroff
