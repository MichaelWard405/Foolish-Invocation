#!/bin/bash
set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Helper Functions ---
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
  exit 1
}
print_header() {
  echo -e "\n${BLUE}================================================================${NC}"
  echo -e "${GREEN}  $1 ${NC}"
  echo -e "${BLUE}================================================================${NC}"
}

# --- Configuration ---
USERNAME="${1:-archuser}"
TARGET_DISK="${2:-/dev/nvme0n1}"
FORMAT_EFI="true"
# UPDATED: Pointing to the 'master' branch
GITHUB_RAW_URL="https://raw.githubusercontent.com/MichaelWard405/Foolish-Invocation/master/packages.json"

# --- Step 1: Verify Dependencies & Fetch JSON ---
print_header "Step 1: Environment & Config Retrieval"

# Ensure jq and curl are installed on the live environment
if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null; then
  log_warn "Required tools missing. Installing jq and curl on live USB..."
  pacman -Sy --noconfirm jq curl || log_error "Failed to install dependencies."
fi

# Dynamically fetch the packages.json directly from GitHub
log_info "Fetching packages.json from GitHub (master branch)..."
curl -sL "$GITHUB_RAW_URL" -o "packages.json"

# Validate that the file downloaded and is valid JSON
if [ ! -f "packages.json" ] || ! jq . "packages.json" >/dev/null 2>&1; then
  log_error "FATAL: Failed to download or parse packages.json from GitHub. Check your internet connection or repository URL."
fi
log_info "Successfully loaded packages configuration."

# --- Step 2: Disk & Partition Discovery ---
print_header "Step 2: Disk & Partition Selection"
lsblk -dno NAME,SIZE,MODEL | grep -v "loop"
echo "----------------------------------------------------------------"
read -p "Enter target disk path (e.g., /dev/nvme0n1 or /dev/sda) [default: $TARGET_DISK]: " DISK_PATH
TARGET_DISK="${DISK_PATH:-$TARGET_DISK}"
echo "----------------------------------------------------------------"

# Safely map partitions based on the exact path
mapfile -t PART_PATHS < <(lsblk -rno NAME,TYPE "$TARGET_DISK" | awk '$2=="part" {print "/dev/"$1}')

if [ ${#PART_PATHS[@]} -eq 0 ]; then
  log_error "No partitions found on $TARGET_DISK. Please run cfdisk first."
fi

echo "Existing partitions on $TARGET_DISK:"
for i in "${!PART_PATHS[@]}"; do
  PART_INFO=$(lsblk -dno SIZE,FSTYPE,LABEL "${PART_PATHS[$i]}" | tr -s ' ')
  echo "  [$((i + 1))] ${PART_PATHS[$i]}  ->  ($PART_INFO)"
done

echo ""
echo -e "${YELLOW}[WARNING] The selected ROOT partition will be formatted to BTRFS!${NC}"
read -p "Select ROOT partition index: " ROOT_IDX
ROOT_PART="${PART_PATHS[$((ROOT_IDX - 1))]}"

read -p "Select EFI partition index: " EFI_IDX
EFI_PART="${PART_PATHS[$((EFI_IDX - 1))]}"

if [ "$ROOT_PART" == "$EFI_PART" ]; then
  log_error "FATAL ERROR: Root and EFI partitions cannot be the same device."
fi

# --- Step 3: Format & Mount Partitions ---
print_header "Step 3: Formatting & Mounting"

# Unmount just in case they are busy
umount -q "$ROOT_PART" 2>/dev/null || true
umount -q "$EFI_PART" 2>/dev/null || true

log_info "Formatting ${ROOT_PART} to BTRFS..."
mkfs.btrfs -f "$ROOT_PART"

if [ "$FORMAT_EFI" == "true" ]; then
  log_info "Formatting ${EFI_PART} to FAT32 (BOOT)..."
  mkfs.fat -F 32 -n "BOOT" "$EFI_PART"
fi

log_info "Mounting File Systems..."
mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot/efi
mount -t vfat "$EFI_PART" /mnt/boot/efi

# --- Step 4: Bootstrap Base System ---
print_header "Step 4: Bootstrapping Base Arch System"

# We install the absolute bare minimum here to ensure the chroot works.
# The rest of your packages.json will be installed safely via 'yay' inside the chroot.
log_info "Running pacstrap..."
pacstrap -K /mnt base base-devel linux linux-firmware networkmanager git zsh jq curl

log_info "Generating fstab..."
genfstab -U /mnt >>/mnt/etc/fstab

# Copy the fetched packages.json to the new system so the chroot can read it
cp packages.json /mnt/root/

# --- Step 5: System Configuration via arch-chroot ---
print_header "Step 5: Chroot Environment Configuration"

arch-chroot /mnt /bin/bash <<EOF
    set -e
    
    # --- Set System Locale, Hostname, and Root User ---
    ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
    hwclock --systohc
    sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    locale-gen
    echo "LANG=en_US.UTF-8" > /etc/locale.conf
    echo "arch-hyprland" > /etc/hostname

    # --- Create User ---
    useradd -m -G wheel -s /bin/zsh "$USERNAME"
    echo "$USERNAME:password" | chpasswd  # REPLACE 'password' WITH YOUR DESIRED DEFAULT
    echo "root:password" | chpasswd       # REPLACE 'password' WITH YOUR DESIRED DEFAULT
    echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" >> /etc/sudoers

    # --- Bootloader (Grub) ---
    pacman -S --noconfirm grub efibootmgr
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
    grub-mkconfig -o /boot/grub/grub.cfg

    # --- AUR Helper Setup (yay-bin) ---
    echo "==> Setting up AUR Helper (yay-bin)..."
    sudo -u "$USERNAME" bash -c "cd ~ && git clone https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si --noconfirm"

    # --- Install Packages from JSON File ---
    PACKAGES_FILE="/root/packages.json"
    if [ -f "\$PACKAGES_FILE" ]; then
        echo "==> Installing modular packages from GitHub JSON..."
        
        # Parse the flat JSON array into a single space-separated string
        ALL_PKGS=\$(jq -r '.[]' "\$PACKAGES_FILE" | tr '\n' ' ')
        
        # Use yay with --needed so we don't redownload things pacstrap already installed (like 'base')
        sudo -u "$USERNAME" yay -S --needed --noconfirm \$ALL_PKGS
    else
        echo "[WARN] packages.json not found in /root/. Skipping modular install."
    fi

    # --- Services ---
    systemctl enable NetworkManager

    echo "==> Internal Configuration Complete."
EOF

# --- Step 6: Cleanup and Reboot ---
print_header "Step 6: Finalizing & Unmounting"
umount -R /mnt

log_info "Installation Complete!"
echo -e "${GREEN}You may now reboot into your new system.${NC}"
