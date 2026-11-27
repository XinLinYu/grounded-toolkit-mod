--[[
    文件：lua/tests/lua_regression_test.lua
    职责：GroundedQoL Lua 逻辑层全业务场景离线自动化回归测试套件。
    运行方式：
      "C:\Program Files (x86)\Lua\5.3.6\bin\lua.exe" lua\tests\lua_regression_test.lua
    验证范围（直接加载真实未改动的 main.lua 与 json.lua，在全真模拟 UE4SS 运行时中驱动调度器）：
      - L1: 默认配置与 Steam 成就保护不变量（绝不调用 SwapToCustom/SetGameMode/UpdateCustomSettings）
      - L2: 死亡背包保留独立生效（DeathBehavior=1），不影响独立关闭的死亡耐久惩罚
      - L3: 免除死亡装备耐久惩罚独立生效，且双开关关闭后精准还原不同难度的原版基准值
      - L4: 多人联机客机权限隔离（客机不能改写死亡规则，也不能触发一键找回背包）
      - L5: 一键找回我的背包（唤醒远距 LOD、排除建筑战利品袋与空包与销毁中背包、不动队友包、清除物理速度、前方扇形错开落地并同步联机坐标）
      - L6: 一键找回全队背包（在线队友送回本人脚边、K2_TeleportTo 失败自动降级 K2_SetActorLocation、离线玩家背包归房主代收）
      - L7: 本人无背包但存在队友背包时的友好中文引导提示
      - L8: 退出存档切换世界时清空基准值缓存，进入新难度存档正确读取新基准值
      - L9: 原有核心功能无回归（物品堆叠保护单件装备、伤害倍率、采集倍率排除背包/乳牙且搬运物封顶 12）
      - L10: 游玩期性能不变量（ADR-0004：30 秒内 0 次周期全图 LOD/LootComponent 扫表、0 次重复 FindFirstOf、0 次无效写盘）
      - L11: SpawnLoot 实时 Hook 接管新掉落组件并在关闭采集倍率时无损还原
      - L12: 打开菜单 5 秒冷却静默软刷新（refresh_catalog_soft）与 M 地图 1.8 秒刷新节流
]]

-- ============================================================
-- 1. 路径准备与真实 json.lua 加载
-- ============================================================
local scriptPath = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("/", "\\")
local repoRoot = scriptPath:match("^(.*)\\lua\\tests\\[^\\]+$") or "."
local scriptsDir = repoRoot .. "\\lua\\GroundedQoL\\Scripts"
local modDataDir = repoRoot .. "\\lua\\GroundedQoL\\data"
local mainLuaPath = scriptsDir .. "\\main.lua"

package.path = scriptsDir .. "\\?.lua;" .. package.path
local json = require("json")

--- 轻量断言辅助，失败时输出中文用例名与原因并终止测试进程（返回非零码）。
local passedCount = 0
local function assertEq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("[断言失败] %s | 期望=%s, 实际=%s", msg, tostring(expected), tostring(actual)), 2)
    end
end

local function assertNear(actual, expected, eps, msg)
    if math.abs((actual or 0) - expected) > (eps or 0.001) then
        error(string.format("[断言失败] %s | 期望=%.4f (±%.4f), 实际=%.4f", msg, expected, eps or 0.001, actual or 0), 2)
    end
end

local function assertTrue(cond, msg)
    if not cond then
        error("[断言失败] " .. tostring(msg), 2)
    end
end

local function assertContains(haystack, needle, msg)
    if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
        error(string.format("[断言失败] %s | 未在 '%s' 中找到 '%s'", msg, tostring(haystack), tostring(needle)), 2)
    end
end

--- 原子写入测试用 IPC 文件（config.json / actions.json）。
local function writeJsonFile(path, tbl)
    os.execute('mkdir "' .. modDataDir .. '" >nul 2>&1')
    local f = assert(io.open(path, "wb"))
    f:write(json.encode(tbl))
    f:close()
end

--- 读取并解码 Lua 端生成的 status.json。
local function readJsonFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return json.decode(s)
end

-- ============================================================
-- 2. UE4SS 模拟运行时构建（虚拟时钟 + UObject 工厂 + 成就安全探针）
-- ============================================================
local nextAddr = 0x10000000
local function allocAddr()
    nextAddr = nextAddr + 0x1000
    return nextAddr
end

--- 构造 FName 模拟对象，支持 :ToString()。
local function makeFName(s)
    return {
        _str = tostring(s or "None"),
        ToString = function(self) return self._str end,
    }
end

--- 构造模拟 UObject 基底（IsValid / GetAddress / GetFullName / GetClass）。
local function makeUObject(className, fullName, extra)
    local obj = extra or {}
    obj._addr = obj._addr or allocAddr()
    obj._valid = (obj._valid ~= false)
    obj._className = className
    obj._fullName = fullName or (className .. "_Instance")
    function obj:IsValid() return self._valid end
    function obj:GetAddress() return self._addr end
    function obj:GetFullName() return self._fullName end
    function obj:GetClass()
        local clsName = self._className
        return {
            IsValid = function() return true end,
            GetFName = function() return makeFName(clsName) end,
        }
    end
    return obj
end

--- 构造模拟玩家角色及其 PlayerState（含 GUID、名称、位置与朝向）。
local function makePlayer(opts)
    local ps = makeUObject("SurvivalPlayerState", "PS_" .. opts.name, {
        PlayerGuid = opts.guid,
        GetPlayerGuid = function(self) return self.PlayerGuid end,
        GetPlayerName = function(self) return makeFName(opts.name) end,
    })
    local pawn = makeUObject("SurvivalPlayerCharacter", "Char_" .. opts.name, {
        PlayerGuid = opts.guid,
        PlayerState = ps,
        _loc = { X = opts.x, Y = opts.y, Z = opts.z },
        _fwd = { X = opts.fx or 1, Y = opts.fy or 0, Z = 0 },
        K2_GetActorLocation = function(self) return { X = self._loc.X, Y = self._loc.Y, Z = self._loc.Z } end,
        GetActorForwardVector = function(self) return { X = self._fwd.X, Y = self._fwd.Y, Z = self._fwd.Z } end,
        InventoryComponent = makeUObject("InventoryComponent", "Inv_" .. opts.name, { Items = {} }),
    })
    return pawn, ps
end

