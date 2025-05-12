#!/bin/bash

set -e

echo "Обновление системы..."
sudo apt update && sudo apt upgrade -y

echo "Установка Dante-server..."
sudo apt install -y dante-server

echo "Создание резервной копии оригинального конфига..."
sudo cp /etc/danted.conf /etc/danted.conf.bak

# --- Новый шаг: выбор порта ---
read -p "Введите порт, который будет использовать Dante (по умолчанию 1080): " DANTE_PORT
DANTE_PORT=${DANTE_PORT:-1080}

# --- Новый шаг: выбор имени пользователя ---
read -p "Введите имя системного пользователя для прокси (по умолчанию proxyuser): " PROXY_USER
PROXY_USER=${PROXY_USER:-proxyuser}

# --- Определение интерфейса ---
INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n 1)
echo "Используется сетевой интерфейс: $INTERFACE"

echo "Создание нового конфига /etc/danted.conf..."
sudo bash -c "cat > /etc/danted.conf" <<EOF
logoutput: /var/log/danted.log
internal: $INTERFACE port = $DANTE_PORT
external: $INTERFACE

method: username none
user.notprivileged: nobody

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect error
}

pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    protocol: tcp udp
    log: connect disconnect error
}
EOF

echo "Создание пользователя для прокси..."
sudo useradd -M -s /usr/sbin/nologin $PROXY_USER || true
echo "Установите пароль для пользователя $PROXY_USER:"
sudo passwd $PROXY_USER

echo "Изменение владельца лог-файла..."
sudo touch /var/log/danted.log
sudo chown $PROXY_USER:nogroup /var/log/danted.log

echo "Включение и запуск сервиса danted..."
sudo systemctl enable danted
sudo systemctl restart danted

echo "Проверка статуса сервиса:"
sudo systemctl status danted

echo "Готово! Dante SOCKS5 proxy работает на порту $DANTE_PORT с пользователем $PROXY_USER."
