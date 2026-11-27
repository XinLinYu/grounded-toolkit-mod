-- GroundedQoL: 禁闭求生 体验增强插件（UE4SS v4.0.0 Lua 引擎逻辑层）
-- 架构：单调度器线程安全循环 + 原生 DX12/DX11 4K 简体中文悬浮菜单
-- 功能：物品堆叠倍率、玩家/怪物伤害倍率、采集与掉落倍率、“M”地图乳牙与全游戏资源自由追踪

local UEHelpers = require("UEHelpers")
local json = require("json")

-- ============================================================
-- 1. 路径初始化与原生 DX12/DX11 悬浮菜单 DLL 加载
-- ============================================================
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

local function logInfo(msg)
    print("[GroundedQoL] " .. tostring(msg) .. "\n")
end

-- 加载原生 DX12/DX11 ImGui 悬浮菜单 DLL（仅通过 package.loadlib 触发 LoadLibraryA 与 DllMain）
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
local function readAllText(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

local function writeAtomicText(path, content)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return false end
    f:write(content)
    f:close()
    os.remove(path)
    local ok = os.rename(tmp, path)
    if not ok then
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
    showMilkMolars = true,
    showMegaMilkMolars = true,
    showScabColors = false,
    showCollectedMolars = false,
    showMapLabels = false,
    showMapLegend = true,
    mapIconScale = 1.0,
    trackedIds = {},
}

local lastConfigRaw = ""
local lastActionSeq = 0
local lastStatusMessage = "插件已就绪，按 Insert 或 F8 打开中文菜单"

-- ============================================================
-- 3. 缓存状态与辅助工具
-- ============================================================
local origStackSizes = {}
local origStackBonusPerTier = nil
local origMaxDropStackSize = nil
local lastStackSummary = ""

local origDamageMap = {}
local origLootCounts = {}
local managedLootCount = 0

local cachedOEITextLib = nil
local cachedSlateLib = nil
local cachedLayoutLib = nil
local cachedStatics = nil
local cachedAllItemsTable = nil
local cachedHarvestNodesTable = nil
local cachedCharactersTable = nil

local itemRowToZhName = {}
local surveyableRows = {}
local harvestTableByHint = {}
local charTableByHint = {}
local nodeClassToZhName = {}
local nodeClassToDropRows = {}
local creatureClassToZhName = {}
local catalogBuiltForWorld = nil
local worldEnterClock = 0
local worldInitialScanDone = false
local catalogList = {}
local worldPinBuckets = {}
local collectiblePins = {}
local molarStats = { unMilk = 0, totMilk = 0, unMega = 0, totMega = 0 }
local lastSurveyedName = ""
local foliagePinCache = {}

local interactSnapshot = {}

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

local function isHaulingRowName(rowName)
    if not rowName then return false end
    local low = rowName:lower()
    return low:find("grassplank") ~= nil
        or low:find("stemweed") ~= nil
        or low:find("weedstem") ~= nil
        or low:find("plank") ~= nil
        or low == "log"
end

local function safeValid(obj)
    if not obj then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end

local function getOEITextLib()
    if safeValid(cachedOEITextLib) then return cachedOEITextLib end
    local ok, obj = pcall(StaticFindObject, "/Script/OEIText.Default__OEITextLibrary")
    if ok and safeValid(obj) then cachedOEITextLib = obj; return obj end
    return nil
end

local function getSlateLib()
    if safeValid(cachedSlateLib) then return cachedSlateLib end
    local ok, obj = pcall(StaticFindObject, "/Script/UMG.Default__SlateBlueprintLibrary")
    if ok and safeValid(obj) then cachedSlateLib = obj; return obj end
    return nil
end

local function getWidgetLayoutLib()
    if safeValid(cachedLayoutLib) then return cachedLayoutLib end
    local ok, obj = pcall(StaticFindObject, "/Script/UMG.Default__WidgetLayoutLibrary")
    if ok and safeValid(obj) then cachedLayoutLib = obj; return obj end
    return nil
end

