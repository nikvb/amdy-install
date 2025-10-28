# AMD Installer Repository

## 🎯 Overview

This repository contains installation scripts for AMD (Answering Machine Detection) system for Vicibox call centers. The AMD system automatically detects answering machines vs human callers to optimize call routing.

## 🚀 Quick Installation

### Method 1: Direct Installation (Recommended)
```bash
# For Vicibox 9-12 (Auto-detect OS)
bash <(curl -s -k https://download.amdy.io/installamd.sh)>

# For Vicibox 7-8 (Auto-detect OS)  
bash <(curl -s -k https://download.amdy.io/installamd8.sh)>

# For CentOS/Alma/Rocky
bash <(curl -s https://download.amdy.io/installamdcentos.sh)>

# For Vicibox 9-11 with Press 1 Option
bash <(curl -s -k https://download.amdy.io/installamdpress1.sh)>
```

### Method 2: Repository Installation
```bash
# Clone repository
git clone https://github.com/nikvb/amdy-install.git
cd amdy-install

# Use unified installer
sudo ./installamd-unified.sh

# Use Press 1 installer
sudo ./installamdpress1.sh
```

## 📁 Repository Structure

```
amdy-install/
├── README.md                    # This file
├── installamd-unified.sh        # 🌟 Unified installer (recommended)
├── installamdpress1.sh           # Press 1 installer for Vicibox 9-11
├── README.md                    # Detailed documentation
├── INTEGRATION.md               # Complete integration guide
├── test-installer.sh            # Test script for validation
├── installamd.sh                # Original Vicibox 9-12 script
├── installamd7.sh               # Original Vicibox 7 script
├── installamd8.sh               # Original Vicibox 8 script
├── installamd360.sh             # Original 360 version script
├── installamdcentos.sh           # Original CentOS script
├── installamddebian.sh            # Original Debian script
├── installamdubuntu.sh            # Original Ubuntu script
└── amdy.tar.gz                  # AMD package archive
```

## 🎯 Key Features

### Unified Installer (`installamd-unified.sh`)

#### ✅ Automatic Detection
- **OS Detection**: openSUSE, CentOS, Debian, Ubuntu
- **Vicibox Version**: 7-12 via system files
- **Package Manager**: zypper, yum, apt

#### 🐍 Python3/pip Installation
- **Vicibox 7**: Manual wheel installation for compatibility
- **Vicibox 8**: Remove/reinstall python3-pip, downgrade pip to 19.0.0
- **Vicibox 9-12**: Standard pip installation with latest versions

#### 📦 Package Management
- **Version-specific packages**: Different versions for each Vicibox release
- **Trusted hosts**: For Vicibox 8 compatibility
- **Fallback logic**: Advanced AMD with honeypot detection for newer versions

#### 🔧 Configuration
- **Basic AMD**: Vicibox 7 (simple answering machine detection)
- **Advanced AMD**: Vicibox 8-12 (with honeypot detection and fallback)
- **Extension 8370**: Automatically configured in Asterisk

### Press 1 Installer (`installamdpress1.sh`)

#### 🎮 Interactive Features
- **Interactive Mode**: Script stops and waits for user input
- **Press 1 Support**: Special handling for Vicibox 9-11
- **User Exit**: Press any button to exit AMD agent
- **Enhanced Logging**: Colored output with timestamps

## 🖥️ Supported Systems

### Operating Systems
| OS | Package Manager | Status |
|-----|----------------|---------|
| openSUSE Leap/Tumbleweed | zypper | ✅ Fully Supported |
| SLES | zypper | ✅ Fully Supported |
| CentOS/RHEL/Fedora | yum | ✅ Fully Supported |
| Ubuntu | apt | ✅ Fully Supported |
| Debian | apt | ✅ Fully Supported |

### Vicibox Versions
| Version | Python Packages | AMD Features | Status |
|---------|-----------------|---------------|---------|
| Vicibox 7 | Manual wheels | Basic AMD | ✅ Fully Supported |
| Vicibox 8 | Trusted-host install | Advanced AMD | ✅ Fully Supported |
| Vicibox 9-12 | Latest packages | Advanced AMD | ✅ Fully Supported |

## 📋 Installation Examples

