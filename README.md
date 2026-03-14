# ⚡ NETGETK VPN Script

Panel de administración VPN profesional con sistema de licencias.

## 📦 Instalación en VPS

```bash
apt update -y && wget -q https://raw.githubusercontent.com/NETGETK/NETGETK-Script/main/script/setup && chmod +x setup && ./setup
```

> El instalador solicitará una **LICENSE KEY** válida.
> Contacta **@NETGETK** en Telegram para obtener tu licencia.

## 🏗️ Estructura del Proyecto

```
NETGETK/
├── script/          ← Script que se instala en el VPS del cliente
│   ├── setup        ← Instalador principal (valida licencia)
│   ├── manager      ← Menú interactivo
│   ├── Server/      ← Módulos de protocolos
│   └── back/        ← Gestión de usuarios y sistema
│
├── license-server/  ← Servidor de licencias (despliega en Railway/Render)
│   ├── server.js
│   └── package.json
│
├── bot/             ← Bot de Telegram para gestión remota
│   ├── bot.js
│   └── package.json
│
└── panel/           ← Panel web (se instala en el VPS del cliente)
    ├── server.js
    └── public/
```

## 🚀 Despliegue del Sistema

### 1. Servidor de Licencias (Railway.app - GRATIS)

```bash
# Ir a https://railway.app
# New Project → Deploy from GitHub
# Selecciona la carpeta license-server/
# Variables de entorno:
#   ADMIN_TOKEN = tu_token_secreto_aqui
#   PORT = 3000
```

### 2. Bot de Telegram

```bash
# Obtener BOT_TOKEN: habla con @BotFather en Telegram
# Obtener tu TELEGRAM_ID: habla con @userinfobot

cd bot/
npm install
BOT_TOKEN=xxx ADMIN_IDS=123456789 LICENSE_SERVER=https://tu-app.railway.app node bot.js
```

### 3. Script en GitHub

Sube todo a tu repositorio GitHub público y el setup descargará los archivos automáticamente.

## 🤖 Comandos del Bot

| Comando | Descripción |
|---------|-------------|
| `/genkey` | Generar nueva licencia (conversación guiada) |
| `/listkeys` | Ver todas las licencias |
| `/keyinfo KEY` | Info detallada de una key |
| `/revoke KEY` | Revocar licencia |
| `/activate KEY` | Reactivar licencia |
| `/renew KEY días` | Extender validez |
| `/transfer KEY nueva_ip` | Cambiar IP vinculada |
| `/stats` | Estadísticas del sistema |
| `/log` | Ver logs de actividad |

## ⚙️ Variables de Entorno

### license-server
```
ADMIN_TOKEN = token_secreto_para_el_bot
PORT        = 3000
```

### bot
```
BOT_TOKEN       = token_de_@BotFather
ADMIN_IDS       = tu_id_telegram (separados por coma si hay varios)
LICENSE_SERVER  = https://tu-servidor.railway.app
ADMIN_TOKEN     = mismo_token_del_servidor
```

## 🔒 Sistema de Licencias

- Cada KEY se genera con un nombre de usuario y días de validez
- Al instalar el script, la KEY queda **vinculada a la IP del VPS**
- Si el cliente cambia de VPS, usa `/transfer KEY nueva_ip` en el bot
- El script hace **ping diario** al servidor para verificar validez
- Si la licencia se revoca, el cliente pierde acceso en 24h

## 📋 Protocolos incluidos

- ✅ OpenSSH + WebSocket
- ✅ Xray (VLESS + VMess + WebSocket)
- ✅ SOCKS5 Python
- ✅ SlowDNS
- ✅ UDP Custom + BadVPN-UDPgw
- ✅ Nginx + SSL/TLS
- ✅ Panel Web (puerto 2095)

## By: NETGETK | Telegram: @NETGETK
