/*
 * 文件：overlay/src/ipc.cpp
 * 职责：实现 IpcBridge 的原子 JSON 文件读写、时间戳去重轮询与线程安全状态快照分发。
 * 并发说明：
 *   - 渲染线程（Present）调用 PollFromLua / Get*Copy / UpdateConfigAndSave；
 *   - 窗口消息线程（WndProc）调用 PushAction；
 *   - 后台启动线程调用 Initialize。
 *   所有内存状态访问均通过 m_mutex 保护，跨进程文件交互依赖 MoveFileExW 原子替换并容忍偶发解析重试。
 */

#include "ipc.h"

#include <Windows.h>
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
        {"trackedIds", cfg.trackedIds},
    };
}

} // namespace

IpcBridge& IpcBridge::Instance() {
    static IpcBridge inst;
    return inst;
}

void IpcBridge::Initialize(const std::wstring& dllDirectory) {
    std::lock_guard<std::mutex> lock(m_mutex);
    m_dataDir = dllDirectory;
    if (!m_dataDir.empty() && m_dataDir.back() != L'\\' && m_dataDir.back() != L'/') {
        m_dataDir.push_back(L'\\');
    }
    m_dataDir += L"data";
    CreateDirectoryW(m_dataDir.c_str(), nullptr);

    if (!LoadConfigLocked()) {
        // 首次启动或旧配置文件损坏时写出完整默认配置，确保 Lua 端立即可读取
        AtomicWriteText(m_dataDir + L"\\config.json", SerializeConfigJson(m_config).dump(2));
    }
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
    // 使用 MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH 确保跨线程/跨脚本不会读到未写完的半截文件
    return MoveFileExW(tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0;
}

bool IpcBridge::LoadConfigLocked() {
    std::wstring path = m_dataDir + L"\\config.json";
    std::ifstream ifs(path, std::ios::binary);
    if (!ifs.is_open()) {
        return false;
    }
    try {
        json j = json::parse(ifs);
        ModConfig cfg;
        // 对每个字段使用默认值兜底，确保旧版本升级后新增字段平滑兼容
        cfg.stackEnabled = j.value("stackEnabled", cfg.stackEnabled);
        cfg.stackMultiplier = j.value("stackMultiplier", cfg.stackMultiplier);
        cfg.damageEnabled = j.value("damageEnabled", cfg.damageEnabled);
        cfg.playerDamageMultiplier = j.value("playerDamageMultiplier", cfg.playerDamageMultiplier);
        cfg.enemyDamageMultiplier = j.value("enemyDamageMultiplier", cfg.enemyDamageMultiplier);
        cfg.harvestEnabled = j.value("harvestEnabled", cfg.harvestEnabled);
        cfg.harvestMultiplier = j.value("harvestMultiplier", cfg.harvestMultiplier);
        cfg.harvestAffectHauling = j.value("harvestAffectHauling", cfg.harvestAffectHauling);
        cfg.harvestAffectPickup = j.value("harvestAffectPickup", cfg.harvestAffectPickup);
        cfg.instantBuildEnabled = j.value("instantBuildEnabled", cfg.instantBuildEnabled);
        cfg.freeCraftEnabled = j.value("freeCraftEnabled", cfg.freeCraftEnabled);
        cfg.unlockAllRecipes = j.value("unlockAllRecipes", cfg.unlockAllRecipes);
        cfg.keepInventoryOnDeath = j.value("keepInventoryOnDeath", cfg.keepInventoryOnDeath);
        cfg.noDeathDurabilityPenalty = j.value("noDeathDurabilityPenalty", cfg.noDeathDurabilityPenalty);
        cfg.showMilkMolars = j.value("showMilkMolars", cfg.showMilkMolars);
        cfg.showMegaMilkMolars = j.value("showMegaMilkMolars", cfg.showMegaMilkMolars);
        cfg.showScabColors = j.value("showScabColors", cfg.showScabColors);
        cfg.showCollectedMolars = j.value("showCollectedMolars", cfg.showCollectedMolars);
        cfg.showMapLabels = j.value("showMapLabels", cfg.showMapLabels);
        cfg.showMapLegend = j.value("showMapLegend", cfg.showMapLegend);
        cfg.mapIconScale = j.value("mapIconScale", cfg.mapIconScale);
        if (j.contains("trackedIds") && j["trackedIds"].is_array()) {
            cfg.trackedIds = j["trackedIds"].get<std::vector<std::string>>();
        }
        m_config = std::move(cfg);
        return true;
    } catch (...) {
        return false;
    }
}

void IpcBridge::SaveConfig(const ModConfig& cfg) {
    AtomicWriteText(m_dataDir + L"\\config.json", SerializeConfigJson(cfg).dump(2));
}

void IpcBridge::UpdateConfigAndSave(const ModConfig& cfg) {
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_config = cfg;
    }
    SaveConfig(cfg);
}

void IpcBridge::PushAction(const std::string& type, const std::string& payload, float x, float y, float z) {
    int seq = 0;
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        seq = ++m_actionSeq;
    }
    json j = {
        {"seq", seq},
        {"type", type},
        {"payload", payload},
        {"x", x},
        {"y", y},
        {"z", z},
    };
    AtomicWriteText(m_dataDir + L"\\actions.json", j.dump());
}

