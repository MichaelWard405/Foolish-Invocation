#!/bin/bash
set -euo pipefail

# --- Colors (from Citation 3) ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Helper Functions (from Citation 3 & 4) ---
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
  exit 1
}
mount_btrfs_root() {
  log_info "Mounting Root Partition as Btrfs..."
  mkdir -p "/mnt/boot/efi"
  # Mount main partition to /mnt (as root)
  mount "$ROOT_PARTITION" "/mnt"
}

setup_btrfs_subvolumes() {
  log_info "Configuring Btrfs Subvolumes..."

  # Create standard Arch directories if not present
  mkdir -p "/mnt/home/$USERNAME"
  mkdir -p "/mnt/var/log"
  mkdir -p "/mnt/etc/skel"

  # Check if currently mounted to ext4 (sometimes happens on live envs), switch if needed.
  if mountpoint -q "/mnt"; then
    umount "/mnt" 2>/dev/null || true
  fi

  # Ensure /mnt is Btrfs and remount with root subvolume logic
  mkfs.btrfs -f "$ROOT_PARTITION"

  # Mount Root directly as Btrfs root
  mount -t btrfs -o subvol=root "$ROOT_PARTITION" "/mnt"
}

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USERNAME="${1:-archuser}"
TARGET_DISK="${2:-/dev/nvme0n1}" # Default to NVMe, can change to /dev/sda
FORMAT_EFI="true"
AUTO_REBOOT=1

# --- Step 1: Verify Dependencies (jq) ---
log_info "Verifying dependencies..."
if ! command -v jq &>/dev/null; then
  log_warn "jq not found. Installing on live USB..."
  pacman -Sy --noconfirm jq || log_error "Failed to install jq. Cannot read packages.json."
fi

# Check for packages.json in script directory
if [ ! -f "$SCRIPT_DIR/packages.json" ]; then
  log_error "FATAL: packages.json not found in $(pwd). Please create it first."
fi

# --- Step 2: Disk & Partition Discovery (Enhanced Parsing) ---
log_info "Scanning for bootable drives..."

DISK_INFO=""
while IFS= read -r line; do
  if [[ "$line" == *"/dev/nvme"* ]] || [[ "$line" == *"/dev/sda"* ]]; then
    DISK_INFO="$line"
  fi
done < <(lsblk -dno NAME,SIZE,MODEL -e 103 | grep -E "nvme|sda")

# If no specific disk found, ask user for path (Enhanced Logic)
if [ -z "$DISK_INFO" ]; then
  log_warn "No NVMe or SATA drive detected in standard locations."
fi

read -p "Enter target disk path [default: $TARGET_DISK]: " DISK_PATH
TARGET_DISK="${DISK_PATH:-/dev/nvme0n1}"

# List Partitions Safely (from Citation 4 & Older System Logic)
log_info "Listing partitions on $TARGET_DISK..."
# Parse lsblk output carefully to avoid 'unbound variable' errors
mapfile -t PARTITION_DEVICES < <(lsblk -nno NAME | grep "^${TARGET_DISK}[^1-9]" || lsblk -nno NAME | tail -n +2)

if [ ${#PARTITION_DEVICES[@]} -lt 1 ]; then
  log_error "No partitions found on $TARGET_DISK."
fi

echo ""
echo -e "${GREEN}Available Partitions:${NC}"
printf "%-30s %-10s %-6s\n" "NAME" "SIZE" "TYPE"
for i in "${!PARTITION_DEVICES[@]}"; do
  PART_SIZE=$(lsblk -nno SIZE,SIZE "$TARGET_DISK"/"${PARTITION_DEVICES[$i]}" | tail -1)
  echo "$(printf "%-30s %-10s %-6s\n" "${PARTITION_DEVICES[$i]}" "Size")"
done

# --- Step 3: Partition Selection (Input Handling) ---
print_header "Partition Selection"
echo -e "${YELLOW}[WARNING] This script will FORMAT selected partitions.${NC}"
read -p "Select ROOT partition index (usually 2 or higher, e.g., nvme0n1p2): " ROOT_IDX
ROOT_PART="${PARTITION_DEVICES[$((ROOT_IDX - 1))]}"

read -p "Select EFI partition index (usually 1, e.g., nvme0n1p1): " EFI_IDX
EFI_PART="${PARTITION_DEVICES[$((EFI_IDX - 1))]}"

echo ""
echo -e "${GREEN}Selected ROOT Partition: ${ROOT_PART}${NC}"
echo -e "${YELLOW}Selected EFI Partition:  ${EFI_PART}${NC}"

if [ "$ROOT_PART" == "$EFI_PART" ]; then
  log_error "FATAL ERROR: Root and EFI partitions cannot be the same device."
fi

# --- Step 4: Format Partitions (Citation 2 & 3) ---
print_header "Step 1: Formatting Partitions"

log_info "Formatting ${ROOT_PART} to BTRFS..."
mount_btrfs_root # Uses function from Citation 4 logic

if [ "$FORMAT_EFI" == "true" ]; then
  log_info "Formatting ${EFI_PART} to FAT32 (BOOT)..."
  mkfs.fat -F 32 -n "BOOT" "$EFI_PART"
else
  log_warn "Skipping EFI formatting. Ensure UUIDs are valid if you're adding Windows later."
fi

# --- Step 5: Mount Hierarchy (Citation 4) ---
print_header "Step 2: Mounting Hierarchy"

mkdir -p "/mnt/boot/efi"
mount "$ROOT_PARTITION" /mnt
mount "$EFI_PART" "/mnt/boot/efi"

setup_btrfs_subvolumes # Configures Btrfs subvolumes as per Citation 4

# --- Step 6: Chroot and Install (Citation 3 & AUR Logic) ---
print_header "Step 3: Installing System"

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
if command -v ly &>/dev/null; then
    echo "Using 'ly' as AUR helper"
    # Install additional AUR helper packages for hyprland dependencies
    # Note: Ly is in AUR, so if it's not installed yet, this might fail. 
    # Fallback to yay-bin installation logic if ly is missing or fails.
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

# --- Step 7: Cleanup and Reboot ---
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
