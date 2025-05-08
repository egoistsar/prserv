#!/usr/bin/env bash
# install.sh — интерактивная установка/удаление SOCKS5 прокси (Dante)
# Все read читают ввод из /dev/tty, скрипт может запускаться через curl | bash

set -euo pipefail
IFS=$'\n\t'
LOGFILE=/var/log/s5proxy_install.log
TIMEOUT=300
ACTION="install"  # Значение по умолчанию

# Перевод сообщений
function t() {
  local en="$1"; shift
  local ru="$1"; shift
  [[ "${LANGUAGE:-en}" == "ru" ]] && echo -e "$ru" || echo -e "$en"
}

# Лог
function log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"
}

function die() {
  log "ERROR: $*"
  exit 1
}

# Проверки
function check_root() {
  [[ $EUID -eq 0 ]] || die "Нужно запустить от root"
}

function detect_os() {
  [[ -f /etc/os-release ]] || die "/etc/os-release не найден"
  source /etc/os-release
  if [[ -z "${PRETTY_NAME:-}" ]]; then
    log "PRETTY_NAME не найден. ID: ${ID:-unknown}, VERSION_ID: ${VERSION_ID:-unknown}"
  fi
  case "${ID:-}" in
    debian|ubuntu) ;; *) die "Поддерживаются только Debian/Ubuntu (ваша: $ID)";;
  esac
}

# Интерфейс
function ask_language() {
  echo; echo "$(t "Select language:" "Выберите язык:")"
  echo "  1) English"; echo "  2) Русский"
  read -t $TIMEOUT -rp "$(t "Enter [1-2]:" "Введите [1-2]:") " choice </dev/tty || die "Timeout or no input received for language selection"
  case "$choice" in 2) LANGUAGE=ru ;; *) LANGUAGE=en ;; esac
}

function ask_action() {
  echo; echo "$(t "Select action:" "Выберите действие:")"
  echo "  1) Install SOCKS5 proxy server"; echo "  2) Uninstall SOCKS5 proxy server"
  local input
  read -t $TIMEOUT -rp "$(t "Enter [1-2]:" "Введите [1-2]:") " input </dev/tty || die "Timeout or no input received for action selection"
  case "$input" in
    1) ACTION="install" ;;
    2) ACTION="uninstall" ;;
    *) die "Invalid action selected: $input" ;;
  esac
}

function ask_port() {
  local default=1080
  read -t $TIMEOUT -rp "$(t "Enter port [${default}]:" "Введите порт [${default}]:") " PORT </dev/tty || die "Timeout or no input received for port"
  PORT=${PORT:-$default}
  [[ "$PORT" =~ ^[0-9]+$ ]] || die "Неверный порт: $PORT"
}

function ask_credentials() {
  read -t $TIMEOUT -rp "$(t "Enter username:" "Введите имя пользователя:") " USER </dev/tty || die "Timeout or no input received for username"
  read -s -t $TIMEOUT -rp "$(t "Enter password:" "Введите пароль:") " PASS </dev/tty || die "Timeout or no input received for password"
  echo; [[ -n "$USER" && -n "$PASS" ]] || die "Логин и пароль не могут быть пустыми"
}

# Установка
function install_packages() {
  log "Installing packages..."
  apt-get update -y
  apt-get install -y dante-server libpam-pwdfile iptables
}

function detect_interface() {
  IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '/dev/ {for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}')
  IFACE=${IFACE:-eth0}; log "Using interface: $IFACE"
}

function write_dante_conf() {
  log "Writing /etc/dante.conf"
  if ! touch /etc/dante.conf 2>/dev/null; then
    die "Cannot write to /etc/dante.conf. Check permissions or file system."
  fi
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
  if systemctl enable dante-server.service; then
    if systemctl is-enabled dante-server.service >/dev/null; then
      log "Service successfully enabled for autostart"
    else
      log "Warning: service enable command completed but service is not enabled"
    fi
  else
    die "Failed to enable dante-server.service"
  fi
}

function setup_pam() {
  log "Configuring PAM"
  mkdir -p /etc/dante-users; touch /etc/dante-users/users.pwd
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
  echo; echo "╔════════════════════════════════════════╗"
  echo "║         SOCKS5 Proxy Details          ║"
  echo "╠════════════════════════════════════════╣"
  echo "║ Server:   $ip"; echo "║ Port:     $PORT"
  echo "║ Username: $USER"; echo "║ Password: $PASS"
  echo "╚════════════════════════════════════════╝"; echo
}

function uninstall_all() {
  log "Uninstalling proxy..."

  log "Stopping service..."
  if systemctl stop dante-server.service 2>/dev/null; then log "Service stopped"; else log "Service stop failed or not running"; fi

  log "Disabling service..."
  if systemctl disable dante-server.service 2>/dev/null; then log "Service disabled"; else log "Service disable failed or not enabled"; fi

  log "Removing packages..."
  if apt-get purge --auto-remove -y dante-server libpam-pwdfile; then log "Packages removed"; else log "Package removal failed"; fi

  log "Deleting /etc/dante.conf..."
  if rm -f /etc/dante.conf; then log "/etc/dante.conf deleted"; else log "No /etc/dante.conf to delete"; fi

  log "Deleting /etc/dante-users and PAM config..."
  if rm -rf /etc/dante-users /etc/pam.d/sockd; then log "User data and PAM config deleted"; else log "User data or PAM config not found"; fi

  log "Deleting systemd service file..."
  if rm -f /etc/systemd/system/dante-server.service; then log "Service file deleted"; else log "Service file not found"; fi

  systemctl daemon-reload
  log "Systemd daemon reloaded"
}

# Main
check_root; detect_os; ask_language; ask_action
if [[ "$ACTION" == "install" ]]; then
  ask_port; ask_credentials; install_packages; detect_interface
  write_dante_conf; write_systemd_service; setup_pam; configure_firewall
  add_proxy_user; systemctl start dante-server.service; show_info
else
  uninstall_all
fi
