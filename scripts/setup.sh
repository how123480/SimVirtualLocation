#!/bin/bash

# SkyWalker Setup Script
# This script installs all necessary dependencies for the SkyWalker app
# Created: 2026-03-21
#
# Target Versions:
# - uv: latest
# - Python: 3.13 (installed via uv)
# - pymobiledevice3: latest (installed via uv tool with Python 3.13)

# Set TERM environment variable if not set (needed for installer environment)
export TERM="${TERM:-dumb}"

# Detect if running in installer environment (non-interactive)
if [ ! -t 0 ] || [ -n "$INSTALLER_TEMP" ] || [ "$COMMAND_LINE_INSTALL" = "1" ]; then
    INSTALLER_MODE=1
    # In installer mode, don't exit on error for non-critical operations
    set +e
else
    INSTALLER_MODE=0
    set -e  # Exit on error in interactive mode
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$SCRIPT_DIR/SimVirtualLocation/.venv"

# Log file for installer mode
if [ "$INSTALLER_MODE" = "1" ]; then
    LOG_FILE="/tmp/skywalker-setup-$$.log"
    exec 1> >(tee -a "$LOG_FILE")
    exec 2>&1
    echo "Running in installer mode. Log: $LOG_FILE"
fi

# Print functions
print_header() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

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

# Check if Xcode Command Line Tools are installed
check_xcode_tools() {
    print_header "Checking Xcode Command Line Tools"
    
    if xcode-select -p &>/dev/null; then
        print_success "Xcode Command Line Tools are installed at: $(xcode-select -p)"
        return 0
    else
        print_warning "Xcode Command Line Tools are not installed"
        return 1
    fi
}

# Install Xcode Command Line Tools
install_xcode_tools() {
    print_header "Installing Xcode Command Line Tools"
    
    if [ "$INSTALLER_MODE" = "1" ]; then
        print_warning "Running in installer mode - skipping interactive Xcode Command Line Tools installation"
        print_info "Please install Xcode Command Line Tools manually by running: xcode-select --install"
        return 1
    fi
    
    print_info "This will open a dialog to install Xcode Command Line Tools"
    print_info "Please follow the installation wizard..."
    
    xcode-select --install
    
    print_info "Waiting for installation to complete..."
    print_warning "Please complete the installation dialog, then press Enter to continue"
    read -r
    
    if xcode-select -p &>/dev/null; then
        print_success "Xcode Command Line Tools installed successfully"
    else
        print_error "Xcode Command Line Tools installation failed"
        exit 1
    fi
}

# Check and install uv (modern Python package manager)
check_uv() {
    print_header "Checking uv (Python package manager)"
    
    if command_exists uv; then
        local uv_version=$(uv --version 2>&1)
        print_success "uv is installed: $uv_version"
        return 0
    else
        print_warning "uv is not installed"
        return 1
    fi
}

install_uv() {
    print_header "Installing uv"
    
    print_info "Installing uv (modern Python package manager)..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    
    # Add uv to PATH
    export PATH="$HOME/.local/bin:$PATH"
    
    if command_exists uv; then
        print_success "uv installed successfully"
    else
        print_error "uv installation failed"
        exit 1
    fi
}

# Check if Python 3.13 is installed via uv
check_python313() {
    print_header "Checking Python 3.13"
    
    if command_exists uv; then
        if uv python list 2>/dev/null | grep -q "3.13"; then
            print_success "Python 3.13 is available"
            return 0
        else
            print_warning "Python 3.13 is not installed"
            return 1
        fi
    else
        print_warning "uv not found, cannot check Python 3.13"
        return 1
    fi
}

# Install Python 3.13 via uv
install_python313() {
    print_header "Installing Python 3.13"
    
    print_info "Installing Python 3.13 via uv..."
    uv python install 3.13
    
    if uv python list 2>/dev/null | grep -q "3.13"; then
        print_success "Python 3.13 installed successfully"
        local python_info=$(uv python list 2>/dev/null | grep "3.13" | head -n 1)
        print_info "$python_info"
    else
        print_error "Failed to install Python 3.13"
        exit 1
    fi
}

# Check if pymobiledevice3 is installed
check_pymobiledevice3() {
    print_header "Checking pymobiledevice3"
    
    if command_exists pymobiledevice3 || [[ -f "$HOME/.local/bin/pymobiledevice3" ]]; then
        if uv tool list 2>/dev/null | grep -q "pymobiledevice3"; then
            local pmd3_info=$(uv tool list 2>/dev/null | grep -A 1 "pymobiledevice3" | head -n 1)
            local pmd3_version=$(echo "$pmd3_info" | sed 's/pymobiledevice3 v//' | sed 's/ .*//')
            print_success "pymobiledevice3 is installed: $pmd3_version"
        else
            print_success "pymobiledevice3 is installed"
        fi
        return 0
    else
        print_warning "pymobiledevice3 is not installed"
        return 1
    fi
}

