/*
 * 文件：overlay/src/ipc.cpp
 * 职责：实现 IpcBridge 的后台异步文件轮询、原子 JSON 写盘与零拷贝不可变快照分发。
 * 并发说明（见 ADR-0004）：
 *   - 独立后台线程 IoWorkerLoop 统一承担 map_live/status/catalog 读取解析与 config/actions 原子写盘；
 *   - Present 渲染线程与 WndProc 消息线程仅做短暂锁内的 std::shared_ptr 拷贝或队列入队，永不阻塞于磁盘 I/O。
 */

#include "ipc.h"

#include <Windows.h>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <nlohmann/json.hpp>

using json = nlohmann::json;

namespace gqol {

namespace {

/// 无损解析 JSON 中的 64 位内存地址字段（兼容 "0x..." 十六进制字符串与无符号/有符号整数）。
uint64_t ParseAddrField(const json& j, const char* key) {
    auto it = j.find(key);
    if (it == j.end() || it->is_null()) return 0;
    if (it->is_string()) {
        const std::string& s = it->get_ref<const std::string&>();
        if (s.empty()) return 0;
        return std::strtoull(s.c_str(), nullptr, 0);
    }
    if (it->is_number_unsigned()) return it->get<uint64_t>();
    if (it->is_number_integer()) {
        int64_t v = it->get<int64_t>();
        return v > 0 ? static_cast<uint64_t>(v) : 0;
    }
    return 0;
}

/// 获取文件最后修改时间（64 位 FILETIME），文件不存在或查询失败时返回 0。
unsigned long long GetFileMtime64(const std::wstring& path) {
    WIN32_FILE_ATTRIBUTE_DATA fad{};
    if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &fad)) {
        return 0;
    }
    ULARGE_INTEGER ui{};
    ui.LowPart = fad.ftLastWriteTime.dwLowDateTime;
    ui.HighPart = fad.ftLastWriteTime.dwHighDateTime;
    return ui.QuadPart;
}

/// 判断追踪 ID 是否包含历史版本遗留的损坏 UE4SS Userdata 内存指针文本。
bool IsCorruptTrackedId(const std::string& id) {
    return id.empty()
        || id.find("Userdata:") != std::string::npos
        || id.find("userdata:") != std::string::npos;
}

/// 将 ModConfig 统一序列化为 JSON 对象（供首次初始化落盘与用户修改保存复用，防止字段漂移）。
json SerializeConfigJson(const ModConfig& cfg) {
    return json{
        {"stackEnabled", cfg.stackEnabled},
        {"stackMultiplier", cfg.stackMultiplier},
        {"damageEnabled", cfg.damageEnabled},
        {"playerDamageMultiplier", cfg.playerDamageMultiplier},
        {"enemyDamageMultiplier", cfg.enemyDamageMultiplier},
        {"harvestEnabled", cfg.harvestEnabled},
        {"harvestMultiplier", cfg.harvestMultiplier},
        {"harvestAffectHauling", cfg.harvestAffectHauling},
        {"harvestAffectPickup", cfg.harvestAffectPickup},
        {"instantBuildEnabled", cfg.instantBuildEnabled},
        {"freeCraftEnabled", cfg.freeCraftEnabled},
        {"unlockAllRecipes", cfg.unlockAllRecipes},
        {"keepInventoryOnDeath", cfg.keepInventoryOnDeath},
        {"noDeathDurabilityPenalty", cfg.noDeathDurabilityPenalty},
        {"showMilkMolars", cfg.showMilkMolars},
        {"showMegaMilkMolars", cfg.showMegaMilkMolars},
        {"showScabColors", cfg.showScabColors},
        {"showCollectedMolars", cfg.showCollectedMolars},
        {"showMapLabels", cfg.showMapLabels},
        {"showMapLegend", cfg.showMapLegend},
        {"mapIconScale", cfg.mapIconScale},
        {"imeCandidateMode", std::clamp(cfg.imeCandidateMode, 0, 2)},
        {"trackedIds", cfg.trackedIds},
    };
}

} // namespace

