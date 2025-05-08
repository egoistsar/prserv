#!/usr/bin/env bash
set -e

# Перезапуск через TTY, если stdin не является терминалом
if [[ ! -t 0 ]]; then
  exec bash -s "$@" < /dev/tty
fi

echo "
===================================================="
echo "  Dante SOCKS5 Proxy Installer"
echo "===================================================="
echo

# 1) Update system
echo "[1/8] Updating package lists..."
apt-get update -qq
echo "[2/8] Upgrading installed packages..."
apt-get dist-upgrade -y -qq

echo
# 2) Prompt for configuration parameters
read -rp "Enter internal interface to listen on (e.g., eth0) [default: eth0]: " INTERNAL_IF
INTERNAL_IF=${INTERNAL_IF:-eth0}

read -rp "Enter external interface for outbound traffic (e.g., eth0) [default: eth0]: " EXTERNAL_IF
EXTERNAL_IF=${EXTERNAL_IF:-eth0}

read -rp "Enter port for SOCKS5 proxy [default: 8467]: " PROXY_PORT
PROXY_PORT=${PROXY_PORT:-8467}

read -rp "Enter username for proxy authentication [default: socksuser]: " PROXY_USER
PROXY_USER=${PROXY_USER:-socksuser}

# Hidden password prompt через /dev/tty
while true; do
  read -srp "Enter password for user $PROXY_USER: " PROXY_PASS < /dev/tty
  echo
  read -srp "Confirm password: " PROXY_PASS2 < /dev/tty
  echo
  [[ "$PROXY_PASS" == "$PROXY_PASS2" ]] && break
  echo "Passwords do not match, try again."
done

echo
# 3) Install Dante server
echo "[3/8] Installing dante-server package..."
apt-get install -y dante-server

echo
# 4) Create proxy user and set password
if id "$PROXY_USER" &>/dev/null; then
  echo "User $PROXY_USER already exists, skipping creation."
else
  echo "[4/8] Creating system user $PROXY_USER..."
  useradd --system --shell /usr/sbin/nologin "$PROXY_USER"
fi

echo "$PROXY_USER:$PROXY_PASS" | chpasswd
echo "Password set for $PROXY_USER"

echo
# 5) Generate Dante config
echo "[5/8] Writing /etc/danted.conf..."
cat > /etc/danted.conf <<EOF
# /etc/danted.conf
logoutput: syslog
internal: $INTERNAL_IF port = $PROXY_PORT
external: $EXTERNAL_IF
method: username
user.privileged: root
user.notprivileged: nobody
user.libwrap: nobody
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error connect disconnect
}
pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    protocol: tcp udp
    command: bind connect udpassociate
    log: error connect disconnect
}
EOF

echo
# 6) Configure firewall (iptables)
echo "[6/8] Configuring iptables to allow proxy port..."
ip6tables -A INPUT -p tcp --dport $PROXY_PORT -j ACCEPT || true
iptables -A INPUT -p tcp --dport $PROXY_PORT -j ACCEPT || true

# Persist iptables rules if iptables-persistent is installed
dpkg -l | grep -qw iptables-persistent && netfilter-persistent save || true

echo
# 7) Restart and enable service
echo "[7/8] Restarting danted service..."
systemctl restart danted
systemctl enable danted

echo
# 8) Done
echo "[8/8] Dante SOCKS5 proxy is now installed and running."
echo "Interface: $INTERNAL_IF"
echo "Port:      $PROXY_PORT"
echo "Username:  $PROXY_USER"
echo
echo "You can test it using: socks5://$PROXY_USER@<server_ip>:$PROXY_PORT"