--- 构造模拟 ALootBag（含类型、空包状态、物理速度重置记录、瞬移降级开关与联机同步计数）。
local function makeLootBag(opts)
    local invItems = {}
    for i = 1, (opts.itemCount or 0) do
        invItems[i] = makeUObject("Item", "Item_" .. i, { StackSize = 5 })
    end
    local inv = makeUObject("InventoryComponent", "BagInv_" .. opts.id, {
        Items = invItems,
        IsInventoryEmpty = function(self) return #self.Items == 0 end,
    })
    local root = makeUObject("PrimitiveComponent", "BagRoot_" .. opts.id, {
        linVel = { X = opts.vx or 0, Y = opts.vy or 0, Z = opts.vz or 0 },
        angVel = { X = opts.avx or 0, Y = opts.avy or 0, Z = opts.avz or 0 },
        SetPhysicsLinearVelocity = function(self, v)
            self.linVel = { X = v.X, Y = v.Y, Z = v.Z }
        end,
        SetPhysicsAngularVelocityInDegrees = function(self, v)
            self.angVel = { X = v.X, Y = v.Y, Z = v.Z }
        end,
    })
    local bag = makeUObject("LootBag", opts.fullName or ("BP_Backpack_C_" .. opts.id), {
        _id = opts.id,
        _loc = { X = opts.x or 0, Y = opts.y or 0, Z = opts.z or 0 },
        _destroying = opts.destroying == true,
        _rejectTeleportTo = opts.rejectTeleportTo == true,
        _movedCount = 0,
        _usedFallbackSetLoc = false,
        _resyncCount = 0,
        LootBagType = opts.bagType, -- 1=PlayerBackpack, 0=Undefined(BuildingLootBag)
        OwnerPlayerGuid = opts.ownerGuid or { A = 0, B = 0, C = 0, D = 0 },
        OwnerName = makeFName(opts.ownerName or ""),
        InventoryComponent = inv,
        RootComponent = root,
        IsActorBeingDestroyed = function(self) return self._destroying end,
        K2_GetActorLocation = function(self) return { X = self._loc.X, Y = self._loc.Y, Z = self._loc.Z } end,
        K2_TeleportTo = function(self, dest, _rot)
            if self._rejectTeleportTo then return false end
            self._loc = { X = dest.X, Y = dest.Y, Z = dest.Z }
            self._movedCount = self._movedCount + 1
            return true
        end,
        K2_SetActorLocation = function(self, dest, _sweep, _hit, _teleport)
            self._loc = { X = dest.X, Y = dest.Y, Z = dest.Z }
            self._movedCount = self._movedCount + 1
            self._usedFallbackSetLoc = true
            return true
        end,
        ResyncReplicationTransform = function(self)
            self._resyncCount = self._resyncCount + 1
        end,
    })
    return bag
end

--- 构造模拟未流式加载的远距 ULootBagLODActor（支持模拟蓝图类名、UProxyLootBagActor 归属与 ProxyInventory 判空）。
local function makeUnloadedLootBagLod(bag, lodOpts)
    lodOpts = lodOpts or {}
    local actorClsName = lodOpts.actorClassName or "BP_Backpack_C"
    local proxyInv = makeUObject("ProxyInventoryComponent", "ProxyInv_" .. bag._id, {
        Items = bag.InventoryComponent.Items,
        IsInventoryEmpty = function(self) return #self.Items == 0 end,
    })
    local invLodComp = makeUObject("InventoryLODComponent", "InvLod_" .. bag._id, {
        ProxyComponent = proxyInv,
    })
    local proxyActor = makeUObject("ProxyLootBagActor", "Proxy_" .. bag._id, {
        OwnerPlayerGuid = lodOpts.proxyGuid or bag.OwnerPlayerGuid,
        OwnerName = makeFName(lodOpts.proxyOwnerName ~= nil and lodOpts.proxyOwnerName or bag.OwnerName:ToString()),
    })
    local lod = makeUObject("LootBagLODActor", "LOD_" .. bag._id, {
        FullActor = nil,
        ProxyActor = proxyActor,
        LODComponents = { invLodComp },
        _convertCalled = 0,
        GetActorLocation = function() return bag:K2_GetActorLocation() end,
        GetActorClassHard = function()
            return {
                IsValid = function() return true end,
                GetFName = function() return makeFName(actorClsName) end,
            }
        end,
        GetActorClassSoft = function() return "/Game/Blueprints/" .. actorClsName end,
        IsFullActorType = function(_, cls)
            return cls ~= nil and actorClsName == "BP_Backpack_C"
        end,
        ConvertToFullActorBlocking = function(self)
            self._convertCalled = self._convertCalled + 1
            self.FullActor = bag
        end,
        K2_GetFullActor = function(self) return self.FullActor end,
    })
    return lod
end

--- 构造模拟游戏世界状态，内置成就安全探针（若调用任何会切自定义模式的接口立即累加计数）。
local world = {
    inWorld = true,
    isHost = true,
    customModeCalls = 0,
    gs = nil,
    pc = nil,
    hostPawn = nil,
    teammates = {},
    loadedBags = {},
    lods = {},
    lootComponents = {},
    globalItemData = nil,
}

