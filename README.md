# Freedom Music

Локальный музыкальный плеер: метаданные живут в ваших MP3, библиотека — у вас на устройстве.
Два клиента одной идеи — **Windows** и **Android**.

```
freedom-music/
├── apps/
│   ├── windows/   # Flutter · Windows desktop
│   └── android/   # Flutter · Android
└── README.md
```

---

## Клиенты

| | Windows | Android |
|---|---|---|
| Путь | [`apps/windows`](apps/windows) | [`apps/android`](apps/android) |
| Платформа | Windows 10/11 · x64 | Android 8+ |
| Сборка | `flutter build windows` | `flutter build apk --release` |
| Релизы | [GitHub Releases](https://github.com/TheSadFreedom/FreedomMusic/releases) | APK из `build/app/outputs/flutter-apk/` |

Оба клиента читают и пишут теги в файлы: название, артисты, альбом, год, номер трека, продюсер, текст. Прослушивания, плейлисты и фото артистов хранятся рядом с приложением, не в облаке.

---

## Возможности

- **Библиотека** — артисты, продюсеры, чарт, календарь, плейлисты
- **Плеер** — очередь, EQ, тексты (в т.ч. таймкоды), редактор метаданных
- **Браузер** — поиск и замена треков из сети (Windows)
- **Чарт** — треки и альбомы за всё время, динамика мест
- **Системные плейлисты** — новинки, без метаданных, корзина и др.

---

## Быстрый старт

Нужен [Flutter](https://docs.flutter.dev/get-started/install) stable.

### Windows

```bash
cd apps/windows
flutter pub get
flutter run -d windows
```

Портативный запуск: рядом с exe должна лежать папка `music`.  
Требуется [VC++ Redistributable 2015–2022 x64](https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist).

### Android

```bash
cd apps/android
flutter pub get
flutter run
# или
flutter build apk --release
```

Для release-подписи создайте локально `android/key.properties` и keystore — **в репозиторий они не входят**.

---

## Данные и приватность

- MP3 не уезжают на сервер приложения
- Экспорт/импорт переносит плейлисты, прослушивания, фото и настройки — без самих треков
- Обнуление прослушиваний сбрасывает чарт, плейлисты остаются

---

## Связанные репозитории

Исторические релизы Windows остаются на  
[TheSadFreedom/FreedomMusic](https://github.com/TheSadFreedom/FreedomMusic).  
Этот репозиторий — единый дом исходников обоих клиентов.
