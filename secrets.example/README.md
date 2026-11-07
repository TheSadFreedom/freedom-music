# OAuth secrets

Скопируйте нужный файл в `secrets/` в корне репозитория (папка в `.gitignore`).

## Яндекс.Диск

1. Создайте приложение на https://oauth.yandex.ru/ («Для авторизации пользователей»)
2. Redirect URI может быть фиксированным: `https://oauth.yandex.ru/verification_code` — так и задумано; приложение попросит вставить код
3. Права: `cloud_api:disk.app_folder` (email опционально)
4. Скопируйте `secrets.example/yandex_oauth.desktop.json` → `secrets/yandex_oauth.desktop.json`
5. Подставьте `client_id` и `client_secret`
