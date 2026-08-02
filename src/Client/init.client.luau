--!strict
--[[
	Клиентский загрузчик. Полностью повторяет логику серверного (см. Server/init.server.luau):
	require всех контроллеров -> все Init() -> все Start().
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Types"))

type Controller = Types.Controller

local controllersFolder = script:WaitForChild("Controllers")

local moduleScripts: { ModuleScript } = {}
for _, child in controllersFolder:GetChildren() do
	if child:IsA("ModuleScript") then
		table.insert(moduleScripts, child)
	end
end
table.sort(moduleScripts, function(a: ModuleScript, b: ModuleScript): boolean
	return a.Name < b.Name
end)

local startClock = os.clock()

local controllers: { { name: string, controller: Controller } } = {}
for _, moduleScript in moduleScripts do
	local ok, result = xpcall(require, debug.traceback, moduleScript)
	if not ok then
		error(`[Client] Не удалось загрузить контроллер {moduleScript.Name}:\n{result}`, 0)
	end
	assert(
		typeof(result) == "table",
		`[Client] Контроллер {moduleScript.Name} должен возвращать таблицу, а вернул {typeof(
			result
		)}`
	)
	table.insert(controllers, { name = moduleScript.Name, controller = result :: Controller })
end

for _, entry in controllers do
	local init = entry.controller.Init
	if init then
		local ok, err = xpcall(init, debug.traceback)
		if not ok then
			error(`[Client] {entry.name}.Init() упал:\n{err}`, 0)
		end
	end
end

for _, entry in controllers do
	local start = entry.controller.Start
	if start then
		task.spawn(function()
			local ok, err = xpcall(start, debug.traceback)
			if not ok then
				warn(`[Client] {entry.name}.Start() упал:\n{err}`)
			end
		end)
	end
end

print(
	`[Client] Загружено контроллеров: {#controllers} за {math.floor(
		(os.clock() - startClock) * 1000
	)} мс`
)
