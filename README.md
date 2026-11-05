<p align="center">
  <img src="docs/screenshots/01-home.png" alt="Freedom Music — Windows" width="58%" />
  &nbsp;
  <img src="docs/screenshots/Home.jpg" alt="Freedom Music — Android" width="28%" />
</p>

<h1 align="center">Freedom Music</h1>

<p align="center">
  <strong>Локальный плеер для Windows и Android</strong><br/>
  Музыка остаётся у вас. Метаданные живут в файлах.
</p>

<p align="center">
  <a href="https://github.com/TheSadFreedom/freedom-music/releases/latest"><img src="https://img.shields.io/github/v/release/TheSadFreedom/freedom-music?style=flat-square&label=release&color=3D8B6E" alt="release" /></a>
  <a href="https://github.com/TheSadFreedom/freedom-music/releases"><img src="https://img.shields.io/github/downloads/TheSadFreedom/freedom-music/total?style=flat-square&color=5CBA92" alt="downloads" /></a>
  <img src="https://img.shields.io/badge/Windows-10%2F11-0C1210?style=flat-square" alt="Windows" />
  <img src="https://img.shields.io/badge/Android-8%2B-0C1210?style=flat-square" alt="Android" />
</p>

<p align="center">
  <a href="https://github.com/TheSadFreedom/freedom-music/releases/latest"><strong>Скачать последний релиз</strong></a>
  ·
  <a href="#установка">Установка</a>
  ·
  <a href="#возможности">Возможности</a>
</p>

---

## Что это

Freedom Music — плеер для вашей папки с MP3. Без облачной библиотеки и подписок: название, артисты, альбом, год, продюсер и текст читаются из тегов и туда же записываются. Прослушивания, плейлисты и фото артистов хранятся рядом с приложением.

Два клиента одной идеи: **Windows** и **Android**. Данные можно переносить экспортом между ними (без самих аудиофайлов).

---

## Возможности

### Артисты и продюсеры

<table>
  <tr>
    <td align="center" width="55%"><strong>Windows</strong></td>
    <td align="center" width="45%"><strong>Android</strong></td>
  </tr>
  <tr>
    <td valign="top">
      <img src="docs/screenshots/02-artists.png" alt="Артисты · Windows" />
      <p><strong>Артисты</strong> — карточки по прослушиваниям, альбомы и синглы, объединение имён без порчи тегов.</p>
    </td>
    <td valign="top" align="center">
      <img src="docs/screenshots/Artists.jpg" alt="Артисты · Android" width="280" />
    </td>
  </tr>
  <tr>
    <td valign="top">
      <img src="docs/screenshots/03-producers.png" alt="Продюсеры · Windows" />
      <p><strong>Продюсеры</strong> — битмейкеры из метаданных, топ и связи с артистами.</p>
    </td>
    <td valign="top" align="center">
      <img src="docs/screenshots/Prod.jpg" alt="Продюсеры · Android" width="280" />
    </td>
  </tr>
</table>

### Чарт и календарь

<table>
  <tr>
    <td align="center" width="55%"><strong>Windows</strong></td>
    <td align="center" width="45%"><strong>Android</strong></td>
  </tr>
  <tr>
    <td valign="top">
      <img src="docs/screenshots/04-chart.png" alt="Чарт · Windows" />
      <p><strong>Чарт</strong> — треки и альбомы за всё время, динамика мест.</p>
    </td>
    <td valign="top" align="center">
      <img src="docs/screenshots/Chart.jpg" alt="Чарт · Android" width="280" />
    </td>
  </tr>
  <tr>
    <td valign="top">
      <img src="docs/screenshots/05-calendar.png" alt="Календарь · Windows" />
      <p><strong>Календарь</strong> — релизы библиотеки по годам.</p>
    </td>
    <td valign="top" align="center">
      <img src="docs/screenshots/Calendar.jpg" alt="Календарь · Android" width="280" />
    </td>
  </tr>
</table>

### Плейлисты

<table>
  <tr>
    <td align="center" width="55%"><strong>Windows</strong></td>
    <td align="center" width="45%"><strong>Android</strong></td>
  </tr>
  <tr>
    <td valign="top">
      <img src="docs/screenshots/06-playlists.png" alt="Плейлисты · Windows" />
    </td>
    <td valign="top" align="center">
      <img src="docs/screenshots/Playlists.jpg" alt="Плейлисты · Android" width="280" />
    </td>
  </tr>
</table>

<p align="center">Свои подборки и системные: новинки, пробелы в метаданных, корзина.</p>

Также:

- **Плеер** — очередь, EQ, тексты (в т.ч. с таймкодами), редактор метаданных
- **Браузер** (Windows) — поиск и замена треков из сети
- **Экспорт / импорт** — плейлисты, история, фото, объединения, настройки

---

## Установка

### Windows

1. Скачайте `FreedomMusic-*-windows-x64.zip` со [страницы релизов](https://github.com/TheSadFreedom/freedom-music/releases/latest).
2. Распакуйте **всю** папку (не один `.exe`).
3. Запустите `Freedom Music.exe`.
4. Положите MP3 в папку `music` рядом с программой (создаётся при первом запуске).
5. В **Настройках** нажмите **Поиск новых** или **Сканировать папку music**.

Нужны Windows 10/11 x64 и [VC++ Redistributable 2015–2022 (x64)](https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist).

### Android

1. Скачайте `FreedomMusic-*-android.apk` со [страницы релизов](https://github.com/TheSadFreedom/freedom-music/releases/latest).
2. Разрешите установку из неизвестных источников для файла.
3. Укажите доступ к музыке и отсканируйте библиотеку в настройках.

---

## Данные и приватность

| | |
|---|---|
| Аудио | Остаётся на устройстве, в облако приложения не уходит |
| Тексты песен | Пишутся в **теги файла** (и дублируются локально в базе) |
| Экспорт | Плейлисты, прослушивания, фото, объединения, снимки чарта, флаги настроек |
| Не в экспорте | Сами MP3, пути к файлам, EQ и очередь |

Импорт на другую платформу: сначала просканируйте те же треки — списки и история цепляются по ключу артист+название.

---

## Структура репозитория

```
freedom-music/
├── apps/
│   ├── windows/     # Flutter · Windows
│   └── android/     # Flutter · Android
├── docs/screenshots/
└── README.md
```

### Сборка из исходников

Нужен [Flutter](https://docs.flutter.dev/get-started/install) stable.

```bash
# Windows
cd apps/windows && flutter pub get && flutter build windows --release

# Android
cd apps/android && flutter pub get && flutter build apk --release
```

Release-подпись Android: локальные `android/key.properties` и keystore — в git не входят.

---

<p align="center">
  <sub>Сделано для тех, кто хранит музыку у себя.</sub>
</p>
