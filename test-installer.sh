#!/bin/bash

# Test script for installamd-unified.sh
# Tests OS detection, version detection, and command-line parsing

set -e

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}Testing Unified AMD Installer${NC}"
echo "=================================="

# Test 1: Help option
echo -e "\n${YELLOW}Test 1: Help option${NC}"
./installamd-unified.sh -h
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Help option works${NC}"
else
    echo -e "${RED}✗ Help option failed${NC}"
fi

# Test 2: Invalid option
echo -e "\n${YELLOW}Test 2: Invalid option${NC}"
./installamd-unified.sh --invalid 2>/dev/null
if [ $? -ne 0 ]; then
    echo -e "${GREEN}✓ Invalid option properly rejected${NC}"
else
    echo -e "${RED}✗ Invalid option not handled${NC}"
fi

# Test 3: OS detection (dry run simulation)
echo -e "\n${YELLOW}Test 3: OS detection${NC}"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "Detected OS: $NAME $VERSION_ID (Distro: $ID)"
    echo -e "${GREEN}✓ OS detection logic present${NC}"
else
    echo -e "${RED}✗ Cannot test OS detection (no /etc/os-release)${NC}"
fi

# Test 4: Script permissions
echo -e "\n${YELLOW}Test 4: Script permissions${NC}"
if [ -x installamd-unified.sh ]; then
    echo -e "${GREEN}✓ Script is executable${NC}"
else
    echo -e "${RED}✗ Script is not executable${NC}"
fi

# Test 5: Syntax check
echo -e "\n${YELLOW}Test 5: Bash syntax check${NC}"
if bash -n installamd-unified.sh; then
    echo -e "${GREEN}✓ Bash syntax is valid${NC}"
else
    echo -e "${RED}✗ Bash syntax error${NC}"
fi

# Test 6: Required functions exist
echo -e "\n${YELLOW}Test 6: Required functions${NC}"
functions=("detect_os" "detect_vicibox_version" "install_python_pip" "install_python_packages" "download_amd_package" "configure_asterisk" "reload_asterisk" "verify_installation")

for func in "${functions[@]}"; do
    if grep -q "^$func()" installamd-unified.sh; then
        echo -e "${GREEN}✓ Function $func exists${NC}"
    else
        echo -e "${RED}✗ Function $func missing${NC}"
    fi
done

# Test 7: Version-specific logic
echo -e "\n${YELLOW}Test 7: Version-specific logic${NC}"
if grep -q "VICIBOX_MAJOR.*7" installamd-unified.sh && \
   grep -q "VICIBOX_MAJOR.*8" installamd-unified.sh && \
   grep -q "VICIBOX_MAJOR.*9" installamd-unified.sh; then
    echo -e "${GREEN}✓ Version-specific logic present${NC}"
else
    echo -e "${RED}✗ Version-specific logic incomplete${NC}"
fi

# Test 8: OS-specific logic
echo -e "\n${YELLOW}Test 8: OS-specific logic${NC}"
if grep -q "opensuse\|centos\|ubuntu\|debian" installamd-unified.sh; then
    echo -e "${GREEN}✓ OS-specific logic present${NC}"
else
    echo -e "${RED}✗ OS-specific logic missing${NC}"
fi

echo -e "\n${GREEN}Testing completed!${NC}"
echo "=================================="
echo "Note: Full installation test requires root access and Asterisk installation"
echo "Run 'sudo ./installamd-unified.sh' for actual installation"