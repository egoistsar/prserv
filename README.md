# s5proxyserver

## Быстрая установка / удаление

```bash
# Установка с дефолтными параметрами (порт=1080, пользователь=proxy, пароль=proxy)
curl -fsSL https://raw.githubusercontent.com/egoistsar/prserv/main/install.sh | sudo bash

# Указать порт, логин и пароль:
curl -fsSL https://raw.githubusercontent.com/egoistsar/prserv/main/install.sh \
  | sudo bash -s -- -p 1341 -u alice -P s3cr3t

# Полное удаление:
curl -fsSL https://raw.githubusercontent.com/egoistsar/prserv/main/install.sh | sudo bash -s -- -r