local function buildWorld(opts)
    opts = opts or {}
    world.inWorld = true
    world.isHost = (opts.isHost ~= false)
    world.customModeCalls = 0

    local gms = makeUObject("SurvivalGameModeSettings", "ActiveGameModeSettings", {
        GameDifficulty = opts.difficulty or 1,
        PlayerDamageMultiplier = opts.basePlayerDmg or 1.0,
        EnemyDamageMultiplier = opts.baseEnemyDmg or 1.0,
        bAutoCompleteBuildings = false,
        bRecipesRequireIngredients = true,
        bUnlockAllRecipes = false,
        DeathBehavior = opts.baseDeathBehavior or 0,
        ItemDurabilityPenaltyOnDeathPercentage = opts.baseDurabilityPenalty or 0.10,
    })

    local modeMgr = makeUObject("SurvivalModeManagerComponent", "ModeMgr", {
        CurrentGameMode = 1, -- EGameMode::Normal（原版生存模式，Steam 成就开启）
        GameModeSettings = gms,
        SwapToCustom = function() world.customModeCalls = world.customModeCalls + 1 end,
        SetGameMode = function() world.customModeCalls = world.customModeCalls + 1 end,
        UpdateCustomSettings = function() world.customModeCalls = world.customModeCalls + 1 end,
    })

    local hostPawn, hostPs = makePlayer({
        name = "HostAlice",
        guid = { A = 1, B = 2, C = 3, D = 4 },
        x = 1000, y = 2000, z = 300,
        fx = 1, fy = 0,
    })
    local mateBPawn = makePlayer({
        name = "TeammateBob",
        guid = { A = 5, B = 6, C = 7, D = 8 },
        x = 9000, y = 9000, z = 500,
        fx = 0, fy = 1,
    })

    world.hostPawn = hostPawn
    world.teammates = { hostPawn, mateBPawn }
    world.pc = makeUObject("SurvivalPlayerController", "PC_Host", {
        Pawn = hostPawn,
        PlayerState = hostPs,
    })

    world.lods = {}
    world.loadedBags = {}
    world.lootComponents = {}

    world.gs = makeUObject("SurvivalGameState", "GS_World_" .. tostring(opts.worldTag or "A"), {
        HasAuthority = function() return world.isHost end,
        SurvivalModeManagerComponent = modeMgr,
        PartyComponent = makeUObject("PartyComponent", "PartyComp", {
            PartyMembers = world.teammates,
        }),
        LODActorManagerComponent = makeUObject("LODActorManagerComponent", "LodMgr", {
            LODActors = world.lods,
        }),
        TrackedCollectibles = {},
        ResourceSurveyComponent = makeUObject("ResourceSurveyComponent", "SurveyComp", {
            ActivateAllSurveyors = function() end,
        }),
    })

    -- 构造用于回归校验原有核心功能的 GlobalItemData 与 LootComponent
    local stackEntries = {
        { tag = "Item.Stack.Resource", val = 10 },
        { tag = "Item.Stack.Equipment", val = 1 }, -- 单件装备基础堆叠=1，必须受保护不被放大
    }
    world.globalItemData = makeUObject("GlobalItemData", "GlobalItemData", {
        ItemStackBonusPerTier = 5,
        MaxDropStackSize = 10,
        _entries = stackEntries,
        StackSizes = {
            ForEach = function(_, cb)
                for _, e in ipairs(stackEntries) do
                    cb(
                        { get = function() return { TagName = makeFName(e.tag) } end },
                        { get = function() return e.val end, set = function(_, v) e.val = v end }
                    )
                end
            end,
        },
    })

    return gms, modeMgr, hostPawn, mateBPawn
end

-- ============================================================
-- 3. 注入模拟 UE4SS 全局 API 并加载真实 main.lua
-- ============================================================
local mockClock = 10.0
os.clock = function() return mockClock end

-- 屏蔽 DLL 加载，防止 lua.exe 尝试挂接 DX12 图形钩子
package.loadlib = function() return function() return 0 end end

local capturedLoopCallback = nil
local capturedHooks = {}
local perfCounters = {
    findFirst = {},
    findAll = {},
    fileWrites = {},
    gameThreadTicks = 0,
}

local origIoOpen = io.open
io.open = function(path, mode)
    if type(mode) == "string" and mode:find("w") and type(path) == "string" then
        local base = path:match("([^\\]+)$") or path
        perfCounters.fileWrites[base] = (perfCounters.fileWrites[base] or 0) + 1
    end
    return origIoOpen(path, mode)
end

local gameInstanceMock = makeUObject("SurvivalGameInstance", "GI", {
    GlobalTableData = nil,
    WidgetManager = nil,
    FoliageMappings = nil,
})

package.loaded["UEHelpers"] = {
    GetGameInstance = function() return gameInstanceMock end,
    GetPlayerController = function() return world.inWorld and world.pc or nil end,
}

_G.FName = makeFName
_G.RegisterHook = function(funcPath, preFn, postFn)
    capturedHooks[funcPath] = { pre = preFn, post = postFn }
end
_G.LoopAsync = function(_intervalMs, fn) capturedLoopCallback = fn end
_G.ExecuteInGameThread = function(fn)
    perfCounters.gameThreadTicks = perfCounters.gameThreadTicks + 1
    fn()
end

_G.StaticFindObject = function(path)
    if path == "/Script/Maine.Default__SurvivalGameplayStatics" then
        return makeUObject("SurvivalGameplayStatics", path, {
            GetPlayerCharacterFromPlayerGuid = function(_, _gs, guid)
                for _, ch in ipairs(world.teammates) do
                    local g = ch.PlayerGuid
                    if g and guid and g.A == guid.A and g.B == guid.B and g.C == guid.C and g.D == guid.D then
                        return ch
                    end
                end
                return nil
            end,
        })
    end
    return nil
end

_G.FindFirstOf = function(cls)
    perfCounters.findFirst[cls] = (perfCounters.findFirst[cls] or 0) + 1
    if cls == "GlobalItemData" then return world.globalItemData end
    if not world.inWorld then return nil end
    if cls == "SurvivalGameState" then return world.gs end
    if cls == "SurvivalPlayerCharacter" then return world.hostPawn end
    return nil
end

_G.FindAllOf = function(cls)
    perfCounters.findAll[cls] = (perfCounters.findAll[cls] or 0) + 1
    if not world.inWorld then return {} end
    if cls == "SurvivalPlayerCharacter" then return world.teammates end
    if cls == "LootBag" then return world.loadedBags end
    if cls == "LootComponent" then return world.lootComponents end
    if cls == "SurvivalGameModeSettings" then
        return { world.gs.SurvivalModeManagerComponent.GameModeSettings }
    end
    return {}
end

-- 清理残留测试文件后，直接执行真实 main.lua
os.remove(modDataDir .. "\\config.json")
os.remove(modDataDir .. "\\actions.json")
os.remove(modDataDir .. "\\status.json")
os.remove(modDataDir .. "\\catalog.json")
os.remove(modDataDir .. "\\map_live.json")

-- 抑制 main.lua 控制台冗余输出（仅记录必要诊断）
local origPrint = print
local logs = {}
_G.print = function(s) table.insert(logs, tostring(s)) end

assert(loadfile(mainLuaPath))()
assertTrue(type(capturedLoopCallback) == "function", "main.lua 必须注册唯一 LoopAsync 调度器")

--- 推进虚拟时钟并执行一次真实 onGameThreadTick()。
local function stepTick(dt)
    mockClock = mockClock + (dt or 1.0)
    capturedLoopCallback()
end

local actionSeq = 0
local function sendAction(actionType)
    actionSeq = actionSeq + 1
    writeJsonFile(modDataDir .. "\\actions.json", { seq = actionSeq, type = actionType })
end