local function getSurvivalStatics()
    if safeValid(cachedStatics) then return cachedStatics end
    local ok, obj = pcall(StaticFindObject, "/Script/Maine.Default__SurvivalGameplayStatics")
    if ok and safeValid(obj) then cachedStatics = obj; return obj end
    return nil
end

--- 将 Grounded 的 FLocString 转为当前语言（简体中文）字符串。
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

local function cleanClassName(fullOrShort)
    if not fullOrShort or fullOrShort == "" then return "" end
    local s = fullOrShort
    local afterDot = s:match("%.([^%.]+)$")
    if afterDot then s = afterDot end
    s = s:gsub("_C$", ""):gsub("^BP_", ""):gsub("^Default__", "")
    return s
end

local function normalizeKey(s)
    return (s or ""):lower():gsub("[^a-z0-9]", "")
end

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
local function applyStackSizeMultiplier()
    local ok, gid = pcall(FindFirstOf, "GlobalItemData")
    if not ok or not safeValid(gid) then return end

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
-- 5. 功能二 & 功能五：伤害倍率 + 无材料秒建与免费合成（USurvivalGameModeSettings）
-- ============================================================
local function applyGameModeSettings()
    local livePlayerDmg = 1.0
    local liveEnemyDmg = 1.0
    local diffName = "未知"
    local appliedAny = false

    local function applyToSettings(gms)
        if not safeValid(gms) then return end
        local addr = gms:GetAddress()
        if not origDamageMap[addr] then
            origDamageMap[addr] = {
                player = gms.PlayerDamageMultiplier or 1.0,
                enemy = gms.EnemyDamageMultiplier or 1.0,
                autoComplete = (gms.bAutoCompleteBuildings == true),
                requireIngredients = (gms.bRecipesRequireIngredients ~= false),
                unlockAll = (gms.bUnlockAllRecipes == true),
            }
        end
        local base = origDamageMap[addr]

        -- 伤害倍率
        local targetP = cfg.damageEnabled and (base.player * (cfg.playerDamageMultiplier or 1.0)) or base.player
        local targetE = cfg.damageEnabled and (base.enemy * (cfg.enemyDamageMultiplier or 1.0)) or base.enemy
        if math.abs((gms.PlayerDamageMultiplier or 1.0) - targetP) > 0.001 then
            gms.PlayerDamageMultiplier = targetP
        end
        if math.abs((gms.EnemyDamageMultiplier or 1.0) - targetE) > 0.001 then
            gms.EnemyDamageMultiplier = targetE
        end

        -- 建筑建设无材料立刻建成 / 工作台与背包合成制作无需材料 / 可选解锁全部配方
        local targetAutoBuild = cfg.instantBuildEnabled and true or base.autoComplete
        local targetReqIngr = cfg.freeCraftEnabled and false or base.requireIngredients
        local targetUnlock = cfg.unlockAllRecipes and true or base.unlockAll

        if gms.bAutoCompleteBuildings ~= targetAutoBuild then
            gms.bAutoCompleteBuildings = targetAutoBuild
        end
        if gms.bRecipesRequireIngredients ~= targetReqIngr then
            gms.bRecipesRequireIngredients = targetReqIngr
        end
        if gms.bUnlockAllRecipes ~= targetUnlock then
            gms.bUnlockAllRecipes = targetUnlock
        end

        livePlayerDmg = gms.PlayerDamageMultiplier
        liveEnemyDmg = gms.EnemyDamageMultiplier
        appliedAny = true

        local d = gms.GameDifficulty
        if d == 0 then diffName = "简易 (Mild)"
        elseif d == 1 then diffName = "中等 (Medium)"
        elseif d == 2 then diffName = "哇哦! (Woah!)"
        else diffName = "自定义" end
    end

    local okGs, gs = pcall(FindFirstOf, "SurvivalGameState")
    if okGs and safeValid(gs) then
        pcall(function()
            local sm = gs.SurvivalModeManagerComponent
            if safeValid(sm) and safeValid(sm.GameModeSettings) then
                applyToSettings(sm.GameModeSettings)
            end
        end)
    end

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

    return livePlayerDmg, liveEnemyDmg, diffName