# Install pymobiledevice3
install_pymobiledevice3() {
    print_header "Installing pymobiledevice3 with Python 3.13"
    
    # Check if already installed via uv tool
    if uv tool list 2>/dev/null | grep -q "pymobiledevice3"; then
        print_info "pymobiledevice3 is already installed, reinstalling with Python 3.13..."
        uv tool uninstall pymobiledevice3 2>/dev/null || true
    fi
    
    print_info "Installing pymobiledevice3 with Python 3.13..."
    # Install with specific Python version and force flag
    uv tool install --python 3.13 pymobiledevice3 --force
    
    # Verify installation
    if command_exists pymobiledevice3 || [[ -f "$HOME/.local/bin/pymobiledevice3" ]]; then
        print_success "pymobiledevice3 installed successfully with Python 3.13"
        local pmd3_location=$(which pymobiledevice3 2>/dev/null || echo "$HOME/.local/bin/pymobiledevice3")
        print_info "Location: $pmd3_location"
        
        # Verify Python version used
        if [[ -f "$HOME/.local/share/uv/tools/pymobiledevice3/bin/python" ]]; then
            local python_version=$($HOME/.local/share/uv/tools/pymobiledevice3/bin/python --version 2>&1)
            print_info "Python version: $python_version"
        fi
    else
        print_error "Failed to install pymobiledevice3"
        print_info "You may need to add ~/.local/bin to your PATH"
        exit 1
    fi
}

# Verify installations
verify_installations() {
    print_header "Verifying Installations"
    
    local all_good=true
    
    # Check uv
    if command_exists uv; then
        print_success "uv: $(uv --version 2>&1)"
    else
        print_error "uv not found"
        all_good=false
    fi
    
    # Check pymobiledevice3 (uv tool)
    if command_exists pymobiledevice3 || [[ -f "$HOME/.local/bin/pymobiledevice3" ]]; then
        local pmd3_version=$(uv tool list 2>/dev/null | grep -A 1 "pymobiledevice3" | head -n 1 | sed 's/pymobiledevice3 v//' || echo "unknown")
        print_success "pymobiledevice3: $pmd3_version"
        local pmd3_location=$(which pymobiledevice3 2>/dev/null || echo "$HOME/.local/bin/pymobiledevice3")
        print_success "Location: $pmd3_location"
        
        # Check Python version used by pymobiledevice3
        if [[ -f "$HOME/.local/share/uv/tools/pymobiledevice3/bin/python" ]]; then
            local python_version=$($HOME/.local/share/uv/tools/pymobiledevice3/bin/python --version 2>&1)
            print_success "Uses: $python_version"
        fi
    else
        print_error "pymobiledevice3 not found"
        all_good=false
    fi
    
    # Check Xcode Command Line Tools
    if xcode-select -p &>/dev/null; then
        print_success "Xcode Command Line Tools: $(xcode-select -p)"
    else
        print_warning "Xcode Command Line Tools not found"
        all_good=false
    fi
    
    echo ""
    if $all_good; then
        print_success "All required dependencies are installed!"
    else
        print_error "Some dependencies are missing or not properly installed"
        return 1
    fi
}

# Main installation flow
main() {
    # Clear screen only if in interactive mode and terminal supports it
    if [ "$INSTALLER_MODE" = "0" ] && [ -t 0 ] && command_exists clear; then
        clear
    fi
    
    echo ""
    print_header "SkyWalker Setup Script"
    echo ""
    
    if [ "$INSTALLER_MODE" = "1" ]; then
        print_info "Running in installer mode (non-interactive)"
    else
        print_info "Running in interactive mode"
    fi
    
    print_info "This script will install all necessary dependencies for SkyWalker"
    echo ""
    
    # Check and install uv
    if ! check_uv; then
        install_uv || {
            if [ "$INSTALLER_MODE" = "1" ]; then
                print_warning "Failed to install uv, but continuing..."
            else
                print_error "Failed to install uv"
                return 1
            fi
        }
    fi
    
    # Check and install Python 3.13
    if ! check_python313; then
        install_python313 || {
            if [ "$INSTALLER_MODE" = "1" ]; then
                print_warning "Failed to install Python 3.13, but continuing..."
            else
                print_error "Failed to install Python 3.13"
                return 1
            fi
        }
    fi
    
    # Check and install pymobiledevice3
    if ! check_pymobiledevice3; then
        install_pymobiledevice3 || {
            if [ "$INSTALLER_MODE" = "1" ]; then
                print_warning "Failed to install pymobiledevice3, but continuing..."
            else
                print_error "Failed to install pymobiledevice3"
                return 1
            fi
        }
    fi
    
    # Verify all installations
    echo ""
    if [ "$INSTALLER_MODE" = "1" ]; then
        verify_installations || true  # Don't fail in installer mode
        echo ""
        print_info "Setup complete. If dependencies are missing, you can run this script manually later."
        exit 0
    else
        verify_installations
    fi
}

# Run main function
main
