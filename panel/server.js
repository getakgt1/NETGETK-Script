const express = require('express');
const { execSync, exec } = require('child_process');
const fs = require('fs');
const path = require('path');
const session = require('express-session');
const bodyParser = require('body-parser');

const app = express();
const PORT = 2095;
const CONFIG_FILE = '/etc/gtkvpn/config.conf';
const USERS_DIR = '/etc/gtkvpn/users';
const XRAY_CONFIG = '/usr/local/etc/xray/config.json';

// ── Middleware ────────────────────────────────────────────────
app.use(bodyParser.json());
app.use(bodyParser.urlencoded({ extended: true }));
app.use(express.static(path.join(__dirname, 'public')));
app.use(session({
    secret: 'gtkvpn-secret-2024',
    resave: false,
    saveUninitialized: false,
    cookie: { maxAge: 86400000 }
}));

// Credenciales del panel (cambiar en producción)
const PANEL_USER = process.env.PANEL_USER || 'admin';
const PANEL_PASS = process.env.PANEL_PASS || 'admin123';

// ── Auth middleware ───────────────────────────────────────────
const requireAuth = (req, res, next) => {
    if (req.session.authenticated) return next();
    res.status(401).json({ error: 'No autenticado' });
};

// ── Helpers ───────────────────────────────────────────────────
const run = (cmd, throwOnError = false) => {
    try { return execSync(cmd, { encoding: 'utf8', timeout: 10000, shell: '/bin/bash' }).trim(); }
    catch (e) {
        if (throwOnError) throw e;
        console.error(`[CMD ERROR] ${cmd}\n`, e.stderr || e.message);
        return '';
    }
};

const readConf = () => {
    try {
        const conf = {};
        if (!fs.existsSync(CONFIG_FILE)) return conf;
        fs.readFileSync(CONFIG_FILE, 'utf8').split('\n').forEach(line => {
            const [k, ...v] = line.split('=');
            if (k) conf[k.trim()] = v.join('=').trim();
        });
        return conf;
    } catch { return {}; }
};

const writeConf = (key, value) => {
    try {
        if (!fs.existsSync(CONFIG_FILE)) {
            fs.mkdirSync('/etc/gtkvpn', { recursive: true });
            fs.writeFileSync(CONFIG_FILE, '');
        }
        let content = fs.readFileSync(CONFIG_FILE, 'utf8');
        const regex = new RegExp(`^${key}=.*$`, 'm');
        if (regex.test(content)) {
            content = content.replace(regex, `${key}=${value}`);
        } else {
            content += `\n${key}=${value}`;
        }
        fs.writeFileSync(CONFIG_FILE, content);
    } catch (e) { console.error(e); }
};

const svcStatus = (name) => {
    const st = run(`systemctl is-active ${name} 2>/dev/null`);
    return st === 'active';
};

const portOpen = (port) => {
    if (!port || port === 'N/A') return false;
    const r = run(`ss -tlnp 2>/dev/null | grep ':${port} ' | head -1`);
    return r.length > 0;
};

// ── AUTH ──────────────────────────────────────────────────────
app.post('/api/login', (req, res) => {
    const { username, password } = req.body;
    if (username === PANEL_USER && password === PANEL_PASS) {
        req.session.authenticated = true;
        res.json({ ok: true });
    } else {
        res.status(401).json({ error: 'Credenciales incorrectas' });
    }
});

app.post('/api/logout', (req, res) => {
    req.session.destroy();
    res.json({ ok: true });
});

