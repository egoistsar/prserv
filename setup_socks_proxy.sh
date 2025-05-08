#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
LOGFILE=/var/log/s5proxy_install.log
TIMEOUT=300

function log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"
}

function t() {
  local key="$1"; shift
  local msg_en="$1"; local msg_ru="$2"
  if [[ "${LANGUAGE:-en}" == "ru" ]]; then
    echo -e "$msg_ru"
  else
    echo -e "$msg_en"
  fi
}

function ask_language() {
  echo "Select language / Выберите язык:"
  echo "1) English"
  echo "2) Русский"
  read -t $TIMEOUT -rp "$(t prompt \"Enter your choice [1-2]: \" \"Введите ваш выбор [1-2]: \")" choice \
    || { log "No input, defaulting to English"; choice=1; }
  case "$choice" in
    2) LANGUAGE="ru" ;;
    *) LANGUAGE="en" ;;
  esac
  export LANGUAGE
}

function ask_action() {
  t action "Select action:" "Выберите действие:"
  t opt1   "1) Install SOCKS5 proxy server"   "1) Установить SOCKS5 прокси-сервер"
  t opt2   "2) Uninstall SOCKS5 proxy server" "2) Удалить SOCKS5 прокси-сервер"
  read -t $TIMEOUT -rp "$(t prompt \"Enter your choice [1-2]: \" \"Введите ваш выбор [1-2]: \")" action_choice \
    || { log "No input, default to install"; action_choice=1; }
}

function ask_port() {
  local default_port=1080
  read -t $TIMEOUT -rp "$(t prompt \"Enter port number [${default_port}]: \" \"Введите порт [${default_port}]: \")" PORT
  PORT=${PORT:-$default_port}
  if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
    log "Invalid port: $PORT"
    exit 1
  fi
}

function ask_credentials() {
  read -t $TIMEOUT -rp "$(t prompt \"Enter username: \" \"Введите имя пользователя: \")" PROXY_USER
  read -s -t $TIMEOUT -rp "$(t prompt \"Enter password: \" \"Введите пароль: \")" PROXY_PASS
  echo
  if [[ -z "$PROXY_USER" || -z "$PROXY_PASS" ]]; then
    log "Username/password empty"
    exit 1
  fi
}

function install_packages() {
  log "Installing required packages"
  apt-get update
  apt-get install -y dante-server libpam-pwdfile iptables
}

function detect_interface() {
  log "Detecting network interface"
  if ip route get 8.8.8.8 &>/dev/null; then
    IFACE=$(ip route get 8.8.8.8 | awk '/dev/{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}')
  else
    IFACE=eth0
  fi
  log "Using interface $IFACE"
}

function create_dante_config() {
  log "Creating Dante config"
  cat > /etc/dante.conf <<EOF
logoutput: syslog
internal: $IFACE port = $PORT
external: $IFACE
method: pam
user.privileged: root
user.unprivileged: nobody

client pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  log: error
}

pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  protocol: tcp udp
  log: error
}
EOF
}

function create_dante_service() {
  SOCKD_BIN=$(command -v sockd)
  log "Creating systemd service"
  cat > /etc/systemd/system/dante-server.service <<EOF
[Unit]
Description=Socks5 proxy server (Dante)
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

function setup_pam() {
  log "Setting up PAM authentication"
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
  log "Adding proxy user"
  HASH=$(openssl passwd -6 "$PROXY_PASS")
  echo "$PROXY_USER:$HASH" >> /etc/dante-users/users.pwd
}

function show_connection_info() {
  IP=$(hostname -I | awk '{print $1}')
  echo -e "╔════════════════════════════════════════╗"
  echo -e "║ $(t info \"SOCKS5 Proxy Connection Information\" \"Информация для подключения\") ║"
  echo -e "╠════════════════════════════════════════╣"
  echo -e "║ Server:  $IP                     ║"
  echo -e "║ Port:    $PORT                   ║"
  echo -e "║ Username: $PROXY_USER            ║"
  echo -e "║ Password: $PROXY_PASS            ║"
  echo -e "╚════════════════════════════════════════╝"
}

function uninstall() {
  log "Uninstalling Dante proxy"
  systemctl stop dante-server.service   || true
  systemctl disable dante-server.service|| true
  apt-get purge --auto-remove -y dante-server libpam-pwdfile || true
  rm -rf /etc/dante.conf \
         /etc/systemd/system/dante-server.service \
         /etc/pam.d/sockd \
         /etc/dante-users \
         /usr/local/bin/proxy-users
  systemctl daemon-reload
  log "Uninstallation complete"
}

# Main
ask_language
ask_action

if [[ $action_choice -eq 1 ]]; then
  ask_port
  ask_credentials
  install_packages
  detect_interface
  create_dante_config
  create_dante_service
  setup_pam
  configure_firewall
  add_proxy_user
  systemctl start dante-server.service
  show_connection_info

elif [[ $action_choice -eq 2 ]]; then
  uninstall

else
  log "Unknown choice"
  exit 1
fi
