#!/bin/bash

# Unified AMD Installation Script for Vicibox 7-12
# Supports openSUSE, CentOS, Debian, and Ubuntu
# Automatically detects OS and Vicibox version

set -e  # Exit on any error

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

# Function to detect Vicibox version
detect_vicibox_version() {
    if [ -f /etc/vicidial/version ]; then
        VICIBOX_VERSION=$(cat /etc/vicidial/version | grep -o '[0-9]\+\.[0-9]\+' | head -1)
        VICIBOX_MAJOR=$(echo $VICIBOX_VERSION | cut -d. -f1)
    elif [ -f /usr/src/astguiclient/VERSION ]; then
        VICIBOX_VERSION=$(cat /usr/src/astguiclient/VERSION | grep -o '[0-9]\+\.[0-9]\+' | head -1)
        VICIBOX_MAJOR=$(echo $VICIBOX_VERSION | cut -d. -f1)
    else
        warning "Cannot detect Vicibox version, assuming latest (9+)"
        VICIBOX_MAJOR=9
    fi
    
    log "Detected Vicibox version: $VICIBOX_VERSION (Major: $VICIBOX_MAJOR)"
}

# Function to install Python3 and pip based on OS
install_python_pip() {
    log "Installing Python3 and pip..."
    
    case $DISTRO in
        opensuse-leap|opensuse-tumbleweed|sles)
            info "Using zypper package manager (openSUSE/SLES)"
            if [ "$VICIBOX_MAJOR" -eq 8 ]; then
                # Vicibox 8 specific handling
                zypper remove -y python3-pip python3-setuptools 2>/dev/null || true
                zypper in -y python3-pip
                pip3 install --upgrade pip==19.0.0
            else
                # Vicibox 7, 9-12
                zypper in -y python3-pip
                pip3 install --upgrade pip
            fi
            ;;
        centos|rhel|fedora)
            info "Using yum package manager (CentOS/RHEL/Fedora)"
            yum -y install curl
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

# Function to install Python packages based on Vicibox version
install_python_packages() {
    log "Installing Python packages for Vicibox $VICIBOX_MAJOR..."
    
    case $VICIBOX_MAJOR in
        7)
            log "Installing packages for Vicibox 7 (manual wheel installation)..."
            
            # Download and install specific wheel versions
            wget --no-check-certificate https://files.pythonhosted.org/packages/d9/5a/e7c31adbe875f2abbb91bd84cf2dc52d792b5a01506781dbcf25c91daf11/six-1.16.0-py2.py3-none-any.whl
            pip3 install six-1.16.0-py2.py3-none-any.whl
            
            wget --no-check-certificate https://files.pythonhosted.org/packages/4a/9a/42c1a187a171807a6b214060544fbd6f4bf4a33bf1428aabaa46befed9dc/pyst2-0.5.1-py3-none-any.whl
            pip3 install pyst2-0.5.1-py3-none-any.whl
            
            wget --no-check-certificate https://files.pythonhosted.org/packages/4c/5f/f61b420143ed1c8dc69f9eaec5ff1ac36109d52c80de49d66e0c36c3dfdf/websocket_client-0.57.0-py2.py3-none-any.whl
            pip3 install websocket_client-0.57.0-py2.py3-none-any.whl
            ;;
            
        8)
            log "Installing packages for Vicibox 8 (specific versions with trusted hosts)..."
            
            pip3 --trusted-host pypi.org --trusted-host pypi.python.org --trusted-host files.pythonhosted.org install \
                pyst2 websocket-client==0.52.0 mysql-connector-python==8.0.5 configparser --upgrade
            ;;
            
        9|10|11|12)
            log "Installing packages for Vicibox $VICIBOX_MAJOR (latest versions)..."
            
            pip3 install pyst2 websocket-client mysql-connector-python==8.0.29 configparser --upgrade
            ;;
            
        *)
            log "Unknown Vicibox version, using default package installation..."
            pip3 install pyst2 websocket-client mysql-connector-python==8.0.29 configparser --upgrade
            ;;
    esac
}

# Function to download and extract AMD package
download_amd_package() {
    log "Downloading AMD package..."
    
    # Remove existing archive
    rm -f amdy*.tar.gz
    
    case $VICIBOX_MAJOR in
        8)
            wget -N -O amdy.tar.gz http://download.amdy.io/amdy8.tar.gz
            ;;
        *)
            # Check if this is a 360 version request
            if [ "$1" = "360" ]; then
                wget -N -O amdy360.tar.gz http://download.amdy.io/amdy360.tar.gz
                tar zxvf amdy360.tar.gz --directory /var/lib/asterisk/agi-bin
            else
                wget -N -O amdy.tar.gz http://download.amdy.io/amdy.tar.gz
                tar zxvf amdy.tar.gz --directory /var/lib/asterisk/agi-bin
            fi
            ;;
    esac
    
    # Set executable permissions
    chmod a+x /var/lib/asterisk/agi-bin/amd.py
    log "AMD package installed and permissions set"
}

