# Вдохновлено логикой инсталлятора TorrServer (YouROK/TorrServer)
#!/usr/bin/env bash
#
# install.sh — автоматизированная без-интерактивная установка/удаление SOCKS5 прокси (Dante)
# По образцу YouROK/TorrServer: работает через один пайп и без read
#

set -euo pipefail
IFS=$'\n\t'

LOGFILE=/var/log/s5proxy_install.log

# Параметры по-умолчанию
PORT=1080
USER=proxy
PASS=proxy
ACTION=install  # install или uninstall

# ======== Парсинг опций ========
usage() {
  cat <<EOF
Usage: $0 [options]

  -p PORT       Порт для SOCKS5 (default: $PORT)
  -u USER       Логин прокси (default: $USER)
  -P PASS       Пароль прокси (default: $PASS)
  -r            Удалить установленный прокси (uninstall mode)
  -h            Показать это сообщение

Examples:
  curl -fsSL https://.../install.sh | sudo bash
  curl -fsSL https://.../install.sh | sudo bash -s -- -p 1341 -u alice -P s3cr3t
  curl -fsSL https://.../install.sh | sudo bash -s -- -r

EOF
  exit 1
}

# Если скрипт запускают через пайп, параметры идут через '-s --'
if [[ "${1:-}" == "-h" ]]; then
  usage
fi

while getopts "p:u:P:rh" opt; do
  case "$opt" in
    p) PORT=$OPTARG ;;
    u) USER=$OPTARG ;;
    P) PASS=$OPTARG ;;
    r) ACTION=uninstall ;;
    h|*) usage ;;
  esac
done

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"
}

die() {
  log "ERROR: $*"
  exit 1
}

check_root() {
  [[ $EUID -eq 0 ]] || die "Требуется root-доступ"
}

detect_os() {
  [[ -f /etc/os-release ]] || die "/etc/os-release не найден"
  source /etc/os-release
  case "$ID" in
    debian|ubuntu) ;;
    *) die "Только Debian/Ubuntu поддерживается (текущий: $ID)";;
  esac
  log "OS: $PRETTY_NAME"
}

install_packages() {
  log "Обновляем пакеты и устанавливаем Dante"
  apt-get update -y
  apt-get install -y dante-server libpam-pwdfile iptables
}

detect_interface() {
  IFACE=$(ip route get 8.8.8.8 | awk '/dev/{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}')
  IFACE=${IFACE:-eth0}
  log "Интерфейс: $IFACE"
}

write_dante_conf() {
  log "Пишем /etc/dante.conf"
  cat > /etc/dante.conf <<EOF
logoutput: syslog
internal: $IFACE port = $PORT
external: $IFACE
method: pam
user.privileged: root
user.unprivileged: nobody

client pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  log: connect error
}

pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  protocol: tcp udp
  log: connect error
}
EOF
}

write_systemd_service() {
  BIN=$(command -v sockd)
  log "Создаём unit-файл systemd"
  cat > /etc/systemd/system/dante-server.service <<EOF
[Unit]
Description=Dante SOCKS5 Proxy Server
After=network.target

[Service]
Type=simple
ExecStart=$BIN -f /etc/dante.conf
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable dante-server.service
}

setup_pam() {
  log "Настраиваем PAM"
  mkdir -p /etc/dante-users
  touch /etc/dante-users/users.pwd
  cat > /etc/pam.d/sockd <<EOF
auth required pam_pwdfile.so pwdfile /etc/dante-users/users.pwd
account required pam_permit.so
EOF
  chmod 644 /etc/pam.d/sockd
}

configure_firewall() {
  log "Настраиваем iptables"
  iptables -I INPUT -p tcp --dport 22 -j ACCEPT
  iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
  iptables -I INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
  iptables -P INPUT DROP
}

add_proxy_user() {
  log "Добавляем пользователя $USER"
  HASH=$(openssl passwd -6 "$PASS")
  echo "$USER:$HASH" >> /etc/dante-users/users.pwd
}

show_info() {
  IP=$(hostname -I | awk '{print $1}')
  cat <<EOF

╔════════════════════════════════════╗
║        SOCKS5 Proxy Details       ║
╠════════════════════════════════════╣
║ Server:   $IP
║ Port:     $PORT
║ Username: $USER
║ Password: $PASS
╚════════════════════════════════════╝

EOF
}

uninstall_all() {
  log "Удаляем сервис и пакеты"
  systemctl stop dante-server.service 2>/dev/null || true
  systemctl disable dante-server.service 2>/dev/null || true
  apt-get purge --auto-remove -y dante-server libpam-pwdfile
  rm -f /etc/dante.conf
  rm -rf /etc/dante-users /etc/pam.d/sockd
  rm -f /etc/systemd/system/dante-server.service
  systemctl daemon-reload
  log "Удаление завершено"
}

# ======== Main ========
check_root
detect_os

if [[ "$ACTION" == "install" ]]; then
  install_packages
  detect_interface
  write_dante_conf
  write_systemd_service
  setup_pam
  configure_firewall
  add_proxy_user
  systemctl start dante-server.service
  show_info
else
  uninstall_all
fi
