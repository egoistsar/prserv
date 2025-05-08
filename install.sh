#!/usr/bin/env bash
#_install.sh — интерактивная установка/удаление SOCKS5 прокси (Dante)
#   Все read читают ввод из /dev/tty, чтобы при "curl | bash" диалоги работали корректно

set -euo pipefail
IFS=$'\n\t'
LOGFILE=/var/log/s5proxy_install.log
TIMEOUT=300

# Локализация сообщений
function t() {
  local en="$1"; shift
  local ru="$1"; shift
  [[ "${LANGUAGE:-en}" == "ru" ]] && echo -e "$ru" || echo -e "$en"
}

# Логирование
function log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"
}

function die() {
  log "ERROR: $*"
  exit 1
}

function check_root() {
  [[ $EUID -eq 0 ]] || die "Нужно запустить от root"
}

function detect_os() {
  [[ -f /etc/os-release ]] || die "/etc/os-release не найден"
  source /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ;;
    *) die "Поддерживаются только Debian/Ubuntu (ваша: $ID)";;
  esac
}

# Выбор языка
function ask_language() {
  echo
  echo "$(t "Select language:" "Выберите язык:")"
  echo "  1) English"
  echo "  2) Русский"
  read -t $TIMEOUT -rp "$(t "Enter [1-2]:" "Введите [1-2]:") " choice </dev/tty || choice=1
  case "$choice" in
    2) LANGUAGE=ru ;; * ) LANGUAGE=en ;;
  esac
}

# Выбор действия
function ask_action() {
  echo
  echo "$(t "Select action:" "Выберите действие:")"
  echo "  1) Install SOCKS5 proxy server"
  echo "  2) Uninstall SOCKS5 proxy server"
  read -t $TIMEOUT -rp "$(t "Enter [1-2]:" "Введите [1-2]:") " action_choice </dev/tty || action_choice=1
  case "$action_choice" in
    1) ACTION=install ;; 2) ACTION=uninstall ;; * ) ACTION=install ;;
  esac
}

# Запрос порта
function ask_port() {
  local default=1080
  read -t $TIMEOUT -rp "$(t "Enter port [${default}]:" "Введите порт [${default}]:") " PORT </dev/tty
  PORT=${PORT:-$default}
  [[ "$PORT" =~ ^[0-9]+$ ]] || die "Неверный порт: $PORT"
}

# Запрос учётных данных
function ask_credentials() {
  read -t $TIMEOUT -rp "$(t "Enter username:" "Введите имя пользователя:") " USER </dev/tty
  read -s -t $TIMEOUT -rp "$(t "Enter password:" "Введите пароль:") " PASS </dev/tty
  echo
  [[ -n "$USER" && -n "$PASS" ]] || die "Логин и пароль не могут быть пустыми"
}

# Основные шаги установки
function install_packages() {
  log "Installing packages..."
  apt-get update -y
  apt-get install -y dante-server libpam-pwdfile iptables
}

function detect_interface() {
  IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '/dev/ {for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}')
  IFACE=${IFACE:-eth0}
  log "Using interface: $IFACE"
}

function write_dante_conf() {
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

function write_systemd_service() {
  local bin=$(command -v sockd)
  log "Creating systemd service"
  cat > /etc/systemd/system/dante-server.service <<EOF
[Unit]
Description=Dante SOCKS5 Proxy Server
After=network.target

[Service]
Type=simple
ExecStart=$bin -f /etc/dante.conf
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable dante-server.service
}

function setup_pam() {
  log "Configuring PAM"
  mkdir -p /etc/dante-users
  touch /etc/dante-users/users.pwd
  cat > /etc/pam.d/sockd <<EOF
auth required pam_pwdfile.so pwdfile /etc/dante-users/users.pwd
account required pam_permit.so
EOF
  chmod 644 /etc/pam.d/sockd
}

function configure_firewall() {
  log "Configuring iptables"
  iptables -I INPUT -p tcp --dport 22 -j ACCEPT
  iptables -I INPUT -p tcp --dport $PORT -j ACCEPT
  iptables -I INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
  iptables -P INPUT DROP
}

function add_proxy_user() {
  log "Adding proxy user $USER"
  local hash=$(openssl passwd -6 "$PASS")
  echo "$USER:$hash" >> /etc/dante-users/users.pwd
}

function show_info() {
  local ip=$(hostname -I | awk '{print $1}')
  echo
  echo "╔════════════════════════════════════════╗"
  echo "║         SOCKS5 Proxy Details          ║"
  echo "╠════════════════════════════════════════╣"
  echo "║ Server:   $ip"
  echo "║ Port:     $PORT"
  echo "║ Username: $USER"
  echo "║ Password: $PASS"
  echo "╚════════════════════════════════════════╝"
  echo
}

function uninstall_all() {
  log "Uninstalling proxy..."
  systemctl stop dante-server.service 2>/dev/null || true
  systemctl disable dante-server.service 2>/dev/null || true
  apt-get purge --auto-remove -y dante-server libpam-pwdfile
  rm -f /etc/dante.conf
  rm -rf /etc/dante-users /etc/pam.d/sockd
  rm -f /etc/systemd/system/dante-server.service
  systemctl daemon-reload
}

# ======== Main ========
check_root
detect_os
ask_language
ask_action

if [[ "$ACTION" == "install" ]]; then
  ask_port
  ask_credentials
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
