#!/usr/bin/env bash
set -euo pipefail

# ===== Kali Network "Factory Reset" =====
# O que faz:
# - Backup de perfis do NetworkManager, DNS e firewall
# - Remove perfis (.nmconnection) e estado do NM
# - Restaura resolv.conf para ser gerido pelo NetworkManager
# - Limpa regras do nftables (firewall)
# - Reinicia/religa a pilha de rede pelo NetworkManager

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Este script precisa ser executado como root." >&2
    exit 1
  fi
}

log() { printf "\n[%s] %s\n" "$(date +%T)" "$*"; }
ok()  { printf "[OK] %s\n" "$*"; }
warn(){ printf "[AVISO] %s\n" "$*"; }
die() { printf "[ERRO] %s\n" "$*" >&2; exit 1; }

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

need_root

# Checagens básicas
SERVICE_NAME="NetworkManager"
if ! systemctl list-unit-files | grep -q "^${SERVICE_NAME}\.service"; then
  die "NetworkManager não encontrado. Este reset foi feito para sistemas com NetworkManager."
fi

# Pastas/arquivos
NM_CONN_DIR="/etc/NetworkManager/system-connections"
NM_STATE="/var/lib/NetworkManager/NetworkManager.state"
BACKUP_DIR="/root/kali-netreset-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

log "1/7 Backup do estado atual em $BACKUP_DIR"
# Backup de perfis do NM
if [[ -d "$NM_CONN_DIR" ]]; then
  tar -C / -czf "$BACKUP_DIR/system-connections.tgz" "${NM_CONN_DIR#/}" 2>/dev/null || true
fi
# Backup do resolv.conf (conteúdo + info de link)
if [[ -e /etc/resolv.conf ]]; then
  cp -aL /etc/resolv.conf "$BACKUP_DIR/resolv.conf.backup" || true
  ls -l /etc/resolv.conf > "$BACKUP_DIR/resolv.conf.ls" || true
fi
# Backup do firewall (nftables) e rotas/ips
if cmd_exists nft; then
  nft list ruleset > "$BACKUP_DIR/nft-ruleset.txt" 2>/dev/null || true
fi
if cmd_exists iptables-save; then
  iptables-save > "$BACKUP_DIR/iptables-save.txt" 2>/dev/null || true
fi
ip addr > "$BACKUP_DIR/ip-addr.txt" 2>/dev/null || true
ip route > "$BACKUP_DIR/ip-route.txt" 2>/dev/null || true
ok "Backup concluído"

log "2/7 Parando o NetworkManager"
systemctl stop NetworkManager

log "3/7 Limpando perfis salvos (.nmconnection)"
if [[ -d "$NM_CONN_DIR" ]]; then
  rm -f "$NM_CONN_DIR"/*.nmconnection 2>/dev/null || true
fi

log "4/7 Zerando o arquivo de estado do NetworkManager"
rm -f "$NM_STATE" 2>/dev/null || true

log "5/7 Reset do DNS: restaurando /etc/resolv.conf para o NM"
rm -f /etc/resolv.conf 2>/dev/null || true
# Link apontando para o resolv.conf gerido pelo NM em runtime
ln -s /run/NetworkManager/resolv.conf /etc/resolv.conf

log "6/7 Limpando firewall (nftables)"
if cmd_exists nft; then
  nft flush ruleset 2>/dev/null || true
else
  warn "nft não encontrado; ignorando flush do firewall."
fi

log "7/7 Iniciando o NetworkManager e religando a rede"
systemctl start NetworkManager
# Garante que a pilha de rede está "on"
if cmd_exists nmcli; then
  nmcli networking on || true
  nmcli connection reload || true
  # Tenta reconectar dispositivos desconectados (Ethernet volta sozinha; Wi-Fi precisará refazer SSID/senha)
  while IFS=: read -r dev state; do
    [[ "$state" == "disconnected" ]] && nmcli -g GENERAL.TYPE dev show "$dev" >/dev/null 2>&1 && nmcli dev connect "$dev" || true
  done < <(nmcli -t -f DEVICE,STATE dev 2>/dev/null || true)
else
  warn "nmcli não encontrado; pulei a parte de reconexão assistida."
fi

ok "Reset concluído."
echo
echo "Arquivos de backup: $BACKUP_DIR"
echo "Dica: para Wi-Fi, conecte novamente (GUI ou 'nmcli dev wifi connect <SSID> password <SENHA>')."
