/*
 * 文件：overlay/src/ipc.h
 * 职责：定义 C++ 悬浮层与 UE4SS Lua 逻辑层之间基于原子 JSON 文件通信的数据结构与异步桥接类。
 * 架构说明（见 ADR-0004）：
 *   - 全部磁盘轮询（map_live / status / catalog）与原子写盘（config / actions）均在独立后台 I/O 线程执行，
 *     彻底消除 DX12/DX11 Present 渲染线程与 WndProc 窗口线程上的文件 I/O 与 JSON 解析卡顿。
 *   - 渲染线程通过 std::shared_ptr<const ...> 获取不可变只读快照（O(1) 零拷贝）与 atomic 地图开启标志。
 * 通信约定（位于 GroundedQoL/data/ 目录）：
 *   - config.json   : C++ 写 / Lua 读，保存全部可持久化开关、输入法候选模式与追踪列表
 *   - actions.json  : C++ 写 / Lua 消费后删除，传递带递增序列号的一次性指令
 *   - status.json   : Lua 写 / C++ 读，上报当前存档/房主权限/实时倍率与死亡保护状态
 *   - catalog.json  : Lua 写 / C++ 读，上报全图资源与生物目录
 *   - map_live.json : Lua 写 / C++ 读，M 地图打开时上报控件指针、地图边界与标点列表
 */

#pragma once

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
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

    // 7. 中文输入法候选框显示模式（见 ADR-0003）
    //    0 = 自动（无边框/窗口走系统原生，独占全屏自动降级 ImGui 自绘）
    //    1 = 强制系统原生候选框
    //    2 = 强制内置自绘候选条
    int imeCandidateMode = 0;

    std::vector<std::string> trackedIds;    ///< 用户勾选的自由追踪条目 ID 列表
};

/// 单个可追踪条目（物品、资源、采集点、生物或特殊收集品）。
struct CatalogEntry {
    std::string id;          ///< 唯一键，如 item:MintChunk / node:BP_Rock_Clay_C / creature:BP_Spider_Wolf_C
    std::string name;        ///< 官方简体中文显示名
    std::string rawName;     ///< 内部英文 RowName 或蓝图类名，支持中英双语检索
    std::string category;    ///< 分类：collectible / item / node / creature / survey / special
    int count = 0;           ///< 世界中当前检测到的存活实例数量
    bool surveyable = false; ///< 是否可联动游戏原版资源扫描仪热区
    std::string rowName;     ///< 对应 AllItemsTable 的 RowName（供原版扫描仪使用）
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

/// M 地图屏幕投影与实时状态（Lua 仅在 M 地图打开时更新）。
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
    bool inWorld = false;                      ///< 是否已进入可游玩存档
    bool isHost = true;                        ///< 是否具备房主权威（客机为 false）
    std::string difficulty = "未知";            ///< 当前存档难度显示名
    float livePlayerDamage = 1.0f;             ///< 游戏内实时生效的玩家伤害倍率
    float liveEnemyDamage = 1.0f;              ///< 游戏内实时生效的怪物伤害倍率
    bool liveKeepInventoryOnDeath = false;     ///< 游戏内实时生效的死亡背包保留状态
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

/// 线程安全的异步单例 IPC 桥接器：所有文件 I/O 均由后台线程承担，渲染线程零阻塞只读共享快照。
class IpcBridge {
public:
    static IpcBridge& Instance();

    /// 初始化 data/ 通信目录、加载/写出 config.json，并启动后台异步 I/O 轮询与写盘线程。
    void Initialize(const std::wstring& dllDirectory);

    /// 停止后台 I/O 线程（processTerminating=true 时禁止 join，防止 DllMain 进程退出死锁）。
    void Shutdown(bool processTerminating = false);

    /// 兼容旧调用点：所有轮询已移至后台线程，此处仅做零开销空操作。
    void PollFromLua();

    /// 将指定配置入队交由后台线程原子写入 data/config.json。
    void SaveConfig(const ModConfig& cfg);

