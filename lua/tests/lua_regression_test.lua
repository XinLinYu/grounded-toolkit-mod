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
      - L9: 原有核心功能无回归（物品堆叠保护单件装备、伤害倍率、严禁全图扫表或篡改 CDO/GEN_VARIABLE 掉落模板）
      - L10: 游玩期性能不变量（ADR-0004：30 秒内 0 次周期全图 LOD/LootComponent 扫表、0 次重复 FindFirstOf、0 次无效写盘）
      - L11: SpawnLoot 瞬时 Pre/Post 还原（仅肩扛搬运物封顶 12 根且执行后立刻还原，普通掉落物与 CDO/GEN_VARIABLE 始终保持原版 1 倍，连续 10 次无复利）
      - L12: 打开菜单 5 秒冷却静默软刷新（refresh_catalog_soft）与 M 地图 1.8 秒刷新节流
      - L13: 采集入包倍率精确生效（橡果爆出物、联机队友拾取、虫尸直入背包均精确 1 次倍率；自然直拾开关独立控制 ISM 植被与地图预摆物）
      - L14: 四重防刷拦截回归（玩家丢弃、快捷丢弃、投掷、拆建返还、整堆、不可堆叠装备与储物箱拿取一律严格 1 倍）
      - L15: 多人联机客机 M 地图本地多源扫描（乳牙全队共享 + 全图植被 + 客机可见采集点/生物/散落物/科学点/宝箱，主客机独立追踪互不共享）
      - L16: 原版热区防闪退与真实自然资源过滤（直传纯 Lua 表禁传 DataTableArrayToNetCrc；武器/护甲/料理不再误标 surveyable）
      - L17: 联机客机静态图鉴目录补全（BestiaryTable/HarvestNodesTable 含蜜蜂/幼虫/黑工蚁/矿点，预勾选后进入同步范围自动匹配变体亮标）
      - L18: 免费制作修复回归（freeCraftEnabled 真正令 bRecipesRequireIngredients=false 并支持无损还原且 0 成就风险）
      - L19: 全路径入包倍率扩展回归（NotifySwapped 直拾/砍伐区分、无交互直拾、自动装备、多件堆、超堆叠溢出与 OnDeath->SpawnLoot 嵌套防复利）
      - L20: 一键建成未完工蓝图真实实现（ABuilding:SetUnderConstruction 状态 4->1 + 临时自动建成还原 + 客机拦截）
      - L21: 批量 actions.json 队列消费不丢失 + ULootBagLODActor:GetOwnerPlayerGuid 兜底找回
      - L22: 全量 RegisterHook 路径对照实机 SDK（Maine.hpp）严格校核 + 控制器工作台制作与长按交互防刷验证
      - L23: 同株多条肩扛搬运物总上限封顶 12 根（3+2 @ 4x -> 总计 12 而非 20）及精准还原
      - L24: actions.json 读写交错竞态回归（Lua 读 A 期间写端并发发布 A+B，验证原子认领 0 丢单且 0 重复执行）
      - L25: 建筑/储物箱交互、烤肉架与晾干架上下文防刷回归
      - L26: TryPickupItem 全四分支（AddItem / ServerEquipItem / ClientOnItemAdded / 客机主手兜底）回归
      - L27: 首次采集 Pre-Hook 同步走倍率、满包拒绝回滚与同对象防重回归
      - L28: 击杀昆虫掉落（BlueprintDropItems 单回调、投掷精准行名、昆虫 DroppedByActor 放行与易腐昆虫生肉补发）
      - L29: ADR-0006 纯 GameThread 调度静态源码红线与运行时启动引导校验（零 LoopAsync / 零运行期 ExecuteInGameThread）
      - L30: UE4SS 4.x TSoftObjectPtrUserdata 解析修复（BestiaryTable 与未加载 ULootBagLODActor 零 Userdata 指针泄漏）
      - L31: pollConfig() 历史损坏 trackedIds 自动清洗防回归（保留正常追踪项、过滤 Userdata 指针项）
      - L32: 反作弊与植被地址缓存有界 TTL + 512 上限淘汰校验（不误拦复用地址、不破坏近距防刷）
      - L33: scaleHaulingLootPre / restoreHaulingLootPost 关闭搬运开关时的纯 Lua 零 UObject 早退校验
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

--- 构造真实 UE4SS v4.0.0 风格的 FWeakObjectPtr（不暴露 IsValid，必须通过 :Get() 解包）。
local function makeWeakPtr(obj)
    return {
        Get = function() return obj end,
    }
end

--- 构造模拟 UE4SS v4.0.0 TSoftObjectPtrUserdata（tostring 返回指针地址，直接访问 .AssetPathName 会抛错，
--- 仅提供 :GetObjectID():GetAssetPathName():ToString() 与 :GetWeakPtr()）。
local function makeSoftObjectPtrUserdata(assetPath, hexAddr)
    local fakePtrStr = "TSoftObjectPtrUserdata: " .. tostring(hexAddr or "000001D82641E4D8")
    local oid = setmetatable({
        GetAssetPathName = function()
            return makeFName(assetPath or "None")
        end,
    }, {
        __tostring = function() return "FSoftObjectPathUserdata: " .. tostring(hexAddr or "000001D82641E4D8") end,
    })
    return setmetatable({
        GetObjectID = function() return oid end,
        GetWeakPtr = function() return makeWeakPtr(nil) end,
    }, {
        __tostring = function() return fakePtrStr end,
        __index = function(_, key)
            if key == "AssetPathName" then
                error("Tried accessing non-existent property AssetPathName on TSoftObjectPtrUserdata")
            end
            return nil
        end,
    })
end

--- 构造模拟玩家角色及其 PlayerState（含 GUID、名称、位置、朝向与完整模拟背包组件）。
local function makePlayer(opts)
    local ps = makeUObject("SurvivalPlayerState", "PS_" .. opts.name, {
        PlayerGuid = opts.guid,
        GetPlayerGuid = function(self) return self.PlayerGuid end,
        GetPlayerName = function(self) return makeFName(opts.name) end,
        _surveyedHandles = {},
        _surveyVisible = false,
        ServerSetSurveyedResource = function(self, handle)
            if type(handle) == "table" and handle._isDangerousNetCrcUserdata then
                error("模拟 UE4SS 闪退：禁止将 DataTableArrayToNetCrc 返回的临时 UScriptStruct userdata 传给 ServerSetSurveyedResource！")
            end
            table.insert(self._surveyedHandles, handle)
        end,
        SetResourceSurveyVisible = function(self, vis)
            self._surveyVisible = (vis == true)
        end,
    })
    local pawn = nil
    local inv = makeUObject("InventoryComponent", "Inv_" .. opts.name, {
        Items = {},
        MaxSize = 30,
        GetOuter = function() return pawn end,
        GetOwner = function() return pawn end,
        GetEmptySlots = function(self)
            return math.max(0, (self.MaxSize or 30) - #self.Items)
        end,
    })
    local eq = makeUObject("EquipmentComponent", "Eq_" .. opts.name, {
        _weapon = nil,
        _offhand = nil,
        GetOuter = function() return pawn end,
        GetOwner = function() return pawn end,
        GetWeapon = function(self) return self._weapon end,
        GetItemInSlot = function(self, slot)
            if slot == 1 then return self._weapon end
            if slot == 2 then return self._offhand end
            return nil
        end,
    })
    pawn = makeUObject("SurvivalPlayerCharacter", "Char_" .. opts.name, {
        PlayerGuid = opts.guid,
        PlayerState = ps,
        _loc = { X = opts.x, Y = opts.y, Z = opts.z },
        _fwd = { X = opts.fx or 1, Y = opts.fy or 0, Z = 0 },
        IsA = function(_, clsOrPath)
            if clsOrPath == "/Script/Maine.SurvivalPlayerCharacter" then return true end
            if type(clsOrPath) == "table" and clsOrPath._classPath == "/Script/Maine.SurvivalPlayerCharacter" then return true end
            return false
        end,
        K2_GetActorLocation = function(self) return { X = self._loc.X, Y = self._loc.Y, Z = self._loc.Z } end,
        GetActorForwardVector = function(self) return { X = self._fwd.X, Y = self._fwd.Y, Z = self._fwd.Z } end,
        InventoryComponent = inv,
        EquipmentComponent = eq,
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
    world.harvestNodes = {}
    world.creatures = {}
    world.spawnedItems = {}
    world.scienceOrbs = {}
    world.worldIsms = {}
    world.buildings = {}

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
            _activateCalls = 0,
            _surveyableHandles = {},
            ActivateAllSurveyors = function(self) self._activateCalls = self._activateCalls + 1 end,
            GetSurveyableItems = function(self) return self._surveyableHandles end,
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
local capturedLoopDelayMs = nil
local capturedHooks = {}
local inGameThreadDepth = 0
local hooksRegisteredOutsideGameThread = 0
local perfCounters = {
    findFirst = {},
    findAll = {},
    fileWrites = {},
    gameThreadBootstraps = 0,
    loopInGameThreadRegs = 0,
    configPolls = 0,
    playerControllerQueries = 0,
}

local origIoOpen = io.open
io.open = function(path, mode)
    if type(path) == "string" then
        local base = path:match("([^\\]+)$") or path
        if type(mode) == "string" and mode:find("w") then
            perfCounters.fileWrites[base] = (perfCounters.fileWrites[base] or 0) + 1
        elseif (mode == nil or (type(mode) == "string" and mode:find("r"))) and base == "config.json" then
            perfCounters.configPolls = perfCounters.configPolls + 1
        end
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
    GetPlayerController = function()
        perfCounters.playerControllerQueries = perfCounters.playerControllerQueries + 1
        return world.inWorld and world.pc or nil
    end,
}

_G.FName = makeFName
_G.RegisterHook = function(funcPath, preFn, postFn)
    if inGameThreadDepth <= 0 then
        hooksRegisteredOutsideGameThread = hooksRegisteredOutsideGameThread + 1
    end
    capturedHooks[funcPath] = { pre = preFn, post = postFn }
end
-- ADR-0006 禁令：严禁任何后台异步线程 API（避免 UE4SS 4.x 跨线程篡改 m_hook_lua 栈闪退）
_G.LoopAsync = function()
    error("ADR-0006 违例：禁止调用 LoopAsync！")
end
_G.ExecuteAsync = function()
    error("ADR-0006 违例：禁止调用 ExecuteAsync！")
end
_G.ExecuteWithDelay = function()
    error("ADR-0006 违例：禁止调用 ExecuteWithDelay！")
end
_G.LoopInGameThreadWithDelay = function(delayMs, fn)
    assertTrue(inGameThreadDepth > 0, "LoopInGameThreadWithDelay 必须在 GameThread 启动引导内注册")
    perfCounters.loopInGameThreadRegs = perfCounters.loopInGameThreadRegs + 1
    capturedLoopDelayMs = delayMs
    capturedLoopCallback = fn
    return 1001
end
_G.ExecuteInGameThread = function(fn)
    perfCounters.gameThreadBootstraps = perfCounters.gameThreadBootstraps + 1
    inGameThreadDepth = inGameThreadDepth + 1
    local ok, err = pcall(fn)
    inGameThreadDepth = inGameThreadDepth - 1
    if not ok then error(err, 0) end
end

local mockNaturalRows = {
    FoodMint = true,
    Clay = true,
    AcornShell = true,
    BeeFuzz = true,
}

local mockUClassCache = {}
local function getMockUClass(path)
    if not mockUClassCache[path] then
        mockUClassCache[path] = makeUObject("Class", path, { _classPath = path })
    end
    return mockUClassCache[path]
end

_G.StaticFindObject = function(path)
    if path == "/Script/OEIText.Default__OEITextLibrary" then
        return makeUObject("OEITextLibrary", path, {
            GetLocStringText = function(_, loc)
                if type(loc) == "table" and loc.zh then
                    return makeFName(loc.zh)
                end
                return makeFName("")
            end,
        })
    end
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
            IsNaturalResource = function(_, handle)
                local rn = handle and handle.RowName and handle.RowName:ToString() or ""
                return mockNaturalRows[rn] == true
            end,
            DataTableArrayToNetCrc = function(_, arr)
                return { { _isDangerousNetCrcUserdata = true, _src = arr } }
            end,
        })
    end
    if path == "/Script/Maine.Building"
        or path == "/Script/Maine.LootBag"
        or path == "/Script/Maine.SpawnedItem"
        or path == "/Script/Maine.SurvivalPlayerCharacter"
        or path == "/Script/Maine.SurvivalCreature"
        or path == "/Script/Maine.SurvivalCharacter" then
        return getMockUClass(path)
    end
    return nil
end

_G.FindFirstOf = function(cls)
    perfCounters.findFirst[cls] = (perfCounters.findFirst[cls] or 0) + 1
    if cls == "GlobalItemData" then return world.globalItemData end
    if cls == "GlobalTableData" then return gameInstanceMock.GlobalTableData end
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
    if cls == "HarvestNode" then return world.harvestNodes or {} end
    if cls == "SurvivalCreature" then return world.creatures or {} end
    if cls == "SpawnedItem" then return world.spawnedItems or {} end
    if cls == "ScienceCollectable" then return world.scienceOrbs or {} end
    if cls == "InstancedStaticMeshComponent" then return world.worldIsms or {} end
    if cls == "Building" then return world.buildings or {} end
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
assertEq(perfCounters.gameThreadBootstraps, 1, "ADR-0006：main.lua 启动期必须且仅调用 1 次 ExecuteInGameThread 进行主线程引导")
assertEq(perfCounters.loopInGameThreadRegs, 1, "ADR-0006：main.lua 必须注册唯一 1 个 LoopInGameThreadWithDelay 调度器")
assertEq(capturedLoopDelayMs, 100, "LoopInGameThreadWithDelay 间隔应为 100ms")
assertEq(hooksRegisteredOutsideGameThread, 0, "ADR-0006：全部 RegisterHook 必须在 GameThread 引导内安装（顶层注册必须为 0）")
assertTrue(type(capturedLoopCallback) == "function", "main.lua 必须注册唯一纯 GameThread 定时回调")

--- 推进虚拟时钟并执行一次真实 onScheduledGameThreadCheck()（在 GameThread 上运行）。
local function stepTick(dt)
    mockClock = mockClock + (dt or 1.0)
    inGameThreadDepth = inGameThreadDepth + 1
    local ok, err = pcall(capturedLoopCallback)
    inGameThreadDepth = inGameThreadDepth - 1
    if not ok then error(err, 0) end
end

local actionSeq = 0
local function sendAction(actionType, payload)
    actionSeq = actionSeq + 1
    writeJsonFile(modDataDir .. "\\actions.json", { seq = actionSeq, type = actionType, payload = payload or "" })
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

runCase("L9: 原有核心功能无回归（堆叠保护装备 + 伤害倍率 + 严禁全图扫表或污染 LootComponent 蓝图模板）", function()
    local gms3 = buildWorld({ worldTag = "C", basePlayerDmg = 1.0, baseEnemyDmg = 1.0 })
    local grassEntry = { Type = 0, Count = 5, ItemData = { RowName = makeFName("GrassPlank") } }
    local acornEntry = { Type = 0, Count = 2, ItemData = { RowName = makeFName("AcornShell") } }
    local cdoEntry = { Type = 0, Count = 2, ItemData = { RowName = makeFName("AcornBits") } }

    local lcNormal = makeUObject("LootComponent", "LC_Grass", {
        GetOuter = function() return makeUObject("HarvestNode", "BP_GrassBlade_A_C_1") end,
        Items = { grassEntry, acornEntry },
    })
    local lcTemplate = makeUObject("LootComponent", "BP_Acorn_C:Loot_GEN_VARIABLE", {
        GetOuter = function() return makeUObject("HarvestNode", "Default__BP_Acorn_C") end,
        Items = { cdoEntry },
    })
    world.lootComponents = { lcNormal, lcTemplate }

    local faLootBeforeL9 = perfCounters.findAll["LootComponent"] or 0
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
    assertEq((perfCounters.findAll["LootComponent"] or 0) - faLootBeforeL9, 0,
        "ADR-0005：进图与改配置期间严禁调用 FindAllOf(LootComponent) 扫表")
    assertEq(grassEntry.Count, 5, "未触发 SpawnLoot 时草板组件应保持原版 Count=5")
    assertEq(acornEntry.Count, 2, "普通可入包掉落物组件应始终保持原版 1 倍")
    assertEq(cdoEntry.Count, 2, "蓝图 CDO / GEN_VARIABLE 模板严禁被任何逻辑改写")
end)

