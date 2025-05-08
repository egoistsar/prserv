# Вдохновлено логикой инсталлятора TorrServer→YouROK/TorrServer
#!/usr/bin/env bash
#
# install.sh — автоматизированная без-интерактивная установка/удаление SOCKS5 прокси (Dante)
# По образцу YouROK/TorrServer: одна команда через curl | bash и работа через флаги
#

set -euo pipefail
IFS=$'\n\t'

LOGFILE=/var/log/s5proxy_install.log

# Параметры по-умолчанию
PORT=1080
USER=proxy
PASS=proxy
ACTION=install  # install или uninstall

# ======== Функции ========
usage() {
  cat <<EOF
Usage: $0 [options]

  -p PORT       Порт для SOCKS5 (default: $PORT)
  -u USER       Логин прокси (default: $USER)
  -P PASS       Пароль прокси (default: $PASS)
  -r            Удалить установленный прокси (uninstall mode)
  -h            Показать это сообщение

Examples:
  # Установка с дефолтными параметрами
  curl -fsSL https://raw.githubusercontent.com/egoistsar/prserv/main/install.sh | sudo bash
  # Установка с кастомным портом, логином и паролем
  curl -fsSL https://raw.githubusercontent.com/egoistsar/prserv/main/install.sh \
    | sudo bash -s -- -p 1341 -u alice -P s3cr3t
  # Полное удаление
  curl -fsSL https://raw.githubusercontent.com/egoistsar/prserv/main/install.sh \
    | sudo bash -s -- -r

EOF
  exit 1
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"
}

die() {
  log "ERROR: $*"
  exit 1
}

check_root() {
  [[ $EUID -eq 0 ]] || die "Нужно запустить от root"
}

detect_os() {
  [[ -f /etc/os-release ]] || die "/etc/os-release не найден — не могу определить ОС"
  source /etc/os-release
  case "$ID" in
    debian|ubuntu) ;;
    *) die "Поддерживаются только Debian/Ubuntu (ваша: $ID)";;
  esac
  log "Detected OS: $PRETTY_NAME"
}

install_packages() {
  log "Updating package lists and installing Dante"
  apt-get update -y
  apt-get install -y dante-server libpam-pwdfile iptables
}

detect_interface() {
  log "Detecting external network interface"
  IFACE=$(ip route get 8.8.8.8 2>/dev/null \
    | awk '/dev/ { for(i=1;i<NF;i++) if($i=="dev") print $(i+1) }')
  IFACE=${IFACE:-eth0}
  log "Using interface: $IFACE"
}

write_dante_conf() {
  log "Writing /etc/dante.conf"
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
  SOCKD_BIN=$(command -v sockd)
  log "Creating systemd unit /etc/systemd/system/dante-server.service"
  cat > /etc/systemd/system/dante-server.service <<EOF
[Unit]
Description=Dante SOCKS5 Proxy Server
After=network.target

[Service]
Type=simple
ExecStart=$SOCKD_BIN -f /etc/dante.conf
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable dante-server.service
}

setup_pam() {
  log "Configuring PAM authentication (pam_pwdfile)"
  mkdir -p /etc/dante-users
  touch /etc/dante-users/users.pwd
  cat > /etc/pam.d/sockd <<EOF
auth required pam_pwdfile.so pwdfile /etc/dante-users/users.pwd
account required pam_permit.so
EOF
  chmod 644 /etc/pam.d/sockd
}

configure_firewall() {
  log "Setting up iptables rules"
  iptables -I INPUT -p tcp --dport 22 -j ACCEPT
  iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
  iptables -I INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
  iptables -P INPUT DROP
}

add_proxy_user() {
  log "Adding proxy user '$USER'"
  HASH=$(openssl passwd -6 "$PASS")
  echo "$USER:$HASH" >> /etc/dante-users/users.pwd
}

show_info() {
  IP=$(hostname -I | awk '{print $1}')
  cat <<EOF

╔════════════════════════════════════════╗
║         SOCKS5 Proxy Details          ║
╠════════════════════════════════════════╣
║ Server:   $IP
║ Port:     $PORT
║ Username: $USER
║ Password: $PASS
╚════════════════════════════════════════╝

EOF
}

uninstall_all() {
  log "Stopping and disabling Dante service"
  systemctl stop dante-server.service 2>/dev/null || true
  systemctl disable dante-server.service 2>/dev/null || true

  log "Removing packages and configurations"
  apt-get purge --auto-remove -y dante-server libpam-pwdfile
  rm -f /etc/dante.conf
  rm -rf /etc/dante-users /etc/pam.d/sockd
  rm -f /etc/systemd/system/dante-server.service
  systemctl daemon-reload

  log "Uninstallation complete"
}

# ======== Основной блок ========
# Разбор опций (при запуске через pipe => параметры передаются через -s --)
while getopts "p:u:P:rh" opt; do
  case "$opt" in
    p) PORT=$OPTARG ;;
    u) USER=$OPTARG ;;
    P) PASS=$OPTARG ;;
    r) ACTION=uninstall ;;
    h|*) usage ;;
  esac
done

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