# Function to configure Asterisk extensions
configure_asterisk() {
    log "Configuring Asterisk extensions..."
    
    # Remove existing AMD extension
    sed -i 's/exten => 8370.*//g' /etc/asterisk/extensions.conf
    
    case $VICIBOX_MAJOR in
        7)
            log "Configuring for Vicibox 7 (basic AMD)..."
            sed -i 's/exten => 8369,n,Hangup()/exten => 8369,n,Hangup()\n\n;AI AMD extension\nexten => 8370,1,AGI(agi\:\/\/127.0.0.1\:4577\/call_log)\nexten => 8370,n,Playback(sip-silence)\nexten => 8370,n,EAGI(\/var\/lib\/asterisk\/agi\-bin\/amd.py)\nexten => 8370,n,AGI(VD_amd.agi,${EXTEN})\nexten => 8370,n,AGI(agi-VDAD_ALL_outbound.agi,NORMAL-----LB-----${CONNECTEDLINE(name)})\nexten => 8370,n,Hangup()\n/g' /etc/asterisk/extensions.conf
            ;;
            
        *)
            log "Configuring for Vicibox $VICIBOX_MAJOR (advanced AMD with honeypot detection)..."
            sed -i 's/exten => 8369,n,Hangup()/exten => 8369,n,Hangup()\n\n;AI AMD extension\nexten => 8370,1,AGI(agi\:\/\/127.0.0.1\:4577\/call_log)\nexten => 8370,n,Playback(sip-silence)\nexten => 8370,n,EAGI(\/var\/lib\/asterisk\/agi\-bin\/amd.py)\nexten => 8370,n,GotoIf($\[\"${AMDSTATUS}\" = \"HONEYPOT\"]?honeypot)\nexten => 8370,n,GotoIf($\[\"${AMDCAUSE}\" = \"NETERR\" \| \"${AMDCAUSE}\" = \"INTERR\"\]?amd_fallback\:continue)\nexten => 8370,n(amd_fallback),AMD(2000,2000,1000,5000,120,50,4,256)\nexten => 8370,n(continue),AGI(VD_amd.agi,${EXTEN})\nexten => 8370,n,AGI(agi-VDAD_ALL_outbound.agi,NORMAL-----LB-----${CONNECTEDLINE(name)})\nexten => 8370,n(honeypot),Hangup()\n/g' /etc/asterisk/extensions.conf
            ;;
    esac
    
    log "Asterisk extensions configured"
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
    echo "  -v, --version  Specify Vicibox version (7,8,9,10,11,12)"
    echo "  -o, --os       Specify OS (opensuse,centos,debian,ubuntu)"
    echo "  -3, --360      Install 360 version package"
    echo ""
    echo "Examples:"
    echo "  $0                           # Auto-detect everything"
    echo "  $0 -v 8                       # Force Vicibox 8 installation"
    echo "  $0 -o centos                  # Force CentOS installation"
    echo "  $0 --360                      # Install 360 version"
}

# Main installation function
main() {
    log "Starting unified AMD installation..."
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                exit 0
                ;;
            -v|--version)
                VICIBOX_MAJOR_OVERRIDE="$2"
                shift 2
                ;;
            -o|--os)
                OS_OVERRIDE="$2"
                shift 2
                ;;
            -3|--360)
                INSTALL_360="true"
                shift
                ;;
            *)
                error "Unknown option: $1"
                ;;
        esac
    done
    
    # Detect OS and Vicibox version
    detect_os
    detect_vicibox_version
    
    # Apply overrides if specified
    if [ -n "$VICIBOX_MAJOR_OVERRIDE" ]; then
        VICIBOX_MAJOR="$VICIBOX_MAJOR_OVERRIDE"
        warning "Overriding Vicibox version to: $VICIBOX_MAJOR"
    fi
    
    if [ -n "$OS_OVERRIDE" ]; then
        DISTRO="$OS_OVERRIDE"
        warning "Overriding OS to: $DISTRO"
    fi
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        error "This script must be run as root"
    fi
    
    # Check if Asterisk is installed
    if ! command -v asterisk &> /dev/null; then
        error "Asterisk is not installed or not in PATH"
    fi
    
    # Installation steps
    install_python_pip
    install_python_packages
    download_amd_package "$INSTALL_360"
    configure_asterisk
    reload_asterisk
    verify_installation
    
    log "Unified AMD installation completed successfully!"
    log "AMD extension 8370 is now configured and ready to use"
}

# Run main function with all arguments
main "$@"