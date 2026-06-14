#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status

# ============================================
# --- Colors (from Citation 1 & 2) ---
# ============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ============================================
# --- Helper Functions (Citation 2 Style) ---
# ============================================

print_header() {
  echo -e "${GREEN}=========================================${NC}"
  echo "$1"
  echo -e "${GREEN}=========================================${NC}"
}

get_input() {
  local prompt="$1"
  local default="${2:-}"
  local val
  if [ -n "$default" ]; then
    read -r val && val=${val:-$default}
  else
    read -r val
  fi
  echo "${val# }" # Trim spaces
}

run_cmd() {
  # Standard command runner with error handling
  "$@" &>/dev/null || return 1
  return $?
}

# ============================================
# --- Step 1: Disk and Partition Selection Logic ---
# ============================================

print_header "FOOLISH INVOCATION"
print_header "Hyprland Arch VM Installer - Btrfs Edition"

echo -e "${YELLOW}[INFO] This script will format partitions. Proceed with caution.${NC}"

# 1. Ask for the base disk path (e.g., /dev/sda)
echo ""
read -p "Enter base disk path [e.g. /dev/sda]: " DISK_PATH
DISK_PATH="${DISK_PATH:-/dev/nvme0n1}" # Default fallback if empty

# 2. List Partitions for selection
print_header "Partition Selection"
echo -e "${CYAN}Please verify the partitions on ${DISK_PATH}...${NC}"

echo -e "${GREEN}Available partitions on ${DISK_PATH}:${NC}"
printf "%-10s %-10s %-6s %-6s\n" "NAME" "SIZE" "TYPE" "MOUNT"
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT -n | grep "^${DISK_PATH}" | while read line; do
  printf "%-15s %-7s %-7s %s\n" "$(echo "$line" | cut -d' ' -f1)" "$(echo "$line" | cut -d' ' -f2)" "$(echo "$line" | cut -d' ' -f3)" "$(echo "$line" | cut -d' ' -f4)"
done

# Function to wait for number selection
select_partition() {
  local label="$1"
  echo -e "${YELLOW}Enter partition index (e.g., 1 for /dev/sda1) for ${label} [Default: 2]:"$'\r'
  read idx || idx=2
  # Note: lsblk output order might vary, we assume standard EFI then Root or user specifies.
  # For simplicity in this script, we will assign based on index from the lsblk list above.
  echo "$idx"
}

# Capture Root Partition Index (e.g., if /dev/sda2 is root)
ROOT_IDX=select_partition "Root Partition" # User input logic here would require a loop, keeping simple for now
ROOT_IDX=$(read -p "Select number for ${label}: " ROOT_NUM)

# Capture EFI Partition Index (usually the first partition)
EFI_IDX=$(read -p "Select number for ${label} (usually index 1): " EFI_NUM)

# Retrieve actual paths based on user selection (Simulated from lsblk list above)
# NOTE: To ensure this works dynamically, we parse lsblk output into an array
partitions=($(lsblk -n -o NAME))

ROOT_PART="${partitions[$((ROOT_NUM - 1))]}"
EFI_PART="${partitions[$((EFI_NUM - 1))]}"

echo ""
echo -e "${GREEN}Selected Root: ${ROOT_PART}${NC}"
echo -e "${YELLOW}Selected EFI:  ${EFI_PART}${NC}"

# ============================================
# --- Step 2: Formatting Partitions (Citation 1 & 2) ---
# ============================================

print_header "Step 1: Formatting and Filesystem Setup"

# Check if we need to format (User Request Logic)
echo -e "${YELLOW}Formatting EFI Partition...${NC}"
if mountpoint -q "/boot/efi"; then
  umount "/boot/efi" 2>/dev/null || true
fi

# Ensure mkfs.vfat exists, otherwise check for gptfdisk or similar tools if missing
if command -v mkfs.fat &>/dev/null; then
  mkfs.vfat -F 32 -n "BOOT" "$EFI_PART"
  echo -e "${GREEN}EFI formatted successfully.${NC}"
