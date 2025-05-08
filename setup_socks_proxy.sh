#!/usr/bin/env bash
#
# setup_socks_proxy.sh — автоматизированная установка/удаление SOCKS5 прокси на базе Dante
# Вдохновлено логикой инсталлятора TorrServer (YouROK/TorrServer)
#

set -euo pipefail
IFS=$'\n\t'

# === Параметры ===
LOGFILE=/var/log/s5proxy_install.log
TIMEOUT=300

# Команды, которые нам понадобятся
REQUIRED_CMDS=(bash curl grep awk systemctl iptables ip route openssl apt-get)

# === Утилиты ===
function log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"
}

function die() {
  log "ERROR: $*"
  exit 1
}

# Проверка наличия команд
function check_deps() {
  for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
      die "Требуется '$cmd', но не найден"
    fi
  done
}

# Проверка, что мы root
function check_root() {
  [[ $EUID -eq 0 ]] || die "Нужно запустить от root"
}

# Определение дистрибутива и версии
function detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    DISTRO=$ID
    VERSION_ID=$VERSION_ID
  else
    die "/etc/os-release не найден — не могу определить ОС"
  fi
  case "$DISTRO" in
    ubuntu|debian) ;;
    *) die "Поддерживаются только Debian/Ubuntu (ваша: $DISTRO)";;
  esac
  log "Detected OS: $PRETTY_NAME"
}

# Функция перевода
function t() {
  local key="$1"; shift
  local en="$1"; local ru="$2"
  [[ "${LANG:-en}" == "ru" ]] && echo -e "$ru" || echo -e "$en"
}

# === Интерактив ===
function ask_language() {
  echo "----------------------------------------"
  echo " Select language / Выберите язык"
  echo " 1) English"
  echo " 2) Русский"
  echo "----------------------------------------"
  read -t $TIMEOUT -rp "$(t prompt "Enter choice [1-2]: " "Введите выбор [1-2]: ")" LANG_CHOICE \
    || LANG_CHOICE=1
  case "$LANG_CHOICE" in
    2) export LANG=ru ;;
    *) export LANG=en ;;
  esac
}

function ask_action() {
  echo
  t header "Select action:" "Выберите действие:"
  t opt1   "1) Install SOCKS5 proxy server"   "1) Установить SOCKS5 прокси"
  t opt2   "2) Uninstall SOCKS5 proxy server" "2) Удалить SOCKS5 прокси"
  read -t $TIMEOUT -rp "$(t prompt "Enter choice [1-2]: " "Введите выбор [1-2]: ")" ACTION \
    || ACTION=1
}

function ask_port() {
  local default=1080
  read -t $TIMEOUT -rp "$(t prompt "Enter port [${default}]: " "Введите порт [${default}]: ")" PORT
  PORT=${PORT:-$default}
  [[ "$PORT" =~ ^[0-9]+$ ]] && ((PORT>=1 && PORT<=65535)) || die "Неверный порт: $PORT"
}

function ask_credentials() {
  read -t $TIMEOUT -rp "$(t prompt "Enter username: " "Введите имя пользователя: ")" PROXY_USER
  read -s -t $TIMEOUT -rp "$(t prompt "Enter password: " "Введите пароль: ")" PROXY_PASS
  echo
  [[ -n "$PROXY_USER" && -n "$PROXY_PASS" ]] || die "Логин/пароль не должны быть пустыми"
}

# === Установка ===
function install_packages() {
  log "Updating package lists"
  apt-get update -y
  log "Installing Dante and dependencies"
  apt-get install -y dante-server libpam-pwdfile iptables
}

function detect_interface() {
  log "Detecting external interface"
  IFACE=$(ip route get 8.8.8.8 2>/dev/null \
    | awk '/dev/ { for(i=1;i<NF;i++) if($i=="dev") print $(i+1) }')
  IFACE=${IFACE:-eth0}
  log "Will bind to interface: $IFACE"
}

function create_dante_config() {
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

function create_systemd_service() {
  local sockd_bin
  sockd_bin=$(command -v sockd)
  log "Writing systemd unit for Dante"
  cat > /etc/systemd/system/dante-server.service <<EOF
[Unit]
Description=Dante SOCKS5 Proxy Server
After=network.target

[Service]
Type=simple
ExecStart=$sockd_bin -f /etc/dante.conf
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable dante-server.service
}

function setup_pam() {
  log "Configuring PAM (pam_pwdfile)"
  mkdir -p /etc/dante-users
  touch /etc/dante-users/users.pwd
  cat > /etc/pam.d/sockd <<EOF
auth required pam_pwdfile.so pwdfile /etc/dante-users/users.pwd
account required pam_permit.so
EOF
  chmod 644 /etc/pam.d/sockd
}

function configure_firewall() {
  log "Setting up iptables rules"
  iptables -I INPUT -p tcp --dport 22 -j ACCEPT
  iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
  iptables -I INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
  iptables -P INPUT DROP
}

function add_user() {
  log "Adding proxy user to database"
  local hash
  hash=$(openssl passwd -6 "$PROXY_PASS")
  echo "$PROXY_USER:$hash" >> /etc/dante-users/users.pwd
}

function show_info() {
  local ip
  ip=$(hostname -I | awk '{print $1}')
  echo
  echo "╔════════════════════════════════════╗"
  echo "║ $(t info "SOCKS5 Proxy Information" "Информация SOCKS5 прокси") ║"
  echo "╠════════════════════════════════════╣"
  echo "║ Server:   $ip              ║"
  echo "║ Port:     $PORT             ║"
  echo "║ Username: $PROXY_USER       ║"
  echo "║ Password: $PROXY_PASS       ║"
  echo "╚════════════════════════════════════╝"
}

# === Удаление ===
function uninstall() {
  log "Stopping and disabling Dante service"
  systemctl stop dante-server.service 2>/dev/null || true
  systemctl disable dante-server.service 2>/dev/null || true

  log "Purging packages"
  apt-get purge --auto-remove -y dante-server libpam-pwdfile

  log "Removing configs and scripts"
  rm -f /etc/dante.conf
  rm -rf /etc/dante-users /etc/pam.d/sockd
  rm -f /etc/systemd/system/dante-server.service
  systemctl daemon-reload

  log "Uninstall complete"
}

# === Main ===
check_root
check_deps
detect_os

ask_language
ask_action

case "${ACTION:-1}" in
  1)
    ask_port
    ask_credentials
    install_packages
    detect_interface
    create_dante_config
    create_systemd_service
    setup_pam
    configure_firewall
    add_user
    systemctl start dante-server.service
    show_info
    ;;
  2)
    uninstall
    ;;
  *)
    die "Unknown action: $ACTION"
    ;;
esac
