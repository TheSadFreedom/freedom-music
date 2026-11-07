<div align="center">

<img src="docs/screenshots/01-home.png" alt="Freedom Music на Windows" width="720" />

<br/><br/>

# FREEDOM MUSIC

**Локальный плеер.** Музыка на вашем диске — метаданные в файлах.

<br/>

<a href="https://github.com/TheSadFreedom/freedom-music/releases/latest">
  <img src="https://img.shields.io/badge/%D0%A1%D0%BA%D0%B0%D1%87%D0%B0%D1%82%D1%8C-Windows%20%26%20Android-3D8B6E?style=for-the-badge&labelColor=0C1210" alt="Скачать" />
</a>

<br/><br/>

<img src="https://img.shields.io/github/v/release/TheSadFreedom/freedom-music?style=flat-square&color=5CBA92&labelColor=0C1210" alt="version" />
<img src="https://img.shields.io/badge/Windows-10%2F11-0C1210?style=flat-square&color=15201C" alt="Windows" />
<img src="https://img.shields.io/badge/Android-8%2B-0C1210?style=flat-square&color=15201C" alt="Android" />
<img src="https://img.shields.io/github/downloads/TheSadFreedom/freedom-music/total?style=flat-square&color=3D8B6E&labelColor=0C1210" alt="downloads" />

<br/><br/>

<img src="docs/screenshots/Home.jpg" alt="Главная на Android" height="420" />
&nbsp;&nbsp;
<img src="docs/screenshots/Artists.jpg" alt="Артисты на Android" height="420" />
&nbsp;&nbsp;
<img src="docs/screenshots/Playlists.jpg" alt="Плейлисты на Android" height="420" />

</div>

---

## Идея

Без облака и подписок. Положите MP3 в папку — Freedom Music читает теги, пишет правки обратно в файлы и считает прослушивания локально.

Один вкус на двух платформах. Экспорт переносит плейлисты, историю и фото — сами треки остаются у вас.

---

## Галерея

<div align="center">

| | |
|:---:|:---:|
| <img src="docs/screenshots/02-artists.png" alt="Артисты · Windows" width="520" /><br/><sub>Артисты · Windows</sub> | <img src="docs/screenshots/Artists.jpg" alt="Артисты · Android" width="220" /><br/><sub>Артисты · Android</sub> |
| <img src="docs/screenshots/03-producers.png" alt="Продюсеры · Windows" width="520" /><br/><sub>Продюсеры · Windows</sub> | <img src="docs/screenshots/Prod.jpg" alt="Продюсеры · Android" width="220" /><br/><sub>Продюсеры · Android</sub> |
| <img src="docs/screenshots/04-chart.png" alt="Чарт · Windows" width="520" /><br/><sub>Чарт · Windows</sub> | <img src="docs/screenshots/Chart.jpg" alt="Чарт · Android" width="220" /><br/><sub>Чарт · Android</sub> |
| <img src="docs/screenshots/05-calendar.png" alt="Календарь · Windows" width="520" /><br/><sub>Календарь · Windows</sub> | <img src="docs/screenshots/Calendar.jpg" alt="Календарь · Android" width="220" /><br/><sub>Календарь · Android</sub> |
| <img src="docs/screenshots/06-playlists.png" alt="Плейлисты · Windows" width="520" /><br/><sub>Плейлисты · Windows</sub> | <img src="docs/screenshots/Playlists.jpg" alt="Плейлисты · Android" width="220" /><br/><sub>Плейлисты · Android</sub> |

</div>

---

## Что умеет

| | |
|---|---|
| **Библиотека** | Артисты, продюсеры, чарт, календарь релизов |
| **Плейлисты** | Свои и системные: новинки, метаданные, корзина |
| **Плеер** | Очередь, EQ, тексты с таймкодами, редактор тегов |
| **Синхронизация** | Экспорт / импорт между Windows и Android |

---

## Установка

<details open>
<summary><strong>Windows</strong></summary>

<br/>

1. Скачайте `FreedomMusic-*-windows-x64.zip` из [релизов](https://github.com/TheSadFreedom/freedom-music/releases/latest)
2. Распакуйте **всю** папку — не один `.exe`
3. Запустите `Freedom Music.exe`
4. Положите MP3 в папку `music` рядом с программой
5. В настройках — **Поиск новых** или **Сканировать папку music**

Нужны Windows 10/11 ×64 и [VC++ Redistributable](https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist).

</details>

<details open>
<summary><strong>Android</strong></summary>

<br/>

1. Скачайте `FreedomMusic-*-android.apk` из [релизов](https://github.com/TheSadFreedom/freedom-music/releases/latest)
2. Разрешите установку из этого файла
3. Дайте доступ к музыке и отсканируйте библиотеку

</details>

---

## Данные

| В файлах | В приложении | В экспорте |
|---|---|---|
| Теги, обложки, тексты | Плейлисты, прослушивания, фото | Плейлисты, история, фото, объединения, настройки |
| | | **Не входит:** MP3, пути, EQ, очередь |

На другой платформе сначала просканируйте те же треки — связи идут по артисту и названию.

---

<details>
<summary><strong>Для разработчиков</strong></summary>

<br/>

```
freedom-music/
├── apps/windows
├── apps/android
└── docs/screenshots
```

```bash
cd apps/windows && flutter pub get && flutter build windows --release
cd apps/android && flutter pub get && flutter build apk --release
```

Android release-подпись: локальные `key.properties` и keystore — не в git.

</details>

<br/>

<div align="center">

<sub>Сделано для тех, кто хранит музыку у себя.</sub>

</div>
