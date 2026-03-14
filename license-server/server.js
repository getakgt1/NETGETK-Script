// ================================================================
//   NETGETK License Server
//   Despliega en: Railway / Render / VPS propio
//   Puerto: 3000
// ================================================================

const express    = require('express');
const fs         = require('fs');
const path       = require('path');
const crypto     = require('crypto');
const bodyParser = require('body-parser');

const app  = express();
const PORT = process.env.PORT || 4000;

// ─── Base de datos simple en JSON ────────────────────────────
// En producción usa MongoDB o PostgreSQL
const DB_FILE = path.join(__dirname, 'data', 'licenses.json');
const LOG_FILE = path.join(__dirname, 'data', 'activity.log');

const ensureDB = () => {
    const dir = path.join(__dirname, 'data');
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    if (!fs.existsSync(DB_FILE)) fs.writeFileSync(DB_FILE, JSON.stringify({ licenses: [] }, null, 2));
    if (!fs.existsSync(LOG_FILE)) fs.writeFileSync(LOG_FILE, '');
};

const readDB = () => {
    ensureDB();
    return JSON.parse(fs.readFileSync(DB_FILE, 'utf8'));
};

const writeDB = (data) => {
    ensureDB();
    fs.writeFileSync(DB_FILE, JSON.stringify(data, null, 2));
};

const logActivity = (msg) => {
    const line = `[${new Date().toISOString()}] ${msg}\n`;
    fs.appendFileSync(LOG_FILE, line);
    console.log(msg);
};

// ─── Generar KEY única ────────────────────────────────────────
const generateKey = (prefix = 'NETGETK') => {
    const rand = crypto.randomBytes(12).toString('hex').toUpperCase();
    // Formato: NETGETK-XXXX-XXXX-XXXX-XXXX
    return `${prefix}-${rand.slice(0,4)}-${rand.slice(4,8)}-${rand.slice(8,12)}-${rand.slice(12,16)}`;
};

app.use(bodyParser.json());
app.use(bodyParser.urlencoded({ extended: true }));

// ─── Auth del admin ───────────────────────────────────────────
const ADMIN_TOKEN = process.env.ADMIN_TOKEN || 'netgetk-admin-secret-2024';
const requireAdmin = (req, res, next) => {
    const token = req.headers['x-admin-token'] || req.query.token;
    if (token !== ADMIN_TOKEN) return res.status(401).json({ error: 'No autorizado' });
    next();
};

// ================================================================
//   RUTAS PÚBLICAS (usadas por el script en el VPS)
// ================================================================

// POST /api/validate  → El script llama esto al instalar
app.post('/api/validate', (req, res) => {
    const { key, ip, action } = req.body;
    if (!key || !ip) return res.json({ status: 'error', message: 'Datos incompletos' });

    const db = readDB();
    const lic = db.licenses.find(l => l.key === key.toUpperCase().trim());

    if (!lic) {
        logActivity(`VALIDATE FAIL | KEY=${key} | IP=${ip} | motivo=no_existe`);
        return res.json({ status: 'error', message: 'Licencia no encontrada' });
    }

    if (!lic.active) {
        logActivity(`VALIDATE FAIL | KEY=${key} | IP=${ip} | motivo=desactivada`);
        return res.json({ status: 'error', message: 'Licencia desactivada' });
    }

    // Verificar expiración
    const today = new Date();
    const expiry = new Date(lic.expiry);
    if (expiry < today) {
        logActivity(`VALIDATE FAIL | KEY=${key} | IP=${ip} | motivo=expirada`);
        return res.json({ status: 'error', message: `Licencia expirada el ${lic.expiry}` });
    }

    // Verificar IP vinculada
    if (action === 'install') {
        if (lic.bound_ip && lic.bound_ip !== ip) {
            logActivity(`VALIDATE FAIL | KEY=${key} | IP=${ip} | motivo=ip_diferente | ip_original=${lic.bound_ip}`);
            return res.json({
                status: 'error',
                message: `Esta licencia está vinculada a la IP ${lic.bound_ip}. Contacta soporte para transferir.`
            });
        }
        // Vincular IP si es primera vez
        if (!lic.bound_ip) {
            lic.bound_ip = ip;
            lic.installed_at = new Date().toISOString();
        }
    }

    // Actualizar último acceso
    lic.last_seen = new Date().toISOString();
    lic.last_ip = ip;
    writeDB(db);

    logActivity(`VALIDATE OK | KEY=${key} | IP=${ip} | OWNER=${lic.owner} | ACTION=${action}`);

    res.json({
        status:  'ok',
        message: 'Licencia válida',
        owner:   lic.owner,
        expiry:  lic.expiry,
        type:    lic.type || 'standard'
    });
});

