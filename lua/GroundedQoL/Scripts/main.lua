--[[
    文件：lua/GroundedQoL/Scripts/main.lua
    职责：GroundedQoL（禁闭求生体验增强工具箱）UE4SS v4.0.0 Lua 引擎逻辑层。
    核心架构：
      1. 单异步定时器 + ExecuteInGameThread 单飞调度器，彻底规避 UE4SS 多 LoopAsync 并发访问 UObject 导致的崩溃。
      2. 通过原子文件 IPC（data/*.json）与原生 C++ DX12/DX11 Dear ImGui 悬浮层解耦通信。
      3. 原地覆写运行时 USurvivalGameModeSettings（绝不切换为自定义模式），100% 保留 Steam 成就。
    核心功能：
      - 物品堆叠上限倍率（自动保护基础堆叠为 1 的装备）
      - 战斗伤害倍率、无材料秒建、免费制作、死亡背包保留与免除死亡耐久惩罚
      - 采集与掉落数量倍率（含草板搬运上限保护与自然拾取增量 Hook）
      - 一键找回掉落背包（唤醒远距 LOD、跳过空包与建筑战利品袋、前方扇形错开落地并同步联机坐标）
      - “M” 地图乳牙/高级乳牙/全游戏资源实时追踪、原版路标放置与全队资源扫描联动
]]

local UEHelpers = require("UEHelpers")
local json = require("json")

-- ============================================================
-- 1. 路径初始化与原生 DX12/DX11 悬浮菜单 DLL 加载
-- ============================================================

--- 从当前脚本路径推导出 Mod 根目录（...\ue4ss\Mods\GroundedQoL），用于定位 DLL 与 data/ 通信目录。
local function getModRootDir()
    local src = debug.getinfo(1, "S").source or ""
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    src = src:gsub("/", "\\")
    local dir = src:match("^(.*)\\Scripts\\[^\\]+$") or src:match("^(.*)\\[^\\]+$") or "."
    return dir
end

local MOD_DIR = getModRootDir()
local DATA_DIR = MOD_DIR .. "\\data"
local CONFIG_PATH = DATA_DIR .. "\\config.json"
local CATALOG_PATH = DATA_DIR .. "\\catalog.json"
local MAP_LIVE_PATH = DATA_DIR .. "\\map_live.json"
local STATUS_PATH = DATA_DIR .. "\\status.json"
local ACTIONS_PATH = DATA_DIR .. "\\actions.json"

os.execute('mkdir "' .. DATA_DIR .. '" >nul 2>&1')

--- 统一带前缀的 UE4SS 控制台日志输出函数。
local function logInfo(msg)
    print("[GroundedQoL] " .. tostring(msg) .. "\n")
end

-- 加载原生 DX12/DX11 ImGui 悬浮菜单 DLL（仅通过 package.loadlib 触发 LoadLibraryA 与 DllMain 后台挂钩）
do
    local dllPath = MOD_DIR .. "\\GroundedQoLOverlay.dll"
    local f = io.open(dllPath, "rb")
    if f then
        f:close()
        local fn, err = package.loadlib(dllPath, "GroundedQoL_Bootstrap")
        if fn then
            logInfo("DX12/DX11 中文悬浮菜单 DLL 已加载: " .. dllPath)
        else
            logInfo("警告: 加载 GroundedQoLOverlay.dll 失败: " .. tostring(err))
        end
    else
        logInfo("未找到 GroundedQoLOverlay.dll: " .. dllPath)
    end
end

-- ============================================================
-- 2. 文件原子读写与默认配置
-- ============================================================

--- 以二进制模式读取文件全部内容，文件不存在或无法打开时返回 nil。
local function readAllText(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

--- 通过“写临时文件 + 替换重命名”原子写入文本，防止 C++ 悬浮层读到半截 JSON。
local function writeAtomicText(path, content)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return false end
    f:write(content)
    f:close()
    os.remove(path)
    local ok = os.rename(tmp, path)
    if not ok then
        -- 若目标文件瞬时被 C++ 端占用导致 rename 失败，降级为直接覆写
        local f2 = io.open(path, "wb")
        if f2 then
            f2:write(content)
            f2:close()
            os.remove(tmp)
            return true
        end
        return false
    end
    return true
end

--- 与 data/config.json 双向同步的运行时配置表（所有新开关默认偏向保守/不破坏原版规则）。
local cfg = {
    stackEnabled = true,
    stackMultiplier = 10,
    damageEnabled = true,
    playerDamageMultiplier = 1.5,
    enemyDamageMultiplier = 1.0,
    harvestEnabled = true,
    harvestMultiplier = 3,
    harvestAffectHauling = true,
    harvestAffectPickup = true,
    instantBuildEnabled = false,
    freeCraftEnabled = false,
    unlockAllRecipes = false,
    -- 死亡保护（默认关闭，按需开启；仅原地修改运行时设置，不影响 Steam 成就）
    keepInventoryOnDeath = false,
    noDeathDurabilityPenalty = false,
    showMilkMolars = true,
    showMegaMilkMolars = true,
    showScabColors = false,
    showCollectedMolars = false,
    showMapLabels = false,
    showMapLegend = true,
    mapIconScale = 1.0,
    imeCandidateMode = 0,
    trackedIds = {},
}

local lastConfigRaw = ""
local lastActionSession = ""
local lastActionSeq = 0
local lastStatusMessage = "插件已就绪，按 Insert 或 F8 打开中文菜单"
local lastStatusJson = ""
local lastMapLiveJson = ""
local lastCatalogJson = ""
local lastStackConfigKey = ""
local lastHarvestConfigKey = ""

-- ============================================================
-- 3. 缓存状态与辅助工具
-- ============================================================
-- 原版基准值缓存（用于关闭开关时精确还原原版难度设置，切换世界时会重置）
local origStackSizes = {}
local origStackBonusPerTier = nil
local origMaxDropStackSize = nil
local lastStackSummary = ""

local origDamageMap = {}   -- key=USurvivalGameModeSettings 地址，保存伤害/免材/死亡行为等原版基准值
local harvestBoostHits = 0 -- 当次进图实时生效的采集入包/搬运倍率计数（彻底替代旧的全图 LootComponent 扫表）
local spawnLootActiveDepth = {}       -- key=ULootComponent 地址 -> 当前并发调用深度（防 OnDeath->SpawnLoot 嵌套重复缩放）
local spawnLootRestoreMap = {}        -- key=ULootComponent 地址 -> 原版 Count 恢复记录（仅搬运物瞬时缩放）
local excludedSpawnedActorAddrs = {}  -- 本局内通过玩家丢弃/投掷/拆建生成的 ASpawnedItem 地址黑名单
local excludedItemObjAddrs = {}       -- 本局内被玩家丢弃/拆建返还的 UItem 对象地址黑名单
local recentExcludedDropEvents = {}   -- 近期玩家丢弃/拆建事件的空间兜底缓冲（防 C++ 内部新建 UItem 绕过地址表）
local inExcludedDropDepth = 0         -- 同步 Hook 深度：>0 时新生成的 ASpawnedItem 自动记入防刷黑名单
local inNonHarvestAddDepth = 0        -- 非采集入包调用深度（箱子转移/合并/制作/容器直取期间屏蔽入包倍率）
local inModExtraAddDepth = 0          -- 本插件溢出补发调用深度（防 ServerCreateAndAddItem 递归触发 AddItem 倍率）
local inAddItemDepth = 0              -- InventoryComponent:AddItem 同步执行深度（供 ClientOnItemAdded 精确识别 TryPickupItem 自动堆叠装备分支）
local foliagePickupActorAddrs = {}    -- 由 NotifySwapped(bFromDamage=false) 产生的天然植被直拾 ASpawnedItem 地址表
local foliagePickupItemAddrs = {}     -- 由 NotifySwapped(bFromDamage=false) 产生的天然植被直拾 UItem 地址表
local interactContextByPlayer = {}    -- 记录玩家当前/最近一次交互/触碰上下文（用于容器防护、直拾植被判定与装备栈增量溯源）
local pendingAddItemBoosts = {}       -- key=UInventoryComponent 地址 -> AddItem Pre/Post 共享待加倍栈
local pendingEquipBoosts = {}         -- key=UEquipmentComponent 地址 -> ServerEquipItem Pre/Post 共享待加倍栈
local recentEquipHandledByInv = {}    -- key=UInventoryComponent 地址 -> 刚由 ServerEquipItem 处理完的防重复记录
local recentlyBoostedItemAddrs = {}   -- key=UItem 地址 -> os.clock()（防止 TryPickupItem 分支 4 AddItem->ServerEquipItem 对同一物品二次倍增）
local cachedClassMap = {}             -- UClass 缓存表，供 obj:IsA(UClass) 正确校验类型

-- 引擎单件、高频世界对象与静态数据表句柄缓存（避免每帧/每秒重复 FindFirstOf 扫描 GObjects）
local cachedGlobalItemData = nil
local cachedGameState = nil
local cachedPawnAddr = nil
local cachedWidgetManager = nil
local cachedOEITextLib = nil
local cachedSlateLib = nil
local cachedLayoutLib = nil
local cachedStatics = nil
local cachedAllItemsTable = nil
local cachedHarvestNodesTable = nil
local cachedCharactersTable = nil
local cachedBestiaryTable = nil

-- 世界资源目录、本地化映射与乳牙统计缓存
local itemRowToZhName = {}
local surveyableRows = {}
local harvestTableByHint = {}
local charTableByHint = {}
local charTableRows = {}
local staticBestiaryCreatures = {}
local staticHarvestNodes = {}
local nodeClassToZhName = {}
local nodeClassToDropRows = {}
local creatureClassToZhName = {}
local catalogBuiltForWorld = nil
local worldEnterClock = 0
local worldInitialScanDone = false
local catalogList = {}
local catalogMetaById = {}
local worldPinBuckets = {}
local collectiblePins = {}
local molarStats = { unMilk = 0, totMilk = 0, unMega = 0, totMega = 0 }
local lastSurveyedName = ""
local foliagePinCache = {}

-- 常见未加载代理采集点的简体中文友好兜底名称（当远距离蓝图尚未流式加载时使用）
local NODE_FALLBACK_ZH = {
    food_mint = "薄荷糖",
    candy_spicy = "辛辣糖",
    candy_sour = "酸糖",
    candy_corn = "玉米糖",
    salt_cluster = "盐块矿点",
    acorn = "橡果",
    gum_node = "口香糖块",
    rock_clay = "黏土块",
    rock_pebble = "鹅卵石矿点",
    rock_armorstone1 = "脆性大理石矿点",
    rock_armorstone2 = "坚固大理石矿点",
    rock_armorstone3 = "至尊大理石矿点",
    rock_weaponstone1 = "脆性石英岩矿点",
    rock_weaponstone2 = "坚固石英岩矿点",
    rock_weaponstone3 = "至尊石英岩矿点",
    bombable_rock = "可炸裂岩石",
    spiderweb_sticky = "蜘蛛网",
    feather = "乌鸦羽毛",
    pinecone = "松果",
    burr = "毛刺球",
    berry = "树篱浆果",
    pupa = "虫蛹",
    splinter = "木刺",
    charcoal = "永燃木炭块",
    rust = "生锈螺丝/铁锈",
    toenail = "脚趾甲",
    lint = "棉絮/绒毛",
    cap_harvestable = "可采集蘑菇/菌盖",
    dst_hazeroot = "雾霾根茎",
    food_apple = "苹果核",
    food_hotdog = "热狗",
    food_donut = "甜甜圈",
    food_cookie = "曲奇饼干",
    muscle_sprout = "肌肉芽",
    pond_moss = "池塘苔藓",
    sunken_bone = "沉没骨头",
    scale_koi = "锦鲤鳞片",
    cattail = "香蒲",
    dandelion = "蒲公英",
    weed = "杂草/蒲公英茎",
}

--- 判断物品 RowName 是否属于需要肩扛的搬运物（草板、杂草茎等），用于采集倍率上限防卡顿控制。
local function isHaulingRowName(rowName)
    if not rowName then return false end
    local low = rowName:lower()
    return low:find("grassplank") ~= nil
        or low:find("stemweed") ~= nil
        or low:find("weedstem") ~= nil
        or low:find("plank") ~= nil
        or low == "log"
end

--- 安全检查 UE4SS UObject 代理是否仍然存活有效（避免 GC 回收后访问引发异常）。
local function safeValid(obj)
    if not obj then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end

--- 安全解包 UE4SS FWeakObjectPtr / RemoteUnrealParam / UObject，返回存活的 UObject 或 nil。
local function unwrapWeakObject(val)
    if not val then return nil end
    if safeValid(val) then return val end
    local inner = nil
    pcall(function()
        if val.Get then
            local o = val:Get()
            if safeValid(o) then inner = o end
        elseif val.get then
            local o = val:get()
            if safeValid(o) then inner = o end
        end
    end)
    return inner
end

--- 缓存并获取指定 UE 脚本路径对应的 UClass 对象，用于兼容 UE4SS v4.0.0 的 obj:IsA(UClass)。
local function getCachedUClass(scriptClassPath)
    local cached = cachedClassMap[scriptClassPath]
    if safeValid(cached) then return cached end
    local ok, cls = pcall(StaticFindObject, scriptClassPath)
    if ok and safeValid(cls) then
        cachedClassMap[scriptClassPath] = cls
        return cls
    end
    return nil
end

--- 兼容 UE4SS v4.0.0 与离线单测的类型判定（优先传 UClass*，再兜底传字符串路径与短类名匹配）。
local function isAOf(obj, scriptClassPath, fallbackShortName)
    if not safeValid(obj) then return false end
    local clsObj = getCachedUClass(scriptClassPath)
    if safeValid(clsObj) then
        local ok, res = pcall(function() return obj.IsA and obj:IsA(clsObj) == true end)
        if ok and res then return true end
    end
    local okStr, resStr = pcall(function() return obj.IsA and obj:IsA(scriptClassPath) == true end)
    if okStr and resStr then return true end
    if fallbackShortName and fallbackShortName ~= "" then
        local cname = ""
        pcall(function() cname = obj:GetClass():GetFName():ToString() end)
        if cname == fallbackShortName then return true end
    end
    return false
end

--- 懒获取 AllItemsTable（供 Hook 回调内安全使用，不依赖后文函数定义顺序）。
local function ensureAllItemsTable()
    if safeValid(cachedAllItemsTable) then return cachedAllItemsTable end
    pcall(function()
        local gi = UEHelpers.GetGameInstance()
        if safeValid(gi) and safeValid(gi.GlobalTableData) and safeValid(gi.GlobalTableData.AllItemsTable) then
            cachedAllItemsTable = gi.GlobalTableData.AllItemsTable
        end
    end)
    if not safeValid(cachedAllItemsTable) then
        pcall(function()
            local gtd = FindFirstOf("GlobalTableData")
            if safeValid(gtd) and safeValid(gtd.AllItemsTable) then
                cachedAllItemsTable = gtd.AllItemsTable
            end
        end)
    end
    return cachedAllItemsTable
end

--- 将 UE4SS 返回的字符串/FString/FName/FText 统一安全转换为纯 Lua 字符串。
local function ueStringToLua(v)
    if not v then return "" end
    if type(v) == "string" then return v end
    local ok, s = pcall(function()
        if v.ToString then return v:ToString() end
        return tostring(v)
    end)
    if ok and type(s) == "string" then return s end
    return ""
end

--- 将 UE4 的 FGuid（A/B/C/D 四个 int32）归一化为可比较的字符串键；全零或无效返回空串。
local function guidToKey(g)
    if not g then return "" end
    local ok, a, b, c, d = pcall(function()
        return g.A or 0, g.B or 0, g.C or 0, g.D or 0
    end)
    if not ok then return "" end
    if a == 0 and b == 0 and c == 0 and d == 0 then return "" end
    return string.format("%d_%d_%d_%d", a, b, c, d)
end

--- 获取 OEITextLibrary 静态默认对象（用于把游戏内 FLocString 翻译为当前简体中文显示名）。
local function getOEITextLib()
    if safeValid(cachedOEITextLib) then return cachedOEITextLib end
    local ok, obj = pcall(StaticFindObject, "/Script/OEIText.Default__OEITextLibrary")
    if ok and safeValid(obj) then cachedOEITextLib = obj; return obj end
    return nil
end

--- 获取 SlateBlueprintLibrary 静态默认对象。
local function getSlateLib()
    if safeValid(cachedSlateLib) then return cachedSlateLib end
    local ok, obj = pcall(StaticFindObject, "/Script/UMG.Default__SlateBlueprintLibrary")
    if ok and safeValid(obj) then cachedSlateLib = obj; return obj end
    return nil
end

--- 获取 WidgetLayoutLibrary 静态默认对象（用于读取当前游戏视口分辨率）。
local function getWidgetLayoutLib()
    if safeValid(cachedLayoutLib) then return cachedLayoutLib end
    local ok, obj = pcall(StaticFindObject, "/Script/UMG.Default__WidgetLayoutLibrary")
    if ok and safeValid(obj) then cachedLayoutLib = obj; return obj end
    return nil
end

--- 获取 SurvivalGameplayStatics 静态默认对象（用于资源扫描判定、玩家 GUID 查表等）。
local function getSurvivalStatics()
    if safeValid(cachedStatics) then return cachedStatics end
    local ok, obj = pcall(StaticFindObject, "/Script/Maine.Default__SurvivalGameplayStatics")
    if ok and safeValid(obj) then cachedStatics = obj; return obj end
    return nil
end

--- 将 Grounded 的 FLocString 转为当前语言（简体中文）字符串；缺失词条返回空串。
local function locStringToZh(locStr)
    if not locStr then return "" end
    local lib = getOEITextLib()
    if not lib then return "" end
    local ok, txt = pcall(function()
        local ft = lib:GetLocStringText(locStr)
        if ft then return ft:ToString() end
        return ""
    end)
    if ok and type(txt) == "string" and txt ~= "" and not txt:find("Missing String") then
        return txt
    end
    return ""
end

--- 清洗蓝图类名（剥离包路径前缀、BP_ 前缀与 _C 后缀），便于展示和模糊匹配。
local function cleanClassName(fullOrShort)
    if not fullOrShort or fullOrShort == "" then return "" end
    local s = fullOrShort
    local afterDot = s:match("%.([^%.]+)$")
    if afterDot then s = afterDot end
    s = s:gsub("_C$", ""):gsub("^BP_", ""):gsub("^Default__", "")
    return s
end

--- 将英文名称归一为纯小写字母数字串，用于与 DataTable RowName 做容错匹配。
local function normalizeKey(s)
    return (s or ""):lower():gsub("[^a-z0-9]", "")
end

--- 为尚未流式加载完整实体的远距采集点提供简体中文兜底名称。
local function fallbackNodeZh(actorClsShort)
    local low = (actorClsShort or ""):lower()
    for pat, zh in pairs(NODE_FALLBACK_ZH) do
        if low:find(pat, 1, true) then
            return zh .. " (" .. actorClsShort .. ")"
        end
    end
    local nk = normalizeKey(actorClsShort)
    if harvestTableByHint[nk] then
        return harvestTableByHint[nk]
    end
    return actorClsShort
end

-- ============================================================
-- 4. 功能一：物品堆叠上限倍率（GlobalItemData.StackSizes）
-- ============================================================

--- 按配置倍率原地调整 GlobalItemData 的各类物品堆叠上限。
-- 自动跳过基础堆叠 <= 1 的武器/防具/工具，避免耐久或强化词条异常合并。
local function getStackConfigKey()
    return tostring(cfg.stackEnabled == true) .. ":" .. tostring(cfg.stackMultiplier or 1)
end

local function getHarvestConfigKey()
    return tostring(cfg.harvestEnabled == true)
        .. ":" .. tostring(cfg.harvestMultiplier or 1)
        .. ":" .. tostring(cfg.harvestAffectHauling == true)
        .. ":" .. tostring(cfg.harvestAffectPickup == true)
end

local function applyStackSizeMultiplier()
    local gid = cachedGlobalItemData
    if not safeValid(gid) then
        local ok, found = pcall(FindFirstOf, "GlobalItemData")
        if ok and safeValid(found) then
            gid = found
            cachedGlobalItemData = found
        else
            return
        end
    end

    if origStackBonusPerTier == nil then
        pcall(function() origStackBonusPerTier = gid.ItemStackBonusPerTier end)
    end
    if origMaxDropStackSize == nil then
        pcall(function() origMaxDropStackSize = gid.MaxDropStackSize end)
    end

    local mult = (cfg.stackEnabled and cfg.stackMultiplier and cfg.stackMultiplier > 1) and cfg.stackMultiplier or 1
    local summaryParts = {}

    pcall(function()
        local idx = 0
        gid.StackSizes:ForEach(function(keyParam, valParam)
            idx = idx + 1
            local keyTag = "Tag_" .. tostring(idx)
            pcall(function()
                local k = keyParam:get()
                if k and k.TagName then
                    keyTag = k.TagName:ToString()
                end
            end)
            local curVal = valParam:get()
            if origStackSizes[keyTag] == nil then
                origStackSizes[keyTag] = curVal
            end
            local baseVal = origStackSizes[keyTag]
            -- 保护基础堆叠 <= 1 的武器、防具、工具，防止耐久或强化异常合并
            if baseVal and baseVal > 1 then
                local target = math.min(9999, math.max(baseVal, math.floor(baseVal * mult + 0.5)))
                if curVal ~= target then
                    valParam:set(target)
                end
                local shortTag = keyTag:match("([^%.]+)$") or keyTag
                table.insert(summaryParts, string.format("%s:%d->%d", shortTag, baseVal, target))
            end
        end)
    end)

    if origStackBonusPerTier and origStackBonusPerTier > 0 then
        pcall(function()
            gid.ItemStackBonusPerTier = math.min(500, math.max(origStackBonusPerTier, math.floor(origStackBonusPerTier * mult + 0.5)))
        end)
    end
    if origMaxDropStackSize and origMaxDropStackSize > 0 then
        pcall(function()
            gid.MaxDropStackSize = math.min(9999, math.max(origMaxDropStackSize, math.floor(origMaxDropStackSize * mult + 0.5)))
        end)
    end

    if #summaryParts > 0 then
        lastStackSummary = table.concat(summaryParts, " | ")
    end
end

-- ============================================================
-- 5. 功能二 & 功能五 & 死亡保护：原地覆写运行时 USurvivalGameModeSettings
-- ============================================================

--- 原地覆写运行时游戏模式设置（伤害倍率、无材料建造/制作、死亡背包保留与免除死亡耐久惩罚）。
-- 设计约束（见 ADR-0001）：只直接修改活跃 USurvivalGameModeSettings 字段并缓存原版基准值用于还原，
-- 绝不调用 SwapToCustom / SetGameMode / UpdateCustomSettings，从而保持原版生存模式、100% 不影响 Steam 成就。
-- @param isHost 当前端是否具备房主权威；死亡保护类设置仅在房主端写入，由主机自然同步给全队。
-- @param gsIn   调用方已缓存并校验有效的 SurvivalGameState，避免重复 FindFirstOf 扫描。
-- @return livePlayerDmg, liveEnemyDmg, diffName, liveKeepInv, liveNoDurPenalty
local function applyGameModeSettings(isHost, gsIn)
    local livePlayerDmg = 1.0
    local liveEnemyDmg = 1.0
    local diffName = "未知"
    local liveKeepInv = false
    local liveNoDurPenalty = false
    local appliedAny = false

    local function applyToSettings(gms)
        if not safeValid(gms) then return end
        local addr = gms:GetAddress()
        if not origDamageMap[addr] then
            local baseDeathBehavior = 0
            local baseDurPenalty = 0.1
            pcall(function() baseDeathBehavior = gms.DeathBehavior or 0 end)
            pcall(function() baseDurPenalty = gms.ItemDurabilityPenaltyOnDeathPercentage or 0.1 end)
            origDamageMap[addr] = {
                player = gms.PlayerDamageMultiplier or 1.0,
                enemy = gms.EnemyDamageMultiplier or 1.0,
                autoComplete = (gms.bAutoCompleteBuildings == true),
                requireIngredients = (gms.bRecipesRequireIngredients ~= false),
                unlockAll = (gms.bUnlockAllRecipes == true),
                deathBehavior = baseDeathBehavior,
                deathDurabilityPenalty = baseDurPenalty,
            }
        end
        local base = origDamageMap[addr]

        -- 1. 伤害倍率（以原版难度基准值按比例缩放，关闭时无损还原）
        local targetP = cfg.damageEnabled and (base.player * (cfg.playerDamageMultiplier or 1.0)) or base.player
        local targetE = cfg.damageEnabled and (base.enemy * (cfg.enemyDamageMultiplier or 1.0)) or base.enemy
        if math.abs((gms.PlayerDamageMultiplier or 1.0) - targetP) > 0.001 then
            gms.PlayerDamageMultiplier = targetP
        end
        if math.abs((gms.EnemyDamageMultiplier or 1.0) - targetE) > 0.001 then
            gms.EnemyDamageMultiplier = targetE
        end

        -- 2. 建筑建设无材料立刻建成 / 工作台与背包合成制作无需材料 / 可选解锁全部配方
        -- 注意：Lua 中 `cond and false or fallback` 会因 false 为假值而永远落回 fallback，必须显式用 if 分支赋值！
        local targetAutoBuild = base.autoComplete
        if cfg.instantBuildEnabled then
            targetAutoBuild = true
        end
        local targetReqIngr = base.requireIngredients
        if cfg.freeCraftEnabled then
            targetReqIngr = false
        end
        local targetUnlock = base.unlockAll
        if cfg.unlockAllRecipes then
            targetUnlock = true
        end

        if gms.bAutoCompleteBuildings ~= targetAutoBuild then
            gms.bAutoCompleteBuildings = targetAutoBuild
        end
        if gms.bRecipesRequireIngredients ~= targetReqIngr then
            gms.bRecipesRequireIngredients = targetReqIngr
        end
        if gms.bUnlockAllRecipes ~= targetUnlock then
            gms.bUnlockAllRecipes = targetUnlock
        end

        -- 3. 死亡背包保留与免除死亡装备耐久惩罚（仅房主权威端写入，关闭即精准还原原版难度设置）
        -- EPlayerDeathBehavior 枚举：0=DropItemsOnDeath（原版掉落）, 1=KeepItemsOnDeath（保留全部物品）
        if isHost then
            local targetDeathBehavior = cfg.keepInventoryOnDeath and 1 or base.deathBehavior
            local targetDurPenalty = cfg.noDeathDurabilityPenalty and 0.0 or base.deathDurabilityPenalty
            pcall(function()
                if gms.DeathBehavior ~= targetDeathBehavior then
                    gms.DeathBehavior = targetDeathBehavior
                end
            end)
            pcall(function()
                local curPen = gms.ItemDurabilityPenaltyOnDeathPercentage or 0.0
                if math.abs(curPen - targetDurPenalty) > 0.0001 then
                    gms.ItemDurabilityPenaltyOnDeathPercentage = targetDurPenalty
                end
            end)
        end

        livePlayerDmg = gms.PlayerDamageMultiplier
        liveEnemyDmg = gms.EnemyDamageMultiplier
        pcall(function() liveKeepInv = (gms.DeathBehavior == 1) end)
        pcall(function() liveNoDurPenalty = ((gms.ItemDurabilityPenaltyOnDeathPercentage or 0.0) <= 0.0001) end)
        appliedAny = true

        local d = gms.GameDifficulty
        if d == 0 then diffName = "简易 (Mild)"
        elseif d == 1 then diffName = "中等 (Medium)"
        elseif d == 2 then diffName = "哇哦! (Woah!)"
        else diffName = "自定义" end
    end

    -- 优先通过当前 SurvivalGameState 的模式管理器获取正在生效的设置实例（复用调用方缓存对象，零 GObjects 扫描）
    local gs = gsIn
    if not safeValid(gs) then
        local okGs, foundGs = pcall(FindFirstOf, "SurvivalGameState")
        if okGs and safeValid(foundGs) then gs = foundGs end
    end
    if safeValid(gs) then
        pcall(function()
            local sm = gs.SurvivalModeManagerComponent
            if safeValid(sm) and safeValid(sm.GameModeSettings) then
                applyToSettings(sm.GameModeSettings)
            end
        end)
    end

    -- 兜底遍历所有非 CDO 的 USurvivalGameModeSettings 实例（兼容极少数加载过渡帧）
    if not appliedAny then
        local okAll, list = pcall(FindAllOf, "SurvivalGameModeSettings")
        if okAll and list then
            for _, gms in ipairs(list) do
                local fn = safeValid(gms) and gms:GetFullName() or ""
                if not fn:find("Default__") then
                    applyToSettings(gms)
                end
            end
        end
    end

    return livePlayerDmg, liveEnemyDmg, diffName, liveKeepInv, liveNoDurPenalty
end

-- ============================================================
-- 6. 功能三：采集入包倍率与搬运物瞬时缩放（ADR-0005：零模板修改 + 四重防刷拦截）
-- ============================================================

--- 判断对象名是否属于蓝图 CDO、SCS 组件模板或骨架类（严禁对模板对象写入任何掉落数量）。
local function isTemplateOrCdoName(fullName)
    if not fullName or fullName == "" then return false end
    return fullName:find("Default__", 1, true) ~= nil
        or fullName:find("_GEN_VARIABLE", 1, true) ~= nil
        or fullName:find("SKEL_", 1, true) ~= nil
        or fullName:find("REINST_", 1, true) ~= nil
end

--- 判断掉落组件所属对象是否需要排除（玩家死亡背包、乳牙、宝箱、储物箱与玩家自身）。
local function shouldSkipLootOwner(ownerFullName)
    if not ownerFullName or ownerFullName == "" then return false end
    local low = ownerFullName:lower()
    return low:find("lootbag") ~= nil
        or low:find("backpack") ~= nil
        or low:find("milk_nugget") ~= nil
        or low:find("upgradecollectible") ~= nil
        or low:find("storage") ~= nil
        or low:find("survivalplayercharacter") ~= nil
        or low:find("chest") ~= nil
end

--- 判断一个 UObject 的类或名称是否属于储物箱/背包/建筑/工作台等非拾取容器。
local function isContainerOrBuildingObject(obj)
    if not safeValid(obj) then return false end
    if isAOf(obj, "/Script/Maine.Building", "Building")
        or isAOf(obj, "/Script/Maine.LootBag", "LootBag") then
        return true
    end
    local clsName = ""
    local fullName = ""
    pcall(function() clsName = obj:GetClass():GetFName():ToString():lower() end)
    pcall(function() fullName = obj:GetFullName():lower() end)
    return clsName:find("lootbag") ~= nil
        or clsName:find("storage") ~= nil
        or clsName:find("chest") ~= nil
        or clsName:find("building") ~= nil
        or fullName:find("lootbag") ~= nil
        or fullName:find("backpack") ~= nil
        or fullName:find("storage") ~= nil
        or fullName:find("chest") ~= nil
end

--- 判断一个 UObject 是否为玩家角色（ASurvivalPlayerCharacter）。
local function isSurvivalPlayerObject(obj)
    if not safeValid(obj) then return false end
    if isAOf(obj, "/Script/Maine.SurvivalPlayerCharacter", "SurvivalPlayerCharacter") then
        return true
    end
    local cname = ""
    pcall(function() cname = obj:GetClass():GetFName():ToString():lower() end)
    return cname:find("survivalplayercharacter") ~= nil or cname:find("player_male") ~= nil or cname:find("player_female") ~= nil
end

--- 安全解包 UE4SS 返回的 TScriptInterface<IInteractableInterface> 为实际 UObject。
local function unwrapInteractable(val)
    if not val then return nil end
    if safeValid(val) then return val end
    local inner = nil
    pcall(function()
        if val.ObjectPointer and safeValid(val.ObjectPointer) then
            inner = val.ObjectPointer
        elseif val.GetObject then
            local o = val:GetObject()
            if safeValid(o) then inner = o end
        end
    end)
    return inner
end

--- 判断 FFoliageKey 是否指向一个有效的世界植被实例（ISM），兼容 UE4SS FWeakObjectPtr 解包。
local function hasValidFoliageKey(fk)
    if not fk then return false end
    local valid = false
    pcall(function()
        local ism = unwrapWeakObject(fk.InstancedStaticMeshComponent)
        local idx = fk.MeshIndex
        if safeValid(ism) and (idx == nil or idx >= 0) then
            valid = true
        end
    end)
    return valid
end

--- 向防刷黑名单登记被玩家丢弃、投掷或拆建返还的 UItem 与空间事件（有界裁剪防内存增长）。
local function recordExcludedDrop(itemObj, rowNameHint, actorForPos, countHint, radiusOverride)
    if safeValid(itemObj) then
        pcall(function()
            excludedItemObjAddrs[itemObj:GetAddress()] = true
        end)
        if (not rowNameHint or rowNameHint == "" or rowNameHint == "None") then
            pcall(function() rowNameHint = itemObj.ItemDataRowHandle.RowName:ToString() end)
        end
    end

    local px, py, pz = nil, nil, nil
    if safeValid(actorForPos) then
        pcall(function()
            local loc = actorForPos:K2_GetActorLocation()
            if loc then px, py, pz = loc.X or 0, loc.Y or 0, loc.Z or 0 end
        end)
    end
    if px ~= nil then
        local rn = (rowNameHint and rowNameHint ~= "None") and rowNameHint or ""
        table.insert(recentExcludedDropEvents, {
            rowName = rn,
            x = px, y = py, z = pz,
            radius = radiusOverride or 450.0,
            remaining = math.max(1, tonumber(countHint) or 1),
            clock = os.clock(),
        })
        if #recentExcludedDropEvents > 128 then
            table.remove(recentExcludedDropEvents, 1)
        end
    end
end

--- 检查指定地面物品是否命中近期玩家丢弃/拆建返还的空间事件；命中则扣减配额并返回 true（强制 1 倍）。
local function consumeMatchingExcludedDropEvent(rowName, itemActor)
    if #recentExcludedDropEvents == 0 or not safeValid(itemActor) then return false end
    local loc = nil
    pcall(function() loc = itemActor:K2_GetActorLocation() end)
    if not loc then return false end
    local ix, iy, iz = loc.X or 0, loc.Y or 0, loc.Z or 0
    local now = os.clock()

    local matchedIdx = nil
    for i = #recentExcludedDropEvents, 1, -1 do
        local ev = recentExcludedDropEvents[i]
        local maxAge = (ev.rowName ~= "") and 180.0 or 15.0
        if (now - ev.clock) > maxAge or ev.remaining <= 0 then
            table.remove(recentExcludedDropEvents, i)
        else
            local rowOk = (ev.rowName == "" or ev.rowName == rowName)
            if rowOk then
                local dx = ix - ev.x
                local dy = iy - ev.y
                local dz = iz - ev.z
                local r = ev.radius or 450.0
                if (dx * dx + dy * dy + dz * dz) <= (r * r) then
                    matchedIdx = i
                    break
                end
            end
        end
    end

    if matchedIdx then
        local ev = recentExcludedDropEvents[matchedIdx]
        ev.remaining = ev.remaining - 1
        if ev.remaining <= 0 then
            table.remove(recentExcludedDropEvents, matchedIdx)
        end
        return true
    end
    return false
end

--- 搬运物（草板/杂草茎）瞬时缩放 Pre-Hook 共用实现：
-- 覆盖 ULootComponent:OnDeath / OnDamaged / SpawnLoot 三大入口，使用每对象嵌套深度防止重复缩放，
-- 按 ELootSpawnType 精确过滤对应阶段条目（避免未砍倒时的 OnDamaged 空计次），并在最外层 Post-Hook 立刻还原原版 Count（ADR-0005）。
local function scaleHaulingLootPre(selfParam, expectedSpawnType, skipThisCall)
    pcall(function()
        local lc = selfParam:get()
        if not safeValid(lc) then return end
        local addr = lc:GetAddress()
        local depth = (spawnLootActiveDepth[addr] or 0) + 1
        spawnLootActiveDepth[addr] = depth
        if depth > 1 or skipThisCall then
            -- 已被外层 OnDeath/OnDamaged 缩放过，或本次调用不产生物品（如 OnDamaged IsKillingBlow=true），跳过
            return
        end

        if not (cfg.harvestEnabled and cfg.harvestAffectHauling and cfg.harvestMultiplier and cfg.harvestMultiplier > 1) then
            return
        end
        local lcName = ""
        pcall(function() lcName = lc:GetFullName() end)
        if isTemplateOrCdoName(lcName) then return end

        local ownerName = ""
        pcall(function()
            local outer = lc:GetOuter()
            if safeValid(outer) then ownerName = outer:GetFullName() end
        end)
        if isTemplateOrCdoName(ownerName) or shouldSkipLootOwner(ownerName) then return end

        local items = nil
        pcall(function() items = lc.Items end)
        if not items then return end
        local len = 0
        pcall(function() len = #items end)
        if len <= 0 then return end

        local mult = cfg.harvestMultiplier
        local haulingEntries = {}
        local totalOrig = 0
        for i = 1, len do
            pcall(function()
                local entry = items[i]
                -- 仅统计 ELootType::Item (0) 且符合当前触发阶段（SpawnType）的肩扛搬运物条目，其余普通物品保持原版 1 倍爆出
                if entry and entry.Type == 0 then
                    local st = entry.SpawnType
                    if expectedSpawnType == nil or st == nil or st == expectedSpawnType then
                        local baseCnt = entry.Count or 0
                        if baseCnt > 0 then
                            local rowName = ""
                            pcall(function() rowName = entry.ItemData.RowName:ToString() end)
                            if isHaulingRowName(rowName) then
                                totalOrig = totalOrig + baseCnt
                                table.insert(haulingEntries, { idx = i, entry = entry, orig = baseCnt, rowName = rowName })
                            end
                        end
                    end
                end
            end)
        end

        -- 按「单株倍率放大上限 12 根，且不削减原版固有数量」分配总预算（而非每条各自封顶 12），
        -- 当原版单株 totalOrig < 12 时最高放大至 12；若原版单株本身已 >= 12 则保持原版数量不削减。
        local saved = nil
        if totalOrig > 0 and #haulingEntries > 0 then
            local plantTarget = math.max(totalOrig, math.min(12, math.floor(totalOrig * mult + 0.5)))
            local extraBudget = plantTarget - totalOrig
            if extraBudget > 0 then
                local allocs = {}
                local usedExtra = 0
                for k, rec in ipairs(haulingEntries) do
                    local wantExtra = math.max(0, math.floor(rec.orig * mult + 0.5) - rec.orig)
                    local share = math.min(wantExtra, math.floor(extraBudget * rec.orig / totalOrig))
                    allocs[k] = { extra = share, want = wantExtra }
                    usedExtra = usedExtra + share
                end
                -- 分配按比例取整后的剩余余数，确保整株总量严格贴合 plantTarget（<= 12）
                local rem = extraBudget - usedExtra
                for k = 1, #haulingEntries do
                    if rem <= 0 then break end
                    local a = allocs[k]
                    local room = a.want - a.extra
                    if room > 0 then
                        local give = math.min(rem, room)
                        a.extra = a.extra + give
                        rem = rem - give
                    end
                end
                for k, rec in ipairs(haulingEntries) do
                    local extra = allocs[k].extra
                    if extra > 0 then
                        if not saved then saved = {} end
                        table.insert(saved, { idx = rec.idx, orig = rec.orig })
                        rec.entry.Count = rec.orig + extra
                    end
                end
            end
        end

        if saved then
            spawnLootRestoreMap[addr] = saved
            harvestBoostHits = harvestBoostHits + 1
            if harvestBoostHits <= 15 then
                logInfo(string.format("搬运倍率生效(#%d): %s 原始=%d -> 放大后=%d (%dx)",
                    harvestBoostHits, haulingEntries[1].rowName or "Hauling", totalOrig, math.max(totalOrig, math.min(12, math.floor(totalOrig * mult + 0.5))), mult))
            end
        end
    end)
end

--- 搬运物瞬时缩放 Post-Hook 共用实现：在最外层调用退出时立即还原原版 Count。
local function restoreHaulingLootPost(selfParam)
    pcall(function()
        local lc = selfParam:get()
        if not safeValid(lc) then return end
        local addr = lc:GetAddress()
        local depth = (spawnLootActiveDepth[addr] or 1) - 1
        if depth > 0 then
            spawnLootActiveDepth[addr] = depth
            return
        end
        spawnLootActiveDepth[addr] = nil

        local saved = spawnLootRestoreMap[addr]
        spawnLootRestoreMap[addr] = nil
        if not saved then return end

        local items = nil
        pcall(function() items = lc.Items end)
        if not items then return end
        for _, rec in ipairs(saved) do
            pcall(function()
                local entry = items[rec.idx]
                if entry then
                    entry.Count = rec.orig
                end
            end)
        end
    end)
end

pcall(function()
    RegisterHook("/Script/Maine.LootComponent:SpawnLoot", function(selfParam, _looterParam, spawnTypeParam)
        local st = nil
        pcall(function() if spawnTypeParam then st = spawnTypeParam:get() end end)
        scaleHaulingLootPre(selfParam, st, false)
    end, restoreHaulingLootPost)
end)

pcall(function()
    RegisterHook("/Script/Maine.LootComponent:OnDeath", function(selfParam)
        -- ELootSpawnType::SpawnOnDeath == 2
        scaleHaulingLootPre(selfParam, 2, false)
    end, restoreHaulingLootPost)
end)

pcall(function()
    RegisterHook("/Script/Maine.LootComponent:OnDamaged", function(selfParam, _dmgParam, _infoParam, _instParam, _causerParam, isKillingBlowParam)
        local isKill = false
        pcall(function()
            if isKillingBlowParam then
                local v = isKillingBlowParam:get()
                isKill = (v == true or v == 1)
            end
        end)
        -- ELootSpawnType::SpawnOnHit == 1；致命一击由紧随其后的 OnDeath 统一掉落，此处跳过
        scaleHaulingLootPre(selfParam, 1, isKill)
    end, restoreHaulingLootPost)
end)

-- 防刷拦截钩子组 A：实时登记玩家丢弃、快捷丢弃、投掷、脱手以及拆毁建筑/取消蓝图返还的地面物品（始终保持 1 倍）。
pcall(function()
    RegisterHook("/Script/Maine.InventoryComponent:ServerDropItem", function(selfParam, itemParam, countParam)
        inExcludedDropDepth = inExcludedDropDepth + 1
        pcall(function()
            local inv = selfParam:get()
            local owner = safeValid(inv) and inv:GetOuter() or nil
            local it = itemParam and itemParam:get() or nil
            local cnt = countParam and countParam:get() or 1
            recordExcludedDrop(it, "", owner, cnt, 400.0)
        end)
    end, function()
        inExcludedDropDepth = math.max(0, inExcludedDropDepth - 1)
    end)
end)

pcall(function()
    RegisterHook("/Script/Maine.EquipmentComponent:ServerDropItem", function(selfParam, itemParam, countParam)
        inExcludedDropDepth = inExcludedDropDepth + 1
        pcall(function()
            local eq = selfParam:get()
            local owner = safeValid(eq) and eq:GetOuter() or nil
            local it = itemParam and itemParam:get() or nil
            local cnt = countParam and countParam:get() or 1
            recordExcludedDrop(it, "", owner, cnt, 400.0)
        end)
    end, function()
        inExcludedDropDepth = math.max(0, inExcludedDropDepth - 1)
    end)
end)

pcall(function()
    RegisterHook("/Script/Maine.EquipmentComponent:ServerDumpItem", function(selfParam, itemParam)
        inExcludedDropDepth = inExcludedDropDepth + 1
        pcall(function()
            local eq = selfParam:get()
            local owner = safeValid(eq) and eq:GetOuter() or nil
            local it = itemParam and itemParam:get() or nil
            recordExcludedDrop(it, "", owner, 1, 400.0)
        end)
    end, function()
        inExcludedDropDepth = math.max(0, inExcludedDropDepth - 1)
    end)
end)

pcall(function()
    RegisterHook("/Script/Maine.SurvivalPlayerCharacter:ServerHotDrop", function(selfParam, itemParam)
        inExcludedDropDepth = inExcludedDropDepth + 1
        pcall(function()
            local player = selfParam:get()
            local it = itemParam and itemParam:get() or nil
            recordExcludedDrop(it, "", player, 1, 400.0)
        end)
    end, function()
        inExcludedDropDepth = math.max(0, inExcludedDropDepth - 1)
    end)
end)

pcall(function()
    RegisterHook("/Script/Maine.SurvivalPlayerCharacter:ServerHandleDrop", function(selfParam, objParam)
        inExcludedDropDepth = inExcludedDropDepth + 1
        pcall(function()
            local player = selfParam:get()
            local obj = objParam and objParam:get() or nil
            local it = nil
            local rn = ""
            if safeValid(obj) then
                excludedSpawnedActorAddrs[obj:GetAddress()] = true
                pcall(function()
                    if obj.GetItem then it = obj:GetItem() end
                end)
                if not safeValid(it) then
                    pcall(function()
                        if obj.ItemDataRowHandle and obj.ItemDataRowHandle.RowName then
                            it = obj
                        end
                    end)
                end
                if safeValid(it) then
                    pcall(function() rn = it.ItemDataRowHandle.RowName:ToString() end)
                end
            end
            -- 仅在能明确物品 RowName 时写入空间兜底事件，避免通配符 "" 误伤附近击杀昆虫爆出的材料
            if safeValid(it) or (rn ~= "" and rn ~= "None") then
                recordExcludedDrop(it, rn, player, 1, 400.0)
            end
        end)
    end, function()
        inExcludedDropDepth = math.max(0, inExcludedDropDepth - 1)
    end)
end)

pcall(function()
    RegisterHook("/Script/Maine.SurvivalPlayerCharacter:ServerReleaseThrow", function(selfParam)
        inExcludedDropDepth = inExcludedDropDepth + 1
        pcall(function()
            local player = selfParam:get()
            local weapon = nil
            local wRow = ""
            if safeValid(player) then
                pcall(function()
                    local eq = player.EquipmentComponent
                    if safeValid(eq) then
                        if eq.GetWeapon then weapon = eq:GetWeapon()
                        elseif eq.GetItemInSlot then weapon = eq:GetItemInSlot(1) end
                        if safeValid(weapon) then
                            pcall(function() wRow = weapon.ItemDataRowHandle.RowName:ToString() end)
                        end
                    end
                end)
            end
            -- 只登记实际被投掷武器的精确 RowName（严禁写通配符 ""，否则投掷长矛/石子击杀昆虫后 15 秒 6 米内的虫材料会被误拦！）
            if safeValid(weapon) or (wRow ~= "" and wRow ~= "None") then
                recordExcludedDrop(weapon, wRow, player, 1, 600.0)
            end
        end)
    end, function()
        inExcludedDropDepth = math.max(0, inExcludedDropDepth - 1)
    end)
end)

pcall(function()
    RegisterHook("/Script/Maine.HaulingComponent:ServerDropItem", function()
        inExcludedDropDepth = inExcludedDropDepth + 1
    end, function()
        inExcludedDropDepth = math.max(0, inExcludedDropDepth - 1)
    end)
end)

pcall(function()
    RegisterHook("/Script/Maine.HaulingComponent:ServerDropAll", function()
        inExcludedDropDepth = inExcludedDropDepth + 1
    end, function()
        inExcludedDropDepth = math.max(0, inExcludedDropDepth - 1)
    end)
end)

pcall(function()
    RegisterHook("/Script/Maine.Building:DropItem", function(selfParam, itemParam)
        inExcludedDropDepth = inExcludedDropDepth + 1
        pcall(function()
            local bld = selfParam:get()
            local it = itemParam and itemParam:get() or nil
            recordExcludedDrop(it, "", bld, 4, 550.0)
        end)
    end, function()
        inExcludedDropDepth = math.max(0, inExcludedDropDepth - 1)
    end)
end)

pcall(function()
    RegisterHook("/Script/Maine.Building:DropNewItem", function(selfParam, rowParam)
        inExcludedDropDepth = inExcludedDropDepth + 1
        pcall(function()
            local bld = selfParam:get()
            local rn = ""
            pcall(function()
                local h = rowParam and rowParam:get() or nil
                if h and h.RowName then rn = h.RowName:ToString() end
            end)
            recordExcludedDrop(nil, rn, bld, 4, 550.0)
        end)
    end, function()
        inExcludedDropDepth = math.max(0, inExcludedDropDepth - 1)
    end)
end)

-- 注意：Building:BlueprintDropItems 是蓝图脚本函数（UE4SS 注册为 script hook (N, N)），
-- 绝不可传第二个 Post-Hook 回调（否则 UE4SS 既不会触发 Post 导致 inExcludedDropDepth 永久泄漏拉黑全图掉落，
-- 还会反复报 Lua::Registry::get_function_ref / attempt to call a RemoteUnrealParam value 错误）！
pcall(function()
    RegisterHook("/Script/Maine.Building:BlueprintDropItems", function(selfParam)
        pcall(function()
            recordExcludedDrop(nil, "", selfParam:get(), 16, 600.0)
        end)
    end)
end)

pcall(function()
    RegisterHook("/Script/Maine.Building:CancelBuild", function(selfParam)
        inExcludedDropDepth = inExcludedDropDepth + 1
        pcall(function()
            recordExcludedDrop(nil, "", selfParam:get(), 16, 600.0)
        end)
    end, function()
        inExcludedDropDepth = math.max(0, inExcludedDropDepth - 1)
    end)
end)

pcall(function()
    RegisterHook("/Script/Maine.SpawnedItem:NotifySpawned", function(selfParam)
        if inExcludedDropDepth <= 0 then return end
        pcall(function()
            local actor = selfParam:get()
            if safeValid(actor) then
                excludedSpawnedActorAddrs[actor:GetAddress()] = true
                local it = nil
                pcall(function() it = actor:GetItem() end)
                if safeValid(it) then
                    excludedItemObjAddrs[it:GetAddress()] = true
                end
            end
        end)
    end)
end)

-- 精准标记天然植被直拾（ISM -> ASpawnedItem，bFromDamage == false），与砍伐/破坏爆出（bFromDamage == true）彻底区分
pcall(function()
    RegisterHook("/Script/Maine.SpawnedItem:NotifySwapped", function(selfParam, _fromKeyParam, fromDamageParam)
        pcall(function()
            local fromDmg = false
            if fromDamageParam then
                local v = fromDamageParam:get()
                fromDmg = (v == true or v == 1)
            end
            if not fromDmg then
                local actor = selfParam:get()
                if safeValid(actor) then
                    foliagePickupActorAddrs[actor:GetAddress()] = true
                    local it = nil
                    pcall(function() it = actor:GetItem() end)
                    if safeValid(it) then
                        foliagePickupItemAddrs[it:GetAddress()] = true
                    end
                end
            end
        end)
    end)
end)

-- 防刷拦截钩子组 B：容器转移、堆叠合并、物品制作、卸下装备与内部创建 RPC 期间严格保持 1 倍，绝不误倍增。
-- 关键注意：严禁把 /Script/Maine.InventoryComponent:ServerAddItem 加入此处！
-- 经实机二进制验证，ASurvivalPlayerCharacter::TryPickupItem 常规拾取路径调用的就是 ServerAddItem(Item, true) -> 尾调用 AddItem(Item, true)，
-- 其余 14 处 ServerAddItem 调用方要么传 bIsNewItem=false，要么已被下方 ServerTransfer*/ServerSwap* 拦截。
local function hookNonHarvestDepth(funcPath)
    pcall(function()
        RegisterHook(funcPath, function()
            inNonHarvestAddDepth = inNonHarvestAddDepth + 1
        end, function()
            inNonHarvestAddDepth = math.max(0, inNonHarvestAddDepth - 1)
        end)
    end)
end

for _, nonHarvestRpc in ipairs({
    "/Script/Maine.InventoryComponent:ServerTransferItemTo",
    "/Script/Maine.InventoryComponent:ServerTransferItemFrom",
    "/Script/Maine.InventoryComponent:ServerTransferAllTo",
    "/Script/Maine.InventoryComponent:ServerTransferAllFrom",
    "/Script/Maine.InventoryComponent:ServerSwapItemSlots",
    "/Script/Maine.InventoryComponent:ServerSwapItemSlotsBetweenInventories",
    "/Script/Maine.InventoryComponent:ServerMergeItemStacks",
    "/Script/Maine.InventoryComponent:ServerCraftRecipe",
    "/Script/Maine.InventoryComponent:ServerCraftRecipeForInventory",
    "/Script/Maine.InventoryComponent:ServerCraftRecipeDataForInventory",
    "/Script/Maine.InventoryComponent:ServerCreateAndAddItem",
    "/Script/Maine.SurvivalPlayerController:ServerCraftRecipeAtBuilding",
    "/Script/Maine.SurvivalPlayerController:ServerCraftRecipeDataAtBuilding",
    "/Script/Maine.EquipmentComponent:ServerUnequipItem",
    "/Script/Maine.EquipmentComponent:ServerUnequipItemSlot",
}) do
    hookNonHarvestDepth(nonHarvestRpc)
end

--- 统计背包内指定 RowName 的当前总堆叠数量（单物品 O(N) 轻量计数）。
local function countRowInInventory(invComp, targetRowName)
    local total = 0
    if not safeValid(invComp) or not targetRowName or targetRowName == "" then return 0 end
    pcall(function()
        local items = invComp.Items
        if not items then return end
        for i = 1, #items do
            local it = items[i]
            if safeValid(it) then
                local rn = ""
                pcall(function() rn = it.ItemDataRowHandle.RowName:ToString() end)
                if rn == targetRowName then
                    total = total + (it.StackSize or 1)
                end
            end
        end
    end)
    return total
end

--- 判定对象是否为地面 ASpawnedItem 实例。
local function isSpawnedItemObject(obj)
    if not safeValid(obj) then return false end
    if isAOf(obj, "/Script/Maine.SpawnedItem", "SpawnedItem") then
        return true
    end
    local cname = ""
    pcall(function() cname = obj:GetClass():GetFName():ToString() end)
    return cname == "SpawnedItem" or cname:find("WorldItem", 1, true) ~= nil
end

--- 安全获取组件所属玩家角色（优先 GetOwner，兜底 GetOuter）。
local function getComponentOwnerPlayer(comp)
    if not safeValid(comp) then return nil end
    local owner = nil
    pcall(function() if comp.GetOwner then owner = comp:GetOwner() end end)
    if not safeValid(owner) then
        pcall(function() owner = comp:GetOuter() end)
    end
    if isSurvivalPlayerObject(owner) then
        return owner
    end
    return nil
end

--- 判断 ASpawnedItem.DroppedByActor / GetDroppedBySpawnedActor 是否来自玩家或建筑/容器（用于防刷拦截）。
-- 关键二进制实证：野生昆虫（ASurvivalCreature）与采集点（AHarvestNode）通过 ULootComponent 掉落地面材料时，
-- 引擎也会把 ASpawnedItem.DroppedByActor 设为死亡昆虫的 LODActor！因此严禁见非空就一刀切拦截，
-- 只拦截「玩家角色」与「建筑/储物箱/战利品袋」丢出的物品，放行昆虫与野生采集点掉落物。
local function isExcludedDropperObject(obj)
    if not safeValid(obj) then return false end
    if isSurvivalPlayerObject(obj) or isContainerOrBuildingObject(obj) then
        return true
    end
    -- 若为 UBaseLODActor（例如 UCharacterLODActor / UBuildingLODActor），解包 FullActor 与硬/软类名二次核验
    local fullActor = nil
    pcall(function() fullActor = obj.FullActor end)
    if not safeValid(fullActor) then
        pcall(function() if obj.K2_GetFullActor then fullActor = obj:K2_GetFullActor() end end)
    end
    if safeValid(fullActor) then
        if isSurvivalPlayerObject(fullActor) or isContainerOrBuildingObject(fullActor) then
            return true
        end
        if isAOf(fullActor, "/Script/Maine.SurvivalCreature", "SurvivalCreature")
            or isAOf(fullActor, "/Script/Maine.HarvestNode", "HarvestNode") then
            return false
        end
    end
    local clsHint = ""
    pcall(function()
        if obj.GetActorClassHard then
            local hc = obj:GetActorClassHard()
            if safeValid(hc) then clsHint = hc:GetFName():ToString():lower() end
        end
    end)
    if clsHint == "" then
        pcall(function()
            if obj.GetActorClassSoft then
                clsHint = ueStringToLua(obj:GetActorClassSoft()):lower()
            end
        end)
    end
    if clsHint ~= "" then
        if clsHint:find("survivalplayer", 1, true) ~= nil
            or clsHint:find("player_male", 1, true) ~= nil
            or clsHint:find("player_female", 1, true) ~= nil
            or clsHint:find("building", 1, true) ~= nil
            or clsHint:find("lootbag", 1, true) ~= nil
            or clsHint:find("storage", 1, true) ~= nil
            or clsHint:find("chest", 1, true) ~= nil
            or clsHint:find("backpack", 1, true) ~= nil then
            return true
        end
    end
    return false
end

--- 检查指定地面 ASpawnedItem 是否命中玩家丢弃/投掷/箭矢/玩家放置防刷规则，并返回 (blocked, preplaced, actorAddr)。
local function inspectSpawnedActorFlags(spawnedActor)
    if not safeValid(spawnedActor) then return false, 0, nil end
    local spawnedAddr = spawnedActor:GetAddress()
    if excludedSpawnedActorAddrs[spawnedAddr] then
        return true, 0, spawnedAddr
    end
    local blocked = false
    local preplaced = 0
    pcall(function()
        local droppedBy = nil
        local droppedBySpawned = nil
        local attackOwner = nil
        pcall(function() droppedBy = spawnedActor:GetDroppedBy() end)
        pcall(function() droppedBySpawned = spawnedActor:GetDroppedBySpawnedActor() end)
        pcall(function() attackOwner = spawnedActor.AttackOwner end)
        if isExcludedDropperObject(droppedBy) or isExcludedDropperObject(droppedBySpawned) or safeValid(attackOwner) then
            blocked = true
            return
        end
        if spawnedActor.bWasThrown == true or spawnedActor.bWasThrown == 1
            or spawnedActor.bIsThrown == true or spawnedActor.bIsThrown == 1 then
            blocked = true
            return
        end
        pcall(function() preplaced = spawnedActor.PreplacedType or 0 end)
        if preplaced == 0 then
            pcall(function()
                if spawnedActor.GetPreplacedType then preplaced = spawnedActor:GetPreplacedType() or 0 end
            end)
        end
        if preplaced == 1 then
            -- EPreplacedType::PreplacedUser (1)：玩家手动放置物一律 1 倍
            blocked = true
        end
    end)
    return blocked, preplaced, spawnedAddr
end

--- 从地面 ASpawnedItem 抓取交互前快照（供 TryPickupItem 自动叠加装备分支在实体被销毁前溯源防刷与原始数量）。
local function snapshotSpawnedTarget(targetObj)
    local snap = {
        rowName = "",
        stackSize = 1,
        blocked = false,
        isNatural = false,
        actorAddr = nil,
        itemAddr = nil,
    }
    if not (safeValid(targetObj) and isSpawnedItemObject(targetObj)) then
        return snap
    end
    local blocked, preplaced, actorAddr = inspectSpawnedActorFlags(targetObj)
    snap.blocked = blocked
    snap.actorAddr = actorAddr
    snap.isNatural = (preplaced == 2 or preplaced == 3)
        or (actorAddr ~= nil and foliagePickupActorAddrs[actorAddr] == true)
    pcall(function()
        local it = targetObj:GetItem()
        if safeValid(it) then
            local ia = it:GetAddress()
            snap.itemAddr = ia
            if excludedItemObjAddrs[ia] then
                snap.blocked = true
            end
            if foliagePickupItemAddrs[ia] then
                snap.isNatural = true
            end
            local rn = ""
            pcall(function() rn = it.ItemDataRowHandle.RowName:ToString() end)
            snap.rowName = rn or ""
            snap.stackSize = math.max(1, tonumber(it.StackSize) or 1)
        end
    end)
    return snap
end

--- 读取玩家当前主手装备的 UItem、RowName 与当前堆叠数（用于 TryPickupItem 分支 2 叠加到主手鹅卵石/箭矢时的倍增与客机兜底）。
local function readEquippedMainWeapon(player)
    if not safeValid(player) then return nil, "", 0 end
    local weapon, rn, sz = nil, "", 0
    pcall(function()
        local eq = player.EquipmentComponent
        if not safeValid(eq) then return end
        if eq.GetWeapon then
            weapon = eq:GetWeapon()
        elseif eq.GetItemInSlot then
            weapon = eq:GetItemInSlot(1)
        end
        if safeValid(weapon) then
            pcall(function() rn = weapon.ItemDataRowHandle.RowName:ToString() end)
            sz = tonumber(weapon.StackSize) or 1
        end
    end)
    return weapon, rn or "", sz
end

--- 判定不可堆叠物品是否属于可倍增的「易腐昆虫生肉/食材」（CanSpoil=true 且不可装备、无耐久、非搬运物）。
-- 武器/防具/工具/饰品/火把等单件装备一律返回 false，严禁复制。
local function isPerishableNonEquipMaterial(item, rowName)
    if not safeValid(item) or isHaulingRowName(rowName) then return false end
    local canSpoil = false
    pcall(function()
        if item.CanSpoil then
            local v = item:CanSpoil()
            canSpoil = (v == true or v == 1)
        end
    end)
    if not canSpoil then
        pcall(function()
            if item.GetTotalSpoilTime and (tonumber(item:GetTotalSpoilTime()) or 0) > 0 then
                canSpoil = true
            end
        end)
    end
    if not canSpoil then return false end

    local canEquip = false
    pcall(function()
        if item.CanEquip then
            local v = item:CanEquip()
            canEquip = (v == true or v == 1)
        end
    end)
    if canEquip then return false end

    local eqSlot = 0
    pcall(function()
        if item.GetEquipmentSlot then eqSlot = tonumber(item:GetEquipmentSlot()) or 0 end
    end)
    if eqSlot ~= 0 then return false end

    local hasDur = false
    pcall(function()
        if item.HasDurability then
            local v = item:HasDurability()
            hasDur = (v == true or v == 1)
        end
    end)
    if hasDur then return false end

    local isHaul = false
    pcall(function()
        if item.IsAHaulingItem then
            local v = item:IsAHaulingItem()
            isHaul = (v == true or v == 1)
        end
    end)
    return not isHaul
end

--- 计算背包对指定 RowName 当前可额外容纳的总数量（已有未满堆叠余量 + 空槽 * maxStack），确保 Pre-Hook 加倍绝不撑爆背包槽数。
local function computeInventoryAvailableSpace(inv, rowName, maxStack, canStack)
    if not safeValid(inv) or not rowName or rowName == "" then return 0, 0 end
    local allowAdd = true
    pcall(function()
        if inv.bAllowAddItems == false or inv.bAllowAddItems == 0 then
            allowAdd = false
        end
    end)
    if not allowAdd then return 0, 0 end

    local emptySlots = 0
    local okEmp, emp = pcall(function() return inv:GetEmptySlots() end)
    if okEmp and type(emp) == "number" then
        emptySlots = math.max(0, emp)
    else
        pcall(function()
            local maxSz = inv.MaxSize or 0
            local curCnt = inv.Items and #inv.Items or 0
            emptySlots = math.max(0, maxSz - curCnt)
        end)
    end

    local mS = math.max(1, tonumber(maxStack) or 1)
    local partialRoom = 0
    if canStack and mS > 1 then
        pcall(function()
            local items = inv.Items
            if not items then return end
            for i = 1, #items do
                local it = items[i]
                if safeValid(it) then
                    local itRn = ""
                    pcall(function() itRn = it.ItemDataRowHandle.RowName:ToString() end)
                    if itRn == rowName then
                        local itCan = false
                        pcall(function()
                            local vCan = it:CanStack()
                            itCan = (vCan == true or vCan == 1)
                        end)
                        if itCan then
                            local itMax = mS
                            pcall(function() itMax = it:GetMaxStackSize() or mS end)
                            local itCur = tonumber(it.StackSize) or 1
                            if itMax > itCur then
                                partialRoom = partialRoom + (itMax - itCur)
                            end
                        end
                    end
                end
            end
        end)
    end

    return partialRoom + emptySlots * mS, emptySlots
end

--- 标记某个 UItem 对象已刚完成倍率结算（短时间窗防 TryPickupItem 分支 4 AddItem->ServerEquipItem 二次倍增）。
local function markItemRecentlyBoosted(itemAddr)
    if not itemAddr then return end
    local now = os.clock()
    recentlyBoostedItemAddrs[itemAddr] = now
    -- 轻量惰性清理，避免长局内存增长
    local count = 0
    for k, ts in pairs(recentlyBoostedItemAddrs) do
        count = count + 1
        if (now - ts) > 3.0 then
            recentlyBoostedItemAddrs[k] = nil
        end
    end
    if count > 256 then
        recentlyBoostedItemAddrs = { [itemAddr] = now }
    end
end

local function wasItemRecentlyBoosted(itemAddr)
    if not itemAddr then return false end
    local ts = recentlyBoostedItemAddrs[itemAddr]
    if not ts then return false end
    if (os.clock() - ts) <= 1.0 then
        return true
    end
    recentlyBoostedItemAddrs[itemAddr] = nil
    return false
end

--- 统一为刚入包或刚装备的可堆叠物品（或经校验的易腐昆虫生肉）补发额外倍率数量（先补主目标 UItem，再补背包已有堆叠，超堆叠自动溢出到空闲槽位）。
local function applyExtraStackAndOverflow(owner, inv, primaryItem, rowName, extraCount, maxStack, pathTag, allowSingleCopyOverflow, itemDataTable)
    local remaining = tonumber(extraCount) or 0
    if remaining <= 0 or not rowName or rowName == "" then return false end
    local boostedAny = false
    local mStack = math.max(1, tonumber(maxStack) or 1)

    -- 阶段 1：优先把新增数量叠加到本次刚入包/刚装备的主目标 UItem 本身（确保鹅卵石/箭矢等主手装备与新格优先拿到整组）
    local primaryAddr = nil
    if safeValid(primaryItem) and mStack > 1 then
        pcall(function()
            primaryAddr = primaryItem:GetAddress()
            local canS = false
            local vCan = primaryItem:CanStack()
            canS = (vCan == true or vCan == 1)
            if canS then
                local mS = mStack
                pcall(function() mS = primaryItem:GetMaxStackSize() or mStack end)
                local curS = tonumber(primaryItem.StackSize) or 1
                if mS > 1 then
                    local room = math.max(0, mS - curS)
                    local give = math.min(remaining, room)
                    if give > 0 then
                        primaryItem:AdjustStackSize(give)
                        remaining = remaining - give
                        boostedAny = true
                    end
                end
            end
        end)
    end

    -- 阶段 2：补满背包内同种已有堆叠
    if remaining > 0 and mStack > 1 and safeValid(inv) then
        pcall(function()
            local items = inv.Items
            if not items then return end
            for i = 1, #items do
                if remaining <= 0 then break end
                local it = items[i]
                if safeValid(it) and (primaryAddr == nil or it:GetAddress() ~= primaryAddr) then
                    local itRn = ""
                    pcall(function() itRn = it.ItemDataRowHandle.RowName:ToString() end)
                    if itRn == rowName then
                        local canS = false
                        pcall(function()
                            local vCan = it:CanStack()
                            canS = (vCan == true or vCan == 1)
                        end)
                        if canS then
                            local mS = mStack
                            pcall(function() mS = it:GetMaxStackSize() or mStack end)
                            local curS = tonumber(it.StackSize) or 1
                            if mS > 1 then
                                local room = math.max(0, mS - curS)
                                local give = math.min(remaining, room)
                                if give > 0 then
                                    it:AdjustStackSize(give)
                                    remaining = remaining - give
                                    boostedAny = true
                                end
                            end
                        end
                    end
                end
            end
        end)
    end

    -- 阶段 3：若当前堆叠已满且仍有溢出数量（或为易腐昆虫生肉补发单份副本），自动按空闲背包格补发（绝不强行塞爆）
    if remaining > 0 and (mStack > 1 or allowSingleCopyOverflow == true) and safeValid(inv) then
        local emptySlots = 0
        local okEmp, emp = pcall(function() return inv:GetEmptySlots() end)
        if okEmp and type(emp) == "number" then
            emptySlots = emp
        else
            pcall(function()
                local maxSz = inv.MaxSize or 0
                local curCnt = inv.Items and #inv.Items or 0
                emptySlots = math.max(0, maxSz - curCnt)
            end)
        end

        if emptySlots > 0 and inv.ServerCreateAndAddItem then
            local itemsTable = safeValid(itemDataTable) and itemDataTable or ensureAllItemsTable()
            local maxIter = (allowSingleCopyOverflow == true and mStack <= 1) and 8 or 32
            local guardIter = 0
            while remaining > 0 and emptySlots > 0 and guardIter < maxIter do
                guardIter = guardIter + 1
                local chunk = math.min(remaining, mStack)
                inModExtraAddDepth = inModExtraAddDepth + 1
                local okCreate = pcall(function()
                    inv:ServerCreateAndAddItem({ DataTable = itemsTable, RowName = FName(rowName) }, chunk)
                end)
                inModExtraAddDepth = math.max(0, inModExtraAddDepth - 1)
                if okCreate then
                    remaining = remaining - chunk
                    emptySlots = emptySlots - 1
                    boostedAny = true
                else
                    break
                end
            end
        end
    end

    if boostedAny then
        harvestBoostHits = harvestBoostHits + 1
        if safeValid(owner) then
            local ctx = interactContextByPlayer[owner:GetAddress()]
            if ctx then ctx.boostedDuringInteract = true end
        end
        if harvestBoostHits <= 15 then
            logInfo(string.format("采集入包倍率生效(#%d): %s +%d (路径=%s, 倍率=%dx)",
                harvestBoostHits, rowName, (tonumber(extraCount) or 0) - remaining, tostring(pathTag or "AddItem"), cfg.harvestMultiplier))
        end
    end
    return boostedAny
end

--- 评估某次新物品拾取/装备是否满足采集倍率资格与四重防刷规则；符合条件返回请求元数据，否则返回 nil。
local function evaluatePickupItemForBoost(owner, item)
    if not safeValid(owner) or not safeValid(item) then return nil end

    local hasAuth = true
    pcall(function()
        if owner.HasAuthority then hasAuth = (owner:HasAuthority() == true) end
    end)
    if not hasAuth then return nil end

    local itemAddr = item:GetAddress()
    if excludedItemObjAddrs[itemAddr] or wasItemRecentlyBoosted(itemAddr) then
        return nil
    end

    local rn = ""
    local itemDataTable = nil
    pcall(function()
        local h = item.ItemDataRowHandle
        if h then
            if h.RowName then rn = h.RowName:ToString() end
            if h.DataTable and safeValid(h.DataTable) then itemDataTable = h.DataTable end
        end
    end)
    if rn == "" or rn == "None" or isHaulingRowName(rn) then
        return nil
    end

    local canStack = false
    local maxStack = 1
    pcall(function()
        local vCan = item:CanStack()
        canStack = (vCan == true or vCan == 1)
    end)
    pcall(function() maxStack = item:GetMaxStackSize() or 1 end)

    local isPerishableSingle = false
    if (not canStack) or maxStack <= 1 then
        if isPerishableNonEquipMaterial(item, rn) then
            isPerishableSingle = true
            canStack = false
            maxStack = 1
        else
            return nil
        end
    end

    -- 溯源地面 ASpawnedItem（依次检查 ItemVisuals.FullActor、item:GetOuter()，仅在目标确属该物品时兜底近期交互目标）
    local ownerAddr = owner:GetAddress()
    local spawnedActor = nil
    pcall(function()
        local visLod = unwrapWeakObject(item.ItemVisuals)
        if safeValid(visLod) then
            local fa = nil
            pcall(function() fa = visLod.FullActor end)
            if not safeValid(fa) then
                pcall(function() if visLod.K2_GetFullActor then fa = visLod:K2_GetFullActor() end end)
            end
            if safeValid(fa) and isSpawnedItemObject(fa) then
                spawnedActor = fa
            end
        end
    end)
    if not safeValid(spawnedActor) then
        pcall(function()
            local itemOuter = item:GetOuter()
            if safeValid(itemOuter) and isSpawnedItemObject(itemOuter) then
                spawnedActor = itemOuter
            end
        end)
    end
    local ctx = interactContextByPlayer[ownerAddr]
    local ctxFresh = (ctx ~= nil and (os.clock() - ctx.clock) <= 0.75)
    if (not safeValid(spawnedActor)) and ctxFresh then
        -- 防止摸死虫尸体（ULootComponent 新建 UItem）误套用 0.75 秒内残留的旧 ASpawnedItem（例如插在虫身上的投掷长矛/箭矢）
        if safeValid(ctx.target) and isSpawnedItemObject(ctx.target) then
            local targetMatchesItem = false
            pcall(function()
                local tIt = ctx.target.GetItem and ctx.target:GetItem() or nil
                if safeValid(tIt) and tIt:GetAddress() == itemAddr then
                    targetMatchesItem = true
                end
            end)
            if (not targetMatchesItem) and ctx.targetSnap then
                if ctx.targetSnap.itemAddr == itemAddr
                    or (ctx.targetSnap.rowName ~= "" and ctx.targetSnap.rowName == rn) then
                    targetMatchesItem = true
                end
            end
            if targetMatchesItem then
                spawnedActor = ctx.target
            end
        end
    end

    -- 四重防刷校验：拦截玩家丢弃物、投掷物、射出的箭矢(AttackOwner)、玩家放置物(PreplacedUser=1)与拆建返还物
    local preplaced = 0
    local spawnedAddr = nil
    if safeValid(spawnedActor) then
        local blocked
        blocked, preplaced, spawnedAddr = inspectSpawnedActorFlags(spawnedActor)
        if blocked then return nil end
        if consumeMatchingExcludedDropEvent(rn, spawnedActor) then
            return nil
        end
    elseif ctxFresh and ctx.targetSnap and ctx.targetSnap.rowName == rn and ctx.targetSnap.blocked then
        return nil
    end

    -- 区分「天然散落物直拾」(ISM 非破坏替换 / PreplacedDesign / 植被交互) 与「采集/击杀掉落及摸尸」
    local isNaturalDirectPickup = (preplaced == 2 or preplaced == 3)
        or (spawnedAddr ~= nil and foliagePickupActorAddrs[spawnedAddr] == true)
        or (foliagePickupItemAddrs[itemAddr] == true)
    if (not isNaturalDirectPickup) and ctxFresh then
        if (not safeValid(spawnedActor)) and ctx.isFoliage then
            isNaturalDirectPickup = true
        elseif ctx.targetSnap and ctx.targetSnap.rowName == rn and ctx.targetSnap.isNatural then
            isNaturalDirectPickup = true
        end
    end
    if isNaturalDirectPickup and not cfg.harvestAffectPickup then
        return nil
    end

    return {
        owner = owner,
        item = item,
        itemAddr = itemAddr,
        spawnedAddr = spawnedAddr,
        rowName = rn,
        itemDataTable = itemDataTable,
        canStack = canStack,
        isPerishableSingle = isPerishableSingle,
        maxStack = maxStack,
        mult = cfg.harvestMultiplier,
        origStack = math.max(1, tonumber(item.StackSize) or 1),
    }
end

--- 轻量记录玩家交互上下文（在按 E / 长按交互容器、烤肉架、晾干架、掉落背包期间拉高 inNonHarvestAddDepth 防刷，同时快照地面目标与主手装备）。
local function enterInteractContext(player, explicitTarget, forceContainer, forceFoliage)
    if not safeValid(player) then return end
    local pAddr = player:GetAddress()
    local targetObj = explicitTarget
    local isFoliage = (forceFoliage == true)
    local isCont = (forceContainer == true)
    pcall(function()
        if not safeValid(targetObj) then
            targetObj = unwrapInteractable(player.InteractableInRange)
        end
        if not safeValid(targetObj) then
            targetObj = unwrapInteractable(player.InteractableInRangeOnClient)
        end
        if not safeValid(targetObj) then
            targetObj = unwrapInteractable(player.TemporarilyDeinstancedInteractableInRange)
        end
        if not isFoliage then
            isFoliage = hasValidFoliageKey(player.InteractableFoliageKeyInRange)
                or hasValidFoliageKey(player.InteractableFoliageKeyInRangeOnClient)
        end
        if (not isCont) and safeValid(targetObj) then
            isCont = isContainerOrBuildingObject(targetObj)
        end
    end)
    if isCont then
        inNonHarvestAddDepth = inNonHarvestAddDepth + 1
    end
    local targetSnap = snapshotSpawnedTarget(targetObj)
    local eqWeapon, eqRow, eqStack = readEquippedMainWeapon(player)
    local prev = interactContextByPlayer[pAddr]
    local prevStack = (prev and prev.depthStack) or {}
    table.insert(prevStack, isCont)
    interactContextByPlayer[pAddr] = {
        target = targetObj,
        targetSnap = targetSnap,
        isContainer = isCont,
        isFoliage = isFoliage,
        equipWeapon = eqWeapon,
        equipWeaponRow = eqRow,
        equipWeaponBefore = eqStack,
        boostedDuringInteract = false,
        depthStack = prevStack,
        clock = os.clock(),
    }
end

local function leaveInteractContext(player)
    if not safeValid(player) then return end
    local pAddr = player:GetAddress()
    local ctx = interactContextByPlayer[pAddr]
    if ctx then
        local wasBlocked = false
        if ctx.depthStack and #ctx.depthStack > 0 then
            wasBlocked = (table.remove(ctx.depthStack) == true)
            if wasBlocked then
                inNonHarvestAddDepth = math.max(0, inNonHarvestAddDepth - 1)
            end
        end

        -- 联机客机兜底（TryPickupItem 分支 2：客机玩家手持鹅卵石/箭矢再按 E 拾取同类物品时，ClientOnItemAdded 为发往客机的 Client RPC，
        -- 在房主端不触发本地 Native Hook，此处直接比对主手装备实际堆叠增量并在房主端补足倍率，同时防重复触发）
        if (not wasBlocked) and (not ctx.boostedDuringInteract) and inNonHarvestAddDepth == 0 and inModExtraAddDepth == 0
            and cfg.harvestEnabled and cfg.harvestMultiplier and cfg.harvestMultiplier > 1
            and ctx.equipWeaponRow and ctx.equipWeaponRow ~= "" then
            pcall(function()
                local hasAuth = true
                if player.HasAuthority then hasAuth = (player:HasAuthority() == true) end
                if not hasAuth then return end
                local curWeapon, curRow, curStack = readEquippedMainWeapon(player)
                if safeValid(curWeapon) and curRow == ctx.equipWeaponRow and curStack > (ctx.equipWeaponBefore or 0) then
                    local delta = curStack - (ctx.equipWeaponBefore or 0)
                    local snap = ctx.targetSnap
                    if snap and snap.rowName == curRow and snap.blocked then return end
                    if consumeMatchingExcludedDropEvent(curRow, player) then return end
                    local isNat = ctx.isFoliage or (snap and snap.rowName == curRow and snap.isNatural)
                    if isNat and not cfg.harvestAffectPickup then return end
                    local canS = false
                    local vCan = curWeapon:CanStack()
                    canS = (vCan == true or vCan == 1)
                    local maxS = curWeapon:GetMaxStackSize() or 1
                    if canS and maxS > 1 then
                        local extra = delta * (cfg.harvestMultiplier - 1)
                        applyExtraStackAndOverflow(player, player.InventoryComponent, curWeapon, curRow, extra, maxS, "InteractEquipFallback")
                    end
                end
            end)
        end

        -- 保留极短时间窗（0.75s）内的植被直拾标记供延迟动画入包判定，容器标记不跨调用残留
        ctx.isContainer = false
    end
end

-- 触碰自动拾取上下文快照（如踩过地上箭矢/鹅卵石触发 ASpawnedItem:HandleTouch）
pcall(function()
    RegisterHook("/Script/Maine.SpawnedItem:HandleTouch", function(selfParam, actorParam)
        pcall(function()
            local si = selfParam:get()
            local actor = actorParam and actorParam:get() or nil
            if not safeValid(si) or not isSurvivalPlayerObject(actor) then return end
            local pAddr = actor:GetAddress()
            local prev = interactContextByPlayer[pAddr]
            local snap = snapshotSpawnedTarget(si)
            local eqWeapon, eqRow, eqStack = readEquippedMainWeapon(actor)
            interactContextByPlayer[pAddr] = {
                target = si,
                targetSnap = snap,
                isContainer = false,
                isFoliage = snap.isNatural,
                equipWeapon = eqWeapon,
                equipWeaponRow = eqRow,
                equipWeaponBefore = eqStack,
                boostedDuringInteract = false,
                depthStack = (prev and prev.depthStack) or {},
                clock = os.clock(),
            }
        end)
    end)
end)

-- 按实机 SDK（Maine.hpp）精确挂接短按交互与全部长按交互入口（Actor / Building / Foliage 三分入口）：
pcall(function()
    RegisterHook("/Script/Maine.SurvivalPlayerCharacter:ServerHandleInteract", function(selfParam)
        enterInteractContext(selfParam:get(), nil, false, false)
    end, function(selfParam)
        leaveInteractContext(selfParam:get())
    end)
end)

for _, actorHoldPath in ipairs({
    "/Script/Maine.SurvivalPlayerCharacter:ServerHandleHoldInteractActor",
    "/Script/Maine.SurvivalPlayerCharacter:ServerEndHoldInteractActor",
}) do
    pcall(function()
        RegisterHook(actorHoldPath, function(selfParam, targetParam)
            local tObj = nil
            pcall(function() tObj = targetParam and targetParam:get() or nil end)
            enterInteractContext(selfParam:get(), unwrapInteractable(tObj), false, false)
        end, function(selfParam)
            leaveInteractContext(selfParam:get())
        end)
    end)
end

pcall(function()
    RegisterHook("/Script/Maine.SurvivalPlayerCharacter:ServerHoldInteractSecondaryActor", function(selfParam, _chanParam, targetParam)
        local tObj = nil
        pcall(function() tObj = targetParam and targetParam:get() or nil end)
        enterInteractContext(selfParam:get(), unwrapInteractable(tObj), false, false)
    end, function(selfParam)
        leaveInteractContext(selfParam:get())
    end)
end)

for _, bldHoldPath in ipairs({
    "/Script/Maine.SurvivalPlayerCharacter:ServerHandleHoldInteractBuilding",
    "/Script/Maine.SurvivalPlayerCharacter:ServerHoldInteractSecondaryBuilding",
    "/Script/Maine.SurvivalPlayerCharacter:ServerEndHoldInteractBuilding",
}) do
    pcall(function()
        RegisterHook(bldHoldPath, function(selfParam)
            enterInteractContext(selfParam:get(), nil, true, false)
        end, function(selfParam)
            leaveInteractContext(selfParam:get())
        end)
    end)
end

for _, folHoldPath in ipairs({
    "/Script/Maine.SurvivalPlayerCharacter:ServerHandleHoldInteractFoliage",
    "/Script/Maine.SurvivalPlayerCharacter:ServerHoldInteractSecondaryFoliage",
    "/Script/Maine.SurvivalPlayerCharacter:ServerEndHoldInteractFoliage",
}) do
    pcall(function()
        RegisterHook(folHoldPath, function(selfParam)
            enterInteractContext(selfParam:get(), nil, false, true)
        end, function(selfParam)
            leaveInteractContext(selfParam:get())
        end)
    end)
end

-- 统一全路径入包与自动装备倍率 Hook（ADR-0005 实机二进制全覆盖版）：
--   1. /Script/Maine.InventoryComponent:AddItem：覆盖 TryPickupItem 分支 4（经 ServerAddItem 尾调用 AddItem）与 ULootComponent 摸尸直入背包；
--   2. /Script/Maine.EquipmentComponent:ServerEquipItem（bCheckInventory=false）：覆盖 TryPickupItem 分支 1/3 空手自动装备鹅卵石/箭矢；
--   3. /Script/Maine.InventoryComponent:ClientOnItemAdded（inAddItemDepth==0）：覆盖 TryPickupItem 分支 2 手持鹅卵石/箭矢时继续拾取直接叠加主手。
pcall(function()
    RegisterHook("/Script/Maine.InventoryComponent:AddItem", function(selfParam, itemParam, isNewParam)
        inAddItemDepth = inAddItemDepth + 1
        if not (cfg.harvestEnabled and cfg.harvestMultiplier and cfg.harvestMultiplier > 1) then
            return
        end
        if inNonHarvestAddDepth > 0 or inModExtraAddDepth > 0 then
            return
        end

        local isNew = false
        if isNewParam then
            local v = isNewParam:get()
            isNew = (v == true or v == 1)
        end
        if not isNew then return end

        local inv = selfParam:get()
        local item = itemParam and itemParam:get() or nil
        if not safeValid(inv) or not safeValid(item) then return end

        local owner = getComponentOwnerPlayer(inv)
        if not owner then return end

        local eval = evaluatePickupItemForBoost(owner, item)
        if not eval then return end

        eval.beforeCount = countRowInInventory(inv, eval.rowName)
        eval.preAdded = 0
        eval.totalExtra = eval.origStack * math.max(0, (eval.mult or 1) - 1)

        -- 关键修复（首次采集即走倍率 + 原生 HUD 同步显示正确总数）：
        -- 原版 UInventoryComponent::AddItem 会先读取 item->StackSize、执行 AddItemInternal，
        -- 再在函数末尾触发 OnItemAdded 与 ClientOnItemAdded(TotalCount) 后才回到 Post-Hook。
        -- 在 Pre-Hook 核验背包安全余量后直接抬升 item.StackSize，确保首次采集入包、背包显示与左下角 HUD 播报 100% 同步走倍率！
        if eval.canStack and eval.maxStack > 1 and eval.totalExtra > 0 then
            local availSpace = computeInventoryAvailableSpace(inv, eval.rowName, eval.maxStack, true)
            if availSpace > 0 then
                local itemRoom = math.max(0, eval.maxStack - eval.origStack)
                local invExtraRoom = math.max(0, availSpace - eval.origStack)
                local preWant = math.min(eval.totalExtra, itemRoom, invExtraRoom)
                if preWant > 0 then
                    local beforeSz = tonumber(item.StackSize) or eval.origStack
                    pcall(function() item:AdjustStackSize(preWant) end)
                    local afterSz = tonumber(item.StackSize) or beforeSz
                    eval.preAdded = math.max(0, afterSz - beforeSz)
                end
            end
        end

        local invAddr = inv:GetAddress()
        local stk = pendingAddItemBoosts[invAddr]
        if not stk then
            stk = {}
            pendingAddItemBoosts[invAddr] = stk
        end
        table.insert(stk, eval)
    end, function(selfParam)
        inAddItemDepth = math.max(0, inAddItemDepth - 1)
        local inv = selfParam:get()
        if not safeValid(inv) then return end
        local invAddr = inv:GetAddress()
        local stk = pendingAddItemBoosts[invAddr]
        if not stk or #stk == 0 then return end
        local req = table.remove(stk)
        if #stk == 0 then
            pendingAddItemBoosts[invAddr] = nil
        end
        if not req then return end

        if req.itemAddr then foliagePickupItemAddrs[req.itemAddr] = nil end
        if req.spawnedAddr then foliagePickupActorAddrs[req.spawnedAddr] = nil end

        local extraMult = (req.mult or 1) - 1
        if extraMult <= 0 then return end

        -- 用前后精确增量确认物品确实入包；若背包已满被引擎拒绝（actualAdded <= 0），立刻回滚 Pre-Hook 预加量绝不污染地面物品
        local afterCount = countRowInInventory(inv, req.rowName)
        local actualAdded = afterCount - (req.beforeCount or 0)
        if actualAdded <= 0 then
            if (req.preAdded or 0) > 0 and safeValid(req.item) then
                pcall(function() req.item:AdjustStackSize(-req.preAdded) end)
            end
            return
        end

        -- 计算除 Pre-Hook 已随原版 AddItem 一起入包的增量外，是否还有超堆叠/易腐生肉副本需要 Post-Hook 补发
        local preAdded = req.preAdded or 0
        local baseAdded = math.max(0, actualAdded - preAdded)
        if preAdded > 0 then
            -- 若原版 AddItem 实际接纳量小于 origStack + preAdded（例如背包仅剩部分空间），以实际已入包 preAdded 计次
            harvestBoostHits = harvestBoostHits + 1
            markItemRecentlyBoosted(req.itemAddr)
            if safeValid(req.owner) then
                local ctx = interactContextByPlayer[req.owner:GetAddress()]
                if ctx then ctx.boostedDuringInteract = true end
            end
            if harvestBoostHits <= 15 then
                logInfo(string.format("采集入包倍率生效(#%d): %s +%d (路径=AddItem-Pre, 倍率=%dx)",
                    harvestBoostHits, req.rowName, preAdded, cfg.harvestMultiplier))
            end
        end

        local wantTotalExtra = (baseAdded > 0 and (baseAdded * extraMult)) or (req.totalExtra or 0)
        local remainingExtra = math.max(0, wantTotalExtra - preAdded)
        if remainingExtra <= 0 then return end

        -- 若刚入包的 UItem 仍在背包列表中，将其作为首选目标，确保紧随其后的自动装备拿到整组
        local primaryInInv = nil
        pcall(function()
            local items = inv.Items
            if items and req.itemAddr then
                for i = 1, #items do
                    local it = items[i]
                    if safeValid(it) and it:GetAddress() == req.itemAddr then
                        primaryInInv = it
                        break
                    end
                end
            end
        end)

        local boostedOverflow = applyExtraStackAndOverflow(
            req.owner, inv, primaryInInv, req.rowName, remainingExtra, req.maxStack,
            req.isPerishableSingle and "AddItem-PerishableMeat" or (preAdded > 0 and "AddItem-Overflow" or "AddItem"),
            req.isPerishableSingle == true, req.itemDataTable)
        if boostedOverflow then
            markItemRecentlyBoosted(req.itemAddr)
        end
    end)
end)

-- 路径 2：TryPickupItem 分支 1/3 空手自动装备可堆叠物（如空手捡鹅卵石/箭矢直接走 ServerEquipItem(Item, false) 绕过 AddItem）
pcall(function()
    RegisterHook("/Script/Maine.EquipmentComponent:ServerEquipItem", function(selfParam, itemParam, checkInvParam)
        if not (cfg.harvestEnabled and cfg.harvestMultiplier and cfg.harvestMultiplier > 1) then
            return
        end
        if inNonHarvestAddDepth > 0 or inModExtraAddDepth > 0 or inAddItemDepth > 0 then
            return
        end
        -- bCheckInventory=true 表示从背包/快捷栏切换装备，严禁倍增；仅地面直拾自动装备时 TryPickupItem 传入 false
        local checkInv = true
        if checkInvParam then
            local v = checkInvParam:get()
            checkInv = (v == true or v == 1)
        end
        if checkInv then return end

        local eq = selfParam:get()
        local item = itemParam and itemParam:get() or nil
        if not safeValid(eq) or not safeValid(item) then return end

        local owner = getComponentOwnerPlayer(eq)
        if not owner then return end

        local eval = evaluatePickupItemForBoost(owner, item)
        if not eval or eval.isPerishableSingle then return end

        local eqAddr = eq:GetAddress()
        local stk = pendingEquipBoosts[eqAddr]
        if not stk then
            stk = {}
            pendingEquipBoosts[eqAddr] = stk
        end
        table.insert(stk, eval)
    end, function(selfParam)
        local eq = selfParam:get()
        if not safeValid(eq) then return end
        local eqAddr = eq:GetAddress()
        local stk = pendingEquipBoosts[eqAddr]
        if not stk or #stk == 0 then return end
        local req = table.remove(stk)
        if #stk == 0 then
            pendingEquipBoosts[eqAddr] = nil
        end
        if not req then return end

        if req.itemAddr then foliagePickupItemAddrs[req.itemAddr] = nil end
        if req.spawnedAddr then foliagePickupActorAddrs[req.spawnedAddr] = nil end
        if wasItemRecentlyBoosted(req.itemAddr) then return end

        local extraMult = (req.mult or 1) - 1
        if extraMult <= 0 then return end

        local inv = nil
        pcall(function() inv = req.owner.InventoryComponent end)
        local boosted = applyExtraStackAndOverflow(
            req.owner, inv, req.item, req.rowName, (req.origStack or 1) * extraMult,
            req.maxStack, "ServerEquipItem", false, req.itemDataTable)
        if boosted then
            markItemRecentlyBoosted(req.itemAddr)
            if safeValid(inv) then
                -- 标记该物品刚由 ServerEquipItem 完成倍增，防止 5 条指令后的 ClientOnItemAdded 二次叠加
                recentEquipHandledByInv[inv:GetAddress()] = { rowName = req.rowName, clock = os.clock() }
            end
        end
    end)
end)

-- 路径 3：TryPickupItem 分支 2 手持同类可堆叠物继续拾取（如手持鹅卵石再捡鹅卵石，绕过 AddItem 与 ServerEquipItem 直调 ClientOnItemAdded）
pcall(function()
    RegisterHook("/Script/Maine.InventoryComponent:ClientOnItemAdded", function(selfParam, rowHandleParam, isNewParam)
        if inAddItemDepth > 0 or inNonHarvestAddDepth > 0 or inModExtraAddDepth > 0 then
            return
        end
        if not (cfg.harvestEnabled and cfg.harvestMultiplier and cfg.harvestMultiplier > 1) then
            return
        end
        local isNew = false
        if isNewParam then
            local v = isNewParam:get()
            isNew = (v == true or v == 1)
        end
        if not isNew then return end

        local inv = selfParam:get()
        if not safeValid(inv) then return end
        local owner = getComponentOwnerPlayer(inv)
        if not owner then return end
        local hasAuth = true
        pcall(function()
            if owner.HasAuthority then hasAuth = (owner:HasAuthority() == true) end
        end)
        if not hasAuth then return end

        local rn = ""
        pcall(function()
            local h = rowHandleParam and rowHandleParam:get() or nil
            if h and h.RowName then rn = h.RowName:ToString() end
        end)
        if rn == "" or rn == "None" or isHaulingRowName(rn) then return end

        -- 若刚由 ServerEquipItem（分支 1/3）倍增过，消费防重标记并直接返回
        local invAddr = inv:GetAddress()
        local recent = recentEquipHandledByInv[invAddr]
        if recent and recent.rowName == rn and (os.clock() - recent.clock) <= 0.1 then
            recentEquipHandledByInv[invAddr] = nil
            return
        end

        local weapon, wRn, _ = readEquippedMainWeapon(owner)
        if not safeValid(weapon) or wRn ~= rn then return end

        local canS = false
        local maxS = 1
        pcall(function()
            local vCan = weapon:CanStack()
            canS = (vCan == true or vCan == 1)
            maxS = weapon:GetMaxStackSize() or 1
        end)
        if (not canS) or maxS <= 1 then return end

        local ownerAddr = owner:GetAddress()
        local ctx = interactContextByPlayer[ownerAddr]
        local ctxFresh = (ctx ~= nil and (os.clock() - ctx.clock) <= 0.75)
        local snap = (ctxFresh and ctx.targetSnap and ctx.targetSnap.rowName == rn) and ctx.targetSnap or nil
        if snap and snap.blocked then return end
        if consumeMatchingExcludedDropEvent(rn, owner) then return end

        local isNaturalDirectPickup = (snap and snap.isNatural == true) or (ctxFresh and ctx.isFoliage == true)
        if isNaturalDirectPickup and not cfg.harvestAffectPickup then
            return
        end

        local delta = (snap and snap.stackSize) or 1
        if ctxFresh and ctx.equipWeaponRow == rn and (ctx.equipWeaponBefore or 0) > 0 then
            local curS = tonumber(weapon.StackSize) or 1
            if curS > ctx.equipWeaponBefore then
                delta = curS - ctx.equipWeaponBefore
            end
        end
        if snap and snap.itemAddr then foliagePickupItemAddrs[snap.itemAddr] = nil end
        if snap and snap.actorAddr then foliagePickupActorAddrs[snap.actorAddr] = nil end

        local extra = delta * (cfg.harvestMultiplier - 1)
        applyExtraStackAndOverflow(owner, inv, weapon, rn, extra, maxS, "ClientOnItemAdded-EquipStack")
    end)
end)

-- ============================================================
-- 6.5. 死亡保护扩展：一键找回掉落背包（唤醒远距 LOD + 瞬移到目标玩家脚边）
-- ============================================================

--- 提取指定玩家角色（及其 PlayerState）的归一化 GUID 键与小写玩家名，用于匹配掉落背包归属。
local function extractPlayerIdentity(pawn)
    local gKey = ""
    local nameLow = ""
    if not safeValid(pawn) then return gKey, nameLow end

    pcall(function()
        local ps = pawn.PlayerState
        if safeValid(ps) then
            gKey = guidToKey(ps.PlayerGuid)
            if gKey == "" then
                pcall(function() gKey = guidToKey(ps:GetPlayerGuid()) end)
            end
            pcall(function()
                local pn = ueStringToLua(ps:GetPlayerName())
                if pn ~= "" then nameLow = pn:lower() end
            end)
        end
    end)
    if gKey == "" then
        pcall(function() gKey = guidToKey(pawn.PlayerGuid) end)
    end
    return gKey, nameLow
end

--- 判断一个 ALootBag 内部是否已经没有物品（用于跳过已被捡空但尚未销毁的空背包）。
local function isLootBagEmpty(bag)
    if not safeValid(bag) then return true end
    local empty = false
    pcall(function()
        local inv = bag.InventoryComponent
        if not safeValid(inv) then
            empty = true
            return
        end
        local okEmpty, isEmp = pcall(function() return inv:IsInventoryEmpty() end)
        if okEmpty and isEmp == true then
            empty = true
            return
        end
        local items = inv.Items
        if items and #items == 0 then
            empty = true
        end
    end)
    return empty
end

--- 从 UBaseLODActor 提取未加载目标蓝图短类名（纯只读查询，绝不触发 LOD 唤醒）。
local function getLodActorClassShort(lod)
    local clsShort = ""
    if not safeValid(lod) then return clsShort end
    pcall(function()
        local hardCls = lod:GetActorClassHard()
        if safeValid(hardCls) then
            clsShort = cleanClassName(hardCls:GetFName():ToString())
        end
    end)
    if clsShort == "" then
        pcall(function()
            local softCls = lod:GetActorClassSoft()
            if softCls then
                local softStr = ""
                if type(softCls) == "string" then
                    softStr = softCls
                elseif softCls.AssetPathName then
                    softStr = softCls.AssetPathName:ToString()
                elseif softCls.ToString then
                    softStr = softCls:ToString()
                else
                    softStr = tostring(softCls)
                end
                if softStr and softStr ~= "" and softStr ~= "None" then
                    clsShort = cleanClassName(softStr)
                end
            end
        end)
    end
    return clsShort
end

--- 在不唤醒 LOD 的前提下，通过 InventoryLODComponent.ProxyComponent 判断远距未加载背包是否已空。
-- @return true=确认已空, false=确认非空或无法判定（交由唤醒后二次校验）
local function isUnloadedLodInventoryEmpty(lod)
    local empty = false
    if not safeValid(lod) then return false end
    pcall(function()
        local comps = lod.LODComponents
        if not comps then return end
        for i = 1, #comps do
            local comp = comps[i]
            if safeValid(comp) then
                local cname = ""
                pcall(function() cname = comp:GetClass():GetFName():ToString() end)
                if cname == "InventoryLODComponent" then
                    local proxyComp = nil
                    pcall(function() proxyComp = comp.ProxyComponent end)
                    if safeValid(proxyComp) then
                        local okEmp, isEmp = pcall(function() return proxyComp:IsInventoryEmpty() end)
                        if okEmp and isEmp == true then
                            empty = true
                            return
                        end
                        local items = nil
                        pcall(function() items = proxyComp.Items end)
                        if items and #items == 0 then
                            empty = true
                            return
                        end
                    end
                end
            end
        end
    end)
    return empty
end

--- 将指定掉落背包安全瞬移到目标坐标，清除物理残留速度并触发联机坐标同步。
-- 先尝试 K2_TeleportTo（UE4 内置防卡墙微调），若被狭小洞穴几何体拒绝则降级为 K2_SetActorLocation(bSweep=false, bTeleport=true)。
local function teleportLootBagSafely(bag, destPos)
    if not safeValid(bag) then return false end

    -- 清除可能存在的下落/翻滚物理速度，防止悬崖或水下找回的背包落地后弹飞
    pcall(function()
        local root = bag.RootComponent
        if safeValid(root) then
            pcall(function() root:SetPhysicsLinearVelocity({ X = 0, Y = 0, Z = 0 }, false, FName("None")) end)
            pcall(function() root:SetPhysicsAngularVelocityInDegrees({ X = 0, Y = 0, Z = 0 }, false, FName("None")) end)
        end
    end)

    local moved = false
    pcall(function()
        local okTp = bag:K2_TeleportTo(destPos, { Pitch = 0, Yaw = 0, Roll = 0 })
        if okTp == true then
            moved = true
        end
    end)
    if not moved then
        pcall(function()
            local hitOut = {}
            bag:K2_SetActorLocation(destPos, false, hitOut, true)
            moved = true
        end)
    end

    -- 通知 Grounded 联机复制层立即刷新背包坐标，保证联机队友端立刻同步到新位置
    pcall(function() bag:ResyncReplicationTransform() end)
    return moved
end

--- 一键找回玩家死亡掉落的非空背包（见 ADR-0002）。
-- 仅在房主权威端执行；采用“零唤醒前置过滤”机制：
--   1. 先从 HUDMarkerManagerComponent 收集游戏原生登记的 DroppedBackpack(7) 标记与对应 Actor/LOD；
--   2. 扫描已加载的 ALootBag（无需唤醒）；
--   3. 对未加载的 ULootBagLODActor，在调用 ConvertToFullActorBlocking() 前必须通过四重只读前置校验：
--      类型白名单(BP_Backpack/HUD标记) + 宝箱/建筑袋黑名单 + UProxyLootBagActor 归属校验 + ProxyInventory 非空校验，
--      彻底杜绝误唤醒未加载实验室子关卡中的 Ominent 宝箱引发引擎空指针闪退。
-- @param recoverAllParty false=仅找回房主/单人自己的掉落背包；true=找回全队所有玩家背包（在线送至本人脚边，离线归房主）
local function recoverDroppedBackpacks(recoverAllParty)
    local okGs, gs = pcall(FindFirstOf, "SurvivalGameState")
    local pc = UEHelpers.GetPlayerController()
    local hostPawn = safeValid(pc) and pc.Pawn or nil

    if not (okGs and safeValid(gs) and safeValid(hostPawn)) then
        lastStatusMessage = "当前尚未进入存档，无法找回掉落背包"
        logInfo(lastStatusMessage)
        return
    end

    local isHost = true
    pcall(function() isHost = gs:HasAuthority() end)
    if not isHost then
        lastStatusMessage = "仅房主可执行一键找回背包（请由房主点击找回全队背包）"
        logInfo(lastStatusMessage)
        return
    end

    -- 1. 收集房主及全部在线队友的角色与身份映射（GUID 与玩家名双索引）
    local hostGuidKey, hostNameLow = extractPlayerIdentity(hostPawn)
    local backpackClass = nil
    pcall(function() backpackClass = hostPawn.Backpack end)

    local guidToPawn = {}
    local nameToPawn = {}
    local onlinePawnsByAddr = {}
    local onlineCount = 0

    local function registerOnlinePawn(p)
        if not safeValid(p) then return end
        local addr = p:GetAddress()
        if onlinePawnsByAddr[addr] then return end
        onlinePawnsByAddr[addr] = p
        onlineCount = onlineCount + 1
        local gk, nl = extractPlayerIdentity(p)
        if gk ~= "" then guidToPawn[gk] = p end
        if nl ~= "" then nameToPawn[nl] = p end
    end

    registerOnlinePawn(hostPawn)
    pcall(function()
        if safeValid(gs.PartyComponent) and gs.PartyComponent.PartyMembers then
            local members = gs.PartyComponent.PartyMembers
            for i = 1, #members do
                registerOnlinePawn(members[i])
            end
        end
    end)
    pcall(function()
        local allChars = FindAllOf("SurvivalPlayerCharacter")
        if allChars then
            for _, ch in ipairs(allChars) do
                registerOnlinePawn(ch)
            end
        end
    end)

    -- 2. 收集游戏原生 HUDMarkerManagerComponent 中已确认的 DroppedBackpack(7) 标记（零唤醒）
    local bagsByAddr = {}
    local candidateBags = {}
    local markerConfirmedLod = {}   -- key=LODActor 地址 -> true
    local markerLodOwnerGuid = {}   -- key=LODActor 地址 -> RestrictedToPlayer GUID 字符串键
    local skippedEmpty = 0
    local otherPlayerBagCount = 0
    local wokeLodCount = 0

    local function pushCandidateBag(bag)
        if not safeValid(bag) then return end
        local fullName = ""
        pcall(function() fullName = bag:GetFullName() end)
        if fullName:find("Default__") then return end
        local destroying = false
        pcall(function() destroying = (bag:IsActorBeingDestroyed() == true) end)
        if destroying then return end

        local addr = bag:GetAddress()
        if not bagsByAddr[addr] then
            bagsByAddr[addr] = true
            table.insert(candidateBags, bag)
        end
    end

    local function collectDroppedBackpackMarkers(markerArr)
        if not markerArr then return end
        local n = 0
        pcall(function() n = #markerArr end)
        for i = 1, n do
            pcall(function()
                local md = markerArr[i]
                if not safeValid(md) then return end
                local mType = -1
                pcall(function() mType = md:GetMarkerType() end)
                if mType == -1 then
                    pcall(function() mType = md.MarkerType or -1 end)
                end
                if mType ~= 7 then return end -- EHUDMarkerType::DroppedBackpack == 7

                local ownerGk = ""
                pcall(function() ownerGk = guidToKey(md:GetRestrictedToPlayer()) end)
                if ownerGk == "" then
                    pcall(function() ownerGk = guidToKey(md.RestrictedToPlayer) end)
                end

                local refAct = nil
                pcall(function() refAct = md:GetReferencedActor() end)
                if safeValid(refAct) then
                    pushCandidateBag(refAct)
                end

                local refLod = nil
                pcall(function() refLod = md:GetReferencedLODActor() end)
                if safeValid(refLod) then
                    local lAddr = refLod:GetAddress()
                    markerConfirmedLod[lAddr] = true
                    if ownerGk ~= "" then
                        markerLodOwnerGuid[lAddr] = ownerGk
                    end
                end
            end)
        end
    end

    pcall(function()
        local hm = nil
        pcall(function() hm = gs.HUDMarkerManagerComponent end)
        if not safeValid(hm) then
            pcall(function() hm = FindFirstOf("HUDMarkerManagerComponent") end)
        end
        if safeValid(hm) then
            pcall(function()
                if hm.RegisteredActorMarkerData then
                    collectDroppedBackpackMarkers(hm.RegisteredActorMarkerData.MarkerArray)
                end
            end)
            pcall(function()
                if hm.RegisteredLODActorMarkerData then
                    collectDroppedBackpackMarkers(hm.RegisteredLODActorMarkerData.MarkerArray)
                end
            end)
            pcall(function()
                collectDroppedBackpackMarkers(hm.ReplicatedMarkerList)
            end)
        end
    end)

    -- 3. 先收集所有已加载的 ALootBag（纯只读，无任何 LOD 唤醒风险）
    pcall(function()
        local loadedBags = FindAllOf("LootBag")
        if loadedBags then
            for _, bag in ipairs(loadedBags) do
                pushCandidateBag(bag)
            end
        end
    end)

    -- 4. 仅对严格通过“玩家掉落背包 + 归属匹配 + 非空”前置校验的远距未加载 LOD 执行按需唤醒（上限 16 个）
    local MAX_WAKE_PER_CLICK = 16
    local lodsToWake = {}
    local seenLodAddr = {}

    local function considerLootBagLod(lod)
        if not safeValid(lod) then return end
        local lAddr = lod:GetAddress()
        if seenLodAddr[lAddr] then return end
        seenLodAddr[lAddr] = true

        local fullActor = nil
        pcall(function() fullActor = lod.FullActor end)
        if safeValid(fullActor) then
            pushCandidateBag(fullActor)
            return
        end

        local confirmedByMarker = (markerConfirmedLod[lAddr] == true)
        local clsShort = getLodActorClassShort(lod)
        local lowCls = clsShort:lower()

        -- 黑名单硬拦截：绝不唤醒任何 Ominent 宝箱、补给箱、储物箱或建筑战利品袋
        if lowCls:find("chest") or lowCls:find("ominent") or lowCls:find("treasure")
            or lowCls:find("storage") or lowCls:find("building") or lowCls:find("supply") then
            return
        end

        -- 白名单校验：必须匹配玩家背包蓝图类型、类名含 backpack，或经 HUD DroppedBackpack 标记确认
        local isBackpackType = confirmedByMarker or (lowCls:find("backpack") ~= nil)
        if (not isBackpackType) and safeValid(backpackClass) then
            pcall(function()
                if lod:IsFullActorType(backpackClass) == true then
                    isBackpackType = true
                end
            end)
        end
        if not isBackpackType then
            return
        end

        -- 读取 UProxyLootBagActor 归属信息（无需唤醒 FullActor），并在 ProxyActor 为空时兜底调用 lod:GetOwnerPlayerGuid()
        local proxyGuidKey = markerLodOwnerGuid[lAddr] or ""
        local proxyOwnerNameLow = ""
        pcall(function()
            local proxy = lod.ProxyActor
            if safeValid(proxy) then
                if proxyGuidKey == "" then
                    proxyGuidKey = guidToKey(proxy.OwnerPlayerGuid)
                end
                local pn = ueStringToLua(proxy.OwnerName)
                if pn ~= "" then proxyOwnerNameLow = pn:lower() end
            end
        end)
        if proxyGuidKey == "" then
            pcall(function()
                if lod.GetOwnerPlayerGuid then
                    proxyGuidKey = guidToKey(lod:GetOwnerPlayerGuid())
                end
            end)
        end

        -- 无主且无 DroppedBackpack 标记的容器属于场景预摆物体，禁止唤醒
        if (not confirmedByMarker) and proxyGuidKey == "" and proxyOwnerNameLow == "" then
            return
        end

        -- 未加载代理中已可判定为空背包时，直接跳过不唤醒
        if isUnloadedLodInventoryEmpty(lod) then
            skippedEmpty = skippedEmpty + 1
            return
        end

        -- 仅找回自己的背包时，先在未加载层排除明确属于其他队友的远距背包
        if not recoverAllParty then
            local matchesHost = false
            if hostGuidKey ~= "" and proxyGuidKey ~= "" then
                matchesHost = (proxyGuidKey == hostGuidKey)
            elseif hostNameLow ~= "" and proxyOwnerNameLow ~= "" then
                matchesHost = (proxyOwnerNameLow == hostNameLow)
            elseif onlineCount <= 1 and confirmedByMarker then
                matchesHost = true
            end
            if not matchesHost then
                otherPlayerBagCount = otherPlayerBagCount + 1
                return
            end
        end

        if #lodsToWake < MAX_WAKE_PER_CLICK then
            table.insert(lodsToWake, lod)
        end
    end

    pcall(function()
        local mgr = gs.LODActorManagerComponent
        if not safeValid(mgr) or not mgr.LODActors then return end
        local lods = mgr.LODActors
        for i = 1, #lods do
            local lod = lods[i]
            if safeValid(lod) then
                pcall(function()
                    local lAddr = lod:GetAddress()
                    if markerConfirmedLod[lAddr] or lod:GetClass():GetFName():ToString() == "LootBagLODActor" then
                        considerLootBagLod(lod)
                    end
                end)
            end
        end
    end)

    -- 仅在遍历 LODActors 结束后再逐一唤醒少量已确认的远距玩家背包（避免迭代期间修改数组）
    for _, lod in ipairs(lodsToWake) do
        pcall(function()
            lod:ConvertToFullActorBlocking()
            local fullActor = nil
            pcall(function() fullActor = lod.FullActor end)
            if not safeValid(fullActor) then
                pcall(function() fullActor = lod:K2_GetFullActor() end)
            end
            if safeValid(fullActor) then
                wokeLodCount = wokeLodCount + 1
                pushCandidateBag(fullActor)
            end
        end)
    end

    -- 5. 严格筛选玩家死亡掉落背包（ELootBagType::PlayerBackpack = 1）、跳过空包，并按目标玩家分组
    local statics = getSurvivalStatics()
    local targetGroups = {}      -- key=targetPawn 地址 -> { pawn=targetPawn, bags={...} }
    local targetGroupOrder = {}
    local offlineToHostCount = 0

    for _, bag in ipairs(candidateBags) do
        pcall(function()
            -- 严格排除建筑拆毁/储物箱损坏产生的战利品袋（ELootBagType::Undefined = 0）
            local bagType = bag.LootBagType
            if bagType ~= 1 then return end

            -- 跳过已空背包
            if isLootBagEmpty(bag) then
                skippedEmpty = skippedEmpty + 1
                return
            end

            local ownerGuidRaw = nil
            pcall(function() ownerGuidRaw = bag.OwnerPlayerGuid end)
            local ownerGuidKey = guidToKey(ownerGuidRaw)
            local ownerNameLow = ueStringToLua(bag.OwnerName):lower()

            -- 判定该背包是否属于当前房主本人
            local isMine = false
            if hostGuidKey ~= "" and ownerGuidKey ~= "" then
                isMine = (ownerGuidKey == hostGuidKey)
            elseif hostNameLow ~= "" and ownerNameLow ~= "" then
                isMine = (ownerNameLow == hostNameLow)
            elseif onlineCount <= 1 then
                -- 单人存档若历史旧包未写入 GUID，兜底归属当前单人玩家
                isMine = true
            end

            local targetPawn = nil
            if not recoverAllParty then
                if not isMine then
                    otherPlayerBagCount = otherPlayerBagCount + 1
                    return
                end
                targetPawn = hostPawn
            else
                -- 全队找回：优先按 GUID / 名字匹配在线队友，离线玩家背包交由房主代收
                if isMine then
                    targetPawn = hostPawn
                else
                    if ownerGuidKey ~= "" and guidToPawn[ownerGuidKey] then
                        targetPawn = guidToPawn[ownerGuidKey]
                    end
                    if (not safeValid(targetPawn)) and statics and ownerGuidKey ~= "" and ownerGuidRaw then
                        pcall(function()
                            local found = statics:GetPlayerCharacterFromPlayerGuid(gs, ownerGuidRaw)
                            if safeValid(found) then targetPawn = found end
                        end)
                    end
                    if (not safeValid(targetPawn)) and ownerNameLow ~= "" and nameToPawn[ownerNameLow] then
                        targetPawn = nameToPawn[ownerNameLow]
                    end
                    if not safeValid(targetPawn) then
                        targetPawn = hostPawn
                        offlineToHostCount = offlineToHostCount + 1
                    end
                end
            end

            local tAddr = targetPawn:GetAddress()
            if not targetGroups[tAddr] then
                targetGroups[tAddr] = { pawn = targetPawn, bags = {} }
                table.insert(targetGroupOrder, tAddr)
            end
            table.insert(targetGroups[tAddr].bags, bag)
        end)
    end

    -- 6. 对每位目标玩家的匹配背包，在其正前方地面按小扇形阵列错开落地
    local totalRecovered = 0
    for _, tAddr in ipairs(targetGroupOrder) do
        local grp = targetGroups[tAddr]
        local pawn = grp.pawn
        local bags = grp.bags
        if safeValid(pawn) and #bags > 0 then
            local pLoc = nil
            local fwdX, fwdY = 1.0, 0.0
            local rightX, rightY = 0.0, 1.0
            pcall(function() pLoc = pawn:K2_GetActorLocation() end)
            pcall(function()
                local f = pawn:GetActorForwardVector()
                if f then
                    local len2d = math.sqrt((f.X or 0) * (f.X or 0) + (f.Y or 0) * (f.Y or 0))
                    if len2d > 0.001 then
                        fwdX = f.X / len2d
                        fwdY = f.Y / len2d
                        rightX = -fwdY
                        rightY = fwdX
                    end
                end
            end)

            if pLoc then
                local totalForPlayer = #bags
                for idx, bag in ipairs(bags) do
                    local forwardDist = 135.0
                    local sideOffset = 0.0
                    if totalForPlayer > 1 then
                        -- 每排最多 5 个背包，左右间隔 65cm、前后排间距 70cm，避免碰撞箱重叠弹飞
                        local row = math.floor((idx - 1) / 5)
                        local col = (idx - 1) % 5
                        local rowCount = math.min(5, totalForPlayer - row * 5)
                        local centered = col - (rowCount - 1) * 0.5
                        forwardDist = 140.0 + row * 70.0
                        sideOffset = centered * 65.0
                    end

                    local destPos = {
                        X = (pLoc.X or 0) + fwdX * forwardDist + rightX * sideOffset,
                        Y = (pLoc.Y or 0) + fwdY * forwardDist + rightY * sideOffset,
                        Z = (pLoc.Z or 0) + 45.0, -- 略抬高 45cm 让背包自然落回地面，避免卡入地底
                    }
                    if teleportLootBagSafely(bag, destPos) then
                        totalRecovered = totalRecovered + 1
                    end
                end
            end
        end
    end

    -- 7. 生成清晰中文状态反馈（写入顶部状态栏与 UE4SS 控制台）
    if totalRecovered == 0 then
        if recoverAllParty then
            if skippedEmpty > 0 then
                lastStatusMessage = string.format("未发现非空玩家掉落背包（已自动跳过 %d 个空背包）", skippedEmpty)
            else
                lastStatusMessage = "当前世界未检测到任何可找回的玩家掉落背包"
            end
        else
            if otherPlayerBagCount > 0 then
                lastStatusMessage = string.format("未检测到属于你的掉落背包（另有 %d 个队友背包，可点“找回全队背包”）", otherPlayerBagCount)
            elseif skippedEmpty > 0 then
                lastStatusMessage = string.format("未发现属于你的非空掉落背包（已自动跳过 %d 个空背包）", skippedEmpty)
            else
                lastStatusMessage = "当前未检测到属于你的掉落背包"
            end
        end
    else
        if recoverAllParty then
            if offlineToHostCount > 0 then
                lastStatusMessage = string.format("已找回全队 %d 个掉落背包（其中 %d 个离线玩家背包已送至房主脚边）！",
                    totalRecovered, offlineToHostCount)
            else
                lastStatusMessage = string.format("已将全队 %d 个掉落背包各自瞬移到对应玩家正前方地面！", totalRecovered)
            end
        else
            lastStatusMessage = string.format("已将你的 %d 个掉落背包瞬移到正前方地面，按 E 即可拾取！", totalRecovered)
        end
    end

    logInfo(string.format("一键找回背包完成: mode=%s recovered=%d wokeLod=%d skippedEmpty=%d offlineToHost=%d -> %s",
        recoverAllParty and "all_party" or "self", totalRecovered, wokeLodCount, skippedEmpty, offlineToHostCount, lastStatusMessage))
end

-- ============================================================
-- 7. 功能四：“M” 地图乳牙、高级乳牙与全游戏资源目录扫描
-- ============================================================

--- 懒加载并缓存游戏核心 DataTable（AllItemsTable / HarvestNodesTable / CharactersTable / BestiaryTable）。
local function loadDataTables()
    local gi = UEHelpers.GetGameInstance()
    if safeValid(gi) and safeValid(gi.GlobalTableData) then
        local gtd = gi.GlobalTableData
        if safeValid(gtd.AllItemsTable) then cachedAllItemsTable = gtd.AllItemsTable end
        if safeValid(gtd.HarvestNodesTable) then cachedHarvestNodesTable = gtd.HarvestNodesTable end
        if safeValid(gtd.CharactersTable) then cachedCharactersTable = gtd.CharactersTable end
        if safeValid(gtd.BestiaryTable) then cachedBestiaryTable = gtd.BestiaryTable end
    end
    if not safeValid(cachedAllItemsTable) or not safeValid(cachedBestiaryTable) then
        local ok, gtd = pcall(FindFirstOf, "GlobalTableData")
        if ok and safeValid(gtd) then
            if safeValid(gtd.AllItemsTable) then cachedAllItemsTable = gtd.AllItemsTable end
            if safeValid(gtd.HarvestNodesTable) then cachedHarvestNodesTable = gtd.HarvestNodesTable end
            if safeValid(gtd.CharactersTable) then cachedCharactersTable = gtd.CharactersTable end
            if safeValid(gtd.BestiaryTable) then cachedBestiaryTable = gtd.BestiaryTable end
        end
    end
end

--- 从 TSoftClassPtr 提取干净的蓝图短类名（如 "/Game/.../BP_Bee.BP_Bee_C" -> "Bee"）。
local function extractSoftClassShortName(softCls)
    if not softCls then return "" end
    local softStr = ""
    pcall(function()
        if type(softCls) == "string" then
            softStr = softCls
        elseif softCls.AssetPathName then
            softStr = softCls.AssetPathName:ToString()
        elseif softCls.ToString then
            softStr = softCls:ToString()
        else
            softStr = tostring(softCls)
        end
    end)
    if softStr == "" or softStr == "None" then return "" end
    return cleanClassName(softStr)
end

--- 将蓝图/行名拆分为小写词元集合（支持下划线与驼峰拆分，如 Ant_HillWorker_Black -> {ant, hill, worker, black}）。
local function splitIdentTokens(s)
    local set = {}
    local list = {}
    if not s or s == "" then return set, list end
    local spaced = s:gsub("([a-z0-9])([A-Z])", "%1_%2"):lower()
    for tok in spaced:gmatch("[a-z0-9]+") do
        if not set[tok] then
            set[tok] = true
            table.insert(list, tok)
        end
    end
    return set, list
end

--- 剥离兜底显示名末尾的 " (ClassName)" 后缀，便于跨变体比对纯中文物种/采集点名。
local function stripClassFallbackSuffix(name)
    if not name or name == "" then return "" end
    local stripped = name:match("^(.-)%s*%([^%(%)]+%)$")
    if stripped and stripped ~= "" then
        return stripped
    end
    return name
end

--- 按生物蓝图类名从 CharactersTable 索引解析官方简体中文名（支持精确匹配、词元子集匹配与最长子串兜底）。
local function resolveCreatureZhName(actorClsShort, rowNameHint)
    local nk = normalizeKey(actorClsShort)
    if nk ~= "" and charTableByHint[nk] then
        return charTableByHint[nk]
    end
    if rowNameHint and rowNameHint ~= "" then
        local rnk = normalizeKey(rowNameHint)
        if rnk ~= "" and charTableByHint[rnk] then
            return charTableByHint[rnk]
        end
    end
    if actorClsShort and actorClsShort ~= "" and #charTableRows > 0 then
        -- 优先词元全包含匹配（如 Ant_HillWorker_Black 包含 {ant, black} -> 精准命中黑工蚁而非红工蚁）
        local clsTokSet = splitIdentTokens(actorClsShort)
        local bestTokCount = 0
        local bestNormLen = 0
        local bestZh = nil
        for _, row in ipairs(charTableRows) do
            if #row.tokens > 0 then
                local allMatch = true
                for _, tok in ipairs(row.tokens) do
                    if not clsTokSet[tok] then
                        allMatch = false
                        break
                    end
                end
                if allMatch then
                    if (#row.tokens > bestTokCount) or (#row.tokens == bestTokCount and #row.norm > bestNormLen) then
                        bestTokCount = #row.tokens
                        bestNormLen = #row.norm
                        bestZh = row.zh
                    end
                end
            end
        end
        if bestZh then
            return bestZh
        end
    end
    if nk ~= "" then
        -- 兜底选择最长连续子串匹配键
        local bestKeyLen = 0
        local bestVal = nil
        for k, v in pairs(charTableByHint) do
            if #k > bestKeyLen and (nk == k or nk:find(k, 1, true)) then
                bestKeyLen = #k
                bestVal = v
            end
        end
        if bestVal then
            return bestVal .. " (" .. actorClsShort .. ")"
        end
    end
    return actorClsShort
end

--- 统一计算某个目录/追踪词条（creature:/node:）对应的全部实时标点桶 ID（供目录计数汇总与 M 地图出点共用，保证列表计数与地图标点严格一致）。
-- @param tid        待匹配的词条 ID（如 creature:Ant_Black / creature:Bee / node:Rock_Clay）
-- @param trackedSet 若传入（M 地图渲染期），跳过已被玩家单独勾选的变体 ID 防止重复叠点；目录计数汇总期传 nil
-- @param buckets    世界实时标点桶（worldPinBuckets 或 refresh 期 newBuckets）
-- @param metaMap    目录元数据表（metaById 或 catalogMetaById）
local function collectMatchingBucketIds(tid, trackedSet, buckets, metaMap)
    local matched = {}
    if not tid or not buckets then return matched end
    if buckets[tid] and #buckets[tid] > 0 then
        table.insert(matched, tid)
    end

    if tid:sub(1, 9) == "creature:" then
        local baseCls = tid:sub(10)
        local baseClsLow = baseCls:lower()
        local baseMeta = metaMap and metaMap[tid] or nil
        local rawBaseName = (baseMeta and baseMeta.name)
            or (staticBestiaryCreatures[baseCls] and staticBestiaryCreatures[baseCls].zh)
            or resolveCreatureZhName(baseCls)
        local baseZh = stripClassFallbackSuffix(rawBaseName)
        local hasRealBaseZh = (baseZh ~= "" and baseZh ~= baseCls)
        local prefixLow = baseClsLow .. "_"
        -- 仅图鉴基础物种词条（如 creature:Ant_Black）按同种中文名汇总全部变体；
        -- 具体变体词条（如 creature:Ant_Black_UpperDeck）仅匹配自身及更细子前缀，避免拉入同种其他变体导致重复标点与重复计数。
        local isBaseCreature = (staticBestiaryCreatures[baseCls] ~= nil) or (next(staticBestiaryCreatures) == nil)

        for bId, bList in pairs(buckets) do
            if bId ~= tid and (not (trackedSet and trackedSet[bId])) and bId:sub(1, 9) == "creature:" and #bList > 0 then
                local liveCls = bId:sub(10)
                local liveClsLow = liveCls:lower()
                local liveZh = stripClassFallbackSuffix(bList[1].n or "")
                local hasRealLiveZh = (liveZh ~= "" and liveZh ~= liveCls)

                local sameSpeciesZh = isBaseCreature and hasRealBaseZh and hasRealLiveZh and (liveZh == baseZh)
                local samePrefix = (liveClsLow:sub(1, #prefixLow) == prefixLow)
                    and ((not hasRealBaseZh) or (not hasRealLiveZh) or (liveZh == baseZh))
                if sameSpeciesZh or samePrefix then
                    table.insert(matched, bId)
                end
            end
        end
    elseif tid:sub(1, 5) == "node:" then
        local baseKey = tid:sub(6)
        local baseKeyLow = baseKey:lower()
        local baseNorm = normalizeKey(baseKey)
        local baseMeta = metaMap and metaMap[tid] or nil
        local rawBaseName = (baseMeta and baseMeta.name)
            or (staticHarvestNodes[baseKey] and staticHarvestNodes[baseKey].zh)
            or fallbackNodeZh(baseKey)
        local baseZh = stripClassFallbackSuffix(rawBaseName)
        local hasRealBaseZh = (baseZh ~= "" and baseZh ~= baseKey)
        local prefixLow = baseKeyLow .. "_"
        -- 仅数据表基础采集点词条（如 node:Rock_Clay）按中文名/归一化键汇总同族变体；具体变体仅匹配自身及子前缀。
        local isBaseNode = (staticHarvestNodes[baseKey] ~= nil) or (next(staticHarvestNodes) == nil)

        for bId, bList in pairs(buckets) do
            if bId ~= tid and (not (trackedSet and trackedSet[bId])) and bId:sub(1, 5) == "node:" and #bList > 0 then
                local liveKey = bId:sub(6)
                local liveKeyLow = liveKey:lower()
                local liveNorm = normalizeKey(liveKey)
                local liveZh = stripClassFallbackSuffix(bList[1].n or "")
                local hasRealLiveZh = (liveZh ~= "" and liveZh ~= liveKey)

                local samePrefix = (liveKeyLow:sub(1, #prefixLow) == prefixLow)
                local normHit = isBaseNode and (baseNorm ~= "" and (liveNorm == baseNorm or liveNorm:find(baseNorm, 1, true) ~= nil))
                local zhHit = isBaseNode and hasRealBaseZh and hasRealLiveZh and (liveZh == baseZh)
                if samePrefix or normHit or zhHit then
                    table.insert(matched, bId)
                end
            end
        end
    end
    return matched
end

--- 从游戏数据表一次性构建简体中文译名索引、真实原版资源扫描仪支持列表，以及客机可用的全图鉴静态生物/采集点索引。
local function loadTableTranslations()
    loadDataTables()
    local statics = getSurvivalStatics()

    -- 1. AllItemsTable -> 官方简体中文物品名 + 真实自然资源可扫描标记（仅限真正带有 Resource.Natural 标签的自然物品，绝不再用 itemType == 0 误标武器/护甲/食谱）
    if next(itemRowToZhName) == nil and safeValid(cachedAllItemsTable) then
        pcall(function()
            cachedAllItemsTable:ForEachRow(function(rowName, rowData)
                local wasCut = 0
                pcall(function() wasCut = rowData.bWasCut or 0 end)
                if wasCut ~= 0 then return end

                local zh = ""
                pcall(function() zh = locStringToZh(rowData.LocalizedDisplayName) end)
                -- 过滤引擎内部占位/无效词条（如 Invalid -1 / ???? / Debug）
                if zh == "" or zh:find("Invalid %-1") or zh:find("%?%?%?") or rowName:find("^Debug") or rowName == "UnknownItem" then
                    return
                end
                itemRowToZhName[rowName] = zh

                -- 仅真正属于自然资源的物品才支持游戏原版资源扫描仪热区（与 UResourceSurveyComponent::GetSurveyableItems 一致）
                local isNat = false
                if statics then
                    pcall(function()
                        isNat = (statics:IsNaturalResource({ DataTable = cachedAllItemsTable, RowName = FName(rowName) }) == true)
                    end)
                end
                if isNat then
                    surveyableRows[rowName] = true
                end
            end)
        end)
    end

    -- 2. HarvestNodesTable -> 官方简体中文采集点名索引 + 静态采集点目录（供客机预勾选）
    if next(harvestTableByHint) == nil and safeValid(cachedHarvestNodesTable) then
        pcall(function()
            cachedHarvestNodesTable:ForEachRow(function(rowName, rowData)
                if not rowName or rowName == "" or rowName:find("^Debug") or rowName:find("^Test") then return end
                local zh = ""
                pcall(function() zh = locStringToZh(rowData.DisplayName) end)
                if zh ~= "" and not zh:find("Invalid %-1") and not zh:find("%?%?%?") then
                    harvestTableByHint[normalizeKey(rowName)] = zh
                    staticHarvestNodes[rowName] = { rowName = rowName, zh = zh }
                end
            end)
        end)
    end

    -- 3. CharactersTable -> 官方简体中文生物名索引（同时建立词元表用于跨命名变体精准匹配，如 Ant_HillWorker_Black -> 黑工蚁）
    if next(charTableByHint) == nil and safeValid(cachedCharactersTable) then
        pcall(function()
            cachedCharactersTable:ForEachRow(function(rowName, rowData)
                local zh = ""
                pcall(function() zh = locStringToZh(rowData.CharacterName) end)
                if zh ~= "" and not zh:find("Invalid %-1") and not zh:find("%?%?%?") then
                    local nk = normalizeKey(rowName)
                    charTableByHint[nk] = zh
                    local _, tokList = splitIdentTokens(rowName)
                    table.insert(charTableRows, { norm = nk, tokens = tokList, zh = zh })
                end
            end)
        end)
    end

    -- 4. BestiaryTable -> 全游戏生物图鉴静态类名与中文名（保证联机客机列表完整包含蜜蜂、幼虫、黑工蚁等全部生物）
    if next(staticBestiaryCreatures) == nil and safeValid(cachedBestiaryTable) then
        pcall(function()
            cachedBestiaryTable:ForEachRow(function(rowName, rowData)
                if not rowName or rowName == "" or rowName:find("^Debug") or rowName:find("^Test") then return end
                local clsShort = extractSoftClassShortName(rowData.Creature)
                if clsShort == "" then
                    clsShort = cleanClassName(rowName)
                end
                if clsShort == "" or clsShort == "None" then return end
                local low = clsShort:lower()
                if low:find("debug") or low:find("test") or low:find("player") then return end
                local zh = resolveCreatureZhName(clsShort, rowName)
                staticBestiaryCreatures[clsShort] = {
                    clsShort = clsShort,
                    zh = zh,
                    rowName = rowName,
                }
            end)
        end)
    end
end

local cachedHealthLodClass = nil
local knownCatalogMeta = {}
local noFoliageRows = {}
local cachedWorldIsms = nil
local lastCatalogWriteClock = 0
local lastCatalogRefreshClock = -100.0

--- 判断 LODActor 或其实体是否已死亡、被摧毁或正在销毁（确保击杀昆虫/挖掉矿点后标点立刻消失）。
local function isLodDeadOrInvalid(lod, fullActor, healthLodCls)
    local isDead = false
    -- 1. LOD 层检测（即使玩家在地图另一端未加载 FullActor，也能准确识别死亡/已摧毁状态）
    if safeValid(healthLodCls) then
        pcall(function()
            local hLod = lod:GetComponentByClass(healthLodCls)
            if safeValid(hLod) and hLod:IsDead() then
                isDead = true
            end
        end)
    else
        pcall(function()
            local comps = lod.LODComponents
            if comps then
                for k = 1, #comps do
                    local c = comps[k]
                    if safeValid(c) and c:GetClass():GetFName():ToString() == "HealthLODComponent" then
                        if c:IsDead() then
                            isDead = true
                        end
                        break
                    end
                end
            end
        end)
    end
    if isDead then return true end

    -- 2. FullActor 实体层检测（近处已加载时，拦截刚死亡尸体、已打碎采集点与待销毁对象）
    if safeValid(fullActor) then
        pcall(function()
            if fullActor:IsActorBeingDestroyed() then
                isDead = true
            end
        end)
        if isDead then return true end

        pcall(function()
            local hc = fullActor.HealthComponent
            if safeValid(hc) then
                if hc:IsDead() or hc:GetHealthState() == 2 then
                    isDead = true
                end
            end
        end)
    end
    return isDead
end

--- 扫描全图固定收集品（乳牙/高级乳牙/SCA.B）与全部存活 LOD 实体，更新内存标点桶并按需写出 catalog.json。
-- @param writeCatalogFile 是否将排序后的资源目录原子写入 data/catalog.json 供 C++ 菜单展示
-- @param quietLog         是否静默日志（定时增量刷新时设为 true 避免刷屏）
local function refreshWorldCatalogAndPins(writeCatalogFile, quietLog)
    local gs = cachedGameState
    if not safeValid(gs) then
        local okGs, found = pcall(FindFirstOf, "SurvivalGameState")
        if okGs and safeValid(found) then
            gs = found
            cachedGameState = found
        end
    end
    if not safeValid(gs) then return false end
    lastCatalogRefreshClock = os.clock()

    loadTableTranslations()
    -- 合并原版 ResourceSurveyComponent:GetSurveyableItems() 返回的官方可扫描集合，确保与游戏扫描仪严格对齐
    pcall(function()
        local rsc = gs.ResourceSurveyComponent
        if safeValid(rsc) and rsc.GetSurveyableItems then
            local survList = rsc:GetSurveyableItems()
            if survList then
                for i = 1, #survList do
                    local h = survList[i]
                    local rn = ""
                    pcall(function()
                        if h and h.RowName then rn = h.RowName:ToString() end
                    end)
                    if rn ~= "" and rn ~= "None" and itemRowToZhName[rn] then
                        surveyableRows[rn] = true
                    end
                end
            end
        end
    end)
    if not safeValid(cachedHealthLodClass) then
        pcall(function()
            local cls = StaticFindObject("/Script/Maine.HealthLODComponent")
            if safeValid(cls) then cachedHealthLodClass = cls end
        end)
    end

    -- A. 刷新全部乳牙、高级乳牙、SCA.B 收集品（SurvivalGameState.TrackedCollectibles）
    local newCollectibles = {}
    local unMilk, totMilk, unMega, totMega = 0, 0, 0, 0
    local seenMolarPos = {}

    local function addCollectibleEntry(cType, cState, x, y, z)
        local key = string.format("%d_%d_%d", cType, math.floor(x / 200 + 0.5), math.floor(y / 200 + 0.5))
        if seenMolarPos[key] then return end
        seenMolarPos[key] = true

        local isCollected = (cState == 2)
        if cType == 2 then
            totMilk = totMilk + 1
            if not isCollected then unMilk = unMilk + 1 end
        elseif cType == 3 then
            totMega = totMega + 1
            if not isCollected then unMega = unMega + 1 end
        end

        table.insert(newCollectibles, {
            type = cType,
            collected = isCollected,
            x = x, y = y, z = z,
        })
    end

    pcall(function()
        local tc = gs.TrackedCollectibles
        if tc then
            local n = #tc
            for i = 1, n do
                local item = tc[i]
                if item and (item.bHiddenForThisNewGameLoop or 0) == 0 then
                    local t = item.Type or 0
                    if t == 1 or t == 2 or t == 3 then
                        local pos = item.WorldPos
                        if pos then
                            addCollectibleEntry(t, item.State or 0, pos.X or 0, pos.Y or 0, pos.Z or 0)
                        end
                    end
                end
            end
        end
    end)

    -- B. 遍历全图 LODActorManagerComponent.LODActors
    local newBuckets = {}
    local metaById = {}

    local function pushPin(id, name, rawName, category, x, y, z, surveyable, rowName)
        local b = newBuckets[id]
        if not b then
            b = {}
            newBuckets[id] = b
            metaById[id] = {
                id = id,
                name = name,
                rawName = rawName,
                category = category,
                count = 0,
                surveyable = surveyable or false,
                rowName = rowName or "",
            }
        end
        table.insert(b, { x = x, y = y, z = z, n = name, cat = category })
        metaById[id].count = #b
    end

    pcall(function()
        local mgr = gs.LODActorManagerComponent
        if not safeValid(mgr) then return end
        local lods = mgr.LODActors
        if not lods then return end
        local n = #lods

        for i = 1, n do
            local lod = lods[i]
            if safeValid(lod) then
                pcall(function()
                    local loc = lod:GetActorLocation()
                    if not loc then return end
                    local x, y, z = loc.X or 0, loc.Y or 0, loc.Z or 0
                    if x == 0 and y == 0 and z == 0 then return end

                    local lodClassName = lod:GetClass():GetFName():ToString()
                    local actorClsShort = ""
                    local fullActor = nil
                    pcall(function() fullActor = lod.FullActor end)

                    -- 过滤已死亡的生物尸体、已挖碎的采集点与正在销毁的实体，确保击杀/采集后标点立刻消失
                    if isLodDeadOrInvalid(lod, fullActor, cachedHealthLodClass) then
                        return
                    end

                    if safeValid(fullActor) then
                        actorClsShort = cleanClassName(fullActor:GetClass():GetFName():ToString())
                    else
                        pcall(function()
                            local hardCls = lod:GetActorClassHard()
                            if safeValid(hardCls) then
                                actorClsShort = cleanClassName(hardCls:GetFName():ToString())
                            end
                        end)
                        if actorClsShort == "" then
                            pcall(function()
                                local softCls = lod:GetActorClassSoft()
                                if softCls then
                                    local softStr = ""
                                    if type(softCls) == "string" then
                                        softStr = softCls
                                    elseif softCls.AssetPathName then
                                        softStr = softCls.AssetPathName:ToString()
                                    elseif softCls.ToString then
                                        softStr = softCls:ToString()
                                    else
                                        softStr = tostring(softCls)
                                    end
                                    if softStr and softStr ~= "" and softStr ~= "None" then
                                        actorClsShort = cleanClassName(softStr)
                                    end
                                end
                            end)
                        end
                    end
                    local lowCls = actorClsShort:lower()

                    -- 1. 乳牙 / 高级乳牙 / SCA.B 兜底补充
                    if lowCls:find("milk_nugget_party") then
                        addCollectibleEntry(3, 0, x, y, z)
                        return
                    elseif lowCls:find("milk_nugget_personal") or lodClassName == "UpgradeCollectibleLODActor" then
                        addCollectibleEntry(2, 0, x, y, z)
                        return
                    elseif lodClassName == "ColorCollectibleLODActor" then
                        addCollectibleEntry(1, 0, x, y, z)
                        return
                    end

                    -- 2. 原始科学点
                    if lodClassName == "ScienceCollectableLODActor" then
                        pushPin("special:RawScience", "原始科学点 (Raw Science)", "RawScience", "special", x, y, z, false, "")
                        return
                    end

                    -- 3. 散落世界物品（官方中文名，排除已被拾取/拿在手里的装备与隐藏对象）
                    if lodClassName == "SpawnedItemLODActor" or lodClassName == "SpawnedItemDropletLODActor" then
                        if safeValid(fullActor) then
                            local skipItem = false
                            pcall(function()
                                if safeValid(fullActor.EquippedOwner) or fullActor:IsHidden() then
                                    skipItem = true
                                end
                            end)
                            if skipItem then return end
                        end
                        local itemObj = nil
                        pcall(function() itemObj = lod:GetItem() end)
                        if safeValid(itemObj) then
                            local stackCnt = 1
                            pcall(function() stackCnt = itemObj.StackSize or 1 end)
                            if stackCnt <= 0 then return end
                            local rn = ""
                            pcall(function() rn = itemObj.ItemDataRowHandle.RowName:ToString() end)
                            if rn ~= "" and rn ~= "None" then
                                local zh = itemRowToZhName[rn]
                                if not zh or zh == "" then
                                    pcall(function() zh = itemObj:GetDisplayName():ToString() end)
                                end
                                if not zh or zh == "" then zh = rn end
                                pushPin("item:" .. rn, zh, rn, "item", x, y, z, surveyableRows[rn] == true, rn)
                            end
                        end
                        return
                    end

                    -- 4. 生物 / 昆虫（GetCharacterTypeName 返回 FLocString，转为官方简体中文名）
                    if lodClassName == "CreatureLODActor" then
                        if actorClsShort == "" then actorClsShort = "Creature" end
                        local zh = creatureClassToZhName[actorClsShort]
                        if not zh then
                            pcall(function()
                                local ls = lod:GetCharacterTypeName()
                                local s = locStringToZh(ls)
                                if s ~= "" then zh = s end
                            end)
                            if (not zh or zh == "") then
                                zh = resolveCreatureZhName(actorClsShort)
                            end
                            if not zh or zh == "" then zh = actorClsShort end
                            creatureClassToZhName[actorClsShort] = zh
                        end
                        pushPin("creature:" .. actorClsShort, zh, actorClsShort, "creature", x, y, z, false, "")
                        return
                    end

                    -- 5. 采集点 / 矿石 / 糖果 / 浆果 / 橡果
                    if lodClassName == "HarvestNodeLODActor" then
                        if actorClsShort == "" then return end
                        local zh = nodeClassToZhName[actorClsShort]
                        local dropRows = nodeClassToDropRows[actorClsShort]
                        if not zh then
                            if safeValid(fullActor) then
                                pcall(function()
                                    local d = locStringToZh(fullActor.DisplayName)
                                    if d ~= "" then zh = d end
                                end)
                                pcall(function()
                                    local lc = fullActor.LootComponent
                                    if safeValid(lc) and lc.Items then
                                        dropRows = {}
                                        for k = 1, #lc.Items do
                                            local it = lc.Items[k]
                                            if it and it.Type == 0 then
                                                local drn = it.ItemData.RowName:ToString()
                                                if drn and drn ~= "None" then
                                                    table.insert(dropRows, drn)
                                                end
                                            end
                                        end
                                        nodeClassToDropRows[actorClsShort] = dropRows
                                    end
                                end)
                            end
                            if (not zh or zh == "") and dropRows and #dropRows > 0 then
                                local dzh = itemRowToZhName[dropRows[1]]
                                if dzh and dzh ~= "" then zh = dzh .. " (采集点)" end
                            end
                            if not zh or zh == "" then
                                zh = fallbackNodeZh(actorClsShort)
                            end
                            nodeClassToZhName[actorClsShort] = zh
                        end
                        local primaryRow = (dropRows and dropRows[1]) or ""
                        local isSurv = (primaryRow ~= "" and surveyableRows[primaryRow] == true)
                        pushPin("node:" .. actorClsShort, zh, actorClsShort, "node", x, y, z, isSurv, primaryRow)

                        if dropRows then
                            for _, drn in ipairs(dropRows) do
                                local dzh = itemRowToZhName[drn] or drn
                                pushPin("item:" .. drn, dzh, drn, "item", x, y, z, surveyableRows[drn] == true, drn)
                            end
                        end
                        return
                    end

                    -- 6. 实验室宝箱 / 补给箱（若近处已加载且已被搬空则自动隐藏）
                    if lowCls:find("ominent_chest") or lowCls:find("treasure") then
                        if safeValid(fullActor) then
                            local isEmpty = false
                            pcall(function()
                                local inv = fullActor.InventoryComponent
                                if safeValid(inv) and inv.Items and #inv.Items == 0 then
                                    isEmpty = true
                                end
                            end)
                            if isEmpty then return end
                        end
                        pushPin("special:OminentChest", "Ominent 宝箱 / 补给箱", actorClsShort, "special", x, y, z, false, "")
                        return
                    end
                end)
            end
        end
    end)

    -- B2. 多人联机客机本地多源兜底扫描（ADR-0004 / Q8）：
    -- Grounded 的 LODActorManagerComponent.LODActors 为房主独占、客机端为空；
    -- 当检测到客机（HasAuthority()==false）或 LODActors 未产出任何标点时，直接扫描客机本地已加载/网络同步范围内的
    -- 真实世界实体与全图原生同步植被（ISM），与房主使用完全一致的 ID 规范（node:/creature:/item:/special:），
    -- 保持主客机独立追踪互不共享、乳牙全队共享且零联机协议风险。
    local isHostNow = true
    pcall(function() isHostNow = (gs:HasAuthority() == true) end)
    local hasAnyLodBucket = (next(newBuckets) ~= nil)
    if (not isHostNow) or (not hasAnyLodBucket) then
        local seenClientActors = {}
        local function isLiveWorldActor(act)
            if not safeValid(act) then return false end
            local addr = act:GetAddress()
            if seenClientActors[addr] then return false end
            local fullName = ""
            pcall(function() fullName = act:GetFullName() end)
            if isTemplateOrCdoName(fullName) then return false end
            local bad = false
            pcall(function()
                if act.IsActorBeingDestroyed and act:IsActorBeingDestroyed() == true then bad = true end
                if (not bad) and act.IsHidden and act:IsHidden() == true then bad = true end
            end)
            if bad then return false end
            pcall(function()
                local hc = act.HealthComponent
                if safeValid(hc) then
                    if (hc.IsDead and hc:IsDead() == true) or (hc.GetHealthState and hc:GetHealthState() == 2) then
                        bad = true
                    end
                end
            end)
            if bad then return false end
            seenClientActors[addr] = true
            return true
        end

        local function getActorPosSafe(act)
            local loc = nil
            pcall(function() loc = act:K2_GetActorLocation() end)
            if not loc then return nil end
            local x, y, z = loc.X or 0, loc.Y or 0, loc.Z or 0
            if x == 0 and y == 0 and z == 0 then return nil end
            return x, y, z
        end

        -- 1) 客机可见采集点 / 矿石 / 橡果 / 糖果 / 浆果
        pcall(function()
            local nodes = FindAllOf("HarvestNode")
            if not nodes then return end
            for _, node in ipairs(nodes) do
                if isLiveWorldActor(node) then
                    pcall(function()
                        local x, y, z = getActorPosSafe(node)
                        if not x then return end
                        local actorClsShort = cleanClassName(node:GetClass():GetFName():ToString())
                        if actorClsShort == "" then return end
                        local lowCls = actorClsShort:lower()
                        if lowCls:find("milk_nugget_party") then
                            addCollectibleEntry(3, 0, x, y, z)
                            return
                        elseif lowCls:find("milk_nugget_personal") then
                            addCollectibleEntry(2, 0, x, y, z)
                            return
                        end

                        local zh = nodeClassToZhName[actorClsShort]
                        local dropRows = nodeClassToDropRows[actorClsShort]
                        if not zh then
                            pcall(function()
                                local d = locStringToZh(node.DisplayName)
                                if d ~= "" then zh = d end
                            end)
                            pcall(function()
                                local lc = node.LootComponent
                                if safeValid(lc) and lc.Items then
                                    dropRows = {}
                                    for k = 1, #lc.Items do
                                        local it = lc.Items[k]
                                        if it and it.Type == 0 then
                                            local drn = it.ItemData.RowName:ToString()
                                            if drn and drn ~= "None" then
                                                table.insert(dropRows, drn)
                                            end
                                        end
                                    end
                                    nodeClassToDropRows[actorClsShort] = dropRows
                                end
                            end)
                            if (not zh or zh == "") and dropRows and #dropRows > 0 then
                                local dzh = itemRowToZhName[dropRows[1]]
                                if dzh and dzh ~= "" then zh = dzh .. " (采集点)" end
                            end
                            if not zh or zh == "" then
                                zh = fallbackNodeZh(actorClsShort)
                            end
                            nodeClassToZhName[actorClsShort] = zh
                        end
                        local primaryRow = (dropRows and dropRows[1]) or ""
                        local isSurv = (primaryRow ~= "" and surveyableRows[primaryRow] == true)
                        pushPin("node:" .. actorClsShort, zh, actorClsShort, "node", x, y, z, isSurv, primaryRow)
                        if dropRows then
                            for _, drn in ipairs(dropRows) do
                                local dzh = itemRowToZhName[drn] or drn
                                pushPin("item:" .. drn, dzh, drn, "item", x, y, z, surveyableRows[drn] == true, drn)
                            end
                        end
                    end)
                end
            end
        end)

        -- 2) 客机可见生物 / 昆虫（存活）
        pcall(function()
            local creatures = FindAllOf("SurvivalCreature")
            if not creatures then return end
            for _, cr in ipairs(creatures) do
                if isLiveWorldActor(cr) then
                    pcall(function()
                        local x, y, z = getActorPosSafe(cr)
                        if not x then return end
                        local actorClsShort = cleanClassName(cr:GetClass():GetFName():ToString())
                        if actorClsShort == "" then actorClsShort = "Creature" end
                        local zh = creatureClassToZhName[actorClsShort]
                        if not zh then
                            pcall(function()
                                if cr.GetCharacterTypeName then
                                    local s = locStringToZh(cr:GetCharacterTypeName())
                                    if s ~= "" then zh = s end
                                end
                            end)
                            if not zh or zh == "" then
                                zh = resolveCreatureZhName(actorClsShort)
                            end
                            if not zh or zh == "" then zh = actorClsShort end
                            creatureClassToZhName[actorClsShort] = zh
                        end
                        pushPin("creature:" .. actorClsShort, zh, actorClsShort, "creature", x, y, z, false, "")
                    end)
                end
            end
        end)

        -- 3) 客机可见散落世界物品（排除拿在手里的装备）
        pcall(function()
            local spawned = FindAllOf("SpawnedItem")
            if not spawned then return end
            for _, si in ipairs(spawned) do
                if isLiveWorldActor(si) then
                    pcall(function()
                        if safeValid(si.EquippedOwner) then return end
                        local x, y, z = getActorPosSafe(si)
                        if not x then return end
                        local itemObj = nil
                        pcall(function() itemObj = si:GetItem() end)
                        if not safeValid(itemObj) then return end
                        local stackCnt = 1
                        pcall(function() stackCnt = itemObj.StackSize or 1 end)
                        if stackCnt <= 0 then return end
                        local rn = ""
                        pcall(function() rn = itemObj.ItemDataRowHandle.RowName:ToString() end)
                        if rn ~= "" and rn ~= "None" then
                            local zh = itemRowToZhName[rn]
                            if not zh or zh == "" then
                                pcall(function() zh = itemObj:GetDisplayName():ToString() end)
                            end
                            if not zh or zh == "" then zh = rn end
                            pushPin("item:" .. rn, zh, rn, "item", x, y, z, surveyableRows[rn] == true, rn)
                        end
                    end)
                end
            end
        end)

        -- 4) 客机可见原始科学点
        pcall(function()
            local scis = FindAllOf("ScienceCollectable")
            if not scis then return end
            for _, sc in ipairs(scis) do
                if isLiveWorldActor(sc) then
                    pcall(function()
                        local x, y, z = getActorPosSafe(sc)
                        if x then
                            pushPin("special:RawScience", "原始科学点 (Raw Science)", "RawScience", "special", x, y, z, false, "")
                        end
                    end)
                end
            end
        end)

        -- 5) 客机可见非空 Ominent 宝箱 / 补给箱
        pcall(function()
            local bags = FindAllOf("LootBag")
            if not bags then return end
            for _, bag in ipairs(bags) do
                if isLiveWorldActor(bag) then
                    pcall(function()
                        local actorClsShort = cleanClassName(bag:GetClass():GetFName():ToString())
                        local lowCls = actorClsShort:lower()
                        if not (lowCls:find("ominent_chest") or lowCls:find("treasure")) then return end
                        local inv = bag.InventoryComponent
                        if safeValid(inv) and inv.Items and #inv.Items == 0 then return end
                        local x, y, z = getActorPosSafe(bag)
                        if x then
                            pushPin("special:OminentChest", "Ominent 宝箱 / 补给箱", actorClsShort, "special", x, y, z, false, "")
                        end
                    end)
                end
            end
        end)

        -- 6) 客机全图植被资源目录充实（只读查询，绝不修改 FoliageMappings；让全图植被在目录中显示真实可用状态）
        pcall(function()
            local gi = UEHelpers.GetGameInstance()
            if not safeValid(gi) then return end
            if not cachedWorldIsms then
                cachedWorldIsms = FindAllOf("InstancedStaticMeshComponent") or {}
            end
            local meshAliveCounts = {}
            for _, ism in ipairs(cachedWorldIsms) do
                if safeValid(ism) and ism.StaticMesh and safeValid(ism.StaticMesh) then
                    local vis = true
                    pcall(function() vis = ism:IsVisible() end)
                    if vis then
                        local ic = 0
                        pcall(function() ic = ism:GetInstanceCount() end)
                        if ic > 0 then
                            local ma = ism.StaticMesh:GetAddress()
                            meshAliveCounts[ma] = (meshAliveCounts[ma] or 0) + ic
                        end
                    end
                end
            end
            if next(meshAliveCounts) ~= nil and safeValid(cachedAllItemsTable) and gi.GetFoliageMeshesFromItemHandle then
                for rn, _ in pairs(surveyableRows) do
                    if not noFoliageRows[rn] then
                        pcall(function()
                            local meshes = gi:GetFoliageMeshesFromItemHandle({ DataTable = cachedAllItemsTable, RowName = FName(rn) }, false)
                            if meshes and #meshes > 0 then
                                local totalInst = 0
                                for k = 1, #meshes do
                                    local m = meshes[k]
                                    if safeValid(m) then
                                        totalInst = totalInst + (meshAliveCounts[m:GetAddress()] or 0)
                                    end
                                end
                                if totalInst > 0 then
                                    local itemId = "item:" .. rn
                                    local zh = itemRowToZhName[rn] or rn
                                    local approxDisplay = math.min(240, totalInst)
                                    if not metaById[itemId] then
                                        metaById[itemId] = {
                                            id = itemId,
                                            name = zh,
                                            rawName = rn,
                                            category = "item",
                                            count = approxDisplay,
                                            surveyable = true,
                                            rowName = rn,
                                        }
                                    elseif metaById[itemId].count < approxDisplay then
                                        metaById[itemId].count = approxDisplay
                                        if metaById[itemId].category == "survey" then
                                            metaById[itemId].category = "item"
                                        end
                                    end
                                end
                            else
                                noFoliageRows[rn] = true
                            end
                        end)
                    end
                end
            end
        end)
    end

    -- B3. 静态全图鉴目录补全（修复联机客机缺少蜜蜂、幼虫、黑工蚁等远距生物/采集点的问题）：
    -- 房主的 LODActors 覆盖全图，而客机端仅能感知网络同步半径（约 50~150m）内的实体；
    -- 从客机本地静态 DataTable（BestiaryTable / HarvestNodesTable）补全全游戏生物与采集点词条（初始 count=0），
    -- 客机随时可搜索并预勾选，靠近同步范围后实时标点会自动出现，零联机协议修改。
    for clsShort, info in pairs(staticBestiaryCreatures) do
        local cid = "creature:" .. clsShort
        if not metaById[cid] then
            metaById[cid] = {
                id = cid,
                name = info.zh,
                rawName = clsShort,
                category = "creature",
                count = 0,
                surveyable = false,
                rowName = "",
            }
        end
    end

    if (not isHostNow) or (not hasAnyLodBucket) then
        -- 客机端补充静态采集点词条（去重：若已有同名或同归一化键的实时 node: 词条则不重复生成）
        local existingNodeZh = {}
        local existingNodeNorm = {}
        for id, m in pairs(metaById) do
            if m.category == "node" then
                existingNodeZh[m.name] = true
                existingNodeNorm[normalizeKey(m.rawName)] = true
            end
        end
        for rowName, info in pairs(staticHarvestNodes) do
            local nk = normalizeKey(rowName)
            local nid = "node:" .. rowName
            if (not metaById[nid]) and (not existingNodeZh[info.zh]) and (not existingNodeNorm[nk]) then
                metaById[nid] = {
                    id = nid,
                    name = info.zh,
                    rawName = rowName,
                    category = "node",
                    count = 0,
                    surveyable = false,
                    rowName = "",
                }
            end
        end
    end

    -- 记录本存档已知的全部词条：即使某生物/资源暂时被全部清光（count=0 等待重生），
    -- 仍保留在菜单列表中供取消勾选，且重生后会立刻自动恢复标点与数量。
    for id, m in pairs(metaById) do
        knownCatalogMeta[id] = {
            id = m.id,
            name = m.name,
            rawName = m.rawName,
            category = m.category,
            surveyable = m.surveyable,
            rowName = m.rowName,
        }
    end
    for id, km in pairs(knownCatalogMeta) do
        if not metaById[id] then
            metaById[id] = {
                id = km.id,
                name = km.name,
                rawName = km.rawName,
                category = km.category,
                count = 0,
                surveyable = km.surveyable,
                rowName = km.rowName,
            }
        end
    end

    -- C. 将所有真实支持原版扫描仪的自然资源物品补全到目录（确保全游戏所有自然资源都能中文搜索并安全联动原版扫描热区）
    for rn, _ in pairs(surveyableRows) do
        local itemId = "item:" .. rn
        local zh = itemRowToZhName[rn] or rn
        if not metaById[itemId] then
            metaById[itemId] = {
                id = itemId,
                name = zh,
                rawName = rn,
                category = "survey",
                count = 0,
                surveyable = true,
                rowName = rn,
            }
        else
            metaById[itemId].surveyable = true
            metaById[itemId].rowName = rn
        end
    end

    -- D. 统一用 collectMatchingBucketIds 汇总生物与采集点词条的真实匹配标点数，
    -- 确保如预勾选「蜜蜂(creature:Bee)」时若周边存在 Bee_HiveWorker，目录计数同步更新为 1 处而非继续显示“范围内 0 处”。
    for id, m in pairs(metaById) do
        if m.category == "creature" or m.category == "node" then
            local matchedIds = collectMatchingBucketIds(id, nil, newBuckets, metaById)
            local totalMatched = 0
            for _, bId in ipairs(matchedIds) do
                local bList = newBuckets[bId]
                if bList then totalMatched = totalMatched + #bList end
            end
            m.count = totalMatched
        end
    end

    -- 检测目录条目集或任意实时计数是否相对上次发生变化：
    -- 当 M 地图持续开启且生物/采集点进出客机同步范围时，仅在计数或词条实际变更时自动同步写出 catalog.json，
    -- 既保持零无意义磁盘写入，又彻底消除“地图已有标点但列表仍显示 0”的同步滞后。
    local catalogChanged = false
    for id, m in pairs(metaById) do
        local prev = catalogMetaById[id]
        if (not prev) or prev.count ~= m.count or prev.name ~= m.name
            or prev.surveyable ~= m.surveyable or prev.category ~= m.category then
            catalogChanged = true
            break
        end
    end
    if not catalogChanged then
        for id, _ in pairs(catalogMetaById) do
            if not metaById[id] then
                catalogChanged = true
                break
            end
        end
    end

    collectiblePins = newCollectibles
    worldPinBuckets = newBuckets
    catalogMetaById = metaById
    molarStats = { unMilk = unMilk, totMilk = totMilk, unMega = unMega, totMega = totMega }

    if writeCatalogFile or catalogChanged then
        local list = {}
        for _, m in pairs(metaById) do
            table.insert(list, m)
        end
        local catOrder = { special = 1, node = 2, item = 3, creature = 4, survey = 5 }
        table.sort(list, function(a, b)
            local oa = catOrder[a.category] or 9
            local ob = catOrder[b.category] or 9
            if oa ~= ob then return oa < ob end
            if a.count ~= b.count then return a.count > b.count end
            return a.name < b.name
        end)
        catalogList = list
        local encodedCatalog = json.encode(json.array(list))
        if writeCatalogFile or encodedCatalog ~= lastCatalogJson then
            lastCatalogWriteClock = os.clock()
            lastCatalogJson = encodedCatalog
            writeAtomicText(CATALOG_PATH, encodedCatalog)
        end
        if not quietLog then
            logInfo(string.format("已生成全图资源目录: %d 项 | 未采普通乳牙 %d/%d, 未采高级乳牙 %d/%d",
                #list, unMilk, totMilk, unMega, totMega))
        end
    end
    return true
end

--- 动态查询存活的植被实例（草、三叶草、蒲公英、树枝、植物纤维、鹅卵石、树液等），自动过滤已采集项并在重生后自动恢复。
local function getFoliagePinsForRow(rowName, now, forceRefresh)
    if noFoliageRows[rowName] then return {} end
    local cached = foliagePinCache[rowName]
    if cached and (not forceRefresh) and ((now - cached.clock) < 6.0) then
        return cached.pins
    end

    local pins = {}
    if not safeValid(cachedAllItemsTable) then return pins end

    pcall(function()
        local gi = UEHelpers.GetGameInstance()
        if not safeValid(gi) then return end
        local handle = { DataTable = cachedAllItemsTable, RowName = FName(rowName) }
        local meshes = gi:GetFoliageMeshesFromItemHandle(handle, false)
        if not meshes or #meshes == 0 then
            noFoliageRows[rowName] = true
            return
        end

        local targetMeshSet = {}
        for i = 1, #meshes do
            local m = meshes[i]
            if safeValid(m) then targetMeshSet[m:GetAddress()] = true end
        end

        -- 获取 FoliageManagerComponent 以精准剔除已采集/已砍伐/默认移除的植被实例（复用缓存 GameState）
        local fm = nil
        local removedIsmSet = {}
        pcall(function()
            local gs = cachedGameState
            if not safeValid(gs) then gs = FindFirstOf("SurvivalGameState") end
            if safeValid(gs) and safeValid(gs.FoliageManagerComponent) then
                fm = gs.FoliageManagerComponent
                if fm.DefaultRemovedISMs then
                    for k = 1, #fm.DefaultRemovedISMs do
                        local rism = fm.DefaultRemovedISMs[k]
                        if safeValid(rism) then removedIsmSet[rism:GetAddress()] = true end
                    end
                end
            end
        end)

        if not cachedWorldIsms then
            cachedWorldIsms = FindAllOf("InstancedStaticMeshComponent") or {}
        end

        local cellSeen = {}
        local fmCheckSupported = safeValid(fm)
        for _, ism in ipairs(cachedWorldIsms) do
            if safeValid(ism) and (not removedIsmSet[ism:GetAddress()]) and ism.StaticMesh and safeValid(ism.StaticMesh) and targetMeshSet[ism.StaticMesh:GetAddress()] then
                local ismVisible = true
                pcall(function() ismVisible = ism:IsVisible() end)
                if ismVisible then
                    local instCount = 0
                    pcall(function() instCount = ism:GetInstanceCount() end)
                    local step = math.max(1, math.floor(instCount / 260))
                    for idx = 0, instCount - 1, step do
                        local tr = {}
                        local okTr = ism:GetInstanceTransform(idx, tr, true)
                        if okTr and tr.Translation then
                            -- Grounded 采集植被后会将其缩放归零或登记到 FoliageManager.RemovedFoliageItems
                            local alive = true
                            if tr.Scale3D then
                                local sx = math.abs(tr.Scale3D.X or 1)
                                local sy = math.abs(tr.Scale3D.Y or 1)
                                local sz = math.abs(tr.Scale3D.Z or 1)
                                if sx < 0.01 or sy < 0.01 or sz < 0.01 then
                                    alive = false
                                end
                            end
                            if alive and fmCheckSupported then
                                local okRem, isRem = pcall(function()
                                    return fm:IsRemovedFoliageInstance({ InstancedStaticMeshComponent = ism, MeshIndex = idx })
                                end)
                                if not okRem then
                                    fmCheckSupported = false
                                elseif isRem == true then
                                    alive = false
                                end
                            end

                            if alive then
                                local tx, ty, tz = tr.Translation.X or 0, tr.Translation.Y or 0, tr.Translation.Z or 0
                                local ck = string.format("%d_%d", math.floor(tx / 800), math.floor(ty / 800))
                                if not cellSeen[ck] then
                                    cellSeen[ck] = true
                                    table.insert(pins, { x = tx, y = ty, z = tz })
                                    if #pins >= 240 then break end
                                end
                            end
                        end
                    end
                    if #pins >= 240 then break end
                end
            end
        end
    end)

    foliagePinCache[rowName] = { pins = pins, clock = now }
    return pins
end

-- ============================================================
-- 8. 实时检测 “M” 地图打开状态并向 C++ 上报控件指针与地图边界
-- ============================================================
local lastMapOpen = false
local lastLivePinRefreshClock = 0
local lastMapWriteClock = 0
local lastValidVpW, lastValidVpH = 1920, 1080

--- 将 64 位对象地址格式化为十六进制字符串，避免 JSON double 精度或科学计数法丢失。
local function addrToHex(obj)
    if not safeValid(obj) then return "" end
    local ok, addr = pcall(function() return obj:GetAddress() end)
    if ok and addr and addr ~= 0 then
        return string.format("0x%X", addr)
    end
    return ""
end

--- 通过 Grounded 原生 UWidgetManager.WindowStack 精准获取当前正在显示的 M 地图面板与顶层全屏窗口（缓存 WidgetManager 避免重复 FindFirstOf）。
local function findActiveMapPanel()
    local wm = cachedWidgetManager
    if not safeValid(wm) then
        pcall(function()
            local gi = UEHelpers.GetGameInstance()
            if safeValid(gi) and safeValid(gi.WidgetManager) then
                wm = gi.WidgetManager
            end
        end)
    end
    if not safeValid(wm) then
        pcall(function()
            local pc = UEHelpers.GetPlayerController()
            if safeValid(pc) and safeValid(pc.Pawn) and safeValid(pc.Pawn.WidgetMan) then
                wm = pc.Pawn.WidgetMan
            end
        end)
    end
    if not safeValid(wm) then
        pcall(function()
            local found = FindFirstOf("WidgetManager")
            if safeValid(found) then wm = found end
        end)
    end
    if safeValid(wm) then
        cachedWidgetManager = wm
    end

    if safeValid(wm) then
        local foundPanel, foundWin = nil, nil
        pcall(function()
            local topWin = wm:GetTopWindow()
            local candidates = {}
            if safeValid(topWin) then table.insert(candidates, topWin) end
            if wm.WindowStack then
                for i = #wm.WindowStack, 1, -1 do
                    local w = wm.WindowStack[i]
                    if safeValid(w) and w ~= topWin then
                        table.insert(candidates, w)
                    end
                end
            end

            for _, win in ipairs(candidates) do
                local uiMap = nil
                pcall(function() uiMap = win.Map end)
                if safeValid(uiMap) then
                    local mapActive = false
                    local okAct, actVal = pcall(function() return uiMap.Active end)
                    if okAct and type(actVal) == "boolean" then
                        -- UI_Map_C.Active 精准反映当前是否在“地图”标签页，避免切到背包/制作页时误绘制
                        mapActive = actVal
                    else
                        pcall(function()
                            local vis = uiMap:GetVisibility()
                            if vis == 0 or vis == 3 or vis == 4 then
                                mapActive = true
                            end
                        end)
                    end
                    if mapActive and safeValid(uiMap.MapPanel) then
                        foundPanel = uiMap.MapPanel
                        foundWin = win
                        return
                    end
                end
            end
        end)
        if safeValid(foundPanel) then
            return foundPanel, foundWin
        end
    end

    return nil, nil
end

--- 在每帧/定时轮询中检测 M 地图开关状态，并将最新控件内存指针、地图边界及筛选后的标点写入 map_live.json。
-- @return true 表示 M 地图当前处于打开状态
local function updateMapLiveFrame(now)
    local panel, rootWin = findActiveMapPanel()
    if not safeValid(panel) then
        if lastMapOpen then
            lastMapOpen = false
            lastMapLiveJson = ""
            writeAtomicText(MAP_LIVE_PATH, json.encode({ mapOpen = false }))
            logInfo("M 地图已关闭")
        end
        return false
    end

    local justOpened = not lastMapOpen
    -- M 地图刚打开瞬间立即刷新一次，保持打开期间放宽至每 1.8 秒刷新生物位置与采集状态（拖拽缩放仍由 C++ 满帧直读 Slate 内存）
    if justOpened or (now - lastLivePinRefreshClock >= 1.8) then
        lastLivePinRefreshClock = now
        local shouldSyncCatalog = justOpened and ((now - lastCatalogWriteClock) >= 6.0)
        refreshWorldCatalogAndPins(shouldSyncCatalog, true)
    end
    lastMapOpen = true

    -- 仅在刚打开或每 0.5 秒同步最新坐标，并做脏检查避免无变化重复落盘
    if (not justOpened) and (now - lastMapWriteClock < 0.5) then
        return true
    end
    lastMapWriteClock = now

    local pc = UEHelpers.GetPlayerController()
    if not safeValid(pc) then return true end

    pcall(function()
        local layoutLib = getWidgetLayoutLib()
        if layoutLib then
            local sz = layoutLib:GetViewportSize(pc)
            if sz and sz.X and sz.X > 100 and sz.Y and sz.Y > 100 then
                lastValidVpW, lastValidVpH = sz.X, sz.Y
            end
        end
    end)

    -- 直接读取 UMapPanelWidget 反射边界与贴图尺寸（与 Grounded 原生 AddWidgetToCanvas 公式一致）
    local minX, minY, maxX, maxY, texW, texH = 0, 0, 0, 0, 0, 0
    pcall(function()
        if panel.MinBounds then minX, minY = panel.MinBounds.X or 0, panel.MinBounds.Y or 0 end
        if panel.MaxBounds then maxX, maxY = panel.MaxBounds.X or 0, panel.MaxBounds.Y or 0 end
        if panel.TextureSize then texW, texH = panel.TextureSize.X or 0, panel.TextureSize.Y or 0 end
    end)

    local primaryCanvas = panel.CollectibleCanvas or panel.PlayerCanvas or panel.ImageCanvas
    local fallbackCanvas = panel.ImageCanvas or panel.PlayerCanvas or panel.MapSizeBox
    local borderWidget = panel.MapBorder or panel.OuterCanvas or panel

    -- 提取原版玩家图标控件地址，供 C++ 在首次打开时进行 0 像素误差自检
    local playerIconHex = ""
    pcall(function()
        local pCanvas = panel.PlayerCanvas
        if safeValid(pCanvas) and pCanvas:GetChildrenCount() > 0 then
            playerIconHex = addrToHex(pCanvas:GetChildAt(0))
        end
    end)

    local panelHex = addrToHex(panel)
    local canvasHex = addrToHex(primaryCanvas)
    local fallbackHex = addrToHex(fallbackCanvas)
    local borderHex = addrToHex(borderWidget)
    local rootWinHex = addrToHex(rootWin)

    local hasPlayerPos = false
    local plX, plY, plZ = 0, 0, 0
    pcall(function()
        local pawn = pc.Pawn
        if safeValid(pawn) then
            local loc = pawn:K2_GetActorLocation()
            if loc then
                plX, plY, plZ = loc.X or 0, loc.Y or 0, loc.Z or 0
                hasPlayerPos = true
            end
        end
    end)

    local pins = {}
    for _, c in ipairs(collectiblePins) do
        if c.type == 2 then
            if (not c.collected) and cfg.showMilkMolars then
                table.insert(pins, { id = "__molar", n = "普通乳牙", cat = "collectible", x = c.x, y = c.y, z = c.z, c = -1, col = false })
            elseif c.collected and cfg.showCollectedMolars then
                table.insert(pins, { id = "__molar_c", n = "普通乳牙 (已采集)", cat = "collectible", x = c.x, y = c.y, z = c.z, c = -4, col = true })
            end
        elseif c.type == 3 then
            if (not c.collected) and cfg.showMegaMilkMolars then
                table.insert(pins, { id = "__megamolar", n = "高级乳牙 (巨型)", cat = "collectible", x = c.x, y = c.y, z = c.z, c = -2, col = false })
            elseif c.collected and cfg.showCollectedMolars then
                table.insert(pins, { id = "__megamolar_c", n = "高级乳牙 (已采集)", cat = "collectible", x = c.x, y = c.y, z = c.z, c = -4, col = true })
            end
        elseif c.type == 1 then
            if (not c.collected) and cfg.showScabColors then
                table.insert(pins, { id = "__scab", n = "SCA.B 配色", cat = "collectible", x = c.x, y = c.y, z = c.z, c = -3, col = false })
            end
        end
    end

    if cfg.trackedIds then
        local trackedSet = {}
        for _, tid in ipairs(cfg.trackedIds) do
            trackedSet[tid] = true
        end
        -- 跨勾选词条全局去重桶集合：无论勾选顺序如何，同一个实时标点桶每帧最多绘制一次，杜绝基础物种与变体同选时重复叠标
        local emittedBuckets = {}
        for idx, tid in ipairs(cfg.trackedIds) do
            local colorIdx = (idx - 1) % 12
            local bucketCells = nil
            local function appendBucketPins(bList)
                if not bList or #bList == 0 then return end
                if not bucketCells then bucketCells = {} end
                for _, p in ipairs(bList) do
                    table.insert(pins, {
                        id = tid, n = p.n, cat = p.cat,
                        x = p.x, y = p.y, z = p.z, c = colorIdx, col = false,
                    })
                    local ck = string.format("%d_%d", math.floor(p.x / 300), math.floor(p.y / 300))
                    bucketCells[ck] = true
                end
            end
            local matchedIds = collectMatchingBucketIds(tid, trackedSet, worldPinBuckets, catalogMetaById)
            for _, bId in ipairs(matchedIds) do
                if not emittedBuckets[bId] then
                    emittedBuckets[bId] = true
                    appendBucketPins(worldPinBuckets[bId])
                end
            end

            -- 对于自然物品，同时合并实时存活的植被点（草/鹅卵石/树枝/三叶草/树液/蘑菇等），已采集自动消失、重生自动恢复
            if tid:sub(1, 5) == "item:" then
                local rn = tid:sub(6)
                local zh = itemRowToZhName[rn] or rn
                local fpins = getFoliagePinsForRow(rn, now, justOpened)
                for _, fp in ipairs(fpins) do
                    local ck = string.format("%d_%d", math.floor(fp.x / 300), math.floor(fp.y / 300))
                    if not (bucketCells and bucketCells[ck]) then
                        table.insert(pins, {
                            id = tid, n = zh, cat = "survey",
                            x = fp.x, y = fp.y, z = fp.z, c = colorIdx, col = false,
                        })
                    end
                end
            end
        end
    end

    if justOpened then
        logInfo(string.format("M 地图已打开! panel=%s canvas=%s border=%s win=%s bounds=[%.0f..%.0f, %.0f..%.0f] tex=%.0fx%.0f vp=%.0fx%.0f pins=%d",
            panelHex, canvasHex, borderHex, rootWinHex, minX, maxX, minY, maxY, texW, texH, lastValidVpW, lastValidVpH, #pins))
    end

    local encodedMap = json.encode({
        mapOpen = true,
        hasTransform = false,
        vpW = lastValidVpW,
        vpH = lastValidVpH,
        panelAddr = panelHex,
        canvasAddr = canvasHex,
        fallbackCanvasAddr = fallbackHex,
        borderAddr = borderHex,
        rootWinAddr = rootWinHex,
        playerIconAddr = playerIconHex,
        minBoundsX = minX,
        minBoundsY = minY,
        maxBoundsX = maxX,
        maxBoundsY = maxY,
        texSizeX = texW,
        texSizeY = texH,
        hasPlayerPos = hasPlayerPos,
        playerX = plX, playerY = plY, playerZ = plZ,
        pins = json.array(pins),
    })
    if justOpened or encodedMap ~= lastMapLiveJson then
        lastMapLiveJson = encodedMap
        writeAtomicText(MAP_LIVE_PATH, encodedMap)
    end
    return true
end

-- ============================================================
-- 9. 处理菜单一次性操作指令（通过 data/actions.json 序列号去重）
-- ============================================================

--- 房主端真正一键建成当前世界中所有未完工的建筑蓝图（替代在 Shipping 版中被编译为空操作的 ServerCheatBuildAllBuildings）。
local function buildAllUnderConstructionBlueprints()
    local gs = cachedGameState
    if not safeValid(gs) then
        local okGs, found = pcall(FindFirstOf, "SurvivalGameState")
        if okGs and safeValid(found) then gs = found end
    end
    if not safeValid(gs) then
        lastStatusMessage = "当前尚未进入存档，无法一键建成蓝图"
        logInfo(lastStatusMessage)
        return
    end

    local isHost = true
    pcall(function() isHost = (gs:HasAuthority() == true) end)
    if not isHost then
        lastStatusMessage = "仅房主可执行一键建成已放置的未完工蓝图"
        logInfo(lastStatusMessage)
        return
    end

    -- 获取当前活跃 USurvivalGameModeSettings，临时确保 bAutoCompleteBuildings = true，完成后按 cfg.instantBuildEnabled 精确还原
    local gms = nil
    local prevAutoComplete = nil
    pcall(function()
        local sm = gs.SurvivalModeManagerComponent
        if safeValid(sm) and safeValid(sm.GameModeSettings) then
            gms = sm.GameModeSettings
            prevAutoComplete = (gms.bAutoCompleteBuildings == true)
            if not prevAutoComplete then
                gms.bAutoCompleteBuildings = true
            end
        end
    end)

    local builtCount = 0
    local foundBlueprints = 0
    pcall(function()
        local allBuildings = FindAllOf("Building")
        if not allBuildings then return end
        for _, bld in ipairs(allBuildings) do
            if safeValid(bld) then
                pcall(function()
                    local fullName = bld:GetFullName() or ""
                    if isTemplateOrCdoName(fullName) then return end
                    if bld.IsActorBeingDestroyed and bld:IsActorBeingDestroyed() == true then return end

                    -- EBuildingState::UnderConstruction == 4, Built == 1
                    local isUnder = false
                    pcall(function() isUnder = (bld.BuildingState == 4) end)
                    if not isUnder then
                        pcall(function()
                            if bld.IsUnderConstruction and bld:IsUnderConstruction() == true then
                                isUnder = true
                            end
                        end)
                    end
                    if not isUnder then return end

                    foundBlueprints = foundBlueprints + 1
                    -- 若蓝图尚未缓存 GameModeManagerComponent，先触发 OnGameModeChanged 刷新引用
                    pcall(function()
                        if not safeValid(bld.GameModeManagerComponent) and bld.OnGameModeChanged then
                            bld:OnGameModeChanged()
                        end
                    end)
                    -- ABuilding::SetUnderConstruction 内部检查 bAutoCompleteBuildings 并直接触发原生建成状态机与联机同步
                    bld:SetUnderConstruction()

                    local nowBuilt = false
                    pcall(function() nowBuilt = (bld.BuildingState == 1) end)
                    if not nowBuilt then
                        pcall(function()
                            if bld.IsBuilt and bld:IsBuilt() == true then nowBuilt = true end
                        end)
                    end
                    if nowBuilt then
                        builtCount = builtCount + 1
                    end
                end)
            end
        end
    end)

    -- 若用户未长期开启无材料秒建，还原 bAutoCompleteBuildings 原值
    if safeValid(gms) and (not cfg.instantBuildEnabled) and prevAutoComplete ~= nil then
        pcall(function()
            gms.bAutoCompleteBuildings = prevAutoComplete
        end)
    end

    if builtCount > 0 then
        lastStatusMessage = string.format("已一键建成当前世界中 %d 个未完工建筑蓝图！", builtCount)
    elseif foundBlueprints > 0 then
        lastStatusMessage = string.format("检测到 %d 个未完工蓝图，但部分建筑不支持自动建成", foundBlueprints)
    else
        lastStatusMessage = "当前世界中没有未完工的建筑蓝图"
    end
    logInfo(lastStatusMessage)
end

--- 执行单条来自 C++ 悬浮菜单的一次性操作指令。
local function executeSingleAction(act)
    local t = act.type
    if t == "place_waypoint" then
        pcall(function()
            local pc = UEHelpers.GetPlayerController()
            if safeValid(pc) and safeValid(pc.Pawn) then
                pc.Pawn:ServerAddWaypoint({ X = act.x or 0, Y = act.y or 0, Z = act.z or 0 })
                lastStatusMessage = "已放置原版路标: " .. tostring(act.payload or "")
                logInfo(lastStatusMessage)
            end
        end)
    elseif t == "activate_surveyors" then
        pcall(function()
            local gs = FindFirstOf("SurvivalGameState")
            if safeValid(gs) and safeValid(gs.ResourceSurveyComponent) then
                gs.ResourceSurveyComponent:ActivateAllSurveyors()
                lastStatusMessage = "已解锁全图原版资源扫描仪！"
                logInfo(lastStatusMessage)
            end
        end)
    elseif t == "survey_item" then
        local rn = tostring(act.payload or "")
        if rn ~= "" then
            pcall(function()
                loadDataTables()
                local gs = FindFirstOf("SurvivalGameState")
                local pc = UEHelpers.GetPlayerController()
                if safeValid(gs) and safeValid(gs.ResourceSurveyComponent) then
                    gs.ResourceSurveyComponent:ActivateAllSurveyors()
                end
                if safeValid(pc) and safeValid(pc.PlayerState) and safeValid(cachedAllItemsTable) then
                    local ps = pc.PlayerState
                    -- 直接传入纯 Lua 表由 UE4SS convert_lua_table_to_struct 转为 FDataTableRowHandle_NetCrc，
                    -- 彻底规避 DataTableArrayToNetCrc 返回的临时 UScriptStruct userdata 悬空指针闪退！
                    ps:ServerSetSurveyedResource({ DataTable = cachedAllItemsTable, RowName = FName(rn) })
                    ps:SetResourceSurveyVisible(true)
                    lastSurveyedName = itemRowToZhName[rn] or rn
                    lastStatusMessage = "已开启全队原版资源热区扫描: " .. lastSurveyedName
                    logInfo(lastStatusMessage)
                else
                    lastStatusMessage = "当前尚未进入存档或物品表未就绪，无法开启原版热区扫描"
                end
            end)
        end
    elseif t == "build_all_blueprints" then
        buildAllUnderConstructionBlueprints()
    elseif t == "recover_my_backpacks" then
        recoverDroppedBackpacks(false)
    elseif t == "recover_all_backpacks" then
        recoverDroppedBackpacks(true)
    elseif t == "refresh_catalog_soft" then
        -- 打开 Mod 菜单自动按需静默刷新（距上次扫描 >= 5 秒才执行，不覆盖状态栏提示，见 ADR-0004）
        local now = os.clock()
        if catalogBuiltForWorld ~= nil and (now - lastCatalogRefreshClock) >= 5.0 then
            refreshWorldCatalogAndPins(true, true)
        end
    elseif t == "refresh_catalog" then
        foliagePinCache = {}
        noFoliageRows = {}
        cachedWorldIsms = nil
        if refreshWorldCatalogAndPins(true, false) then
            lastStatusMessage = string.format("已重新扫描世界，共发现 %d 类资源", #catalogList)
        else
            lastStatusMessage = "当前尚未进入存档，无法扫描世界资源"
        end
    end
end

--- 消费 C++ 悬浮菜单写入的一次性操作指令队列（先原子重命名认领再读取删除，彻底杜绝读后删导致的跨线程丢单，按序列号严格去重）。
local function processActions()
    local claimPath = ACTIONS_PATH .. ".proc"
    os.remove(claimPath)
    local okRename = os.rename(ACTIONS_PATH, claimPath)
    if not okRename then return end

    local raw = readAllText(claimPath)
    os.remove(claimPath)
    if not raw or raw == "" then return end

    local decoded = json.decode(raw)
    if not decoded then return end

    local list = nil
    if type(decoded.actions) == "table" then
        list = decoded.actions
    elseif decoded.seq then
        list = { decoded }
    else
        return
    end

    local batchSession = type(decoded.session) == "string" and decoded.session or ""
    for _, act in ipairs(list) do
        if type(act) == "table" and type(act.seq) == "number" then
            local actSession = (type(act.session) == "string" and act.session ~= "") and act.session or batchSession
            if actSession ~= "" and actSession ~= lastActionSession then
                -- 新会话（例如重启游戏/重新加载悬浮层后序列号从 1 重新计数）：切换会话并重置已消费水位
                lastActionSession = actSession
                lastActionSeq = 0
            end
            if act.seq > lastActionSeq then
                lastActionSeq = act.seq
                executeSingleAction(act)
            end
        end
    end
end

-- ============================================================
-- 10. 单线程安全主调度器（彻底避免 UE4SS 多 LoopAsync 并发崩溃，游玩期零周期全扫）
-- ============================================================

--- 轮询 data/config.json，若文本内容发生变化则解码并合并到内存配置表 cfg。
local function pollConfig()
    local raw = readAllText(CONFIG_PATH)
    if not raw or raw == "" or raw == lastConfigRaw then return false end
    local parsed = json.decode(raw)
    if not parsed then return false end
    lastConfigRaw = raw
    for k, v in pairs(parsed) do
        cfg[k] = v
    end
    return true
end

--- 将当前世界状态、实时伤害/死亡保护生效值及乳牙统计按脏检查原子写入 data/status.json（无变化时零写盘）。
local function writeRuntimeStatus(inWorld, isHost, diffName, liveP, liveE, liveKeepInv, liveNoDurPenalty)
    local encoded = json.encode({
        inWorld = inWorld,
        isHost = isHost,
        difficulty = diffName,
        livePlayerDamage = liveP,
        liveEnemyDamage = liveE,
        liveKeepInventoryOnDeath = liveKeepInv == true,
        liveNoDeathDurabilityPenalty = liveNoDurPenalty == true,
        uncollectedMilkMolars = molarStats.unMilk,
        uncollectedMegaMolars = molarStats.unMega,
        totalMilkMolars = molarStats.totMilk,
        totalMegaMolars = molarStats.totMega,
        catalogCount = #catalogList,
        lootCompCount = harvestBoostHits,
        stackSummary = lastStackSummary,
        surveyedItemName = lastSurveyedName,
        lastActionSession = lastActionSession,
        lastActionSeq = lastActionSeq,
        lastMessage = lastStatusMessage,
    })
    if encoded ~= lastStatusJson then
        lastStatusJson = encoded
        writeAtomicText(STATUS_PATH, encoded)
    end
end

local tickInFlight = false
local tickStartClock = 0
local lastSlowTickClock = -10.0
local lastMapCheckClock = -10.0

--- 解析当前活跃存档的 SurvivalGameState 与玩家角色（优先复用缓存句柄，避免每 0.6 秒扫描 GObjects）。
local function resolveActiveWorldObjects()
    local pc = UEHelpers.GetPlayerController()
    local pawn = safeValid(pc) and pc.Pawn or nil
    if not safeValid(pawn) then
        return false, nil
    end

    local pAddr = pawn:GetAddress()
    if pAddr ~= cachedPawnAddr then
        -- 玩家角色实例切换（读档/切换世界/重生），主动刷新缓存句柄
        cachedPawnAddr = pAddr
        cachedGameState = nil
        cachedGlobalItemData = nil
        cachedWidgetManager = nil
    end

    local gs = cachedGameState
    if not safeValid(gs) then
        local okGs, foundGs = pcall(FindFirstOf, "SurvivalGameState")
        if okGs and safeValid(foundGs) then
            gs = foundGs
            cachedGameState = foundGs
        end
    end
    if not safeValid(gs) then
        return false, nil
    end

    return true, gs
end

--- 游戏主线程统一调度入口（由唯一 LoopAsync 经 ExecuteInGameThread 串行驱动，保证 UObject 线程安全）。
local function onGameThreadTick()
    local now = os.clock()

    -- 1. M 地图状态探测与按需刷新（关闭时 0.35s 轻检测，打开时 0.25s 驱动节流同步）
    if catalogBuiltForWorld ~= nil then
        local mapInterval = lastMapOpen and 0.25 or 0.35
        if now - lastMapCheckClock >= mapInterval then
            lastMapCheckClock = now
            pcall(updateMapLiveFrame, now)
        end
    end

    -- 2. 低频任务（每 0.6 秒）：同步配置、消费操作指令、按需应用堆叠/采集倍率并用缓存句柄轻维护游戏模式设置
    if now - lastSlowTickClock >= 0.6 then
        lastSlowTickClock = now

        local cfgChanged = pollConfig()
        local inWorld, gs = resolveActiveWorldObjects()

        if inWorld then
            local isHost = true
            pcall(function() isHost = gs:HasAuthority() end)

            -- 检测到切换世界/新读档（含暂停菜单直接读另一个档，不经过主菜单），彻底重置上一存档瞬态与防刷缓存
            local worldKey = gs:GetAddress()
            local enteredNewWorld = (catalogBuiltForWorld ~= worldKey)
            if enteredNewWorld then
                catalogBuiltForWorld = worldKey
                worldEnterClock = now
                worldInitialScanDone = false
                lastStackConfigKey = ""
                lastHarvestConfigKey = ""
                catalogMetaById = {}
                lastCatalogJson = ""
                lastCatalogWriteClock = 0
                foliagePinCache = {}
                noFoliageRows = {}
                knownCatalogMeta = {}
                cachedWorldIsms = nil
                origDamageMap = {}
                harvestBoostHits = 0
                spawnLootActiveDepth = {}
                spawnLootRestoreMap = {}
                excludedSpawnedActorAddrs = {}
                excludedItemObjAddrs = {}
                recentExcludedDropEvents = {}
                inExcludedDropDepth = 0
                inNonHarvestAddDepth = 0
                inModExtraAddDepth = 0
                inAddItemDepth = 0
                foliagePickupActorAddrs = {}
                foliagePickupItemAddrs = {}
                interactContextByPlayer = {}
                pendingAddItemBoosts = {}
                pendingEquipBoosts = {}
                recentEquipHandledByInv = {}
                recentlyBoostedItemAddrs = {}
                lastStatusMessage = "正在加载世界资源与乳牙坐标..."
            end

            -- 堆叠倍率仅在首次进图或堆叠配置变更时应用，避免周期重复扫描 GlobalItemData
            local stackKey = getStackConfigKey()
            if stackKey ~= lastStackConfigKey then
                lastStackConfigKey = stackKey
                applyStackSizeMultiplier()
            end

            -- 缓存句柄轻心跳维持 USurvivalGameModeSettings 原地覆写（兼顾 ADR-0001 与零 GObjects 扫描）
            local liveP, liveE, diffName, liveKeepInv, liveNoDurPenalty = applyGameModeSettings(isHost, gs)

            -- 进图 2.5 秒后执行一次性初始扫描；彻底停用任何全图 LootComponent 扫表与周期全图 LOD 扫表（见 ADR-0004 / ADR-0005）
            local harvestKey = getHarvestConfigKey()
            if (not worldInitialScanDone) and (now - worldEnterClock >= 2.5) then
                worldInitialScanDone = true
                lastStackConfigKey = getStackConfigKey()
                lastHarvestConfigKey = harvestKey
                applyStackSizeMultiplier()
                liveP, liveE, diffName, liveKeepInv, liveNoDurPenalty = applyGameModeSettings(isHost, gs)
                refreshWorldCatalogAndPins(true, false)
                lastStatusMessage = "已就绪！按 M 查看乳牙与追踪资源，按 Insert/F8 调节参数"
            elseif worldInitialScanDone and (harvestKey ~= lastHarvestConfigKey) then
                lastHarvestConfigKey = harvestKey
            end

            -- 在世界句柄与设置刷新后再消费一次性操作指令，确保指令看到最新世界状态且反馈提示不被“正在加载”覆盖
            processActions()

            writeRuntimeStatus(true, isHost, diffName, liveP, liveE, liveKeepInv, liveNoDurPenalty)
        else
            processActions()
            -- 退出存档返回主菜单时彻底清空旧世界对象地址与防刷黑名单缓存，避免悬空地址复用
            if catalogBuiltForWorld ~= nil or cachedPawnAddr ~= nil then
                catalogBuiltForWorld = nil
                worldInitialScanDone = false
                cachedGameState = nil
                cachedGlobalItemData = nil
                cachedPawnAddr = nil
                cachedWidgetManager = nil
                lastStackConfigKey = ""
                lastHarvestConfigKey = ""
                catalogList = {}
                catalogMetaById = {}
                lastCatalogJson = ""
                lastCatalogWriteClock = 0
                worldPinBuckets = {}
                collectiblePins = {}
                foliagePinCache = {}
                noFoliageRows = {}
                knownCatalogMeta = {}
                cachedWorldIsms = nil
                origDamageMap = {}
                harvestBoostHits = 0
                spawnLootActiveDepth = {}
                spawnLootRestoreMap = {}
                excludedSpawnedActorAddrs = {}
                excludedItemObjAddrs = {}
                recentExcludedDropEvents = {}
                inExcludedDropDepth = 0
                inNonHarvestAddDepth = 0
                inModExtraAddDepth = 0
                inAddItemDepth = 0
                foliagePickupActorAddrs = {}
                foliagePickupItemAddrs = {}
                interactContextByPlayer = {}
                pendingAddItemBoosts = {}
                pendingEquipBoosts = {}
                recentEquipHandledByInv = {}
                recentlyBoostedItemAddrs = {}
                if lastMapOpen then
                    lastMapOpen = false
                    lastMapLiveJson = ""
                    writeAtomicText(MAP_LIVE_PATH, json.encode({ mapOpen = false }))
                end
            end
            writeRuntimeStatus(false, true, "未进入存档", 1.0, 1.0, false, false)
        end
    end

    tickInFlight = false
end

-- 唯一异步定时驱动器：先在异步线程判断是否有任务到期再派发 ExecuteInGameThread，降低游戏主线程唤醒频率
LoopAsync(100, function()
    local now = os.clock()
    if tickInFlight then
        -- 看门狗：若超过 3 秒未释放（如极罕见切换关卡丢帧），自动解锁防止调度器永久卡死
        if now - tickStartClock < 3.0 then
            return false
        end
    end
    local mapInterval = lastMapOpen and 0.25 or 0.35
    local needMapCheck = (catalogBuiltForWorld ~= nil) and ((now - lastMapCheckClock) >= mapInterval)
    local needSlowTick = (now - lastSlowTickClock) >= 0.6
    if not needMapCheck and not needSlowTick then
        return false
    end
    tickInFlight = true
    tickStartClock = now
    ExecuteInGameThread(onGameThreadTick)
    return false
end)

logInfo("GroundedQoL v1.1.0 初始化完成（采集入包倍率零模板污染 + 客机独立地图追踪 + 菜单期光标零闪烁 + 顶层自绘中文候选条）！按 Insert 或 F8 打开中文菜单。")
