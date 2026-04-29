# 📞 Discadora MagnusBilling — Instalação no Debian 11

Sistema de discagem automática baseado no **MagnusBilling 7** com Asterisk, painel web completo, URA, filas de atendimento e gestão de trunks SIP.

---

## ✅ Requisitos

| Item | Valor |
|---|---|
| Sistema Operacional | **Debian 11 (Bullseye) 64-bit — instalação mínima** |
| CPU | Mínimo 2 vCPUs (4 recomendado) |
| RAM | Mínimo 4 GB (8 GB recomendado) |
| Disco | Mínimo 40 GB SSD |
| Rede | IP fixo |
| Acesso | Root ou sudo |

> ⚠️ **Importante:** Use sempre uma instalação **limpa e mínima** do Debian 11. Não instale em servidores com outros serviços rodando.

---

## 🚀 Instalação

### 1. Acesse o servidor como root

```bash
sudo su -
```

---

### 2. Atualize o sistema

```bash
apt-get update && apt-get upgrade -y
```

---

### 3. Baixe e execute o instalador

```bash
wget -O install.sh https://raw.githubusercontent.com/atendimento0008/discadora/main/install.sh
bash install.sh br
```

> O parâmetro `br` instala com idioma **Português do Brasil** e sons em PT-BR.

---

### 4. Aguarde a instalação

O processo instala automaticamente:

- ✔ Asterisk (PBX)
- ✔ Apache + PHP
- ✔ MySQL / MariaDB
- ✔ MagnusBilling 7
- ✔ Sons em Português do Brasil
- ✔ IPTables + Fail2ban

> ⏱️ Tempo estimado: **15 a 30 minutos** dependendo da velocidade do servidor.

---

### 5. Reiniciar o servidor

Ao final da instalação, reinicie:

```bash
reboot
```

---

### 6. Acessar o painel

Após reiniciar, acesse pelo navegador:

```
http://IP_DO_SEU_SERVIDOR/
```

**Credenciais padrão:**

| Campo | Valor |
|---|---|
| Usuário | `root` |
| Senha | `magnus` |

> 🔒 **Troque a senha** imediatamente após o primeiro acesso em: **Admin → Usuários → root → Editar**

---

## 🌐 Portas que devem estar liberadas no firewall

| Porta | Protocolo | Função |
|---|---|---|
| 22 | TCP | SSH |
| 80 | TCP | Painel Web HTTP |
| 443 | TCP | Painel Web HTTPS |
| 5060 | UDP | SIP |
| 5060 | TCP | SIP TCP |
| 10000–20000 | UDP | RTP (áudio das chamadas) |

---

## ⚙️ Configuração básica após instalar

### Passo 1 — Cadastrar Trunk SIP

1. Acesse **Admin → Trunks**
2. Clique em **Adicionar**
3. Preencha os dados da sua operadora SIP:
   - **Nome:** nome da operadora
   - **Host:** endereço SIP da operadora
   - **Usuário / Senha:** credenciais fornecidas pela operadora

---

### Passo 2 — Criar Ramais dos Atendentes

1. Acesse **Admin → Usuários SIP**
2. Clique em **Adicionar**
3. Defina número do ramal e senha
4. Configure o softphone (MicroSIP ou WebPhone) com:
   - **Servidor:** IP do seu servidor
   - **Usuário:** número do ramal
   - **Senha:** senha definida

---

### Passo 3 — Criar Campanha de Discagem

1. Acesse **Admin → Campanhas**
2. Clique em **Adicionar**
3. Defina:
   - Nome da campanha
   - Trunk SIP a usar
   - Fila de atendimento
   - Áudio da URA
4. Importe a lista de contatos (CSV)
5. Inicie a campanha

---

## 🔊 Sons em Português do Brasil

Os sons PT-BR são instalados automaticamente. Para reinstalar manualmente:

```bash
cd /var/lib/asterisk/sounds
wget https://raw.githubusercontent.com/atendimento0008/discadora/main/Disc-OS-Sounds-1.0-pt_BR.tar.gz
tar -xzf Disc-OS-Sounds-1.0-pt_BR.tar.gz
```

---

## 🛠️ Comandos úteis

```bash
# Ver status do Asterisk
asterisk -rx "core show version"

# Verificar ramais registrados
asterisk -rx "sip show peers"

# Reiniciar Asterisk
service asterisk restart

# Reiniciar Apache
service apache2 restart

# Verificar logs do Asterisk
tail -f /var/log/asterisk/messages

# Acessar console do Asterisk
asterisk -rvvvv
```

---

## 🔒 Segurança recomendada

- [ ] Troque a senha padrão `magnus` imediatamente
- [ ] Restrinja acesso SSH por IP
- [ ] Use senhas fortes nos ramais SIP (mínimo 12 caracteres)
- [ ] Configure o Fail2ban (já instalado automaticamente)
- [ ] Limite o acesso ao painel web por IP se possível

---

## ❓ Problemas comuns

**Painel não abre após instalar:**
```bash
service apache2 restart
service mysql restart
```

**Asterisk não inicia:**
```bash
service asterisk restart
tail -f /var/log/asterisk/messages
```

**Ramal não registra:**
- Verifique se a porta 5060 UDP está aberta no firewall
- Confirme usuário e senha no softphone

---

## 📄 Licença

Este projeto é baseado no [MagnusBilling](https://github.com/magnussolution/magnusbilling7) — software open source sob licença GPL v3.

---

> Desenvolvido por **atendimento0008** — [github.com/atendimento0008](https://github.com/atendimento0008)
