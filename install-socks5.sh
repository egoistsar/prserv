#!/usr/bin/env bash
set -euo pipefail
+# Перенаправляем STDIN на реальный терминал,
+# чтобы read читал не поток скрипта, а клавиатуру
+exec 0</dev/tty
echo "==============================================="
echo "  Интерактивный установщик SOCKS5-прокси (Dante)"
echo "==============================================="

# 1. Сбор параметров
read -rp "Интерфейс для прокси (по умолчанию eth0): " PROXY_IFACE
PROXY_IFACE=${PROXY_IFACE:-eth0}

read -rp "Порт прокси (по умолчанию 8467): " PROXY_PORT
PROXY_PORT=${PROXY_PORT:-8467}

read -rp "Имя пользователя для PROXY: " PROXY_USER

while true; do
  read -rsp "Пароль для $PROXY_USER: " PROXY_PASS; echo
  read -rsp "Повторите пароль: " PASS2; echo
  [[ "$PROXY_PASS" == "$PASS2" ]] && break
  echo "Пароли не совпадают — попробуйте ещё раз."
done

echo
echo "Параметры:"
echo "  Интерфейс: $PROXY_IFACE"
echo "  Порт:      $PROXY_PORT"
echo "  Пользователь: $PROXY_USER"
echo

read -rp "Продолжить установку? (yes/No) " CONFIRM
case "$CONFIRM" in
  [Yy][Ee][Ss]|[Yy]) ;;
  *) echo "Установка отменена."; exit 1;;
esac

# 2. Установка Dante
echo "-> Обновляем apt и ставим dante-server"
apt update
DEBIAN_FRONTEND=noninteractive apt install -y dante-server

# 3. Генерация конфига
echo "-> Пишем /etc/danted.conf"
cat > /etc/danted.conf <<EOF
logoutput: syslog
internal: $PROXY_IFACE port = $PROXY_PORT
external: $PROXY_IFACE
socksmethod: username
user.privileged: root
user.unprivileged: nobody

client pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0 log: connect error
}

socks pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0 log: connect error
}
EOF

# 4. Создание пользователя
echo "-> Настраиваем пользователя $PROXY_USER"
useradd -M -s /usr/sbin/nologin "$PROXY_USER" || true
echo "${PROXY_USER}:${PROXY_PASS}" | chpasswd

# 5. Открытие порта
echo "-> Открываем порт $PROXY_PORT"
if command -v ufw &>/dev/null; then
  ufw allow "$PROXY_PORT"/tcp
else
  iptables -C INPUT -p tcp --dport "$PROXY_PORT" -j ACCEPT 2>/dev/null \
    || iptables -A INPUT -p tcp --dport "$PROXY_PORT" -j ACCEPT
fi

# 6. Запуск сервиса
echo "-> Включаем и запускаем danted"
systemctl enable --now danted

echo
echo "==============================================="
echo "Готово! SOCKS5-прокси запущен:"
echo "  Интерфейс: $PROXY_IFACE"
echo "  Порт:      $PROXY_PORT"
echo "  Логин/Пароль: $PROXY_USER / <ваш пароль>"
echo "==============================================="
