#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status

# ============================================
# --- Colors (from Citation 1 & 3) ---
# ============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================
# --- Helper Functions (Citation 2 Style) ---
# ============================================

print_header() {
    echo -e "${GREEN}=========================================${NC}"
    echo "$1"
    echo -e "${GREEN}=========================================${NC}"
}

read_partition() {
    local prompt="$1"
    read -p "${prompt}: " value
    echo "$value"
}

# ============================================
# --- Step 1: Interactive Inputs (Citation 1 & 2) ---
# ============================================

print_header "FOOLISH INVOCATION"
print_header "Hyprland Arch VM Installer"

echo -e "${YELLOW}[INFO] This script will wipe partitions selected. Proceed with caution.${NC}"

read -p "Enter desired username: " USERNAME
USERNAME="${USERNAME:-archuser}" # Default if empty, but user can override

# Note: We handle password in chroot for safety/complexity or via mkpasswd later
# For this auto-setup, we will prompt here using a secure method if available

print_header "Partition Selection"

echo -e "${YELLOW}Please select the partition for Root (Linux VM) or press Enter for Auto-Detect (if nvme)...${NC}"
read MAIN_PARTITION
MAIN_PARTITION="${MAIN_PARTITION:-/dev/nvme0n1p3}" # Default fallback

echo -e "${YELLOW}Please select the EFI Partition...${NC}"
read EFI_PARTITION
EFI_PARTITION="${EFI_PARTITION:-/dev/nvme0n1p1}" # Default fallback

# ============================================
# --- Step 2: Formatting Partitions (Btrfs) ---
# ============================================

print_header "Step 1: Partitioning and Filesystem Setup"

# 1. Format EFI (FAT32) as per Citation 2/3 logic
echo -e "${YELLOW}Formatting EFI partition ${EFI_PARTITION}...${NC}"
# Check if it looks like a UUID path or device, handle accordingly
if [[ ! "$EFI_PARTITION" =~ ^/[ \d\s] ]]; then
    # Assume device path
    mkfs.fat -F 32 -n "BOOT" "${EFI_PARTITION}" 2>/dev/null || true
else
    echo -e "${RED}[WARNING] Invalid EFI Partition Path format.${NC}"
fi

# 2. Format Main Partition (Btrfs) per Citation 1 & User Request
echo -e "${YELLOW}Formatting Main Partition ${MAIN_PARTITION} to BTRFS...${NC}"
mkfs.btrfs -f -L root "${MAIN_PARTITION}"

print_header "Step 2: Mounting Hierarchy"

# 3. Mount Hierarchy (Citation 3)
mkdir -p /mnt/boot/efi # Standard mount point
mkdir -p /home/${USERNAME}

mount "${MAIN_PARTITION}" /mnt
mount "${EFI_PARTITION}" /mnt/boot/efi

# Create Btrfs Subvolumes (Crucial for Hyprland/Swap/HOME per Citation 1)
echo -e "${YELLOW}Creating BTRFS Subvolumes...${NC}"
btrfs subvolume create /home

print_header "Step 3: Installing System"

# Mount proc, sys, dev into chroot for pacman (Standard Arch logic)
mount -t proc /proc /mnt/proc
mount -t sysfs /sys /mnt/sys
mount -t dev dev /mnt/dev

echo -e "${GREEN}Entering Chroot to Install Base...${NC}"
chroot /mnt

# Inside Chroot, we need to fix a few things before exiting back to live (optional step)
# But usually, pacman runs inside chroot. Let's run the installer logic:

cd /
pacman -Sy --noconfirm

# ============================================
# --- Step 4: AUR Helper & Packages.json (Citation 1 & 2) ---
# ============================================

echo -e "${YELLOW}Configuring Ly as AUR Helper...${NC}"
# Since 'ly' might not be in official repo, install yay-bin logic fallback if needed
# But we will try to fetch ly first (as per Citation 1)
pacman -S --noconfirm git base-devel linux-firmware zsh networkmanager hyprland-wayland-wlroots-libva-vulkan-utils vulkan-intel-filesystem

