// ================================================================
//   NETGETK Telegram Bot - Gestión Remota de Licencias
//   Comandos: /genkey /listkeys /revoke /renew /transfer /stats
//   Instala: npm install node-telegram-bot-api axios
// ================================================================

const TelegramBot = require('node-telegram-bot-api');
const axios       = require('axios');

// ─── Configuración ────────────────────────────────────────────
const BOT_TOKEN='8667756036:AAFgmopK7LoP8ePCk_BLA_fCTYRJQrBOAkI';
const ADMIN_IDS = [1462182277];
const LICENSE_SERVER = 'http://127.0.0.1:3000';
const ADMIN_TOKEN = '4f43ba5e23d946791d096c068f2b7509';

const bot = new TelegramBot(BOT_TOKEN, { polling: true });
const api = axios.create({
    baseURL: LICENSE_SERVER,
    headers: { 'x-admin-token': ADMIN_TOKEN, 'Content-Type': 'application/json' }
});

// ─── Auth ─────────────────────────────────────────────────────
const isAdmin = (msg) => ADMIN_IDS.includes(msg.from.id);
const deny    = (msg) => bot.sendMessage(msg.chat.id, '⛔ Sin permisos de administrador.');

const fmt = (obj) => JSON.stringify(obj, null, 2);

// ─── Estado de sesión para conversaciones ─────────────────────
const sessions = {};

// ─── Helper: enviar con Markdown ──────────────────────────────
const send = (chatId, text, opts = {}) =>
    bot.sendMessage(chatId, text, { parse_mode: 'Markdown', ...opts });

// ================================================================
//   COMANDOS
// ================================================================

// /start
bot.onText(/\/start/, (msg) => {
    if (!isAdmin(msg)) return deny(msg);
    send(msg.chat.id, `
⚡ *NETGETK License Bot*

Comandos disponibles:

📋 *Licencias*
/genkey — Generar nueva KEY
/listkeys — Ver todas las licencias
/keyinfo \`KEY\` — Info de una key
/revoke \`KEY\` — Revocar licencia
/activate \`KEY\` — Reactivar licencia
/renew \`KEY\` \`días\` — Extender días
/transfer \`KEY\` \`nueva_ip\` — Cambiar IP vinculada

📊 *Sistema*
/stats — Estadísticas generales
/log — Ver últimos logs
/help — Esta ayuda
`);
});

// /help
bot.onText(/\/help/, (msg) => {
    bot.emit('text', msg);
});

// ─── /genkey ──────────────────────────────────────────────────
bot.onText(/\/genkey/, async (msg) => {
    if (!isAdmin(msg)) return deny(msg);
    const chatId = msg.chat.id;

    // Iniciar conversación guiada
    sessions[chatId] = { step: 'genkey_owner' };
    send(chatId, '🔑 *Generar nueva licencia*\n\n👤 ¿Para quién es? (nombre/usuario Telegram):');
});

// ─── /listkeys ────────────────────────────────────────────────
bot.onText(/\/listkeys/, async (msg) => {
    if (!isAdmin(msg)) return deny(msg);
    try {
        const { data } = await api.get('/admin/licenses');
        if (!data.length) return send(msg.chat.id, '📋 Sin licencias registradas.');

        const today = new Date().toISOString().split('T')[0];
        const lines = data.map((l, i) => {
            const expired  = l.expiry < today;
            const icon = !l.active ? '⛔' : expired ? '🔴' : l.bound_ip ? '🟢' : '🟡';
            return `${icon} \`${l.key}\`\n   👤 ${l.owner} | 📅 ${l.expiry} | 🌐 ${l.bound_ip || 'Sin vincular'}`;
        });

        // Enviar en chunks de 10
        const chunks = [];
        for (let i = 0; i < lines.length; i += 10)
            chunks.push(lines.slice(i, i + 10));

        for (const chunk of chunks) {
            await send(msg.chat.id, `📋 *Licencias (${data.length} total):*\n\n${chunk.join('\n\n')}`);
        }
    } catch (e) {
        send(msg.chat.id, `❌ Error: ${e.message}`);
    }
});