IpcBridge::IpcBridge()
    : m_configSnap(std::make_shared<ModConfig>()),
      m_catalogSnap(std::make_shared<std::vector<CatalogEntry>>()),
      m_mapLiveSnap(std::make_shared<MapLiveState>()),
      m_statusSnap(std::make_shared<RuntimeStatus>()) {
    LARGE_INTEGER qpc{};
    QueryPerformanceCounter(&qpc);
    char sbuf[96];
    std::snprintf(sbuf, sizeof(sbuf), "s_%lu_%llu_%lld",
                  static_cast<unsigned long>(GetCurrentProcessId()),
                  static_cast<unsigned long long>(GetTickCount64()),
                  static_cast<long long>(qpc.QuadPart));
    m_actionSession = sbuf;
}

IpcBridge::~IpcBridge() {
    Shutdown(true);
}

IpcBridge& IpcBridge::Instance() {
    // 使用永生堆单例（Immortal Singleton）：进程退出时后台分离线程可能仍处于内核返回前夕，
    // 绝不让 atexit 析构 m_mutex / m_ioMutex / m_ioCv，彻底杜绝退出阶段 RtlEnterCriticalSection 访问已销毁锁闪退。
    static IpcBridge* inst = new IpcBridge();
    return *inst;
}

void IpcBridge::Initialize(const std::wstring& dllDirectory) {
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_dataDir = dllDirectory;
        if (!m_dataDir.empty() && m_dataDir.back() != L'\\' && m_dataDir.back() != L'/') {
            m_dataDir.push_back(L'\\');
        }
        m_dataDir += L"data";
        CreateDirectoryW(m_dataDir.c_str(), nullptr);

        if (!LoadConfigLocked()) {
            // 首次启动或旧配置文件损坏时同步写出完整默认配置，确保 Lua 端与回归测试立即可读取
            auto defaultCfg = std::make_shared<ModConfig>();
            m_configSnap = defaultCfg;
            AtomicWriteText(m_dataDir + L"\\config.json", SerializeConfigJson(*defaultCfg).dump(2));
        }
        // 启动新会话时清理上次异常退出可能残留的旧 actions.json，避免误触发过期指令
        DeleteFileW((m_dataDir + L"\\actions.json").c_str());
    }

    // 立即在初始化线程预读一次已有 IPC 文件，并拉起后台异步 I/O 轮询线程
    PollFilesOnWorker();

    std::lock_guard<std::mutex> ioLock(m_ioMutex);
    if (!m_ioStarted) {
        m_stopIo.store(false);
        m_ioStarted = true;
        m_ioThread = std::thread(&IpcBridge::IoWorkerLoop, this);
    }
}

void IpcBridge::Shutdown(bool processTerminating) {
    if (processTerminating) {
        m_processTerminating.store(true, std::memory_order_release);
    }
    m_stopIo.store(true, std::memory_order_release);
    m_ioCv.notify_all();
    if (!processTerminating) {
        std::thread toJoin;
        {
            std::lock_guard<std::mutex> ioLock(m_ioMutex);
            if (m_ioThread.joinable()) {
                toJoin = std::move(m_ioThread);
            }
            m_ioStarted = false;
        }
        if (toJoin.joinable()) {
            toJoin.join();
        }
    } else {
        // 进程终止期间（DllMain DLL_PROCESS_DETACH reserved != nullptr）严禁 join 避免 Loader Lock 死锁
        std::lock_guard<std::mutex> ioLock(m_ioMutex);
        if (m_ioThread.joinable()) {
            m_ioThread.detach();
        }
        m_ioStarted = false;
    }
}

void IpcBridge::PollFromLua() {
    // 全部轮询已迁移至后台异步线程 IoWorkerLoop，此处保持空实现，确保 Present 渲染线程零磁盘 I/O
}

bool IpcBridge::ReadFileIfChanged(const std::wstring& path, unsigned long long& lastMtime, std::string& outText) {
    unsigned long long mtime = GetFileMtime64(path);
    if (mtime == 0 || mtime == lastMtime) {
        return false;
    }
    std::ifstream ifs(path, std::ios::binary);
    if (!ifs.is_open()) {
        return false;
    }
    std::ostringstream ss;
    ss << ifs.rdbuf();
    outText = ss.str();
    if (outText.empty()) {
        return false;
    }
    lastMtime = mtime;
    return true;
}

