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

#==========================
# Step 2 - Retrieval & GPU [4]
#==========================
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