// ── OVERVIEW ──────────────────────────────────────────────────
app.get('/api/overview', requireAuth, (req, res) => {
    try {
        const conf = readConf();

        // CPU
        const cpuLine = run("top -bn1 | grep 'Cpu(s)'");
        const cpuMatch = cpuLine.match(/(\d+\.?\d*)\s*us/);
        const cpu = cpuMatch ? parseFloat(cpuMatch[1]) : 0;
        const cores = parseInt(run('nproc') || '1');

        // RAM
        const memInfo = run('free -b');
        const memLines = memInfo.split('\n');
        const memParts = memLines[1]?.split(/\s+/) || [];
        const ramTotal = parseInt(memParts[1] || 0);
        const ramUsed = parseInt(memParts[2] || 0);

        // Swap
        const swapParts = memLines[2]?.split(/\s+/) || [];
        const swapTotal = parseInt(swapParts[1] || 0);
        const swapUsed = parseInt(swapParts[2] || 0);

        // Disco
        const dfLine = run("df / | tail -1").split(/\s+/);
        const diskTotal = parseInt(dfLine[1] || 0) * 1024;
        const diskUsed = parseInt(dfLine[2] || 0) * 1024;

        // Uptime
        const uptimeRaw = run('cat /proc/uptime').split(' ')[0];
        const uptimeSec = parseInt(uptimeRaw || 0);
        const uptimeDays = Math.floor(uptimeSec / 86400);
        const uptimeHours = Math.floor((uptimeSec % 86400) / 3600);

        // Load
        const loadAvg = run('cat /proc/loadavg').split(' ').slice(0, 3).join(' | ');

        // IP
        const ip = run('curl -s --max-time 3 ifconfig.me 2>/dev/null || hostname -I | awk "{print $1}"');

        // Xray version
        const xrayVer = run('/usr/local/bin/xray version 2>/dev/null | head -1 | grep -oP "v[\\d.]+"');

        // OS
        const os = run('lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d"\\"" -f2');
        const kernel = run('uname -r');

        // Servicios
        const services = {
            ssh:      { active: svcStatus('ssh'),            port: conf.SSH_PORT || '22' },
            nginx:    { active: svcStatus('nginx'),          port: conf.NGINX_PORT || '80' },
            xray:     { active: svcStatus('xray'),           port: conf.XRAY_PORT || 'N/A' },
            socks5:   { active: svcStatus('socks5-gtkvpn'),  port: conf.SOCKS_PORT || 'N/A' },
            slowdns:  { active: svcStatus('slowdns'),        port: conf.SDNS_PORT || 'N/A' },
            udp:      { active: svcStatus('udp-custom'),     port: conf.UDP_PORT || 'N/A' },
            badvpn:   { active: svcStatus('badvpn-udpgw'),   port: conf.UDPGW_PORT || '7300' },
            fail2ban: { active: svcStatus('fail2ban'),       port: '-' },
            ufw:      { active: run('ufw status 2>/dev/null').includes('active'), port: '-' },
            sshws:    { active: svcStatus('ssh-ws'),         port: conf.SSH_WS_PORT || 'N/A' },
        };

        // Usuarios SSH activos reales (who + procesos sshd autenticados)
        const _sshWho   = parseInt(run('who 2>/dev/null | wc -l') || '0');
        const _sshProcs = parseInt(run('ps aux 2>/dev/null | grep "sshd:" | grep -v "grep\|sshd -D\|sshd -R" | wc -l') || '0');
        const sshActive = Math.max(_sshWho, _sshProcs);

        res.json({
            cpu, cores, ram: { total: ramTotal, used: ramUsed },
            swap: { total: swapTotal, used: swapUsed },
            disk: { total: diskTotal, used: diskUsed },
            uptime: { days: uptimeDays, hours: uptimeHours },
            loadAvg, ip, xrayVer, os, kernel,
            services, sshActive, conf
        });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

// ── SERVICIOS ─────────────────────────────────────────────────
app.post('/api/service/:name/:action', requireAuth, (req, res) => {
    const { name, action } = req.params;
    const allowed = ['ssh','nginx','xray','socks5-gtkvpn','slowdns','udp-custom','badvpn-udpgw','fail2ban','ssh-ws'];
    const actions = ['start','stop','restart'];
    if (!allowed.includes(name) || !actions.includes(action)) {
        return res.status(400).json({ error: 'No permitido' });
    }
    exec(`systemctl ${action} ${name}`, (err) => {
        setTimeout(() => {
            res.json({ ok: true, active: svcStatus(name) });
        }, 1000);
    });
});

// ── USUARIOS SSH ──────────────────────────────────────────────
app.get('/api/users', requireAuth, (req, res) => {
    try {
        const users = [];
        if (!fs.existsSync(USERS_DIR)) return res.json([]);
        
        fs.readdirSync(USERS_DIR).forEach(file => {
            if (!file.endsWith('.info')) return;
            const conf = {};
            fs.readFileSync(path.join(USERS_DIR, file), 'utf8')
                .split('\n').forEach(line => {
                    const [k, ...v] = line.split('=');
                    if (k) conf[k.trim()] = v.join('=').trim();
                });
            if (conf.USERNAME) {
                const today = new Date().toISOString().split('T')[0];
                conf.expired = conf.EXPIRY && conf.EXPIRY < today;

                // Detectar si está bloqueado
                const passwdStatus = run(`passwd -S ${conf.USERNAME} 2>/dev/null`);
                conf.blocked = passwdStatus.includes(' L ') || passwdStatus.includes(' LK ');

                // Detectar conexión: sesiones TTY (who) + procesos sshd del usuario
                const whoCount  = parseInt(run(`who 2>/dev/null | grep -c "^${conf.USERNAME} "`) || '0');
                const sshdCount = parseInt(run(`ps aux 2>/dev/null | grep "sshd: ${conf.USERNAME}" | grep -v grep | wc -l`) || '0');
                const dropbearCount = parseInt(run(`ss -tnp 2>/dev/null | grep ":2222" | grep "dropbear" | wc -l`) || '0');
                conf.connected  = (whoCount + sshdCount + dropbearCount) > 0;
                conf.connCount  = whoCount + Math.floor(sshdCount/2) + dropbearCount;
                users.push(conf);
            }
        });
        res.json(users);
    } catch (e) { res.status(500).json({ error: e.message }); }
});

app.post('/api/users/create', requireAuth, (req, res) => {
    const { username, password, days, type, xray_transport, xray_host, xray_path, xray_port } = req.body;
    if (!username || (!password && type !== 'xray')) return res.status(400).json({ error: 'Datos incompletos' });

    const expiry = new Date();
    expiry.setDate(expiry.getDate() + parseInt(days || 30));
    const expiryStr = expiry.toISOString().split('T')[0];

    try {
        if (type === 'xray') {
            if (!fs.existsSync(XRAY_CONFIG)) return res.status(400).json({ error: 'Xray no configurado' });

            const uuid      = run('uuidgen');
            const conf      = readConf();
            const ip        = run('curl -s --max-time 3 ifconfig.me 2>/dev/null || hostname -I | awk "{print $1}"');
            const transport = xray_transport || 'ws';
            const host      = (xray_host  || '').trim();
            const usePath   = (xray_path  || conf.XRAY_WS_PATH || '/').trim();
            const port      = (xray_port  || conf.XRAY_PORT    || '32595').toString();

            const config = JSON.parse(fs.readFileSync(XRAY_CONFIG, 'utf8'));

            // Buscar inbound con ese puerto o crear uno nuevo
            let target = null;
            for (const ib of config.inbounds || []) {
                if (ib.protocol === 'vless' && String(ib.port) === port) { target = ib; break; }
            }
            if (!target) {
                target = {
                    tag: `vless-${transport}-${port}`,
                    port: parseInt(port),
                    listen: '0.0.0.0',
                    protocol: 'vless',
                    settings: { clients: [], decryption: 'none' },
                    streamSettings: transport === 'splithttp'
                        ? { network: 'splithttp', splithttpSettings: { path: usePath, host } }
                        : { network: 'ws', wsSettings: { path: usePath, headers: {} } }
                };
                config.inbounds.push(target);
                run(`ufw allow ${port}/tcp 2>/dev/null`);
            } else if (transport === 'splithttp') {
                target.streamSettings = {
                    network: 'splithttp',
                    splithttpSettings: {
                        path: usePath,
                        host: host || target.streamSettings?.splithttpSettings?.host || ''
                    }
                };
            }

            target.settings.clients = target.settings.clients || [];
            // Asegurar que clientes existentes tengan email
            target.settings.clients = target.settings.clients.map((c, i) => ({
                ...c,
                flow: c.flow || '',
                email: c.email || `user${i}@gtkvpn`
            }));
            // Evitar duplicados
            const alreadyExists = target.settings.clients.some(c => c.email === `${username}@gtkvpn`);
            if (!alreadyExists) {
                target.settings.clients.push({ id: uuid, flow: '', email: `${username}@gtkvpn` });
            }

            fs.writeFileSync(XRAY_CONFIG, JSON.stringify(config, null, 2));
            run('systemctl restart xray');

            const ep   = encodeURIComponent(usePath);
            const eh   = encodeURIComponent(host);
            const link = transport === 'splithttp'
                ? `vless://${uuid}@${ip}:${port}?type=splithttp&encryption=none&path=${ep}&host=${eh}&security=none#${username}-GTKVPN`
                : `vless://${uuid}@${ip}:${port}?type=ws&encryption=none&path=${ep}&security=none#${username}-GTKVPN`;

            fs.mkdirSync(USERS_DIR, { recursive: true });
            fs.writeFileSync(path.join(USERS_DIR, `${username}_xray.info`),
                `USERNAME=${username}\nUUID=${uuid}\nTYPE=xray\nTRANSPORT=${transport}\nHOST=${host}\nPATH=${usePath}\nPORT=${port}\nCREATED=${new Date().toISOString().split('T')[0]}\nEXPIRY=${expiryStr}\n`);

            return res.json({ ok: true, uuid, link, transport, host, port });
        } else {
            // Crear usuario SSH
            const exists = run(`id ${username} 2>/dev/null`);
            if (exists) return res.status(400).json({ error: 'Usuario ya existe' });
            
            const addResult = run(`useradd -e ${expiryStr} -s /bin/false -M ${username} 2>&1`);
            if (addResult && addResult.includes('already exists')) {
                return res.status(400).json({ error: 'Usuario ya existe' });
            }
            // Usar printf para manejar contraseñas con caracteres especiales
            const safePw = password.replace(/'/g, "'\\''");
            run(`printf '%s:%s\\n' '${username}' '${safePw}' | chpasswd`);
            
            fs.mkdirSync(USERS_DIR, { recursive: true });
            fs.writeFileSync(path.join(USERS_DIR, `${username}.info`),
                `USERNAME=${username}\nPASSWORD=${password}\nTYPE=ssh\nCREATED=${new Date().toISOString().split('T')[0]}\nEXPIRY=${expiryStr}\nDIAS=${days || 30}\n`);
            
            return res.json({ ok: true });
        }
    } catch (e) { res.status(500).json({ error: e.message }); }
});

app.delete('/api/users/:username', requireAuth, (req, res) => {
    const { username } = req.params;
    try {
        run(`pkill -u ${username} 2>/dev/null`);
        run(`userdel ${username} 2>/dev/null`);
        ['', '_xray'].forEach(s => {
            const f = path.join(USERS_DIR, `${username}${s}.info`);
            if (fs.existsSync(f)) fs.unlinkSync(f);
        });
        // Remover de Xray config si es usuario xray
        if (fs.existsSync(XRAY_CONFIG)) {
            const config = JSON.parse(fs.readFileSync(XRAY_CONFIG, 'utf8'));
            for (const ib of config.inbounds || []) {
                if (ib.settings?.clients) {
                    ib.settings.clients = ib.settings.clients.filter(c => c.email !== `${username}@gtkvpn`);
                }
            }
            fs.writeFileSync(XRAY_CONFIG, JSON.stringify(config, null, 2));
            run('systemctl restart xray');
        }
        res.json({ ok: true });
    } catch (e) { res.status(500).json({ error: e.message }); }
});

app.post('/api/users/:username/toggle', requireAuth, (req, res) => {
    const { username } = req.params;
    try {
        const status = run(`passwd -S ${username} 2>/dev/null`);
        if (status.includes(' L ') || status.includes(' LK ')) {
            run(`passwd -u ${username}`);
            res.json({ ok: true, blocked: false });
        } else {
            run(`pkill -u ${username} 2>/dev/null`);
            run(`passwd -l ${username}`);
            res.json({ ok: true, blocked: true });
        }
    } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── CONFIGURACIÓN DE PROTOCOLOS ───────────────────────────────
app.get('/api/config', requireAuth, (req, res) => {
    try {
        const conf = readConf();
        let xrayInbounds = [];
        if (fs.existsSync(XRAY_CONFIG)) {
            const xray = JSON.parse(fs.readFileSync(XRAY_CONFIG, 'utf8'));
            xrayInbounds = xray.inbounds || [];
        }
        res.json({ conf, xrayInbounds });
    } catch (e) { res.status(500).json({ error: e.message }); }
});

app.post('/api/config/ssh', requireAuth, (req, res) => {
    const { port } = req.body;
    try {
        run(`sed -i 's/^#*Port .*/Port ${port}/' /etc/ssh/sshd_config`);
        run(`ufw allow ${port}/tcp 2>/dev/null`);
        run('systemctl restart ssh');
        writeConf('SSH_PORT', port);
        res.json({ ok: true });
    } catch (e) { res.status(500).json({ error: e.message }); }
});

app.post('/api/config/xray', requireAuth, (req, res) => {
    const { port, path: wsPath } = req.body;
    try {
        if (!fs.existsSync(XRAY_CONFIG)) return res.status(400).json({ error: 'Xray no instalado' });
        const config = JSON.parse(fs.readFileSync(XRAY_CONFIG, 'utf8'));
        for (const ib of config.inbounds || []) {
            if (ib.port && port) ib.port = parseInt(port);
            if (ib.streamSettings?.wsSettings && wsPath) {
                ib.streamSettings.wsSettings.path = wsPath;
            }
        }
        fs.writeFileSync(XRAY_CONFIG, JSON.stringify(config, null, 2));
        run(`ufw allow ${port}/tcp 2>/dev/null`);
        run('systemctl restart xray');
        writeConf('XRAY_PORT', port);
        if (wsPath) writeConf('XRAY_WS_PATH', wsPath);
        res.json({ ok: true });
    } catch (e) { res.status(500).json({ error: e.message }); }
});

app.get('/api/xray/config', requireAuth, (req, res) => {
    try {
        if (!fs.existsSync(XRAY_CONFIG)) return res.json({ config: null });
        const config = JSON.parse(fs.readFileSync(XRAY_CONFIG, 'utf8'));
        res.json({ config });
    } catch (e) { res.status(500).json({ error: e.message }); }
});


// ── HOSTS XRAY (lista guardada para el panel) ─────────────────
app.get('/api/xray/hosts', requireAuth, (req, res) => {
    try {
        const hostsFile = '/etc/gtkvpn/xray_hosts.json';
        if (!fs.existsSync(hostsFile)) return res.json({ hosts: [] });
        res.json({ hosts: JSON.parse(fs.readFileSync(hostsFile, 'utf8')) });
    } catch (e) { res.status(500).json({ error: e.message }); }
});

app.post('/api/xray/hosts', requireAuth, (req, res) => {
    try {
        const { host } = req.body;
        if (!host) return res.status(400).json({ error: 'Host requerido' });
        const hostsFile = '/etc/gtkvpn/xray_hosts.json';
        let hosts = [];
        if (fs.existsSync(hostsFile)) hosts = JSON.parse(fs.readFileSync(hostsFile, 'utf8'));
        if (!hosts.includes(host)) hosts.push(host);
        fs.writeFileSync(hostsFile, JSON.stringify(hosts));
        res.json({ ok: true, hosts });
    } catch (e) { res.status(500).json({ error: e.message }); }
});

app.delete('/api/xray/hosts/:host', requireAuth, (req, res) => {
    try {
        const hostsFile = '/etc/gtkvpn/xray_hosts.json';
        let hosts = [];
        if (fs.existsSync(hostsFile)) hosts = JSON.parse(fs.readFileSync(hostsFile, 'utf8'));
        hosts = hosts.filter(h => h !== decodeURIComponent(req.params.host));
        fs.writeFileSync(hostsFile, JSON.stringify(hosts));
        res.json({ ok: true, hosts });
    } catch (e) { res.status(500).json({ error: e.message }); }
});
// ── LOGS ──────────────────────────────────────────────────────
app.get('/api/logs/:service', requireAuth, (req, res) => {
    const { service } = req.params;
    const allowed = ['xray', 'ssh', 'nginx', 'socks5-gtkvpn', 'slowdns', 'udp-custom'];
    if (!allowed.includes(service)) return res.status(400).json({ error: 'No permitido' });
    try {
        const logs = run(`journalctl -u ${service} -n 50 --no-pager --output=short 2>/dev/null`);
        res.json({ logs });
    } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── PANEL SETTINGS ────────────────────────────────────────────
app.post('/api/settings/password', requireAuth, (req, res) => {
    const { newPassword } = req.body;
    if (!newPassword || newPassword.length < 6) return res.status(400).json({ error: 'Mínimo 6 caracteres' });
    // En producción guardar en archivo seguro
    process.env.PANEL_PASS = newPassword;
    res.json({ ok: true });
});


// ── VER DETALLES DE USUARIO ──────────────────────────────────
app.get('/api/users/:username/details', requireAuth, (req, res) => {
    const { username } = req.params;
    try {
        const conf = readConf();
        const ip = run('curl -s --max-time 3 ifconfig.me 2>/dev/null || hostname -I | awk "{print $1}"');

        // Buscar info SSH
        const infoSsh = path.join(USERS_DIR, `${username}.info`);
        if (fs.existsSync(infoSsh)) {
            const u = {};
            fs.readFileSync(infoSsh, 'utf8').split('\n').forEach(line => {
                const [k, ...v] = line.split('=');
                if (k) u[k.trim()] = v.join('=').trim();
            });
            return res.json({ type: 'ssh', data: u, ip });
        }

        // Buscar info Xray
        const infoXray = path.join(USERS_DIR, `${username}_xray.info`);
        if (fs.existsSync(infoXray)) {
            const u = {};
            fs.readFileSync(infoXray, 'utf8').split('\n').forEach(line => {
                const [k, ...v] = line.split('=');
                if (k) u[k.trim()] = v.join('=').trim();
            });
            const port      = u.PORT      || conf.XRAY_PORT    || '32595';
            const transport = u.TRANSPORT || 'ws';
            const userHost  = u.HOST      || '';
            const userPath  = encodeURIComponent(u.PATH || conf.XRAY_WS_PATH || '/');
            const link = transport === 'splithttp'
                ? `vless://${u.UUID}@${ip}:${port}?type=splithttp&encryption=none&path=${userPath}&host=${encodeURIComponent(userHost)}&security=none#${username}-GTKVPN`
                : `vless://${u.UUID}@${ip}:${port}?type=ws&encryption=none&path=${userPath}&security=none#${username}-GTKVPN`;
            return res.json({ type: 'xray', data: u, ip, link, port, transport, host: userHost });
        }

        res.status(404).json({ error: 'Usuario no encontrado' });
    } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── RENOVAR USUARIO ──────────────────────────────────────────
app.post('/api/users/:username/renew', requireAuth, (req, res) => {
    const { username } = req.params;
    const { days } = req.body;
    const d = parseInt(days);
    if (!d || d <= 0) return res.status(400).json({ error: 'Dias invalidos' });
    try {
        const infoFile = path.join(USERS_DIR, username + '.info');
        if (!fs.existsSync(infoFile))
            return res.status(404).json({ error: 'Usuario no encontrado' });

        // Leer datos actuales
        const uconf = {};
        fs.readFileSync(infoFile, 'utf8').split('\n').forEach(line => {
            const idx = line.indexOf('=');
            if (idx > 0) uconf[line.slice(0, idx).trim()] = line.slice(idx + 1).trim();
        });

        // Calcular nueva fecha desde hoy o desde expiración vigente
        const today = new Date(); today.setHours(0, 0, 0, 0);
        let base = new Date(today);
        if (uconf.EXPIRY) {
            const cur = new Date(uconf.EXPIRY); cur.setHours(0, 0, 0, 0);
            if (cur > today) base = cur;
        }
        base.setDate(base.getDate() + d);
        const yyyy = base.getFullYear();
        const mm   = String(base.getMonth() + 1).padStart(2, '0');
        const dd   = String(base.getDate()).padStart(2, '0');
        const newExpiry = yyyy + '-' + mm + '-' + dd;

        // Actualizar expiración en el sistema operativo
        const chageOut  = run('chage -E ' + newExpiry + ' ' + username + ' 2>&1');
        const usermodOut = run('usermod -e ' + newExpiry + ' ' + username + ' 2>&1');

        // Actualizar archivo .info
        uconf.EXPIRY = newExpiry;
        const newContent = Object.entries(uconf)
            .filter(([k]) => k)
            .map(([k, v]) => k + '=' + v)
            .join('\n') + '\n';
        fs.writeFileSync(infoFile, newContent);

        res.json({ ok: true, expiry: newExpiry });
    } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── LIMITE DE CONEXIONES ──────────────────────────────────────
app.post('/api/users/:username/limit', requireAuth, (req, res) => {
    const { username } = req.params;
    const { limit } = req.body;
    const lv = parseInt(limit);
    if (isNaN(lv) || lv < 0) return res.status(400).json({ error: 'Limite invalido' });
    try {
        const infoFile = path.join(USERS_DIR, username + '.info');
        if (!fs.existsSync(infoFile))
            return res.status(404).json({ error: 'Usuario no encontrado' });

        // Leer y actualizar archivo .info
        const uconf = {};
        fs.readFileSync(infoFile, 'utf8').split('\n').forEach(line => {
            const idx = line.indexOf('=');
            if (idx > 0) uconf[line.slice(0, idx).trim()] = line.slice(idx + 1).trim();
        });
        uconf.LIMIT = lv;
        const newContent = Object.entries(uconf)
            .filter(([k]) => k)
            .map(([k, v]) => k + '=' + v)
            .join('\n') + '\n';
        fs.writeFileSync(infoFile, newContent);

        // Aplicar limite via PAM
        const limitsFile = '/etc/security/limits.d/gtkvpn.conf';
        let lc = fs.existsSync(limitsFile) ? fs.readFileSync(limitsFile, 'utf8') : '';
        lc = lc.split('\n').filter(l => l && !l.startsWith(username + ' ')).join('\n');
        if (lv > 0) lc += '\n' + username + ' hard maxlogins ' + lv + '\n';
        fs.writeFileSync(limitsFile, lc);

        res.json({ ok: true, limit: lv });
    } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── INICIO ────────────────────────────────────────────────────
app.listen(PORT, '0.0.0.0', () => {
    console.log(`GTKVPN Panel corriendo en http://0.0.0.0:${PORT}`);
});