void IpcBridge::PollFromLua() {
    if (m_dataDir.empty()) return;
    unsigned long long now = GetTickCount64();

    // 高频通道：轮询 M 地图实时状态（约 40Hz 间隔，仅在文件修改时间戳变更时真正解析 JSON）
    if (now - m_lastFastPollTick >= 25) {
        m_lastFastPollTick = now;
        std::string txt;
        if (ReadFileIfChanged(m_dataDir + L"\\map_live.json", m_mapLiveMtime, txt)) {
            try {
                json j = json::parse(txt);
                MapLiveState st;
                st.mapOpen = j.value("mapOpen", false);
                st.hasTransform = j.value("hasTransform", false);
                st.vpW = j.value("vpW", 0.0f);
                st.vpH = j.value("vpH", 0.0f);
                st.clipX0 = j.value("clipX0", 0.0f);
                st.clipY0 = j.value("clipY0", 0.0f);
                st.clipX1 = j.value("clipX1", 0.0f);
                st.clipY1 = j.value("clipY1", 0.0f);
                st.p0x = j.value("p0x", 0.0f);
                st.p0y = j.value("p0y", 0.0f);
                st.pxx = j.value("pxx", 0.0f);
                st.pxy = j.value("pxy", 0.0f);
                st.pyx = j.value("pyx", 0.0f);
                st.pyy = j.value("pyy", 0.0f);
                st.panelAddr = ParseAddrField(j, "panelAddr");
                st.canvasAddr = ParseAddrField(j, "canvasAddr");
                st.fallbackCanvasAddr = ParseAddrField(j, "fallbackCanvasAddr");
                st.borderAddr = ParseAddrField(j, "borderAddr");
                st.rootWinAddr = ParseAddrField(j, "rootWinAddr");
                st.playerIconAddr = ParseAddrField(j, "playerIconAddr");
                st.minBoundsX = j.value("minBoundsX", 0.0f);
                st.minBoundsY = j.value("minBoundsY", 0.0f);
                st.maxBoundsX = j.value("maxBoundsX", 0.0f);
                st.maxBoundsY = j.value("maxBoundsY", 0.0f);
                st.texSizeX = j.value("texSizeX", 0.0f);
                st.texSizeY = j.value("texSizeY", 0.0f);
                st.hasPlayerPos = j.value("hasPlayerPos", false);
                st.playerX = j.value("playerX", 0.0f);
                st.playerY = j.value("playerY", 0.0f);
                st.playerZ = j.value("playerZ", 0.0f);

                if (j.contains("pins") && j["pins"].is_array()) {
                    st.pins.reserve(j["pins"].size());
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
                        st.pins.push_back(std::move(pin));
                    }
                }
                std::lock_guard<std::mutex> lock(m_mutex);
                m_mapLive = std::move(st);
            } catch (...) {
                // 忽略偶发文件替换瞬间的读取竞争，下一轮心跳会自动重试
            }
        }
    }

    // 低频通道：轮询运行时状态摘要与全图资源目录（约 2Hz）
    if (now - m_lastSlowPollTick >= 450) {
        m_lastSlowPollTick = now;
        std::string txt;
        if (ReadFileIfChanged(m_dataDir + L"\\status.json", m_statusMtime, txt)) {
            try {
                json j = json::parse(txt);
                RuntimeStatus rs;
                rs.inWorld = j.value("inWorld", false);
                rs.isHost = j.value("isHost", true);
                rs.difficulty = j.value("difficulty", "未知");
                rs.livePlayerDamage = j.value("livePlayerDamage", 1.0f);
                rs.liveEnemyDamage = j.value("liveEnemyDamage", 1.0f);
                rs.liveKeepInventoryOnDeath = j.value("liveKeepInventoryOnDeath", false);
                rs.liveNoDeathDurabilityPenalty = j.value("liveNoDeathDurabilityPenalty", false);
                rs.uncollectedMilkMolars = j.value("uncollectedMilkMolars", 0);
                rs.uncollectedMegaMolars = j.value("uncollectedMegaMolars", 0);
                rs.totalMilkMolars = j.value("totalMilkMolars", 0);
                rs.totalMegaMolars = j.value("totalMegaMolars", 0);
                rs.catalogCount = j.value("catalogCount", 0);
                rs.lootCompCount = j.value("lootCompCount", 0);
                rs.stackSummary = j.value("stackSummary", "");
                rs.surveyedItemName = j.value("surveyedItemName", "");
                rs.lastMessage = j.value("lastMessage", "");
                std::lock_guard<std::mutex> lock(m_mutex);
                m_status = std::move(rs);
            } catch (...) {
            }
        }

        if (ReadFileIfChanged(m_dataDir + L"\\catalog.json", m_catalogMtime, txt)) {
            try {
                json j = json::parse(txt);
                std::vector<CatalogEntry> list;
                if (j.is_array()) {
                    list.reserve(j.size());
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
                            list.push_back(std::move(e));
                        }
                    }
                }
                std::lock_guard<std::mutex> lock(m_mutex);
                m_catalog = std::move(list);
            } catch (...) {
            }
        }
    }
}

ModConfig IpcBridge::GetConfigCopy() {
    std::lock_guard<std::mutex> lock(m_mutex);
    return m_config;
}

std::vector<CatalogEntry> IpcBridge::GetCatalogCopy() {
    std::lock_guard<std::mutex> lock(m_mutex);
    return m_catalog;
}

MapLiveState IpcBridge::GetMapLiveCopy() {
    std::lock_guard<std::mutex> lock(m_mutex);
    return m_mapLive;
}

RuntimeStatus IpcBridge::GetStatusCopy() {
    std::lock_guard<std::mutex> lock(m_mutex);
    return m_status;
}

} // namespace gqol
