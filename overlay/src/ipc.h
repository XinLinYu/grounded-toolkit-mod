#pragma once

#include <cstdint>
#include <mutex>
#include <string>
#include <unordered_set>
#include <vector>

namespace gqol {

/// 插件持久化配置，与 Lua 逻辑层通过 data/config.json 双向同步。
struct ModConfig {
    bool stackEnabled = true;
    int stackMultiplier = 10;

    bool damageEnabled = true;
    float playerDamageMultiplier = 1.5f;
    float enemyDamageMultiplier = 1.0f;

    bool harvestEnabled = true;
    int harvestMultiplier = 3;
    bool harvestAffectHauling = true;
    bool harvestAffectPickup = true;

    // 建造与工作台免费秒做（无需任何材料）
    bool instantBuildEnabled = false;
    bool freeCraftEnabled = false;
    bool unlockAllRecipes = false;

    bool showMilkMolars = true;
    bool showMegaMilkMolars = true;
    bool showScabColors = false;
    bool showCollectedMolars = false;
    bool showMapLabels = false;
    bool showMapLegend = true;
    float mapIconScale = 1.0f;

    std::vector<std::string> trackedIds;
};

/// 单个可追踪条目（物品、资源、采集点、生物或特殊收集品）。
struct CatalogEntry {
    std::string id;        // 唯一键，如 item:MintChunk / node:BP_Rock_Clay_C / creature:BP_Spider_Wolf_C
    std::string name;      // 官方简体中文名
    std::string rawName;   // 内部英文 RowName 或类名，便于中英双语检索
    std::string category;  // 分类：collectible / item / node / creature / survey / special
    int count = 0;         // 世界中当前检测到的实例数量
    bool surveyable = false;
    std::string rowName;   // 若可联动原版资源扫描仪，对应的 AllItemsTable RowName
};

/// M 地图实时渲染用的单个标点。
struct MapPin {
    std::string id;
    std::string name;
    std::string category;
    float wx = 0.0f;
    float wy = 0.0f;
    float wz = 0.0f;
    int colorIndex = 0;    // -1=普通乳牙, -2=高级乳牙, -3=SCA.B, -4=已采集乳牙, >=0 自由追踪色板
    bool collected = false;
};

/// M 地图屏幕投影与实时状态（Lua 仅在 M 地图打开时高频更新）。
struct MapLiveState {
    bool mapOpen = false;
    bool hasTransform = false;
    float vpW = 1920.0f;
    float vpH = 1080.0f;

    // 地图边框裁剪区域（Viewport 物理像素坐标）
    float clipX0 = 0.0f;
    float clipY0 = 0.0f;
    float clipX1 = 0.0f;
    float clipY1 = 0.0f;

    // 3 点仿射投影基准：P0=(0,0), Px=(10000,0), Py=(0,10000) 对应的屏幕像素坐标（兜底/测试模式）
    float p0x = 0.0f, p0y = 0.0f;
    float pxx = 0.0f, pxy = 0.0f;
    float pyx = 0.0f, pyy = 0.0f;

    // Grounded 原生 UWidget 内存地址与地图世界边界（C++ 每帧直接读取 Slate FGeometry，实现零延迟精准投影）
    uint64_t panelAddr = 0;
    uint64_t canvasAddr = 0;
    uint64_t fallbackCanvasAddr = 0;
    uint64_t borderAddr = 0;
    uint64_t rootWinAddr = 0;
    uint64_t playerIconAddr = 0;
    float minBoundsX = 0.0f, minBoundsY = 0.0f;
    float maxBoundsX = 0.0f, maxBoundsY = 0.0f;
    float texSizeX = 0.0f, texSizeY = 0.0f;

    float playerX = 0.0f;
    float playerY = 0.0f;
    float playerZ = 0.0f;
    bool hasPlayerPos = false;

    std::vector<MapPin> pins;
};

/// Lua 端上报的运行时状态摘要，用于菜单顶部状态栏展示。
struct RuntimeStatus {
    bool inWorld = false;
    bool isHost = true;
    std::string difficulty = "未知";
    float livePlayerDamage = 1.0f;
    float liveEnemyDamage = 1.0f;
    int uncollectedMilkMolars = 0;
    int uncollectedMegaMolars = 0;
    int totalMilkMolars = 0;
    int totalMegaMolars = 0;
    int catalogCount = 0;
    int lootCompCount = 0;
    std::string stackSummary;
    std::string surveyedItemName;
    std::string lastMessage;
};

/// 负责在 C++ 悬浮层与 UE4SS Lua 之间通过原子文件 IPC 交换 JSON 状态。
class IpcBridge {
public:
    static IpcBridge& Instance();

    /// 根据当前 DLL 所在路径初始化 data/ 通信目录并读取已有配置。
    void Initialize(const std::wstring& dllDirectory);

    /// 每帧/定时刷新来自 Lua 的 catalog / map_live / status 数据。
    void PollFromLua();

    /// 原子写入最新配置到 data/config.json，供 Lua 立即生效并持久化。
    void SaveConfig(const ModConfig& cfg);

    /// 发送一次性操作指令给 Lua（如放置路标、解锁扫描仪、扫描原版热区、重扫资源）。
    void PushAction(const std::string& type, const std::string& payload = "",
                    float x = 0.0f, float y = 0.0f, float z = 0.0f);

    ModConfig GetConfigCopy();
    void UpdateConfigAndSave(const ModConfig& cfg);
    std::vector<CatalogEntry> GetCatalogCopy();
    MapLiveState GetMapLiveCopy();
    RuntimeStatus GetStatusCopy();
    std::wstring GetDataDir() const { return m_dataDir; }

private:
    IpcBridge() = default;

    bool LoadConfigLocked();
    bool ReadFileIfChanged(const std::wstring& path, unsigned long long& lastMtime, std::string& outText);
    bool AtomicWriteText(const std::wstring& path, const std::string& content);

    std::wstring m_dataDir;
    std::mutex m_mutex;

    ModConfig m_config;
    std::vector<CatalogEntry> m_catalog;
    MapLiveState m_mapLive;
    RuntimeStatus m_status;

    unsigned long long m_catalogMtime = 0;
    unsigned long long m_mapLiveMtime = 0;
    unsigned long long m_statusMtime = 0;
    unsigned long long m_lastSlowPollTick = 0;
    unsigned long long m_lastFastPollTick = 0;
    int m_actionSeq = 0;
};

} // namespace gqol