else
  echo -e "${RED}[ERROR] mkfs.vfat not found. Install dosfstools first.${NC}"
  exit 1
fi

echo -e "${YELLOW}Formatting Main Partition as BTRFS...${NC}"
# Note: In Arch, we usually use mkfs.btrfs on the device directly
if command -v mkfs.btrfs &>/dev/null; then
  mkfs.btrfs -f -L root "$ROOT_PART"
  echo -e "${GREEN}Root partition formatted to BTRFS.${NC}"
else
  # Fallback or error check (Citation 2 suggests this is a requirement)
  echo -e "${RED}[WARNING] btrfs-progs not found. Hyprland requires BTRFS or swap setup.${NC}"
fi

# ============================================
# --- Step 3: Mount Hierarchy (Citation 1 & 3) ---
# ============================================

print_header "Step 2: Mounting Hierarchy"

# Create mount points
mkdir -p /mnt/boot/efi # Standard mount point for arch installer
mkdir -p /mnt/home
mkdir -p /mnt/proc
mkdir -p /mnt/sys

# Mount Root Btrfs
mount "$ROOT_PART" /mnt
# Remount root if needed for btrfs subvolume creation (Citation 2 logic)
if mountpoint -q "/mnt"; then
  # Check fstype, remount as subvol=root if it's a Btrfs device with default subvols
  current_fstype=$(df /mnt | tail -1 | awk '{print $2}')
  if [ "$current_fstype" = "btrfs" ]; then
    mount -t btrfs -o subvol=root /mnt /mnt 2>/dev/null || echo "Root is already mounted as root."
  fi
fi

# Mount EFI
mount "$EFI_PART" /mnt/boot/efi

# ============================================
# --- Step 4: Package Installation (Citation 1 & 2) ---
# ============================================

print_header "Step 3: Installing Packages"

# Chroot logic for pacman
mount -t proc /proc /mnt/proc
mount -t sysfs /sys /mnt/sys
mount -t dev dev /mnt/dev

chroot /mnt

# Inside chroot, we need to setup basic system before AUR install
pacman -Sy --noconfirm || echo "Could not sync packages"

# Install System & Hyprland (Citation 1 packages.json logic)
echo -e "${GREEN}Configuring Ly as AUR Helper...${NC}"
# Setup yay-bin or ly logic if not present
pacman -S --noconfirm git base-devel linux-firmware zsh networkmanager hyprland-wayland-wlroots-libva-vulkan-utils vulkan-intel-filesystem

# Read packages.json (User Requirement)
if [ -f "$HOME/packages.json" ]; then
  PACKAGES_FILE="$HOME/packages.json"
elif [ -f "/packages.json" ]; then
  PACKAGES_FILE="/packages.json"
else
  echo -e "${YELLOW}No packages.json found. Skipping JSON install.${NC}"
fi

# If json exists, install via loop (Simplified logic)
if [ -n "$PACKAGES_FILE" ] && command -v jq &>/dev/null; then
  echo -e "${GREEN}Reading Package List...${NC}"
  while IFS= read -r pkg; do
    # Filter out empty lines or comments
    if [[ ! -z "$pkg" ]]; then
      # Handle specific repo handling
      if [[ "$pkg" =~ ^(linux|grub)$ ]]; then
        pacman -S --noconfirm "$pkg" 2>/dev/null || true
      else
        yay -S --noconfirm "$pkg" 2>/dev/null || pacman -S --noconfirm "$pkg" 2>/dev/null || true
      fi
    fi
  done < <(cat "$PACKAGES_FILE" 2>/dev/null)
fi

# Cleanup and exit chroot
exit 0

# ============================================
# --- Step 5: Finalize and Reboot (User Request) ---
# ============================================

print_header "Installation Complete!"

echo -e "${GREEN}Pausing for ${NC}${BLUE}10 seconds${NC} before reboot..."
sleep 10

sync
poweroff