// ─── /keyinfo <KEY> ───────────────────────────────────────────
bot.onText(/\/keyinfo (.+)/, async (msg, match) => {
    if (!isAdmin(msg)) return deny(msg);
    const key = match[1].trim().toUpperCase();
    try {
        const { data } = await api.get('/admin/licenses');
        const lic = data.find(l => l.key === key);
        if (!lic) return send(msg.chat.id, `❌ KEY no encontrada: \`${key}\``);

        const today   = new Date().toISOString().split('T')[0];
        const expired = lic.expiry < today;
        const status  = !lic.active ? '⛔ Revocada' : expired ? '🔴 Expirada' : lic.bound_ip ? '🟢 Activa' : '🟡 Sin instalar';

        send(msg.chat.id, `
🔑 *Info de Licencia*

\`${lic.key}\`

👤 *Owner:* ${lic.owner}
📊 *Estado:* ${status}
📅 *Expira:* ${lic.expiry}
🌐 *IP VPS:* ${lic.bound_ip || 'No vinculada'}
📝 *Notas:* ${lic.notes || 'N/A'}
🗓 *Creada:* ${lic.created_at?.split('T')[0] || 'N/A'}
📡 *Instalada:* ${lic.installed_at?.split('T')[0] || 'No'}
👁 *Último ping:* ${lic.last_seen?.split('T')[0] || 'Nunca'}
`);
    } catch (e) {
        send(msg.chat.id, `❌ Error: ${e.message}`);
    }
});

// ─── /revoke <KEY> ────────────────────────────────────────────
bot.onText(/\/revoke (.+)/, async (msg, match) => {
    if (!isAdmin(msg)) return deny(msg);
    const key = match[1].trim().toUpperCase();
    try {
        await api.post('/admin/revoke', { key });
        send(msg.chat.id, `⛔ Licencia revocada:\n\`${key}\``);
    } catch (e) {
        send(msg.chat.id, `❌ Error: ${e.message}`);
    }
});

// ─── /activate <KEY> ──────────────────────────────────────────
bot.onText(/\/activate (.+)/, async (msg, match) => {
    if (!isAdmin(msg)) return deny(msg);
    const key = match[1].trim().toUpperCase();
    try {
        await api.post('/admin/activate', { key });
        send(msg.chat.id, `✅ Licencia activada:\n\`${key}\``);
    } catch (e) {
        send(msg.chat.id, `❌ Error: ${e.message}`);
    }
});

// ─── /renew <KEY> <días> ──────────────────────────────────────
bot.onText(/\/renew (.+) (\d+)/, async (msg, match) => {
    if (!isAdmin(msg)) return deny(msg);
    const key  = match[1].trim().toUpperCase();
    const days = parseInt(match[2]);
    try {
        const { data } = await api.post('/admin/renew', { key, days });
        send(msg.chat.id, `✅ Licencia renovada ${days} días:\n\`${key}\`\nNueva expiración: *${data.expiry}*`);
    } catch (e) {
        send(msg.chat.id, `❌ Error: ${e.message}`);
    }
});

// ─── /transfer <KEY> <nueva_ip> ───────────────────────────────
bot.onText(/\/transfer (.+) (.+)/, async (msg, match) => {
    if (!isAdmin(msg)) return deny(msg);
    const key    = match[1].trim().toUpperCase();
    const new_ip = match[2].trim();
    try {
        await api.post('/admin/transfer', { key, new_ip });
        send(msg.chat.id, `🔄 IP transferida:\n\`${key}\`\nNueva IP: \`${new_ip}\``);
    } catch (e) {
        send(msg.chat.id, `❌ Error: ${e.message}`);
    }
});

// ─── /stats ───────────────────────────────────────────────────
bot.onText(/\/stats/, async (msg) => {
    if (!isAdmin(msg)) return deny(msg);
    try {
        const { data } = await api.get('/admin/stats');
        send(msg.chat.id, `
📊 *Estadísticas NETGETK*

🔑 Total licencias: *${data.total}*
✅ Activas:         *${data.active}*
💻 Instaladas:      *${data.installed}*
🔴 Expiradas:       *${data.expired}*
⛔ Revocadas:       *${data.revoked}*
`);
    } catch (e) {
        send(msg.chat.id, `❌ Error: ${e.message}`);
    }
});

