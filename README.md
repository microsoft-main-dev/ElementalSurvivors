# Elemental Survivors

Одиночный экшен-рогалик для Roblox в стиле Vampire Survivors.
Студия: **4pots games** («Четвёртый чайник»).

Полное техническое задание — в [GAME_DESIGN.md](GAME_DESIGN.md).
Место в Roblox: https://www.roblox.com/games/114242369712729/Elemental-Survivors

---

## Как запустить проект

Всё делается в PowerShell, открытом **в папке `C:\Projects\ElementalSurvivors`**.
Открыть его там проще всего так: открыть папку в проводнике, нажать в адресной
строке, напечатать `powershell` и нажать Enter.

### 1. Один раз: поставить инструменты

```
rokit install
```

Если PowerShell пишет «rokit не является внутренней или внешней командой» —
закрой окно PowerShell и открой заново. Программа установлена, но окно, открытое
до её установки, ещё не знает, где её искать.

### 2. Запустить синхронизацию с Roblox Studio

```
rojo serve
```

Окно закрывать нельзя — пока оно открыто, файлы из папки `src/` попадают в Studio.
Остановить: `Ctrl+C` в этом окне.

### 3. Подключиться из Studio

1. Открыть место Elemental Survivors в Roblox Studio.
2. Вкладка **Plugins** сверху → кнопка **Rojo**.
3. В открывшейся панельке нажать **Connect**.
4. В окне **Explorer** должны появиться:
   - `ReplicatedStorage → Shared`
   - `ServerScriptService → Server`
   - `StarterPlayer → StarterPlayerScripts → Client`

### 4. Проверить

Нажать **Play** (или F5). Ожидается: экран загрузки с логотипом, затем персонаж
в лобби, в окне **Output** нет красных строк.

---

## Проверка кода

```
stylua src
```

```
selene src
```

Первая команда форматирует код, вторая ищет ошибки. Обе должны отработать молча —
молчание означает, что всё в порядке.

---

## Структура

```
src/
  Server/       -> ServerScriptService.Server        серверная логика (авторитет во всём)
  Client/       -> StarterPlayerScripts.Client       только отрисовка и ввод
  Shared/       -> ReplicatedStorage.Shared          типы, сеть, таблицы данных
```

Сервис (сервер) и контроллер (клиент) — это ModuleScript с необязательными
`Init()` и `Start()`. Загрузчик сам их найдёт: чтобы добавить новый, достаточно
положить файл в `Server/Services/` или `Client/Controllers/`.

Все балансные числа — в `src/Shared/Config/`. Логика их только читает.

---

## Полезное

Собрать файл места из исходников (не требуется для обычной работы):

```
rojo build -o build/ElementalSurvivors.rbxlx
```