    /// 立即更新内存配置快照，并唤醒后台线程原子落盘（非阻塞）。
    void UpdateConfigAndSave(const ModConfig& cfg);

    /// 异步向 data/actions.json 推送带递增序列号的一次性操作指令（非阻塞）。
    void PushAction(const std::string& type, const std::string& payload = "",
                    float x = 0.0f, float y = 0.0f, float z = 0.0f);

    /// 无锁快速查询当前 M 地图是否打开（供 Present 空闲零开销直通路径使用）。
    bool IsMapOpenFast() const { return m_mapOpenFast.load(std::memory_order_relaxed); }

    /// 获取最近一次 catalog.json 更新的 GetTickCount64 时间戳（用于菜单打开 5 秒软刷新防抖）。
    unsigned long long GetLastCatalogUpdateTick() const {
        return m_lastCatalogUpdateTick.load(std::memory_order_relaxed);
    }

    /// 获取不可变共享快照（O(1) 零拷贝，供渲染线程每帧安全读取）。
    std::shared_ptr<const ModConfig> GetConfigSnapshot();
    std::shared_ptr<const std::vector<CatalogEntry>> GetCatalogSnapshot();
    std::shared_ptr<const MapLiveState> GetMapLiveSnapshot();
    std::shared_ptr<const RuntimeStatus> GetStatusSnapshot();

    /// 兼容接口：返回快照值拷贝。
    ModConfig GetConfigCopy();
    std::vector<CatalogEntry> GetCatalogCopy();
    MapLiveState GetMapLiveCopy();
    RuntimeStatus GetStatusCopy();

    /// 返回 data/ 通信目录的绝对宽字符路径。
    std::wstring GetDataDir() const { return m_dataDir; }

private:
    struct PendingAction {
        int seq = 0;
        std::string type;
        std::string payload;
        float x = 0.0f;
        float y = 0.0f;
        float z = 0.0f;
    };

    IpcBridge();
    ~IpcBridge();

    void IoWorkerLoop();
    void PollFilesOnWorker();
    void FlushPendingWritesOnWorker();

    bool LoadConfigLocked();
    bool ReadFileIfChanged(const std::wstring& path, unsigned long long& lastMtime, std::string& outText);
    bool AtomicWriteText(const std::wstring& path, const std::string& content);

    std::wstring m_dataDir;
    std::mutex m_mutex;

    std::shared_ptr<const ModConfig> m_configSnap;
    std::shared_ptr<const std::vector<CatalogEntry>> m_catalogSnap;
    std::shared_ptr<const MapLiveState> m_mapLiveSnap;
    std::shared_ptr<const RuntimeStatus> m_statusSnap;

    std::atomic<bool> m_mapOpenFast{false};
    std::atomic<unsigned long long> m_lastCatalogUpdateTick{0};
    std::atomic<int> m_lastAckedActionSeq{0};

    // 后台 I/O 线程状态与待落盘队列
    std::mutex m_ioMutex;
    std::condition_variable m_ioCv;
    std::thread m_ioThread;
    std::atomic<bool> m_stopIo{false};
    std::atomic<bool> m_processTerminating{false};
    bool m_ioStarted = false;
    bool m_pendingConfigSave = false;
    ModConfig m_pendingConfigData;
    std::deque<PendingAction> m_pendingActions;
    std::deque<PendingAction> m_unconsumedActions; ///< 仅后台线程访问：保留尚未被 Lua 消费删除的指令批次，避免连续点击相互覆盖

    unsigned long long m_catalogMtime = 0;
    unsigned long long m_mapLiveMtime = 0;
    unsigned long long m_statusMtime = 0;
    unsigned long long m_lastSlowPollTick = 0;
    unsigned long long m_lastFastPollTick = 0;
    std::string m_actionSession; ///< 当前进程会话唯一标识，确保旧会话 status.json 中的 lastActionSeq 绝不裁剪新会话队列
    int m_actionSeq = 0;
};

} // namespace gqol