-- ============================================================
-- 4. 执行 L1 ~ L9 全场景业务回归用例
-- ============================================================
local function runCase(name, fn)
    local ok, err = pcall(fn)
    if not ok then
        origPrint("[FAIL] " .. name .. "\n  " .. tostring(err))
        os.exit(1)
    end
    passedCount = passedCount + 1
    origPrint("[PASS] " .. name)
end

local gms, modeMgr, hostPawn, mateBPawn = buildWorld({ baseDeathBehavior = 0, baseDurabilityPenalty = 0.10 })

runCase("L1: 默认配置下保持原版死亡规则且 100% 不触碰自定义模式（保 Steam 成就）", function()
    writeJsonFile(modDataDir .. "\\config.json", {
        stackEnabled = true, stackMultiplier = 10,
        damageEnabled = true, playerDamageMultiplier = 1.5, enemyDamageMultiplier = 1.0,
        harvestEnabled = true, harvestMultiplier = 3,
        harvestAffectHauling = true, harvestAffectPickup = true,
        instantBuildEnabled = false, freeCraftEnabled = false, unlockAllRecipes = false,
        keepInventoryOnDeath = false, noDeathDurabilityPenalty = false,
    })
    stepTick(1.0)
    stepTick(3.0) -- 完成首次 2.5s 进图初始化扫描

    assertEq(gms.DeathBehavior, 0, "默认关闭死亡保留时 DeathBehavior 应保持原版 0")
    assertNear(gms.ItemDurabilityPenaltyOnDeathPercentage, 0.10, 0.0001, "默认关闭耐久保护时应保持原版 0.10")
    assertEq(modeMgr.CurrentGameMode, 1, "存档模式必须保持原版 Normal(1)")
    assertEq(world.customModeCalls, 0, "严禁调用 SwapToCustom/SetGameMode/UpdateCustomSettings")

    local st = readJsonFile(modDataDir .. "\\status.json")
    assertTrue(st ~= nil and st.inWorld == true and st.isHost == true, "status.json 应正确上报房主进图状态")
    assertEq(st.liveKeepInventoryOnDeath, false, "status.json 应上报 liveKeepInventoryOnDeath=false")
    assertEq(st.liveNoDeathDurabilityPenalty, false, "status.json 应上报 liveNoDeathDurabilityPenalty=false")
end)

runCase("L2: 开启死亡背包保留后独立生效（不连带修改耐久惩罚、不切自定义模式）", function()
    writeJsonFile(modDataDir .. "\\config.json", {
        keepInventoryOnDeath = true,
        noDeathDurabilityPenalty = false,
    })
    stepTick(1.0)

    assertEq(gms.DeathBehavior, 1, "开启后 DeathBehavior 必须为 KeepItemsOnDeath(1)")
    assertNear(gms.ItemDurabilityPenaltyOnDeathPercentage, 0.10, 0.0001, "未勾选耐久子开关时应保持原版 0.10")
    assertEq(world.customModeCalls, 0, "开启死亡保留绝不能触发自定义模式切换")

    local st = readJsonFile(modDataDir .. "\\status.json")
    assertEq(st.liveKeepInventoryOnDeath, true, "status.json 应实时反映 liveKeepInventoryOnDeath=true")
    assertEq(st.liveNoDeathDurabilityPenalty, false, "status.json 应实时反映 liveNoDeathDurabilityPenalty=false")
end)

runCase("L3: 独立开启免除死亡耐久惩罚及双开关关闭后的无损原版基准还原", function()
    writeJsonFile(modDataDir .. "\\config.json", {
        keepInventoryOnDeath = true,
        noDeathDurabilityPenalty = true,
    })
    stepTick(1.0)
    assertNear(gms.ItemDurabilityPenaltyOnDeathPercentage, 0.0, 0.0001, "勾选耐久子开关后应设为 0.0")
    local stOn = readJsonFile(modDataDir .. "\\status.json")
    assertEq(stOn.liveNoDeathDurabilityPenalty, true, "status.json 应上报 liveNoDeathDurabilityPenalty=true")

    -- 关闭双开关，验证精准还原为进入存档时的原版基准值
    writeJsonFile(modDataDir .. "\\config.json", {
        keepInventoryOnDeath = false,
        noDeathDurabilityPenalty = false,
    })
    stepTick(1.0)
    assertEq(gms.DeathBehavior, 0, "关闭死亡保留应精确还原为 0")
    assertNear(gms.ItemDurabilityPenaltyOnDeathPercentage, 0.10, 0.0001, "关闭耐久保护应精确还原为 0.10")
    assertEq(world.customModeCalls, 0, "还原过程同样不得触碰自定义模式")
end)

runCase("L4: 多人联机客机权限隔离（无法篡改死亡规则或执行找回背包）", function()
    world.isHost = false
    local remoteBag = makeLootBag({
        id = "ClientCheckBag", bagType = 1, itemCount = 3,
        ownerGuid = hostPawn.PlayerGuid, ownerName = "HostAlice",
        x = -5000, y = -5000, z = 0,
    })
    world.loadedBags = { remoteBag }

    writeJsonFile(modDataDir .. "\\config.json", {
        keepInventoryOnDeath = true,
        noDeathDurabilityPenalty = true,
    })
    sendAction("recover_my_backpacks")
    stepTick(1.0)

    assertEq(gms.DeathBehavior, 0, "客机不得修改 DeathBehavior")
    assertNear(gms.ItemDurabilityPenaltyOnDeathPercentage, 0.10, 0.0001, "客机不得修改死亡耐久惩罚")
    assertEq(remoteBag._movedCount, 0, "客机不得移动任何掉落背包")
    local st = readJsonFile(modDataDir .. "\\status.json")
    assertEq(st.isHost, false, "status.json 应正确上报 isHost=false")
    assertContains(st.lastMessage, "仅房主", "客机误触发找回时应提示仅房主可操作")

    -- 恢复房主身份供后续用例测试
    world.isHost = true
    writeJsonFile(modDataDir .. "\\config.json", {
        keepInventoryOnDeath = false,
        noDeathDurabilityPenalty = false,
    })
    stepTick(1.0)
end)

