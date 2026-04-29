#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  WEBPHONE + SCREEN POP v2 — MagnusBilling (Asterisk 13)        ║
# ║  Versão corrigida e testada em produção                         ║
# ║  Execute APÓS instalar o MagnusBilling:                         ║
# ║  bash instalar_webphone.sh                                      ║
# ╚══════════════════════════════════════════════════════════════════╝
if [[ $EUID -ne 0 ]]; then exec sudo bash "$0" "$@"; fi
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' W='\033[1m' N='\033[0m'
ok()    { echo -e "${G}[✔]${N} $1"; }
info()  { echo -e "${C}[➜]${N} $1"; }
warn()  { echo -e "${Y}[⚠]${N} $1"; }
passo() { echo -e "\n${W}${Y}[$1]${N} $2"; }

SP_DIR="/opt/webphone"
WEB_DIR="/var/www/html/webphone"
SERVER_IP=$(hostname -I | awk '{print $1}')
DOMAIN=$(hostname -f 2>/dev/null || echo "$SERVER_IP")

# ── Credenciais do MagnusBilling ───────────────────────────────────
AMI_USER="magnus"
AMI_PASS="magnussolution"
AMI_PORT="5038"

MB_CONF="/etc/asterisk/res_config_mysql.conf"
if [[ -f "$MB_CONF" ]]; then
  DB_HOST=$(grep "dbhost" "$MB_CONF" | awk -F'=' '{print $2}' | tr -d ' ')
  DB_NAME=$(grep "dbname" "$MB_CONF" | awk -F'=' '{print $2}' | tr -d ' ')
  DB_USER=$(grep "dbuser" "$MB_CONF" | awk -F'=' '{print $2}' | tr -d ' ')
  DB_PASS=$(grep "dbpass" "$MB_CONF" | awk -F'=' '{print $2}' | tr -d ' ')
  ok "Credenciais do banco detectadas de $MB_CONF"
else
  warn "Arquivo $MB_CONF não encontrado"
  DB_HOST="localhost"; DB_NAME="mbilling"; DB_USER="mbillingUser"
  read -rsp "  🔑 Senha do banco mbillingUser: " DB_PASS; echo
fi

clear
echo -e "${C}${W}"
cat << 'BANNER'
  ╔══════════════════════════════════════════════════════════════╗
  ║   WEBPHONE + SCREEN POP v2 — MagnusBilling                  ║
  ║   Asterisk 13 + chan_sip + WebSocket                         ║
  ╚══════════════════════════════════════════════════════════════╝
BANNER
echo -e "${N}  IP: ${Y}${SERVER_IP}${N}  |  Domínio: ${Y}${DOMAIN}${N}\n"

# ══════════════════════════════════════════════════════════════════
# ETAPA 1 — Dependências
# ══════════════════════════════════════════════════════════════════
passo "1" "Instalando dependências..."
if ! node -v 2>/dev/null | grep -q "v20"; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >> /dev/null 2>&1
  apt-get install -y -qq nodejs >> /dev/null 2>&1
fi
ok "Node.js $(node -v)"
npm install -g pm2 browserify --silent >> /dev/null 2>&1
ok "PM2 + Browserify instalados"

# ══════════════════════════════════════════════════════════════════
# ETAPA 2 — Asterisk WebSocket
# ══════════════════════════════════════════════════════════════════
passo "2" "Configurando WebSocket no Asterisk 13..."

mkdir -p /etc/asterisk/keys
if [[ ! -f /etc/asterisk/keys/asterisk.pem ]]; then
  openssl req -new -x509 -days 3650 -nodes \
    -out /etc/asterisk/keys/asterisk.pem \
    -keyout /etc/asterisk/keys/asterisk.pem \
    -subj "/C=BR/ST=SP/L=SaoPaulo/O=MagnusBilling/CN=${SERVER_IP}" \
    >> /dev/null 2>&1
  chown asterisk:asterisk /etc/asterisk/keys/asterisk.pem
  chmod 600 /etc/asterisk/keys/asterisk.pem
fi

cat > /etc/asterisk/http.conf << EOF
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

if ! grep -q "transport=.*ws" /etc/asterisk/sip.conf 2>/dev/null; then
  sed -i '/^\[general\]/a transport=udp,ws,wss' /etc/asterisk/sip.conf
  ok "Transport WS adicionado"
else
  ok "Transport WS já configurado"
fi

service asterisk restart >> /dev/null 2>&1; sleep 3
ok "Asterisk reiniciado"

# ══════════════════════════════════════════════════════════════════
# ETAPA 3 — SSL Let's Encrypt
# ══════════════════════════════════════════════════════════════════
passo "3" "Verificando SSL..."
SSL_CERT="" SSL_KEY=""

if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
  SSL_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
  SSL_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
  # Asterisk usa cert válido
  cat > /etc/asterisk/http.conf << EOF
[general]
enabled=yes
bindaddr=0.0.0.0
bindport=8088
tlsenable=yes
tlsbindaddr=0.0.0.0:8089
tlscertfile=${SSL_CERT}
tlsprivatekey=${SSL_KEY}
enablestatic=yes
EOF
  service asterisk restart >> /dev/null 2>&1; sleep 2
  ok "Usando certificado Let's Encrypt"
else
  warn "Let's Encrypt não encontrado — usando certificado autoassinado"
  warn "Para HTTPS: apt install certbot python3-certbot-apache && certbot --apache -d ${DOMAIN} -m email@dominio.com --agree-tos"
fi

# ══════════════════════════════════════════════════════════════════
# ETAPA 4 — JsSIP bundled
# ══════════════════════════════════════════════════════════════════
passo "4" "Empacotando JsSIP localmente..."
mkdir -p "${WEB_DIR}"
cd /tmp
npm install jssip --prefix /tmp/jssip_bundle >> /dev/null 2>&1
cat > /tmp/jssip_entry.js << 'EOF'
window.JsSIP = require('jssip');
EOF
cd /tmp/jssip_bundle
browserify /tmp/jssip_entry.js -o "${WEB_DIR}/jssip.min.js" 2>/dev/null || true

if [[ -f "${WEB_DIR}/jssip.min.js" ]] && [[ $(wc -c < "${WEB_DIR}/jssip.min.js") -gt 50000 ]]; then
  ok "JsSIP empacotado ($(du -sh ${WEB_DIR}/jssip.min.js | cut -f1))"
else
  warn "JsSIP não empacotado corretamente — verificar manualmente"
fi

# ══════════════════════════════════════════════════════════════════
# ETAPA 5 — Backend Node.js
# ══════════════════════════════════════════════════════════════════
passo "5" "Criando backend Screen Pop..."
mkdir -p "${SP_DIR}"
cat > "${SP_DIR}/package.json" << 'EOF'
{"name":"webphone-screenpop","version":"2.0.0","main":"server.js"}
EOF
cd "${SP_DIR}"
npm install express ws asterisk-manager mysql2 cors dotenv --save --silent >> /dev/null 2>&1
ok "Dependências instaladas"

cat > "${SP_DIR}/.env" << EOENV
AMI_HOST=127.0.0.1
AMI_PORT=${AMI_PORT}
AMI_USER=${AMI_USER}
AMI_PASS=${AMI_PASS}
DB_HOST=${DB_HOST}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}
DB_NAME=${DB_NAME}
SERVER_IP=${SERVER_IP}
DOMAIN=${DOMAIN}
PORT=4000
EOENV
chmod 600 "${SP_DIR}/.env"

cat > "${SP_DIR}/server.js" << 'EOSRV'
require('dotenv').config();
const express   = require('express');
const http      = require('http');
const WebSocket = require('ws');
const Ami       = require('asterisk-manager');
const mysql     = require('mysql2/promise');
const cors      = require('cors');

const app    = express();
const server = http.createServer(app);
const wss    = new WebSocket.Server({ server });
app.use(cors());
app.use(express.json());

// ── MySQL ─────────────────────────────────────────────────────────
const pool = mysql.createPool({
  host: process.env.DB_HOST, user: process.env.DB_USER,
  password: process.env.DB_PASS, database: process.env.DB_NAME,
  connectionLimit: 10
});
pool.query('SELECT 1').then(() => console.log('✔ MySQL MagnusBilling OK')).catch(e => console.warn('⚠ MySQL:', e.message));

// ── AMI ───────────────────────────────────────────────────────────
const ami = new Ami(process.env.AMI_PORT, process.env.AMI_HOST, process.env.AMI_USER, process.env.AMI_PASS, true);
ami.keepConnected();
ami.on('error', e => console.error('[AMI]', e.message));
ami.on('connect', () => console.log('✔ AMI Asterisk conectado'));

// ── Agentes ───────────────────────────────────────────────────────
const agenteSockets = new Map();
const popEnviados   = new Set();

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
  ws.on('close', () => { if (ramal) agenteSockets.delete(ramal); });
});

