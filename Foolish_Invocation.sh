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

# --- Configuration Variables ---
TARGET_DISK="${1:-/dev/nvme0n1}"
FORMAT_EFI="true"
GITHUB_RAW_URL="https://raw.githubusercontent.com/MichaelWard405/Foolish-Invocation/master/packages.json"

# --- Step 1: System Configuration Details ---
print_header "Step 1: System Credentials"

read -p "Enter desired username [default: archuser]: " INPUT_USER
USERNAME="${INPUT_USER:-archuser}"

# Loop to ensure passwords match and aren't empty
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

# --- Step 2: Verify Dependencies & Fetch JSON ---
print_header "Step 2: Environment & Config Retrieval"

if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null; then
  log_warn "Required tools missing. Installing jq and curl on live USB..."
  pacman -Sy --noconfirm jq curl || log_error "Failed to install dependencies."
fi

log_info "Fetching packages.json from GitHub (master branch)..."
curl -sL "$GITHUB_RAW_URL" -o "packages.json"

if [ ! -f "packages.json" ] || ! jq . "packages.json" >/dev/null 2>&1; then
  log_error "FATAL: Failed to download or parse packages.json from GitHub."
fi
log_info "Successfully loaded packages configuration."

# --- Step 3: Disk & Partition Discovery ---
print_header "Step 3: Disk & Partition Selection"
lsblk -dno NAME,SIZE,MODEL | grep -v "loop"
echo "----------------------------------------------------------------"
read -p "Enter target disk path (e.g., /dev/nvme0n1 or /dev/sda) [default: $TARGET_DISK]: " DISK_PATH
TARGET_DISK="${DISK_PATH:-$TARGET_DISK}"
echo "----------------------------------------------------------------"

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

# --- Step 4: Format & Mount Partitions ---
print_header "Step 4: Formatting & Mounting"

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

# --- Step 5: Bootstrap Base System ---
print_header "Step 5: Bootstrapping Base Arch System"

log_info "Running pacstrap..."
pacstrap -K /mnt base base-devel linux linux-firmware networkmanager git zsh jq curl

log_info "Generating fstab..."
genfstab -U /mnt >>/mnt/etc/fstab

# Pass the external packages file and credentials safely into chroot
cp packages.json /mnt/root/
echo "$USERNAME:$USER_PASSWORD" >/mnt/root/credentials.txt
echo "root:$USER_PASSWORD" >>/mnt/root/credentials.txt
chmod 600 /mnt/root/credentials.txt

# --- Step 6: System Configuration via arch-chroot ---
print_header "Step 6: Chroot Environment Configuration"

arch-chroot /mnt /bin/bash <<EOF
    set -e
    
    # --- Set System Locale and Hostname ---
    ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
    hwclock --systohc
    sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    locale-gen
    echo "LANG=en_US.UTF-8" > /etc/locale.conf
    
    # Custom Hostname
    echo "Foolish" > /etc/hostname
    
    # --- Create User & Apply Passwords ---
    useradd -m -G wheel -s /bin/zsh "$USERNAME"
    chpasswd < /root/credentials.txt
    rm /root/credentials.txt
    echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" >> /etc/sudoers

    # --- Pre-configure Zsh (Bypasses the wizard prompt) ---
    touch "/home/$USERNAME/.zshrc"
    chown "$USERNAME:$USERNAME" "/home/$USERNAME/.zshrc"

    # --- Bootloader (Grub) Setup ---
    pacman -S --noconfirm grub efibootmgr
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
    grub-mkconfig -o /boot/grub/grub.cfg

    # --- AUR Helper Setup (yay-bin) ---
    echo "==> Setting up AUR Helper (yay-bin)..."
    sudo -u "$USERNAME" bash -c "cd ~ && git clone https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si --noconfirm"

    # --- Install Packages from external JSON File ---
    PACKAGES_FILE="/root/packages.json"
    if [ -f "\$PACKAGES_FILE" ]; then
        echo "==> Installing packages from external GitHub JSON..."
        ALL_PKGS=\$(jq -r '.[]' "\$PACKAGES_FILE" | tr '\n' ' ')
        sudo -u "$USERNAME" yay -S --needed --noconfirm \$ALL_PKGS
    else
        echo "[WARN] packages.json missing from chroot environment root."
    fi

    # --- Explicitly ensure 'ly' display manager is present ---
    echo "==> Confirming login manager availability..."
    sudo -u "$USERNAME" yay -S --needed --noconfirm ly

    # --- Pre-configure Hyprland (Removes Warning Banner & Forces Wallpaper Blank) ---
    mkdir -p "/home/$USERNAME/.config/hypr"
    cat << 'EOF2' > "/home/$USERNAME/.config/hypr/hyprland.conf"
# Monitor Settings
monitor=,preferred,auto,auto

# Keybindings Variable
\$mainMod = SUPER

# Core Keybind Shortcuts
bind = \$mainMod, Q, exec, kitty
bind = \$mainMod, C, killactive,
bind = \$mainMod, M, exit,
bind = \$mainMod, R, exec, wofi --show drun

# Input configuration
input {
    kb_layout = us
    follow_mouse = 1
}

# Window borders & Gaps
general {
    gaps_in = 5
    gaps_out = 10
    border_size = 2
    col.active_border = rgba(33ccffee) rgba(00ff99ee) 45deg
    col.inactive_border = rgba(595959aa)
    layout = dwindle
}

# Window Styles
decoration {
    rounding = 10
    blur {
        enabled = true
        size = 3
        passes = 1
    }
}

# Window Layout Managers
dwindle {
    pseudotile = true
    preserve_split = true
}

# Completely turn off anime splash renders, logos, and default tiling backgrounds
misc {
    force_default_wallpaper = 0
    disable_hyprland_logo = true
    disable_splash_rendering = true
}
EOF2

    # Give your user complete ownership of their new configurations
    chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.config"

    # --- Services Activation (Updated for Templated Units) ---
    systemctl enable NetworkManager
    
    # Enable Ly on Virtual Terminal 2 and remove standard console login over it
    systemctl enable ly@tty2.service
    systemctl disable getty@tty2.service

    echo "==> Custom Arch Chroot Configuration Complete."
EOF

# --- Step 7: Cleanup and Reboot ---
print_header "Step 7: Finalizing & Unmounting"
rm -f packages.json
umount -R /mnt

log_info "Installation Complete!"
echo -e "${GREEN}You can now reboot your system directly into Ly controlling TTY2!${NC}"