# Check for packages.json file in /root of Live Environment or chroot path
# We will assume the JSON is passed to chroot context (e.g. copied via loop)
# If running directly from live environment variables:

if [ -f "$HOME/packages.json" ]; then
    PACKAGES_FILE="$HOME/packages.json"
elif [ -f "/packages.json" ]; then
    PACKAGES_FILE="/packages.json"
else
    # Default Hyprland list if JSON missing (Fallback)
    PACKAGES_LIST="hyprland kitty wofi grim slurp waybar nitrogen networkmanager zsh git alsa-utils"
fi

# Install AUR Helper: ly or yay-bin fallback
pacman -S --noconfirm linux-firmware

if command -v ly &> /dev/null; then
    echo -e "${GREEN}Using Ly as AUR Helper...${NC}"
else
    # Fallback logic per Citation 1
    echo -e "${RED}Ly not found. Attempting Yay-Bin or manual install...${NC}"
    pacman -S --noconfirm yay-bin
fi

# Install packages from JSON using jq if available (Citation 2)
if command -v jq &> /dev/null && [ -n "$PACKAGES_FILE" ]; then
    echo -e "${GREEN}Reading Package List from ${PACKAGES_FILE}...${NC}"
    # Loop through JSON and install
    while IFS= read -r pkg; do
        # Handle both aur and official repos (using -S without arg tries AUR)
        if [[ "$pkg" =~ ^(linux|grub|systemd)$ ]]; then
            pacman -S --noconfirm "$pkg"
        else
            yay -S --noconfirm "$pkg" 2>/dev/null || pacman -S --noconfirm "$pkg" 2>/dev/null || true
        fi
    done < <(cat "${PACKAGES_FILE}" | jq -r '.[]')
else
    echo -e "${YELLOW}Reading from Fallback List (Hyprland + Wayland)...${NC}"
    # Install standard Hyprland essentials manually if JSON fails
    yay -S --noconfirm hyprland kitty wofi grim slurp waybar nitrogen networkmanager zsh git alsa-utils libpulse 2>/dev/null || pacman -S --noconfirm hyprland kitty zsh alsa-utils 2>/dev/null || true
fi

# ============================================
# --- Step 5: Hyprland Configuration & User Setup ---
# ============================================

echo -e "${GREEN}Setting up User Environment...${NC}"

# Create user if not exists (inside chroot)
useradd -m -s /bin/zsh "$USERNAME" 2>/dev/null || true

# Basic config for Hyprland
mkdir -p ~/.config/hypr
echo "exec = wofi --show run" > ~/.config/hypr/wofi.conf  # Placeholder for startup

# Setup Sudoers (Enable user to run commands)
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/${USERNAME} 2>/dev/null || true

# Configure Ly (from Citation 1)
mkdir -p ~/.config/ly
cat > ~/.config/ly/config.json << 'EOF'
{
    "theme": "dark",
    "layout": "horizontal"
}
EOF

print_header "Step 6: Cleanup and Exit"

# Unmount Chroot
umount /mnt/dev
umount /mnt/sys
umount /mnt/proc
umount /mnt/boot/efi
umount /mnt

echo -e "${GREEN}[INSTALLER]${NC} Setup Complete!"
echo -e "${YELLOW}[WARNING]${NC} You must reboot now to use your new Hyprland Arch VM."

# ============================================
# --- Step 7: Auto Reboot Logic (User Requirement) ---
# ============================================

echo -e "${GREEN}Pausing for ${NC}${BLUE}10 seconds...${NC}"
sleep 10

# Attempt to reboot the system. Note: If you are in a VM, poweroff might work better if guest tools aren't set up.
sync; poweroff

# If poweroff fails in this context, user may need manual ctrl+alt+del
echo -e "${GREEN}Reboot sequence initiated.${NC}"