// ─── /log ─────────────────────────────────────────────────────
bot.onText(/\/log/, async (msg) => {
    if (!isAdmin(msg)) return deny(msg);
    try {
        const { data } = await api.get('/admin/log');
        const last20 = data.slice(-20).join('\n');
        send(msg.chat.id, `📋 *Últimos logs:*\n\`\`\`\n${last20 || 'Sin logs'}\n\`\`\``);
    } catch (e) {
        send(msg.chat.id, `❌ Error: ${e.message}`);
    }
});

// ================================================================
//   CONVERSACIONES GUIADAS (sesiones)
// ================================================================
bot.on('message', async (msg) => {
    const chatId  = msg.chat.id;
    const session = sessions[chatId];
    if (!session || msg.text?.startsWith('/')) return;

    // ── genkey: paso owner ──────────────────────────────────
    if (session.step === 'genkey_owner') {
        session.owner = msg.text.trim();
        session.step  = 'genkey_days';
        return send(chatId, `👤 Owner: *${session.owner}*\n\n📅 ¿Cuántos días de validez? (ej. 30):`, {
            reply_markup: {
                inline_keyboard: [
                    [{ text: '30 días', callback_data: 'days_30' },
                     { text: '60 días', callback_data: 'days_60' }],
                    [{ text: '90 días', callback_data: 'days_90' },
                     { text: '365 días', callback_data: 'days_365' }]
                ]
            }
        });
    }

    // ── genkey: paso días (texto) ───────────────────────────
    if (session.step === 'genkey_days') {
        const days = parseInt(msg.text);
        if (!days || days < 1) return send(chatId, '❌ Número inválido. Ingresa los días:');
        await createLicense(chatId, session.owner, days, 'standard');
        delete sessions[chatId];
    }
});

// ─── Callbacks de botones inline ─────────────────────────────
bot.on('callback_query', async (query) => {
    const chatId  = query.message.chat.id;
    const session = sessions[chatId];
    bot.answerCallbackQuery(query.id);

    if (query.data.startsWith('days_') && session?.step === 'genkey_days') {
        const days = parseInt(query.data.split('_')[1]);
        await createLicense(chatId, session.owner, days, 'standard');
        delete sessions[chatId];
    }
});

// ─── Crear licencia y enviar resultado ───────────────────────
async function createLicense(chatId, owner, days, type) {
    try {
        const { data } = await api.post('/admin/generate', { owner, days, type });

        // Calcular fecha de expiración legible
        const expDate = new Date(data.expiry).toLocaleDateString('es', {
            day: '2-digit', month: 'long', year: 'numeric'
        });

        // Comando de instalación para el usuario
        const installCmd = `apt update -y && wget -q https://raw.githubusercontent.com/getakgt1/NETGETK-Script/master/script/setup && chmod +x setup && ./setup`;

        await send(chatId, `
✅ *Licencia generada exitosamente*

━━━━━━━━━━━━━━━━━━━━━
🔑 *KEY:*
\`${data.key}\`
━━━━━━━━━━━━━━━━━━━━━
👤 *Para:* ${owner}
📅 *Válida hasta:* ${expDate}
⏱ *Días:* ${days}

📋 *Instrucciones para el usuario:*

1️⃣ Conectarse al VPS como root
2️⃣ Ejecutar:
\`\`\`
${installCmd}
\`\`\`
3️⃣ Ingresar la KEY cuando se solicite:
\`${data.key}\`
`);
    } catch (e) {
        send(chatId, `❌ Error generando licencia: ${e.message}`);
    }
}

// ─── Errores ──────────────────────────────────────────────────
bot.on('polling_error', (err) => console.error('Polling error:', err.message));

console.log('🤖 NETGETK Bot iniciado...');
console.log(`   Admins: ${ADMIN_IDS.join(', ')}`);
console.log(`   License Server: ${LICENSE_SERVER}`);
