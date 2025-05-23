#!/bin/bash
exec < /dev/tty
set -e

cleanup() {
  echo -e "\n[ОЧИСТКА] Удаление dante-server, пользователя и конфигов..."
  systemctl stop danted || true
  systemctl disable danted || true
  rm -f /etc/danted.conf
  rm -f /etc/systemd/system/danted.service
  userdel -r "$USERNAME" 2>/dev/null || true
  apt remove --purge -y dante-server
  apt autoremove -y
  echo "[ОЧИСТКА] Все изменения отменены. Скрипт завершён."
  exit 1
}

# Проверка root
if [[ $EUID -ne 0 ]]; then
  echo "Пожалуйста, запустите скрипт с правами root (sudo)" >&2
  exit 1
fi

# Проверка ОС
if ! grep -qiE 'ubuntu|debian' /etc/os-release; then
  echo "Скрипт поддерживает только Ubuntu/Debian!" >&2
  exit 1
fi

# Установка dante-server
apt update && apt install -y dante-server

# Интерактивный ввод с проверкой и таймаутом
while true; do
  if ! read -t 120 -p "Введите порт для SOCKS5-прокси [1080]: " PORT; then
    echo -e "\n[ОШИБКА] Время ожидания истекло. Без ввода данных работа невозможна."
    cleanup
  fi
  PORT=${PORT:-1080}
  if [[ $PORT =~ ^[0-9]+$ ]] && ((PORT>=1 && PORT<=65535)); then
    break
  else
    echo "Некорректный порт. Введите число от 1 до 65535."
  fi
done

while true; do
  if ! read -t 120 -p "Введите логин для доступа: " USERNAME; then
    echo -e "\n[ОШИБКА] Время ожидания истекло. Без ввода данных работа невозможна."
    cleanup
  fi
  if [[ -n "$USERNAME" ]]; then
    break
  else
    echo "Логин не может быть пустым."
  fi
done

while true; do
  if ! read -t 120 -s -p "Введите пароль для доступа: " PASSWORD; then
    echo -e "\n[ОШИБКА] Время ожидания истекло. Без ввода данных работа невозможна."
    cleanup
  fi
  echo
  if [[ -n "$PASSWORD" ]]; then
    break
  else
    echo "Пароль не может быть пустым."
  fi
done

if ! read -t 120 -p "Разрешить доступ только с определённого IP? (оставьте пустым для всех): " ALLOWED_IP; then
  echo -e "\n[ОШИБКА] Время ожидания истекло. Без ввода данных работа невозможна."
  cleanup
fi

# Создание пользователя для dante
if ! id "$USERNAME" &>/dev/null; then
  useradd -M -s /usr/sbin/nologin "$USERNAME"
fi

echo "$USERNAME:$PASSWORD" | chpasswd

# Генерация конфига dante
cat > /etc/danted.conf <<EOF
logoutput: syslog
internal: 0.0.0.0 port = $PORT
external: eth0

method: username
user.notprivileged: nobody

client pass {
  from: ${ALLOWED_IP:-0.0.0.0/0} to: 0.0.0.0/0
  log: connect disconnect error
}

socks pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  command: bind connect udpassociate
  log: connect disconnect error
  method: username
}
EOF

# Создание systemd unit (если нет)
if [ ! -f /etc/systemd/system/danted.service ]; then
cat > /etc/systemd/system/danted.service <<EOL
[Unit]
Description=Dante SOCKS5 Proxy
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/sbin/danted -f /etc/danted.conf
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOL
fi

systemctl daemon-reload
systemctl enable --now danted

# Вывод информации
IP=$(hostname -I | awk '{print $1}')
echo -e "\nSOCKS5-прокси установлен и запущен!"
echo "Параметры подключения:"
echo "IP: $IP"
echo "Порт: $PORT"
echo "Логин: $USERNAME"
echo "Пароль: $PASSWORD"
if [[ -n "$ALLOWED_IP" ]]; then
  echo "Доступ разрешён только с IP: $ALLOWED_IP"
else
  echo "Доступ разрешён с любого IP"
fi