-- 构造全边界背包场景供 L5 与 L6 使用
local bagHostLoaded = makeLootBag({
    id = "HostLoaded", bagType = 1, itemCount = 4,
    ownerGuid = { A = 1, B = 2, C = 3, D = 4 }, ownerName = "HostAlice",
    x = -50000, y = 30000, z = -200,
    vx = 120, vy = -240, vz = -900, avx = 50, avy = 60, avz = 70,
})
local bagHostRemote = makeLootBag({
    id = "HostRemoteLOD", bagType = 1, itemCount = 2,
    ownerGuid = { A = 1, B = 2, C = 3, D = 4 }, ownerName = "HostAlice",
    x = 80000, y = -40000, z = 100,
})
local lodHostRemote = makeUnloadedLootBagLod(bagHostRemote, { actorClassName = "BP_Backpack_C" })

-- 复现真实闪退现场：68 个未加载的实验室 Ominent 宝箱 + 1 个未加载建筑战利品袋 + 1 个未加载空背包 + 1 个未加载队友远距背包
local ominentChestLods = {}
for idx = 1, 68 do
    local chestBag = makeLootBag({
        id = "OminentChest_" .. idx, bagType = 0, itemCount = 5,
        ownerGuid = { A = 0, B = 0, C = 0, D = 0 }, ownerName = "",
        x = -30000 + idx * 100, y = 40000, z = -500,
    })
    ominentChestLods[idx] = makeUnloadedLootBagLod(chestBag, { actorClassName = "BP_Ominent_Chest_C" })
end
local unloadedBuildingLod = makeUnloadedLootBagLod(makeLootBag({
    id = "UnloadedBuildingBag", bagType = 0, itemCount = 8,
    ownerGuid = { A = 1, B = 2, C = 3, D = 4 }, ownerName = "HostAlice",
}), { actorClassName = "BP_BuildingLootBag_C" })
local unloadedEmptyHostLod = makeUnloadedLootBagLod(makeLootBag({
    id = "UnloadedEmptyHostBag", bagType = 1, itemCount = 0,
    ownerGuid = { A = 1, B = 2, C = 3, D = 4 }, ownerName = "HostAlice",
}), { actorClassName = "BP_Backpack_C" })
local unloadedMateBLod = makeUnloadedLootBagLod(makeLootBag({
    id = "UnloadedMateBBag", bagType = 1, itemCount = 3,
    ownerGuid = { A = 5, B = 6, C = 7, D = 8 }, ownerName = "TeammateBob",
}), { actorClassName = "BP_Backpack_C" })

local bagHostEmpty = makeLootBag({
    id = "HostEmpty", bagType = 1, itemCount = 0,
    ownerGuid = { A = 1, B = 2, C = 3, D = 4 }, ownerName = "HostAlice",
    x = 4000, y = 4000, z = 0,
})
local bagBuilding = makeLootBag({
    id = "BuildingLoot", bagType = 0, itemCount = 10, -- 建筑战利品袋（Undefined=0）
    ownerGuid = { A = 1, B = 2, C = 3, D = 4 }, ownerName = "HostAlice",
    x = 5000, y = 5000, z = 0,
})
local bagMateB = makeLootBag({
    id = "MateBBag", bagType = 1, itemCount = 5,
    ownerGuid = { A = 5, B = 6, C = 7, D = 8 }, ownerName = "TeammateBob",
    x = -20000, y = -20000, z = 0,
    rejectTeleportTo = true, -- 模拟狭小洞穴 K2_TeleportTo 被拒，验证自动降级 K2_SetActorLocation
})
local bagOfflineC = makeLootBag({
    id = "OfflineCBag", bagType = 1, itemCount = 3,
    ownerGuid = { A = 9, B = 9, C = 9, D = 9 }, ownerName = "OfflineCharlie",
    x = 30000, y = 30000, z = 0,
})
local bagDestroying = makeLootBag({
    id = "DestroyingBag", bagType = 1, itemCount = 2,
    ownerGuid = { A = 1, B = 2, C = 3, D = 4 }, ownerName = "HostAlice",
    x = 6000, y = 6000, z = 0, destroying = true,
})

runCase("L5a: 68 个未加载 Ominent 宝箱场景下点找回（0 掉落背包时必须 0 次 LOD 唤醒，防闪退）", function()
    world.lods = {}
    for _, cl in ipairs(ominentChestLods) do table.insert(world.lods, cl) end
    table.insert(world.lods, unloadedBuildingLod)
    table.insert(world.lods, unloadedEmptyHostLod)
    world.gs.LODActorManagerComponent.LODActors = world.lods
    world.loadedBags = { bagBuilding }

    sendAction("recover_my_backpacks")
    stepTick(1.0)

    local totalWoke = 0
    for _, cl in ipairs(ominentChestLods) do totalWoke = totalWoke + cl._convertCalled end
    assertEq(totalWoke, 0, "严禁唤醒任何未加载 Ominent 实验室宝箱（防止子关卡空指针闪退）")
    assertEq(unloadedBuildingLod._convertCalled, 0, "严禁唤醒未加载建筑战利品袋")
    assertEq(unloadedEmptyHostLod._convertCalled, 0, "未加载空背包应在 ProxyInventory 层跳过，不触发唤醒")
end)