bool IpcBridge::AtomicWriteText(const std::wstring& path, const std::string& content) {
    std::wstring tmp = path + L".tmp";
    {
        std::ofstream ofs(tmp, std::ios::binary | std::ios::trunc);
        if (!ofs.is_open()) {
            return false;
        }
        ofs.write(content.data(), static_cast<std::streamsize>(content.size()));
        ofs.flush();
        if (!ofs.good()) {
            return false;
        }
    }
    // 使用 MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH 原子替换，遇极短暂文件共享竞争时做有界重试
    for (int attempt = 0; attempt < 4; ++attempt) {
        if (MoveFileExW(tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0) {
            return true;
        }
        Sleep(1);
    }
    return false;
}

bool IpcBridge::LoadConfigLocked() {
    std::wstring path = m_dataDir + L"\\config.json";
    std::ifstream ifs(path, std::ios::binary);
    if (!ifs.is_open()) {
        return false;
    }
    try {
        json j = json::parse(ifs);
        ifs.close();
        auto cfg = std::make_shared<ModConfig>();
        // 对每个字段使用默认值兜底，确保旧版本升级后新增字段平滑兼容
        cfg->stackEnabled = j.value("stackEnabled", cfg->stackEnabled);
        cfg->stackMultiplier = j.value("stackMultiplier", cfg->stackMultiplier);
        cfg->damageEnabled = j.value("damageEnabled", cfg->damageEnabled);
        cfg->playerDamageMultiplier = j.value("playerDamageMultiplier", cfg->playerDamageMultiplier);
        cfg->enemyDamageMultiplier = j.value("enemyDamageMultiplier", cfg->enemyDamageMultiplier);
        cfg->harvestEnabled = j.value("harvestEnabled", cfg->harvestEnabled);
        cfg->harvestMultiplier = j.value("harvestMultiplier", cfg->harvestMultiplier);
        cfg->harvestAffectHauling = j.value("harvestAffectHauling", cfg->harvestAffectHauling);
        cfg->harvestAffectPickup = j.value("harvestAffectPickup", cfg->harvestAffectPickup);
        cfg->instantBuildEnabled = j.value("instantBuildEnabled", cfg->instantBuildEnabled);
        cfg->freeCraftEnabled = j.value("freeCraftEnabled", cfg->freeCraftEnabled);
        cfg->unlockAllRecipes = j.value("unlockAllRecipes", cfg->unlockAllRecipes);
        cfg->keepInventoryOnDeath = j.value("keepInventoryOnDeath", cfg->keepInventoryOnDeath);
        cfg->noDeathDurabilityPenalty = j.value("noDeathDurabilityPenalty", cfg->noDeathDurabilityPenalty);
        cfg->showMilkMolars = j.value("showMilkMolars", cfg->showMilkMolars);
        cfg->showMegaMilkMolars = j.value("showMegaMilkMolars", cfg->showMegaMilkMolars);
        cfg->showScabColors = j.value("showScabColors", cfg->showScabColors);
        cfg->showCollectedMolars = j.value("showCollectedMolars", cfg->showCollectedMolars);
        cfg->showMapLabels = j.value("showMapLabels", cfg->showMapLabels);
        cfg->showMapLegend = j.value("showMapLegend", cfg->showMapLegend);
        cfg->mapIconScale = j.value("mapIconScale", cfg->mapIconScale);
        cfg->imeCandidateMode = std::clamp(j.value("imeCandidateMode", cfg->imeCandidateMode), 0, 2);
        bool sanitizedTrackedIds = false;
        if (j.contains("trackedIds") && j["trackedIds"].is_array()) {
            auto rawIds = j["trackedIds"].get<std::vector<std::string>>();
            cfg->trackedIds.reserve(rawIds.size());
            for (auto& id : rawIds) {
                if (IsCorruptTrackedId(id)) {
                    sanitizedTrackedIds = true;
                    continue;
                }
                if (std::find(cfg->trackedIds.begin(), cfg->trackedIds.end(), id) == cfg->trackedIds.end()) {
                    cfg->trackedIds.push_back(std::move(id));
                }
            }
        }
        m_configSnap = std::move(cfg);
        if (sanitizedTrackedIds) {
            AtomicWriteText(path, SerializeConfigJson(*m_configSnap).dump(2));
        }
        return true;
    } catch (...) {
        return false;
    }
}

void IpcBridge::SaveConfig(const ModConfig& cfg) {
    {
        std::lock_guard<std::mutex> ioLock(m_ioMutex);
        m_pendingConfigData = cfg;
        m_pendingConfigSave = true;
    }
    m_ioCv.notify_one();
}

void IpcBridge::UpdateConfigAndSave(const ModConfig& cfg) {
    auto snap = std::make_shared<ModConfig>(cfg);
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_configSnap = std::move(snap);
    }
    SaveConfig(cfg);
}

