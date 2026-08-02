--!strict
--[[
	Серверный загрузчик.

	Требует все ModuleScript из папки Services, затем вызывает у них Init(),
	и только после того, как отработали ВСЕ Init, — Start().
	Это снимает проблему порядка зависимостей: к моменту Start любой другой
	сервис уже проинициализирован.

	Ошибка в Init считается фатальной: сервер поднимать в полурабочем состоянии
	бессмысленно, лучше увидеть красную ошибку сразу.
	Start запускается в отдельном потоке — сервису разрешено yield-иться.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Types"))

type Service = Types.Service

local servicesFolder = script:WaitForChild("Services")

-- Собираем модули и сортируем по имени, чтобы порядок загрузки был предсказуемым.
local moduleScripts: { ModuleScript } = {}
for _, child in servicesFolder:GetChildren() do
	if child:IsA("ModuleScript") then
		table.insert(moduleScripts, child)
	end
end
table.sort(moduleScripts, function(a: ModuleScript, b: ModuleScript): boolean
	return a.Name < b.Name
end)

local startClock = os.clock()

-- Фаза 1: require.
local services: { { name: string, service: Service } } = {}
for _, moduleScript in moduleScripts do
	local ok, result = xpcall(require, debug.traceback, moduleScript)
	if not ok then
		error(`[Server] Не удалось загрузить сервис {moduleScript.Name}:\n{result}`, 0)
	end
	assert(
		typeof(result) == "table",
		`[Server] Сервис {moduleScript.Name} должен возвращать таблицу, а вернул {typeof(
			result
		)}`
	)
	table.insert(services, { name = moduleScript.Name, service = result :: Service })
end

-- Фаза 2: Init.
for _, entry in services do
	local init = entry.service.Init
	if init then
		local ok, err = xpcall(init, debug.traceback)
		if not ok then
			error(`[Server] {entry.name}.Init() упал:\n{err}`, 0)
		end
	end
end

-- Фаза 3: Start.
for _, entry in services do
	local start = entry.service.Start
	if start then
		task.spawn(function()
			local ok, err = xpcall(start, debug.traceback)
			if not ok then
				warn(`[Server] {entry.name}.Start() упал:\n{err}`)
			end
		end)
	end
end

print(
	`[Server] Загружено сервисов: {#services} за {math.floor((os.clock() - startClock) * 1000)} мс`
)
