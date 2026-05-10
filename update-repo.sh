#!/bin/bash
# ============================================================
#   NETGETK - Actualizador de repositorio GitHub
#   Sincroniza los archivos activos del VPS al repo git
#   y hace push a GitHub.
#
#   Uso: bash update-repo.sh
#   Ejecutar desde: ~/NETGETK-Script
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="/etc/gtkvpn"

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${WHITE}       Actualizando repositorio NETGETK en GitHub${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Verificar que estamos en el repo correcto
if [[ ! -d "$REPO_DIR/.git" ]]; then
    echo -e "${RED}[!] No es un repositorio git. Ejecuta desde ~/NETGETK-Script${NC}"
    exit 1
fi

cd "$REPO_DIR"

# ── Paso 1: Copiar archivos activos al repo ───────────────────
echo -e "${CYAN}[1/4] Copiando archivos activos al repositorio...${NC}"

FILES_COPIED=0

copy_file() {
    local SRC="$1"
    local DST="$2"
    if [[ -f "$SRC" ]]; then
        cp "$SRC" "$DST" && \
        echo -e "  ${GREEN}✓${NC} $(basename $DST)" && \
        ((FILES_COPIED++))
    else
        echo -e "  ${YELLOW}~${NC} $(basename $DST) (no existe en $SRC)"
    fi
}

# Archivos del directorio activo -> repo
copy_file "$INSTALL_DIR/manager"              "$REPO_DIR/script/manager"
copy_file "$INSTALL_DIR/setup"                "$REPO_DIR/script/setup"
copy_file "$INSTALL_DIR/banner.sh"            "$REPO_DIR/script/banner.sh"
copy_file "$INSTALL_DIR/Server/vaydns.sh"     "$REPO_DIR/script/Server/vaydns.sh"
copy_file "$INSTALL_DIR/Server/hysteria.sh"   "$REPO_DIR/script/Server/hysteria.sh"
copy_file "$INSTALL_DIR/Server/ssh.sh"        "$REPO_DIR/script/Server/ssh.sh"
copy_file "$INSTALL_DIR/Server/ssl.sh"        "$REPO_DIR/script/Server/ssl.sh"
copy_file "$INSTALL_DIR/Server/udp.sh"        "$REPO_DIR/script/Server/udp.sh"
copy_file "$INSTALL_DIR/Server/slowdns.sh"    "$REPO_DIR/script/Server/slowdns.sh"
copy_file "$INSTALL_DIR/Server/socks5.sh"     "$REPO_DIR/script/Server/socks5.sh"
copy_file "$INSTALL_DIR/Server/xray.sh"       "$REPO_DIR/script/Server/xray.sh"
copy_file "$INSTALL_DIR/back/usuarios.sh"     "$REPO_DIR/script/back/usuarios.sh"
copy_file "$INSTALL_DIR/back/firewall.sh"     "$REPO_DIR/script/back/firewall.sh"
copy_file "$INSTALL_DIR/back/contador.sh"     "$REPO_DIR/script/back/contador.sh"
copy_file "$INSTALL_DIR/back/optimizador.sh"  "$REPO_DIR/script/back/optimizador.sh"
copy_file "$INSTALL_DIR/back/speedtest.sh"    "$REPO_DIR/script/back/speedtest.sh"

echo ""

# ── Paso 2: Verificar permisos de ejecucion ───────────────────
echo -e "${CYAN}[2/4] Verificando permisos...${NC}"
find "$REPO_DIR/script" -name "*.sh" -exec chmod +x {} \;
chmod +x "$REPO_DIR/script/manager" "$REPO_DIR/script/setup" 2>/dev/null
echo -e "  ${GREEN}✓ Permisos OK${NC}"
echo ""

# ── Paso 3: Ver cambios antes de commit ───────────────────────
echo -e "${CYAN}[3/4] Cambios detectados:${NC}"
git status --short
echo ""

# Si no hay cambios, salir
if git diff --quiet && git diff --cached --quiet && [[ -z "$(git ls-files --others --exclude-standard)" ]]; then
    echo -e "${YELLOW}[!] No hay cambios nuevos para subir${NC}"
    exit 0
fi

# ── Paso 4: Commit y push ─────────────────────────────────────
echo -e "${CYAN}[4/4] Subiendo a GitHub...${NC}"

# Mensaje de commit con fecha
COMMIT_MSG="update: sync VPS changes $(date '+%Y-%m-%d %H:%M')"
echo -ne " ${WHITE}Mensaje de commit [Enter para usar el automatico]: ${NC}"
read CUSTOM_MSG
[[ -n "$CUSTOM_MSG" ]] && COMMIT_MSG="$CUSTOM_MSG"

git add -A
git commit -m "$COMMIT_MSG"

if git push origin master; then
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✓ Repositorio actualizado correctamente${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e " ${WHITE}Archivos subidos:${NC} $FILES_COPIED"
    echo -e " ${WHITE}Commit:${NC} $COMMIT_MSG"
    echo -e " ${WHITE}Repo:${NC} $(git remote get-url origin)"
else
    echo -e "${RED}[!] Error al hacer push. Verifica tu token de GitHub${NC}"
    echo -e "${YELLOW}    git remote set-url origin https://TOKEN@github.com/getakgt1/NETGETK-Script.git${NC}"
fi