void IpcBridge::PushAction(const std::string& type, const std::string& payload, float x, float y, float z) {
    PendingAction act;
    {
        std::lock_guard<std::mutex> ioLock(m_ioMutex);
        act.seq = ++m_actionSeq;
        act.type = type;
        act.payload = payload;
        act.x = x;
        act.y = y;
        act.z = z;
        // 避免队列无限增长（保留最新 16 条即可）
        if (m_pendingActions.size() >= 16) {
            m_pendingActions.pop_front();
        }
        m_pendingActions.push_back(std::move(act));
    }
    m_ioCv.notify_one();
}

void IpcBridge::FlushPendingWritesOnWorker() {
    bool doConfig = false;
    ModConfig cfgToWrite;
    std::deque<PendingAction> actsToWrite;

    {
        std::lock_guard<std::mutex> ioLock(m_ioMutex);
        if (m_pendingConfigSave) {
            doConfig = true;
            cfgToWrite = m_pendingConfigData;
            m_pendingConfigSave = false;
        }
        if (!m_pendingActions.empty()) {
            actsToWrite.swap(m_pendingActions);
        }
    }

    if (doConfig && !m_dataDir.empty()) {
        AtomicWriteText(m_dataDir + L"\\config.json", SerializeConfigJson(cfgToWrite).dump(2));
    }

    if (!actsToWrite.empty() && !m_dataDir.empty()) {
        const std::wstring actionsPath = m_dataDir + L"\\actions.json";
        // 若磁盘上的 actions.json 已被 Lua 通过原子重命名认领走，则清空上一批缓冲；
        // 若仍存在则按已确认的 lastActionSeq 裁剪旧指令后再把新指令追加合并，确保交错并发读写 0 丢单。
        if (GetFileAttributesW(actionsPath.c_str()) == INVALID_FILE_ATTRIBUTES) {
            m_unconsumedActions.clear();
        } else {
            const int acked = m_lastAckedActionSeq.load(std::memory_order_acquire);
            while (!m_unconsumedActions.empty() && m_unconsumedActions.front().seq <= acked) {
                m_unconsumedActions.pop_front();
            }
        }
        for (auto& act : actsToWrite) {
            // 合并多余的连续静默目录软刷新，保留高优先级用户操作不丢失
            if (act.type == "refresh_catalog_soft" && !m_unconsumedActions.empty() &&
                m_unconsumedActions.back().type == "refresh_catalog_soft") {
                m_unconsumedActions.back() = std::move(act);
                continue;
            }
            if (m_unconsumedActions.size() >= 32) {
                m_unconsumedActions.pop_front();
            }
            m_unconsumedActions.push_back(std::move(act));
        }

        json arr = json::array();
        for (const auto& a : m_unconsumedActions) {
            arr.push_back({
                {"session", m_actionSession},
                {"seq", a.seq},
                {"type", a.type},
                {"payload", a.payload},
                {"x", a.x},
                {"y", a.y},
                {"z", a.z},
            });
        }
        json batch = {
            {"session", m_actionSession},
            {"actions", std::move(arr)},
        };
        AtomicWriteText(actionsPath, batch.dump());
    }
}

