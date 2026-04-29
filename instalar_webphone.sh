#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  WEBPHONE + SCREEN POP — MagnusBilling (Asterisk 13 chan_sip)   ║
# ║  Execute APÓS instalar o MagnusBilling:                         ║
# ║  sudo bash instalar_webphone.sh                                 ║
# ╚══════════════════════════════════════════════════════════════════╝
if [[ $EUID -ne 0 ]]; then exec sudo bash "$0" "$@"; fi
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

# ── Cores ──────────────────────────────────────────────────────────
G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' R='\033[0;31m' W='\033[1m' N='\033[0m'
ok()    { echo -e "${G}[✔]${N} $1"; }
info()  { echo -e "${C}[➜]${N} $1"; }
warn()  { echo -e "${Y}[⚠]${N} $1"; }
passo() { echo -e "\n${W}${Y}[$1]${N} $2"; }

SP_DIR="/opt/webphone"
WEB_DIR="/var/www/html/webphone"
SERVER_IP=$(hostname -I | awk '{print $1}')
AMI_SECRET="magnussolution"
AMI_PORT="5038"

# ── Pegar senha do banco do MagnusBilling ──────────────────────────
MB_DB_PASS=""
if [[ -f /root/passwordMysql.log ]]; then
  MB_DB_PASS=$(cat /root/passwordMysql.log | tr -d '[:space:]')
fi
if [[ -z "$MB_DB_PASS" ]]; then
  read -rsp "  🔑 Senha root do MySQL (gerada na instalação do Magnus): " MB_DB_PASS; echo
fi

# Pegar senha do usuário mbillingUser
MB_USER_PASS=$(mysql -uroot -p"${MB_DB_PASS}" -se "SELECT password FROM pkg_user WHERE username='admin' LIMIT 1" mbilling 2>/dev/null || echo "")

clear
echo -e "${C}${W}"
cat << 'BANNER'
  ╔══════════════════════════════════════════════════════════════╗
  ║   WEBPHONE + SCREEN POP — MagnusBilling                     ║
  ║   Asterisk 13 + chan_sip + WebSocket + JsSIP                 ║
  ╚══════════════════════════════════════════════════════════════╝
BANNER
echo -e "${N}  IP: ${Y}${SERVER_IP}${N}"
echo -e "  MagnusBilling detectado: ${G}✔${N}\n"

# ══════════════════════════════════════════════════════════════════
# ETAPA 1 — Instalar dependências
# ══════════════════════════════════════════════════════════════════
passo "1" "Instalando dependências..."

# Node.js 20
if ! node -v 2>/dev/null | grep -q "v20"; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >> /dev/null 2>&1
  apt-get install -y -qq nodejs >> /dev/null 2>&1
fi
ok "Node.js $(node -v)"

npm install -g pm2 --silent >> /dev/null 2>&1
ok "PM2 instalado"

# ══════════════════════════════════════════════════════════════════
# ETAPA 2 — Configurar Asterisk 13 para WebSocket
# ══════════════════════════════════════════════════════════════════
passo "2" "Configurando WebSocket no Asterisk 13..."

# http.conf — habilitar WebSocket
cat > /etc/asterisk/http.conf << 'EOF'
[general]
enabled=yes
bindaddr=0.0.0.0
bindport=8088
tlsenable=yes
tlsbindaddr=0.0.0.0:8089
tlscertfile=/etc/asterisk/keys/asterisk.pem
tlsprivatekey=/etc/asterisk/keys/asterisk.pem
enablestatic=yes
EOF

# Gerar certificado SSL autoassinado
mkdir -p /etc/asterisk/keys
openssl req -new -x509 -days 3650 -nodes \
  -out /etc/asterisk/keys/asterisk.pem \
  -keyout /etc/asterisk/keys/asterisk.pem \
  -subj "/C=BR/ST=SP/L=SaoPaulo/O=MagnusBilling/CN=${SERVER_IP}" \
  >> /dev/null 2>&1
chown asterisk:asterisk /etc/asterisk/keys/asterisk.pem
chmod 600 /etc/asterisk/keys/asterisk.pem
ok "Certificado SSL gerado"

# Adicionar WebSocket ao sip.conf do MagnusBilling
# Verificar se já tem configuração ws
if ! grep -q "transport=ws" /etc/asterisk/sip.conf 2>/dev/null; then
  # Adicionar transporte WebSocket e desabilitar verificação TLS para desenvolvimento
  sed -i '/^\[general\]/a transport=udp,ws,wss\nallow_reload=yes\ntlscertfile=/etc/asterisk/keys/asterisk.pem\ntlsprivatekey=/etc/asterisk/keys/asterisk.pem\ntlsdontverifyserver=yes\ntlscipher=ALL\nvideosupport=no' /etc/asterisk/sip.conf
fi

# Habilitar módulos necessários no modules.conf
for mod in res_http_websocket res_srtp; do
  if grep -q "noload.*${mod}" /etc/asterisk/modules.conf 2>/dev/null; then
    sed -i "s/noload.*${mod}/load = ${mod}.so/" /etc/asterisk/modules.conf
  fi
done

ok "Asterisk configurado para WebSocket"

# Reiniciar Asterisk
asterisk -rx "module reload res_http_websocket.so" >> /dev/null 2>&1 || true
service asterisk restart
sleep 3
ok "Asterisk reiniciado"

# ══════════════════════════════════════════════════════════════════
# ETAPA 3 — Backend Node.js (Screen Pop + API)
# ══════════════════════════════════════════════════════════════════
passo "3" "Criando backend Screen Pop..."
mkdir -p "${SP_DIR}"

cat > "${SP_DIR}/package.json" << 'EOF'
{"name":"webphone-screenpop","version":"1.0.0","main":"server.js"}
EOF

cd "${SP_DIR}"
npm install express ws asterisk-manager mysql2 cors --save --silent >> /dev/null 2>&1
ok "Dependências Node.js instaladas"

# Pegar senha do mbillingUser do arquivo de config do Magnus
MB_BILLING_PASS=$(grep -r "password" /var/www/html/mbilling/protected/config/main.php 2>/dev/null | grep -v "//" | grep "'" | head -1 | sed "s/.*'\(.*\)'.*/\1/" || echo "")

cat > "${SP_DIR}/.env" << EOENV
AMI_HOST=127.0.0.1
AMI_PORT=${AMI_PORT}
AMI_USER=admin
AMI_PASS=${AMI_SECRET}
DB_HOST=localhost
DB_USER=mbillingUser
DB_PASS=${MB_BILLING_PASS}
DB_NAME=mbilling
SERVER_IP=${SERVER_IP}
PORT=4000
EOENV
chmod 600 "${SP_DIR}/.env"

cat > "${SP_DIR}/server.js" << 'EOSRV'
require('dotenv').config();
const express     = require('express');
const http        = require('http');
const WebSocket   = require('ws');
const Ami         = require('asterisk-manager');
const mysql       = require('mysql2/promise');
const cors        = require('cors');
const path        = require('path');

const app    = express();
const server = http.createServer(app);
const wss    = new WebSocket.Server({ server });
app.use(cors());
app.use(express.json());

// ── Pool MySQL (banco do MagnusBilling) ───────────────────────────
const pool = mysql.createPool({
  host:            process.env.DB_HOST,
  user:            process.env.DB_USER,
  password:        process.env.DB_PASS,
  database:        process.env.DB_NAME,
  connectionLimit: 10
});
pool.query('SELECT 1').then(()=>console.log('✔ MySQL MagnusBilling OK')).catch(e=>console.warn('⚠ MySQL:',e.message));

// ── AMI ───────────────────────────────────────────────────────────
const ami = new Ami(process.env.AMI_PORT, process.env.AMI_HOST,
  process.env.AMI_USER, process.env.AMI_PASS, true);
ami.keepConnected();
ami.on('error', e=>console.error('[AMI]',e.message));
ami.on('connect', ()=>console.log('✔ AMI Asterisk conectado'));

// ── Mapa ramal → websocket ────────────────────────────────────────
const agenteSockets = new Map();
const pendingPops   = new Map(); // uniqueid → dados

// ── WebSocket ─────────────────────────────────────────────────────
wss.on('connection', ws => {
  let ramal = null;
  ws.on('message', msg => {
    try {
      const d = JSON.parse(msg);
      if (d.type === 'registrar') {
        ramal = String(d.ramal);
        agenteSockets.set(ramal, ws);
        console.log(`[WS] Agente ${ramal} conectado`);
        ws.send(JSON.stringify({ type:'ok', ramal }));
      }
    } catch(e) {}
  });
  ws.on('close', ()=>{ if(ramal) agenteSockets.delete(ramal); });
});

// ── Buscar lead pelo telefone ─────────────────────────────────────
async function buscarLead(telefone) {
  if (!telefone) return null;
  const tel = telefone.replace(/\D/g,'');

  // 1. Tabela de leads customizada (nossa)
  try {
    const [r] = await pool.query(
      `SELECT nome, telefone, cpf, estado FROM leads
       WHERE REPLACE(telefone,'+','') LIKE ? LIMIT 1`,
      [`%${tel.slice(-9)}`]);
    if (r.length) return { ...r[0], fonte:'leads' };
  } catch(e) {}

  // 2. Usuários do MagnusBilling (pkg_user)
  try {
    const [r] = await pool.query(
      `SELECT CONCAT(firstname,' ',lastname) AS nome,
              phone AS telefone, '' AS cpf, '' AS estado
       FROM pkg_user
       WHERE REPLACE(phone,'+','') LIKE ? OR
             REPLACE(callerid,'+','') LIKE ? LIMIT 1`,
      [`%${tel.slice(-9)}`, `%${tel.slice(-9)}`]);
    if (r.length) return { ...r[0], fonte:'mbilling' };
  } catch(e) {}

  // 3. CDR — chamadas anteriores para enriquecer dados
  try {
    const [r] = await pool.query(
      `SELECT src AS telefone,
              COALESCE(cnam,'') AS nome,
              '' AS cpf, '' AS estado
       FROM cdr
       WHERE REPLACE(src,'+','') LIKE ?
       ORDER BY calldate DESC LIMIT 1`,
      [`%${tel.slice(-9)}`]);
    if (r.length) return { ...r[0], fonte:'cdr' };
  } catch(e) {}

  return null;
}

// ── Enviar popup para agente ──────────────────────────────────────
async function enviarPopup(ramalBruto, telefone, extra={}) {
  const ramal = String(ramalBruto)
    .replace(/SIP\//i,'')
    .replace(/IAX2\//i,'')
    .replace(/\/.*/,'')
    .trim();

  const ws = agenteSockets.get(ramal);
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    console.log(`[Popup] Agente ${ramal} não conectado`);
    return;
  }

  const lead = await buscarLead(telefone);
  const payload = {
    type:       'screenpop',
    telefone:   telefone || '—',
    nome:       lead?.nome    || extra.nome    || 'Não identificado',
    cpf:        lead?.cpf     || extra.cpf     || '—',
    estado:     lead?.estado  || extra.estado  || '—',
    fonte:      lead?.fonte   || 'desconhecido',
    encontrado: !!lead,
    hora:       new Date().toLocaleTimeString('pt-BR'),
    data:       new Date().toLocaleDateString('pt-BR')
  };

  ws.send(JSON.stringify(payload));
  console.log(`[Popup] ✔ Agente ${ramal} ← ${payload.nome} (${telefone})`);
}

// ── Eventos AMI do MagnusBilling ─────────────────────────────────

// Agente atendeu chamada da fila — PRINCIPAL
ami.on('agentconnect', evt => {
  const ramal = evt.agent || evt.membername || evt.agentcalled || '';
  const tel   = evt.calleridnum || evt.connectedlinenum || '';
  console.log('[AMI] AgentConnect:', ramal, '←', tel);
  if (ramal && tel) enviarPopup(ramal, tel);
});

// Alternativo: quando agente é chamado (antes de atender)
ami.on('agentcalled', evt => {
  const ramal = evt.agentcalled || evt.agent || '';
  const tel   = evt.calleridnum || '';
  console.log('[AMI] AgentCalled:', ramal, '←', tel);
  if (ramal && tel) {
    const uid = evt.uniqueid || tel;
    pendingPops.set(uid, { ramal, tel });
  }
});

// Bridge — quando dois canais são conectados (fallback)
ami.on('bridgeenter', evt => {
  if (!evt.channel) return;
  const m = evt.channel.match(/SIP\/(\d+)/i) || evt.channel.match(/IAX2\/(\w+)/i);
  if (!m) return;
  const ramal = m[1];
  const tel   = evt.calleridnum || evt.connectedlinenum || '';
  if (tel && !/^\d{3,5}$/.test(tel)) { // ignorar ramais internos
    console.log('[AMI] BridgeEnter:', ramal, '←', tel);
    enviarPopup(ramal, tel);
  }
});

// Hangup — limpar dados
ami.on('hangup', evt => {
  if (evt.uniqueid) pendingPops.delete(evt.uniqueid);
});

// ── Rotas ─────────────────────────────────────────────────────────

// Criar tabela de leads (chamado na primeira vez)
async function criarTabelaLeads() {
  try {
    await pool.query(`
      CREATE TABLE IF NOT EXISTS leads (
        id       INT AUTO_INCREMENT PRIMARY KEY,
        nome     VARCHAR(150),
        telefone VARCHAR(25) NOT NULL,
        cpf      VARCHAR(14),
        estado   VARCHAR(2),
        criado   DATETIME DEFAULT NOW(),
        UNIQUE KEY uk_tel (telefone)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    `);
    console.log('✔ Tabela leads OK');
  } catch(e) { console.warn('⚠ Tabela leads:', e.message); }
}
criarTabelaLeads();

// Importar leads via JSON
app.post('/api/leads', async (req, res) => {
  const { leads } = req.body;
  if (!leads?.length) return res.status(400).json({ erro:'Sem leads' });
  let ok=0, skip=0;
  for (const l of leads) {
    let tel = (l.telefone||'').replace(/\D/g,'');
    if (!tel) { skip++; continue; }
    if (tel.length<=11) tel='55'+tel;
    try {
      await pool.execute(
        `INSERT INTO leads (nome,telefone,cpf,estado) VALUES (?,?,?,?)
         ON DUPLICATE KEY UPDATE nome=VALUES(nome),cpf=VALUES(cpf),estado=VALUES(estado)`,
        [l.nome||'',tel,l.cpf||'',l.estado||'']);
      ok++;
    } catch { skip++; }
  }
  res.json({ ok:true, importados:ok, ignorados:skip });
});

// Buscar lead pelo telefone (para debug)
app.get('/api/leads/:tel', async (req,res) => {
  const lead = await buscarLead(req.params.tel);
  res.json(lead || { encontrado:false });
});

// Status dos agentes online
app.get('/api/status', (req,res) => {
  const lista = [];
  agenteSockets.forEach((ws,r)=>lista.push({ ramal:r, online:ws.readyState===WebSocket.OPEN }));
  res.json({ agentes:lista, total:lista.length });
});

// Popup manual via URL (para integrar com MicroSIP)
app.get('/popup', (req,res) => {
  const { ramal,numero,nome,cpf,estado } = req.query;
  if (ramal && numero) enviarPopup(ramal, numero, { nome,cpf,estado });
  res.json({ ok:true });
});

server.listen(process.env.PORT||4000, ()=>
  console.log(`🚀 WebPhone Screen Pop na porta ${process.env.PORT||4000}`));
EOSRV
ok "server.js criado"

# ══════════════════════════════════════════════════════════════════
# ETAPA 4 — Interface Web do Agente
# ══════════════════════════════════════════════════════════════════
passo "4" "Criando interface do agente..."
mkdir -p "${WEB_DIR}"

cat > "${WEB_DIR}/index.html" << EOHTML
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Painel do Atendente — MagnusBilling</title>
<style>
/* ── Reset & Base ── */
*{box-sizing:border-box;margin:0;padding:0;font-family:'Segoe UI',system-ui,sans-serif}
:root{
  --bg:#0d1117; --bg2:#161b22; --bg3:#1c2128;
  --border:#30363d; --border2:#21262d;
  --text:#e6edf3; --muted:#8b949e;
  --blue:#58a6ff; --blue-bg:#1f6feb22; --blue-border:#1f6feb44;
  --green:#3fb950; --green-bg:#0d4a1e; --green-dark:#238636;
  --red:#f85149; --red-bg:#4a0000; --red-dark:#da3633;
  --orange:#f0883e; --orange-bg:#3a1a00;
  --yellow:#d29922; --purple:#bc8cff;
}
body{background:var(--bg);color:var(--text);min-height:100vh;display:flex;flex-direction:column}

/* ── Header ── */
.header{
  background:var(--bg2);
  border-bottom:1px solid var(--border);
  padding:10px 20px;
  display:flex;align-items:center;gap:12px;
}
.header h1{font-size:.95rem;color:var(--blue);flex:1}
.badge{
  display:flex;align-items:center;gap:6px;
  padding:4px 12px;border-radius:20px;
  font-size:.75rem;
  background:var(--bg3);border:1px solid var(--border2);
  transition:.3s;
}
.badge.online {background:var(--green-bg);border-color:var(--green-dark);color:var(--green)}
.badge.chamada{background:var(--orange-bg);border-color:var(--orange);color:var(--orange)}
.led{width:8px;height:8px;border-radius:50%;flex-shrink:0;transition:.3s}
.led.off {background:#484f58}
.led.on  {background:var(--green);box-shadow:0 0 6px var(--green)66}
.led.ring{background:var(--orange);box-shadow:0 0 6px var(--orange)66;animation:pulse .8s infinite}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.4}}

/* ── Layout ── */
.main{flex:1;display:flex;gap:0}
.sidebar{width:320px;flex-shrink:0;border-right:1px solid var(--border2);padding:16px;display:flex;flex-direction:column;gap:12px}
.content{flex:1;padding:16px;display:flex;flex-direction:column;gap:12px}

/* ── Cards ── */
.card{
  background:var(--bg2);
  border:1px solid var(--border);
  border-radius:10px;
  padding:14px;
}
.card-title{
  font-size:.74rem;color:var(--blue);
  text-transform:uppercase;letter-spacing:.05em;
  margin-bottom:12px;display:flex;align-items:center;gap:6px;
}

/* ── Formulários ── */
label{display:block;font-size:.72rem;color:var(--muted);margin-bottom:3px;margin-top:8px}
input,select{
  width:100%;padding:7px 10px;
  background:var(--bg);border:1px solid var(--border);
  border-radius:6px;color:var(--text);font-size:.83rem;
  transition:.2s;
}
input:focus,select:focus{outline:none;border-color:var(--blue);box-shadow:0 0 0 3px var(--blue-bg)}
input[type=password]{letter-spacing:.1em}

/* ── Botões ── */
.btn{
  padding:7px 14px;border:none;border-radius:6px;
  cursor:pointer;font-weight:600;font-size:.8rem;
  display:inline-flex;align-items:center;gap:5px;
  transition:.15s;white-space:nowrap;
}
.btn:hover{filter:brightness(1.1)}
.btn:active{transform:scale(.97)}
.btn-green {background:var(--green-dark);color:#fff}
.btn-red   {background:var(--red-dark);color:#fff;display:none}
.btn-mute  {background:var(--blue-bg);color:var(--blue);border:1px solid var(--blue-border)}
.btn-gray  {background:var(--bg3);color:var(--muted);border:1px solid var(--border2)}
.btn-full  {width:100%;justify-content:center}

/* ── WebPhone ── */
.phone-row{display:flex;gap:8px;align-items:center;margin-top:8px}
.phone-row input{flex:1}
#timer{
  font-size:1.4rem;color:var(--blue);
  font-variant-numeric:tabular-nums;
  min-width:65px;text-align:center;font-weight:600;
}

/* ── Status SIP ── */
#sipst{font-size:.74rem;color:var(--muted);margin-top:8px;padding:6px 10px;background:var(--bg);border-radius:5px}

/* ══════════════════════════════════════════════════
   SCREEN POP — Janela que aparece ao receber chamada
   ══════════════════════════════════════════════════ */
#popup-overlay{
  display:none;
  position:fixed;inset:0;
  background:rgba(0,0,0,.55);
  z-index:9999;
  align-items:flex-start;
  justify-content:flex-end;
  padding:24px;
}
#popup-overlay.show{display:flex}

#popup-box{
  background:var(--bg2);
  border:2px solid var(--blue);
  border-radius:14px;
  width:360px;
  box-shadow:0 12px 48px rgba(0,0,0,.7), 0 0 0 1px var(--blue-border);
  animation:slideDown .3s cubic-bezier(.22,.68,0,1.2);
  overflow:hidden;
}
@keyframes slideDown{from{transform:translateY(-30px) scale(.95);opacity:0}to{transform:none;opacity:1}}

.popup-header{
  background:linear-gradient(135deg,#1f6feb22,#58a6ff11);
  border-bottom:1px solid var(--border);
  padding:14px 16px;
  display:flex;align-items:center;gap:10px;
}
.popup-avatar{
  width:44px;height:44px;
  background:var(--blue-bg);
  border:1px solid var(--blue-border);
  border-radius:50%;
  display:flex;align-items:center;justify-content:center;
  font-size:1.3rem;flex-shrink:0;
}
.popup-meta h3{font-size:.88rem;color:var(--blue);margin-bottom:2px}
.popup-meta p {font-size:.72rem;color:var(--muted)}
.popup-close{
  margin-left:auto;
  background:none;border:none;
  color:var(--muted);cursor:pointer;
  font-size:1.1rem;padding:4px 8px;
  border-radius:5px;transition:.15s;
}
.popup-close:hover{background:var(--bg3);color:var(--text)}

.popup-body{padding:14px 16px}

.field-row{
  display:flex;align-items:center;
  padding:9px 0;
  border-bottom:1px solid var(--border2);
}
.field-row:last-child{border-bottom:none}
.field-icon{width:32px;font-size:.95rem;flex-shrink:0}
.field-label{width:70px;font-size:.72rem;color:var(--muted)}
.field-value{
  flex:1;font-size:.88rem;font-weight:600;color:var(--text);
  white-space:nowrap;overflow:hidden;text-overflow:ellipsis;
}
.field-value.big{font-size:1rem;color:var(--blue)}

.badge-fonte{
  display:inline-block;padding:1px 6px;
  border-radius:4px;font-size:.68rem;font-weight:700;margin-left:6px;
  vertical-align:middle;
}
.fonte-leads   {background:#0d4a1e;color:#3fb950}
.fonte-mbilling{background:#0c2d6b;color:#58a6ff}
.fonte-cdr     {background:#4a3000;color:#d29922}
.fonte-nf      {background:#4a0000;color:#f85149}

.popup-footer{
  padding:12px 16px;
  border-top:1px solid var(--border2);
  display:flex;gap:8px;
}
.popup-footer .btn{flex:1;justify-content:center}

/* ── Histórico ── */
#log{
  font-size:.76rem;color:var(--muted);
  max-height:200px;overflow-y:auto;
}
#log::-webkit-scrollbar{width:4px}
#log::-webkit-scrollbar-thumb{background:var(--border);border-radius:2px}
.log-item{
  padding:5px 8px;
  border-bottom:1px solid var(--border2);
  display:flex;gap:8px;align-items:flex-start;
}
.log-item .log-time{color:#484f58;flex-shrink:0;font-size:.7rem;padding-top:1px}
.log-item .log-text{flex:1}

/* ── Tag de fonte ── */
.nao-cadastrado{
  display:inline-block;
  background:var(--orange-bg);color:var(--orange);
  border-radius:4px;padding:1px 5px;font-size:.68rem;margin-left:4px;
}
</style>
</head>
<body>

<!-- ══ SCREEN POP OVERLAY ══════════════════════════════════════ -->
<div id="popup-overlay">
  <div id="popup-box">

    <div class="popup-header">
      <div class="popup-avatar">📋</div>
      <div class="popup-meta">
        <h3>Cliente em Linha</h3>
        <p id="pop-hora">—</p>
      </div>
      <button class="popup-close" onclick="fecharPopup()">✕</button>
    </div>

    <div class="popup-body">
      <div class="field-row">
        <span class="field-icon">👤</span>
        <span class="field-label">Nome</span>
        <span class="field-value big" id="pop-nome">—</span>
      </div>
      <div class="field-row">
        <span class="field-icon">📱</span>
        <span class="field-label">Telefone</span>
        <span class="field-value" id="pop-tel">—</span>
      </div>
      <div class="field-row">
        <span class="field-icon">🪪</span>
        <span class="field-label">CPF</span>
        <span class="field-value" id="pop-cpf">—</span>
      </div>
      <div class="field-row">
        <span class="field-icon">📍</span>
        <span class="field-label">Estado</span>
        <span class="field-value" id="pop-estado">—</span>
      </div>
    </div>

    <div class="popup-footer">
      <button class="btn btn-gray" onclick="fecharPopup()">Fechar</button>
    </div>
  </div>
</div>

<!-- ══ HEADER ══════════════════════════════════════════════════ -->
<div class="header">
  <h1>📞 Painel do Atendente — MagnusBilling</h1>
  <div class="badge" id="badge">
    <span class="led off" id="led"></span>
    <span id="badge-txt">Offline</span>
  </div>
</div>

<!-- ══ MAIN ════════════════════════════════════════════════════ -->
<div class="main">

  <!-- ── Sidebar ── -->
  <div class="sidebar">

    <!-- Config SIP -->
    <div class="card">
      <div class="card-title">⚙️ Configuração SIP</div>
      <label>Ramal</label>
      <input id="cfg-ramal" value="1001" style="width:100%">
      <label>Senha SIP</label>
      <input id="cfg-pass" type="password" placeholder="Senha do ramal no Magnus">
      <label>Servidor</label>
      <input id="cfg-host" value="${SERVER_IP}">
      <button class="btn btn-green btn-full" style="margin-top:12px" id="btn-conectar" onclick="conectar()">
        🔌 Conectar
      </button>
      <div id="sipst">Aguardando configuração...</div>
    </div>

    <!-- WebPhone -->
    <div class="card">
      <div class="card-title">☎️ Discagem</div>
      <label>Número</label>
      <input id="num-discar" type="tel" placeholder="Ex: 5585999887766">
      <div style="display:flex;gap:6px;margin-top:8px">
        <button class="btn btn-green" id="btn-ligar" onclick="ligar()" style="flex:1">📞 Ligar</button>
        <button class="btn btn-red"   id="btn-desl"  onclick="desligar()" style="flex:1">📵 Encerrar</button>
      </div>
      <div style="display:flex;align-items:center;justify-content:space-between;margin-top:8px">
        <button class="btn btn-mute" onclick="mute()">🔇 Mute</button>
        <div id="timer">00:00</div>
      </div>
    </div>

  </div>

  <!-- ── Content ── -->
  <div class="content">

    <!-- Última chamada (screen pop resumido) -->
    <div class="card" id="ultimo-card" style="display:none">
      <div class="card-title">📋 Última Chamada Identificada</div>
      <div style="display:flex;gap:16px;flex-wrap:wrap">
        <div><div style="font-size:.7rem;color:var(--muted)">Nome</div><div style="font-weight:600" id="ult-nome">—</div></div>
        <div><div style="font-size:.7rem;color:var(--muted)">Telefone</div><div style="font-weight:600" id="ult-tel">—</div></div>
        <div><div style="font-size:.7rem;color:var(--muted)">CPF</div><div style="font-weight:600" id="ult-cpf">—</div></div>
        <div><div style="font-size:.7rem;color:var(--muted)">Estado</div><div style="font-weight:600" id="ult-estado">—</div></div>
        <div><div style="font-size:.7rem;color:var(--muted)">Horário</div><div style="font-weight:600" id="ult-hora">—</div></div>
      </div>
    </div>

    <!-- Histórico -->
    <div class="card" style="flex:1">
      <div class="card-title">📜 Histórico da Sessão</div>
      <div id="log">Nenhuma chamada ainda.</div>
    </div>

  </div>
</div>

<!-- JsSIP — compatível com Asterisk 13 chan_sip + WebSocket -->
<script src="https://cdnjs.cloudflare.com/ajax/libs/jssip/3.10.0/jssip.min.js"></script>
<script>
// ── Configuração ──────────────────────────────────────────────────
const SERVER = document.getElementById('cfg-host').value || '${SERVER_IP}';

// ── WebSocket Screen Pop ──────────────────────────────────────────
let wsPop = null;

function conectarPop(ramal) {
  if (wsPop) { try{wsPop.close();}catch(e){} }
  wsPop = new WebSocket('ws://' + window.location.hostname + ':4000');
  wsPop.onopen = () => {
    wsPop.send(JSON.stringify({ type:'registrar', ramal:String(ramal) }));
    setStatus('online');
  };
  wsPop.onmessage = e => {
    try {
      const d = JSON.parse(e.data);
      if (d.type === 'screenpop') mostrarPopup(d);
    } catch(e) {}
  };
  wsPop.onclose = () => {
    setStatus('offline');
    setTimeout(() => conectarPop(document.getElementById('cfg-ramal').value), 4000);
  };
}

// ── Mostrar popup ─────────────────────────────────────────────────
function mostrarPopup(d) {
  const fonteClass = { leads:'fonte-leads', mbilling:'fonte-mbilling', cdr:'fonte-cdr' }[d.fonte] || 'fonte-nf';
  const fonteLabel = { leads:'Lead', mbilling:'Magnus', cdr:'CDR' }[d.fonte] || 'Novo';

  document.getElementById('pop-hora').textContent = d.data + ' ' + d.hora;
  document.getElementById('pop-nome').innerHTML =
    (d.nome||'—') +
    '<span class="badge-fonte ' + fonteClass + '">' + fonteLabel + '</span>' +
    (!d.encontrado ? '<span class="nao-cadastrado">Não cadastrado</span>' : '');
  document.getElementById('pop-tel').textContent    = d.telefone || '—';
  document.getElementById('pop-cpf').textContent    = d.cpf      || '—';
  document.getElementById('pop-estado').textContent = d.estado   || '—';

  // Mostrar overlay
  document.getElementById('popup-overlay').classList.add('show');

  // Atualizar card de resumo
  document.getElementById('ultimo-card').style.display = 'block';
  document.getElementById('ult-nome').textContent   = d.nome    || '—';
  document.getElementById('ult-tel').textContent    = d.telefone|| '—';
  document.getElementById('ult-cpf').textContent    = d.cpf     || '—';
  document.getElementById('ult-estado').textContent = d.estado  || '—';
  document.getElementById('ult-hora').textContent   = d.hora    || '—';

  // Notificação do navegador
  if (Notification.permission === 'granted') {
    new Notification('📞 ' + (d.nome||'Chamada'), {
      body: 'Tel: ' + (d.telefone||'—') + ' | CPF: ' + (d.cpf||'—') + ' | ' + (d.estado||'—'),
    });
  }

  addLog('📋 ' + (d.nome||d.telefone) + (d.encontrado?' ✓':' (não cadastrado)'));
}

function fecharPopup() {
  document.getElementById('popup-overlay').classList.remove('show');
}
document.getElementById('popup-overlay').addEventListener('click', e => {
  if (e.target.id === 'popup-overlay') fecharPopup();
});

// ── Status ────────────────────────────────────────────────────────
function setStatus(s) {
  const led   = document.getElementById('led');
  const txt   = document.getElementById('badge-txt');
  const badge = document.getElementById('badge');
  badge.className = 'badge ' + s;
  if (s==='online')  { led.className='led on';   txt.textContent='🟢 Online'; }
  else if (s==='chamada') { led.className='led ring'; txt.textContent='🟠 Em chamada'; }
  else               { led.className='led off';  txt.textContent='🔴 Offline'; }
}

// ── JsSIP WebPhone ────────────────────────────────────────────────
let ua=null, sess=null, mutado=false, seg=0, timerInt=null;

function conectar() {
  const ramal = document.getElementById('cfg-ramal').value.trim();
  const pass  = document.getElementById('cfg-pass').value.trim();
  const host  = document.getElementById('cfg-host').value.trim();
  if (!pass) { alert('Informe a senha SIP'); return; }

  Notification.requestPermission();
  conectarPop(ramal);

  if (ua) { try{ua.stop();}catch(e){} }

  // Tentar WSS primeiro, fallback WS
  const socket = new JsSIP.WebSocketInterface('wss://' + host + ':8089/ws');

  ua = new JsSIP.UA({
    sockets:        [socket],
    uri:            'sip:' + ramal + '@' + host,
    password:       pass,
    register:       true,
    // Compatibilidade com chan_sip (não pjsip)
    contact_uri:    'sip:' + ramal + '@' + host + ';transport=ws',
    user_agent:     'MagnusBilling WebPhone'
  });

  ua.on('registered',         () => setSip('✅ Registrado — pronto para atender'));
  ua.on('unregistered',       () => setSip('⚠️ Desregistrado'));
  ua.on('registrationFailed', e => {
    setSip('❌ Falha: ' + e.cause + ' — tentando WS...');
    // Fallback para WS sem SSL
    setTimeout(() => {
      const sk2 = new JsSIP.WebSocketInterface('ws://' + host + ':8088/ws');
      ua = new JsSIP.UA({ sockets:[sk2], uri:'sip:'+ramal+'@'+host, password:pass, register:true });
      ua.on('registered',  () => setSip('✅ Registrado (WS)'));
      ua.on('registrationFailed', e2 => setSip('❌ Falha: '+e2.cause));
      registrarEventos();
      ua.start();
    }, 2000);
  });

  registrarEventos();
  ua.start();
  setSip('🔄 Conectando...');
}

function registrarEventos() {
  ua.on('newRTCSession', e => {
    sess = e.session;
    const dir = e.originator==='remote' ? '📲 Entrada' : '📤 Saída';
    const num = sess.remote_identity?.uri?.user || '?';
    addLog(dir + ': ' + num);

    sess.on('accepted', () => {
      iniciarTimer();
      setStatus('chamada');
      document.getElementById('btn-desl').style.display = 'inline-flex';
      document.getElementById('btn-ligar').style.display = 'none';
    });
    sess.on('ended',  () => { pararTimer(); resetUI(); fecharPopup(); addLog('📵 Chamada encerrada'); });
    sess.on('failed', e2=> { pararTimer(); resetUI(); addLog('❌ Falhou: '+(e2.cause||'')); });

    if (e.originator==='remote') {
      sess.answer({ mediaConstraints:{ audio:true, video:false } });
    }
  });
}

function ligar() {
  const n    = document.getElementById('num-discar').value.trim();
  const host = document.getElementById('cfg-host').value.trim();
  if (!n||!ua) return;
  ua.call('sip:'+n+'@'+host, { mediaConstraints:{ audio:true, video:false } });
}
function desligar()  { sess?.terminate(); }
function mute() {
  if (!sess) return;
  mutado ? sess.unmute({ audio:true }) : sess.mute({ audio:true });
  mutado = !mutado;
  document.querySelector('.btn-mute').textContent = mutado ? '🔊 Unmute' : '🔇 Mute';
}
function iniciarTimer() {
  seg=0;
  timerInt=setInterval(()=>{
    seg++;
    const m=String(Math.floor(seg/60)).padStart(2,'0');
    const s=String(seg%60).padStart(2,'0');
    document.getElementById('timer').textContent=m+':'+s;
  },1000);
}
function pararTimer()  { clearInterval(timerInt); document.getElementById('timer').textContent='00:00'; }
function resetUI() {
  setStatus('online');
  document.getElementById('btn-desl').style.display ='none';
  document.getElementById('btn-ligar').style.display='inline-flex';
}
function setSip(t) { document.getElementById('sipst').textContent=t; }
function addLog(txt) {
  const el = document.getElementById('log');
  const h  = new Date().toLocaleTimeString('pt-BR');
  if (el.children.length === 0 || el.textContent === 'Nenhuma chamada ainda.') el.innerHTML='';
  el.innerHTML = '<div class="log-item"><span class="log-time">'+h+'</span><span class="log-text">'+txt+'</span></div>' + el.innerHTML;
}
</script>
</body>
</html>
EOHTML
ok "Interface web do agente criada"

# ══════════════════════════════════════════════════════════════════
# ETAPA 5 — Configurar Apache para servir o WebPhone
# ══════════════════════════════════════════════════════════════════
passo "5" "Configurando Apache..."

cat > /etc/apache2/sites-available/webphone.conf << 'EOF'
<VirtualHost *:80>
  Alias /webphone /var/www/html/webphone
  <Directory /var/www/html/webphone>
    Options -Indexes
    AllowOverride None
    Require all granted
  </Directory>
</VirtualHost>
EOF

# Habilitar módulos necessários
a2enmod proxy proxy_http proxy_wstunnel headers 2>/dev/null || true

# Incluir no config principal
if ! grep -q "webphone" /etc/apache2/sites-enabled/*.conf 2>/dev/null; then
  ln -sf /etc/apache2/sites-available/webphone.conf /etc/apache2/conf-enabled/webphone.conf 2>/dev/null || true
fi

# Adicionar /webphone ao VirtualHost do MagnusBilling
if ! grep -q "Alias /webphone" /etc/apache2/sites-enabled/*.conf 2>/dev/null; then
  APACHE_CONF=$(find /etc/apache2/sites-enabled/ -name "*.conf" | head -1)
  if [[ -n "$APACHE_CONF" ]]; then
    sed -i 's|</VirtualHost>|  Alias /webphone /var/www/html/webphone\n  <Directory /var/www/html/webphone>\n    Options -Indexes\n    AllowOverride None\n    Require all granted\n  </Directory>\n</VirtualHost>|' "$APACHE_CONF"
  fi
fi

chown -R asterisk:asterisk "${WEB_DIR}"
service apache2 reload 2>/dev/null || true
ok "Apache configurado"

# ══════════════════════════════════════════════════════════════════
# ETAPA 6 — Firewall
# ══════════════════════════════════════════════════════════════════
passo "6" "Abrindo portas..."
ufw allow 4000/tcp  >> /dev/null 2>&1 || true
ufw allow 8088/tcp  >> /dev/null 2>&1 || true
ufw allow 8089/tcp  >> /dev/null 2>&1 || true
ok "Portas 4000, 8088, 8089 liberadas"

# ══════════════════════════════════════════════════════════════════
# ETAPA 7 — Iniciar serviços
# ══════════════════════════════════════════════════════════════════
passo "7" "Iniciando Screen Pop..."
cd "${SP_DIR}"
pm2 delete webphone-screenpop 2>/dev/null || true
pm2 start server.js --name webphone-screenpop
pm2 save
env PATH=$PATH:/usr/bin pm2 startup systemd -u root --hp /root >> /dev/null 2>&1 || true
ok "Screen Pop iniciado com PM2"

# ══════════════════════════════════════════════════════════════════
# RESUMO
# ══════════════════════════════════════════════════════════════════
clear
echo -e "${G}${W}"
cat << 'EOF'
  ╔══════════════════════════════════════════════════════════════╗
  ║   ✔  WEBPHONE + SCREEN POP INSTALADO!                       ║
  ╚══════════════════════════════════════════════════════════════╝
EOF
echo -e "${N}"
echo -e "  ${W}PAINEL DO ATENDENTE:${N}"
echo -e "  ┌─────────────────────────────────────────────────────────┐"
echo -e "  │  http://${SERVER_IP}/webphone/                         "
echo -e "  └─────────────────────────────────────────────────────────┘"
echo -e ""
echo -e "  ${W}COMO FUNCIONA:${N}"
echo -e "  1. Atendente abre ${C}http://${SERVER_IP}/webphone/${N}"
echo -e "  2. Informa ramal + senha SIP → clica Conectar"
echo -e "  3. Cliente liga → cai na URA → pressiona 1 para fila"
echo -e "  4. Atendente atende → ${G}popup abre automaticamente${N} com:"
echo -e "     👤 Nome  |  📱 Telefone  |  🪪 CPF  |  📍 Estado"
echo -e ""
echo -e "  ${W}IMPORTAR LEADS (CSV → banco):${N}"
echo -e "  Use a rota: POST http://${SERVER_IP}:4000/api/leads"
echo -e "  Body JSON: {\"leads\":[{\"nome\":\"\",\"telefone\":\"\",\"cpf\":\"\",\"estado\":\"\"}]}"
echo -e ""
echo -e "  ${W}LOGS:${N}"
echo -e "  pm2 logs webphone-screenpop"
echo -e ""