runCase("L5: 一键找回我的背包（仅唤醒房主远距包、绝不唤醒 68 宝箱/队友包、清速度、扇形错开落地并联机同步）", function()
    world.lods = { lodHostRemote, unloadedBuildingLod, unloadedEmptyHostLod, unloadedMateBLod }
    for _, cl in ipairs(ominentChestLods) do table.insert(world.lods, cl) end
    world.gs.LODActorManagerComponent.LODActors = world.lods
    world.loadedBags = { bagHostLoaded, bagHostEmpty, bagBuilding, bagMateB, bagOfflineC, bagDestroying }

    sendAction("recover_my_backpacks")
    stepTick(1.0)

    -- 1. 仅房主远距非空背包被唤醒，68 宝箱/建筑袋/空包/队友远距包均 0 唤醒
    assertEq(lodHostRemote._convertCalled, 1, "房主远距非空 ULootBagLODActor 必须调用 ConvertToFullActorBlocking 唤醒")
    assertEq(unloadedMateBLod._convertCalled, 0, "找回我的背包时不得唤醒队友的远距背包")
    local chestWoke = 0
    for _, cl in ipairs(ominentChestLods) do chestWoke = chestWoke + cl._convertCalled end
    assertEq(chestWoke, 0, "68 个未加载 Ominent 宝箱唤醒次数必须严格为 0")

    -- 2. 只有房主自己的 2 个非空玩家背包被移动
    assertEq(bagHostLoaded._movedCount, 1, "房主已加载非空背包应移动 1 次")
    assertEq(bagHostRemote._movedCount, 1, "房主远距唤醒后的非空背包应移动 1 次")
    assertEq(bagHostEmpty._movedCount, 0, "空背包必须被跳过")
    assertEq(bagBuilding._movedCount, 0, "建筑战利品袋(LootBagType=0)严禁被找回")
    assertEq(bagMateB._movedCount, 0, "找回我的背包时不得移动在线队友背包")
    assertEq(bagOfflineC._movedCount, 0, "找回我的背包时不得移动离线玩家背包")
    assertEq(bagDestroying._movedCount, 0, "正在销毁的背包必须被跳过")

    -- 3. 物理速度清零 + 联机坐标同步
    assertEq(bagHostLoaded.RootComponent.linVel.Z, 0, "瞬移前必须清空线性物理速度防止落地弹飞")
    assertEq(bagHostLoaded.RootComponent.angVel.X, 0, "瞬移前必须清空角速度")
    assertEq(bagHostLoaded._resyncCount, 1, "移动后必须调用 ResyncReplicationTransform 同步联机坐标")
    assertEq(bagHostRemote._resyncCount, 1, "远距背包移动后也必须同步联机坐标")

    -- 4. 校验前方扇形错开坐标（房主在 (1000, 2000, 300) 面向 +X，2 个包应在 X=1140, Z=345, Y 错开 65cm）
    assertNear(bagHostLoaded._loc.X, 1140.0, 0.1, "背包 1 X 坐标应在房主正前方 140cm")
    assertNear(bagHostRemote._loc.X, 1140.0, 0.1, "背包 2 X 坐标应在房主正前方 140cm")
    assertNear(bagHostLoaded._loc.Z, 345.0, 0.1, "背包 1 Z 坐标应抬高 45cm 防穿模")
    assertNear(bagHostRemote._loc.Z, 345.0, 0.1, "背包 2 Z 坐标应抬高 45cm 防穿模")
    assertNear(math.abs(bagHostLoaded._loc.Y - bagHostRemote._loc.Y), 65.0, 0.1, "多背包左右间距应为 65cm 避免碰撞重叠")

    local st = readJsonFile(modDataDir .. "\\status.json")
    assertContains(st.lastMessage, "2 个掉落背包", "顶部状态栏应明确回报找回 2 个背包")
end)

runCase("L6: 一键找回全队背包（在线队友各回脚边、降级瞬移兜底、离线玩家归房主、仍排除 68 宝箱与建筑袋）", function()
    -- 仅保留已加载的 bagMateB 以验证精确 1 包落点，同时保留 68 个未加载 Ominent 宝箱验证 0 唤醒
    world.lods = { lodHostRemote, unloadedBuildingLod, unloadedEmptyHostLod }
    for _, cl in ipairs(ominentChestLods) do table.insert(world.lods, cl) end
    world.gs.LODActorManagerComponent.LODActors = world.lods

    sendAction("recover_all_backpacks")
    stepTick(1.0)

    local chestWoke = 0
    for _, cl in ipairs(ominentChestLods) do chestWoke = chestWoke + cl._convertCalled end
    assertEq(chestWoke, 0, "全队找回时 68 个未加载 Ominent 宝箱唤醒次数也必须严格为 0")

    -- TeammateBob 位于 (9000, 9000, 500) 面向 +Y，单个包应落在 (9000, 9135, 545)，且走降级 K2_SetActorLocation
    assertEq(bagMateB._movedCount, 1, "在线队友 Bob 的背包应被找回")
    assertEq(bagMateB._usedFallbackSetLoc, true, "K2_TeleportTo 返回 false 时必须自动降级调用 K2_SetActorLocation")
    assertEq(bagMateB._resyncCount, 1, "队友背包瞬移后必须触发联机坐标同步")
    assertNear(bagMateB._loc.X, 9000.0, 0.1, "Bob 背包 X 坐标应贴合 Bob")
    assertNear(bagMateB._loc.Y, 9135.0, 0.1, "Bob 背包 Y 坐标应在 Bob 正前方(+Y) 135cm")
    assertNear(bagMateB._loc.Z, 545.0, 0.1, "Bob 背包 Z 坐标应在 Bob 上方 45cm")

    -- OfflineCharlie 的背包应送至房主正前方（与房主 2 个包一起排成 3 包扇形，间距 65cm 无重叠）
    assertEq(bagOfflineC._movedCount, 1, "离线玩家 Charlie 的背包应送至房主脚边代收")
    assertNear(bagOfflineC._loc.X, 1140.0, 0.1, "离线玩家背包应落在房主正前方")
    assertNear(bagOfflineC._loc.Z, 345.0, 0.1, "离线玩家背包 Z 高度应与房主抬高一致")
    assertTrue(
        math.abs(bagOfflineC._loc.Y - bagHostLoaded._loc.Y) >= 64.9 and
        math.abs(bagOfflineC._loc.Y - bagHostRemote._loc.Y) >= 64.9,
        "离线玩家背包与房主背包在扇形阵列中不得重叠"
    )

    -- 建筑战利品袋与空包依旧丝毫不动
    assertEq(bagBuilding._movedCount, 0, "全队找回同样严禁触碰建筑战利品袋")
    assertEq(bagHostEmpty._movedCount, 0, "全队找回同样跳过空背包")

    local st = readJsonFile(modDataDir .. "\\status.json")
    assertContains(st.lastMessage, "4 个掉落背包", "应回报全队共找回 4 个非空玩家背包")
    assertContains(st.lastMessage, "1 个离线玩家背包已送至房主脚边", "应明确提示离线玩家背包已送至房主脚边")
end)

runCase("L7: 房主本人无掉落背包但世界存在队友背包时的清晰引导提示", function()
    world.lods = {}
    world.gs.LODActorManagerComponent.LODActors = world.lods
    world.loadedBags = { bagMateB }

    sendAction("recover_my_backpacks")
    stepTick(1.0)
    local st = readJsonFile(modDataDir .. "\\status.json")
    assertContains(st.lastMessage, "另有 1 个队友背包", "应提示存在队友背包并引导点击找回全队背包")
end)

