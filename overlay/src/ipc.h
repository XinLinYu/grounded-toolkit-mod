/*
 * 文件：overlay/src/ipc.h
 * 职责：定义 C++ 悬浮层与 UE4SS Lua 逻辑层之间基于原子 JSON 文件通信的数据结构与桥接类。
 * 通信约定（位于 GroundedQoL/data/ 目录）：
 *   - config.json   : C++ 写 / Lua 读，保存全部可持久化开关与追踪列表
 *   - actions.json  : C++ 写 / Lua 消费后删除，传递带递增序列号的一次性指令（如找回背包、放路标）
 *   - status.json   : Lua 写 / C++ 读，上报当前存档/房主权限/实时倍率与死亡保护状态
 *   - catalog.json  : Lua 写 / C++ 读，上报全图资源与生物目录
 *   - map_live.json : Lua 写 / C++ 读，M 地图打开时高频上报控件指针、地图边界与标点列表
 */

#pragma once

#include <cstdint>
#include <mutex>
#include <string>
#include <unordered_set>
#include <vector>

namespace gqol {

/// 插件持久化配置，与 Lua 逻辑层通过 data/config.json 双向同步。
struct ModConfig {
    // 1. 物品堆叠上限倍率
    bool stackEnabled = true;
    int stackMultiplier = 10;

    // 2. 战斗伤害倍率
    bool damageEnabled = true;
    float playerDamageMultiplier = 1.5f;
    float enemyDamageMultiplier = 1.0f;

    // 3. 采集与掉落数量倍率
    bool harvestEnabled = true;
    int harvestMultiplier = 3;
    bool harvestAffectHauling = true;
    bool harvestAffectPickup = true;

    // 4. 建造与工作台免费秒做（无需任何材料）
    bool instantBuildEnabled = false;
    bool freeCraftEnabled = false;
    bool unlockAllRecipes = false;

    // 5. 死亡保护（默认关闭，仅在房主端原地覆写运行时设置，不影响 Steam 成就）
    bool keepInventoryOnDeath = false;      ///< 死亡背包保留：死亡时保留背包内全部物品、不生成掉落背包
    bool noDeathDurabilityPenalty = false;  ///< 独立可选：免除死亡时已穿戴装备的耐久度惩罚

    // 6. “M” 地图追踪显示开关
    bool showMilkMolars = true;
    bool showMegaMilkMolars = true;
    bool showScabColors = false;
    bool showCollectedMolars = false;
    bool showMapLabels = false;
    bool showMapLegend = true;
    float mapIconScale = 1.0f;

    std::vector<std::string> trackedIds;    ///< 用户勾选的自由追踪条目 ID 列表
};

/// 单个可追踪条目（物品、资源、采集点、生物或特殊收集品）。
struct CatalogEntry {
    std::string id;        ///< 唯一键，如 item:MintChunk / node:BP_Rock_Clay_C / creature:BP_Spider_Wolf_C
    std::string name;      ///< 官方简体中文显示名
    std::string rawName;   ///< 内部英文 RowName 或蓝图类名，支持中英双语检索
    std::string category;  ///< 分类：collectible / item / node / creature / survey / special
    int count = 0;         ///< 世界中当前检测到的存活实例数量
    bool surveyable = false; ///< 是否可联动游戏原版资源扫描仪热区
    std::string rowName;   ///< 对应 AllItemsTable 的 RowName（供原版扫描仪使用）
};

/// M 地图实时渲染用的单个标点。
struct MapPin {
    std::string id;
    std::string name;
    std::string category;
    float wx = 0.0f;       ///< UE 世界坐标 X（cm）
    float wy = 0.0f;       ///< UE 世界坐标 Y（cm）
    float wz = 0.0f;       ///< UE 世界坐标 Z（高度，cm）
    int colorIndex = 0;    ///< -1=普通乳牙, -2=高级乳牙, -3=SCA.B, -4=已采集乳牙, >=0 自由追踪 12 色板索引
    bool collected = false;
};

/// M 地图屏幕投影与实时状态（Lua 仅在 M 地图打开时高频更新）。
struct MapLiveState {
    bool mapOpen = false;
    bool hasTransform = false;
    float vpW = 1920.0f;
    float vpH = 1080.0f;

    // 地图边框裁剪区域（Viewport 物理像素坐标，仅在仿射兜底/测试模式使用）
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

/// Lua 端上报的运行时状态摘要，用于菜单顶部状态栏与权限控制展示。
struct RuntimeStatus {
    bool inWorld = false;                   ///< 是否已进入可游玩存档
    bool isHost = true;                     ///< 是否具备房主权威（客机为 false）
    std::string difficulty = "未知";        ///< 当前存档难度显示名
    float livePlayerDamage = 1.0f;          ///< 游戏内实时生效的玩家伤害倍率
    float liveEnemyDamage = 1.0f;           ///< 游戏内实时生效的怪物伤害倍率
    bool liveKeepInventoryOnDeath = false;  ///< 游戏内实时生效的死亡背包保留状态
    bool liveNoDeathDurabilityPenalty = false; ///< 游戏内实时生效的死亡耐久惩罚免除状态
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

/// 线程安全的单例 IPC 桥接器：在图形渲染线程、WndProc 回调与后台初始化线程间共享快照。
class IpcBridge {
public:
    static IpcBridge& Instance();

    /// 根据当前 DLL 所在目录初始化 data/ 通信目录并加载已有配置（首次启动自动写出默认 config.json）。
    void Initialize(const std::wstring& dllDirectory);

    /// 在 Present 帧内按高低频节流轮询来自 Lua 的 map_live / status / catalog 文件更新。
    void PollFromLua();

    /// 将指定配置原子写入 data/config.json，供 Lua 立即读取并持久化。
    void SaveConfig(const ModConfig& cfg);

    /// 向 data/actions.json 推送带递增序列号的一次性操作指令（如找回背包、放置路标、解锁扫描仪等）。
    void PushAction(const std::string& type, const std::string& payload = "",
                    float x = 0.0f, float y = 0.0f, float z = 0.0f);

    /// 获取当前内存配置的线程安全拷贝。
    ModConfig GetConfigCopy();

    /// 更新内存配置并立即原子落盘。
    void UpdateConfigAndSave(const ModConfig& cfg);

    /// 获取全图资源目录快照。
    std::vector<CatalogEntry> GetCatalogCopy();

    /// 获取 M 地图实时渲染状态快照。
    MapLiveState GetMapLiveCopy();

    /// 获取 Lua 端上报的运行时状态快照。
    RuntimeStatus GetStatusCopy();

    /// 返回 data/ 通信目录的绝对宽字符路径。
    std::wstring GetDataDir() const { return m_dataDir; }

private:
    IpcBridge() = default;

    /// 在持有 m_mutex 的前提下从 data/config.json 加载配置。
    bool LoadConfigLocked();

    /// 仅当目标文件修改时间戳（FILETIME）发生变化时重新读取完整文本，减少无意义磁盘 I/O。
    bool ReadFileIfChanged(const std::wstring& path, unsigned long long& lastMtime, std::string& outText);

    /// 通过写 .tmp 临时文件 + MoveFileExW(REPLACE_EXISTING) 原子替换目标文件。
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
