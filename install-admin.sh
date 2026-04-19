#!/bin/bash
# ================================================================
#   NETGETK - Instalador del Sistema de Admin
#   Instala en TU VPS: servidor de licencias + bot de Telegram
#   Ejecutar como root en tu VPS principal
# ================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'

clear
echo -e "${CYAN}"
cat << 'LOGO'
  _   _ _____ _____ ____  _____ _____ _  __
 | \ | | ____|_   _/ ___|| ____|_   _| |/ /
 |  \| |  _|   | || |  _ |  _|   | | | ' /
 | |\  | |___  | || |_| || |___  | | | . \
 |_| \_|_____| |_| \____||_____| |_| |_|\_\
LOGO
echo -e "${WHITE}     SISTEMA DE ADMINISTRACIÓN - INSTALADOR${NC}"
echo -e "${CYAN}================================================================${NC}"
echo ""

[[ $EUID -ne 0 ]] && echo -e "${RED}[!] Ejecutar como root${NC}" && exit 1

# ── Obtener IP del VPS admin ───────────────────────────────────
MY_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
echo -e " ${WHITE}IP de este VPS:${NC} ${CYAN}$MY_IP${NC}"
echo ""

# ── Solicitar datos de configuración ──────────────────────────
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${WHITE} Necesito algunos datos para configurar el sistema:${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# 1. Token del bot de Telegram
echo -e "${WHITE}[1/4] TOKEN del Bot de Telegram${NC}"
echo -e "      ${CYAN}→ Ve a Telegram, busca @BotFather${NC}"
echo -e "      ${CYAN}→ Escribe /newbot, pon un nombre, obtendrás el token${NC}"
echo -e "      ${CYAN}→ Formato: 1234567890:ABCdefGHIjklMNO...${NC}"
echo ""
echo -ne " ${WHITE}Pega tu BOT TOKEN: ${NC}"
read BOT_TOKEN
if [[ -z "$BOT_TOKEN" ]]; then
    echo -e "${RED}[!] Token requerido${NC}"; exit 1
fi

echo ""

# 2. Telegram ID del admin
echo -e "${WHITE}[2/4] Tu TELEGRAM ID (número)${NC}"
echo -e "      ${CYAN}→ Ve a Telegram, busca @userinfobot${NC}"
echo -e "      ${CYAN}→ Escríbele /start${NC}"
echo -e "      ${CYAN}→ Te dirá tu ID: ej. 123456789${NC}"
echo ""
echo -ne " ${WHITE}Tu Telegram ID: ${NC}"
read ADMIN_ID
if [[ -z "$ADMIN_ID" ]]; then
    echo -e "${RED}[!] ID requerido${NC}"; exit 1
fi

echo ""

# 3. Token secreto de admin (lo inventa el usuario)
echo -e "${WHITE}[3/4] Token secreto de administración${NC}"
echo -e "      ${CYAN}→ Inventa una contraseña segura para proteger el servidor${NC}"
echo -e "      ${CYAN}→ Ej: MiClaveSecreta2024 (guárdala, no la pierdas)${NC}"
echo ""
echo -ne " ${WHITE}Token secreto (o Enter para generar uno): ${NC}"
read ADMIN_TOKEN
if [[ -z "$ADMIN_TOKEN" ]]; then
    ADMIN_TOKEN=$(openssl rand -hex 16)
    echo -e " ${GREEN}Token generado: ${CYAN}$ADMIN_TOKEN${NC}"
    echo -e " ${YELLOW}⚠️  Guárdalo en un lugar seguro${NC}"
fi

echo ""

# 4. Puerto del servidor de licencias
echo -e "${WHITE}[4/4] Puerto del servidor de licencias${NC}"
echo -e "      ${CYAN}→ Por defecto: 3000 (puedes cambiarlo)${NC}"
echo ""
echo -ne " ${WHITE}Puerto (Enter = 3000): ${NC}"
read LIC_PORT
[[ -z "$LIC_PORT" ]] && LIC_PORT=3000

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${WHITE} Configuración:${NC}"
echo -e "  Bot Token:    ${CYAN}${BOT_TOKEN:0:20}...${NC}"
echo -e "  Admin ID:     ${CYAN}$ADMIN_ID${NC}"
echo -e "  Admin Token:  ${CYAN}$ADMIN_TOKEN${NC}"
echo -e "  Puerto:       ${CYAN}$LIC_PORT${NC}"
echo -e "  URL servidor: ${CYAN}http://$MY_IP:$LIC_PORT${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -ne "${YELLOW}¿Continuar con esta configuración? (s/n): ${NC}"
read CONFIRM
[[ "$CONFIRM" != "s" && "$CONFIRM" != "S" ]] && echo "Cancelado." && exit 0

echo ""

# ── Instalar dependencias ──────────────────────────────────────
echo -e "${CYAN}[1/4] Instalando dependencias...${NC}"
apt update -y -qq 2>/dev/null
apt install -y -qq curl wget git ufw 2>/dev/null

# Node.js 18
if ! command -v node &>/dev/null; then
    echo -e "  → Instalando Node.js 18..."
    curl -fsSL https://deb.nodesource.com/setup_18.x | bash - 2>/dev/null
    apt install -y nodejs 2>/dev/null
fi
echo -e "  ${GREEN}✓ Node.js $(node -v)${NC}"

# PM2
if ! command -v pm2 &>/dev/null; then
    echo -e "  → Instalando PM2..."
    npm install -g pm2 -q 2>/dev/null
fi
echo -e "  ${GREEN}✓ PM2 instalado${NC}"

# ── Crear directorio del sistema ───────────────────────────────
echo -e "${CYAN}[2/4] Creando estructura...${NC}"
mkdir -p /opt/netgetk/{license-server/data,bot}

# ── Descargar archivos ─────────────────────────────────────────
REPO="https://raw.githubusercontent.com/NETGETK/NETGETK-Script/main"

echo -e "  → Descargando license-server..."
wget -q -O /opt/netgetk/license-server/server.js "$REPO/license-server/server.js" 2>/dev/null
wget -q -O /opt/netgetk/license-server/package.json "$REPO/license-server/package.json" 2>/dev/null

echo -e "  → Descargando bot..."
wget -q -O /opt/netgetk/bot/bot.js "$REPO/bot/bot.js" 2>/dev/null
wget -q -O /opt/netgetk/bot/package.json "$REPO/bot/package.json" 2>/dev/null

# Si el repo no existe aún, crear los archivos localmente
# (el ZIP ya los tiene, copiarlos si están en /tmp)
if [[ ! -s /opt/netgetk/license-server/server.js ]]; then
    echo -e "  ${YELLOW}→ Repo no disponible, usando archivos locales...${NC}"
    # El usuario debe tener los archivos del ZIP
    [[ -f /tmp/NETGETK/license-server/server.js ]] && \
        cp -r /tmp/NETGETK/license-server/* /opt/netgetk/license-server/
    [[ -f /tmp/NETGETK/bot/bot.js ]] && \
        cp -r /tmp/NETGETK/bot/* /opt/netgetk/bot/
fi

# ── Guardar configuración en .env ─────────────────────────────
cat > /opt/netgetk/license-server/.env << ENV
PORT=$LIC_PORT
ADMIN_TOKEN=$ADMIN_TOKEN
ENV

cat > /opt/netgetk/bot/.env << ENV
BOT_TOKEN=$BOT_TOKEN
ADMIN_IDS=$ADMIN_ID
LICENSE_SERVER=http://127.0.0.1:$LIC_PORT
ADMIN_TOKEN=$ADMIN_TOKEN
ENV

# Guardar config general
cat > /opt/netgetk/config << CFG
MY_IP=$MY_IP
LIC_PORT=$LIC_PORT
ADMIN_TOKEN=$ADMIN_TOKEN
ADMIN_ID=$ADMIN_ID
LICENSE_SERVER_URL=http://$MY_IP:$LIC_PORT
INSTALLED=$(date +%Y-%m-%d)
CFG

chmod 600 /opt/netgetk/config /opt/netgetk/license-server/.env /opt/netgetk/bot/.env

# ── Instalar dependencias npm ──────────────────────────────────
echo -e "${CYAN}[3/4] Instalando paquetes npm...${NC}"
cd /opt/netgetk/license-server && npm install --silent 2>/dev/null
echo -e "  ${GREEN}✓ License server listo${NC}"
cd /opt/netgetk/bot && npm install --silent 2>/dev/null
cd /etc/gtkvpn/panel && npm install --silent 2>/dev/null
echo -e "  ${GREEN}✓ Bot listo${NC}"

# ── Iniciar con PM2 ───────────────────────────────────────────
echo -e "${CYAN}[4/4] Iniciando servicios...${NC}"

# License Server
pm2 delete netgetk-license 2>/dev/null
cd /opt/netgetk/license-server
pm2 start server.js --name netgetk-license \
    --env production \
    --node-args "--env-file .env" 2>/dev/null || \
pm2 start server.js --name netgetk-license 2>/dev/null

sleep 2

# Verificar que inició
if pm2 list | grep -q "netgetk-license.*online"; then
    echo -e "  ${GREEN}✓ License Server corriendo en :$LIC_PORT${NC}"
else
    # Método alternativo con env
    PORT=$LIC_PORT ADMIN_TOKEN=$ADMIN_TOKEN pm2 start server.js \
        --name netgetk-license 2>/dev/null
    sleep 2
fi

# Bot de Telegram
pm2 delete netgetk-bot 2>/dev/null
cd /opt/netgetk/bot
BOT_TOKEN=$BOT_TOKEN ADMIN_IDS=$ADMIN_ID \
LICENSE_SERVER="http://127.0.0.1:$LIC_PORT" \
ADMIN_TOKEN=$ADMIN_TOKEN \
pm2 start bot.js --name netgetk-bot 2>/dev/null

sleep 3

pm2 save 2>/dev/null
pm2 startup 2>/dev/null | tail -1 | bash 2>/dev/null

# ── Abrir puerto en UFW ────────────────────────────────────────
ufw allow $LIC_PORT/tcp 2>/dev/null
ufw allow 22/tcp 2>/dev/null
ufw --force enable 2>/dev/null

# ── Guardar comando de instalación para clientes ───────────────
LICENSE_URL="http://$MY_IP:$LIC_PORT"

# Actualizar la URL en el setup del script
# (El usuario debe hacer esto en el archivo setup antes de subir a GitHub)

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           ✓ SISTEMA INSTALADO CORRECTAMENTE                   ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  ${WHITE}📡 License Server:${NC} ${CYAN}http://$MY_IP:$LIC_PORT${NC}"
echo -e "${GREEN}║${NC}  ${WHITE}🤖 Bot Telegram:${NC}   ${GREEN}Activo${NC}"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  ${YELLOW}⚠️  IMPORTANTE - Guarda esto:${NC}"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Admin Token: ${CYAN}$ADMIN_TOKEN${NC}"
echo -e "${GREEN}║${NC}  License URL: ${CYAN}http://$MY_IP:$LIC_PORT${NC}"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  ${WHITE}📝 Antes de subir a GitHub, edita script/setup:${NC}"
echo -e "${GREEN}║${NC}  ${CYAN}LICENSE_SERVER=\"http://$MY_IP:$LIC_PORT\"${NC}"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  ${WHITE}🤖 Prueba el bot en Telegram - escribe /stats${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ── Crear comando 'netgetk' ────────────────────────────────────
cat > /usr/local/bin/netgetk << 'CMD'
#!/bin/bash
echo ""
echo "⚡ NETGETK Admin"
echo ""
echo "  pm2 status              → ver servicios"
echo "  pm2 logs netgetk-bot    → logs del bot"
echo "  pm2 logs netgetk-license → logs del servidor"
echo "  pm2 restart netgetk-bot → reiniciar bot"
echo ""
source /opt/netgetk/config 2>/dev/null
echo "  License Server: http://$MY_IP:$LIC_PORT"
echo ""
pm2 list --no-color | grep netgetk
echo ""
CMD
chmod +x /usr/local/bin/netgetk

echo -e " ${CYAN}Usa el comando${NC} ${WHITE}netgetk${NC} ${CYAN}para ver el estado del sistema${NC}"
echo ""
