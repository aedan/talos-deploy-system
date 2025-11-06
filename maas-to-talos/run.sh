#!/bin/bash
# Convenience wrapper for maas_to_inventory.py

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}MAAS to Inventory Converter${NC}"
echo "================================"
echo ""

# Check if Python 3 is installed
if ! command -v python3 &> /dev/null; then
    echo -e "${RED}Error: Python 3 is not installed${NC}"
    exit 1
fi

# Check if required Python packages are installed
python3 -c "import requests, yaml" 2>/dev/null
if [ $? -ne 0 ]; then
    echo -e "${YELLOW}Installing required Python packages...${NC}"
    pip3 install -r requirements.txt
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Failed to install dependencies${NC}"
        exit 1
    fi
fi

# Check if config file exists
if [ ! -f "maas_config.ini" ]; then
    echo -e "${YELLOW}Config file not found. Creating from example...${NC}"
    if [ -f "maas_config.ini.example" ]; then
        cp maas_config.ini.example maas_config.ini
        echo -e "${YELLOW}Please edit maas_config.ini with your MAAS credentials${NC}"
        exit 1
    else
        echo -e "${RED}Error: maas_config.ini.example not found${NC}"
        exit 1
    fi
fi

# Run the script
echo -e "${GREEN}Running inventory converter...${NC}"
python3 maas_to_inventory.py "$@"

if [ $? -eq 0 ]; then
    echo ""
    echo -e "${GREEN}✓ Inventory generation completed successfully${NC}"
else
    echo ""
    echo -e "${RED}✗ Error generating inventory${NC}"
    exit 1
fi