### Basic Installation
```bash
# Clone repository
git clone https://github.com/nikvb/amdy-install.git
cd amdy-install

# Run unified installer
sudo ./installamd-unified.sh
```

### Advanced Usage
```bash
# Force specific Vicibox version
sudo ./installamd-unified.sh -v 8

# Force specific OS
sudo ./installamd-unified.sh -o centos

# Install 360 version
sudo ./installamd-unified.sh --360

# Use Press 1 installer
sudo ./installamdpress1.sh
```

## 🔧 Configuration

### AMD Agent Routing Options

1. **Enable AMD Routing**
   - Navigate to **Admin → Routing Options**
   - Enable **AMD Agent Routing Options**
   - Configure routing preferences

2. **Campaign Configuration**
   - Go to **Campaigns → [Your Campaign]**
   - Set **AMD Agent Route Options** to `HUMAN,HUMAN`
   - Save configuration

3. **Rebuild Servers**
   - Navigate to **Admin → Servers**
   - Click **Rebuild Telephony Servers Config**

### Extension Configuration

| Extension | Purpose | Configuration |
|-----------|---------|-------------|
| 8370 | AI AMD Extension | Set in campaign dial string |
| 8369 | Standard Extension | Fallback option |

## 📖 Documentation

### Detailed Documentation
- [`README.md`](README.md) - This file
- [`INTEGRATION.md`](INTEGRATION.md) - Complete integration guide

### Command Line Options
```bash
Usage: ./installamd-unified.sh [OPTIONS]

Options:
  -h, --help     Show help message
  -v, --version  Specify Vicibox version (7,8,9,10,11,12)
  -o, --os       Specify OS (opensuse,centos,debian,ubuntu)
  -3, --360      Install 360 version package

Examples:
  ./installamd-unified.sh                           # Auto-detect everything
  ./installamd-unified.sh -v 8                       # Force Vicibox 8
  ./installamd-unified.sh -o centos                  # Force CentOS
  ./installamd-unified.sh --360                      # Install 360 version
```

## 🚨 Troubleshooting

### Common Issues

1. **Permission Denied**
   ```bash
   sudo ./installamd-unified.sh
   ```

2. **Asterisk Not Found**
   ```bash
   # Ensure Asterisk is installed
   which asterisk
   ```

3. **Network Issues**
   ```bash
   # Check internet connectivity
   ping download.amdy.io
   ```

4. **Python Package Conflicts**
   ```bash
   # Use version override
   sudo ./installamd-unified.sh -v 8
   ```

### Verification
```bash
# Check AMD script
ls -la /var/lib/asterisk/agi-bin/amd.py

# Check Asterisk configuration
grep -A 10 "exten => 8370" /etc/asterisk/extensions.conf

# Test AMD functionality
asterisk -rx "core show hints"
```

## 🔄 Updates and Maintenance

### Checking for Updates
```bash
# Check for updates
cd /tmp
wget -q http://download.amdy.io/latest_version.txt
CURRENT_VERSION=$(cat /var/lib/asterisk/agi-bin/version.txt 2>/dev/null || echo "unknown")

if [ "$LATEST_VERSION" != "$CURRENT_VERSION" ]; then
    echo "Update available: $LATEST_VERSION"
    echo "Current version: $CURRENT_VERSION"
    
    # Update
    bash <(curl -s -k https://download.amdy.io/installamd.sh)
fi
```

## 📞 Support

For issues and questions:
1. Check troubleshooting section above
2. Review [INTEGRATION.md](INTEGRATION.md)
3. Run validation script
4. Submit GitHub issue with system details

## 🗺️ Changelog

### v1.0.0
- ✨ Consolidated 7 separate install scripts into unified installer
- 🔍 Added automatic OS and Vicibox version detection
- 🐍 Implemented version-specific Python package installation
- 🔧 Added comprehensive error handling and logging
- ✅ Created verification system
- 📖 Added complete documentation
- 🎮 Added Press 1 installer for Vicibox 9-11
- 🧪 Included test script for validation
- 📋 Created integration guide with examples

---

**🌟 Recommendation**: Use `installamd-unified.sh` for all new installations. It automatically detects your system and applies the appropriate configuration.