void IpcBridge::PollFilesOnWorker() {
    if (m_dataDir.empty()) return;
    unsigned long long now = GetTickCount64();

    // 高频通道（每 ~40ms）：仅在 map_live.json 修改时间戳变化时解析并替换不可变快照
    if (now - m_lastFastPollTick >= 40) {
        m_lastFastPollTick = now;
        std::string txt;
        if (ReadFileIfChanged(m_dataDir + L"\\map_live.json", m_mapLiveMtime, txt)) {
            try {
                json j = json::parse(txt);
                auto st = std::make_shared<MapLiveState>();
                st->mapOpen = j.value("mapOpen", false);
                st->hasTransform = j.value("hasTransform", false);
                st->vpW = j.value("vpW", 0.0f);
                st->vpH = j.value("vpH", 0.0f);
                st->clipX0 = j.value("clipX0", 0.0f);
                st->clipY0 = j.value("clipY0", 0.0f);
                st->clipX1 = j.value("clipX1", 0.0f);
                st->clipY1 = j.value("clipY1", 0.0f);
                st->p0x = j.value("p0x", 0.0f);
                st->p0y = j.value("p0y", 0.0f);
                st->pxx = j.value("pxx", 0.0f);
                st->pxy = j.value("pxy", 0.0f);
                st->pyx = j.value("pyx", 0.0f);
                st->pyy = j.value("pyy", 0.0f);
                st->panelAddr = ParseAddrField(j, "panelAddr");
                st->canvasAddr = ParseAddrField(j, "canvasAddr");
                st->fallbackCanvasAddr = ParseAddrField(j, "fallbackCanvasAddr");
                st->borderAddr = ParseAddrField(j, "borderAddr");
                st->rootWinAddr = ParseAddrField(j, "rootWinAddr");
                st->playerIconAddr = ParseAddrField(j, "playerIconAddr");
                st->minBoundsX = j.value("minBoundsX", 0.0f);
                st->minBoundsY = j.value("minBoundsY", 0.0f);
                st->maxBoundsX = j.value("maxBoundsX", 0.0f);
                st->maxBoundsY = j.value("maxBoundsY", 0.0f);
                st->texSizeX = j.value("texSizeX", 0.0f);
                st->texSizeY = j.value("texSizeY", 0.0f);
                st->hasPlayerPos = j.value("hasPlayerPos", false);
                st->playerX = j.value("playerX", 0.0f);
                st->playerY = j.value("playerY", 0.0f);
                st->playerZ = j.value("playerZ", 0.0f);

                if (j.contains("pins") && j["pins"].is_array()) {
                    st->pins.reserve(j["pins"].size());
                    for (const auto& item : j["pins"]) {
                        MapPin pin;
                        pin.id = item.value("id", "");
                        pin.name = item.value("n", "");
                        pin.category = item.value("cat", "");
                        pin.wx = item.value("x", 0.0f);
                        pin.wy = item.value("y", 0.0f);
                        pin.wz = item.value("z", 0.0f);
                        pin.colorIndex = item.value("c", 0);
                        pin.collected = item.value("col", false);
                        st->pins.push_back(std::move(pin));
                    }
                }
                bool isOpen = st->mapOpen;
                {
                    std::lock_guard<std::mutex> lock(m_mutex);
                    m_mapLiveSnap = std::move(st);
                }
                m_mapOpenFast.store(isOpen, std::memory_order_relaxed);
            } catch (...) {
                // 忽略偶发文件替换瞬间的读取竞争，下轮自动重试
                m_mapLiveMtime = 0;
            }
        }
    }

    // 低频通道（每 ~350ms）：仅在 status.json 或 catalog.json 变更时解析并替换不可变快照
    if (now - m_lastSlowPollTick >= 350) {
        m_lastSlowPollTick = now;
        std::string txt;
        if (ReadFileIfChanged(m_dataDir + L"\\status.json", m_statusMtime, txt)) {
            try {
                json j = json::parse(txt);
                auto rs = std::make_shared<RuntimeStatus>();
                rs->inWorld = j.value("inWorld", false);
                rs->isHost = j.value("isHost", true);
                rs->difficulty = j.value("difficulty", "未知");
                rs->livePlayerDamage = j.value("livePlayerDamage", 1.0f);
                rs->liveEnemyDamage = j.value("liveEnemyDamage", 1.0f);
                rs->liveKeepInventoryOnDeath = j.value("liveKeepInventoryOnDeath", false);
                rs->liveNoDeathDurabilityPenalty = j.value("liveNoDeathDurabilityPenalty", false);
                rs->uncollectedMilkMolars = j.value("uncollectedMilkMolars", 0);
                rs->uncollectedMegaMolars = j.value("uncollectedMegaMolars", 0);
                rs->totalMilkMolars = j.value("totalMilkMolars", 0);
                rs->totalMegaMolars = j.value("totalMegaMolars", 0);
                rs->catalogCount = j.value("catalogCount", 0);
                rs->lootCompCount = j.value("lootCompCount", 0);
                rs->stackSummary = j.value("stackSummary", "");
                rs->surveyedItemName = j.value("surveyedItemName", "");
                rs->lastMessage = j.value("lastMessage", "");
                // 仅当 status.json 回传的 lastActionSession 与本进程会话严格一致时，才采信 lastActionSeq 裁剪队列；
                // 重启后若磁盘上仍残留上次会话的 status.json（如 lastActionSeq=8 或缺少 session），必须完全忽略，防止误删新会话 seq=1！
                std::string ackedSession;
                if (auto itS = j.find("lastActionSession"); itS != j.end() && itS->is_string()) {
                    ackedSession = itS->get<std::string>();
                }
                int ackedSeq = 0;
                if (auto itQ = j.find("lastActionSeq"); itQ != j.end() && itQ->is_number_integer()) {
                    ackedSeq = itQ->get<int>();
                }
                if (!ackedSession.empty() && ackedSession == m_actionSession &&
                    ackedSeq > m_lastAckedActionSeq.load(std::memory_order_relaxed)) {
                    m_lastAckedActionSeq.store(ackedSeq, std::memory_order_release);
                }
                std::lock_guard<std::mutex> lock(m_mutex);
                m_statusSnap = std::move(rs);
            } catch (...) {
                m_statusMtime = 0;
            }
        }

        if (ReadFileIfChanged(m_dataDir + L"\\catalog.json", m_catalogMtime, txt)) {
            try {
                json j = json::parse(txt);
                auto list = std::make_shared<std::vector<CatalogEntry>>();
                if (j.is_array()) {
                    list->reserve(j.size());
                    for (const auto& item : j) {
                        CatalogEntry e;
                        e.id = item.value("id", "");
                        e.name = item.value("name", "");
                        e.rawName = item.value("rawName", "");
                        e.category = item.value("category", "item");
                        e.count = item.value("count", 0);
                        e.surveyable = item.value("surveyable", false);
                        e.rowName = item.value("rowName", "");
                        if (!e.id.empty()) {
                            list->push_back(std::move(e));
                        }
                    }
                }
                {
                    std::lock_guard<std::mutex> lock(m_mutex);
                    m_catalogSnap = std::move(list);
                }
                m_lastCatalogUpdateTick.store(GetTickCount64(), std::memory_order_relaxed);
            } catch (...) {
                m_catalogMtime = 0;
            }
        }
    }
}

