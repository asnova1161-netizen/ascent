# ascent — iOS лоадер (.tipa)

Тот самый экран «ascent» из веб-макета, но как настоящее iOS-приложение на SwiftUI.
Собирается **без macOS и без Xcode** — на бесплатном macOS-раннере GitHub Actions,
на выходе готовый `Ascent.tipa`, который открывается в TrollStore.

```
ascent-ios/
├─ Ascent/
│  ├─ AscentApp.swift        # точка входа
│  ├─ LoaderView.swift       # весь экран: лого, прогресс, Start, t.me/ascentios
│  ├─ Theme.swift            # цвета и стиль кнопки
│  ├─ Info.plist
│  └─ Assets.xcassets/       # иконка приложения 1024×1024
├─ project.yml               # описание Xcode-проекта (XcodeGen)
└─ .github/workflows/build.yml
```

Интерфейс намеренно написан только на API из iOS 14, чтобы приложение работало
на всех версиях, где живёт TrollStore (14.0b2 – 16.6.1, 16.7 RC, 17.0).

---

## Шаг 1. Положить проект в GitHub

Нужен аккаунт GitHub (бесплатный). Выбери любой способ.

**Вариант А — GitHub Desktop (проще всего, git не нужен)**
1. Установи [GitHub Desktop](https://desktop.github.com/).
2. `File → Add local repository…` → укажи папку `ascent-ios`.
3. Он предложит создать репозиторий — согласись, затем `Publish repository`.
4. В настройках публикации **сними галку «Keep this code private»** — у публичных
   репозиториев macOS-раннеры бесплатны и без лимита.

**Вариант Б — через сайт GitHub (даже без установки чего-либо)**
1. github.com → `New repository` → имя `ascent` → Public → Create.
2. `Add file → Upload files` → перетащи содержимое папки `ascent-ios`
   (файлы `project.yml`, `.gitignore`, папку `Ascent`).
3. Отдельно `Add file → Create new file`, в поле имени впиши
   `.github/workflows/build.yml` и вставь туда содержимое одноимённого файла
   (папку `.github` веб-загрузка не показывает — её надо создать вручную).

**Вариант В — git в терминале** (git для Windows: https://git-scm.com/download/win)
```bash
cd ascent-ios
git init -b main
git add .
git commit -m "ascent loader"
git remote add origin https://github.com/ТВОЙ_ЛОГИН/ascent.git
git push -u origin main
```

## Шаг 2. Собрать

После пуша: вкладка **Actions** → workflow `build-tipa` стартует сам.
Ничего настраивать не надо, занимает ~2–3 минуты.

Если запуска не было: Actions → `build-tipa` → `Run workflow`.

## Шаг 3. Забрать .tipa

**Способ 1 — артефакт (быстро)**
1. Открой завершённый запуск в Actions.
2. Внизу в разделе `Artifacts` скачай `Ascent-tipa` (это обычный zip).
3. Распакуй → внутри `Ascent.tipa`.

**Способ 2 — релиз с прямой ссылкой (удобнее для телефона)**
```bash
git tag v1.0
git push --tags
```
Соберётся `.tipa` и прикрепится к релизу. Тогда на iPhone можно просто открыть
страницу релиза в Safari → тапнуть `Ascent.tipa`.

## Шаг 4. Поставить на iPhone

TrollStore должен быть уже установлен. Дальше:
1. Перекинь `Ascent.tipa` на телефон: iCloud Drive/Google Drive/Telegram «себе»,
   либо просто скачай из релиза прямо в Safari.
2. В **Файлах** тапни по `Ascent.tipa` → «Поделиться» → **TrollStore**
   (или открой TrollStore → `+` → `Install IPA File` → выбери файл,
   либо `+` → `Install from URL`).
3. TrollStore покажет карточку приложения → `Install` → иконка «ascent» появится на экране.

---

## Что легко поменять

| Что | Где |
|---|---|
| Ссылка внизу | `Ascent/LoaderView.swift` → `telegramURL` |
| Название на экране | `Ascent/LoaderView.swift` → `Text("ascent")` |
| Тексты этапов загрузки | там же, массив `stages` |
| Зелёный цвет | `Ascent/Theme.swift` → `green` / `green2` |
| Иконка | замени `Ascent/Assets.xcassets/AppIcon.appiconset/icon-1024.png` (1024×1024, без альфы) |
| Имя приложения под иконкой | `Ascent/Info.plist` → `CFBundleDisplayName` |
| Bundle ID | `project.yml` → `PRODUCT_BUNDLE_IDENTIFIER` |
| Версия | `project.yml` → `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` |

Кнопка `Start` пока только меняет состояние на `Started` — логику добавим,
когда будет понятно, что она должна запускать.

## Если что-то пошло не так

- **Билд упал** — открой лог шага в Actions, там видно причину; почти всегда это
  опечатка в `project.yml` или новое API SwiftUI, которого нет в iOS 14.
- **TrollStore не видит файл** — проверь, что расширение `.tipa` (не `.zip`),
  и что файл не в архиве.
- **Установилось, но не запускается** — почти всегда «User» регистрация:
  в TrollStore тапни по приложению → `Switch to "System" Registration` → respring.
- **Приложение не ставится вообще** — версия iOS вне диапазона TrollStore.

## Локальная перепаковка

Если нужно пересобрать `.tipa` уже из готового `.ipa`/`.app` на этом ПК —
используй `../tipa/New-Tipa.ps1` (там же лежит `zsign.exe`):

```powershell
.\tipa\New-Tipa.ps1 .\Ascent.ipa -Entitlements .\ent.plist
```
