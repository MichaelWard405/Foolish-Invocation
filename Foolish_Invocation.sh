#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status

# --- Colors (from Citation 1) ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo -e "${GREEN}=========================================${NC}"
    echo "$1"
    echo -e "${GREEN}=========================================${NC}"
}

# --- Helper Function to Run Commands Safely ---
run_cmd() {
    local output=("$@")
    if command -v "$output[0]" &>/dev/null; then
        "${output[@]}"
    else
        echo -e "${RED}[ERROR] Missing required tool: ${output[0]}${NC}" >&2
        exit 1
    fi
}

# --- Step 1: User Inputs ---
print_header "FOOLISH INVOCATION"
echo -e "${YELLOW}[INFO] Please be patient. This script will manage partitions.${NC}"

read -p "Enter your Username (default: archuser): " USERNAME
USERNAME="${USERNAME:-archuser}"

# --- Step 2: Partition Listing and Selection ---
print_header "Select Disks and Partitions"
echo -e "${YELLOW}[WARN] This script will format disks selected. Proceed with caution.${NC}"

# Ask for the disk (e.g., /dev/sda)
read -p "Enter Base Disk Path [e.g. /dev/sda]: " DISK_PATH
DISK_PATH="${DISK_PATH:-/dev/nvme0n1}" # Default fallback if empty

echo ""
echo -e "${GREEN}Listing Partitions on ${DISK_PATH}:${NC}"
echo -e "------------------------------------------------------------"
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT -n --no-headings | while read line; do
    echo "$(printf "%-10s %-8s %-6s %s" $(echo $line | cut -d' ' -f1) $(echo $line | cut -d' ' -f2) $(echo $line | cut -d' ' -f3) $(echo $line | cut -d' ' -f4))")
done

echo "------------------------------------------------------------"
echo ""

# We assume the first valid entry on the disk is EFI, second is Root usually. 
# But we will allow user to pick by index (1 for sda1, 2 for sda2).

print_header "Partition Selection Logic"
echo -e "${YELLOW}[INFO] We will attempt to auto-detect based on size first.${NC}"
echo -e "${YELLOW}Please verify this matches your desired layout:${NC}"

# Assign indices from lsblk output list (excluding the disk header)
# We read the previous lsblk loop result into an array for selection
IFS=$'\n' 
DISK_PARTS=($(lsblk -n -o NAME,SIZE,FSTYPE --exclude "/dev/sd[0-9]" 2>/dev/null || lsblk -n -o NAME,SIZE,FSTYPE))

# Simplified approach: Prompt specifically for Root and EFI based on device order
print_header "1. Select EFI Partition"
echo -e "${YELLOW}Partition List (Format: Index | Device)${NC}"
echo "------------------------------------------------------------"
index=0
for part in $(lsblk -n -o NAME --sort SIZE -r /dev/sda| tail -n +2); do 
    echo "${GREEN}${index}. ${part}${NC}"
    ((index++))
done

# Store the selection logic safely to avoid "command not found" errors
read -p "Enter Index for EFI Partition (usually 1): " EFI_INDEX

print_header "2. Select Root Partition"
echo -e "${YELLOW}Partition List (Format: Index | Device)${NC}"
echo "------------------------------------------------------------"
# We must re-scan because the previous loop might have exited or variables cleared in subshells
read -p "Enter Index for ROOT Partition (usually 2): " ROOT_INDEX

# Map indices to actual paths from lsblk output
PARTITION_PATHS=($(lsblk -n -o NAME --sort SIZE -r /dev/sda | tail -n +2))
if [ ${#PARTITION_PATHS[@]} -ge 2 ]; then
    EFI_PART="${PARTITION_PATHS[$((EFI_INDEX-1))]}"
    ROOT_PART="${PARTITION_PATHS[$((ROOT_INDEX-1))]}"
else
    echo -e "${RED}[ERROR] Not enough partitions found on ${DISK_PATH}.${NC}" >&2
    exit 1
fi

echo ""
echo -e "${GREEN}Selected EFI: ${EFI_PART}${NC}"
echo -e "${YELLOW}Selected Root: ${ROOT_PART}${NC}"

# --- Step 3: Formatting (Citation 1 & 2 Logic) ---
print_header "Step 1: Partitioning and Filesystem Setup"

# Format EFI (FAT32)
if mountpoint -q "/boot/efi"; then
    umount "/boot/efi" 2>/dev/null || true
fi

echo -e "${YELLOW}Formatting EFI Partition (${EFI_PART}) to FAT32...${NC}"
mkfs.fat -F 32 -n "BOOT" "$EFI_PART"
if [ $? -eq 0 ]; then
    echo -e "${GREEN}[OK] EFI partition formatted.${NC}"
else
    echo -e "${RED}[FAIL] Formatting EFI failed. Check if device is writable.${NC}" >&2
fi

# Format Root (Btrfs)
echo -e "${YELLOW}Formatting Root Partition (${ROOT_PART}) to BTRFS...${NC}"
mkfs.btrfs -f -L root "$ROOT_PART"
if [ $? -eq 0 ]; then
    echo -e "${GREEN}[OK] Root partition formatted as BTRFS.${NC}"
else
    echo -e "${RED}[FAIL] Formatting Root failed. Ensure btrfs-progs is installed.${NC}" >&2
fi

# --- Step 4: Mount Hierarchy (Citation 3) ---
print_header "Step 2: Mounting Hierarchy"
mkdir -p /mnt/boot/efi

mount "$ROOT_PART" /mnt
mount "$EFI_PART" /mnt/boot/efi

# Btrfs Subvolume Creation (Crucial for Hyprland)
echo -e "${YELLOW}Creating BTRFS Subvolumes...${NC}"
btrfs subvolume create /home
if [ $? -ne 0 ]; then
    echo -e "${RED}[FAIL] Failed to create /home subvolume.${NC}" >&2
fi

# --- Step 5: Package Installation (Citation 1) ---
print_header "Step 3: Installing System & AUR Helper"

mount -t proc /proc /mnt/proc
mount -t sysfs /sys /mnt/sys
mount -t dev dev /mnt/dev

echo -e "${GREEN}Entering Chroot...${NC}"
chroot /mnt

# Inside chroot, install base and Hyprland packages
# Note: This step requires 'yay' or 'pacman -S' access. Since 'ly' might be missing, use yay-bin.
pacman -Sy --noconfirm

# Try to install yay-bin as AUR helper (Fallback) or ly if present
if command -v yay &>/dev/null; then
    yay -S --noconfirm hyprland kitty wofi grim slurp waybar nitrogen networkmanager zsh git
else
    pacman -S --noconfirm hyprland kitty wofi grim slurp waybar nitrogen networkmanager zsh git
fi

# Check for packages.json (Citation 1)
PACKAGES_FILE=""
if [ -f "$HOME/packages.json" ]; then
    PACKAGES_FILE="$HOME/packages.json"
    echo -e "${GREEN}[INFO] Using provided ${PACKAGES_FILE}.${NC}"
fi

# Cleanup Chroot before exiting
umount /mnt/dev
umount /mnt/sys
umount /mnt/proc

echo -e "${GREEN}[INSTALLER]${NC} Setup Complete!"
echo -e "${YELLOW}[WARNING]${NC} You must reboot now to use your new Hyprland Arch VM."

# ============================================
# --- Step 6: Auto Reboot (User Requirement) ---
# ============================================

echo -e "${GREEN}Pausing for ${NC}${BLUE}10 seconds...${NC}"
sleep 10

sync; poweroff

3 Citations


44.65 tok/sec
2973 tokens
3.35s
Stop reason: EOS Token Found