runCase("L8: 退出存档并进入不同原版难度新存档时，基准值缓存彻底清空不串档", function()
    -- 模拟退回主菜单
    world.inWorld = false
    stepTick(1.0)
    local stMenu = readJsonFile(modDataDir .. "\\status.json")
    assertEq(stMenu.inWorld, false, "退回主菜单时 status.json 应上报 inWorld=false")

    -- 进入一个基准耐久惩罚为 0.25 的新存档，先开启再关闭，验证还原为 0.25 而非旧档 0.10
    local gms2 = buildWorld({ worldTag = "B", baseDeathBehavior = 0, baseDurabilityPenalty = 0.25 })
    writeJsonFile(modDataDir .. "\\config.json", {
        keepInventoryOnDeath = true,
        noDeathDurabilityPenalty = true,
    })
    stepTick(1.0)
    assertEq(gms2.DeathBehavior, 1, "新档开启死亡保留生效")
    assertNear(gms2.ItemDurabilityPenaltyOnDeathPercentage, 0.0, 0.0001, "新档开启免除耐久惩罚生效")

    writeJsonFile(modDataDir .. "\\config.json", {
        keepInventoryOnDeath = false,
        noDeathDurabilityPenalty = false,
    })
    stepTick(1.0)
    assertEq(gms2.DeathBehavior, 0, "新档关闭死亡保留精准还原")
    assertNear(gms2.ItemDurabilityPenaltyOnDeathPercentage, 0.25, 0.0001, "新档关闭耐久保护应精准还原为新档基准 0.25")
end)

runCase("L9: 原有核心功能无回归（堆叠保护装备 + 伤害倍率 + 采集倍率排除背包/乳牙且草板封顶 12）", function()
    local gms3 = buildWorld({ worldTag = "C", basePlayerDmg = 1.0, baseEnemyDmg = 1.0 })
    local grassEntry = { Type = 0, Count = 5, ItemData = { RowName = makeFName("GrassPlank") } }
    local oreEntry = { Type = 0, Count = 2, ItemData = { RowName = makeFName("Quartzite") } }
    local bagLootEntry = { Type = 0, Count = 2, ItemData = { RowName = makeFName("Quartzite") } }

    local lcNormal = makeUObject("LootComponent", "LC_Rock", {
        GetOuter = function() return makeUObject("HarvestNode", "BP_Rock_WeaponStone1_C") end,
        Items = { grassEntry, oreEntry },
    })
    local lcBackpack = makeUObject("LootComponent", "LC_Backpack", {
        GetOuter = function() return makeUObject("LootBag", "BP_Backpack_C_1") end,
        Items = { bagLootEntry },
    })
    world.lootComponents = { lcNormal, lcBackpack }

    writeJsonFile(modDataDir .. "\\config.json", {
        stackEnabled = true, stackMultiplier = 10,
        damageEnabled = true, playerDamageMultiplier = 2.5, enemyDamageMultiplier = 0.5,
        harvestEnabled = true, harvestMultiplier = 5,
        harvestAffectHauling = true, harvestAffectPickup = true,
        keepInventoryOnDeath = false, noDeathDurabilityPenalty = false,
    })
    stepTick(1.0)
    stepTick(3.0)

    assertEq(world.globalItemData._entries[1].val, 100, "普通资源基础堆叠 10 x10 应变为 100")
    assertEq(world.globalItemData._entries[2].val, 1, "单件装备基础堆叠 1 必须受保护保持 1")
    assertNear(gms3.PlayerDamageMultiplier, 2.5, 0.001, "玩家伤害倍率应生效为 2.5")
    assertNear(gms3.EnemyDamageMultiplier, 0.5, 0.001, "怪物伤害倍率应生效为 0.5")
    assertEq(grassEntry.Count, 12, "草板搬运物放大后必须封顶 12 根防物理卡顿")
    assertEq(oreEntry.Count, 10, "普通矿石 2 x5 应放大为 10")
    assertEq(bagLootEntry.Count, 2, "玩家死亡背包所属 LootComponent 严禁被采集倍率放大")
end)

runCase("L10: 正常游玩期 30 秒性能不变量（0 次周期全图扫描、0 次重复 FindFirstOf、0 次无效写盘）", function()
    -- 稳态再推进 1 秒让首次 status.json 稳定落盘
    stepTick(1.0)
    local ffGsBefore = perfCounters.findFirst["SurvivalGameState"] or 0
    local ffGidBefore = perfCounters.findFirst["GlobalItemData"] or 0
    local faLootBefore = perfCounters.findAll["LootComponent"] or 0
    local statusWritesBefore = perfCounters.fileWrites["status.json.tmp"] or 0
    local catWritesBefore = perfCounters.fileWrites["catalog.json.tmp"] or 0

    -- 模拟玩家关闭菜单和 M 地图持续跑图 30 秒（含高频 0.1s 定时器步进验证自适应调度）
    local ticksBefore = perfCounters.gameThreadTicks
    for _ = 1, 300 do
        stepTick(0.1)
    end
    local ticksDelta = perfCounters.gameThreadTicks - ticksBefore

    assertEq((perfCounters.findFirst["SurvivalGameState"] or 0) - ffGsBefore, 0,
        "稳态游玩期间严禁重复 FindFirstOf(SurvivalGameState)")
    assertEq((perfCounters.findFirst["GlobalItemData"] or 0) - ffGidBefore, 0,
        "稳态游玩期间严禁重复 FindFirstOf(GlobalItemData)")
    assertEq((perfCounters.findAll["LootComponent"] or 0) - faLootBefore, 0,
        "稳态游玩期间严禁周期性 FindAllOf(LootComponent) 扫表")
    assertEq((perfCounters.fileWrites["status.json.tmp"] or 0) - statusWritesBefore, 0,
        "状态无变化时严禁每 0.6s 无效重写 status.json")
    assertEq((perfCounters.fileWrites["catalog.json.tmp"] or 0) - catWritesBefore, 0,
        "游玩期严禁每 10s 后台全图扫描并重写 catalog.json")
    assertTrue(ticksDelta < 120,
        "30 秒内自适应调度应大幅减少 GameThread 唤醒次数（实际=" .. tostring(ticksDelta) .. "）")
end)