end

-- ============================================================
-- 6. 功能三：采集与掉落数量倍率（ULootComponent + SpawnLoot Hook + 自然拾取）
-- ============================================================
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

local function applyLootComponent(lc)
    if not safeValid(lc) then return false end
    local ownerName = ""
    pcall(function()
        local outer = lc:GetOuter()
        if safeValid(outer) then ownerName = outer:GetFullName() end
    end)
    if shouldSkipLootOwner(ownerName) then return false end

    local addr = lc:GetAddress()
    local items = nil
    pcall(function() items = lc.Items end)
    if not items then return false end

    local len = 0
    pcall(function() len = #items end)
    if len <= 0 then return false end

    local orig = origLootCounts[addr]
    if not orig then
        orig = {}
        origLootCounts[addr] = orig
    end

    local mult = (cfg.harvestEnabled and cfg.harvestMultiplier and cfg.harvestMultiplier > 1) and cfg.harvestMultiplier or 1

    for i = 1, len do
        pcall(function()
            local entry = items[i]
            if entry and entry.Type == 0 then -- 仅放大 ELootType::Item，绝不触碰乳牙Actor/科学点/装备
                local cur = entry.Count or 0
                if orig[i] == nil then
                    orig[i] = cur
                end
                local baseCnt = orig[i]
                if baseCnt and baseCnt > 0 then
                    local rowName = ""
                    pcall(function() rowName = entry.ItemData.RowName:ToString() end)
                    local target = baseCnt
                    if mult > 1 then
                        if isHaulingRowName(rowName) then
                            if cfg.harvestAffectHauling then
                                target = math.min(12, math.max(baseCnt, math.floor(baseCnt * mult + 0.5)))
                            end
                        else
                            target = math.min(999, math.max(baseCnt, math.floor(baseCnt * mult + 0.5)))
                        end
                    end
                    if cur ~= target then
                        entry.Count = target
                    end
                end
            end
        end)
    end
    return true
end

local function applyAllLootComponents()
    local cnt = 0
    local ok, list = pcall(FindAllOf, "LootComponent")
    if ok and list then
        for _, lc in ipairs(list) do
            if applyLootComponent(lc) then
                cnt = cnt + 1
            end
        end
    end
    pcall(function()
        local gi = UEHelpers.GetGameInstance()
        if safeValid(gi) and gi.FoliageMappings then
            gi.FoliageMappings:ForEach(function(_, mapParam)
                pcall(function()
                    local m = mapParam:get()
                    if m and safeValid(m.LootComponent) then
                        if applyLootComponent(m.LootComponent) then
                            cnt = cnt + 1
                        end
                    end
                end)
            end)
        end
    end)
    managedLootCount = cnt
end

-- 在 SpawnLoot 触发瞬间确保刚生成的草/矿石/怪物掉落表已被放大（幂等、无 NotifyOnNewObject 并发风险）
pcall(function()
    RegisterHook("/Script/Maine.LootComponent:SpawnLoot", function(selfParam)
        if cfg.harvestEnabled and cfg.harvestMultiplier and cfg.harvestMultiplier > 1 then
            pcall(function() applyLootComponent(selfParam:get()) end)
        end
    end)
end)

-- 地面自然植被与无主刷新物按 E 拾取增量 Hook
local function snapshotInventoryCounts(invComp)
    local counts = {}
    if not safeValid(invComp) then return counts end
    pcall(function()
        local items = invComp.Items
        local n = #items
        for i = 1, n do
            local it = items[i]
            if safeValid(it) then
                local rn = it.ItemDataRowHandle.RowName:ToString()
                if rn and rn ~= "None" then
                    counts[rn] = (counts[rn] or 0) + (it.StackSize or 1)
                end
            end
        end
    end)
    return counts
end

pcall(function()
    RegisterHook("/Script/Maine.SurvivalPlayerCharacter:ServerHandleInteract", function(selfParam)
        if not (cfg.harvestEnabled and cfg.harvestAffectPickup and cfg.harvestMultiplier and cfg.harvestMultiplier > 1) then
            return
        end
        local player = selfParam:get()
        if not safeValid(player) then return end

        local allowBoost = false
        pcall(function()
            local curObj = player.CurrentInteractable
            if not safeValid(curObj) then
                allowBoost = true
            elseif curObj:IsA("/Script/Maine.SpawnedItem") then
                local droppedBy = nil
                pcall(function() droppedBy = curObj:GetDroppedBy() end)
                local placedRow = ""
                pcall(function() placedRow = curObj.PlacedItemData.RowName:ToString() end)
                local itemObj = nil
                pcall(function() itemObj = curObj:GetItem() end)
                if not safeValid(droppedBy) and placedRow ~= "" and placedRow ~= "None" and safeValid(itemObj) then
                    local canStack = false
                    pcall(function() canStack = itemObj:CanStack() end)
                    if canStack and (itemObj.StackSize or 1) == 1 then
                        allowBoost = true
                    end
                end
            end
        end)

        if not allowBoost then return end
        local inv = player.InventoryComponent
        if not safeValid(inv) then return end
        local pAddr = player:GetAddress()
        interactSnapshot[pAddr] = {
            inv = inv,
            before = snapshotInventoryCounts(inv),
            mult = cfg.harvestMultiplier,
        }
    end, function(selfParam)
        local player = selfParam:get()
        if not safeValid(player) then return end
        local pAddr = player:GetAddress()
        local snap = interactSnapshot[pAddr]
        interactSnapshot[pAddr] = nil
        if not snap or not safeValid(snap.inv) then return end

        local after = snapshotInventoryCounts(snap.inv)
        local extraMult = (snap.mult or 1) - 1
        if extraMult <= 0 then return end

        for rn, newTotal in pairs(after) do
            local oldTotal = snap.before[rn] or 0
            local delta = newTotal - oldTotal
            if delta > 0 and delta <= 3 and not isHaulingRowName(rn) then
                local addAmount = delta * extraMult
                pcall(function()
                    local items = snap.inv.Items
                    for i = 1, #items do
                        local it = items[i]
                        if safeValid(it) and it.ItemDataRowHandle.RowName:ToString() == rn then
                            local canStack = false
                            pcall(function() canStack = it:CanStack() end)
                            if canStack then
                                local maxS = it:GetMaxStackSize()
                                local curS = it.StackSize or 1
                                local room = math.max(0, maxS - curS)
                                local give = math.min(addAmount, room)
                                if give > 0 then
                                    it:AdjustStackSize(give)
                                    addAmount = addAmount - give
                                end
                                if addAmount <= 0 then break end
                            end
                        end
                    end
                end)
            end
        end
    end)
end)

-- ============================================================
-- 7. 功能四：“M” 地图乳牙、高级乳牙与全游戏资源目录扫描
-- ============================================================
local function loadDataTables()
    local gi = UEHelpers.GetGameInstance()
    if safeValid(gi) and safeValid(gi.GlobalTableData) then
        local gtd = gi.GlobalTableData
        if safeValid(gtd.AllItemsTable) then cachedAllItemsTable = gtd.AllItemsTable end
        if safeValid(gtd.HarvestNodesTable) then cachedHarvestNodesTable = gtd.HarvestNodesTable end
        if safeValid(gtd.CharactersTable) then cachedCharactersTable = gtd.CharactersTable end
    end
    if not safeValid(cachedAllItemsTable) then
        local ok, gtd = pcall(FindFirstOf, "GlobalTableData")
        if ok and safeValid(gtd) then
            if safeValid(gtd.AllItemsTable) then cachedAllItemsTable = gtd.AllItemsTable end
            if safeValid(gtd.HarvestNodesTable) then cachedHarvestNodesTable = gtd.HarvestNodesTable end
            if safeValid(gtd.CharactersTable) then cachedCharactersTable = gtd.CharactersTable end
        end
    end
end

local function loadTableTranslations()
    loadDataTables()
    local statics = getSurvivalStatics()

    -- 1. AllItemsTable -> 官方简体中文物品名 + 自然资源/可扫描标记
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

                -- 判定是否支持原版资源扫描仪热区
                local isNat = false
                if statics then
                    pcall(function()
                        isNat = statics:IsNaturalResource({ DataTable = cachedAllItemsTable, RowName = FName(rowName) })
                    end)
                end
                local itemType = 0
                pcall(function() itemType = rowData.ItemType or 0 end)
                if isNat or itemType == 0 then
                    surveyableRows[rowName] = true
                end
            end)
        end)
    end

    -- 2. HarvestNodesTable -> 官方简体中文采集点名索引
    if next(harvestTableByHint) == nil and safeValid(cachedHarvestNodesTable) then
        pcall(function()
            cachedHarvestNodesTable:ForEachRow(function(rowName, rowData)
                local zh = ""
                pcall(function() zh = locStringToZh(rowData.DisplayName) end)
                if zh ~= "" then
                    harvestTableByHint[normalizeKey(rowName)] = zh
                end
            end)
        end)
    end

    -- 3. CharactersTable -> 官方简体中文生物名索引
    if next(charTableByHint) == nil and safeValid(cachedCharactersTable) then
        pcall(function()
            cachedCharactersTable:ForEachRow(function(rowName, rowData)
                local zh = ""
                pcall(function() zh = locStringToZh(rowData.CharacterName) end)
                if zh ~= "" then
                    charTableByHint[normalizeKey(rowName)] = zh
                end
            end)
        end)
    end