// ── Buscar lead na tabela pkg_phonenumber do MagnusBilling ────────
async function buscarLead(telefone) {
  if (!telefone || telefone === '<unknown>') return null;
  const tel = telefone.replace(/\D/g, '');
  if (!tel || tel.length < 8) return null;

  try {
    const [r] = await pool.query(
      `SELECT name AS nome, number AS telefone, doc AS cpf, city AS estado
       FROM pkg_phonenumber
       WHERE REPLACE(number,'+','') LIKE ? LIMIT 1`,
      [`%${tel.slice(-9)}`]);
    if (r.length) return { ...r[0], fonte:'leads' };
  } catch(e) {}

  try {
    const [r] = await pool.query(
      `SELECT CONCAT(firstname,' ',lastname) AS nome, phone AS telefone, '' AS cpf, '' AS estado
       FROM pkg_user WHERE REPLACE(phone,'+','') LIKE ? LIMIT 1`,
      [`%${tel.slice(-9)}`]);
    if (r.length) return { ...r[0], fonte:'mbilling' };
  } catch(e) {}

  return null;
}

// ── Enviar popup ──────────────────────────────────────────────────
async function enviarPopup(ramalBruto, telefone) {
  if (!telefone || telefone === '<unknown>') return;
  const tel = telefone.replace(/\D/g, '');
  if (!tel || tel.length < 8) return;

  const ramal = String(ramalBruto).replace(/SIP\//i,'').replace(/IAX2\//i,'').replace(/\/.*/,'').trim();
  const ws = agenteSockets.get(ramal);
  if (!ws || ws.readyState !== WebSocket.OPEN) return;

  const lead = await buscarLead(tel);
  ws.send(JSON.stringify({
    type:'screenpop', telefone:tel,
    nome:    lead?.nome    || 'Não identificado',
    cpf:     lead?.cpf     || '—',
    estado:  lead?.estado  || '—',
    fonte:   lead?.fonte   || 'desconhecido',
    encontrado: !!lead,
    hora: new Date().toLocaleTimeString('pt-BR'),
    data: new Date().toLocaleDateString('pt-BR')
  }));
  console.log(`[Popup] ✔ Agente ${ramal} ← ${lead?.nome||'?'} (${tel})`);
}

// ── Eventos AMI ───────────────────────────────────────────────────

// VarSet — método principal testado em produção com MagnusBilling
ami.on('varset', evt => {
  if (!evt.channel) return;
  const m = evt.channel.match(/^SIP\/([\d]+)-/);
  if (!m) return;
  const ramal = m[1];

  // Aceitar SOMENTE sequência de 8+ dígitos numéricos puros
  // Bloqueia: 's', 'h', '<unknown>', ramais internos, letras
  const _e = String(evt.exten || '');
  const _c = String(evt.connectedlinenum || '');
  const _n = String(evt.calleridnum || '');
  const _ok = (v) => /^[0-9]{8,}$/.test(v);
  const tel = _ok(_e) ? _e : _ok(_c) ? _c : _ok(_n) ? _n : '';

  if (!tel) return;
  // Só enviar se o agente estiver conectado no painel
  if (!agenteSockets.has(ramal)) return;

  const chave = `${ramal}-${tel}`;
  if (popEnviados.has(chave)) return;
  popEnviados.add(chave);
  setTimeout(() => popEnviados.delete(chave), 30000);

  console.log(`[VarSet] Ramal ${ramal} ← ${tel}`);
  enviarPopup(ramal, tel);
});

// AgentConnect — fallback (só números válidos)
ami.on('agentconnect', evt => {
  const ramal  = evt.agent || evt.membername || '';
  const rawTel = evt.calleridnum || evt.connectedlinenum || '';
  const tel    = rawTel.replace(/\D/g, '');
  if (ramal && tel.length >= 8 && rawTel !== '<unknown>') {
    console.log('[AMI] AgentConnect:', ramal, '←', tel);
    enviarPopup(ramal, tel);
  }
});

// BridgeEnter — fallback (ignora <unknown> e ramais internos)
ami.on('bridgeenter', evt => {
  if (!evt.channel) return;
  const m = evt.channel.match(/^SIP\/([\d]+)-/i);
  if (!m) return;
  const ramal  = m[1];
  const rawTel = evt.connectedlinenum || evt.calleridnum || '';
  const tel    = rawTel.replace(/\D/g, '');
  if (tel.length >= 8 && rawTel !== '<unknown>') {
    console.log('[AMI] BridgeEnter:', ramal, '←', tel);
    enviarPopup(ramal, tel);
  }
});

// ── Rotas ─────────────────────────────────────────────────────────
app.get('/status', (req, res) => {
  const lista = [];
  agenteSockets.forEach((ws, r) => lista.push({ ramal:r, online:ws.readyState===WebSocket.OPEN }));
  res.json({ agentes:lista, total:lista.length, ok:true });
});

server.listen(process.env.PORT || 4000, () =>
  console.log(`🚀 Screen Pop na porta ${process.env.PORT || 4000}`));
EOSRV
ok "server.js criado"

# ══════════════════════════════════════════════════════════════════
# ETAPA 6 — Interface Web
# ══════════════════════════════════════════════════════════════════
passo "6" "Criando interface web..."

# URLs corretas conforme SSL disponível
if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
  WS_POP="wss://${DOMAIN}/screenpop"
  WS_SIP="wss://${DOMAIN}/ws"
else
  WS_POP="ws://${SERVER_IP}:4000"
  WS_SIP="ws://${SERVER_IP}:8088/ws"
fi

cat > "${WEB_DIR}/index.html" << EOHTML
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Painel do Atendente — MagnusBilling</title>
<style>
*{box-sizing:border-box;margin:0;padding:0;font-family:'Segoe UI',system-ui,sans-serif}
:root{--bg:#0d1117;--bg2:#161b22;--bg3:#1c2128;--border:#30363d;--border2:#21262d;--text:#e6edf3;--muted:#8b949e;--blue:#58a6ff;--blue-bg:#1f6feb22;--blue-border:#1f6feb44;--green:#3fb950;--green-bg:#0d4a1e;--green-dark:#238636;--red:#f85149;--red-dark:#da3633;--orange:#f0883e;--orange-bg:#3a1a00}
body{background:var(--bg);color:var(--text);min-height:100vh;display:flex;flex-direction:column}
.header{background:var(--bg2);border-bottom:1px solid var(--border);padding:10px 20px;display:flex;align-items:center;gap:12px}
.header h1{font-size:.95rem;color:var(--blue);flex:1}
.badge{display:flex;align-items:center;gap:6px;padding:4px 12px;border-radius:20px;font-size:.75rem;background:var(--bg3);border:1px solid var(--border2);transition:.3s}
.badge.online{background:var(--green-bg);border-color:var(--green-dark);color:var(--green)}
.badge.chamada{background:var(--orange-bg);border-color:var(--orange);color:var(--orange)}
.led{width:8px;height:8px;border-radius:50%;flex-shrink:0}
.led.off{background:#484f58}.led.on{background:var(--green);box-shadow:0 0 6px var(--green)66}
.led.ring{background:var(--orange);box-shadow:0 0 6px var(--orange)66;animation:pulse .8s infinite}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.4}}
.main{flex:1;display:flex}
.sidebar{width:300px;flex-shrink:0;border-right:1px solid var(--border2);padding:16px;display:flex;flex-direction:column;gap:12px}
.content{flex:1;padding:16px;display:flex;flex-direction:column;gap:12px}
.card{background:var(--bg2);border:1px solid var(--border);border-radius:10px;padding:14px}
.card-title{font-size:.74rem;color:var(--blue);text-transform:uppercase;letter-spacing:.05em;margin-bottom:12px}
label{display:block;font-size:.72rem;color:var(--muted);margin-bottom:3px;margin-top:8px}
input{width:100%;padding:7px 10px;background:var(--bg);border:1px solid var(--border);border-radius:6px;color:var(--text);font-size:.83rem}
input:focus{outline:none;border-color:var(--blue)}
.btn{padding:7px 14px;border:none;border-radius:6px;cursor:pointer;font-weight:600;font-size:.8rem;display:inline-flex;align-items:center;gap:5px;transition:.15s}
.btn:hover{filter:brightness(1.1)}.btn:active{transform:scale(.97)}
.btn-green{background:var(--green-dark);color:#fff}.btn-red{background:var(--red-dark);color:#fff;display:none}
.btn-mute{background:var(--blue-bg);color:var(--blue);border:1px solid var(--blue-border)}.btn-full{width:100%;justify-content:center}
#timer{font-size:1.4rem;color:var(--blue);font-variant-numeric:tabular-nums;min-width:65px;text-align:center;font-weight:600}
#sipst{font-size:.74rem;color:var(--muted);margin-top:8px;padding:6px 10px;background:var(--bg);border-radius:5px}
#popup-overlay{display:none;position:fixed;inset:0;background:rgba(0,0,0,.55);z-index:9999;align-items:flex-start;justify-content:flex-end;padding:24px}
#popup-overlay.show{display:flex}
#popup-box{background:var(--bg2);border:2px solid var(--blue);border-radius:14px;width:360px;box-shadow:0 12px 48px rgba(0,0,0,.7);animation:slideDown .3s cubic-bezier(.22,.68,0,1.2);overflow:hidden}
@keyframes slideDown{from{transform:translateY(-30px) scale(.95);opacity:0}to{transform:none;opacity:1}}
.popup-header{background:linear-gradient(135deg,#1f6feb22,#58a6ff11);border-bottom:1px solid var(--border);padding:14px 16px;display:flex;align-items:center;gap:10px}
.popup-avatar{width:44px;height:44px;background:var(--blue-bg);border:1px solid var(--blue-border);border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:1.3rem;flex-shrink:0}
.popup-meta h3{font-size:.88rem;color:var(--blue);margin-bottom:2px}.popup-meta p{font-size:.72rem;color:var(--muted)}
.popup-close{margin-left:auto;background:none;border:none;color:var(--muted);cursor:pointer;font-size:1.1rem;padding:4px 8px;border-radius:5px}
.popup-close:hover{background:var(--bg3);color:var(--text)}
.popup-body{padding:14px 16px}
.field-row{display:flex;align-items:center;padding:9px 0;border-bottom:1px solid var(--border2)}.field-row:last-child{border-bottom:none}
.field-icon{width:32px;font-size:.95rem;flex-shrink:0}.field-label{width:70px;font-size:.72rem;color:var(--muted)}
.field-value{flex:1;font-size:.88rem;font-weight:600;color:var(--text)}.field-value.big{font-size:1rem;color:var(--blue)}
.badge-fonte{display:inline-block;padding:1px 6px;border-radius:4px;font-size:.68rem;font-weight:700;margin-left:6px}
.fonte-leads{background:#0d4a1e;color:#3fb950}.fonte-mbilling{background:#0c2d6b;color:#58a6ff}
.nao-cad{display:inline-block;background:var(--orange-bg);color:var(--orange);border-radius:4px;padding:1px 5px;font-size:.68rem;margin-left:4px}
.popup-footer{padding:12px 16px;border-top:1px solid var(--border2);display:flex;gap:8px}
.popup-footer .btn{flex:1;justify-content:center}.btn-fechar{background:var(--bg3);color:var(--muted);border:1px solid var(--border2)}
.ult-grid{display:flex;gap:20px;flex-wrap:wrap}
.ult-campo .lbl{font-size:.7rem;color:var(--muted);margin-bottom:2px}.ult-campo .val{font-size:.88rem;font-weight:600}
#log{font-size:.76rem;color:var(--muted);max-height:200px;overflow-y:auto}
#log::-webkit-scrollbar{width:4px}#log::-webkit-scrollbar-thumb{background:var(--border);border-radius:2px}
.log-item{padding:5px 8px;border-bottom:1px solid var(--border2);display:flex;gap:8px}
.log-time{color:#484f58;flex-shrink:0;font-size:.7rem;padding-top:1px}
</style>
</head>
<body>

<div id="popup-overlay">
  <div id="popup-box">
    <div class="popup-header">
      <div class="popup-avatar">📋</div>
      <div class="popup-meta"><h3>Cliente em Linha</h3><p id="pop-ts">—</p></div>
      <button class="popup-close" onclick="fecharPopup()">✕</button>
    </div>
    <div class="popup-body">
      <div class="field-row"><span class="field-icon">👤</span><span class="field-label">Nome</span><span class="field-value big" id="pop-nome">—</span></div>
      <div class="field-row"><span class="field-icon">📱</span><span class="field-label">Telefone</span><span class="field-value" id="pop-tel">—</span></div>
      <div class="field-row"><span class="field-icon">🪪</span><span class="field-label">CPF</span><span class="field-value" id="pop-cpf">—</span></div>
      <div class="field-row"><span class="field-icon">📍</span><span class="field-label">Estado</span><span class="field-value" id="pop-estado">—</span></div>
    </div>
    <div class="popup-footer"><button class="btn btn-fechar" onclick="fecharPopup()">Fechar</button></div>
  </div>
</div>

<div class="header">
  <h1>📞 Painel do Atendente — MagnusBilling</h1>
  <div class="badge" id="badge"><span class="led off" id="led"></span><span id="badge-txt">Offline</span></div>
</div>

<div class="main">
  <div class="sidebar">
    <div class="card">
      <div class="card-title">⚙️ Configuração</div>
      <label>Ramal SIP *</label><input id="cfg-ramal" value="1001" placeholder="Número do ramal">
      <label>Senha SIP (opcional)</label><input id="cfg-pass" type="password" placeholder="Deixe vazio → só Screen Pop">
      <label>Servidor</label><input id="cfg-host" value="${SERVER_IP}">
      <button class="btn btn-green btn-full" style="margin-top:12px" onclick="conectar()">🔌 Conectar</button>
      <div id="sipst">Aguardando configuração...</div>
    </div>
    <div class="card">
      <div class="card-title">☎️ Discagem Manual</div>
      <label>Número</label><input id="num-discar" type="tel" placeholder="5585999887766">
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
  <div class="content">
    <div class="card" id="ult-card" style="display:none">
      <div class="card-title">📋 Último Atendimento</div>
      <div class="ult-grid">
        <div class="ult-campo"><div class="lbl">Nome</div><div class="val" id="ult-nome">—</div></div>
        <div class="ult-campo"><div class="lbl">Telefone</div><div class="val" id="ult-tel">—</div></div>
        <div class="ult-campo"><div class="lbl">CPF</div><div class="val" id="ult-cpf">—</div></div>
        <div class="ult-campo"><div class="lbl">Estado</div><div class="val" id="ult-estado">—</div></div>
        <div class="ult-campo"><div class="lbl">Horário</div><div class="val" id="ult-hora">—</div></div>
      </div>
    </div>
    <div class="card" style="flex:1">
      <div class="card-title">📜 Histórico da Sessão</div>
      <div id="log">Nenhuma chamada ainda.</div>
    </div>
  </div>
</div>

<script src="/webphone/jssip.min.js"></script>
<script>
const WS_POP = '${WS_POP}';
const WS_SIP = '${WS_SIP}';
let wsPop=null,ua=null,sess=null,mutado=false,seg=0,timerInt=null;

function conectarPop(ramal) {
  if (wsPop) { try{wsPop.close();}catch(e){} }
  wsPop = new WebSocket(WS_POP);
  wsPop.onopen = () => {
    wsPop.send(JSON.stringify({type:'registrar',ramal:String(ramal)}));
    setStatus('online');
  };
  wsPop.onmessage = e => { try{const d=JSON.parse(e.data);if(d.type==='screenpop')mostrarPopup(d);}catch(e){} };
  wsPop.onclose = () => { setStatus('offline'); setTimeout(()=>conectarPop(document.getElementById('cfg-ramal').value),5000); };
}

function mostrarPopup(d) {
  const fc={leads:'fonte-leads',mbilling:'fonte-mbilling'}[d.fonte]||'';
  const fl={leads:'Lead',mbilling:'Magnus'}[d.fonte]||'';
  document.getElementById('pop-ts').textContent=d.data+' '+d.hora;
  document.getElementById('pop-nome').innerHTML=(d.nome||'—')+(fl?\`<span class="badge-fonte \${fc}">\${fl}</span>\`:'')+(d.encontrado?'':'<span class="nao-cad">Novo</span>');
  document.getElementById('pop-tel').textContent=d.telefone||'—';
  document.getElementById('pop-cpf').textContent=d.cpf||'—';
  document.getElementById('pop-estado').textContent=d.estado||'—';
  document.getElementById('popup-overlay').classList.add('show');
  document.getElementById('ult-card').style.display='block';
  document.getElementById('ult-nome').textContent=d.nome||'—';
  document.getElementById('ult-tel').textContent=d.telefone||'—';
  document.getElementById('ult-cpf').textContent=d.cpf||'—';
  document.getElementById('ult-estado').textContent=d.estado||'—';
  document.getElementById('ult-hora').textContent=d.hora||'—';
  if(Notification.permission==='granted')
    new Notification('📞 '+(d.nome||'Chamada'),{body:'Tel: '+(d.telefone||'—')+' | CPF: '+(d.cpf||'—')+' | '+(d.estado||'—')});
  addLog('📋 '+(d.nome||d.telefone)+(d.encontrado?' ✓':' (novo)'));
}

function fecharPopup(){document.getElementById('popup-overlay').classList.remove('show');}
document.getElementById('popup-overlay').addEventListener('click',e=>{if(e.target.id==='popup-overlay')fecharPopup();});

function setStatus(s){
  document.getElementById('badge').className='badge '+s;
  const c={online:['led on','🟢 Online'],chamada:['led ring','🟠 Em chamada'],offline:['led off','🔴 Offline']}[s]||['led off','🔴 Offline'];
  document.getElementById('led').className=c[0];
  document.getElementById('badge-txt').textContent=c[1];
}

function conectar() {
  const ramal=document.getElementById('cfg-ramal').value.trim();
  const pass =document.getElementById('cfg-pass').value.trim();
  const host =document.getElementById('cfg-host').value.trim();
  if (!ramal){alert('Informe o ramal');return;}
  Notification.requestPermission();
  conectarPop(ramal);
  if (!pass){setSip('✅ Screen Pop ativo — atenda pelo MicroSIP');return;}
  if(ua){try{ua.stop();}catch(e){}}
  const sk=new JsSIP.WebSocketInterface(WS_SIP);
  ua=new JsSIP.UA({sockets:[sk],uri:'sip:'+ramal+'@'+host,password:pass,register:true});
  ua.on('registered',()=>setSip('✅ Registrado — pronto para atender'));
  ua.on('unregistered',()=>setSip('⚠️ Desregistrado'));
  ua.on('registrationFailed',e=>setSip('❌ Falha: '+e.cause));
  ua.on('newRTCSession',e=>{
    sess=e.session;
    addLog((e.originator==='remote'?'📲 Entrada':'📤 Saída')+': '+(sess.remote_identity?.uri?.user||'?'));
    sess.on('accepted',()=>{iniciarTimer();setStatus('chamada');document.getElementById('btn-desl').style.display='inline-flex';document.getElementById('btn-ligar').style.display='none';});
    sess.on('ended',()=>{pararTimer();resetUI();fecharPopup();});
    sess.on('failed',()=>{pararTimer();resetUI();});
    if(e.originator==='remote')sess.answer({mediaConstraints:{audio:true,video:false}});
  });
  ua.start();setSip('🔄 Conectando SIP...');
}

function ligar(){const n=document.getElementById('num-discar').value.trim(),h=document.getElementById('cfg-host').value.trim();if(!n||!ua)return;ua.call('sip:'+n+'@'+h,{mediaConstraints:{audio:true,video:false}});}
function desligar(){sess?.terminate();}
function mute(){if(!sess)return;mutado?sess.unmute({audio:true}):sess.mute({audio:true});mutado=!mutado;document.querySelector('.btn-mute').textContent=mutado?'🔊 Unmute':'🔇 Mute';}
function iniciarTimer(){seg=0;timerInt=setInterval(()=>{seg++;const m=String(Math.floor(seg/60)).padStart(2,'0'),s=String(seg%60).padStart(2,'0');document.getElementById('timer').textContent=m+':'+s;},1000);}
function pararTimer(){clearInterval(timerInt);document.getElementById('timer').textContent='00:00';}
function resetUI(){setStatus('online');document.getElementById('btn-desl').style.display='none';document.getElementById('btn-ligar').style.display='inline-flex';}
function setSip(t){document.getElementById('sipst').textContent=t;}
function addLog(txt){const el=document.getElementById('log'),h=new Date().toLocaleTimeString('pt-BR');if(el.textContent==='Nenhuma chamada ainda.')el.innerHTML='';el.innerHTML='<div class="log-item"><span class="log-time">'+h+'</span><span>'+txt+'</span></div>'+el.innerHTML;}
</script>
</body>
</html>
EOHTML
ok "Interface web criada"

# ══════════════════════════════════════════════════════════════════
# ETAPA 7 — Apache
# ══════════════════════════════════════════════════════════════════
passo "7" "Configurando Apache..."
a2enmod ssl rewrite proxy proxy_http proxy_wstunnel headers >> /dev/null 2>&1

if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
  cat > /etc/apache2/sites-available/mbilling-ssl.conf << EOF
<VirtualHost *:443>
  ServerName ${DOMAIN}
  DocumentRoot /var/www/html
  SSLEngine on
  SSLCertificateFile /etc/letsencrypt/live/${DOMAIN}/fullchain.pem
  SSLCertificateKeyFile /etc/letsencrypt/live/${DOMAIN}/privkey.pem
  Alias /webphone /var/www/html/webphone
  <Directory /var/www/html/webphone>
    Options -Indexes
    AllowOverride None
    Require all granted
  </Directory>
  ProxyPass /ws ws://127.0.0.1:8088/ws
  ProxyPassReverse /ws ws://127.0.0.1:8088/ws
  ProxyPass /screenpop ws://127.0.0.1:4000
  ProxyPassReverse /screenpop ws://127.0.0.1:4000
</VirtualHost>
<VirtualHost *:80>
  ServerName ${DOMAIN}
  RewriteEngine On
  RewriteRule ^(.*)$ https://${DOMAIN}\$1 [R=301,L]
</VirtualHost>
EOF
  a2ensite mbilling-ssl.conf >> /dev/null 2>&1
  ok "Apache HTTPS configurado"
else
  cat > /etc/apache2/conf-available/webphone.conf << EOF
Alias /webphone /var/www/html/webphone
<Directory /var/www/html/webphone>
  Options -Indexes
  AllowOverride None
  Require all granted
</Directory>
EOF
  a2enconf webphone >> /dev/null 2>&1
  ok "Apache HTTP configurado"
fi

chown -R www-data:www-data "${WEB_DIR}" 2>/dev/null || chown -R asterisk:asterisk "${WEB_DIR}"
service apache2 restart >> /dev/null 2>&1
ok "Apache reiniciado"

# ══════════════════════════════════════════════════════════════════
# ETAPA 8 — Firewall
# ══════════════════════════════════════════════════════════════════
passo "8" "Liberando portas..."
iptables -I INPUT -p tcp --dport 4000 -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p tcp --dport 8088 -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p tcp --dport 8089 -j ACCEPT 2>/dev/null || true
netfilter-persistent save 2>/dev/null || iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
ufw allow 4000/tcp 2>/dev/null || true
ufw allow 8088/tcp 2>/dev/null || true
ufw allow 8089/tcp 2>/dev/null || true
ok "Portas liberadas"

# ══════════════════════════════════════════════════════════════════
# ETAPA 9 — Iniciar
# ══════════════════════════════════════════════════════════════════
passo "9" "Iniciando Screen Pop..."
cd "${SP_DIR}"
pm2 delete webphone-screenpop 2>/dev/null || true
pm2 start server.js --name webphone-screenpop
pm2 save
env PATH=$PATH:/usr/bin pm2 startup systemd -u root --hp /root >> /dev/null 2>&1 || true
sleep 4
pm2 logs webphone-screenpop --lines 6 --nostream 2>/dev/null || true
ok "Screen Pop iniciado"

# ══════════════════════════════════════════════════════════════════
# RESUMO
# ══════════════════════════════════════════════════════════════════
clear
echo -e "${G}${W}"
cat << 'EOF'
  ╔══════════════════════════════════════════════════════════════╗
  ║   ✔  WEBPHONE + SCREEN POP v2 INSTALADO!                    ║
  ╚══════════════════════════════════════════════════════════════╝
EOF
echo -e "${N}"

if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
  echo -e "  ${W}ACESSO:${N} https://${DOMAIN}/webphone/"
else
  echo -e "  ${W}ACESSO:${N} http://${SERVER_IP}/webphone/"
  echo -e ""
  echo -e "  ${Y}Para HTTPS (recomendado):${N}"
  echo -e "  apt install -y certbot python3-certbot-apache"
  echo -e "  certbot --apache -d ${DOMAIN} -m email@dominio.com --agree-tos"
fi

echo -e ""
echo -e "  ${W}COMO USAR:${N}"
echo -e "  1. Abra o painel no navegador"
echo -e "  2. Digite o ramal (ex: 41795) → clique Conectar"
echo -e "  3. Deixe a senha em branco → Screen Pop apenas (atende pelo MicroSIP)"
echo -e "  4. Quando cliente pressionar 1 → popup abre automaticamente"
echo -e ""
echo -e "  ${W}DADOS DO POPUP vêm de:${N} pkg_phonenumber (MagnusBilling)"
echo -e "  Campos: name (nome) | doc (CPF) | city (estado)"
echo -e ""
echo -e "  ${W}LOGS:${N} pm2 logs webphone-screenpop"
echo -e ""