runCase("L10: 正常游玩期 30 秒性能不变量（0 次周期全图扫描、0 次重复 FindFirstOf、0 次无效写盘）", function()
    -- 稳态再推进 1 秒让首次 status.json 稳定落盘
    stepTick(1.0)
    local ffGsBefore = perfCounters.findFirst["SurvivalGameState"] or 0
    local ffGidBefore = perfCounters.findFirst["GlobalItemData"] or 0
    local faLootBefore = perfCounters.findAll["LootComponent"] or 0
    local statusWritesBefore = perfCounters.fileWrites["status.json.tmp"] or 0
    local catWritesBefore = perfCounters.fileWrites["catalog.json.tmp"] or 0

    -- 模拟玩家关闭菜单和 M 地图持续跑图 30 秒（含高频 0.1s 定时器步进验证纯 GameThread 轻量节流与零跨线程调用）
    local bootstrapsBefore = perfCounters.gameThreadBootstraps
    local configPollsBefore = perfCounters.configPolls
    local pcQueriesBefore = perfCounters.playerControllerQueries
    for _ = 1, 300 do
        stepTick(0.1)
    end
    local bootstrapsDelta = perfCounters.gameThreadBootstraps - bootstrapsBefore
    local configPollsDelta = perfCounters.configPolls - configPollsBefore
    local pcQueriesDelta = perfCounters.playerControllerQueries - pcQueriesBefore

    assertEq(bootstrapsDelta, 0,
        "ADR-0006：稳态游玩 30 秒内严禁再调用任何跨线程 ExecuteInGameThread")
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
    assertTrue(configPollsDelta <= 55 and pcQueriesDelta <= 140,
        string.format("30 秒内 100ms 轻量检查应严格节流实际工作频率（configPolls=%d, pcQueries=%d）",
            configPollsDelta, pcQueriesDelta))
end)