// POST /api/heartbeat  → Cron diario del script
app.post('/api/heartbeat', (req, res) => {
    const { key, ip } = req.body;
    if (!key || !ip) return res.json({ status: 'ok' });

    const db = readDB();
    const lic = db.licenses.find(l => l.key === key.toUpperCase().trim());
    if (!lic) return res.json({ status: 'revoked' });

    const today = new Date();
    const expiry = new Date(lic.expiry);
    if (expiry < today || !lic.active) return res.json({ status: 'revoked' });

    lic.last_seen = new Date().toISOString();
    writeDB(db);

    res.json({ status: 'ok', expiry: lic.expiry });
});

// ================================================================
//   RUTAS DE ADMIN (protegidas con token)
// ================================================================

// GET /admin/licenses → listar todas las licencias
app.get('/admin/licenses', requireAdmin, (req, res) => {
    const db = readDB();
    res.json(db.licenses);
});

// POST /admin/generate → crear nueva licencia
// Body: { owner, days, type, notes }
app.post('/admin/generate', requireAdmin, (req, res) => {
    const { owner, days = 30, type = 'standard', notes = '' } = req.body;
    if (!owner) return res.status(400).json({ error: 'owner requerido' });

    const key    = generateKey('NETGETK');
    const expiry = new Date();
    expiry.setDate(expiry.getDate() + parseInt(days));

    const license = {
        key,
        owner,
        type,
        notes,
        active:       true,
        bound_ip:     null,
        created_at:   new Date().toISOString(),
        expiry:       expiry.toISOString().split('T')[0],
        days:         parseInt(days),
        last_seen:    null,
        installed_at: null
    };

    const db = readDB();
    db.licenses.push(license);
    writeDB(db);

    logActivity(`KEY GENERADA | KEY=${key} | OWNER=${owner} | DÍAS=${days}`);
    res.json({ ok: true, key, expiry: license.expiry });
});

// POST /admin/revoke → desactivar licencia
app.post('/admin/revoke', requireAdmin, (req, res) => {
    const { key } = req.body;
    const db = readDB();
    const lic = db.licenses.find(l => l.key === key);
    if (!lic) return res.status(404).json({ error: 'No encontrada' });
    lic.active = false;
    writeDB(db);
    logActivity(`KEY REVOCADA | KEY=${key} | OWNER=${lic.owner}`);
    res.json({ ok: true });
});

// POST /admin/activate → reactivar licencia
app.post('/admin/activate', requireAdmin, (req, res) => {
    const { key } = req.body;
    const db = readDB();
    const lic = db.licenses.find(l => l.key === key);
    if (!lic) return res.status(404).json({ error: 'No encontrada' });
    lic.active = true;
    writeDB(db);
    res.json({ ok: true });
});

// POST /admin/transfer → cambiar IP vinculada (para reinstalaciones)
app.post('/admin/transfer', requireAdmin, (req, res) => {
    const { key, new_ip } = req.body;
    const db = readDB();
    const lic = db.licenses.find(l => l.key === key);
    if (!lic) return res.status(404).json({ error: 'No encontrada' });
    const old_ip = lic.bound_ip;
    lic.bound_ip = new_ip || null;
    writeDB(db);
    logActivity(`TRANSFER | KEY=${key} | ${old_ip} → ${new_ip}`);
    res.json({ ok: true });
});

// POST /admin/renew → extender días de una licencia
app.post('/admin/renew', requireAdmin, (req, res) => {
    const { key, days = 30 } = req.body;
    const db = readDB();
    const lic = db.licenses.find(l => l.key === key);
    if (!lic) return res.status(404).json({ error: 'No encontrada' });

    const base   = new Date(lic.expiry) > new Date() ? new Date(lic.expiry) : new Date();
    base.setDate(base.getDate() + parseInt(days));
    lic.expiry = base.toISOString().split('T')[0];
    writeDB(db);

    logActivity(`RENOVADA | KEY=${key} | nueva_expiry=${lic.expiry}`);
    res.json({ ok: true, expiry: lic.expiry });
});

// GET /admin/stats → estadísticas
app.get('/admin/stats', requireAdmin, (req, res) => {
    const db = readDB();
    const today = new Date().toISOString().split('T')[0];
    res.json({
        total:      db.licenses.length,
        active:     db.licenses.filter(l => l.active).length,
        installed:  db.licenses.filter(l => l.bound_ip).length,
        expired:    db.licenses.filter(l => l.expiry < today).length,
        revoked:    db.licenses.filter(l => !l.active).length,
    });
});

// GET /admin/log → ver log de actividad
app.get('/admin/log', requireAdmin, (req, res) => {
    ensureDB();
    const lines = fs.existsSync(LOG_FILE)
        ? fs.readFileSync(LOG_FILE, 'utf8').split('\n').filter(Boolean).slice(-100)
        : [];
    res.json(lines);
});

// ─── Health check ─────────────────────────────────────────────
app.get('/health', (req, res) => res.json({ status: 'ok', time: new Date().toISOString() }));

app.listen(PORT, () => {
    ensureDB();
    console.log(`NETGETK License Server corriendo en :${PORT}`);
    console.log(`Admin token: ${ADMIN_TOKEN}`);
});
