# План M6 — контент и режимы

Согласован с владельцем. Код пишется только после «ок» (правило 2 ТЗ).

## Решения владельца

1. **Боссфайт.** После окончания фазы выживания спавн прекращается. Босс выходит,
   когда убиты все оставшиеся враги. Арена к этому моменту пустая — босс читается
   и хитбоксы не перекрываются.
2. **Объём.** Одна локация, 10 уровней. Генератор пишется на все 500 сразу,
   в `Config/Stages` описана одна локация; вторая добавляется одной записью.
3. **Длина сюжетного забега — 8 минут.** ВРЕМЕННОЕ значение. ТЗ фиксирует 15 минут,
   и владелец планирует вернуться к ним после переработки системы способностей
   и питомцев: сейчас все способности выходят на максимум задолго до конца забега,
   и последние минуты игра не меняется. Число лежит в `Balance.Stages.baseDuration`
   и меняется одной правкой.

## Риск, который закрывается в реализации

Ожидание полной зачистки подвешивает забег, если последний враг недостижим:
застрял за колонной, ушёл за радиус, оказался в мёртвой зоне. Страховка в три шага,
все числа в `Balance.Stages`:

1. Спавн остановлен, оставшиеся враги помечаются «добиваемыми».
2. Через `sweepDelay` секунд они начинают стягиваться к игроку с повышенной
   скоростью — обычно этого достаточно.
3. Через `sweepTimeout` секунд оставшиеся удаляются молча, босс выходит.

Без третьего шага любой баг в поиске пути превращается в бесконечный забег.

## Новые файлы

### `Shared/Config/Stages.luau`
20 локаций как данные, конкретный уровень собирается функцией. Никаких 500 записей.
```lua
Stages.Locations: { LocationDef }        -- в первой версии описана одна
Stages.TotalLevels: number
Stages.Get(index: number) -> StageDef    -- собирает уровень из формул
Stages.LocationFor(index: number) -> LocationDef
Stages.IsLocationFinal(index: number) -> boolean
```
`LocationDef = { key, displayName, levels, palette, fog, enemyTypes, bossKeys }`
`StageDef = { index, location, indexInLocation, isFinal, duration, enemyScale: {health, damage, speed}, enemyTypes, bossKey, bossScale, essence, xp, guaranteedItem: boolean }`

### `Shared/Config/Bosses.luau`
Архетипы боссов с фазами и атаками (раздел 3.5 ТЗ). В M6 три архетипа × стихия ×
модификаторы; дальше добавляются данными.
```lua
Bosses.List / Bosses.ByKey
BossDef = { key, displayName, archetype, element, stats, model, phases: { PhaseDef } }
PhaseDef = { healthAbove: number, attacks: { AttackDef }, moveSpeed }
AttackDef = { kind: "Charge" | "Shockwave" | "Summon", telegraph, cooldown, damage, radius, ... }
```
Три вида атак — минимум, на котором боссфайт перестаёт быть «мешком с HP».
Телеграф обязателен: без предупреждения атака на автобое воспринимается как
несправедливость.

### `Shared/Config/Items.luau`
Экипировка (раздел 6.1 ТЗ): слоты, редкости, роллы характеристик.
```lua
Items.Slots: { "Helmet", "Chest", "Boots", "Trinket" }
Items.Rarities / Items.List / Items.ByKey
Items.Roll(stageIndex, random) -> ItemInstance
Items.StatsFor(item: ItemInstance) -> ItemStats
```
Бонусы предметов перемножаются с талантами и питомцем — как всё остальное.

### `Server/Services/StageService.luau`
Владелец сюжетного прогресса и фаз забега.
```lua
StageService.BeginStage(player, stageIndex) -> (boolean, string?)
StageService.GetPhase(slot) -> "Survival" | "Sweep" | "Boss" | "Done"
StageService.OnBossKilled(slot)
StageService.CanPlay(player, stageIndex) -> boolean   -- строго последовательно
```

