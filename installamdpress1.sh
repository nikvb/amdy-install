#!/bin/bash

# AMD Installation Script for Vicibox 9, 10, 11 with Press 1 Option
# This script installs AMD with interactive press-1 functionality

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
    exit 1
}

warning() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

info() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1${NC}"
}

# Function to detect OS
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
        OS_VERSION=$VERSION_ID
        DISTRO=$ID
    else
        error "Cannot detect operating system"
    fi
    
    log "Detected OS: $OS $OS_VERSION (Distro: $DISTRO)"
}

# Function to install Python3 and pip based on OS
install_python_pip() {
    log "Installing Python3 and pip for Vicibox 9-11..."
    
    case $DISTRO in
        opensuse-leap|opensuse-tumbleweed|sles)
            info "Using zypper package manager (openSUSE/SLES)"
            zypper in -y python3-pip
            pip3 install --upgrade pip
            ;;
        centos|rhel|fedora)
            info "Using yum package manager (CentOS/RHEL/Fedora)"
            yum -y install python3 python3-pip
            pip3 install --upgrade pip
            ;;
        ubuntu|debian)
            info "Using apt package manager (Ubuntu/Debian)"
            apt update
            apt install python3-pip -y
            pip3 install --upgrade pip
            ;;
        *)
            error "Unsupported operating system: $DISTRO"
            ;;
    esac
}

# Function to install Python packages for Vicibox 9-11
install_python_packages() {
    log "Installing Python packages for Vicibox 9-11 with Press 1 support..."
    
    pip3 install pyst2 websocket-client mysql-connector-python==8.0.29 configparser --upgrade
}

# Function to download and extract AMD package
download_amd_package() {
    log "Downloading AMD package for Vicibox 9-11..."
    
    # Remove existing archive
    rm -f amdy.tar.gz
    
    # Download standard package
    wget -N -O amdy.tar.gz http://download.amdy.io/amdy.tar.gz
    
    # Extract to agi-bin directory
    tar zxvf amdy.tar.gz --directory /var/lib/asterisk/agi-bin
    
    # Set executable permissions
    chmod a+x /var/lib/asterisk/agi-bin/amd.py
    log "AMD package installed and permissions set"
}

# Function to configure Asterisk extensions
configure_asterisk() {
    log "Configuring Asterisk extensions for Vicibox 9-11 with Press 1..."
    
    # Remove existing AMD extension
    sed -i 's/exten => 8370.*//g' /etc/asterisk/extensions.conf
    
    # Add new AMD extension with Press 1 support
    sed -i 's/exten => 8369,n,Hangup()/exten => 8369,n,Hangup()\n\n;AI AMD extension with Press 1\nexten => 8370,1,AGI(agi\:\/\/127.0.0.1\:4577\/call_log)\nexten => 8370,n,Playback(sip-silence)\nexten => 8370,n,EAGI(\/var\/lib\/asterisk\/agi\-bin\/amd.py)\nexten => 8370,n,GotoIf($\[\"${AMDSTATUS}\" = \"HONEYPOT\"]?honeypot)\nexten => 8370,n,GotoIf($\[\"${AMDCAUSE}\" = \"NETERR\" \| \"${AMDCAUSE}\" = \"INTERR\"\]?amd_fallback\:continue)\nexten => 8370,n(amd_fallback),AMD(2000,2000,1000,5000,120,50,4,256)\nexten => 8370,n(continue),AGI(VD_amd.agi,${EXTEN})\nexten => 8370,n,AGI(agi-VDAD_ALL_outbound.agi,NORMAL-----LB-----${CONNECTEDLINE(name)})\nexten => 8370,n(honeypot),Hangup()\n/g' /etc/asterisk/extensions.conf
    
    log "Asterisk extensions configured for Press 1 functionality"
}

# Function to reload Asterisk
reload_asterisk() {
    log "Reloading Asterisk configuration..."
    asterisk -rx "reload" || error "Failed to reload Asterisk"
    log "Asterisk reloaded successfully"
}

# Function to verify installation
verify_installation() {
    log "Verifying installation..."
    
    if [ ! -f /var/lib/asterisk/agi-bin/amd.py ]; then
        error "AMD script not found in /var/lib/asterisk/agi-bin/"
    fi
    
    if [ ! -x /var/lib/asterisk/agi-bin/amd.py ]; then
        error "AMD script is not executable"
    fi
    
    # Check if extension 8370 is configured
    if ! grep -q "exten => 8370" /etc/asterisk/extensions.conf; then
        error "Extension 8370 not found in Asterisk configuration"
    fi
    
    log "Installation verification completed successfully"
}

# Function to display usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -h, --help     Show this help message"
    echo ""
    echo "This script installs AMD for Vicibox 9, 10, 11 with Press 1 functionality"
    echo "The script should stop and wait for input after installation."
    echo ""
    echo "Installation is successful if there are no errors reported."
    echo "You can exit by pressing any button."
}

# Function to start AMD agent
start_amd_agent() {
    log "Starting AMD agent..."
    
    if [ -f /var/lib/asterisk/agi-bin/amd.py ]; then
        log "AMD agent is available at: /var/lib/asterisk/agi-bin/amd.py"
        log "The script should stop and wait for input."
        log "You can exit by pressing any button."
        
        # Start the AMD script in interactive mode
        cd /var/lib/asterisk/agi-bin
        python3 amd.py
    else
        error "AMD script not found. Installation may have failed."
    fi
}

# Main installation function
main() {
    log "Starting AMD installation for Vicibox 9-11 with Press 1..."
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                ;;
        esac
        shift
    done
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        error "This script must be run as root"
    fi
    
    # Check if Asterisk is installed
    if ! command -v asterisk &> /dev/null; then
        error "Asterisk is not installed or not in PATH"
    fi
    
    # Installation steps
    detect_os
    install_python_pip
    install_python_packages
    download_amd_package
    configure_asterisk
    reload_asterisk
    verify_installation
    
    log "AMD installation for Vicibox 9-11 completed successfully!"
    log "Extension 8370 is configured and ready to use"
    log ""
    log "Next steps:"
    log "1. Enable AMD agent Routing Options for campaign"
    log "2. Leave only HUMAN,HUMAN for AMD Agent Route Options"
    log "3. Access options through Campaign settings"
    log "4. Rebuild telephony servers config in Admin/Servers settings"
    log "5. In campaign set extension to 8370 to engage AI AMD"
    log "6. Possible to switch back to 8369 if needed"
    log ""
    log "Starting AMD agent..."
    start_amd_agent
}

# Run main function with all arguments
main "$@"