end

local cachedHealthLodClass = nil
local knownCatalogMeta = {}
local noFoliageRows = {}
local cachedWorldIsms = nil
local lastCatalogWriteClock = 0

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

local function refreshWorldCatalogAndPins(writeCatalogFile, quietLog)
    local okGs, gs = pcall(FindFirstOf, "SurvivalGameState")
    if not okGs or not safeValid(gs) then return false end

    loadTableTranslations()
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
                                local nk = normalizeKey(actorClsShort)
                                if charTableByHint[nk] then
                                    zh = charTableByHint[nk]
                                else
                                    -- 尝试前缀匹配 CharactersTable
                                    for k, v in pairs(charTableByHint) do
                                        if nk == k or nk:find(k, 1, true) then
                                            zh = v .. " (" .. actorClsShort .. ")"
                                            break
                                        end
                                    end
                                end
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

    -- C. 将所有可扫描物品补全到目录（确保全游戏所有物品都能中文搜索并联动原版扫描热区）
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

    collectiblePins = newCollectibles
    worldPinBuckets = newBuckets
    molarStats = { unMilk = unMilk, totMilk = totMilk, unMega = unMega, totMega = totMega }

    if writeCatalogFile then
        lastCatalogWriteClock = os.clock()
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
        writeAtomicText(CATALOG_PATH, json.encode(json.array(list)))
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
    if cached and (not forceRefresh) and ((now - cached.clock) < 2.5) then
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

        -- 获取 FoliageManagerComponent 以精准剔除已采集/已砍伐/默认移除的植被实例
        local fm = nil
        local removedIsmSet = {}
        pcall(function()
            local gs = FindFirstOf("SurvivalGameState")
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

--- 通过 Grounded 原生 UWidgetManager.WindowStack 精准获取当前正在显示的 M 地图面板与顶层全屏窗口。
local function findActiveMapPanel()
    local wm = nil
    pcall(function()
        local gi = UEHelpers.GetGameInstance()
        if safeValid(gi) and safeValid(gi.WidgetManager) then
            wm = gi.WidgetManager
        end
    end)
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

local function updateMapLiveFrame(now)
    local panel, rootWin = findActiveMapPanel()
    if not safeValid(panel) then
        if lastMapOpen then
            lastMapOpen = false
            writeAtomicText(MAP_LIVE_PATH, json.encode({ mapOpen = false }))
            logInfo("M 地图已关闭")
        end
        return false
    end

    local justOpened = not lastMapOpen
    -- M 地图刚打开或每 0.45 秒实时刷新一次全图资源、徘徊中动物及死亡/采集状态
    if justOpened or (now - lastLivePinRefreshClock >= 0.45) then
        lastLivePinRefreshClock = now
        local shouldSyncCatalog = justOpened and ((now - lastCatalogWriteClock) >= 6.0)
        refreshWorldCatalogAndPins(shouldSyncCatalog, true)
    end
    lastMapOpen = true

    -- C++ 悬浮层每帧直接从 Slate 内存读取控件 FGeometry（60~144Hz 零延迟），
    -- Lua 只需在刚打开时立刻写出，其余时候按 4Hz 同步最新动物与玩家坐标即可。
    if (not justOpened) and (now - lastMapWriteClock < 0.25) then
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
        for idx, tid in ipairs(cfg.trackedIds) do
            local colorIdx = (idx - 1) % 12
            local bucket = worldPinBuckets[tid]
            local bucketCells = nil
            if bucket and #bucket > 0 then
                bucketCells = {}
                for _, p in ipairs(bucket) do
                    table.insert(pins, {
                        id = tid, n = p.n, cat = p.cat,
                        x = p.x, y = p.y, z = p.z, c = colorIdx, col = false,
                    })
                    local ck = string.format("%d_%d", math.floor(p.x / 300), math.floor(p.y / 300))
                    bucketCells[ck] = true
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

    writeAtomicText(MAP_LIVE_PATH, json.encode({
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
    }))
    return true
end

-- ============================================================
-- 9. 处理菜单一次性操作指令
-- ============================================================
local function processActions()
    local raw = readAllText(ACTIONS_PATH)
    if not raw or raw == "" then return end
    local act = json.decode(raw)
    if not act or not act.seq or act.seq <= lastActionSeq then return end
    lastActionSeq = act.seq
    os.remove(ACTIONS_PATH)

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
                    local statics = getSurvivalStatics()
                    local netHandle = nil
                    if statics then
                        pcall(function()
                            local arr = statics:DataTableArrayToNetCrc({ { DataTable = cachedAllItemsTable, RowName = FName(rn) } })
                            if arr and #arr >= 1 then netHandle = arr[1] end
                        end)
                    end
                    if netHandle then
                        ps:ServerSetSurveyedResource(netHandle)
                    else
                        ps:ServerSetSurveyedResource({ DataTable = cachedAllItemsTable, RowName = FName(rn) })
                    end
                    ps:SetResourceSurveyVisible(true)
                    lastSurveyedName = itemRowToZhName[rn] or rn
                    lastStatusMessage = "已开启全队原版资源热区扫描: " .. lastSurveyedName
                    logInfo(lastStatusMessage)
                end
            end)
        end
    elseif t == "build_all_blueprints" then
        pcall(function()
            local pc = UEHelpers.GetPlayerController()
            if safeValid(pc) and safeValid(pc.Pawn) then
                pc.Pawn:ServerCheatBuildAllBuildings()
                lastStatusMessage = "已一键建成当前世界中所有未完工的建筑蓝图！"
                logInfo(lastStatusMessage)
            end
        end)
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

