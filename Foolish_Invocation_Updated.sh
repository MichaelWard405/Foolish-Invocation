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