runCase("L11: SpawnLoot 瞬时 Pre/Post 还原（仅肩扛搬运物缩放封顶 12 并立即还原，橡果/模板始终 1 倍零复利）", function()
    local spawnHook = capturedHooks["/Script/Maine.LootComponent:SpawnLoot"]
    assertTrue(spawnHook ~= nil and type(spawnHook.pre) == "function" and type(spawnHook.post) == "function",
        "必须注册 LootComponent:SpawnLoot Pre/Post 瞬时还原 Hook")

    local plankEntry = { Type = 0, Count = 4, ItemData = { RowName = makeFName("GrassPlank") } }
    local fiberEntry = { Type = 0, Count = 2, ItemData = { RowName = makeFName("PlantFiber") } }
    local lcGrass = makeUObject("LootComponent", "LC_GrassBlade_Live", {
        GetOuter = function() return makeUObject("HarvestNode", "BP_GrassBlade_A_C_2147400001") end,
        Items = { plankEntry, fiberEntry },
    })

    local acornShell = { Type = 0, Count = 2, ItemData = { RowName = makeFName("AcornShell") } }
    local acornBits = { Type = 0, Count = 2, ItemData = { RowName = makeFName("AcornBits") } }
    local acornTop = { Type = 0, Count = 1, ItemData = { RowName = makeFName("AcornTop") } }
    local lcAcorn = makeUObject("LootComponent", "LC_Acorn_Live", {
        GetOuter = function() return makeUObject("HarvestNode", "BP_Acorn_C_2147400002") end,
        Items = { acornShell, acornBits, acornTop },
    })

    local cdoPlank = { Type = 0, Count = 4, ItemData = { RowName = makeFName("GrassPlank") } }
    local lcCdo = makeUObject("LootComponent", "BP_GrassBlade_A_C:Loot_GEN_VARIABLE", {
        GetOuter = function() return makeUObject("HarvestNode", "Default__BP_GrassBlade_A_C") end,
        Items = { cdoPlank },
    })

    -- 连续触发 10 次 SpawnLoot（倍率=5x）：草板每次瞬时放大封顶 12 并在 Post-Hook 精准还原 4，绝不复利；橡果与纤维保持 1 倍
    for _ = 1, 10 do
        spawnHook.pre({ get = function() return lcGrass end })
        assertEq(plankEntry.Count, 12, "SpawnLoot 执行期间草板应瞬时放大并封顶 12 根")
        assertEq(fiberEntry.Count, 2, "普通可入包物品（植物纤维）落地期间必须保持原版 1 倍")
        spawnHook.post({ get = function() return lcGrass end })
        assertEq(plankEntry.Count, 4, "SpawnLoot Post-Hook 必须立刻将草板 Count 还原为原版 4")

        spawnHook.pre({ get = function() return lcAcorn end })
        assertEq(acornShell.Count, 2, "锤碎橡果壳地上爆出必须保持原版 1 倍")
        assertEq(acornBits.Count, 2, "锤碎橡果肉地上爆出必须保持原版 1 倍")
        assertEq(acornTop.Count, 1, "锤碎橡果盖地上爆出必须保持原版 1 倍")
        spawnHook.post({ get = function() return lcAcorn end })

        spawnHook.pre({ get = function() return lcCdo end })
        assertEq(cdoPlank.Count, 4, "蓝图 GEN_VARIABLE/CDO 模板即使触发 SpawnLoot 也绝不可修改")
        spawnHook.post({ get = function() return lcCdo end })
    end

    -- 关闭肩扛搬运物子开关，草板也保持原版 4
    writeJsonFile(modDataDir .. "\\config.json", {
        stackEnabled = true, stackMultiplier = 10,
        damageEnabled = true, playerDamageMultiplier = 2.5, enemyDamageMultiplier = 0.5,
        harvestEnabled = true, harvestMultiplier = 5,
        harvestAffectHauling = false, harvestAffectPickup = true,
        keepInventoryOnDeath = false, noDeathDurabilityPenalty = false,
    })
    stepTick(1.0)
    spawnHook.pre({ get = function() return lcGrass end })
    assertEq(plankEntry.Count, 4, "关闭搬运物子开关后草板应保持原版 4")
    spawnHook.post({ get = function() return lcGrass end })
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

-- 辅助工厂：构造模拟背包物品与地面 ASpawnedItem 用于 L13 / L14 / L19 全路径拾取倍率与四重防刷测试
local function makeInvItem(rowName, stackSize, maxStack, canStack, visualsActor)
    local item = makeUObject("Item", "InvItem_" .. rowName, {
        ItemDataRowHandle = { RowName = makeFName(rowName) },
        StackSize = stackSize or 1,
        _maxStack = maxStack or 100,
        _canStack = (canStack ~= false),
        CanStack = function(self) return self._canStack end,
        GetMaxStackSize = function(self) return self._maxStack end,
        AdjustStackSize = function(self, delta) self.StackSize = (self.StackSize or 0) + delta end,
    })
    if visualsActor then
        local lod = makeUObject("SpawnedItemLODActor", "LOD_" .. rowName, { FullActor = visualsActor })
        item.ItemVisuals = makeWeakPtr(lod)
    end
    return item
end

local function makeSpawnedItemActor(opts)
    local actor = nil
    actor = makeUObject("SpawnedItem", opts.fullName or ("BP_WorldItem_" .. opts.rowName), {
        PreplacedType = opts.preplacedType or 0,
        bWasThrown = opts.wasThrown or false,
        bIsThrown = opts.isThrown or false,
        AttackOwner = opts.attackOwner,
        _loc = { X = opts.x or 1000, Y = opts.y or 2000, Z = opts.z or 300 },
        IsA = function(_, clsOrPath)
            if clsOrPath == "/Script/Maine.SpawnedItem" then return true end
            if type(clsOrPath) == "table" and clsOrPath._classPath == "/Script/Maine.SpawnedItem" then return true end
            return false
        end,
        GetDroppedBy = function() return opts.droppedBy end,
        GetDroppedBySpawnedActor = function() return opts.droppedBySpawned end,
        GetPreplacedType = function(self) return self.PreplacedType end,
        K2_GetActorLocation = function(self) return { X = self._loc.X, Y = self._loc.Y, Z = self._loc.Z } end,
    })
    local itemObj = opts.itemObj or makeInvItem(opts.rowName, opts.stackSize or 1, opts.maxStack or 100, opts.canStack, actor)
    if not itemObj.ItemVisuals then
        local lod = makeUObject("SpawnedItemLODActor", "LOD_" .. opts.rowName, { FullActor = actor })
        itemObj.ItemVisuals = makeWeakPtr(lod)
    end
    actor.GetItem = function() return itemObj end
    return actor, itemObj
end

--- 模拟真实引擎 UInventoryComponent:AddItem(itemObj, bIsNewItem)（触发已挂载的 Pre/Post Hook，支持超堆叠时 ServerCreateAndAddItem 溢出创建新格）。
local function attachServerCreateAndAdd(inv)
    inv.ServerCreateAndAddItem = function(self, handle, count)
        local rn = handle and handle.RowName and handle.RowName:ToString() or ""
        local maxS = 100
        for _, it in ipairs(self.Items) do
            if it.ItemDataRowHandle.RowName:ToString() == rn then
                maxS = it:GetMaxStackSize() or 100
                break
            end
        end
        local newItem = makeInvItem(rn, count, maxS, true)
        local addHook = capturedHooks["/Script/Maine.InventoryComponent:AddItem"]
        if addHook and addHook.pre then
            addHook.pre({ get = function() return self end }, { get = function() return newItem end }, { get = function() return true end })
        end
        table.insert(self.Items, newItem)
        if addHook and addHook.post then
            addHook.post({ get = function() return self end }, { get = function() return newItem end }, { get = function() return true end })
        end
    end
end

local function simulateAddItem(inv, itemOrRow, deltaOrIsNew, maybeIsNew, maxStack, canStack)
    local itemObj = itemOrRow
    local isNew = true
    if type(itemOrRow) == "string" then
        itemObj = makeInvItem(itemOrRow, deltaOrIsNew or 1, maxStack or 100, canStack)
        if maybeIsNew ~= nil then isNew = maybeIsNew end
    else
        if deltaOrIsNew ~= nil then isNew = deltaOrIsNew end
    end
    attachServerCreateAndAdd(inv)

    -- 模拟真实实机调用链：TryPickupItem 调用 ServerAddItem(Item, true) -> 尾调用 AddItem(Item, true) -> 内部派发 ClientOnItemAdded
    local srvAddHook = capturedHooks["/Script/Maine.InventoryComponent:ServerAddItem"]
    if srvAddHook and srvAddHook.pre then
        srvAddHook.pre(
            { get = function() return inv end },
            { get = function() return itemObj end },
            { get = function() return isNew end }
        )
    end

    local addHook = capturedHooks["/Script/Maine.InventoryComponent:AddItem"]
    if addHook and addHook.pre then
        addHook.pre(
            { get = function() return inv end },
            { get = function() return itemObj end },
            { get = function() return isNew end }
        )
    end

    -- 模拟真实 UE4 AddItem：优先并入未满同种堆叠，装不下或不可堆叠则占新格
    local rn = itemObj.ItemDataRowHandle.RowName:ToString()
    local rem = itemObj.StackSize or 1
    local mergedIntoExisting = false
    if itemObj:CanStack() then
        for _, it in ipairs(inv.Items) do
            if it.ItemDataRowHandle.RowName:ToString() == rn and it:CanStack() then
                local mS = it:GetMaxStackSize() or 100
                local room = math.max(0, mS - (it.StackSize or 1))
                if room >= rem then
                    it.StackSize = (it.StackSize or 1) + rem
                    rem = 0
                    mergedIntoExisting = true
                    break
                end
            end
        end
    end
    if not mergedIntoExisting and #inv.Items < (inv.MaxSize or 30) then
        table.insert(inv.Items, itemObj)
    end

    -- 模拟 AddItem_Implementation 内部发出的 ClientOnItemAdded（处于 inAddItemDepth > 0 期间，严禁二次翻倍）
    local clientAddedHook = capturedHooks["/Script/Maine.InventoryComponent:ClientOnItemAdded"]
    if clientAddedHook and clientAddedHook.pre then
        clientAddedHook.pre(
            { get = function() return inv end },
            { get = function() return { RowName = makeFName(rn) } end },
            { get = function() return isNew end }
        )
    end

    if addHook and addHook.post then
        addHook.post(
            { get = function() return inv end },
            { get = function() return itemObj end },
            { get = function() return isNew end }
        )
    end
    if srvAddHook and srvAddHook.post then
        srvAddHook.post(
            { get = function() return inv end },
            { get = function() return itemObj end },
            { get = function() return isNew end }
        )
    end
    return itemObj
end

local function getInvTotal(inv, rowName)
    local sum = 0
    for _, it in ipairs(inv.Items) do
        if it.ItemDataRowHandle.RowName:ToString() == rowName then
            sum = sum + (it.StackSize or 1)
        end
    end
    return sum
end

runCase("L13: 采集入包倍率精确生效（橡果爆出物/联机队友拾取/虫尸搜刮均 1 次倍率；自然直拾开关独立控制）", function()
    local _, _, pHost, pClient = buildWorld({ worldTag = "D_Pickup" })
    pHost.HasAuthority = function() return true end
    pClient.HasAuthority = function() return true end -- 客机按 E 通过 RPC 在房主服务端执行

    writeJsonFile(modDataDir .. "\\config.json", {
        stackEnabled = true, stackMultiplier = 10,
        harvestEnabled = true, harvestMultiplier = 3,
        harvestAffectHauling = true, harvestAffectPickup = true,
    })
    stepTick(1.0)
    stepTick(3.0)

    local interactHook = capturedHooks["/Script/Maine.SurvivalPlayerCharacter:ServerHandleInteract"]
    local addHook = capturedHooks["/Script/Maine.InventoryComponent:AddItem"]
    assertTrue(interactHook ~= nil and addHook ~= nil and addHook.pre ~= nil and addHook.post ~= nil,
        "必须注册 InventoryComponent:AddItem 与 ServerHandleInteract Pre/Post Hook")

    -- 1. 房主拾取锤碎橡果爆出的地上 1 倍橡果壳 -> 进背包精确为 3（绝不二次翻倍成 9）
    local acornActor, acornItem = makeSpawnedItemActor({ rowName = "AcornShell", preplacedType = 0 })
    pHost.InteractableInRange = { ObjectPointer = acornActor }
    pHost.InteractableFoliageKeyInRange = nil
    interactHook.pre({ get = function() return pHost end })
    simulateAddItem(pHost.InventoryComponent, acornItem, true)
    interactHook.post({ get = function() return pHost end })
    assertEq(getInvTotal(pHost.InventoryComponent, "AcornShell"), 3, "锤碎橡果爆出 1 个按 E 拾取进包应精确变为 3 个")

    -- 2. 联机客机拾取橡果肉 -> 房主端执行 AddItem 同样精确进包 3 个
    local bitsActor, bitsItem = makeSpawnedItemActor({ rowName = "AcornBits", preplacedType = 0 })
    pClient.InteractableInRange = { ObjectPointer = bitsActor }
    interactHook.pre({ get = function() return pClient end })
    simulateAddItem(pClient.InventoryComponent, bitsItem, true)
    interactHook.post({ get = function() return pClient end })
    assertEq(getInvTotal(pClient.InventoryComponent, "AcornBits"), 3, "联机客机拾取爆出物进包同样应精确为 3 倍")

    -- 3. 按 E 搜刮死蜘蛛尸体（ULootComponent 直调 AddItem(item, true) 进背包 4 块 + 1 牙 -> 3 倍后精确为 12 + 3）
    local deadSpider = makeUObject("SurvivalCreature", "BP_Spider_Wolf_C_1", {
        IsA = function(_, clsOrPath)
            return clsOrPath == "/Script/Maine.SurvivalCreature"
                or (type(clsOrPath) == "table" and clsOrPath._classPath == "/Script/Maine.SurvivalCreature")
        end,
        HealthComponent = makeUObject("HealthComponent", "HC_Spider", { IsDead = function() return true end }),
    })
    pHost.InteractableInRange = { ObjectPointer = deadSpider }
    interactHook.pre({ get = function() return pHost end })
    simulateAddItem(pHost.InventoryComponent, "SpiderChunk", 4, true)
    simulateAddItem(pHost.InventoryComponent, "SpiderFang", 1, true)
    interactHook.post({ get = function() return pHost end })
    assertEq(getInvTotal(pHost.InventoryComponent, "SpiderChunk"), 12, "搜刮死虫尸体直入背包 4 块应精确放大为 12 块")
    assertEq(getInvTotal(pHost.InventoryComponent, "SpiderFang"), 3, "搜刮死虫尸体直入背包 1 牙应精确放大为 3 牙")

    -- 4. 地面天然 ISM 植被（真实 FWeakObjectPtr 需要 :Get() 解包）与地图预摆物（鹅卵石）：开启 harvestAffectPickup 时走 3 倍
    local fakeIsm = makeUObject("InstancedStaticMeshComponent", "ISM_Sprig")
    pHost.InteractableInRange = nil
    pHost.InteractableFoliageKeyInRange = { InstancedStaticMeshComponent = makeWeakPtr(fakeIsm), MeshIndex = 7 }
    interactHook.pre({ get = function() return pHost end })
    simulateAddItem(pHost.InventoryComponent, "Sprig", 1, true)
    interactHook.post({ get = function() return pHost end })
    assertEq(getInvTotal(pHost.InventoryComponent, "Sprig"), 3, "开启自然直拾开关时 ISM 树枝直拾应为 3 个")

    local preplacedPebble, pebbleItem = makeSpawnedItemActor({ rowName = "Pebblet", preplacedType = 2 })
    pHost.InteractableInRange = { ObjectPointer = preplacedPebble }
    pHost.InteractableFoliageKeyInRange = nil
    interactHook.pre({ get = function() return pHost end })
    simulateAddItem(pHost.InventoryComponent, pebbleItem, true)
    interactHook.post({ get = function() return pHost end })
    assertEq(getInvTotal(pHost.InventoryComponent, "Pebblet"), 3, "开启自然直拾开关时地图预摆鹅卵石直拾应为 3 个")

    -- 5. 关闭 harvestAffectPickup：自然直拾保持 1 倍，但橡果爆出物仍走 3 倍
    writeJsonFile(modDataDir .. "\\config.json", {
        harvestEnabled = true, harvestMultiplier = 3,
        harvestAffectHauling = true, harvestAffectPickup = false,
    })
    stepTick(1.0)
    pHost.InteractableInRange = nil
    pHost.InteractableFoliageKeyInRange = { InstancedStaticMeshComponent = makeWeakPtr(fakeIsm), MeshIndex = 8 }
    interactHook.pre({ get = function() return pHost end })
    simulateAddItem(pHost.InventoryComponent, "Sprig", 1, true)
    interactHook.post({ get = function() return pHost end })
    assertEq(getInvTotal(pHost.InventoryComponent, "Sprig"), 4, "关闭自然直拾开关后 ISM 树枝仅增加 1 个(3->4)")

    local preplacedPebble2, pebbleItem2 = makeSpawnedItemActor({ rowName = "Pebblet", preplacedType = 2 })
    pHost.InteractableInRange = { ObjectPointer = preplacedPebble2 }
    pHost.InteractableFoliageKeyInRange = nil
    interactHook.pre({ get = function() return pHost end })
    simulateAddItem(pHost.InventoryComponent, pebbleItem2, true)
    interactHook.post({ get = function() return pHost end })
    assertEq(getInvTotal(pHost.InventoryComponent, "Pebblet"), 4, "关闭自然直拾开关后地图预摆鹅卵石仅增加 1 个(3->4)")

    local acornActor2, acornItem2 = makeSpawnedItemActor({ rowName = "AcornShell", preplacedType = 0 })
    pHost.InteractableInRange = { ObjectPointer = acornActor2 }
    interactHook.pre({ get = function() return pHost end })
    simulateAddItem(pHost.InventoryComponent, acornItem2, true)
    interactHook.post({ get = function() return pHost end })
    assertEq(getInvTotal(pHost.InventoryComponent, "AcornShell"), 6, "关闭自然直拾后锤碎橡果爆出物拾取仍按 3 倍入包(3->6)")
end)

runCase("L14: 四重防刷拦截回归（玩家丢弃/投掷/射出箭矢/拆建返还/箱子转移/制作/不可堆叠装备/建筑交互一律严格 1 倍）", function()
    local _, _, pHost = buildWorld({ worldTag = "E_AntiDupe" })
    pHost.HasAuthority = function() return true end

    writeJsonFile(modDataDir .. "\\config.json", {
        harvestEnabled = true, harvestMultiplier = 5,
        harvestAffectHauling = true, harvestAffectPickup = true,
    })
    stepTick(1.0)
    stepTick(3.0)

    local interactHook = capturedHooks["/Script/Maine.SurvivalPlayerCharacter:ServerHandleInteract"]
    local dropHook = capturedHooks["/Script/Maine.InventoryComponent:ServerDropItem"]
    local bldDropHook = capturedHooks["/Script/Maine.Building:DropNewItem"]
    local notifySpawnHook = capturedHooks["/Script/Maine.SpawnedItem:NotifySpawned"]
    local transferFromHook = capturedHooks["/Script/Maine.InventoryComponent:ServerTransferItemFrom"]
    local craftHook = capturedHooks["/Script/Maine.InventoryComponent:ServerCraftRecipe"]
    assertTrue(dropHook ~= nil and bldDropHook ~= nil and notifySpawnHook ~= nil and transferFromHook ~= nil and craftHook ~= nil,
        "必须注册丢弃、拆建返还、容器转移与合成防刷钩子")

    -- 1. 玩家从背包丢弃物品（即使 GetDroppedBy 为空，也由 ServerDropItem + NotifySpawned 黑名单拦截为 1 倍）
    local droppedItemObj = makeInvItem("Clay", 1, 100, true)
    local droppedActor = makeSpawnedItemActor({ rowName = "Clay", itemObj = droppedItemObj, x = 1010, y = 2010, z = 300 })
    dropHook.pre({ get = function() return pHost.InventoryComponent end }, { get = function() return droppedItemObj end }, { get = function() return 1 end })
    notifySpawnHook.pre({ get = function() return droppedActor end })
    dropHook.post()
    simulateAddItem(pHost.InventoryComponent, droppedItemObj, true)
    assertEq(getInvTotal(pHost.InventoryComponent, "Clay"), 1, "玩家自丢物品再捡回必须严格保持 1 倍")

    -- 2. 原生 GetDroppedBy() 非空物品 -> 严格 1 倍
    local _, nativeDroppedItem = makeSpawnedItemActor({ rowName = "Quartzite", droppedBy = pHost })
    simulateAddItem(pHost.InventoryComponent, nativeDroppedItem, true)
    assertEq(getInvTotal(pHost.InventoryComponent, "Quartzite"), 1, "GetDroppedBy 非空物品必须严格保持 1 倍")

    -- 3. 玩家投掷出的物品（bWasThrown=true）与玩家射出的箭矢（AttackOwner 非空）-> 严格 1 倍
    local _, thrownPebbleItem = makeSpawnedItemActor({ rowName = "Pebblet", wasThrown = true })
    simulateAddItem(pHost.InventoryComponent, thrownPebbleItem, true)
    assertEq(getInvTotal(pHost.InventoryComponent, "Pebblet"), 1, "玩家投掷出的物品捡回必须严格保持 1 倍")

    local _, shotArrowItem = makeSpawnedItemActor({ rowName = "ArrowThistle", attackOwner = pHost })
    simulateAddItem(pHost.InventoryComponent, shotArrowItem, true)
    assertEq(getInvTotal(pHost.InventoryComponent, "ArrowThistle"), 1, "玩家射出后回收的箭矢必须严格保持 1 倍")

    -- 4. 拆毁建筑返还掉出的材料（即使 NotifySpawned 未走 ProcessEvent，也靠空间+RowName 事件精准拦截）
    local mockBld = makeUObject("Building", "BP_ClayFoundation_C_1", {
        K2_GetActorLocation = function() return { X = 1100, Y = 2100, Z = 300 } end,
    })
    bldDropHook.pre({ get = function() return mockBld end }, { get = function() return { RowName = makeFName("Marble") } end })
    bldDropHook.post()
    local _, refundItem = makeSpawnedItemActor({ rowName = "Marble", x = 1120, y = 2110, z = 300 })
    simulateAddItem(pHost.InventoryComponent, refundItem, true)
    assertEq(getInvTotal(pHost.InventoryComponent, "Marble"), 1, "拆建返还掉在地上的材料捡回必须严格保持 1 倍")

    -- 5. 玩家放置物（PreplacedType=1）、不可堆叠武器（CanStack=false）、bIsNewItem=false -> 严格 1 倍
    local _, userPlacedItem = makeSpawnedItemActor({ rowName = "FoodMint", preplacedType = 1 })
    simulateAddItem(pHost.InventoryComponent, userPlacedItem, true)
    assertEq(getInvTotal(pHost.InventoryComponent, "FoodMint"), 1, "玩家放置物(PreplacedUser=1)必须保持 1 倍")

    local _, spearItem = makeSpawnedItemActor({ rowName = "SpearPebblet", stackSize = 1, maxStack = 1, canStack = false })
    simulateAddItem(pHost.InventoryComponent, spearItem, true)
    assertEq(getInvTotal(pHost.InventoryComponent, "SpearPebblet"), 1, "不可堆叠武器装备严禁翻倍")

    simulateAddItem(pHost.InventoryComponent, "BerryChunk", 2, false)
    assertEq(getInvTotal(pHost.InventoryComponent, "BerryChunk"), 2, "bIsNewItem=false 内部入包必须严格 1 倍")

    -- 6. 箱子转移（ServerTransferItemFrom）、合成产出（ServerCraftRecipe）与建筑/烤肉架/储物箱直接交互 -> 严格 1 倍
    transferFromHook.pre()
    simulateAddItem(pHost.InventoryComponent, "AcornTop", 3, true)
    transferFromHook.post()
    assertEq(getInvTotal(pHost.InventoryComponent, "AcornTop"), 3, "从储物箱/背包转移物品严禁翻倍")

    craftHook.pre()
    simulateAddItem(pHost.InventoryComponent, "Rope", 2, true)
    craftHook.post()
    assertEq(getInvTotal(pHost.InventoryComponent, "Rope"), 2, "工作台/背包合成产出物品严禁翻倍")

    local chestObj = makeUObject("StorageBuilding", "BP_Storage_Big_C_1", {
        IsA = function(_, clsOrPath)
            return clsOrPath == "/Script/Maine.Building"
                or (type(clsOrPath) == "table" and clsOrPath._classPath == "/Script/Maine.Building")
        end,
    })
    pHost.InteractableInRange = { ObjectPointer = chestObj }
    interactHook.pre({ get = function() return pHost end })
    simulateAddItem(pHost.InventoryComponent, "AcornShell", 1, true)
    interactHook.post({ get = function() return pHost end })
    assertEq(getInvTotal(pHost.InventoryComponent, "AcornShell"), 1, "从储物箱/烤肉架/晾干架交互直接拿取物品严禁翻倍")
end)

runCase("L15: 多人联机客机 M 地图本地多源扫描（乳牙全队共享 + 全图植被 + 客机可见实体 + 独立追踪）", function()
    buildWorld({ worldTag = "F_ClientMap", isHost = false })
    -- 模拟客机端 LODActors 为空（Grounded 原生服务端独占行为）
    world.lods = {}
    world.gs.LODActorManagerComponent.LODActors = world.lods
    -- 模拟游戏原生全队同步的乳牙（普通 + 高级）
    world.gs.TrackedCollectibles = {
        { Type = 2, State = 0, bHiddenForThisNewGameLoop = 0, WorldPos = { X = 1100, Y = 2200, Z = 100 } },
        { Type = 3, State = 0, bHiddenForThisNewGameLoop = 0, WorldPos = { X = -3300, Y = 4400, Z = -200 } },
    }
    -- 模拟客机网络相关性范围内已加载的采集点、活体生物、已死尸体(应排除)、CDO(应排除)、散落物、科学点与宝箱
    local clientAcorn = makeUObject("BP_Acorn_C", "AR_00:PersistentLevel.BP_Acorn_C_1", {
        K2_GetActorLocation = function() return { X = 2000, Y = 3000, Z = 50 } end,
        LootComponent = makeUObject("LootComponent", "LC_ClientAcorn", {
            Items = { { Type = 0, Count = 2, ItemData = { RowName = makeFName("AcornShell") } } },
        }),
    })
    local clientAcornCdo = makeUObject("BP_Acorn_C", "Default__BP_Acorn_C", {
        K2_GetActorLocation = function() return { X = 10, Y = 10, Z = 10 } end,
    })
    local clientSpiderAlive = makeUObject("BP_Spider_Wolf_C", "AR_00:PersistentLevel.BP_Spider_Wolf_C_1", {
        K2_GetActorLocation = function() return { X = 5000, Y = 6000, Z = 80 } end,
        HealthComponent = makeUObject("HealthComponent", "HC_Alive", { IsDead = function() return false end }),
    })
    local clientSpiderDead = makeUObject("BP_Spider_Wolf_C", "AR_00:PersistentLevel.BP_Spider_Wolf_C_Dead", {
        K2_GetActorLocation = function() return { X = 5100, Y = 6100, Z = 80 } end,
        HealthComponent = makeUObject("HealthComponent", "HC_Dead", { IsDead = function() return true end }),
    })
    local clientMintItem = makeSpawnedItemActor({ rowName = "FoodMint", x = 7000, y = 8000, z = 40 })
    local clientSciOrb = makeUObject("ScienceCollectable", "AR_00:PersistentLevel.BP_RawScience_1", {
        K2_GetActorLocation = function() return { X = 9000, Y = 1000, Z = 200 } end,
    })
    local clientChest = makeLootBag({
        id = "OminentChestClient", bagType = 0, itemCount = 3,
        fullName = "BP_Ominent_Chest_C_1", x = -4000, y = -5000, z = -100,
    })
    clientChest._className = "BP_Ominent_Chest_C"

    world.harvestNodes = { clientAcorn, clientAcornCdo }
    world.creatures = { clientSpiderAlive, clientSpiderDead }
    world.spawnedItems = { clientMintItem }
    world.scienceOrbs = { clientSciOrb }
    world.loadedBags = { clientChest }

    -- 模拟客机本机独立勾选追踪列表并打开 M 地图
    local mapPanelMock = makeUObject("MapPanelWidget", "MapPanelClient", {
        MinBounds = { X = -80000, Y = -80000 },
        MaxBounds = { X = 80000, Y = 80000 },
        TextureSize = { X = 2048, Y = 2048 },
        CollectibleCanvas = makeUObject("CanvasPanel", "CollectibleCanvasClient"),
        MapBorder = makeUObject("Border", "MapBorderClient"),
        PlayerCanvas = makeUObject("CanvasPanel", "PlayerCanvasClient", {
            GetChildrenCount = function() return 0 end,
        }),
    })
    local rootWinMock = makeUObject("InGameMenuWidget", "UI_InGameMenuClient", {
        Map = makeUObject("UI_Map", "UI_Map_Client", { Active = true, MapPanel = mapPanelMock }),
    })
    gameInstanceMock.WidgetManager = makeUObject("WidgetManager", "WM_Client", {
        GetTopWindow = function() return rootWinMock end,
        WindowStack = { rootWinMock },
    })

    writeJsonFile(modDataDir .. "\\config.json", {
        showMilkMolars = true, showMegaMilkMolars = true,
        trackedIds = { "node:Acorn", "creature:Spider_Wolf", "item:FoodMint", "special:RawScience", "special:OminentChest" },
    })
    stepTick(1.0)
    stepTick(3.0)
    stepTick(0.5)

    local cat = readJsonFile(modDataDir .. "\\catalog.json")
    assertTrue(cat ~= nil and #cat >= 5, "客机本地多源扫描应产出采集点/生物/散落物/科学点/宝箱目录")
    local catById = {}
    for _, e in ipairs(cat) do catById[e.id] = e end
    assertEq(catById["node:Acorn"] and catById["node:Acorn"].count, 1, "客机目录应包含 1 处橡果采集点并排除 CDO")
    assertEq(catById["creature:Spider_Wolf"] and catById["creature:Spider_Wolf"].count, 1, "客机目录应仅包含存活狼蛛并过滤死尸")
    assertEq(catById["item:FoodMint"] and catById["item:FoodMint"].count, 1, "客机目录应包含薄荷散落物")
    assertEq(catById["special:RawScience"] and catById["special:RawScience"].count, 1, "客机目录应包含原始科学点")
    assertEq(catById["special:OminentChest"] and catById["special:OminentChest"].count, 1, "客机目录应包含非空 Ominent 宝箱")

    local mapLive = readJsonFile(modDataDir .. "\\map_live.json")
    assertTrue(mapLive ~= nil and mapLive.mapOpen == true and mapLive.pins ~= nil, "客机打开 M 地图应输出实时标点")
    local pinIds = {}
    for _, p in ipairs(mapLive.pins) do pinIds[p.id] = (pinIds[p.id] or 0) + 1 end
    assertEq(pinIds["__molar"], 1, "客机应显示全队共享普通乳牙")
    assertEq(pinIds["__megamolar"], 1, "客机应显示全队共享高级乳牙")
    assertEq(pinIds["node:Acorn"], 1, "客机勾选橡果后 M 地图必须显示标点")
    assertEq(pinIds["creature:Spider_Wolf"], 1, "客机勾选狼蛛后 M 地图必须显示标点")
    assertEq(pinIds["item:FoodMint"], 1, "客机勾选薄荷后 M 地图必须显示标点")
    assertEq(pinIds["special:RawScience"], 1, "客机勾选科学点后 M 地图必须显示标点")
    assertEq(pinIds["special:OminentChest"], 1, "客机勾选宝箱后 M 地图必须显示标点")

    -- 清空客机本机 trackedIds：独立追踪标点立刻消失，但全队共享乳牙保留
    writeJsonFile(modDataDir .. "\\config.json", {
        showMilkMolars = true, showMegaMilkMolars = true,
        trackedIds = {},
    })
    stepTick(1.0)
    stepTick(0.6)
    local mapLiveCleared = readJsonFile(modDataDir .. "\\map_live.json")
    local clearedIds = {}
    for _, p in ipairs(mapLiveCleared.pins) do clearedIds[p.id] = (clearedIds[p.id] or 0) + 1 end
    assertEq(clearedIds["__molar"], 1, "清空自由追踪后共享普通乳牙仍应显示")
    assertEq(clearedIds["node:Acorn"], nil, "清空本机 trackedIds 后橡果标点应消失")
    assertEq(clearedIds["creature:Spider_Wolf"], nil, "清空本机 trackedIds 后狼蛛标点应消失")

    rootWinMock.Map.Active = false
    stepTick(0.5)
    gameInstanceMock.WidgetManager = nil
end)

--- 辅助：构造模拟 DataTable（支持 ForEachRow）
local function makeMockDataTable(name, rows)
    return makeUObject("DataTable", name, {
        ForEachRow = function(_, cb)
            for _, pair in ipairs(rows) do
                cb(pair[1], pair[2])
            end
        end,
    })
end

runCase("L16: 原版热区防闪退与真实自然资源过滤（直传纯 Lua 表，武器/护甲/食谱严禁误标 surveyable）", function()
    local allItemsTbl = makeMockDataTable("DT_AllItems", {
        { "FoodMint", { bWasCut = 0, ItemType = 0, LocalizedDisplayName = { zh = "薄荷糖碎片" } } },
        { "Clay", { bWasCut = 0, ItemType = 0, LocalizedDisplayName = { zh = "黏土" } } },
        { "BeeFuzz", { bWasCut = 0, ItemType = 0, LocalizedDisplayName = { zh = "蜜蜂绒毛" } } },
        { "SwordLarva", { bWasCut = 0, ItemType = 0, LocalizedDisplayName = { zh = "幼虫匕首" } } },
        { "ChestBee", { bWasCut = 0, ItemType = 0, LocalizedDisplayName = { zh = "蜜蜂护肩" } } },
        { "MealTier1Larvagna", { bWasCut = 0, ItemType = 0, LocalizedDisplayName = { zh = "千虫面" } } },
    })
    local harvestNodesTbl = makeMockDataTable("DT_HarvestNodes", {
        { "Rock_Clay", { DisplayName = { zh = "黏土块" } } },
        { "Food_Mint", { DisplayName = { zh = "薄荷糖" } } },
    })
    local charsTbl = makeMockDataTable("DT_Characters", {
        { "Bee", { CharacterName = { zh = "蜜蜂" } } },
        { "Larva", { CharacterName = { zh = "幼虫" } } },
        { "Ant_Black", { CharacterName = { zh = "黑工蚁" } } },
        { "Ant_Soldier_Black", { CharacterName = { zh = "黑兵蚁" } } },
        { "Ant", { CharacterName = { zh = "红工蚁" } } },
    })
    local bestiaryTbl = makeMockDataTable("DT_Bestiary", {
        { "Bee", { Creature = makeSoftObjectPtrUserdata("/Game/Blueprints/Creatures/Bee/BP_Bee.BP_Bee_C", "000001D82641E4D8") } },
        { "Larva", { Creature = makeSoftObjectPtrUserdata("None", "000001D82641FFFF") } },
        { "Ant_Black", { Creature = makeSoftObjectPtrUserdata("/Game/Blueprints/Creatures/Ant/BP_Ant_Black.BP_Ant_Black_C", "000001D82641A001") } },
    })
    gameInstanceMock.GlobalTableData = makeUObject("GlobalTableData", "GTD", {
        AllItemsTable = allItemsTbl,
        HarvestNodesTable = harvestNodesTbl,
        CharactersTable = charsTbl,
        BestiaryTable = bestiaryTbl,
    })

    buildWorld({ worldTag = "G_SurveyFix", isHost = true })
    stepTick(1.0)
    stepTick(3.0)

    local cat = readJsonFile(modDataDir .. "\\catalog.json")
    local catById = {}
    for _, e in ipairs(cat) do catById[e.id] = e end
    assertEq(catById["item:FoodMint"] and catById["item:FoodMint"].surveyable, true, "天然资源薄荷糖必须标记 surveyable=true")
    assertEq(catById["item:Clay"] and catById["item:Clay"].surveyable, true, "天然资源黏土必须标记 surveyable=true")
    assertEq(catById["item:SwordLarva"], nil, "非自然资源武器幼虫匕首(ItemType=0)严禁再误标 surveyable 进入扫描目录")
    assertEq(catById["item:ChestBee"], nil, "非自然资源护甲蜜蜂护肩(ItemType=0)严禁再误标 surveyable 进入扫描目录")
    assertEq(catById["item:MealTier1Larvagna"], nil, "非自然资源料理千虫面(ItemType=0)严禁再误标 surveyable 进入扫描目录")

    -- 点击「原版热区(全队)」：若误走 DataTableArrayToNetCrc mock 将直接抛错失败
    sendAction("survey_item", "FoodMint")
    stepTick(1.0)
    local ps = world.pc.PlayerState
    assertEq(#ps._surveyedHandles, 1, "应成功调用一次 ServerSetSurveyedResource 且不闪退")
    assertEq(ps._surveyedHandles[1].DataTable, allItemsTbl, "传入 ServerSetSurveyedResource 的纯 Lua 表 DataTable 必须匹配")
    assertEq(ps._surveyedHandles[1].RowName:ToString(), "FoodMint", "传入 ServerSetSurveyedResource 的 RowName 必须为 FoodMint")
    assertEq(ps._surveyVisible, true, "开启原版热区后必须自动设 SetResourceSurveyVisible(true)")
    local st = readJsonFile(modDataDir .. "\\status.json")
    assertEq(st.surveyedItemName, "薄荷糖碎片", "status.json 应回显当前扫描中的官方中文资源名")
end)

runCase("L17: 联机客机静态图鉴补全（蜜蜂/幼虫/黑工蚁/矿点全可见，预勾选后进入同步范围自动匹配变体亮标）", function()
    buildWorld({ worldTag = "H_ClientCatalog", isHost = false })
    world.lods = {}
    world.gs.LODActorManagerComponent.LODActors = world.lods
    -- 初始远离所有生物与采集点（客机同步范围内 0 个生物和 0 个矿点）
    world.creatures = {}
    world.harvestNodes = {}

    local mapPanelMock = makeUObject("MapPanelWidget", "MapPanelC17", {
        MinBounds = { X = -80000, Y = -80000 },
        MaxBounds = { X = 80000, Y = 80000 },
        TextureSize = { X = 2048, Y = 2048 },
        CollectibleCanvas = makeUObject("CanvasPanel", "CC17"),
        MapBorder = makeUObject("Border", "MB17"),
        PlayerCanvas = makeUObject("CanvasPanel", "PC17", { GetChildrenCount = function() return 0 end }),
    })
    local rootWinMock = makeUObject("InGameMenuWidget", "UI_InGameMenuC17", {
        Map = makeUObject("UI_Map", "UI_Map_C17", { Active = true, MapPanel = mapPanelMock }),
    })
    gameInstanceMock.WidgetManager = makeUObject("WidgetManager", "WM_C17", {
        GetTopWindow = function() return rootWinMock end,
        WindowStack = { rootWinMock },
    })

    writeJsonFile(modDataDir .. "\\config.json", {
        trackedIds = { "creature:Bee", "creature:Larva", "creature:Ant_Black", "node:Rock_Clay" },
    })
    stepTick(1.0)
    stepTick(3.0)
    stepTick(0.5)

    local cat = readJsonFile(modDataDir .. "\\catalog.json")
    local catById = {}
    for _, e in ipairs(cat) do catById[e.id] = e end
    assertTrue(catById["creature:Bee"] ~= nil and catById["creature:Bee"].name == "蜜蜂", "客机目录必须包含静态图鉴生物：蜜蜂")
    assertTrue(catById["creature:Larva"] ~= nil and catById["creature:Larva"].name == "幼虫", "客机目录必须包含静态图鉴生物：幼虫")
    assertTrue(catById["creature:Ant_Black"] ~= nil and catById["creature:Ant_Black"].name == "黑工蚁", "客机目录必须包含静态图鉴生物：黑工蚁（绝不能误译成红工蚁）")
    assertTrue(catById["node:Rock_Clay"] ~= nil and catById["node:Rock_Clay"].name == "黏土块", "客机目录必须包含静态采集点：黏土块")
    assertEq(catById["creature:Bee"].surveyable, false, "生物词条不得错误标记原版热区按钮")

    -- 玩家走向野餐桌/黑蚁巢/黏土区：
    --   - 黑工蚁同时出现 Ant_Black_UpperDeck + Ant_HillWorker_Black（非前缀命名变体），且混入黑兵蚁 Ant_Soldier_Black（不得误命中）
    --   - 黏土块同时出现基础 Rock_Clay + 变体 Rock_Clay_A（两者都必须显示，不可因基础桶非空而跳过变体）
    --   - 蜜蜂出现 Bee_HiveWorker（刷新后目录中 creature:Bee 计数必须同步更新为 1 而非继续显示 0）
    world.creatures = {
        makeUObject("BP_Bee_HiveWorker_C", "AR:Bee_1", { K2_GetActorLocation = function() return { X = 3100, Y = 4100, Z = 200 } end }),
        makeUObject("BP_Larva_Burrow_C", "AR:Larva_1", { K2_GetActorLocation = function() return { X = 3200, Y = 4200, Z = 50 } end }),
        makeUObject("BP_Ant_Black_UpperDeck_C", "AR:BlackAnt_1", { K2_GetActorLocation = function() return { X = 3300, Y = 4300, Z = 80 } end }),
        makeUObject("BP_Ant_HillWorker_Black_C", "AR:BlackAnt_2", { K2_GetActorLocation = function() return { X = 3350, Y = 4350, Z = 80 } end }),
        makeUObject("BP_Ant_Soldier_Black_C", "AR:BlackSoldier_1", { K2_GetActorLocation = function() return { X = 3390, Y = 4390, Z = 80 } end }),
    }
    world.harvestNodes = {
        makeUObject("BP_Rock_Clay_C", "AR:Clay_Base", { K2_GetActorLocation = function() return { X = 3400, Y = 4400, Z = 10 } end }),
        makeUObject("BP_Rock_Clay_A_C", "AR:Clay_VarA", { K2_GetActorLocation = function() return { X = 3450, Y = 4450, Z = 10 } end }),
    }
    stepTick(2.0) -- 超过 1.8 秒节流期触发 M 地图自动刷新（保持 M 地图持续开启，不手动点刷新）

    local mapLive = readJsonFile(modDataDir .. "\\map_live.json")
    local pinIds = {}
    for _, p in ipairs(mapLive.pins) do pinIds[p.id] = (pinIds[p.id] or 0) + 1 end
    assertEq(pinIds["creature:Bee"], 1, "客机预勾选蜜蜂后，进入同步范围的 Bee_HiveWorker 应自动亮标")
    assertEq(pinIds["creature:Larva"], 1, "客机预勾选幼虫后，进入同步范围的 Larva_Burrow 应自动亮标")
    assertEq(pinIds["creature:Ant_Black"], 2, "客机预勾选黑工蚁后，Ant_Black_UpperDeck 与 Ant_HillWorker_Black 必须 2/2 全部亮标且不误含黑兵蚁")
    assertEq(pinIds["node:Rock_Clay"], 2, "客机预勾选黏土块后，基础 Rock_Clay 与变体 Rock_Clay_A 同时出现必须 2/2 全部亮标")

    -- 地图自动刷新同步验收：无需手动点击 refresh_catalog，catalog.json 计数必须与地图实时标点同步更新
    local catAuto = readJsonFile(modDataDir .. "\\catalog.json")
    local catAutoById = {}
    for _, e in ipairs(catAuto) do catAutoById[e.id] = e end
    assertEq(catAutoById["creature:Bee"] and catAutoById["creature:Bee"].count, 1, "保持 M 地图打开自动刷新时，蜜蜂列表计数应立即同步为 1（不可滞后停在 0）")
    assertEq(catAutoById["creature:Ant_Black"] and catAutoById["creature:Ant_Black"].count, 2, "保持 M 地图打开自动刷新时，黑工蚁基础词条计数应自动汇总为 2")
    assertEq(catAutoById["creature:Ant_Black_UpperDeck"] and catAutoById["creature:Ant_Black_UpperDeck"].count, 1, "具体变体 Ant_Black_UpperDeck 计数应为自身 1 处而非误汇总同种变体")
    assertEq(catAutoById["node:Rock_Clay"] and catAutoById["node:Rock_Clay"].count, 2, "保持 M 地图打开自动刷新时，黏土块基础词条计数应自动汇总为 2")
    assertEq(catAutoById["node:Rock_Clay_A"] and catAutoById["node:Rock_Clay_A"].count, 1, "具体变体 Rock_Clay_A 计数应为自身 1 处")

    -- 基础生物/采集点与具体变体同时勾选（正向顺序与反向顺序均严禁重复标点）：
    -- 场内仅 2 只黑工蚁 + 2 处黏土，同时勾选基础项与变体项，地图必须严格输出 2 只黑工蚁(2 处不同坐标)与 2 处黏土(2 处不同坐标)
    local function verifyNoDupBaseAndVariant(orderDesc, trackedOrder)
        writeJsonFile(modDataDir .. "\\config.json", { trackedIds = trackedOrder })
        stepTick(1.0)
        stepTick(0.6)
        local ml = readJsonFile(modDataDir .. "\\map_live.json")
        local antPins, clayPins = {}, {}
        local antPosSet, clayPosSet = {}, {}
        for _, p in ipairs(ml.pins) do
            local pk = string.format("%.0f_%.0f", p.x, p.y)
            if p.id == "creature:Ant_Black" or p.id == "creature:Ant_Black_UpperDeck" then
                table.insert(antPins, p)
                antPosSet[pk] = (antPosSet[pk] or 0) + 1
            elseif p.id == "node:Rock_Clay" or p.id == "node:Rock_Clay_A" then
                table.insert(clayPins, p)
                clayPosSet[pk] = (clayPosSet[pk] or 0) + 1
            end
        end
        assertEq(#antPins, 2, orderDesc .. ": 同时勾选黑工蚁与 Ant_Black_UpperDeck 时仅应输出 2 个标点（绝不把 Ant_HillWorker_Black 重复画成 3 个）")
        local uniqueAntPos = 0
        for _, cnt in pairs(antPosSet) do
            assertEq(cnt, 1, orderDesc .. ": 同一黑工蚁坐标严禁重复叠点")
            uniqueAntPos = uniqueAntPos + 1
        end
        assertEq(uniqueAntPos, 2, orderDesc .. ": 2 个黑工蚁标点必须对应 2 个不同位置")
        assertEq(#clayPins, 2, orderDesc .. ": 同时勾选黏土块与 Rock_Clay_A 时仅应输出 2 个标点")
        local uniqueClayPos = 0
        for _, cnt in pairs(clayPosSet) do
            assertEq(cnt, 1, orderDesc .. ": 同一黏土坐标严禁重复叠点")
            uniqueClayPos = uniqueClayPos + 1
        end
        assertEq(uniqueClayPos, 2, orderDesc .. ": 2 个黏土标点必须对应 2 个不同位置")
    end

    verifyNoDupBaseAndVariant("正向勾选(基础+变体)", {
        "creature:Ant_Black", "creature:Ant_Black_UpperDeck", "node:Rock_Clay", "node:Rock_Clay_A",
    })
    verifyNoDupBaseAndVariant("反向勾选(变体+基础)", {
        "creature:Ant_Black_UpperDeck", "creature:Ant_Black", "node:Rock_Clay_A", "node:Rock_Clay",
    })

    -- 生物离开同步范围后保持 M 地图打开，等待自动刷新 -> 列表计数自动回落为 0
    world.creatures = {}
    stepTick(2.0)
    local catAfterLeave = readJsonFile(modDataDir .. "\\catalog.json")
    local catLeaveById = {}
    for _, e in ipairs(catAfterLeave) do catLeaveById[e.id] = e end
    assertEq(catLeaveById["creature:Bee"] and catLeaveById["creature:Bee"].count, 0, "蜜蜂离开范围后自动刷新目录计数应同步回落为 0")

    rootWinMock.Map.Active = false
    stepTick(0.5)
    gameInstanceMock.WidgetManager = nil
end)

runCase("L18: 免费制作修复回归（freeCraftEnabled=true 令 bRecipesRequireIngredients 真正变为 false 并可无损还原）", function()
    local gmsFree = buildWorld({ worldTag = "I_FreeCraft", isHost = true })
    assertEq(gmsFree.bRecipesRequireIngredients, true, "原版初始 bRecipesRequireIngredients 应为 true")

    writeJsonFile(modDataDir .. "\\config.json", {
        freeCraftEnabled = true,
        instantBuildEnabled = false,
        unlockAllRecipes = false,
    })
    stepTick(1.0)
    assertEq(gmsFree.bRecipesRequireIngredients, false, "开启 freeCraftEnabled 后 bRecipesRequireIngredients 必须严格变为 false（修复 Lua and false or 缺陷）")
    assertEq(world.customModeCalls, 0, "开启免费制作严禁切换自定义模式")

    writeJsonFile(modDataDir .. "\\config.json", {
        freeCraftEnabled = false,
    })
    stepTick(1.0)
    assertEq(gmsFree.bRecipesRequireIngredients, true, "关闭 freeCraftEnabled 后 bRecipesRequireIngredients 必须精准还原为 true")
end)

runCase("L19: 全路径入包倍率扩展回归（NotifySwapped直拾/砍伐、无交互直拾、自动装备、多件堆、超堆叠溢出与 OnDeath 搬运嵌套）", function()
    local _, _, pHost = buildWorld({ worldTag = "J_FullMult", isHost = true })
    pHost.HasAuthority = function() return true end

    writeJsonFile(modDataDir .. "\\config.json", {
        harvestEnabled = true, harvestMultiplier = 4,
        harvestAffectHauling = true, harvestAffectPickup = true,
    })
    stepTick(1.0)
    stepTick(3.0)

    local swapHook = capturedHooks["/Script/Maine.SpawnedItem:NotifySwapped"]
    local onDeathHook = capturedHooks["/Script/Maine.LootComponent:OnDeath"]
    local spawnLootHook = capturedHooks["/Script/Maine.LootComponent:SpawnLoot"]
    assertTrue(swapHook ~= nil and onDeathHook ~= nil and spawnLootHook ~= nil,
        "必须注册 SpawnedItem:NotifySwapped 与 LootComponent:OnDeath/SpawnLoot Hook")

    -- 1. 无 ServerHandleInteract 的接触/延迟动画直拾 + NotifySwapped(bFromDamage=false)
    local fiberActor, fiberItem = makeSpawnedItemActor({ rowName = "PlantFiber", preplacedType = 0 })
    swapHook.pre({ get = function() return fiberActor end }, nil, { get = function() return false end })
    simulateAddItem(pHost.InventoryComponent, fiberItem, true)
    assertEq(getInvTotal(pHost.InventoryComponent, "PlantFiber"), 4, "开启自然直拾时 NotifySwapped(bFromDamage=false) 植物纤维直拾应变为 4 个")

    -- 2. 关闭 harvestAffectPickup：NotifySwapped(bFromDamage=false) 保持 1 倍，但砍伐产生 NotifySwapped(bFromDamage=true) 仍走 4 倍！
    writeJsonFile(modDataDir .. "\\config.json", {
        harvestEnabled = true, harvestMultiplier = 4,
        harvestAffectHauling = true, harvestAffectPickup = false,
    })
    stepTick(1.0)

    local fiberActor2, fiberItem2 = makeSpawnedItemActor({ rowName = "PlantFiber", preplacedType = 0 })
    swapHook.pre({ get = function() return fiberActor2 end }, nil, { get = function() return false end })
    simulateAddItem(pHost.InventoryComponent, fiberItem2, true)
    assertEq(getInvTotal(pHost.InventoryComponent, "PlantFiber"), 5, "关闭自然直拾后 NotifySwapped(bFromDamage=false) 仅 +1(4->5)")

    local cloverActor, cloverItem = makeSpawnedItemActor({ rowName = "CloverLeaf", preplacedType = 0 })
    swapHook.pre({ get = function() return cloverActor end }, nil, { get = function() return true end })
    simulateAddItem(pHost.InventoryComponent, cloverItem, true)
    assertEq(getInvTotal(pHost.InventoryComponent, "CloverLeaf"), 4, "关闭自然直拾后砍伐掉落(bFromDamage=true) 仍按 4 倍入包")

    -- 3. 自动装备鹅卵石验证：AddItem Post-Hook 必须在 TryPickupItem 调用 EquipItem 前把 itemObj.StackSize 自身拉高到 4
    local _, autoEquipPebble = makeSpawnedItemActor({ rowName = "Pebblet", preplacedType = 0, stackSize = 1, maxStack = 10 })
    simulateAddItem(pHost.InventoryComponent, autoEquipPebble, true)
    assertEq(autoEquipPebble.StackSize, 4, "自动装备类物品(鹅卵石/箭矢)在 AddItem 返回时其自身 StackSize 必须已放大为 4")

    -- 4. 多件自然掉落堆（StackSize=2，4 倍 -> 8）
    local _, multiSap = makeSpawnedItemActor({ rowName = "Sap", preplacedType = 0, stackSize = 2, maxStack = 50 })
    simulateAddItem(pHost.InventoryComponent, multiSap, true)
    assertEq(getInvTotal(pHost.InventoryComponent, "Sap"), 8, "多件自然掉落堆(2件x4倍)应精确入包 8 个")

    -- 5. 超出单组堆叠上限（maxStack=10, 倍率=15x）：原格补满 10 + 自动调用 ServerCreateAndAddItem 溢出新格 5（总计 15，零递归）
    writeJsonFile(modDataDir .. "\\config.json", {
        harvestEnabled = true, harvestMultiplier = 15,
        harvestAffectHauling = true, harvestAffectPickup = true,
    })
    stepTick(1.0)
    local _, overflowClay = makeSpawnedItemActor({ rowName = "Clay", preplacedType = 0, stackSize = 1, maxStack = 10 })
    simulateAddItem(pHost.InventoryComponent, overflowClay, true)
    assertEq(getInvTotal(pHost.InventoryComponent, "Clay"), 15, "超单组堆叠上限(1x15, maxStack=10)应自动溢出到空槽总计 15 个且零递归")

    -- 6. OnDeath 内部嵌套触发 SpawnLoot：只缩放 1 次封顶 12 并精准还原为原版 4
    local stemEntry = { Type = 0, Count = 4, ItemData = { RowName = makeFName("WeedStem") } }
    local lcWeed = makeUObject("LootComponent", "LC_Weed_Nest", {
        GetOuter = function() return makeUObject("HarvestNode", "BP_Dandelion_C_1") end,
        Items = { stemEntry },
    })
    onDeathHook.pre({ get = function() return lcWeed end })
    assertEq(stemEntry.Count, 12, "OnDeath 期间杂草茎应缩放封顶 12")
    spawnLootHook.pre({ get = function() return lcWeed end })
    assertEq(stemEntry.Count, 12, "嵌套 SpawnLoot 不得二次叠加")
    spawnLootHook.post({ get = function() return lcWeed end })
    assertEq(stemEntry.Count, 12, "内层 SpawnLoot 结束时不得提前还原外层 OnDeath 缩放")
    onDeathHook.post({ get = function() return lcWeed end })
    assertEq(stemEntry.Count, 4, "最外层 OnDeath 结束后必须精准还原为原版 4")
end)

runCase("L20: 一键建成未完工蓝图真实实现（ABuilding:SetUnderConstruction 状态 4->1 + 临时自动建成还原 + 客机拦截）", function()
    local gmsBld = buildWorld({ worldTag = "K_BuildAll", isHost = true })
    local function makeMockBuilding(name, state)
        local b = makeUObject("Building", name, {
            BuildingState = state,
            GameModeManagerComponent = nil,
            _onGameModeCalls = 0,
            _setUnderCalls = 0,
            IsUnderConstruction = function(self) return self.BuildingState == 4 end,
            IsBuilt = function(self) return self.BuildingState == 1 end,
            OnGameModeChanged = function(self)
                self._onGameModeCalls = self._onGameModeCalls + 1
                self.GameModeManagerComponent = world.gs.SurvivalModeManagerComponent
            end,
            SetUnderConstruction = function(self)
                self._setUnderCalls = self._setUnderCalls + 1
                if gmsBld.bAutoCompleteBuildings == true and self.BuildingState == 4 then
                    self.BuildingState = 1
                end
            end,
        })
        return b
    end

    local bp1 = makeMockBuilding("BP_Workbench_C_1", 4)
    local bp2 = makeMockBuilding("BP_GrassWall_C_2", 4)
    local alreadyBuilt = makeMockBuilding("BP_Storage_C_3", 1)
    local cdoBld = makeMockBuilding("Default__BP_Workbench_C", 4)
    world.buildings = { bp1, bp2, alreadyBuilt, cdoBld }

    writeJsonFile(modDataDir .. "\\config.json", { instantBuildEnabled = false })
    stepTick(1.0)
    assertEq(gmsBld.bAutoCompleteBuildings, false, "未开启秒建时 bAutoCompleteBuildings 初始为 false")

    sendAction("build_all_blueprints")
    stepTick(1.0)
    assertEq(bp1.BuildingState, 1, "未完工蓝图 1 应通过 SetUnderConstruction 建成(4->1)")
    assertEq(bp2.BuildingState, 1, "未完工蓝图 2 应通过 SetUnderConstruction 建成(4->1)")
    assertEq(alreadyBuilt._setUnderCalls, 0, "已建成的建筑不应被重复调用 SetUnderConstruction")
    assertEq(cdoBld._setUnderCalls, 0, "蓝图 CDO 严禁被触碰")
    assertEq(gmsBld.bAutoCompleteBuildings, false, "未长期开启秒建时，一键建成后必须还原 bAutoCompleteBuildings=false")
    local stHost = readJsonFile(modDataDir .. "\\status.json")
    assertContains(stHost.lastMessage, "2 个未完工建筑蓝图", "顶部状态栏应准确回报建成了 2 个蓝图")

    -- 客机端触发必须被权限拦截
    buildWorld({ worldTag = "K_BuildAll_Client", isHost = false })
    world.buildings = { makeMockBuilding("BP_Wall_Client_1", 4) }
    sendAction("build_all_blueprints")
    stepTick(1.0)
    assertEq(world.buildings[1].BuildingState, 4, "客机严禁修改未完工蓝图")
    local stCli = readJsonFile(modDataDir .. "\\status.json")
    assertContains(stCli.lastMessage, "仅房主可执行", "客机点击一键建成应返回明确权限提示")
end)

runCase("L21: 批量 actions.json 队列按序全量执行 + ULootBagLODActor:GetOwnerPlayerGuid 兜底找回", function()
    local gmsQ, _, pHostQ = buildWorld({ worldTag = "L_BatchQueue", isHost = true })
    local bpQ = makeUObject("Building", "BP_Chest_Q_1", {
        BuildingState = 4,
        SetUnderConstruction = function(self)
            if gmsQ.bAutoCompleteBuildings == true then self.BuildingState = 1 end
        end,
    })
    world.buildings = { bpQ }

    -- 单次写入含 2 条指令的批量队列（模拟 0.6s 内连续快速点击两个按钮），确认单次 tick 内两条指令全部按序执行不丢失
    actionSeq = actionSeq + 1
    local seq1 = actionSeq
    actionSeq = actionSeq + 1
    local seq2 = actionSeq
    writeJsonFile(modDataDir .. "\\actions.json", {
        actions = {
            { seq = seq1, type = "activate_surveyors", payload = "" },
            { seq = seq2, type = "build_all_blueprints", payload = "" },
        },
    })
    stepTick(1.0)
    assertEq(world.gs.ResourceSurveyComponent._activateCalls, 1, "批量队列第 1 条 activate_surveyors 必须执行")
    assertEq(bpQ.BuildingState, 1, "批量队列第 2 条 build_all_blueprints 必须同时执行且不丢失")

    -- 重放旧序列号队列 -> 严格去重不重复执行
    writeJsonFile(modDataDir .. "\\actions.json", {
        actions = { { seq = seq1, type = "activate_surveyors", payload = "" } },
    })
    stepTick(1.0)
    assertEq(world.gs.ResourceSurveyComponent._activateCalls, 1, "已消费的旧序列号不得重复执行")

    -- 验证 ULootBagLODActor 在 ProxyActor 为空时通过 GetOwnerPlayerGuid() 兜底成功找回
    local bagFallback = makeLootBag({
        id = "HostFallbackGuid", bagType = 1, itemCount = 2,
        ownerGuid = pHostQ.PlayerGuid, ownerName = "",
        x = -50000, y = -50000, z = 100,
    })
    local lodFallback = makeUnloadedLootBagLod(bagFallback, { actorClassName = "BP_Backpack_C" })
    lodFallback.ProxyActor = nil
    lodFallback.GetOwnerPlayerGuid = function() return pHostQ.PlayerGuid end
    world.lods = { lodFallback }
    world.gs.LODActorManagerComponent.LODActors = world.lods
    sendAction("recover_my_backpacks")
    stepTick(1.0)
    assertEq(bagFallback._movedCount, 1, "ProxyActor 为空但 GetOwnerPlayerGuid 匹配房主时应通过兜底成功找回背包")
end)

runCase("L22: 全量 RegisterHook 路径对照实机 SDK(Maine.hpp) 校核 + 控制器工作台制作与长按三入口防刷", function()
    -- 1. 校验关键实机 SDK 路径已准确注册，且不存在错误类名/虚构函数名
    assertTrue(capturedHooks["/Script/Maine.SurvivalPlayerController:ServerCraftRecipeAtBuilding"] ~= nil,
        "ServerCraftRecipeAtBuilding 必须注册在 SurvivalPlayerController")
    assertTrue(capturedHooks["/Script/Maine.SurvivalPlayerController:ServerCraftRecipeDataAtBuilding"] ~= nil,
        "ServerCraftRecipeDataAtBuilding 必须注册在 SurvivalPlayerController")
    assertEq(capturedHooks["/Script/Maine.SurvivalPlayerCharacter:ServerCraftRecipeAtBuilding"], nil,
        "禁止将 ServerCraftRecipeAtBuilding 误注册在 SurvivalPlayerCharacter")
    assertEq(capturedHooks["/Script/Maine.SurvivalPlayerCharacter:ServerHandleHoldInteract"], nil,
        "禁止注册 SDK 中不存在的 ServerHandleHoldInteract 总入口")
    assertTrue(capturedHooks["/Script/Maine.SurvivalPlayerCharacter:ServerHandleHoldInteractActor"] ~= nil,
        "必须注册 ServerHandleHoldInteractActor")
    assertTrue(capturedHooks["/Script/Maine.SurvivalPlayerCharacter:ServerHandleHoldInteractBuilding"] ~= nil,
        "必须注册 ServerHandleHoldInteractBuilding")
    assertTrue(capturedHooks["/Script/Maine.SurvivalPlayerCharacter:ServerHandleHoldInteractFoliage"] ~= nil,
        "必须注册 ServerHandleHoldInteractFoliage")

    -- 2. 若本机存在游戏导出的 Maine.hpp，逐条静态比对 capturedHooks 中全部 /Script/Maine.Class:Func 是否 100% 真实存在
    local sdkPath = "G:\\SteamLibrary\\steamapps\\common\\Grounded\\Maine\\Binaries\\Win64\\ue4ss\\CXXHeaderDump\\Maine.hpp"
    local fSdk = origIoOpen(sdkPath, "rb")
    if fSdk then
        local sdkMethods = {}
        local curCls = nil
        for line in fSdk:lines() do
            local cls = line:match("^class%s+[AU]([A-Za-z0-9_]+)%s*:")
            if cls then
                curCls = cls
                sdkMethods[curCls] = sdkMethods[curCls] or {}
            elseif curCls then
                local fn = line:match("^%s+void%s+([A-Za-z0-9_]+)%(")
                if fn then
                    sdkMethods[curCls][fn] = true
                end
            end
        end
        fSdk:close()

        local checkedCount = 0
        for hookPath, _ in pairs(capturedHooks) do
            local hCls, hFn = hookPath:match("^/Script/Maine%.([A-Za-z0-9_]+):([A-Za-z0-9_]+)$")
            assertTrue(hCls ~= nil and hFn ~= nil, "Hook 路径格式无效: " .. tostring(hookPath))
            assertTrue(sdkMethods[hCls] ~= nil and sdkMethods[hCls][hFn] == true,
                "Hook 在实机 SDK Maine.hpp 中不存在（路径错误或挂错类）: " .. hookPath)
            checkedCount = checkedCount + 1
        end
        assertTrue(checkedCount >= 30, "应校核全部已注册的 /Script/Maine.* Hook（实际=" .. tostring(checkedCount) .. "）")
    end

    -- 3. 功能验证：SurvivalPlayerController:ServerCraftRecipeAtBuilding 与 ServerHandleHoldInteractBuilding 均拦截 AddItem 为 1 倍；
    --    ServerHandleHoldInteractFoliage 受 harvestAffectPickup 独立控制
    local _, _, pHost22 = buildWorld({ worldTag = "M_SdkHooks", isHost = true })
    pHost22.HasAuthority = function() return true end
    writeJsonFile(modDataDir .. "\\config.json", {
        harvestEnabled = true, harvestMultiplier = 4,
        harvestAffectHauling = true, harvestAffectPickup = false,
    })
    stepTick(1.0)
    stepTick(3.0)

    local craftBldHook = capturedHooks["/Script/Maine.SurvivalPlayerController:ServerCraftRecipeAtBuilding"]
    craftBldHook.pre()
    simulateAddItem(pHost22.InventoryComponent, "SilkRope", 1, true)
    craftBldHook.post()
    assertEq(getInvTotal(pHost22.InventoryComponent, "SilkRope"), 1, "工作台/建筑加工制作(SurvivalPlayerController)产出严禁倍增")

    local holdBldHook = capturedHooks["/Script/Maine.SurvivalPlayerCharacter:ServerHandleHoldInteractBuilding"]
    holdBldHook.pre({ get = function() return pHost22 end })
    simulateAddItem(pHost22.InventoryComponent, "RoastedAphid", 1, true)
    holdBldHook.post({ get = function() return pHost22 end })
    assertEq(getInvTotal(pHost22.InventoryComponent, "RoastedAphid"), 1, "长按建筑交互(ServerHandleHoldInteractBuilding)拿取严禁倍增")

    local holdFolHook = capturedHooks["/Script/Maine.SurvivalPlayerCharacter:ServerHandleHoldInteractFoliage"]
    holdFolHook.pre({ get = function() return pHost22 end })
    simulateAddItem(pHost22.InventoryComponent, "PlantFiber", 1, true)
    holdFolHook.post({ get = function() return pHost22 end })
    assertEq(getInvTotal(pHost22.InventoryComponent, "PlantFiber"), 1, "关闭自然直拾时，长按植被直拾(ServerHandleHoldInteractFoliage)必须保持 1 倍")
end)

runCase("L23: 同株植物多条肩扛搬运物总上限封顶 12 根（原始 3+2、倍率 4x -> 总计 12 而非 20）且 Post-Hook 精准还原", function()
    buildWorld({ worldTag = "N_HaulCap", isHost = true })
    writeJsonFile(modDataDir .. "\\config.json", {
        harvestEnabled = true, harvestMultiplier = 4,
        harvestAffectHauling = true, harvestAffectPickup = true,
    })
    stepTick(1.0)
    stepTick(3.0)

    local spawnHook = capturedHooks["/Script/Maine.LootComponent:SpawnLoot"]
    local e1 = { Type = 0, Count = 3, ItemData = { RowName = makeFName("GrassPlank") } }
    local e2 = { Type = 0, Count = 2, ItemData = { RowName = makeFName("WeedStem") } }
    local eNormal = { Type = 0, Count = 2, ItemData = { RowName = makeFName("PlantFiber") } }
    local lcDual = makeUObject("LootComponent", "LC_DualHaul_Live", {
        GetOuter = function() return makeUObject("HarvestNode", "BP_TallWeed_C_99") end,
        Items = { e1, e2, eNormal },
    })

    spawnHook.pre({ get = function() return lcDual end })
    local sumDuring = e1.Count + e2.Count
    assertEq(sumDuring, 12, "同株两条搬运掉落(3+2 @ 4x)合计必须严格封顶 12 根（而非每条封顶得到 20）")
    assertTrue(e1.Count >= 3 and e2.Count >= 2, "各条搬运数量不得低于原版基准")
    assertEq(eNormal.Count, 2, "同组件内普通可入包物品仍须保持原版 1 倍")
    spawnHook.post({ get = function() return lcDual end })
    assertEq(e1.Count, 3, "Post-Hook 必须将第 1 条搬运物精准还原为 3")
    assertEq(e2.Count, 2, "Post-Hook 必须将第 2 条搬运物精准还原为 2")

    -- 口径边界断言：若原版单株搬运掉落本身已 >= 12（如 8+6=14），开启 4x 时保持原版 14 不削减也不额外放大
    local eBig1 = { Type = 0, Count = 8, ItemData = { RowName = makeFName("GrassPlank") } }
    local eBig2 = { Type = 0, Count = 6, ItemData = { RowName = makeFName("WeedStem") } }
    local lcBig = makeUObject("LootComponent", "LC_BigHaul_Live", {
        GetOuter = function() return makeUObject("HarvestNode", "BP_GiantWeed_C_1") end,
        Items = { eBig1, eBig2 },
    })
    spawnHook.pre({ get = function() return lcBig end })
    assertEq(eBig1.Count + eBig2.Count, 14, "原版单株搬运已 >= 12(8+6=14) 时开启 4x 必须保持原版 14（绝不削减原版掉落）")
    assertEq(eBig1.Count, 8, "不削减原版第 1 条数量")
    assertEq(eBig2.Count, 6, "不削减原版第 2 条数量")
    spawnHook.post({ get = function() return lcBig end })
    assertEq(eBig1.Count, 8, "Post-Hook 维持原版 8")
    assertEq(eBig2.Count, 6, "Post-Hook 维持原版 6")
end)

runCase("L24: actions.json 读写交错竞态回归（Lua 读 A 期间写端并发发布 A+B，验证原子认领 0 丢单且 0 重复执行）", function()
    local gmsRace = buildWorld({ worldTag = "O_QueueRace", isHost = true })
    local bpRace = makeUObject("Building", "BP_Wall_Race_1", {
        BuildingState = 4,
        SetUnderConstruction = function(self)
            if gmsRace.bAutoCompleteBuildings == true then self.BuildingState = 1 end
        end,
    })
    world.buildings = { bpRace }
    stepTick(1.0)
    stepTick(3.0)

    actionSeq = actionSeq + 1
    local seqA = actionSeq
    actionSeq = actionSeq + 1
    local seqB = actionSeq

    -- 先写入仅含 A 的 actions.json
    writeJsonFile(modDataDir .. "\\actions.json", {
        actions = { { seq = seqA, type = "activate_surveyors", payload = "" } },
    })

    -- 注入交错竞态探针：在 Lua 即将打开已认领文件读取 A 的瞬间，模拟 C++ 写端并发向 actions.json 发布 A+B！
    -- 旧实现(读后按原文件名删除)会在此时把刚写入的 A+B 一并删掉导致 B 永久丢失；新实现(先原子重命名为 .proc 再读删)必须完整执行 A 与 B。
    local injectedConcurrentWrite = false
    local prevWrappedOpen = io.open
    io.open = function(path, mode)
        local fh = prevWrappedOpen(path, mode)
        if (not injectedConcurrentWrite) and fh and type(mode) == "string" and mode:find("r")
            and type(path) == "string" and path:find("actions%.json") then
            injectedConcurrentWrite = true
            local fConc = origIoOpen(modDataDir .. "\\actions.json", "wb")
            if fConc then
                fConc:write(json.encode({
                    actions = {
                        { seq = seqA, type = "activate_surveyors", payload = "" },
                        { seq = seqB, type = "build_all_blueprints", payload = "" },
                    },
                }))
                fConc:close()
            end
        end
        return fh
    end

    -- 第 1 次 tick：消费 A，并触发写端并发写入 A+B 到新 actions.json
    stepTick(1.0)
    io.open = prevWrappedOpen

    assertEq(injectedConcurrentWrite, true, "测试探针应成功在读 A 期间注入并发写入 A+B")
    assertEq(world.gs.ResourceSurveyComponent._activateCalls, 1, "第 1 轮应精确执行指令 A 一次")

    -- 第 2 次 tick：消费并发写入的 actions.json，自动去重跳过 A 并执行 B
    stepTick(1.0)
    assertEq(world.gs.ResourceSurveyComponent._activateCalls, 1, "指令 A 已被 lastActionSeq 去重，绝不可重复执行")
    assertEq(bpRace.BuildingState, 1, "并发写入的指令 B 必须完整保留并执行，绝不因读后删竞争丢单")

    local stRace = readJsonFile(modDataDir .. "\\status.json")
    assertEq(stRace.lastActionSeq, seqB, "status.json 应回传最新确认的 lastActionSeq 供 C++ 端裁剪队列")
end)

runCase("L25: 跨重启会话隔离（旧会话 seq=8 后新会话 seq 从 1 起连续执行 1 与 2 不丢单，同会话重放严格去重）", function()
    local gmsSess = buildWorld({ worldTag = "P_SessionRestart", isHost = true })
    local bpSess = makeUObject("Building", "BP_Wall_Sess_1", {
        BuildingState = 4,
        SetUnderConstruction = function(self)
            if gmsSess.bAutoCompleteBuildings == true then self.BuildingState = 1 end
        end,
    })
    world.buildings = { bpSess }
    stepTick(1.0)
    stepTick(3.0)

    -- 旧会话发送 seq=8
    writeJsonFile(modDataDir .. "\\actions.json", {
        session = "s_prev_session_old",
        actions = {
            { session = "s_prev_session_old", seq = 8, type = "activate_surveyors", payload = "" },
        },
    })
    stepTick(1.0)
    assertEq(world.gs.ResourceSurveyComponent._activateCalls, 1, "旧会话 seq=8 应正常执行")
    local stOld = readJsonFile(modDataDir .. "\\status.json")
    assertEq(stOld.lastActionSession, "s_prev_session_old", "status.json 应回传旧会话 lastActionSession")
    assertEq(stOld.lastActionSeq, 8, "status.json 应回传旧会话 lastActionSeq=8")

    -- 模拟重启后的新会话：seq 重新从 1 开始连续下发 [1, 2]，两条均 < 8 但属于新会话必须全部执行
    writeJsonFile(modDataDir .. "\\actions.json", {
        session = "s_new_session_after_restart",
        actions = {
            { session = "s_new_session_after_restart", seq = 1, type = "activate_surveyors", payload = "" },
            { session = "s_new_session_after_restart", seq = 2, type = "build_all_blueprints", payload = "" },
        },
    })
    stepTick(1.0)
    assertEq(world.gs.ResourceSurveyComponent._activateCalls, 2, "新会话 seq=1 绝不可被旧会话 seq=8 拦截")
    assertEq(bpSess.BuildingState, 1, "新会话 seq=2 必须紧接着执行建成蓝图")
    local stNew = readJsonFile(modDataDir .. "\\status.json")
    assertEq(stNew.lastActionSession, "s_new_session_after_restart", "status.json 应切换回传新会话 ID")
    assertEq(stNew.lastActionSeq, 2, "status.json 应回传新会话最新确认序号 2")

    -- 同会话重放 seq=1 必须被严格去重
    writeJsonFile(modDataDir .. "\\actions.json", {
        session = "s_new_session_after_restart",
        actions = {
            { session = "s_new_session_after_restart", seq = 1, type = "activate_surveyors", payload = "" },
        },
    })
    stepTick(1.0)
    assertEq(world.gs.ResourceSurveyComponent._activateCalls, 2, "同会话重放 seq=1 必须严格去重不重复执行")
end)

runCase("L26: 实机二进制 TryPickupItem 全 4 分支回归（ServerAddItem 不拦截、空手 ServerEquipItem、手持主手叠加 ClientOnItemAdded、客机兜底与防刷）", function()
    local _, _, pHost26, pCli26 = buildWorld({ worldTag = "Q_TryPickupAll4", isHost = true })
    pHost26.HasAuthority = function() return true end
    pCli26.HasAuthority = function() return true end

    writeJsonFile(modDataDir .. "\\config.json", {
        harvestEnabled = true, harvestMultiplier = 3,
        harvestAffectHauling = true, harvestAffectPickup = true,
    })
    stepTick(1.0)
    stepTick(3.0)

    -- 0. 断言严禁再把 ServerAddItem 误加入非采集屏蔽钩子（正是导致实机全部 1 倍与 0 次生效的根因）
    assertEq(capturedHooks["/Script/Maine.InventoryComponent:ServerAddItem"], nil,
        "严禁将 InventoryComponent:ServerAddItem 注册到非采集屏蔽列表（TryPickupItem 常规拾取必经 ServerAddItem->AddItem）")

    local equipHook = capturedHooks["/Script/Maine.EquipmentComponent:ServerEquipItem"]
    local unequipHook = capturedHooks["/Script/Maine.EquipmentComponent:ServerUnequipItem"]
    local clientAddedHook = capturedHooks["/Script/Maine.InventoryComponent:ClientOnItemAdded"]
    local interactHook = capturedHooks["/Script/Maine.SurvivalPlayerCharacter:ServerHandleInteract"]
    local touchHook = capturedHooks["/Script/Maine.SpawnedItem:HandleTouch"]
    assertTrue(equipHook ~= nil and unequipHook ~= nil and clientAddedHook ~= nil and touchHook ~= nil,
        "必须注册 ServerEquipItem / ServerUnequipItem / ClientOnItemAdded / HandleTouch Hook")

    -- 1. TryPickupItem 分支 1：空手捡鹅卵石（走 ServerEquipItem(Item, false) -> 紧随 ClientOnItemAdded，完全绕过 AddItem）
    local pebActor1, pebItem1 = makeSpawnedItemActor({ rowName = "Pebblet", preplacedType = 2, stackSize = 1, maxStack = 100 })
    pHost26.InteractableInRange = { ObjectPointer = pebActor1 }
    interactHook.pre({ get = function() return pHost26 end })
    equipHook.pre({ get = function() return pHost26.EquipmentComponent end }, { get = function() return pebItem1 end }, { get = function() return false end })
    pHost26.EquipmentComponent._weapon = pebItem1
    equipHook.post({ get = function() return pHost26.EquipmentComponent end }, { get = function() return pebItem1 end }, { get = function() return false end })
    -- 模拟 5 条指令后的 ClientOnItemAdded：不得二次翻倍（应保持 3 而非 9）
    clientAddedHook.pre(
        { get = function() return pHost26.InventoryComponent end },
        { get = function() return { RowName = makeFName("Pebblet") } end },
        { get = function() return true end }
    )
    interactHook.post({ get = function() return pHost26 end })
    assertEq(pebItem1.StackSize, 3, "空手捡鹅卵石(ServerEquipItem bCheckInventory=false)必须精确倍增为 3 且不被 ClientOnItemAdded 二次叠加")

    -- 2. 从背包切换装备（ServerEquipItem bCheckInventory=true）与卸下装备（ServerUnequipItem）-> 严格 1 倍绝不翻倍
    local bagPeb = makeInvItem("Pebblet", 5, 100, true)
    equipHook.pre({ get = function() return pHost26.EquipmentComponent end }, { get = function() return bagPeb end }, { get = function() return true end })
    equipHook.post({ get = function() return pHost26.EquipmentComponent end }, { get = function() return bagPeb end }, { get = function() return true end })
    assertEq(bagPeb.StackSize, 5, "从背包装备物品(bCheckInventory=true)严禁倍增")

    unequipHook.pre()
    simulateAddItem(pHost26.InventoryComponent, makeInvItem("Pebblet", 4, 100, true), true)
    unequipHook.post()
    assertEq(getInvTotal(pHost26.InventoryComponent, "Pebblet"), 4, "卸下装备回包(ServerUnequipItem)严禁倍增")

    -- 3. TryPickupItem 分支 2（房主）：手持 3 颗鹅卵石时再捡 1 颗鹅卵石（C++ 直接 AdjustStackSize(1) + ClientOnItemAdded，绕过 AddItem 与 ServerEquipItem）
    local pebActor2, _ = makeSpawnedItemActor({ rowName = "Pebblet", preplacedType = 2, stackSize = 1, maxStack = 100 })
    pHost26.InteractableInRange = { ObjectPointer = pebActor2 }
    interactHook.pre({ get = function() return pHost26 end })
    pebItem1:AdjustStackSize(1) -- 原版先 +1（3 -> 4）
    clientAddedHook.pre(
        { get = function() return pHost26.InventoryComponent end },
        { get = function() return { RowName = makeFName("Pebblet") } end },
        { get = function() return true end }
    )
    interactHook.post({ get = function() return pHost26 end })
    assertEq(pebItem1.StackSize, 6, "手持 3 颗鹅卵石再捡 1 颗(3x)必须变为 6 颗（3 + 1*3）且不被 interactHook 二次叠加")

    -- 4. 分支 2 防刷：手持鹅卵石时捡回自己投掷出的鹅卵石（bWasThrown=true）-> 严格 1 倍（6 -> 7）
    local thrownPebActor, _ = makeSpawnedItemActor({ rowName = "Pebblet", wasThrown = true, stackSize = 1, maxStack = 100 })
    touchHook.pre({ get = function() return thrownPebActor end }, { get = function() return pHost26 end })
    pebItem1:AdjustStackSize(1) -- 原版 +1（6 -> 7）
    clientAddedHook.pre(
        { get = function() return pHost26.InventoryComponent end },
        { get = function() return { RowName = makeFName("Pebblet") } end },
        { get = function() return true end }
    )
    assertEq(pebItem1.StackSize, 7, "手持鹅卵石时捡回自己投掷出的鹅卵石必须严格保持 1 倍(6->7)")

    -- 5. TryPickupItem 分支 2（联机客机兜底）：客机手持 2 颗鹅卵石在房主端按 E 拾取 1 颗（ClientOnItemAdded 为发往客机的远程 RPC 不在房主本地触发）
    local cliWeapon = makeInvItem("Pebblet", 2, 100, true)
    pCli26.EquipmentComponent._weapon = cliWeapon
    local pebActorCli, _ = makeSpawnedItemActor({ rowName = "Pebblet", preplacedType = 0, stackSize = 1, maxStack = 100 })
    pCli26.InteractableInRange = { ObjectPointer = pebActorCli }
    interactHook.pre({ get = function() return pCli26 end })
    cliWeapon:AdjustStackSize(1) -- 原版在房主服务端先 +1（2 -> 3），ClientOnItemAdded 未在房主本地执行
    interactHook.post({ get = function() return pCli26 end })
    assertEq(cliWeapon.StackSize, 5, "联机客机手持 2 颗鹅卵石再捡 1 颗(3x)通过房主端交互兜底必须精确变为 5 颗（2 + 1*3）")

    -- 6. 校验 status.json 中 lootCompCount（本次已生效计数）必须真实 > 0
    stepTick(1.0)
    local st26 = readJsonFile(modDataDir .. "\\status.json")
    assertTrue((st26.lootCompCount or 0) >= 3, "采集倍率真实生效后 status.json.lootCompCount 必须实时递增（实际=" .. tostring(st26.lootCompCount) .. "）")
end)

runCase("L27: 首次采集即在 AddItem Pre-Hook 同步走倍率（首采 HUD 播报与背包均直接 3x、满包拒绝精确回滚、分支 4 防二次翻倍）", function()
    local _, _, pHost27 = buildWorld({ worldTag = "R_FirstGather", isHost = true })
    pHost27.HasAuthority = function() return true end

    writeJsonFile(modDataDir .. "\\config.json", {
        harvestEnabled = true, harvestMultiplier = 3,
        harvestAffectHauling = true, harvestAffectPickup = true,
    })
    stepTick(1.0)
    stepTick(3.0)

    local addHook = capturedHooks["/Script/Maine.InventoryComponent:AddItem"]
    local equipHook = capturedHooks["/Script/Maine.EquipmentComponent:ServerEquipItem"]

    -- 1. 首次采集背包里原本为 0 的材料：在原生 AddItem 本体读取 item.StackSize（驱动 HUD +N 播报）之时就已经是 3，而非首次 1、二次才 3！
    local firstActor, firstItem = makeSpawnedItemActor({ rowName = "FiberRaw", preplacedType = 2, stackSize = 1, maxStack = 100 })
    local stackSeenByNativeAddItem = 0
    addHook.pre(
        { get = function() return pHost27.InventoryComponent end },
        { get = function() return firstItem end },
        { get = function() return true end }
    )
    stackSeenByNativeAddItem = firstItem.StackSize
    table.insert(pHost27.InventoryComponent.Items, firstItem)
    addHook.post(
        { get = function() return pHost27.InventoryComponent end },
        { get = function() return firstItem end },
        { get = function() return true end }
    )
    assertEq(stackSeenByNativeAddItem, 3, "首次采集在 AddItem 本体执行/播报 HUD 之前 StackSize 就必须已变为 3（解决首采不走倍率）")
    assertEq(getInvTotal(pHost27.InventoryComponent, "FiberRaw"), 3, "首次采集结束后背包内总数应精确为 3")

    -- 2. 第二次采集同样材料：继续精确 +3（3 -> 6）
    local secondActor, secondItem = makeSpawnedItemActor({ rowName = "FiberRaw", preplacedType = 2, stackSize = 1, maxStack = 100 })
    simulateAddItem(pHost27.InventoryComponent, secondItem, true)
    assertEq(getInvTotal(pHost27.InventoryComponent, "FiberRaw"), 6, "第二次采集同样材料后背包内总数应精确为 6")

    -- 3. TryPickupItem 分支 4 连续调用 AddItem 后紧跟 ServerEquipItem(item, false)：同对象防重不得二次翻倍（应保持 3 而非 9）
    local branch4Actor, branch4Item = makeSpawnedItemActor({ rowName = "Pebblet", preplacedType = 0, stackSize = 1, maxStack = 100 })
    simulateAddItem(pHost27.InventoryComponent, branch4Item, true)
    equipHook.pre({ get = function() return pHost27.EquipmentComponent end }, { get = function() return branch4Item end }, { get = function() return false end })
    equipHook.post({ get = function() return pHost27.EquipmentComponent end }, { get = function() return branch4Item end }, { get = function() return false end })
    assertEq(branch4Item.StackSize, 3, "TryPickupItem 分支 4 AddItem->ServerEquipItem 对同一 UItem 严禁二次倍增")

    -- 4. 引擎拒绝入包时（如自定义容器过滤或满包拒收），Post-Hook 必须把 Pre-Hook 预加的 StackSize 精确回滚为 1
    local rejectedItem = makeInvItem("Sap", 1, 100, true)
    addHook.pre(
        { get = function() return pHost27.InventoryComponent end },
        { get = function() return rejectedItem end },
        { get = function() return true end }
    )
    assertEq(rejectedItem.StackSize, 3, "Pre-Hook 应先尝试预加为 3")
    -- 模拟原生 AddItem 未将其加入 inv.Items（拒收）
    addHook.post(
        { get = function() return pHost27.InventoryComponent end },
        { get = function() return rejectedItem end },
        { get = function() return true end }
    )
    assertEq(rejectedItem.StackSize, 1, "原生 AddItem 拒收时，Post-Hook 必须将地面物品 StackSize 精确回滚为原版 1")
    assertEq(getInvTotal(pHost27.InventoryComponent, "Sap"), 0, "拒收物品不得凭空出现在背包中")

    -- 5. 背包 0 空槽但已有未满堆叠仅剩 1 格空间（99/100）时：Pre-Hook 必须按余量截断，绝不撑爆背包槽位
    pHost27.InventoryComponent.Items = {}
    pHost27.InventoryComponent.MaxSize = 1
    local existing99 = makeInvItem("CloverTop", 99, 100, true)
    table.insert(pHost27.InventoryComponent.Items, existing99)
    local lastClover = makeInvItem("CloverTop", 1, 100, true)
    simulateAddItem(pHost27.InventoryComponent, lastClover, true)
    assertEq(#pHost27.InventoryComponent.Items, 1, "0 空槽仅剩 1 堆叠余量时严禁溢出创建超限槽位")
    assertEq(getInvTotal(pHost27.InventoryComponent, "CloverTop"), 100, "0 空槽仅剩 1 堆叠余量时应精确填满至 100")
end)

runCase("L28: 击杀昆虫掉落全场景回归（BlueprintDropItems 不泄漏深度 + 投掷击杀不误拦虫材 + 昆虫 DroppedByActor 放行 + 易腐昆虫生肉倍增且装备/箱子严格 1x）", function()
    local _, _, pHost28 = buildWorld({ worldTag = "S_InsectDrops", isHost = true })
    pHost28.HasAuthority = function() return true end

    writeJsonFile(modDataDir .. "\\config.json", {
        harvestEnabled = true, harvestMultiplier = 3,
        harvestAffectHauling = true, harvestAffectPickup = true,
    })
    stepTick(1.0)
    stepTick(3.0)

    local bpDropHook = capturedHooks["/Script/Maine.Building:BlueprintDropItems"]
    local throwHook = capturedHooks["/Script/Maine.SurvivalPlayerCharacter:ServerReleaseThrow"]
    local notifySpawnHook = capturedHooks["/Script/Maine.SpawnedItem:NotifySpawned"]
    local touchHook = capturedHooks["/Script/Maine.SpawnedItem:HandleTouch"]
    local transferFromHook = capturedHooks["/Script/Maine.InventoryComponent:ServerTransferItemFrom"]
    local dropHook = capturedHooks["/Script/Maine.InventoryComponent:ServerDropItem"]

    -- 1. Building:BlueprintDropItems 必须是单回调（无 post），调用后绝不泄漏 inExcludedDropDepth 污染后续昆虫掉落！
    assertTrue(bpDropHook ~= nil and type(bpDropHook.pre) == "function", "必须注册 Building:BlueprintDropItems Hook")
    assertEq(bpDropHook.post, nil, "Building:BlueprintDropItems 为蓝图脚本钩子，严禁注册第二 Post-Hook 回调（防止深度永久泄漏与 UE4SS 报错）")
    local farBld = makeUObject("Building", "BP_GrassWall_Far_1", {
        K2_GetActorLocation = function() return { X = 50000, Y = 50000, Z = 0 } end,
    })
    bpDropHook.pre({ get = function() return farBld end })

    -- 紧接着一只昆虫在玩家旁边死亡并通过 NotifySpawned 生成掉落物，绝不可被污染拉黑
    local deadSpiderActor = makeUObject("SurvivalCreature", "BP_Spider_Wolf_C_Dead28", {
        IsA = function(_, clsOrPath)
            return clsOrPath == "/Script/Maine.SurvivalCreature"
                or (type(clsOrPath) == "table" and clsOrPath._classPath == "/Script/Maine.SurvivalCreature")
        end,
    })
    local deadSpiderLod = makeUObject("CharacterLODActor", "LOD_Spider_28", {
        FullActor = deadSpiderActor,
        GetActorClassHard = function()
            return { IsValid = function() return true end, GetFName = function() return makeFName("BP_Spider_Wolf_C") end }
        end,
    })

    -- 2. 玩家手持鹅卵石长矛投掷（ServerReleaseThrow）击杀 2 米内昆虫 -> 捡起昆虫掉落材料必须走 3 倍，捡回投掷长矛本身严格 1 倍！
    local heldSpear = makeInvItem("SpearPebblet", 1, 1, false)
    pHost28.EquipmentComponent._weapon = heldSpear
    throwHook.pre({ get = function() return pHost28 end })
    throwHook.post({ get = function() return pHost28 end })

    -- 昆虫掉落物带有原生 DroppedByActor = 死亡蜘蛛 LODActor，且在玩家投掷后 1 秒、距离 1 米处生成
    local spiderDropActor, spiderDropItem = makeSpawnedItemActor({
        rowName = "SpiderChunk",
        stackSize = 1, maxStack = 100, canStack = true,
        droppedBy = deadSpiderLod,
        droppedBySpawned = deadSpiderActor,
        x = 1050, y = 2000, z = 300,
    })
    notifySpawnHook.pre({ get = function() return spiderDropActor end })
    simulateAddItem(pHost28.InventoryComponent, spiderDropItem, true)
    assertEq(getInvTotal(pHost28.InventoryComponent, "SpiderChunk"), 3,
        "BlueprintDropItems 后 + 投掷击杀 1 米内 + 昆虫 DroppedByActor 的蜘蛛块必须正常走 3 倍")

    -- 对照防刷：玩家亲手丢弃（DroppedByActor = 玩家角色）或建筑掉落（DroppedByActor = Building）依然严格 1 倍
    local playerLod = makeUObject("CharacterLODActor", "LOD_Player_28", { FullActor = pHost28 })
    local _, playerDropItem = makeSpawnedItemActor({
        rowName = "AntPart", droppedBy = playerLod, droppedBySpawned = pHost28,
    })
    simulateAddItem(pHost28.InventoryComponent, playerDropItem, true)
    assertEq(getInvTotal(pHost28.InventoryComponent, "AntPart"), 1, "玩家角色作为 DroppedByActor 的丢弃物必须严格保持 1 倍")

    local bldDropper = makeUObject("Building", "BP_Storage_28", {
        IsA = function(_, clsOrPath)
            return clsOrPath == "/Script/Maine.Building"
                or (type(clsOrPath) == "table" and clsOrPath._classPath == "/Script/Maine.Building")
        end,
    })
    local _, bldDropItem = makeSpawnedItemActor({
        rowName = "BugRubber", droppedBySpawned = bldDropper,
    })
    simulateAddItem(pHost28.InventoryComponent, bldDropItem, true)
    assertEq(getInvTotal(pHost28.InventoryComponent, "BugRubber"), 1, "建筑作为 DroppedByActor 的拆建掉落物必须严格保持 1 倍")

    -- 3. 刚触碰/捡起插在虫尸上的玩家射出箭矢（ctx.target 为被拦的 ArrowThistle）后立刻摸死虫尸体直入背包：不得被残留 ctx.target 误拦截
    local stuckArrowActor, _ = makeSpawnedItemActor({ rowName = "ArrowThistle", attackOwner = pHost28 })
    touchHook.pre({ get = function() return stuckArrowActor end }, { get = function() return pHost28 end })
    simulateAddItem(pHost28.InventoryComponent, "GrubHide", 1, true)
    assertEq(getInvTotal(pHost28.InventoryComponent, "GrubHide"), 3,
        "刚触碰插在虫尸上的箭矢后摸尸直入背包的幼虫皮不得被残留 ctx.target 误拦，必须走 3 倍")

    -- 4. 易腐昆虫生肉（GrubMeat：CanStack=false, MaxStack=1, CanSpoil=true, CanEquip=false, HasDurability=false, EquipmentSlot=0）
    --    拾取时按 3 倍补发额外生肉副本到空闲槽位（1 -> 3 格）；同时从箱子取出、自丢捡回以及单件武器/装备必须严格 1 倍！
    local function makePerishableMeat(rowName)
        local it = makeInvItem(rowName, 1, 1, false)
        it.CanSpoil = function() return true end
        it.GetTotalSpoilTime = function() return 1440.0 end
        it.CanEquip = function() return false end
        it.GetEquipmentSlot = function() return 0 end
        it.HasDurability = function() return false end
        it.IsAHaulingItem = function() return false end
        return it
    end
    local grubMeatActor, grubMeatItem = makeSpawnedItemActor({
        rowName = "GrubMeat",
        itemObj = makePerishableMeat("GrubMeat"),
        droppedBy = deadSpiderLod,
        droppedBySpawned = deadSpiderActor,
    })
    simulateAddItem(pHost28.InventoryComponent, grubMeatItem, true)
    assertEq(getInvTotal(pHost28.InventoryComponent, "GrubMeat"), 3,
        "易腐昆虫生肉(CanSpoil=true 且不可装备无耐久)拾取时应按 3 倍自动补发至空闲槽位(1->3)")

    -- 防刷校验 A：从箱子取出易腐生肉必须严格 1 倍（3 -> 4）
    transferFromHook.pre()
    simulateAddItem(pHost28.InventoryComponent, makePerishableMeat("GrubMeat"), true)
    transferFromHook.post()
    assertEq(getInvTotal(pHost28.InventoryComponent, "GrubMeat"), 4, "从箱子取出易腐生肉严禁倍增(3->4)")

    -- 防刷校验 B：玩家丢弃易腐生肉再捡回必须严格 1 倍（4 -> 5）
    local droppedMeat = makePerishableMeat("GrubMeat")
    local droppedMeatActor = makeSpawnedItemActor({ rowName = "GrubMeat", itemObj = droppedMeat, droppedBy = playerLod, droppedBySpawned = pHost28 })
    dropHook.pre({ get = function() return pHost28.InventoryComponent end }, { get = function() return droppedMeat end }, { get = function() return 1 end })
    notifySpawnHook.pre({ get = function() return droppedMeatActor end })
    dropHook.post()
    simulateAddItem(pHost28.InventoryComponent, droppedMeat, true)
    assertEq(getInvTotal(pHost28.InventoryComponent, "GrubMeat"), 5, "玩家自丢易腐生肉再捡回严禁倍增(4->5)")

    -- 防刷校验 C：可装备的易腐/耐久单件道具（如带 CanEquip=true 的火把/护符）严禁复制（严格 1 倍）
    local equippablePerishable = makePerishableMeat("SlimeMoldTorch")
    equippablePerishable.CanEquip = function() return true end
    equippablePerishable.GetEquipmentSlot = function() return 2 end
    simulateAddItem(pHost28.InventoryComponent, equippablePerishable, true)
    assertEq(getInvTotal(pHost28.InventoryComponent, "SlimeMoldTorch"), 1, "可装备单件物品即使带耐久/腐败也严禁复制，必须严格 1 倍")
end)

runCase("L29: ADR-0006 纯 GameThread 调度静态源码红线与运行时启动引导校验", function()
    -- 1. 静态扫描 main.lua 有效非注释代码行：禁止任何后台异步调度调用，仅允许 1 次启动期 ExecuteInGameThread + LoopInGameThreadWithDelay
    local f = assert(origIoOpen(mainLuaPath, "rb"))
    local src = f:read("*a")
    f:close()

    local inBlockComment = false
    local execInGtCalls = 0
    local loopInGtCalls = 0
    local bannedCalls = {}
    local lineNo = 0
    for line in (src .. "\n"):gmatch("(.-)\r?\n") do
        lineNo = lineNo + 1
        local code = line
        if inBlockComment then
            local closePos = code:find("]]", 1, true)
            if closePos then
                inBlockComment = false
                code = code:sub(closePos + 2)
            else
                code = ""
            end
        end
        if code ~= "" then
            local blkStart = code:find("%-%-%[%[")
            if blkStart then
                local before = code:sub(1, blkStart - 1)
                if not code:find("]]", blkStart + 4, true) then
                    inBlockComment = true
                end
                code = before
            else
                code = code:gsub("%-%-.*$", "")
            end
        end
        if code:find("LoopAsync%s*%(") then table.insert(bannedCalls, "L" .. lineNo .. ":LoopAsync") end
        if code:find("ExecuteAsync%s*%(") then table.insert(bannedCalls, "L" .. lineNo .. ":ExecuteAsync") end
        if code:find("ExecuteWithDelay%s*%(") then table.insert(bannedCalls, "L" .. lineNo .. ":ExecuteWithDelay") end
        if code:find("ExecuteInGameThread%s*%(") then execInGtCalls = execInGtCalls + 1 end
        if code:find("LoopInGameThreadWithDelay%s*%(") then loopInGtCalls = loopInGtCalls + 1 end
    end

    assertEq(#bannedCalls, 0, "ADR-0006：main.lua 严禁存在任何 LoopAsync/ExecuteAsync/ExecuteWithDelay 调用，发现=" .. table.concat(bannedCalls, ","))
    assertEq(execInGtCalls, 1, "ADR-0006：main.lua 仅允许启动期 1 次 ExecuteInGameThread 引导调用")
    assertEq(loopInGtCalls, 1, "ADR-0006：main.lua 必须通过 LoopInGameThreadWithDelay 挂载唯一主线程循环")

    -- 2. 运行时核验：全过程至今 ExecuteInGameThread 总计严格等于 1，且全部 45 个 Hook 均在 GameThread 引导内安装完成
    assertEq(perfCounters.gameThreadBootstraps, 1, "整个回归过程运行期 ExecuteInGameThread 调用总数必须始终为 1")
    assertEq(hooksRegisteredOutsideGameThread, 0, "严禁任何 RegisterHook 在 GameThread 之外注册")
    local hookCount = 0
    for _ in pairs(capturedHooks) do hookCount = hookCount + 1 end
    assertTrue(hookCount >= 40, "主线程引导必须完整注册全部原生 UFunction Hook（当前=" .. tostring(hookCount) .. "）")
end)

runCase("L30: UE4SS 4.x TSoftObjectPtrUserdata 解析修复（BestiaryTable 与未加载 ULootBagLODActor 零 Userdata 泄漏）", function()
    local _, _, pHost30 = buildWorld({ worldTag = "T30_SoftPtr", isHost = true })
    stepTick(1.0)
    stepTick(3.0)

    -- 1. 验证 L16 使用 TSoftObjectPtrUserdata 构造的 BestiaryTable 产出干净目录，绝对不包含任何 "Userdata:" 指针条目
    local cat = readJsonFile(modDataDir .. "\\catalog.json")
    assertTrue(cat ~= nil and #cat > 0, "应正常生成 catalog.json")
    local hasBee, hasLarva, hasBlackAnt = false, false, false
    for _, e in ipairs(cat) do
        assertTrue(not tostring(e.id):find("Userdata:", 1, true) and not tostring(e.id):find("userdata:", 1, true),
            "catalog.json 严禁出现 TSoftObjectPtrUserdata 内存地址条目: " .. tostring(e.id))
        assertTrue(not tostring(e.name):find("Userdata:", 1, true),
            "catalog.json 显示名严禁包含 Userdata 内存地址: " .. tostring(e.name))
        if e.id == "creature:Bee" and e.name == "蜜蜂" then hasBee = true end
        if e.id == "creature:Larva" and e.name == "幼虫" then hasLarva = true end
        if e.id == "creature:Ant_Black" and e.name == "黑工蚁" then hasBlackAnt = true end
    end
    assertTrue(hasBee, "TSoftObjectPtrUserdata:GetObjectID():GetAssetPathName() 必须精准解析 creature:Bee -> 蜜蜂")
    assertTrue(hasLarva, "当 TSoftObjectPtrUserdata 路径为 None 时必须拒绝指针文本并安全回退 rowName -> creature:Larva(幼虫)")
    assertTrue(hasBlackAnt, "TSoftObjectPtrUserdata 必须精准解析 creature:Ant_Black -> 黑工蚁")

    -- 2. 验证远距未加载 ULootBagLODActor 在 GetActorClassHard() 为空、仅 GetActorClassSoft() 返回 TSoftObjectPtrUserdata 时：
    --    - 玩家背包(BP_Backpack_C)能被正确识别并唤醒找回；
    --    - Ominent 宝箱(BP_Ominent_Chest_C)与坏指针(None)均被严密拦截、0 唤醒！
    local softBackpack = makeLootBag({
        id = "SoftPtrHostBag", bagType = 1, itemCount = 2,
        ownerGuid = pHost30.PlayerGuid, ownerName = "HostAlice",
        x = 60000, y = -30000, z = 120,
    })
    local lodSoftBackpack = makeUnloadedLootBagLod(softBackpack, { actorClassName = "BP_Backpack_C" })
    lodSoftBackpack.GetActorClassHard = function() return nil end
    lodSoftBackpack.GetActorClassSoft = function()
        return makeSoftObjectPtrUserdata("/Game/Blueprints/Items/BP_Backpack.BP_Backpack_C", "000001D811112222")
    end
    lodSoftBackpack.IsFullActorType = function() return false end

    local softChest = makeLootBag({
        id = "SoftPtrOminentChest", bagType = 0, itemCount = 4,
        ownerGuid = pHost30.PlayerGuid, ownerName = "HostAlice",
        x = 61000, y = -31000, z = 120,
    })
    local lodSoftChest = makeUnloadedLootBagLod(softChest, { actorClassName = "BP_Ominent_Chest_C" })
    lodSoftChest.GetActorClassHard = function() return nil end
    lodSoftChest.GetActorClassSoft = function()
        return makeSoftObjectPtrUserdata("/Game/Blueprints/Props/BP_Ominent_Chest.BP_Ominent_Chest_C", "000001D833334444")
    end
    lodSoftChest.IsFullActorType = function() return false end

    world.lods = { lodSoftBackpack, lodSoftChest }
    world.gs.LODActorManagerComponent.LODActors = world.lods
    world.loadedBags = {}

    sendAction("recover_my_backpacks")
    stepTick(1.0)
    assertEq(lodSoftBackpack._convertCalled, 1, "仅通过 TSoftObjectPtrUserdata 暴露 BP_Backpack_C 的远距玩家背包应被正确识别并唤醒")
    assertEq(softBackpack._movedCount, 1, "远距软指针背包唤醒后应成功瞬移到房主脚边")
    assertEq(lodSoftChest._convertCalled, 0, "通过 TSoftObjectPtrUserdata 暴露 BP_Ominent_Chest_C 的未加载宝箱必须被黑名单拦死（0 唤醒）")
end)

runCase("L31: pollConfig() 自动清洗历史损坏 trackedIds（过滤 Userdata 指针项并保留正常追踪项）", function()
    buildWorld({ worldTag = "T31_SanitizeTracked", isHost = false })
    world.lods = {}
    world.gs.LODActorManagerComponent.LODActors = world.lods
    world.creatures = {
        makeUObject("BP_Bee_C", "AR:Bee31", { K2_GetActorLocation = function() return { X = 2100, Y = 3100, Z = 100 } end }),
    }
    world.harvestNodes = {
        makeUObject("BP_Rock_Clay_C", "AR:Clay31", { K2_GetActorLocation = function() return { X = 2200, Y = 3200, Z = 20 } end }),
    }

    local mapPanelMock = makeUObject("MapPanelWidget", "MapPanel31", {
        MinBounds = { X = -80000, Y = -80000 }, MaxBounds = { X = 80000, Y = 80000 },
        TextureSize = { X = 2048, Y = 2048 },
        CollectibleCanvas = makeUObject("CanvasPanel", "CC31"),
        MapBorder = makeUObject("Border", "MB31"),
        PlayerCanvas = makeUObject("CanvasPanel", "PC31", { GetChildrenCount = function() return 0 end }),
    })
    local rootWinMock = makeUObject("InGameMenuWidget", "UI_InGameMenu31", {
        Map = makeUObject("UI_Map", "UI_Map_C31", { Active = true, MapPanel = mapPanelMock }),
    })
    gameInstanceMock.WidgetManager = makeUObject("WidgetManager", "WM31", {
        GetTopWindow = function() return rootWinMock end,
        WindowStack = { rootWinMock },
    })

    writeJsonFile(modDataDir .. "\\config.json", {
        trackedIds = {
            "creature:TSoftObjectPtrUserdata: 000001D82641E4D8",
            "creature:Bee",
            "node:userdata: 0xdeadbeef",
            "node:Rock_Clay",
        },
    })
    stepTick(1.0)
    stepTick(3.0)
    stepTick(0.5)

    local ml = readJsonFile(modDataDir .. "\\map_live.json")
    assertTrue(ml ~= nil and ml.mapOpen == true and ml.pins ~= nil, "含脏 trackedIds 的 config.json 不得导致 M 地图渲染异常")
    local pinIds = {}
    for _, p in ipairs(ml.pins) do
        assertTrue(not tostring(p.id):find("Userdata:", 1, true) and not tostring(p.id):find("userdata:", 1, true),
            "M 地图标点严禁包含已清洗的 Userdata 脏 ID: " .. tostring(p.id))
        pinIds[p.id] = (pinIds[p.id] or 0) + 1
    end
    assertEq(pinIds["creature:Bee"], 1, "清洗脏 trackedIds 后正常追踪生物 creature:Bee 必须照常亮标")
    assertEq(pinIds["node:Rock_Clay"], 1, "清洗脏 trackedIds 后正常追踪矿点 node:Rock_Clay 必须照常亮标")

    rootWinMock.Map.Active = false
    stepTick(0.5)
    gameInstanceMock.WidgetManager = nil
end)

runCase("L32: 反作弊与植被地址缓存有界 TTL + 容量淘汰校验（超 TTL 不误拦复用地址，有效期内防刷严格不变）", function()
    local _, _, pHost32 = buildWorld({ worldTag = "T32_BoundedCache", isHost = true })
    pHost32.HasAuthority = function() return true end

    writeJsonFile(modDataDir .. "\\config.json", {
        harvestEnabled = true, harvestMultiplier = 3,
        harvestAffectHauling = true, harvestAffectPickup = true,
    })
    stepTick(1.0)
    stepTick(3.0)

    local dropHook = capturedHooks["/Script/Maine.InventoryComponent:ServerDropItem"]
    local notifySpawnHook = capturedHooks["/Script/Maine.SpawnedItem:NotifySpawned"]
    local swapHook = capturedHooks["/Script/Maine.SpawnedItem:NotifySwapped"]

    -- 1. 玩家丢弃物品 A（记录其地址），推进 25 秒（超过 20s 事件窗但远小于 600s 地址 TTL）-> 捡回仍必须严格 1 倍防刷
    local droppedA = makeInvItem("Sap", 1, 100, true)
    local addrA = droppedA:GetAddress()
    local actorA = makeSpawnedItemActor({ rowName = "Sap", itemObj = droppedA })
    dropHook.pre({ get = function() return pHost32.InventoryComponent end }, { get = function() return droppedA end }, { get = function() return 1 end })
    notifySpawnHook.pre({ get = function() return actorA end })
    dropHook.post()

    mockClock = mockClock + 25.0
    local pickupA = makeInvItem("Sap", 1, 100, true)
    pickupA._addr = addrA
    simulateAddItem(pHost32.InventoryComponent, pickupA, true)
    assertEq(getInvTotal(pHost32.InventoryComponent, "Sap"), 1, "600s TTL 内玩家自丢物地址仍必须严格保持 1 倍防刷")

    -- 2. 模拟超长时间游玩推进 605 秒（> EXCLUDED_ADDR_TTL=600s），引擎内存复用同一地址生成全新野生采集物 -> 过期条目自动释放，正常走 3 倍
    mockClock = mockClock + 605.0
    local reusedWildSap = makeInvItem("Sap", 1, 100, true)
    reusedWildSap._addr = addrA
    simulateAddItem(pHost32.InventoryComponent, reusedWildSap, true)
    assertEq(getInvTotal(pHost32.InventoryComponent, "Sap"), 4, "超过 600s TTL 后复用地址的新野生掉落应自动解除黑名单并走 3 倍(1+3=4)")

    -- 3. 批量注入 600 个不同丢弃地址触发 512 容量上限淘汰，验证最新丢弃物仍严格保持 1 倍且不会无限增长
    local newestDroppedAddr = nil
    for i = 1, 600 do
        mockClock = mockClock + 0.05
        local dummy = makeInvItem("AcornBits", 1, 100, true)
        local dAct = makeSpawnedItemActor({ rowName = "AcornBits", itemObj = dummy })
        dropHook.pre({ get = function() return pHost32.InventoryComponent end }, { get = function() return dummy end }, { get = function() return 1 end })
        notifySpawnHook.pre({ get = function() return dAct end })
        dropHook.post()
        newestDroppedAddr = dummy:GetAddress()
    end
    mockClock = mockClock + 25.0
    local newestPick = makeInvItem("AcornBits", 1, 100, true)
    newestPick._addr = newestDroppedAddr
    simulateAddItem(pHost32.InventoryComponent, newestPick, true)
    assertEq(getInvTotal(pHost32.InventoryComponent, "AcornBits"), 1, "容量淘汰仅清理最旧地址，最新丢弃物仍必须严格保持 1 倍")

    -- 4. 植被直拾地址缓存 TTL(120s)：关闭自然直拾时 5s 内严格 1 倍；超过 125s 后复用地址的非直拾掉落自动解封走 3 倍
    writeJsonFile(modDataDir .. "\\config.json", {
        harvestEnabled = true, harvestMultiplier = 3,
        harvestAffectHauling = true, harvestAffectPickup = false,
    })
    stepTick(1.0)

    local folActFresh, folItemFresh = makeSpawnedItemActor({ rowName = "PlantFiber", preplacedType = 0 })
    local folActExp, folItemExp = makeSpawnedItemActor({ rowName = "PlantFiber", preplacedType = 0 })
    local folExpAddr = folItemExp:GetAddress()
    swapHook.pre({ get = function() return folActFresh end }, nil, { get = function() return false end })
    swapHook.pre({ get = function() return folActExp end }, nil, { get = function() return false end })

    mockClock = mockClock + 5.0
    simulateAddItem(pHost32.InventoryComponent, folItemFresh, true)
    assertEq(getInvTotal(pHost32.InventoryComponent, "PlantFiber"), 1, "120s TTL 内且关闭自然直拾时，植被直拾物品必须保持 1 倍")

    mockClock = mockClock + 125.0
    local reusedWildFiber = makeInvItem("PlantFiber", 1, 100, true)
    reusedWildFiber._addr = folExpAddr
    simulateAddItem(pHost32.InventoryComponent, reusedWildFiber, true)
    assertEq(getInvTotal(pHost32.InventoryComponent, "PlantFiber"), 4, "超过 120s TTL 后复用地址的新采集物不得再被误判为自然直拾(1+3=4)")
end)

runCase("L33: scaleHaulingLootPre / restoreHaulingLootPost 关闭搬运开关时的纯 Lua 零 UObject 早退校验", function()
    buildWorld({ worldTag = "T33_HaulingEarlyExit", isHost = true })

    local spawnHook = capturedHooks["/Script/Maine.LootComponent:SpawnLoot"]
    local onDeathHook = capturedHooks["/Script/Maine.LootComponent:OnDeath"]
    local onDamagedHook = capturedHooks["/Script/Maine.LootComponent:OnDamaged"]
    local plankEntry = { Type = 0, Count = 4, ItemData = { RowName = makeFName("GrassPlank") } }
    local lcGrass = makeUObject("LootComponent", "LC_Grass_33", {
        GetOuter = function() return makeUObject("HarvestNode", "BP_GrassBlade_A_C_33") end,
        Items = { plankEntry },
    })

    local selfGetCalls = 0
    local trackedSelfParam = {
        get = function()
            selfGetCalls = selfGetCalls + 1
            return lcGrass
        end,
    }
    local killingBlowParam = { get = function() return true end }

    -- 1. harvestEnabled=true 但 harvestAffectHauling=false：全部搬运入口 Pre/Post 必须零 UObject 读取早退
    writeJsonFile(modDataDir .. "\\config.json", {
        harvestEnabled = true, harvestMultiplier = 4,
        harvestAffectHauling = false, harvestAffectPickup = true,
    })
    stepTick(1.0)
    selfGetCalls = 0
    spawnHook.pre(trackedSelfParam)
    spawnHook.post(trackedSelfParam)
    onDeathHook.pre(trackedSelfParam)
    onDeathHook.post(trackedSelfParam)
    onDamagedHook.pre(trackedSelfParam, nil, nil, nil, nil, killingBlowParam)
    onDamagedHook.post(trackedSelfParam)
    assertEq(selfGetCalls, 0, "关闭搬运物倍率子开关时，SpawnLoot/OnDeath/OnDamaged 必须纯 Lua 零 UObject(selfParam:get) 早退")
    assertEq(plankEntry.Count, 4, "关闭搬运物子开关时草板 Count 保持原版 4")

    -- 2. harvestEnabled=false 且 harvestAffectHauling=true：同样必须零 UObject 读取早退
    writeJsonFile(modDataDir .. "\\config.json", {
        harvestEnabled = false, harvestMultiplier = 4,
        harvestAffectHauling = true, harvestAffectPickup = true,
    })
    stepTick(1.0)
    selfGetCalls = 0
    spawnHook.pre(trackedSelfParam)
    spawnHook.post(trackedSelfParam)
    assertEq(selfGetCalls, 0, "关闭采集倍率总开关时，搬运 Hook 必须纯 Lua 零 UObject 早退")

    -- 3. 重新双开后正常瞬时放大封顶 12 并精确还原为 4（确认早退逻辑不影响正常功能）
    writeJsonFile(modDataDir .. "\\config.json", {
        harvestEnabled = true, harvestMultiplier = 4,
        harvestAffectHauling = true, harvestAffectPickup = true,
    })
    stepTick(1.0)
    selfGetCalls = 0
    spawnHook.pre(trackedSelfParam)
    assertEq(plankEntry.Count, 12, "重新开启搬运倍率后草板应瞬时放大封顶 12")
    spawnHook.post(trackedSelfParam)
    assertEq(plankEntry.Count, 4, "Post-Hook 必须精准还原草板原版 Count=4")
    assertTrue(selfGetCalls >= 2, "开启状态下应正常读取 LootComponent UObject")
end)

-- 清理本次测试在 lua/GroundedQoL/data 下产生的临时 JSON 文件
os.remove(modDataDir .. "\\config.json")
os.remove(modDataDir .. "\\actions.json")
os.remove(modDataDir .. "\\status.json")
os.remove(modDataDir .. "\\catalog.json")
os.remove(modDataDir .. "\\map_live.json")
os.execute('rmdir "' .. modDataDir .. '" >nul 2>&1')

origPrint(string.format("\n=== ALL %d LUA REGRESSION CASES PASSED ===", passedCount))