-- ============================================================
-- 10. 单线程安全主调度器（彻底避免 UE4SS 多 LoopAsync 并发崩溃）
-- ============================================================
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

local function writeRuntimeStatus(inWorld, isHost, diffName, liveP, liveE)
    writeAtomicText(STATUS_PATH, json.encode({
        inWorld = inWorld,
        isHost = isHost,
        difficulty = diffName,
        livePlayerDamage = liveP,
        liveEnemyDamage = liveE,
        uncollectedMilkMolars = molarStats.unMilk,
        uncollectedMegaMolars = molarStats.unMega,
        totalMilkMolars = molarStats.totMilk,
        totalMegaMolars = molarStats.totMega,
        catalogCount = #catalogList,
        lootCompCount = managedLootCount,
        stackSummary = lastStackSummary,
        surveyedItemName = lastSurveyedName,
        lastMessage = lastStatusMessage,
    }))
end

local tickInFlight = false
local tickStartClock = 0
local lastSlowTickClock = 0
local lastLootSweepClock = 0
local lastMapCheckClock = 0

local function onGameThreadTick()
    local now = os.clock()

    -- 1. 高频任务：仅在已进入存档时检测与刷新 M 地图标点（M 地图打开时 50ms 刷新，关闭时 250ms 探测）
    if catalogBuiltForWorld ~= nil then
        local mapInterval = lastMapOpen and 0.04 or 0.25
        if now - lastMapCheckClock >= mapInterval then
            lastMapCheckClock = now
            pcall(updateMapLiveFrame, now)
        end
    end

    -- 2. 低频任务（每 0.6 秒）：同步配置、执行菜单操作、维护堆叠/伤害倍率与进图状态
    if now - lastSlowTickClock >= 0.6 then
        lastSlowTickClock = now

        local cfgChanged = pollConfig()
        processActions()
        applyStackSizeMultiplier()

        local okGs, gs = pcall(FindFirstOf, "SurvivalGameState")
        local okChar, char = pcall(FindFirstOf, "SurvivalPlayerCharacter")
        local inWorld = okGs and safeValid(gs) and okChar and safeValid(char)

        if inWorld then
            local isHost = true
            pcall(function() isHost = gs:HasAuthority() end)

            local liveP, liveE, diffName = applyGameModeSettings()

            local worldKey = gs:GetAddress()
            if catalogBuiltForWorld ~= worldKey then
                catalogBuiltForWorld = worldKey
                worldEnterClock = now
                worldInitialScanDone = false
                foliagePinCache = {}
                noFoliageRows = {}
                knownCatalogMeta = {}
                cachedWorldIsms = nil
                lastStatusMessage = "正在加载世界资源与乳牙坐标..."
            end

            -- 进入存档 2.5 秒后自动执行一次全量世界扫描（不使用嵌套 ExecuteWithDelay）
            if (not worldInitialScanDone) and (now - worldEnterClock >= 2.5) then
                worldInitialScanDone = true
                applyStackSizeMultiplier()
                applyGameModeSettings()
                applyAllLootComponents()
                refreshWorldCatalogAndPins(true, false)
                lastStatusMessage = "已就绪！按 M 查看乳牙与追踪资源，按 Insert/F8 调节参数"
            elseif cfgChanged or (now - lastLootSweepClock >= 2.5) then
                lastLootSweepClock = now
                applyAllLootComponents()
                -- 每 10 秒静默同步一次目录数量，确保菜单里的“[生物/采集点 | X处]”随击杀/采集/重生动态更新
                if worldInitialScanDone and (not lastMapOpen) and ((now - lastCatalogWriteClock) >= 10.0) then
                    refreshWorldCatalogAndPins(true, true)
                end
            end

            writeRuntimeStatus(true, isHost, diffName, liveP, liveE)
        else
            if catalogBuiltForWorld ~= nil then
                catalogBuiltForWorld = nil
                worldInitialScanDone = false
                catalogList = {}
                worldPinBuckets = {}
                collectiblePins = {}
                foliagePinCache = {}
                noFoliageRows = {}
                knownCatalogMeta = {}
                cachedWorldIsms = nil
                origDamageMap = {}
                origLootCounts = {}
                if lastMapOpen then
                    lastMapOpen = false
                    writeAtomicText(MAP_LIVE_PATH, json.encode({ mapOpen = false }))
                end
            end
            writeRuntimeStatus(false, true, "未进入存档", 1.0, 1.0)
        end
    end

    tickInFlight = false
end

-- 唯一的一个异步定时驱动器，严格保证同一时刻最多只有 1 个游戏线程回调在飞
LoopAsync(50, function()
    local now = os.clock()
    if tickInFlight then
        -- 看门狗：若超过 3 秒未释放（如极罕见切换关卡丢帧），自动解锁防止卡死
        if now - tickStartClock < 3.0 then
            return false
        end
    end
    tickInFlight = true
    tickStartClock = now
    ExecuteInGameThread(onGameThreadTick)
    return false
end)

logInfo("GroundedQoL v1.1 初始化完成（单线程稳定调度 + DX12/DX11 支持）！按 Insert 或 F8 打开中文菜单。")
