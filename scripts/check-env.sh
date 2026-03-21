#!/bin/bash

# SimVirtualLocation Environment Check Script
# This script checks if all necessary dependencies are installed
# Created: 2026-03-21
#
# Expected Versions:
# - uv: latest
# - pymobiledevice3: latest (installed via uv tool)

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$SCRIPT_DIR/SimVirtualLocation/.venv"

# Print functions
print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Counter for issues
issues_count=0

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  SimVirtualLocation Environment Check${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check Xcode Command Line Tools
echo -e "${BLUE}[1/2]${NC} Xcode Command Line Tools"
if xcode-select -p &>/dev/null; then
    print_success "Installed at: $(xcode-select -p)"
else
    print_error "Not installed"
    print_info "Run: xcode-select --install"
    ((issues_count++))
fi
echo ""

# Check uv
echo -e "${BLUE}[2/2]${NC} uv (Python package manager)"
if command_exists uv; then
    uv_version=$(uv --version 2>&1)
    print_success "$uv_version"
    uv_path=$(which uv)
    print_info "Location: $uv_path"
else
    print_error "Not installed"
    print_info "Run: curl -LsSf https://astral.sh/uv/install.sh | sh"
    ((issues_count++))
fi
echo ""

# Check pymobiledevice3 (uv tool)
echo -e "${BLUE}[3/3]${NC} pymobiledevice3 (uv tool)"
if command_exists pymobiledevice3 || [[ -f "$HOME/.local/bin/pymobiledevice3" ]]; then
    # Get version from uv tool list
    pmd3_info=$(uv tool list 2>/dev/null | grep -A 1 "pymobiledevice3" | head -n 1)
    if [[ -n "$pmd3_info" ]]; then
        pmd3_version=$(echo "$pmd3_info" | sed 's/pymobiledevice3 v//' | sed 's/ .*//')
        print_success "Installed: $pmd3_version"
    else
        print_success "Installed"
    fi
    
    pmd3_location=$(which pymobiledevice3 2>/dev/null || echo "$HOME/.local/bin/pymobiledevice3")
    print_info "Location: $pmd3_location"
else
    print_error "Not installed"
    print_info "Run: ./scripts/setup.sh to install it"
    ((issues_count++))
fi
echo ""

# Summary
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
if [[ $issues_count -eq 0 ]]; then
    echo -e "${GREEN}✓ All required dependencies are installed!${NC}"
    echo ""
    echo -e "${GREEN}SimVirtualLocation is ready to use.${NC}"
    echo ""
    echo -e "${BLUE}Next steps:${NC}"
    echo "  1. Open SimVirtualLocation.xcodeproj with Xcode"
    echo "  2. Build and run the application"
    echo ""
    echo -e "${BLUE}Optional (for iOS 17+ devices):${NC}"
    echo "  Run: ${YELLOW}sudo pymobiledevice3 remote start-tunnel${NC}"
    echo ""
    echo -e "${BLUE}Optional (for Android support):${NC}"
    echo "  Install Android Studio and configure ADB path in app settings"
    echo ""
    exit 0
else
    echo -e "${RED}✗ Found $issues_count issue(s)${NC}"
    echo ""
    echo -e "${YELLOW}To fix all issues automatically, run:${NC}"
    echo "  ${GREEN}./scripts/setup.sh${NC}"
    echo ""
    exit 1
fi