runCase("L11: SpawnLoot 实时 Hook 接管新流式掉落组件，且关闭采集倍率时精准还原", function()
    local spawnHook = capturedHooks["/Script/Maine.LootComponent:SpawnLoot"]
    assertTrue(spawnHook ~= nil and type(spawnHook.pre) == "function", "必须注册 LootComponent:SpawnLoot 实时 Hook")

    local lateOre = { Type = 0, Count = 3, ItemData = { RowName = makeFName("Marble") } }
    local lateLc = makeUObject("LootComponent", "LC_LateStreamed", {
        GetOuter = function() return makeUObject("HarvestNode", "BP_Rock_ArmorStone1_C") end,
        Items = { lateOre },
    })

    -- 未经过全图扫表的新组件在 SpawnLoot 触发瞬间即可放大（当前倍率 5x -> 3*5=15）
    spawnHook.pre({ get = function() return lateLc end })
    assertEq(lateOre.Count, 15, "SpawnLoot 实时 Hook 应在掉落瞬间把新组件放大 5 倍")

    -- 关闭采集倍率配置，验证触发一次全扫还原且 SpawnLoot 也能还原已缓存的新组件
    writeJsonFile(modDataDir .. "\\config.json", {
        stackEnabled = true, stackMultiplier = 10,
        damageEnabled = true, playerDamageMultiplier = 2.5, enemyDamageMultiplier = 0.5,
        harvestEnabled = false, harvestMultiplier = 5,
        harvestAffectHauling = true, harvestAffectPickup = true,
        keepInventoryOnDeath = false, noDeathDurabilityPenalty = false,
    })
    stepTick(1.0)
    spawnHook.pre({ get = function() return lateLc end })
    assertEq(lateOre.Count, 3, "关闭采集倍率后 SpawnLoot 应将已放大的掉落组件还原为原版 3")
end)

runCase("L12: 打开菜单静默软刷新（5 秒冷却 + 不覆盖状态提示）与 M 地图 1.8 秒刷新节流", function()
    -- 1. 先执行一次手动刷新设定基准时间与状态提示
    sendAction("refresh_catalog")
    stepTick(1.0)
    local stManual = readJsonFile(modDataDir .. "\\status.json")
    assertContains(stManual.lastMessage, "已重新扫描世界", "手动刷新应更新顶部提示")

    -- 2. 冷却期内（仅过 2 秒）收到 refresh_catalog_soft 不应触发重复写盘
    local catWrites1 = perfCounters.fileWrites["catalog.json.tmp"] or 0
    sendAction("refresh_catalog_soft")
    stepTick(2.0)
    assertEq((perfCounters.fileWrites["catalog.json.tmp"] or 0) - catWrites1, 0,
        "5 秒冷却期内收到 refresh_catalog_soft 不应重复扫表写 catalog.json")

    -- 3. 超过 5 秒后新增一颗未采集乳牙再触发 refresh_catalog_soft -> 静默更新乳牙计数且保留原提示文字
    table.insert(world.gs.TrackedCollectibles, {
        Type = 2, State = 0, bHiddenForThisNewGameLoop = 0,
        WorldPos = { X = 1200, Y = 3400, Z = 100 },
    })
    sendAction("refresh_catalog_soft")
    stepTick(6.0)
    assertEq((perfCounters.fileWrites["catalog.json.tmp"] or 0) - catWrites1, 1,
        "超过 5 秒后 refresh_catalog_soft 应静默更新 catalog.json")
    local stSoft = readJsonFile(modDataDir .. "\\status.json")
    assertEq(stSoft.uncollectedMilkMolars, 1, "静默软刷新后应同步最新未采集普通乳牙计数")
    assertEq(stSoft.lastMessage, stManual.lastMessage, "静默软刷新不得覆盖状态栏提示文案")

    -- 4. 模拟 M 地图打开，验证 1.8 秒刷新节流（打开瞬间立刻写 map_live.json，1.0s 内不再重扫，2.0s 后刷新）
    local lodReadCount = 0
    local mapPanelMock = makeUObject("MapPanelWidget", "MapPanel", {
        MinBounds = { X = -80000, Y = -80000 },
        MaxBounds = { X = 80000, Y = 80000 },
        TextureSize = { X = 2048, Y = 2048 },
        CollectibleCanvas = makeUObject("CanvasPanel", "CollectibleCanvas"),
        MapBorder = makeUObject("Border", "MapBorder"),
        PlayerCanvas = makeUObject("CanvasPanel", "PlayerCanvas", {
            GetChildrenCount = function() return 0 end,
        }),
    })
    local rootWinMock = makeUObject("InGameMenuWidget", "UI_InGameMenu", {
        Map = makeUObject("UI_Map", "UI_Map_C", {
            Active = true,
            MapPanel = mapPanelMock,
        }),
    })
    gameInstanceMock.WidgetManager = makeUObject("WidgetManager", "WM", {
        GetTopWindow = function() return rootWinMock end,
        WindowStack = { rootWinMock },
    })
    local trackedLod = makeUObject("ScienceCollectableLODActor", "RawSci_1", {
        GetActorLocation = function()
            lodReadCount = lodReadCount + 1
            return { X = 1000, Y = 2000, Z = 100 }
        end,
    })
    world.lods = { trackedLod }
    world.gs.LODActorManagerComponent.LODActors = world.lods

    stepTick(0.5) -- M 地图刚打开：立刻扫描一次
    local readsAfterOpen = lodReadCount
    assertEq(readsAfterOpen, 1, "M 地图刚打开瞬间应立刻扫描一次 LODActors")

    stepTick(1.0) -- 仅过去 1.0 秒（< 1.8 秒）：严禁重复全图扫 LODActors
    assertEq(lodReadCount, readsAfterOpen, "M 地图打开后 1.8 秒节流期内不应重复扫描 LODActors")

    stepTick(1.0) -- 累计过去 2.0 秒（>= 1.8 秒）：触发一次节流刷新
    assertEq(lodReadCount, readsAfterOpen + 1, "M 地图打开满 1.8 秒后应触发一次生物/状态刷新")

    -- 关闭 M 地图，确认立刻写出 mapOpen=false 并停止刷新
    rootWinMock.Map.Active = false
    stepTick(0.5)
    local mapClosed = readJsonFile(modDataDir .. "\\map_live.json")
    assertEq(mapClosed.mapOpen, false, "关闭 M 地图后应立刻写出 mapOpen=false")
    gameInstanceMock.WidgetManager = nil
end)

-- 清理本次测试在 lua/GroundedQoL/data 下产生的临时 JSON 文件
os.remove(modDataDir .. "\\config.json")
os.remove(modDataDir .. "\\actions.json")
os.remove(modDataDir .. "\\status.json")
os.remove(modDataDir .. "\\catalog.json")
os.remove(modDataDir .. "\\map_live.json")
os.execute('rmdir "' .. modDataDir .. '" >nul 2>&1')

origPrint(string.format("\n=== ALL %d LUA REGRESSION CASES PASSED ===", passedCount))
