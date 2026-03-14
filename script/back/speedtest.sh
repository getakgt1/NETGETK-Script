#!/bin/bash
# ============================================================
#   GTKVPN - SpeedTest
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

press_enter() { echo -ne "\n${YELLOW}Presiona Enter para continuar...${NC}"; read; }

run_speedtest() {
    echo ""
    echo -e "${CYAN}[*] Ejecutando SpeedTest...${NC}"
    
    # Instalar speedtest si no existe
    if ! command -v speedtest &>/dev/null && ! command -v speedtest-cli &>/dev/null; then
        echo -e "${CYAN}  → Instalando speedtest-cli...${NC}"
        pip3 install speedtest-cli -q 2>/dev/null || \
        apt install -y speedtest-cli -q 2>/dev/null
    fi
    
    echo ""
    if command -v speedtest-cli &>/dev/null; then
        speedtest-cli --simple 2>/dev/null || speedtest-cli 2>/dev/null
    elif command -v speedtest &>/dev/null; then
        speedtest 2>/dev/null
    else
        # Speedtest manual con curl
        echo -e "${CYAN}[*] Test manual de velocidad...${NC}"
        echo ""
        
        echo -e " ${WHITE}↓ Download:${NC}"
        DL_SPEED=$(curl -o /dev/null --max-time 10 -s -w "%{speed_download}" \
            "http://speedtest.tele2.net/10MB.zip" 2>/dev/null)
        DL_MBPS=$(awk "BEGIN {printf \"%.2f\", $DL_SPEED/1024/1024*8}")
        echo -e "   ${GREEN}$DL_MBPS Mbps${NC}"
        
        echo -e " ${WHITE}↑ Upload:${NC}"
        UL_SPEED=$(dd if=/dev/zero bs=1M count=5 2>/dev/null | \
            curl -X POST --max-time 10 -s -w "%{speed_upload}" \
            --data-binary @- "http://httpbin.org/post" 2>/dev/null | tail -1)
        UL_MBPS=$(awk "BEGIN {printf \"%.2f\", ${UL_SPEED:-0}/1024/1024*8}")
        echo -e "   ${GREEN}$UL_MBPS Mbps${NC}"
        
        echo ""
        echo -e " ${WHITE}Ping:${NC}"
        ping -c 4 8.8.8.8 2>/dev/null | tail -1
    fi
    
    press_enter
}

run_speedtest
