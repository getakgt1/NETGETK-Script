#!/bin/bash
# ================================================================
#   NETGETK - Preparar y subir a GitHub
#   Ejecutar DESPUÉS de install-admin.sh
#   Este script actualiza la URL del servidor en el setup
#   y sube todo al repositorio de GitHub
# ================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'

clear
echo -e "${CYAN}[NETGETK] Preparar GitHub${NC}"
echo ""

# ── Leer config instalada ─────────────────────────────────────
if [[ -f /opt/netgetk/config ]]; then
    source /opt/netgetk/config
    echo -e " ${GREEN}✓ Config cargada${NC}"
    echo -e "   License Server: ${CYAN}$LICENSE_SERVER_URL${NC}"
else
    echo -e "${YELLOW}[!] Ejecuta install-admin.sh primero${NC}"
    echo -ne " O ingresa la URL de tu servidor: "; read LICENSE_SERVER_URL
fi

echo ""

# ── Verificar que existe el directorio del proyecto ───────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETUP_FILE="$SCRIPT_DIR/script/setup"

if [[ ! -f "$SETUP_FILE" ]]; then
    echo -e "${RED}[!] No encuentro script/setup${NC}"
    echo -e "    Asegúrate de ejecutar desde la carpeta NETGETK/"
    exit 1
fi

# ── Actualizar URL en script/setup ────────────────────────────
echo -e "${CYAN}[1/4] Actualizando URL del servidor en script/setup...${NC}"
sed -i "s|LICENSE_SERVER=\".*\"|LICENSE_SERVER=\"$LICENSE_SERVER_URL\"|" "$SETUP_FILE"
echo -e " ${GREEN}✓ URL actualizada: $LICENSE_SERVER_URL${NC}"

# ── Verificar git ─────────────────────────────────────────────
if ! command -v git &>/dev/null; then
    apt install -y git -q 2>/dev/null
fi

# ── Configurar git si no está ─────────────────────────────────
if [[ -z "$(git config --global user.email)" ]]; then
    echo ""
    echo -e "${CYAN}[2/4] Configurar Git${NC}"
    echo -ne " ${WHITE}Tu nombre (ej. NETGETK): ${NC}"; read GIT_NAME
    echo -ne " ${WHITE}Tu email: ${NC}"; read GIT_EMAIL
    git config --global user.name "${GIT_NAME:-NETGETK}"
    git config --global user.email "${GIT_EMAIL:-admin@netgetk.com}"
fi

# ── Verificar GitHub CLI ───────────────────────────────────────
echo ""
echo -e "${CYAN}[3/4] Verificando GitHub CLI...${NC}"
if ! command -v gh &>/dev/null; then
    echo -e "  → Instalando GitHub CLI..."
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
        dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | \
        tee /etc/apt/sources.list.d/github-cli.list > /dev/null
    apt update -q 2>/dev/null && apt install -y gh 2>/dev/null
fi

# ── Login en GitHub ───────────────────────────────────────────
if ! gh auth status &>/dev/null; then
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE} Necesitas autenticarte en GitHub${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e " ${CYAN}Pasos:${NC}"
    echo -e "  1. Ve a ${WHITE}https://github.com/settings/tokens/new${NC}"
    echo -e "  2. Note: 'netgetk-deploy'"
    echo -e "  3. Expiration: No expiration"
    echo -e "  4. Marca: ✅ repo"
    echo -e "  5. Clic 'Generate token'"
    echo -e "  6. Copia el token (empieza con ghp_...)"
    echo ""
    echo -ne " ${WHITE}Pega tu GitHub Token: ${NC}"
    read GH_TOKEN
    echo "$GH_TOKEN" | gh auth login --with-token
fi

GH_USER=$(gh api user --jq '.login' 2>/dev/null)
echo -e " ${GREEN}✓ Conectado como: $GH_USER${NC}"

# ── Subir a GitHub ────────────────────────────────────────────
echo ""
echo -e "${CYAN}[4/4] Subiendo a GitHub...${NC}"

cd "$SCRIPT_DIR"

# Crear .gitignore
cat > .gitignore << 'GI'
node_modules/
*.env
data/
*.log
.DS_Store
GI

# Inicializar repo si no existe
if [[ ! -d .git ]]; then
    git init
    git add .
    git commit -m "NETGETK Script v1.0 - Initial commit"
    
    # Crear repo en GitHub y subir
    REPO_NAME="NETGETK-Script"
    echo -e " → Creando repositorio $GH_USER/$REPO_NAME en GitHub..."
    gh repo create "$REPO_NAME" --public --source=. --push
else
    git add .
    git commit -m "Update - $(date '+%Y-%m-%d %H:%M')"
    git push
fi

echo ""
RAW_BASE="https://raw.githubusercontent.com/$GH_USER/NETGETK-Script/main"
INSTALL_CMD="apt update -y && wget -q $RAW_BASE/script/setup && chmod +x setup && ./setup"

echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         ✓ SUBIDO A GITHUB EXITOSAMENTE                        ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  ${WHITE}Repo:${NC} ${CYAN}https://github.com/$GH_USER/NETGETK-Script${NC}"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  ${WHITE}Comando de instalación para clientes:${NC}"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  ${CYAN}$INSTALL_CMD${NC}"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e " ${YELLOW}Ahora en Telegram escribe /genkey para crear tu primera licencia${NC}"
echo ""