void IpcBridge::IoWorkerLoop() {
    while (!m_stopIo.load(std::memory_order_acquire)) {
        FlushPendingWritesOnWorker();
        PollFilesOnWorker();

        std::unique_lock<std::mutex> ioLock(m_ioMutex);
        m_ioCv.wait_for(ioLock, std::chrono::milliseconds(40), [this]() {
            return m_stopIo.load(std::memory_order_acquire) || m_pendingConfigSave || !m_pendingActions.empty();
        });
    }
    // 仅在显式 FreeLibrary 卸载时补写最后一笔未落盘配置；进程终止阶段直接返回，避免磁盘 I/O 与退出竞争
    if (!m_processTerminating.load(std::memory_order_acquire)) {
        FlushPendingWritesOnWorker();
    }
}

std::shared_ptr<const ModConfig> IpcBridge::GetConfigSnapshot() {
    std::lock_guard<std::mutex> lock(m_mutex);
    return m_configSnap;
}

std::shared_ptr<const std::vector<CatalogEntry>> IpcBridge::GetCatalogSnapshot() {
    std::lock_guard<std::mutex> lock(m_mutex);
    return m_catalogSnap;
}

std::shared_ptr<const MapLiveState> IpcBridge::GetMapLiveSnapshot() {
    std::lock_guard<std::mutex> lock(m_mutex);
    return m_mapLiveSnap;
}

std::shared_ptr<const RuntimeStatus> IpcBridge::GetStatusSnapshot() {
    std::lock_guard<std::mutex> lock(m_mutex);
    return m_statusSnap;
}

ModConfig IpcBridge::GetConfigCopy() {
    return *GetConfigSnapshot();
}

std::vector<CatalogEntry> IpcBridge::GetCatalogCopy() {
    return *GetCatalogSnapshot();
}

MapLiveState IpcBridge::GetMapLiveCopy() {
    return *GetMapLiveSnapshot();
}

RuntimeStatus IpcBridge::GetStatusCopy() {
    return *GetStatusSnapshot();
}

} // namespace gqol
