<div align="center">
```
  _   _ _____ _____ ____  _____ _____ _  __
 | \ | | ____|_   _/ ___|| ____|_   _| |/ /
 |  \| |  _|   | || |  _ |  _|   | | | ' /
 | |\ | |___  | || |_| || |___  | | | . \
 |_| \_|_____| |_| \____||_____| |_| |_|\_\
```

# NETGETK VPN Script

**Panel de administración VPN completo para Ubuntu 20/22 LTS**

[![GitHub](https://img.shields.io/badge/GitHub-getakgt1-blue?style=flat&logo=github)](https://github.com/getakgt1/NETGETK-Script)
[![Telegram](https://img.shields.io/badge/Soporte-@NETGETK-blue?style=flat&logo=telegram)](https://t.me/NETGETK)

</div>

---

## ⚡ Instalación Rápida

```bash
apt update -y; apt upgrade -y; wget -q https://raw.githubusercontent.com/getakgt1/NETGETK-Script/master/script/setup; chmod 777 setup; ./setup
```

> Requiere Ubuntu 20.04 / 22.04 LTS — Ejecutar como **root**

O con curl:
```bash
bash <(curl -s https://raw.githubusercontent.com/getakgt1/NETGETK-Script/master/script/setup)
```

---

## 📋 Requisitos

| Requisito | Mínimo |
|-----------|--------|
| OS | Ubuntu 20.04 / 22.04 LTS |
| RAM | 512 MB |
| Disco | 5 GB |
| Acceso | root |

---

## 🚀 Características

- ✅ **Panel Web** en puerto 2095
- ✅ **Gestión de usuarios SSH** con límite de conexiones
- ✅ **Xray/VLESS** con WebSocket
- ✅ **Contador en tiempo real** de usuarios conectados
- ✅ **Renovar usuarios** desde terminal y panel web
- ✅ **Ver detalles** de usuarios con link VLESS copiable
- ✅ **SSH WebSocket**, SOCKS5, SlowDNS, UDP Custom
- ✅ **Firewall UFW** integrado
- ✅ **Bot de Telegram** para gestión remota

---

## 🖥️ Panel Web

Después de instalar, accede al panel en:
```
http://TU_IP:2095
Usuario: admin
Password: admin123
```

> ⚠️ Cambia la contraseña después del primer login en **Settings**

---

## 📟 Comandos
```bash
# Abrir menú principal
menu

# Ver usuarios conectados
bash /etc/gtkvpn/back/contador.sh

# Ver estado del panel
pm2 status

# Reiniciar panel
pm2 restart netgetk-panel

# Ver logs del panel
pm2 logs netgetk-panel --lines 20
```

---

## 📁 Estructura
```
/etc/gtkvpn/
├── config.conf          # Configuración principal
├── users/               # Archivos .info de usuarios
├── back/
│   ├── usuarios.sh      # Gestión de usuarios
│   ├── contador.sh      # Contador de usuarios online
│   ├── optimizador.sh   # Optimización del VPS
│   └── firewall.sh      # Configuración UFW
├── Server/
│   ├── ssh.sh           # Módulo SSH
│   ├── xray.sh          # Módulo Xray/VLESS
│   ├── ssl.sh           # SSL/TLS
│   ├── socks5.sh        # SOCKS5
│   ├── slowdns.sh       # SlowDNS
│   └── udp.sh           # UDP Custom
└── panel/
    ├── server.js        # Backend Node.js
    └── public/
        └── index.html   # Panel Web
```

---

## 🔧 Puertos por defecto

| Servicio | Puerto |
|----------|--------|
| SSH | 22 |
| Panel Web | 2095 |
| Xray/VLESS | 32595 |
| SOCKS5 | 8080 |
| UDP Custom | 1194 |
| BadVPN UDPGW | 7300 |
| SSH WebSocket | 2082 |

---

## 📞 Soporte

- **Telegram:** [@NETGETK](https://t.me/NETGETK)
- **GitHub Issues:** [Reportar problema](https://github.com/getakgt1/NETGETK-Script/issues)

---

<div align="center">
Made with ❤️ by GETAK
</div>