### `Server/Services/BossService.luau`
Один босс на арену: своя позиция, HP, фазы, атаки. Движение — тот же
`Shared/Util/EnemyMotion`, отрисовка — тот же `Pool`, репликация — отдельными
событиями (боссов мало, экономить трафик незачем).
```lua
BossService.Spawn(slot, bossKey, scale)
BossService.Tick(slot, dt, playerLocal)
BossService.Damage(slot, amount) -> (boolean, number)
BossService.StopRun(slot)
BossService.SetDeathHandler(fn)
```

### `Server/Services/ItemService.luau`
Выпадение, инвентарь, экипировка предметов.
```lua
ItemService.GrantForStage(player, stageIndex, isFinal) -> { ItemInstance }
ItemService.Equip(player, uid) -> (boolean, string?)
ItemService.Apply(player, loadout: RunLoadout)   -- третий шаг после питомца и талантов
ItemService.BuildView(player) -> ItemsView?
```

### `Server/Services/LeaderboardService.luau`
Единственный владелец OrderedDataStore. Больше в него не пишет никто —
профиль остаётся у `DataService`, рекорды здесь.
```lua
LeaderboardService.Submit(player, seconds)
LeaderboardService.GetTop() -> { LeaderboardEntry }   -- кеш, обновление раз в 60 с
```

### `Server/Services/QuestService.luau` и `WheelService.luau`
Ежедневные квесты (прогресс тикает из боёв) и колесо раз в 24 часа по `os.time()`
сервера. Оба пишут в профиль только через операции `DataService`.

### Клиент
`Client/UI/StageSelectPanel.luau` (выбор режима и уровня у портала),
`ItemsPanel.luau`, `QuestsPanel.luau`, `WheelPanel.luau`,
`Client/Controllers/BossRenderController.luau` (модель босса, полоса HP, телеграфы).

## Правки существующих файлов

| Файл | Что |
|---|---|
| `Shared/Types.luau` | `RunMode`, `StageDef`, `BossDef`, `ItemInstance`, `ItemStats`, виды для новых панелей; `RunResult` дополняется исходом уровня и выпавшими предметами |
| `Shared/Net.luau` | `StageStarted`, `BossEvents`, `BossHealth`, `ItemsView`, `QuestsView`, `WheelResult`; действия — через существующий `LobbyRequest` |
| `Shared/Config/Balance.luau` | `Stages` (длительность, кривые роста врагов и наград, `sweepDelay`, `sweepTimeout`), `Items`, `Quests`, `Wheel` |
| `Shared/Config/Rewards.luau` | развилка «сюжет / бесконечный»; утешительные 10% за поражение пропорционально времени, только Essence и опыт |
| `Shared/Config/Palette.luau` | палитры локаций (пока одна, дальше данными) |
| `Server/Services/CombatService.luau` | режим забега, фазы, третий шаг сборки лоадаута (предметы), передача исхода в награду |
| `Server/Services/EnemyService.luau` | остановка спавна, режим добивания, масштаб характеристик от уровня |
| `Server/Services/RewardService.luau` | награда по режиму и исходу, выдача предметов, submit рекорда |
| `Server/Services/DataService.luau` | `AdvanceStoryStage`, `AddItem`, `SetEquippedItem`, `RecordQuestProgress`, `ClaimWheel` |
| `Server/Services/LobbyService.luau` | объекты: колесо, стенд рекордсменов, доска квестов |
| `Client/Controllers/HudController.luau` | таймер фазы, полоса HP босса |

## Порядок работы

1. Конфиги и типы: `Stages`, `Bosses`, `Items`, `Balance`, `Types`, `Net`.
2. Сюжет без босса: `StageService`, выбор уровня у портала, фазы, награда по режиму.
3. Босс: `BossService`, отрисовка, телеграфы, победа и открытие следующего уровня.
4. Экипировка: `ItemService`, выпадение, панель.
5. Стенд рекордсменов, квесты, колесо.
6. `stylua` + `selene` начисто, отчёт и инструкция проверки.

Этап большой — резать его на несколько сессий нормально. Точки, после которых
можно останавливаться без незавершённого кода: конец шага 2, конец шага 3,
конец шага 4.

## Приёмка (раздел 9 ТЗ)

- Сюжет проходится последовательно: пятый уровень недоступен, пока не пройден четвёртый.
- Босс убиваем, и его смерть открывает следующий уровень.
- Рекорд бесконечного режима попадает на стенд.
