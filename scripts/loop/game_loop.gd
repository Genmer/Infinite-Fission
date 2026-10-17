# scripts/loop/game_loop.gd
# M-01 GameLoop（架构 §2.17）：状态机 / 固定帧序 / time_scale 唯一持有者 / Boot 序列。
# · 状态机：BOOT→MENU→PLAYING⇄PAUSED / PLAYING⇄LEVEL_UP / →GAME_OVER（迁移矩阵冻结，
#   E-16：player_died 优先级最高，GameOver 状态 level_up 请求丢弃 + 计数）。
# · 固定帧序（架构 §2.17，顺序禁止重排）：①输入 →②玩家(+武器开火——包2 Player.tick 落地口径)
#   →④双网格重建+投射物 →⑤敌+元素+帧末反应 →⑥波次 →⑦GameFeel(raw) →⑧UI(raw)。
# · 双时间通道（§8.7 冻结契约）：game_delta = raw × time_scale 是一切游戏逻辑唯一时间源；
#   顿帧 = GameFeelDirector 申请 → time_scale 短时 0.05，GameLoop 自行消费 raw 计算——
#   ★ 绝不写 Engine.time_scale（AC-15.1/E-11：无时间债跳变）。LEVEL_UP/PAUSED 用 tree.paused。
# · Boot：GameConfig → DataRegistry → 池×5 预热 → 子系统组装 → MENU（<3s 预算；xp 池待
#   集成包经验链路实体时补挂）。
# 编排说明：本类是 main.tscn 根（集成包组装）；headless 自测可直接实例化 + 手动驱动
# _physics_process(raw_delta)。
class_name GameLoop
extends Node2D

const SCENE_PLAYER := "res://scenes/combat/player/player.tscn"
const SCENE_PROJECTILE := "res://scenes/combat/projectiles/ballistic_projectile.tscn"
const SCENE_HOMING := "res://scenes/combat/projectiles/homing_projectile.tscn"
const SCENE_ENEMY := "res://scenes/combat/enemies/enemy.tscn"
const SCENE_POPUP := "res://scenes/ui/damage_popup.tscn"
const SCENE_PARTICLE := "res://scenes/fx/burst_emitter.tscn"
const SCENE_LASER := "res://scenes/combat/lasers/laser_beam.tscn"
const MANIFEST_PATH := "res://data/manifest.cfg"
const STARTING_WEAPON_ID := &"W1_pistol"      # Q-4：首发手枪
const SCENE_XP_SHARD := "res://scenes/combat/pickups/xp_shard.tscn"   # B.1 经验碎片（XPPool 模板）
# E-10 敌间分离力（软分离防重叠）：10Hz 降频 + 网格邻域查询（性能预案 §5.2-5；
# 单轴单次推移 ≤4px 软钳——分离是观感修正而非物理约束，避免两帧内挤开 Boss 阵型）
const SEPARATION_INTERVAL := 0.1              # 10Hz（架构 §2.11 敌间分离力口径）
const SEPARATION_MAX_STEP := 4.0              # 单敌单次推移上限 px
const SEPARATION_SHARDS := 6                  # R256 序2：分片轮转（每敌仍 10Hz，单帧分离成本 ÷6）
const RESUME_GRACE_S := 0.5                   # 暂停恢复输入忽略期 s（防误触，用户反馈 2026-08-29）
const GAME_DELTA_CLAMP_S := 0.25              # R194：单帧游戏 delta 钳制上限 s（巨 delta 分帧消化——
                                              # 防断点/卡顿补账一帧吞掉整段波窗口经硬上限连环叠波）
const STRETCH_ASPECT_RATIO_MAX := 2.34        # R195 适配底座：窗口高宽比超限钳制阈值（代码常量
                                              # 不设设置键；21:9≈2.3333 整档留 EXPAND，>2.34
                                              # 回落 KEEP 居中黑边；IGNORE/INTEGER 写死禁用）

# ── R233 T2：SIM_30HZ 单源谓词（决策5 定稿——挂 game_loop，测试可注入；boot 期一次定型
#    不做运行期热切） ──
# 生效门 = mobile ∧ SIM_30HZ_ENABLED（桌面/headless 恒 false=现状 60Hz 口径零扰动）。
# sim30_override 哨兵（R229 pool_valve_override 同款）：-1=真值（OS mobile 门）/
# -2=强制关 / -3=模拟 mobile（headless 测试驱真值臂——-3 哨兵可测性同款）。
# 联动面（决策5 五项同谓词，后续 T3-T6 逐项落地）：①meta_manager physics hz ②结算帽表
# ③派发/吸收帧帽 ④四处相位短路+swept ⑤插值层——全部只经 sim30_effective() 消费，
# 禁止任何一参与开关脱钩（决策6）。
const SIM_HZ_60 := 60                         # 60Hz 档原值（meta_manager R204 现口径——回退档逐位全等）
const SIM_HZ_30HZ := 30                       # 30Hz 档（决策6 *_30HZ 后缀常量方案；T3 帽值选表同款铺路）
static var SIM_30HZ_ENABLED: bool = false     # 二ch 回退：② 深载净负（fps 7-14）被用户否决，vc39 起默认 60Hz；资产保留，-3/-2 哨兵与 true 注入仍可测
static var sim30_override: int = -1           # 测试注入口（-1 真值 / -2 强制关 / -3 模拟 mobile）


static func sim30_effective() -> bool:
	# 单源谓词（五项联动同谓词——决策5 R3 计数统一）。门序对齐 _pool_valve_on：
	# 哨兵短路边 → OS mobile 门（-3 跳过）→ 开关真值。
	if sim30_override == -2:
		return false
	if sim30_override != -3 and not OS.has_feature("mobile"):
		return false
	return SIM_30HZ_ENABLED


static func sim_hz_target() -> int:
	# 物理频率选表（meta_manager mobile 门内唯一消费点；60Hz 档返回原值=回退档全等，
	# 30Hz 档=决策1 方案A Engine.physics_ticks_per_second=30）。
	return SIM_HZ_30HZ if sim30_effective() else SIM_HZ_60


# ── R285：弹侧 boost 网格命中/死亡冲刷双门（设计 §3.0；R223 pool_valve_override /
#    R235 PLAYER_BULLET_FAST_PATH 静态注入口先例） ─────────────────────────
# 架构红线（§0.3）：boost 关（桌面/headless/测试默认）→ 帧级缓存恒 false → ④ 相执行序
# 与现网逐字相同（关态可执行新增面=④ 头一次 boost_mode() 求值 + 静态 bool 写读，
# 弹/敌热路径零字典查零门调用）。boost 开（mobile 保帧模式）→ T1 收集-冲刷两段式 +
# T3 死亡链批量冲刷。RNG 契约变更声明（boost 开侧限定）：命中时点允许帧级偏移（设计
# §3.1.5——单体结算链数值/命中率统计期望/穿透预算语义/E-03 去重契约不变；同帧多杀
# 击杀连锁读数单向收窄漂移明示不在承诺内），声明全文见 projectile_base._collect_hit_pairs
# 与 enemy._death_fanout 头注。
static var grid_hit_override: int = -1        # -1=真值（跟 boost_mode）/ 0=强关（A/B 对拍臂）/ 1=强开（QA 直驱路径）
static var death_flush_override: int = -1     # 同款三态（T1/T3 可独立裁定）
static var grid_hit_frame: bool = false       # 当帧网格命中路径开关（④ 相头写，帧内只读——〔v2·M2〕帧级缓存）
static var death_flush_frame: bool = false    # 当帧死亡冲刷开关（同上）
static var prof_buckets_frame: bool = false   # R285 P0：四分键计时门（随 stage_probe_enabled 逐帧写——
                                              # 命/结/死/回 四桶只在本门内 begin/end；关态 死/回/ip 键照累计）
static var shortcircuit_ip_pass: bool = false # R285 S8：ip 双遍历短路臂注入口（默认 false=零短路零成本）
static var shortcircuit_proj_stage: bool = false # R286 S9：④弹段整段短路臂注入口（跳过 _tick_projectiles
                                                 # 调用——弹仍活仍可见，④ 段份额定谳；默认 false=零短路零成本）
static var hit_pairs_flushed: int = 0         # 会话累计冲刷命中对数（G 臂 effect check/诊断直读）
static var deaths_flushed: int = 0            # 会话累计冲刷死亡数（同上）


static func grid_hit_on() -> bool:
	# R285：网格命中路径读口（仅 ④ 相头调用，每帧恰一次——非热路径）。
	# 读序：grid_hit_override(0/1) > PerfGovernor.boost_mode()（boost_override 0/1 >
	# Meta.settings("perf_boost")）。boost_mode() 的设置字典查只发生在本求值点。
	if grid_hit_override == 0:
		return false
	if grid_hit_override == 1:
		return true
	return PerfGovernor.boost_mode()


static func death_flush_on() -> bool:
	# R285：死亡冲刷路径读口（诊断/QA 直读口——④ 相头实际用共享求值零二次 boost 查）。
	if death_flush_override == 0:
		return false
	if death_flush_override == 1:
		return true
	return PerfGovernor.boost_mode()

# 状态机（复用 GameConst.GameStatus：BOOT/MENU/PLAYING/PAUSED/LEVEL_UP/GAME_OVER）
# 合法迁移矩阵（冻结；非法迁移 change_state 拒绝 + 计数）。
# ★ PAUSED → MENU 为暂停面板「回主菜单」新增合法迁移（用户反馈 2026-08-29；pkg4 非法
#   迁移用例枚举 MENU→PAUSED / MENU→LEVEL_UP / GAME_OVER→PAUSED，不含本对——不破坏）
const TRANSITIONS: Dictionary = {
	GameConst.GameStatus.BOOT: [GameConst.GameStatus.MENU],
	GameConst.GameStatus.MENU: [GameConst.GameStatus.PLAYING],
	GameConst.GameStatus.PLAYING: [GameConst.GameStatus.PAUSED, GameConst.GameStatus.LEVEL_UP,
		GameConst.GameStatus.GAME_OVER],
	GameConst.GameStatus.PAUSED: [GameConst.GameStatus.PLAYING, GameConst.GameStatus.GAME_OVER,
		GameConst.GameStatus.MENU],
	GameConst.GameStatus.LEVEL_UP: [GameConst.GameStatus.PLAYING, GameConst.GameStatus.GAME_OVER],
	GameConst.GameStatus.GAME_OVER: [GameConst.GameStatus.MENU, GameConst.GameStatus.PLAYING],
}

var state: int = GameConst.GameStatus.BOOT
var time_scale: float = 1.0                   # ★ 唯一持有者（写入口仅 set_time_scale）
var time_scale_source: StringName = &""       # 当前缩放来源（遥测/测试观测）
var frame_stamp: int = 0                      # GameConfig.advance_frame 同步源
var rejected_transitions: int = 0             # 非法迁移拒绝计数（测试/遥测）
var dropped_level_ups: int = 0                # GameOver 状态升级请求丢弃计数（E-16）
var pending_level_ups: int = 0                # 多级连升排队（A3 §6.2：排队弹卡）
# R188-perf 档3 连升合并：排队帽（超出部分并入当前批同分布自动抽卡——4.8 万张选卡
# 冻结的结构性修复；idle 自动选卡计时器只消化真实弹窗批）
const PENDING_LEVEL_UP_CAP: int = 3
var merged_overflow_level_ups: int = 0        # 连升合并溢出批计数（遥测观测口）
# R189 溢出批分帧消化：收口帧只挂批不抽卡，PLAYING 逐帧按时间预算抽卡
const MERGED_OVERFLOW_BUDGET_MS := 35.0       # 单帧抽卡预算（§4.8-9 单帧 ≤50ms 子预算——
                                              # 实测卡均 ~1.4ms：生成 0.74 + 应用 0.6）
# ── R212 刀4：溢出消化预算收紧（mobile 门）+ 高成本卡单迭代超帽保护（全平台） ──
# vc18 真机：35ms 预算在 mobile 帧预算（16.7ms@60Hz / 8.3ms@120Hz）上常态超帽——
# 感段 110-138ms 尖峰主头之一。mobile 档收紧 8ms；桌面/headless 保持 35ms 原口径
# （基准断言零漂移）。高成本卡（WEAPON 类 apply 走 player.add_weapon 实例化，单次
# 70-100ms）另设启动闸：本帧已耗超闸值不再启动新武器实例化，该张让渡下一帧首位
# 应用（roll 结果留存不作废）——原 while 先检后做挡不住单次 apply 独占超帽，
# 同帧连环武器实例化（35ms 预算内 2-3 张）曾是 150-300ms 单帧形态。
const MERGED_OVERFLOW_BUDGET_MS_MOBILE := 8.0 # mobile 收紧档（抽卡预算）
const MERGED_EXPENSIVE_GUARD_US := 1500       # 高成本卡启动闸（帧内已耗 µs；≈首卡位）
var merged_overflow_budget_override_ms: float = -1.0   # 测试覆写口：≥0 强制预算
                                                       # （<0 平台自动；套件用毕复位 -1）
var _merged_overflow_deferred: Dictionary = {}   # 超帽让渡的高成本卡（下一帧首位应用）
var _merged_overflow_draining: bool = false   # 溢出批消化中（persist-defer 归属标记）
var _shard_subtick_left: int = 1              # R212 刀3：mobile 选卡/暂停期磁吸碎片半频
                                              # 相位（1=本帧驱动；桌面每帧恒 1）
var _fullload_absorb_left: int = 0            # R225 刀a：满载吸收单帽剩余预算（帧序②⑦
                                              # 共享一顶 24/帧 帽——原两独立帽最坏 48/帧；
                                              # 非满载恒不被读/扣，双帽原样=零扰动）
var _fullload_absorb_open: bool = false       # R225 刀a：本帧序帽已开标记（⑦ 段兜底开帽
                                              # 判据——防门中途翻转读到陈旧预算冻片一帧）

# ── R188-idle 挂机自动驱动（消费 Meta.settings("auto_select_on"/"auto_restart_mode")） ──
const AUTO_CARD_WINDOW_S := 0.5               # 选卡展示窗 s（0.5s 描金 + pkg4 LEVEL_UP 文案断言口径）
const AUTO_SHOP_WINDOW_S := 0.8               # 黑市自动出击窗 s
const AUTO_RESTART_WINDOW_S := 3.0            # 结算自动重开倒计时 s
# R245 红卡门：大屏自动确认窗 s（对齐 AUTO_CARD_WINDOW_S 风格；1.5s=选卡窗 3 倍——
# 大屏信息量大需阅读时间）。不扩此臂 = auto_select_on 用户永久停在大屏（设计 §6.4-2 P0）
const AUTO_SUBLIME_WINDOW_S := 1.5
const AUTO_RETRY_CAP: int = 4                 # 自动选卡防重入门（is_open 翻 false 重置）
var _auto_card_left: float = -1.0             # ≥0 = 选卡自动倒计时挂起
var _auto_sublime_left: float = -1.0          # R245：≥0 = 红卡大屏自动确认倒计时挂起
var _auto_shop_left: float = -1.0             # ≥0 = 商店自动出击倒计时挂起
var _auto_restart_left: float = -1.0          # ≥0 = 重开倒计时挂起（GAME_OVER 帧序分支）
var _auto_card_shown_index: int = -1          # 本窗已描金候选（重复置金幂等）
var _auto_card_retries: int = 0               # choose 真链失败重试计数（帽内重试）
var _auto_shop_seen_purchases: int = -1       # 商店采购计数基线（变化 = 玩家手动操作）
var _auto_shop_seen_refresh: int = 0          # 商店刷新计数基线（变化 = 玩家手动操作）
var boot_ready: bool = false                  # Boot 完成（MENU 可进）
var boot_fatal: Array = []                    # 致命错误清单（非空 → 停留 BOOT）

var pipeline: RefCounted = null               # DamagePipeline 真件/桩（get_pipeline 工厂）
var enemy_grid: SpaceGrid                     # 敌人格（弹-敌碰撞主路径）
var enemy_bullet_grid: SpaceGrid              # 敌弹格（消弹查询）
var player: Player = null
var wave_director: WaveDirector = null
var current_map_id: StringName = MapTable.FIRST_MAP_ID   # 当前地图（M2 多地图，用户反馈）
var _difficulty: int = GameConst.Difficulty.NORMAL   # R72 难度三档（0 普通/1 困难/2 地狱；开局随图带入）
var _dual_pending: bool = false                # R72 本轮选卡是否成对模式（重发牌保持同模式）
var _backdrop: CloudBackdrop = null                       # 云层主题色宿主（分图换色）
var spawner: EnemySpawner = null
var elemental: ElementalSystem = null
var game_feel: GameFeelDirector = null
var registry: DataRegistry = null
var popup_manager: PopupManager = null
var hud: HUD = null
var boss_bar: BossBar = null
var hurt_indicator: HurtIndicator = null      # F2 受击方向指示
var game_over_screen: GameOverScreen = null
var card_generator: CardGenerator = null
var card_select_ui: CardSelectUI = null
var relic_handler: RelicHandler = null         # 集成包 B.2：遗物效果处理器
var menu_screen: MenuScreen = null            # 集成包 A：主菜单屏（MENU 态宿主）
var pause_overlay: PauseOverlay = null        # 方向 C：暂停遮罩面板（PAUSED 态宿主）
var sublime_confirm_ui: SublimeConfirmUI = null   # R245 红卡大屏确认卡（LEVEL_UP 弹出期宿主）
var first_encounter_card_ui: FirstEncounterCardUI = null   # R251 需求③ 首遇介绍卡（非阻塞队列横条——UI 自连 EventBus，挂载零接线）
var blessing_pick_ui: BlessingPickUI = null   # R252 需求② 祝福（开局自选词条）面板（MENU 态选图确认后弹层）
var _blessing_pending: bool = false           # R252：祝福面板待决闸（面板模态期吞二次出发——仅防二次启动，
                                              # 每日隔离不靠它：面板层 _on_menu_start_daily 直调 + 挂载层种子守卫）
var _blessing_pick_map: StringName = &""      # R252：面板期缓存的出发地图（确认/不选后继续启动用）
var settings_panel: SettingsPanel = null      # P3：设置页（大厅/暂停卡双入口，纯 UI 层）
var shop_ui: ShopUi = null                    # 战地黑市（M7 股市商店，SHOP 波事件宿主）
var sfx: SfxBank = null                       # 程序化音效库（表现层一期）
var elemental_fx: ElementalFxLayer = null     # 方向 C：元素签名特效层（连锁闪电/碎裂环/DOT 火星）
var fx_particles: ParticleDirector = null     # c4①：graze 掠过微光的池化粒子发射口（boot 组装期同指针）
var camera: Camera2D = null                   # 集成包 A：震屏偏移宿主（trauma² 映射应用位）
var confetti: ConfettiBurst = null            # 方向 C：Boss 死亡彩纸屑（actors 段前置订阅）
var _stretch_clamp_armed: bool = false        # R195：超限钳制已挂（boot 时 aspect=expand 才armed——
                                              # 项目设置 keep 回退位下钳制函数全程零触发=现状黑边）
var pools: Dictionary = {}                    # {projectile, enemy, popup, particle, laser, xp}
var _deferred_level_open: int = -1            # R215 刀A：升级开窗延迟档（-1 空；本帧只记档，
                                              # 帧尾 _consume_deferred_level_open 开窗归卡键——
                                              # vc22 选卡窗磁尖峰 183ms=吸收链内同步开窗级联）
var _tex_prewarm_queue: Array = []            # R215 刀C：菜单期分帧贴图预热队列（boot 建、
                                              # MENU 态 12ms/帧消化；空=已消化完零成本）
var _tex_prewarm_skip: int = 0                # R222 Fix P：占空跳帧余额（>0 时菜单帧零成本直返）
var _menu_dwell_s: float = 0.0                # R215 修：MENU 累计停留秒——boss 双面单项实测
                                              # 88-245ms，停留 <BOSS_PREWARM_IDLE_S 时队首 boss
                                              # 项暂停（评审：开局顿挫改『挂机才发生』）
var resume_grace_left: float = 0.0
var _victory_pending_left: float = 0.0        # 通关结算延迟窗（R15：给磁吸碎片收集时间）
var _endless_mode: bool = false               # R62：无尽继续态——清完 final_wave 后选「继续挑战」
                                               # 置位；此局不再重复胜利结算，打到死亡为止
var _victory_settle_pending: bool = false     # R62：通关屏延迟结算待决（玩家未选出口前 Meta 不落账）
var _run_blessing_paid: bool = false          # R263：祝福已购位（start_run 头复位 false；本局首次
                                              # 「挂载+扣费」成功置 true；restart_run 重挂仅当 true——
                                              # 堵「首局买不起→死亡结算补星尘→重开免费挂载」套利）
var _boss_summons: Dictionary = {}            # Boss 裂变召唤追踪（B4 R18 P3：uid → 调度态）
var _boss_summon_keys: Array = []             # R262b L3：召唤键遍历缓冲（免每帧 keys() 分配）

var frame_order: Array[StringName] = []       # 帧序探针（每帧重建；测试断言固定帧序）
var current_candidates: Array[Dictionary] = []   # 当前货架（测试观测）
var active_shards: Array[XpShard] = []        # 场上经验碎片（掉落/吸附/归还管理，B.1）
var _xp_tier_anchor_base: float = 3.0         # R202 四色分档锚：注册表最低 exp_base（boot 一次扫描缓存；
                                               # 默认 3.0=空表/降级兜底。锚语义=「注册表最低 exp_base」，
                                               # 未来新增更低 exp_base 怪自然移锚——非硬编码 E1_grunt）
var stage_probe_enabled: bool = false         # 分阶段采样开关（架构 §5.5：P95 超线按阶段定位）
var stage_probe_us: Dictionary = {}           # {StringName 阶段: 累计 usec}（仅 PLAYING 帧，逐帧重建）
var stage_probe_us_peak: Dictionary = {}      # R206：{阶段: 秒内峰值 usec}（诊断日志采样后由 DebugStats 清零；stage_probe_us 逐帧重建看不见秒内尖峰）
# R286 段窗和：单帧末值口径的秒窗累计补全（段探针每帧清零→1Hz 只见末帧=负载不可和；
# 累计点=帧入口 clear 前〔此刻段表=上一完整步〕，M/D/B 态无段表不累计；读走清零同
# diag_reset_stage_peaks 先例）。段和µs=全段（含 entry/dispatch 不进段序的键）；弹段/
# 网段/敌段=grid_projectile/grid_rebuild/enemy 三段分键——步µs−段和µs=步内未探针暗区直读。
var _stage_win_sum_us: int = 0                # R286：十六段+entry+dispatch 秒窗累计和
var _stage_win_proj_us: int = 0               # R286：弹段（grid_projectile）秒窗累计
var _stage_win_grid_us: int = 0               # R286：网段（grid_rebuild 双网格重建）秒窗累计
var _stage_win_enemy_us: int = 0              # R286：敌段（enemy AI/元素/反应）秒窗累计
# R287 深载分键补全：vc86 判读定谳深载（敌90）弹+敌+网仅占步 30-42%，其余 58-70% 散在
# 未分窗段且尖峰归因 45/47 指向 popup——六段秒窗分键补齐判读面（跳段=popup 跳字管线/
# 玩段=player 含移火子键/特段=fx/UI段=ui 非跳字部分/他段=other/派段=dispatch 结算派发）。
var _stage_win_popup_us: int = 0              # R287：跳段（popup 跳字管线）秒窗累计
var _stage_win_player_us: int = 0             # R287：玩段（player 全段，移/火为其子键已内含）秒窗累计
var _stage_win_fx_us: int = 0                 # R287：特段（fx 特效件）秒窗累计
var _stage_win_ui_us: int = 0                 # R287：UI 段（ui 非跳字部分）秒窗累计
var _stage_win_other_us: int = 0              # R287：他段（other 未归段胶水）秒窗累计
var _stage_win_dispatch_us: int = 0           # R287：派段（dispatch 结算派发）秒窗累计
var _ui_subtick_left: int = 1                 # R206：mobile 跳字半频相位（1=本帧驱动；桌面每帧恒 1）
var _fx_subtick_left: int = 1                 # R207：mobile 元素特效层半频相位（同上）

var _projectile_pool: ProjectilePool = null
var _homing_pool: ProjectilePool = null           # R94：homing 场景池（此前从未接线——HomingProjectile 全程死代码，导弹实为直飞基础弹无爆炸无追踪）
var _boot_elapsed_ms: float = 0.0             # Boot 耗时（AC：<3s 预算遥测）
var _sep_clock: float = 0.0                       # R256 序2：分片轮时钟（游戏增量累计）
var _sep_due: PackedFloat32Array = PackedFloat32Array()   # 各片下次到期时刻（空=待惰性初始化）
var _free_reroll_used: bool = false            # 本局首次「换一批」免费位（一次性刷新方向）
var _card_rarity_floor: int = -1               # R199-N13：本局选卡流稀有度保底留存（首 roll
                                               # 消费 take_rarity_floor 后由本类持有，换一批
                                               # 复传；<0 无——relic_handler 侧消费即焚）
var _active_daily_seed: int = -1               # R186：本局每日种子留存（echo 重开重 roll 的确定性源）
var _run_intro_lines: PackedStringArray = []   # R186：开场横幅唯一收口（难度/大关/随机武装/fission 宣告
                                               # 三源合并为至多一条 toast——消费点 emit 后立即清空）


func _ready() -> void:
	# Boot 序列（架构 §六.2）：fatal 检查 → registry → 池预热 → 子系统组装 → MENU
	process_mode = Node.PROCESS_MODE_ALWAYS      # tree.paused 期间仍驱动 ⑦⑧（帧序契约）
	var t0 := Time.get_ticks_usec()
	if GameConfig.is_fatal():
		boot_fatal = GameConfig.fatal_errors.duplicate()
		_build_boot_error_screen()
		push_error("[GameLoop] 致命配置，拒绝进入 MENU：%s" % str(boot_fatal))
		return
	_boot_load_data()
	if not boot_fatal.is_empty():
		return                                   # R194 空表闸：_boot_load_data 内置位 + 已建 boot_error 屏
		                                         # ——中止后续 boot 段，状态停留 BOOT（唯一合法迁移 BOOT→MENU
		                                         # 永不可达）= 拒绝入局
	_boot_build_pools()
	_boot_prewarm_textures()                  # R215 刀C：贴图全变体预热（池就绪后、任何 spawn 前）
	_boot_build_grids()
	_boot_build_actors()
	_boot_build_presentation()
	boot_ready = true
	_boot_elapsed_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	# R205 真机取证：移动端自动开分阶段探针（§5.5 现成六段埋点，成本 ~12 次
	# usec 读/帧可忽略）——DebugStats 1Hz 诊断日志读 stage_probe_us 拼每秒一行，
	# 主页面「导出日志」取证 10fps 卡点；桌面/headless 缺省关（基准口径零扰动）。
	if OS.has_feature("mobile"):
		stage_probe_enabled = true
	change_state(GameConst.GameStatus.MENU)


func diag_counts() -> Dictionary:
	# R205：诊断日志数据源（DebugStats 每秒拉一次；敌/弹活跃数——弹含玩家+敌方）
	# R212：+runtime_inst 全池运行期 instantiate 合计（预热销案真机口径——prewarm
	# 满容后应恒 0，>0 即懒增长口子被打开；1Hz 行「ri」段直读，
	# r212_poolwarm_cases ② 的求和断言即本键同构预锁）
	# R213：+status_enemies 带元素状态敌数（A 案收益假设「满载 60% 敌带状态」真机
	# 定标口——满载期 态/敌 比值即 A 案实际 o 节省系数；1Hz 一次 O(敌×8) 可忽略）
	# R215 刀D：+敌/弹分桶数（E' 合批健康度——桶数≈该池理论上批数下限；战斗期桶数
	# 涨=新贴图变体入场）+磁吸片在场数（选卡窗磁键尖峰的负载基数）
	var ri_sum := 0
	for key in pools:
		ri_sum += int((pools[key] as ObjectPool).runtime_instantiate_count)
	var status_cnt := 0
	for e in spawner.active:
		var en := e as Enemy
		if en != null and en.elemental != null:
			for g in en.elemental.gauges:
				if float(g) > 0.0:
					status_cnt += 1
					break
	# R215 刀D 解读边界（评审注明）：桶数=host 子桶数=『进入过分桶的不同贴图数』单调
	# 下界——桶内 attachment（装甲/皇冠/底影）破批不可见；判读须 dc-桶-敌三元读数
	# （如 桶未增而 dc 仍升 ⇒ 桶内挂件断批而非新变体入场）。磁片数=仅 is_magnet 真源
	#（不含 _homing 过渡态，与⑦段处理集一致）。
	var bucket_e := 0
	var bucket_p := 0
	var bucket_x := 0
	var eh: Node = (pools[&"enemy"] as ObjectPool).bucket_host
	var ph: Node = (_projectile_pool as ObjectPool).bucket_host
	var xh: Node = (pools[&"xp"] as ObjectPool).bucket_host
	if eh != null:
		bucket_e = eh.get_child_count()
	if ph != null:
		bucket_p = ph.get_child_count()
	if xh != null:
		bucket_x = xh.get_child_count()
	var magnet_cnt := 0
	for s in active_shards:
		if is_instance_valid(s) and (s as XpShard).is_magnet():
			magnet_cnt += 1
	# R217 刀B：断N=桶内断批敌数（modulate/self_modulate 任一非白——闪白窗/染色窗/
	# 入场渐显窗内敌；与 dc 对读定桶内断批贡献）；跳N=跳字在场条数（Label 逐条独立
	# 绘制——dc 贡献候选）
	# R218 刀A（二j #2）：断N 在量化后=高计口径（狂暴常驻 0.18 红全体同值并不真断批）；
	# 分组N=敌桶内 distinct (modulate,self_modulate,根α) 元组数=真合批分组上限——
	# vc26 与 dc 直接对读（≤档组合数≈16 为设计达成；分组N 低而 dc 高→断批源在桶外）
	var tinted_cnt := 0
	var tint_groups := {}
	for e in spawner.active:
		var te := e as Enemy
		if te == null:
			continue
		if te.is_batch_broken():
			tinted_cnt += 1
		tint_groups["%s|%.2f" % [te.sprite_modulate_key(), te.modulate.a]] = true
	var popup_cnt := int((pools[&"popup"] as ObjectPool).stats()["live"])
	return {
		&"enemies": spawner.active.size(),
		&"projectiles": _projectile_pool.active_projectiles().size(),
		&"runtime_inst": ri_sum,
		&"status_enemies": status_cnt,
		&"bucket_enemy": bucket_e,
		&"bucket_projectile": bucket_p,
		&"bucket_xp": bucket_x,
		&"magnet_shards": magnet_cnt,
		&"shards": active_shards.size(),
		&"tinted_enemies": tinted_cnt,
		&"popups": popup_cnt,
		&"tint_groups": tint_groups.size(),
		# R220 刀1：结N=真件管线 settles 秒差分（1Hz 行读数=每秒结算数——真机每命中 µs
		# 定标口 弹段ms×1000÷结N；诊断拉取一次记一次基线，直调测试重复拉取增量=0 合法）；
		# 自导N=_homing_pool 在场数（弹N 不含自导池的口径纠正——方案书 0.2.1 警示）。
		# R223 修轮（评审#4）：顺/冲/弃=结算预算三轴差分（顺=超帽顺延数 / 冲=冲刷真结算数
		# 含过期强冲 / 弃=诚实丢弃=亡目标+uid复用+超载修剪）——vc 真机判读关键轴：
		# 结N≈帽×帧率为预期稳态，「顺高冲稳弃低」=刀健康，「弃高」=真实 DPS 损失形态。
		&"settles": _diag_settles_delta(),
		&"settles_deferred": _diag_pipe_delta("settle_deferred"),
		&"settles_flushed": _diag_pipe_delta("settle_flush"),
		&"settles_dropped": _diag_pipe_delta("settle_flush_dead")
			+ _diag_pipe_delta("settle_flush_reuse")
			+ _diag_pipe_delta("settle_overload_drop"),
		&"homing_projectiles": _homing_pool.active_projectiles().size() if _homing_pool != null else 0,
		# R269 B 轨：敌弹N=team-1 活口当秒末直读（快N 同款非差分通路——ProjectilePool
		# 计数器 plumb 进 diag_counts；一计数两用：320 帽判据（A 轨 §3.4）+ 本观测键）。
		# R269 修1（评审中#1）：改实扫真值 recount_team1()（沿 _live_order 每 1Hz O(n)
		# 自愈计数器——反射盾反弹等 team 翻转点漂移兜底；翻转点已同步 note_team1_flip）
		&"enemy_bullets_live": _projectile_pool.recount_team1() if _projectile_pool != null else 0,
		# R231 刀B：快N 采样源——当帧 pfast 分区计数（_tick_one_pool 直线池分区后写入；
		# _proj_pfast_buf 为帧内瞬态缓冲不可跨帧读）。口径=当秒末帧活弹快路径数，
		# 快N/弹N 即真机覆盖率直读键（vc36 判读：用户构筑大量跳弹/EF_SIZE 时 快N→0）。
		&"pfast_live": _pfast_live,
		# R232 T1b：结µs=结算轴（resolve+冲刷）当秒每结算均值 µs（分子分母同窗秒差分；
		# 真机单结 µs 直读键——vc37 判读与刀3 预算标定输入；与 快N 同款非差分行尾键，
		# 差分在 _diag_settle_us_delta/_diag_settle_per_n_delta 侧完成）。
		# R233 T0：分母基线与结N 键各自独立（本键在结N 键之后求值，结N 键已消费共享
		# 基线——复用则二次差分≈0，见 _diag_settle_us_per 注）
		&"settle_us_per": _diag_settle_us_per(),
		# R233 T1：插µs=渲染帧插值写入每帧均值 µs（决策7 诊断先于行为刀——插值层 T6
		# 未实施期累计器恒 0=关态基线，键先行落地，T6 实施后即有读数；分母=渲染帧数
		# 差分非结N 口径，见 _diag_ip_us_per 注）
		&"ip_us_per": _diag_ip_us_per(),
		# R233 修轮（评审 MED-3 + QA LOW-1）：插模拟µs=模拟侧插值两遍历（帧入口恢复+
		# 帧末快照）当秒累计 µs——决策3.3「贴边预算下必须可观测」补全（原快照遍历挂
		# 「他」键计算之后完全不可见/恢复遍历混入「他」聚合）。秒差分总量口径（非每帧
		# 均值）；快照 T7 无条件跑 → 谓词关/headless 态本键=快照遍历实际成本直读
		#（QA LOW-1 量化 0.1-0.3ms/帧的盲区消解）。见 _diag_ip_sim_us 注。
		&"ip_sim_us": _diag_ip_sim_us(),
		# R226 仪表补码（vc31 读数缺口：位图生效无直读键→dc 归因不可执行）：
		# 位图R=跳字字形图集就绪口（0/1——0 时 mobile 跳字走 Label 回退=dc 假阴态）；
		# 翻N=fullload 门翻转秒差分（真机装饰显隐震荡量化口，>2/s=滞回震荡需回报）
		&"bitmap_ready": 1 if PopupGlyphAtlas.ready() else 0,
		&"fullload_flips_delta": _diag_counter_delta(&"fullload_flips"),
		# R227：补N=新局补烤毫秒（一次性读数——位图激活路径归因：0=菜单队首已就绪/
		# 桌面不补；>0=开局兜底执行过；量级 headless ~40ms 口径，真机界待 vc33 首读校准）
		&"bitmap_bake_ms_delta": int(_diag_counter_delta(&"bitmap_bake_us") / 1000),
		# R229：裁N=弹池静载阀门一次性读数（触发后下一采样行 >0——真机判读键：裁N>0
		# 证明阀门已触发，与 o 键对拍即定标 o 是否计隐藏静载；之后恒归 0）
		&"pool_trimmed": _diag_counter_delta(&"proj_pool_trim"),
	}


var _diag_settles_last: int = -1           # R220 刀1：结N 差分基线（-1=下次拉取立基线返 0）


var _diag_counter_last: Dictionary = {}    # R226 仪表补码：DebugStats 计数差分基线（翻N）


func _diag_counter_delta(p_key: StringName) -> int:
	# DebugStats 计数通用差分（结N 同语义：拉取立基线、重复拉取增量=0 合法）
	var cur := DebugStats.get_counter(p_key)
	var last: int = _diag_counter_last.get(p_key, -1)
	_diag_counter_last[p_key] = cur
	return 0 if last < 0 else maxi(cur - last, 0)


var _diag_pipe_deltas: Dictionary = {}     # R223 修轮：键→上次值（顺/冲/弃 差分基线）


func _diag_pipe_delta(p_key: String) -> int:
	# 管线计数通用差分（结N 同语义：拉取立基线、重复拉取增量=0 合法）
	if pipeline == null or not pipeline.has_method(&"stats"):
		return 0
	var stats: Dictionary = pipeline.call(&"stats")
	var cur := int(stats.get(p_key, 0))
	var last := int(_diag_pipe_deltas.get(p_key, -1))
	var delta := 0 if last < 0 else maxi(cur - last, 0)
	_diag_pipe_deltas[p_key] = cur
	return delta


func _diag_settles_delta() -> int:
	# 结N 差分真源：damage_pipeline._stats["settles"]（计数点 damage_pipeline.resolve :83）
	# ——桩管线（无 stats）恒 0；首拉立基线返 0（避免把整局累计误读为本秒结算数）。
	if pipeline == null or not pipeline.has_method(&"stats"):
		return 0
	var stats: Dictionary = pipeline.call(&"stats")
	var cur := int(stats.get("settles", 0))
	var delta := 0 if _diag_settles_last < 0 else maxi(cur - _diag_settles_last, 0)
	_diag_settles_last = cur
	return delta


# ── R232 T1b：结µs（结算轴当秒每结算均值 µs——vc37 真机单结直读键，刀3 标定输入） ──
var _diag_settle_us_last: int = -1         # 结算轴累计 µs 差分基线（结N 同款：首拉立基线）
var _diag_settle_per_n_last: int = -1      # R233 T0：结µs 分母专用差分基线（与结N 键的
                                           # _diag_settles_last 分离——共享基线被 diag_counts
                                           # 结N 键先消费，本键复用则二次差分恒 ≈0）


func _diag_settle_us_delta() -> int:
	# 结µs 分子：pipeline.settle_us_total() 秒差分（累计 µs；桩管线/旧管线无该方法恒 0）
	if pipeline == null or not pipeline.has_method(&"settle_us_total"):
		return 0
	var cur := int(pipeline.call(&"settle_us_total"))
	var delta := 0 if _diag_settle_us_last < 0 else maxi(cur - _diag_settle_us_last, 0)
	_diag_settle_us_last = cur
	return delta


func _diag_settle_per_n_delta() -> int:
	# R233 T0 结µs 分母专用差分：真源与结N 同一（damage_pipeline._stats["settles"]），
	# 语义与 _diag_settles_delta 全同（首拉立基线、重复拉取增量=0），仅基线独立——
	# 与结N 键同一 diag_counts 拉取期建立/消费，同帧同窗同源。
	if pipeline == null or not pipeline.has_method(&"stats"):
		return 0
	var stats: Dictionary = pipeline.call(&"stats")
	var cur := int(stats.get("settles", 0))
	var delta := 0 if _diag_settle_per_n_last < 0 else maxi(cur - _diag_settle_per_n_last, 0)
	_diag_settle_per_n_last = cur
	return delta


func _diag_settle_us_per() -> int:
	# 结µs = 当秒结算轴累计 µs ÷ 当秒结算数（分母=结N 同真源独立基线差分，含冲刷真
	# 结算；分母 0 → 返 0 防除零。诊断 only——真实链零改动）。
	# R233 T0 修复：分母不再调 _diag_settles_delta()——diag_counts 字典字面量按序求值，
	# 结N 键先消费其共享基线，本键二次拉取差分恒 ≈0 → 分母 maxi(0,1)=1 → 输出退化为
	# 「每秒累计 µs」而非「每结算均值 µs」（vc37 实证 8134/204=39.9 被打成 8134）。
	var us := _diag_settle_us_delta()
	var n := _diag_settle_per_n_delta()
	return int(float(us) / float(maxi(n, 1)))


# ── R233 T1：插µs（渲染帧插值写入耗时——决策7 诊断先于行为刀，插值层 T6 实施后由
#    _process 写入遍历计时累加；本期无写点恒 0 基线） ──
var ip_write_us_total: int = 0             # 插值写入累计 µs（T6 _process 遍历计时累加口——
                                           # 渲染帧通道，与物理帧 stage_probe 通道分立）
var _diag_ip_us_last: int = -1             # 插µs 分子差分基线（结µs 同款：首拉立基线返 0）
var _diag_ip_frames_last: int = -1         # 插µs 分母差分基线：渲染帧数（Engine.get_frames_drawn
                                           # 同窗——均值口径=每渲染帧，非每结算）


func _diag_ip_us_per() -> int:
	# 插µs = 当秒插值写入累计 µs ÷ 当秒渲染帧数（每帧均值 µs；AC-9 深载判据 ≤500）。
	# 分子分母同窗独立差分（首拉立基线、重复拉取增量=0——结µs/帽N 同语义）；插值层
	# 未实施/开关关期分子恒 0 → 键恒 0（AC-9 关=0 基线）。
	var us := ip_write_us_total
	var us_delta := 0 if _diag_ip_us_last < 0 else maxi(us - _diag_ip_us_last, 0)
	_diag_ip_us_last = us
	var fr := Engine.get_frames_drawn()
	var fr_delta := 0 if _diag_ip_frames_last < 0 else maxi(fr - _diag_ip_frames_last, 0)
	_diag_ip_frames_last = fr
	return int(float(us_delta) / float(maxi(fr_delta, 1)))


# ── R233 修轮（评审 MED-3 + QA LOW-1）：插模拟µs（模拟侧插值两遍历耗时——恢复+快照） ──
var ip_sim_us_total: int = 0             # 模拟侧两遍历累计 µs（物理帧通道——与渲染帧
                                         # ip_write_us_total 分立；快照 T7 无条件跑 →
                                         # 谓词关/headless 态亦计=快照遍历成本可观测）
var _diag_ip_sim_last: int = -1          # 插模拟µs 秒差分基线（结µs 同款：首拉立基线返 0）


func _diag_ip_sim_us() -> int:
	# R233 修轮：插模拟µs=当秒模拟侧两遍历累计 µs（秒差分总量口径——非每帧均值，与
	# 插µs 的每渲染帧均值口径不同源；挂点/次序零改动，只加计量）。首拉立基线、重复
	# 拉取增量=0（结µs/帽N 同语义）；恢复遍历同谓词零执行=关态不计，快照遍历 T7
	# 无条件=关态本键反映快照实际成本。
	var us := ip_sim_us_total
	var delta := 0 if _diag_ip_sim_last < 0 else maxi(us - _diag_ip_sim_last, 0)
	_diag_ip_sim_last = us
	return delta


# ── R233 T6：渲染插值层（决策3——模拟 30Hz 真位/显示缓存双缓冲，纯表现通道） ──────
# 四段时序（设计 3.1 定案，次序固定）：恢复（模拟帧入口 global_position=_ip_curr，
# 抵消上渲染帧插值覆写）→ 模拟（②④⑤ 段读写全在真位）→ 快照（帧末 _ip_prev=_ip_curr;
# _ip_curr=global_position，prev=N-1 步末位）→ 插值（渲染帧 _process 写
# prev.lerp(curr, alpha)）。模拟读到的 global_position 恒=真位；插值只写显示缓存。
# 开关关（SIM_30HZ false/headless）：三遍历与 _process 全部直返零写=现状逐位。
var _ip_alpha_t: float = 0.0                # 渲染帧插值时间累计（步进点归零基准，决策3.1）
var _ip_last_phys_frames: int = -1          # Engine.get_physics_frames() 上渲染帧快照（-1 未初始化）


func _ip_restore_pass() -> void:
	# 恢复遍历（挂点：_physics_process 帧入口 _maybe_trim_pools 之后、pipeline.begin_frame
	# 之前——一次遍历覆盖 ②玩家/④网格+弹/⑤敌/磁吸碎片全部读点）。
	# 豁免：空引用（boot_fatal 期）/已释放（is_instance_valid）/树外节点（is_inside_tree）/
	# 弹池内非本层桩对象（as ProjectileBase null 短路）。零分配（活跃表引用遍历）。
	# R233 修轮（MED-3+QA LOW-1）：全程计时喂 ip_sim_us_total（诊断 only 两次 usec 读，
	# 挂点/次序零改动；谓词关态本函数不被调用=零计入）。
	# R285 S8：短路臂注入口（deeprepro ipµs 份额定谳臂——默认 false 零短路零成本）；
	# R285 P0：ipµs 桶（&"ip_pass"——双遍历合计秒窗键，同 R269 桶器只加计时不改行为）。
	if shortcircuit_ip_pass:
		return
	DebugStats.bucket_begin(&"ip_pass")
	var us_r := Time.get_ticks_usec()
	if player != null and is_instance_valid(player) and player.is_inside_tree():
		player.global_position = player._ip_curr
	if spawner != null:
		for e in spawner.active:
			if is_instance_valid(e):
				var en := e as Enemy
				if en != null and en.is_inside_tree():
					en.global_position = en._ip_curr
	if _projectile_pool != null:
		for proj in _projectile_pool.active_projectiles():
			if is_instance_valid(proj):
				var pb := proj as ProjectileBase
				if pb != null and pb.is_inside_tree():
					pb.global_position = pb._ip_curr
	if _homing_pool != null:
		for proj in _homing_pool.active_projectiles():
			if is_instance_valid(proj):
				var hb := proj as ProjectileBase
				if hb != null and hb.is_inside_tree():
					hb.global_position = hb._ip_curr
	for shard in active_shards:
		if is_instance_valid(shard) and shard.is_inside_tree():
			shard.global_position = shard._ip_curr
	ip_sim_us_total += int(Time.get_ticks_usec() - us_r)
	DebugStats.bucket_end(&"ip_pass")


func _ip_snapshot_pass() -> void:
	# 快照遍历（挂点：_physics_process 帧序最末——EventBus.end_frame 与探针段之后）：
	# _ip_prev=_ip_curr; _ip_curr=global_position。敌击退/闪现、玩家瞬移等一切步内写位
	# 由帧末统一收编（设计 3.1）。遍历源与豁免同恢复遍历。
	# R233 修轮（MED-3+QA LOW-1）：全程计时喂 ip_sim_us_total（诊断 only——快照 T7
	# 无条件跑，谓词关/headless 态本遍历成本即插模拟µs 关态读数，盲区消解）。
	# R235 4c：生产关态直返——谓词关 ∧ 无注入（override==-1 真值臂）。生产态谓词 boot
	# 期定型不运行期翻转（决策5），关态下恢复/插值遍历同谓词零执行，快照保鲜仅服务
	# 「测试注入翻转谓词」的边缘 case（原 T7 无条件理由）；vc39 默认回退后 60Hz 生产
	# 路径直返省 520+ 实体双数组写（0.2-0.5ms/步，vc38 插模拟µs 关态换算）。注入态
	# （-2/-3/ENABLED=true）保持原无条件快照语义（翻谓词的保鲜需求原样成立）。
	# 评审 LOW#5 披露：override==-1 直返期间缓冲冻结而实体在动——若测试「中途」注入
	# -3/-2+true 翻开谓词，翻开首帧 _ip_restore_pass 会把全场写回冻结位（旧无条件快照
	# 无此过渡态）。生产不可达（SIM_30HZ_ENABLED/sim30_override 全仓写点仅声明默认+
	# tests/*，无运行期生产写者——grep 证实）；现网测试均「先注入后驱动」不触发。
	if not sim30_effective() and sim30_override == -1:
		return
	if shortcircuit_ip_pass:                # R285 S8：ip 短路臂（快照遍历同款早退）
		return
	DebugStats.bucket_begin(&"ip_pass")     # R285 P0：ipµs 桶（恢复+快照双遍历合计）
	var us_s := Time.get_ticks_usec()
	if player != null and is_instance_valid(player) and player.is_inside_tree():
		player._ip_prev = player._ip_curr
		player._ip_curr = player.global_position
	if spawner != null:
		for e in spawner.active:
			if is_instance_valid(e):
				var en := e as Enemy
				if en != null and en.is_inside_tree():
					en._ip_prev = en._ip_curr
					en._ip_curr = en.global_position
	if _projectile_pool != null:
		for proj in _projectile_pool.active_projectiles():
			if is_instance_valid(proj):
				var pb := proj as ProjectileBase
				if pb != null and pb.is_inside_tree():
					pb._ip_prev = pb._ip_curr
					pb._ip_curr = pb.global_position
	if _homing_pool != null:
		for proj in _homing_pool.active_projectiles():
			if is_instance_valid(proj):
				var hb := proj as ProjectileBase
				if hb != null and hb.is_inside_tree():
					hb._ip_prev = hb._ip_curr
					hb._ip_curr = hb.global_position
	for shard in active_shards:
		if is_instance_valid(shard) and shard.is_inside_tree():
			shard._ip_prev = shard._ip_curr
			shard._ip_curr = shard.global_position
	ip_sim_us_total += int(Time.get_ticks_usec() - us_s)
	DebugStats.bucket_end(&"ip_pass")


func _ip_render_write(p_alpha: float) -> void:
	# 渲染帧写遍历（纯表现）：显示位 = _ip_prev.lerp(_ip_curr, alpha)（alpha 由调用方
	# 钳 [0,1]——写位恒 ∈ [prev,curr] 包络）。中途 spawn（prev=curr=出生位）无跳变；
	# release/树外实体经活跃表成员与豁免守卫天然排除（回池位不被插值覆盖，设计 3.4）。
	# 计时喂 ip_write_us_total（AC-9 插µs 分子——_process 与测试直调同口）。
	var us0 := Time.get_ticks_usec()
	if player != null and is_instance_valid(player) and player.is_inside_tree():
		player.global_position = player._ip_prev.lerp(player._ip_curr, p_alpha)
	if spawner != null:
		for e in spawner.active:
			if is_instance_valid(e):
				var en := e as Enemy
				if en != null and en.is_inside_tree():
					en.global_position = en._ip_prev.lerp(en._ip_curr, p_alpha)
	if _projectile_pool != null:
		for proj in _projectile_pool.active_projectiles():
			if is_instance_valid(proj):
				var pb := proj as ProjectileBase
				if pb != null and pb.is_inside_tree():
					pb.global_position = pb._ip_prev.lerp(pb._ip_curr, p_alpha)
	if _homing_pool != null:
		for proj in _homing_pool.active_projectiles():
			if is_instance_valid(proj):
				var hb := proj as ProjectileBase
				if hb != null and hb.is_inside_tree():
					hb.global_position = hb._ip_prev.lerp(hb._ip_curr, p_alpha)
	for shard in active_shards:
		if is_instance_valid(shard) and shard.is_inside_tree():
			shard.global_position = shard._ip_prev.lerp(shard._ip_curr, p_alpha)
	ip_write_us_total += int(Time.get_ticks_usec() - us0)


func _ip_alpha_advance(p_delta: float) -> float:
	# alpha 口径（设计 3.1 定案自算——Engine.get_physics_interpolation_fraction 4.3 不存在）：
	# Engine.get_physics_frames() 较上渲染帧推进=模拟步步进点 → 时间累计以本渲染帧归零
	# 基准；否则累计渲染 delta。alpha=累计/步长（步长走 sim_hz_target() 单源）钳 [0,1]。
	# 深载 overrun 段每渲染帧恰带一步 → alpha 常驻低位=亚步直排（决策1b 预期退化形态）。
	var pf := Engine.get_physics_frames()
	if pf != _ip_last_phys_frames:
		_ip_last_phys_frames = pf
		_ip_alpha_t = 0.0
	else:
		_ip_alpha_t += p_delta
	return clampf(_ip_alpha_t / (1.0 / float(sim_hz_target())), 0.0, 1.0)


# ── R268 性能刀 P4：PLAYING 期双预热泵深载门预算 ────────────────────
func _playing_prewarm_budget(p_mobile: bool, p_tier: int, p_fullload: bool) -> Vector2i:
	# 四象限门判定纯函数（qa_r268_physphase 直测）：mobile ∧ 帧率优先档（tier≤2）∧
	# 满载（Enemy.fullload_dim）→ 两泵预算收缩 (500,1000)；desktop / tier3 / 非满载
	# 原值 (2000,4000)。不暂停防队列饿死；MENU 泵/runstart 补烤兜底门/R267 首波门零动。
	if p_mobile and p_tier <= 2 and p_fullload:
		return Vector2i(500, 1000)
	return Vector2i(2000, 4000)


func _process(p_delta: float) -> void:
	# R244 物理相冲刷桶批：菜单期贴图预热迁本轴（原 _physics_process MENU 分支消费）。
	# 归因：vc53 真机菜单行 物步µs 45170→77486 两秒尖峰——gl_compatibility 下贴图
	# 创建/上传是主线程同步成本，预热在物理窗内执行即全额记进引擎物理块（MENU 态
	# 段探针不记账 → 物步µs 残差独吞读数）；R215 自证 boss 双面单项 88-245ms。
	# 迁渲染轴三收益：①菜单物理窗归零（诊断键不再伪报）②物理窗尖峰不再触发追赶步
	# 级联（一步 88ms → 后续帧连补多步的放大链）③vsync 60Hz 下菜单静态渲染轴有
	# 整帧余量，12ms 预算语义名实更符。预算/占空还账（R222 Fix P）与 boss 挂机门
	# （_menu_dwell_s——物理侧 60Hz 累计，读法不变）原样保留；本节点
	# PROCESS_MODE_ALWAYS（:208）⇒ 暂停/菜单态 _process 恒被驱动。headless 下
	# _process 仍被引擎驱动（主循环在跑）→ 测试侧预热路径行为不变。
	if state == GameConst.GameStatus.MENU:
		# R260 评审 MED-2：弹层模态期（祝福/设置）tex 泵同停——menu 侧泵挂起谓词为
		# 合并门（三泵合计 12ms/帧全让给前景动画；boss 预热单项 88-245ms 尖峰同被
		# 3s 挂机门+此门拦在模态窗外）。R262b L5：门换 codex 谓词（图鉴面板开豁免，
		# 照图鉴泵同款口径）——op:7 图鉴域贴图预热回到消费窗口，面板期行建不再回落
		# 行内惰性首生成（放大冷行成本）。
		if menu_screen == null or not menu_screen.codex_pump_paused():
			_process_tex_prewarm(4000)               # R252D P5：12000→4000——与 card_desc 预热
			                                         # 泵(BUDGET_US 4000)合计 8ms/帧 < 16.6ms，
			                                         # 还点击响应帧余量（r244 A1 字面锚随迁）
	elif state == GameConst.GameStatus.PLAYING:
		# R256 序1：战斗态续泵卡描述预热——菜单停留短常有余量，首开卡窗缓存 miss
		# 全量梯量测=每局首次升级必现顿挫（压力门复活血内 card_open 峰值 45.4ms 实测；
		# R255 对照实验排空后开卡中位 16.52→2.60ms）。小预算 2ms/帧（战斗帧预算敏感，
		# 物理窗 8.3ms；排空后零成本早退；R221 超支还账跳帧机制内建）。LEVEL_UP/PAUSED
		# 不泵（tree.paused 时选卡已开，增量 miss 走惰性同现状不劣化）
		# R268 性能刀 P4：深载门收缩——mobile ∧ 帧率优先 ∧ tier≤2 ∧ 满载 双泵预算
		# (2000,4000)→(500,1000)（PLAYING 期原固定 6ms/帧≈60fps 帧预算 36%）。特效优先
		# 模式（frame_priority()==false）按 tier3 口径不收缩（用户选特效保预算）；
		# 桌面/MENU 泵/整泵停摆门/R267 首波门零动。深载预算收缩代价（R268 评审改口——
		# 原「runstart 补烤门兜底」归属有误：runstart_gate 属跳字字形图集域不焙敌贴图，
		# tex 泵侧同门实为整泵停摆门=消费推迟非兜烤）：大项原子焙不被小预算摊薄
		# （tex_prewarm_atom_overruns 原子超支另计），新怪生成先于队列消化时惰性首焙
		# 尖峰（42-50ms/单面、boss 88-245ms）回潮战斗帧——缓解=波序重排
		# _reorder_tex_prewarm_wave_first 前置当波项；vc 轮真机判读键=泵消化迟到型
		# 生成帧尖峰，非泛称「开/波尖峰收窄」。
		var _pw_budget := _playing_prewarm_budget(OS.has_feature("mobile"),
			PerfGovernor.effective_tier() if PerfGovernor.frame_priority() else 3,
			Enemy.fullload_dim())
		DescPrewarm.pump(_pw_budget.x)
		# R267 刀P1：PLAYING tex 预热泵（新渲染轴通道）——快开局玩家在 MENU 排不到的
		# 敌变体（首波新怪首见 42-50ms / boss 双面 88-245ms 惰性首焙），战斗帧 4ms/帧
		# 分帧消化（skip 语义/波次门槛/占空还账在 _process_tex_prewarm(p_playing=true)；
		# 队列波序重排在 _reorder_tex_prewarm_wave_first）。整泵停摆门：mobile 补烤门
		# 开着且图集未就绪 → 队列消费属 runstart 兜底域（qa_r227_bake_b ③b 口径：
		# op:6 只在 MENU 泵消化），ready 后恢复。队列空零成本早退（下行首判定）。
		if not _tex_prewarm_queue.is_empty() \
				and not (PopupGlyphAtlas.runstart_gate() and not PopupGlyphAtlas.ready()):
			var _prewarm_t0 := Time.get_ticks_usec()
			_process_tex_prewarm(_pw_budget.y, true)   # R268 性能刀 P4：tex 泵预算走深载门（原恒 4000）
			# 观测口：每次泵调用实际耗时（验收 e/f 与真机 vc 轮判读源；原子超支另计
			# tex_prewarm_atom_overruns——泵内落账）
			DebugStats.count(&"tex_prewarm_frame_us", int(Time.get_ticks_usec() - _prewarm_t0))
	# R233 T6 决策3：渲染帧插值写入（纯表现通道——§0.2 架构纪律合规）。
	# 首行谓词直返零写（R3 定案：SIM_30HZ 关=现状零写点——直通写 curr 是零收益每帧
	# 遍历且回池/树外边角暴露面；headless 无渲染同直返，直驱口径模拟位=显示位）。
	# R271 P2：两早退谓词合并等价改写（行为逐位不变）——延渲哨兵挂真函数尾
	#（idle 相冲刷窗键源）。
	if sim30_effective() and DisplayServer.get_name() != "headless":
		_ip_render_write(_ip_alpha_advance(p_delta))
	DebugStats.call_deferred(&"diag_flush_sentinel_render", Time.get_ticks_usec())


# ── R229 弹池静载阀门：三重门触发运行期裁闲（820→448） ──────────────
# R228 对象谱实锤：弹族 1688 件=全树 41%（ProjectilePool 820 容量×2 件，
# balance_tables.tres pool_prewarm 实值；活弹带 40-370、闲置 ~960 件=最大静载），
# 且 820 预热全量进每帧 canvas cull 遍历。刀＝深载三重门首次通过时把弹池空闲栈
# 一次性裁到 448（活弹带实测上沿 370+21% 余量），裁后容量同步降=懒增长口保持封死
# （AC-14.1 ri==0 口径不破）。性能阀门是保险丝不是成长帽（R226 口径）：弹量成长
# 无上限——超 448 并发走满池 null 降级（AC-14.4，misses 可观测），无懒增长无崩溃。
# 单池归因干净：HomingPool 24/EnemyPool 128/其余池不动（vc34 真机 裁N+o 键对拍
# 可判）。会话内单向（_pool_valve_done 闩）：新局不恢复 820——菜单期预算 prewarm
# 回 820 的恢复通道进 backlog。
const PROJ_POOL_VALVE_CAP := 448              # 裁后容量（活弹带上沿 370+21% 余量；
                                              # SETTLE_BUDGET_T1/T2 脚本内常量先例）
static var pool_valve_override: int = -1      # 测试注入口（R223 settle_budget_override
                                              # 同款）：-1=真值（OS mobile 门）/
                                              # -2=强制关 / -3=模拟 mobile（headless
                                              # 无头可测；注入后 tier_override/
                                              # mode_override 即三重门全驱）
var _pool_valve_done: bool = false            # 会话级闩（首次触发后永真——每帧谓词
                                              # 短路为一次 bool 读）


func _pool_valve_on() -> bool:
	# 三重门（R223 _settle_cap_now 同序同款）：mobile ∧ 帧率优先 ∧ tier≤2。
	# override 哨兵：-2 恒关；-3 跳过 OS.has_feature("mobile") 直入后两门（无头测试
	# 的「模拟真机」哨兵——真机语义与测试口径共用同一条门序）。
	if pool_valve_override == -2:
		return false
	if pool_valve_override != -3 and not OS.has_feature("mobile"):
		return false
	if not PerfGovernor.frame_priority():
		return false
	return PerfGovernor.effective_tier() <= 2


func _maybe_trim_pools() -> void:
	# 帧入口调用（_physics_process 顶部）：未触发期成本=一次 bool 闩读（+池空判），
	# 三重门谓词只在未闩时评估（三个静态读）。首次触发→裁弹池空闲栈 + 计数
	# （DebugStats proj_pool_trim，1Hz 行 裁N 一次性读数源）。
	if _pool_valve_done or _projectile_pool == null:
		return
	if not _pool_valve_on():
		return
	_pool_valve_done = true
	var trimmed: int = _projectile_pool.trim_free_to(PROJ_POOL_VALVE_CAP)
	DebugStats.count(&"proj_pool_trim", trimmed)


# ── R235 搭车④：Phase 0 六臂微基准真机校准件挂载（菜单态一次性） ────
# 桌面源型 tests/probe_r234_databench_cases.gd（N=1 万紧循环）→ 真机随包版
# scripts/diag/phase0_calib.gd：N=3000×40 帧×2 轮、_process 自驱每渲染帧一次臂迭代
# 分帧跑（120Hz 真机单臂≈0.8s、六臂≈5s 菜单期空闲预算；夹具分帧构建防单帧尖峰）。
# 件完成后一行「校准」进 DebugStats 1Hz 环形日志（diag_push_calib——导出诊断日志
# 必然带上；不写文件系统）。门=mobile（stage_probe_enabled 同款真机口径——桌面/
# headless 零扰动，测试用 phase0_calib_force 注入）。快速开局者本局不跑：dwell 门
# 未过即离场 → 闩未消费，回菜单停留满门补跑（_menu_dwell_s 离场清零语义复用）。
const PHASE0_CALIB_SRC := preload("res://scripts/diag/phase0_calib.gd")
static var phase0_calib_force: bool = false   # 测试注入口（true=桌面/headless 也自动触发）
static var phase0_calib_delay_s: float = 4.0  # 菜单停留门秒（BOOT 后延迟——避开启动帧
                                              # +贴图预热队列；测试可调小加速触发）
var _phase0_calib_latch: bool = false         # 实例闩（本 GameLoop 挂载一次后不再挂）


func _maybe_start_phase0_calib() -> void:
	# MENU 臂帧尾调用：门+停留双条件过 → 挂载校准件（件自驱自拆）。会话幂等双闩：
	# 件侧 static 闩（完成后二次挂载自拆不占日志）+ 本实例闩（不再挂载）。
	if _phase0_calib_latch:
		return
	if not (OS.has_feature("mobile") or phase0_calib_force):
		return
	if _menu_dwell_s < phase0_calib_delay_s:
		return
	_phase0_calib_latch = true
	if PHASE0_CALIB_SRC.session_started():
		return                            # 同会话已跑过（测试重挂/二实例场景）——不再占日志
	var calib: Node = PHASE0_CALIB_SRC.new()
	calib.name = "Phase0Calib"
	add_child(calib)


func _physics_process(p_raw_delta: float) -> void:
	# ★ 固定帧序（架构 §2.17，顺序禁止重排）
	# R271 P1/P2：步闭环四分账+三哨兵——步入口时戳（步µs/隙µs 键源）与延早哨兵
	#（入队→执行延迟=整步工作+冲刷窗）。只加计时不改行为：DebugStats 为 autoload
	# 目标，零场景树副作用零分支变更（与段序头 _phys_t0 探针不同面——无条件记）。
	DebugStats.diag_step_begin()
	DebugStats.call_deferred(&"diag_flush_sentinel_early", Time.get_ticks_usec())
	var _phys_t0 := Time.get_ticks_usec() if stage_probe_enabled else 0
	var _probe_active := false              # R218 刀A：本帧是否有段记录（MENU/GAME_OVER 臂无段——他键不乱算）
	GameConfig.advance_frame()
	frame_stamp = GameConfig.frame_stamp
	_maybe_trim_pools()                     # R229：帧入口三重门谓词（未触发期一次闩读近零成本）
	if sim30_effective():
		_ip_restore_pass()                  # R233 T6：帧入口恢复真位（抵消上渲染帧插值覆写
		                                    # ——防污染 ②④⑤ 段读位；谓词关=零遍历零写）
	if pipeline != null:
		pipeline.begin_frame(frame_stamp,     # R221 修轮 D1：传帧号（dispatch 过期守卫基准）；
			state == GameConst.GameStatus.PLAYING)  # R223 修轮：战斗态门——暂停/选卡窗内
			# 结算积压不冲刷不强冲（AC-16.2 冻结契约；恢复战斗首帧统一冲刷）
	# R216 刀②：MENU 停留秒只在 MENU 态累计——离开即清零（vc23 0:41 回菜单 fps56=
	# dwell 跨局残留致一回菜单立刻消化 boss 双面；清零后回菜单同样享 3s 挂机缓冲）
	if state != GameConst.GameStatus.MENU:
		_menu_dwell_s = 0.0
	match state:
		GameConst.GameStatus.PLAYING:
			var gd := _game_delta(p_raw_delta)
			frame_order.clear()
			var _probe_t0 := Time.get_ticks_usec() if stage_probe_enabled else 0
			if stage_probe_enabled:
				# R286 段窗和：此刻 stage_probe_us=上一完整步的段表（仅 PLAYING 产生、
				# 逐帧只在本点清零）——先累计再清零；首步空表天然跳过。
				# R286 修轮（QA D1）：player_mv/player_wp 为 玩段 严格子集键（R217 拆键
				# 双计——debug_stats 既有两处段和口径 :375/:485 同款跳过），不入段和µs。
				if not stage_probe_us.is_empty():
					for _win_k in stage_probe_us:
						if _win_k == &"player_mv" or _win_k == &"player_wp":
							continue
						_stage_win_sum_us += int(stage_probe_us[_win_k])
					_stage_win_proj_us += int(stage_probe_us.get(&"grid_projectile", 0))
					_stage_win_grid_us += int(stage_probe_us.get(&"grid_rebuild", 0))
					_stage_win_enemy_us += int(stage_probe_us.get(&"enemy", 0))
					# R287 六段分键：与上三键同表同点累计（.get 缺键 0 兜底——段未执行帧天然 0）
					_stage_win_popup_us += int(stage_probe_us.get(&"popup", 0))
					_stage_win_player_us += int(stage_probe_us.get(&"player", 0))
					_stage_win_fx_us += int(stage_probe_us.get(&"fx", 0))
					_stage_win_ui_us += int(stage_probe_us.get(&"ui", 0))
					_stage_win_other_us += int(stage_probe_us.get(&"other", 0))
					_stage_win_dispatch_us += int(stage_probe_us.get(&"dispatch", 0))
				stage_probe_us.clear()
				_probe_active = true
				# R244 物理相冲刷桶批：帧入口键——函数头→PLAYING 首段计时点之间的全部
				# glue（advance_frame/_maybe_trim_pools/_ip_restore_pass/pipeline.begin_frame/
				# _game_delta/match 分派）此前无段键 → 全额落「他」段（真机深载 尖峰他
				# 26-45ms 的成分之一不可分）。键不进 DIAG_STAGE_ORDER（1Hz 行不印——行
				# 格式/尾锚正则零扰动；debug_stats 两处段和显式加本键同 dispatch 先例）。
				stage_probe_us[&"entry"] = _probe_t0 - _phys_t0
				stage_probe_us_peak[&"entry"] = maxi(int(stage_probe_us_peak.get(&"entry", 0)),
					int(stage_probe_us[&"entry"]))
			# ① 输入采样：相对拖动由 Player._unhandled_input 自采——E-15 单指针锁定亦由
			#    Player 采样层承担（R194 修正：原注释把锁定读成 GameLoop 承担，失实——
			#    GameLoop 从不持有指针锁，本层仅透传零向量 = 玩家消费自采样，包 2 落地口径）。
			#    暂停恢复宽限期内吞掉拖动输入（防误触，raw 通道倒计时）
			frame_order.append(&"input")
			if resume_grace_left > 0.0:
				resume_grace_left = maxf(resume_grace_left - p_raw_delta, 0.0)
			player.input_enabled = resume_grace_left <= 0.0
			_tick_victory_pending(p_raw_delta)  # R15：通关结算延迟窗（碎片收集收尾）
			# ② 玩家（移动/受击/拾取；内含武器冷却+开火调度——包 2 Player.tick 落地口径）
			frame_order.append(&"player")
			Player.reset_stage_probe()             # R217 刀C：tick 内部移/火两段拆键
			player.tick(gd, Vector2.ZERO)
			if stage_probe_enabled:
				# R216 刀②拆键：玩=②段全量（输入+player.tick+碎片+连杀），碎=碎片段；
				# R217 刀C 下钻：移/火=player.tick 内部（增益节拍+移动 vs 四组武器调度）
				# ——vc24 尖峰玩 117ms 归因粒度
				stage_probe_us[&"player"] = Time.get_ticks_usec() - _probe_t0
				stage_probe_us_peak[&"player"] = maxi(int(stage_probe_us_peak.get(&"player", 0)), int(stage_probe_us[&"player"]))
				stage_probe_us[&"player_mv"] = Player.probe_pre_us
				stage_probe_us_peak[&"player_mv"] = maxi(int(stage_probe_us_peak.get(&"player_mv", 0)), int(stage_probe_us[&"player_mv"]))
				stage_probe_us[&"player_wp"] = Player.probe_weapons_us
				stage_probe_us_peak[&"player_wp"] = maxi(int(stage_probe_us_peak.get(&"player_wp", 0)), int(stage_probe_us[&"player_wp"]))
				_probe_t0 = Time.get_ticks_usec()
			_fullload_absorb_frame_open()     # R225 刀a：满载吸收单帽帧序开帽（②⑦共享）
			_tick_xp_shards(gd)               # B.1：经验碎片磁吸/吸收（拾取属玩家阶段）
			if _combo_left > 0.0:             # E9 连杀窗口（战斗通道——暂停冻结）
				_combo_left -= gd
				if _combo_left <= 0.0:
					_combo_count = 0
					_combo_tier_paid = 0            # G9 档位随窗口复位
			if stage_probe_enabled:
				stage_probe_us[&"shard"] = Time.get_ticks_usec() - _probe_t0
				stage_probe_us_peak[&"shard"] = maxi(int(stage_probe_us_peak.get(&"shard", 0)), int(stage_probe_us[&"shard"]))
				_probe_t0 = Time.get_ticks_usec()
			# ④ 双网格重建（当前实体位置确定性快照）→ 投射物运动/碰撞/结算
			frame_order.append(&"grid_projectile")
			# R285：boost 门帧级缓存（④ 相头每帧恰一次求值——grid_hit_on() 的
			# Meta.settings 字典查只发生在本点；死亡冲刷门共享同一次求值零二次查；
			# 弹/敌热路径只读静态 bool，关态执行序与现网逐字相同）
			grid_hit_frame = grid_hit_on()
			match death_flush_override:      # T1/T3 可独立裁定；缺省臂=与网格门同真值
				0:
					death_flush_frame = false
				1:
					death_flush_frame = true
				_:
					death_flush_frame = grid_hit_frame
			prof_buckets_frame = stage_probe_enabled   # R285 P0：四分键计时门（帧级）
			_hp_proj.clear()                 # R285：对缓冲帧头清（防跨帧滞留——t1b 断言面）
			_hp_target.clear()
			_hp_serial.clear()
			enemy_grid.rebuild(spawner.active)
			enemy_bullet_grid.rebuild(_collect_enemy_bullets())
			if stage_probe_enabled:
				# R213 拆键：网=双网格重建（120 敌满载 rebuild 与弹 tick 分开读——vc20
				# 开局弹段 203ms 尖峰的归因粒度）
				stage_probe_us[&"grid_rebuild"] = Time.get_ticks_usec() - _probe_t0
				stage_probe_us_peak[&"grid_rebuild"] = maxi(int(stage_probe_us_peak.get(&"grid_rebuild", 0)), int(stage_probe_us[&"grid_rebuild"]))
				_probe_t0 = Time.get_ticks_usec()
			if not shortcircuit_proj_stage:      # R286 S9：④弹段整段短路（台架臂——弹仍活仍可见，
				_tick_projectiles(gd)            # 分区循环/调用全跳；两冲刷点保留=无收集自然空转）
			if grid_hit_frame:
				_flush_hit_pairs()           # R285 T1 冲刷点：④ 尾统一提交（收集制命中）
			if death_flush_frame:
				_flush_deaths()              # R285 T3 冲刷点①：命中杀 fan-out 统一执行
			if stage_probe_enabled:
				stage_probe_us[&"grid_projectile"] = Time.get_ticks_usec() - _probe_t0
				stage_probe_us_peak[&"grid_projectile"] = maxi(int(stage_probe_us_peak.get(&"grid_projectile", 0)), int(stage_probe_us[&"grid_projectile"]))
				_probe_t0 = Time.get_ticks_usec()
			# ⑤ 敌 AI + 元素 tick + 帧末反应检测（E-07；倒序遍历——自爆/结算可在 tick 内回收）
			# R189c 定稿：敌段 LOD（隔帧 tick 实验）整体移除——安静环境 800p 实测两种
			# 形态均净负：2×delta 补账把帧时间打成双峰（P95 9.46 FAIL/超阈帧 6.6%）；
			# 1×delta 半帧率 + 豁免谓词每敌每帧 8 次动态访问，开销 ≈ tick 本身（P95
			# 8.94 FAIL/超阈帧 5.7%）。全帧率对照：avg 2.112 / P95 4.421 PASS / 超阈帧
			# 0.4%，优于 R187 历史基线（avg 3.114 / P95 5.887）。数据存 tracker 二ay。
			frame_order.append(&"enemy")
			var eidx := spawner.active.size() - 1
			while eidx >= 0:
				var enemy := spawner.active[eidx] as Enemy
				if is_instance_valid(enemy):
					enemy.tick(gd)
				eidx -= 1
			elemental.tick(gd)
			elemental.detect_reactions()
			# E-10 敌间软分离（R256 序2：10Hz 全量单帧尖峰→分片轮转；网格为 ④ 阶段
			# 重建快照——上一帧位置确定性口径不变）
			_tick_separation(gd)
			if death_flush_frame:
				_flush_deaths()              # R285 T3 冲刷点②：⑤ 尾（DOT/反应杀——
			                                 # elemental.tick+detect_reactions+分离之后、⑥ 前）
			if stage_probe_enabled:
				stage_probe_us[&"enemy"] = Time.get_ticks_usec() - _probe_t0
				stage_probe_us_peak[&"enemy"] = maxi(int(stage_probe_us_peak.get(&"enemy", 0)), int(stage_probe_us[&"enemy"]))
				_probe_t0 = Time.get_ticks_usec()
			# ⑥ 波次推进（生成节流 ≤8/帧 / 窗口计时 / Boss 伴随怪流水）
			frame_order.append(&"wave")
			wave_director.tick(gd)
			_tick_boss_summons(gd)            # B4 裂变召唤（R18 P3 接线，原零消费者死数据）
			relic_handler.tick(gd)            # R66：遗物内部冷却推进（暴击谐振 30s 内冷）
			_reap_corpses_soon(gd)            # R66：尸体看门狗（1Hz 降频——保底 + 诊断）
			if stage_probe_enabled:
				stage_probe_us[&"wave"] = Time.get_ticks_usec() - _probe_t0
				stage_probe_us_peak[&"wave"] = maxi(int(stage_probe_us_peak.get(&"wave", 0)), int(stage_probe_us[&"wave"]))
				_probe_t0 = Time.get_ticks_usec()
			# R189：连升溢出批分帧消化（抽卡时间预算内——不改战斗帧序语义）
			# R216 修（评审#1）：溢出消化成本归「卡」键（原落磁键误归因——mobile 8ms/帧
			# 预算可打满，深局磁键无端抬头会被误判磁吸回归）；消化后复位 _probe_t0，
			# 磁键只量磁吸碎片飞行/吸收
			# R220 刀1：卡键拆分——溢出消化段独立记 card_drain（消），与 _open_card_flow
			# 的 card_open（开）分键归因（vc26 卡键同键混合的拆账口径）。
			var _ovf_t0 := Time.get_ticks_usec() if stage_probe_enabled else 0
			_tick_merged_overflow()
			if stage_probe_enabled:
				stage_probe_us[&"card_drain"] = int(stage_probe_us.get(&"card_drain", 0)) + int(Time.get_ticks_usec() - _ovf_t0)
				stage_probe_us_peak[&"card_drain"] = maxi(int(stage_probe_us_peak.get(&"card_drain", 0)), int(stage_probe_us[&"card_drain"]))
				_probe_t0 = Time.get_ticks_usec()
			# ⑦ GameFeel（raw 通道）→ 顿帧申请出口（time_scale 唯一变更点）
			# R26：磁吸态碎片在选卡/暂停期继续飞向玩家（Boss 巨额经验连环选卡时
			# 「球冻半空」终解——磁吸=收割演出，吸收走 pending 升级队列安全）
			_tick_magnetized_shards(p_raw_delta)
			if stage_probe_enabled:
				# R213 拆键：磁=磁吸碎片飞行/吸收（→gain_xp 入账链）独立计——vc20 选卡窗
				# 感段跨窗尖峰 129ms 的归因粒度（磁吸 vs game_feel）
				stage_probe_us[&"feel_shard"] = Time.get_ticks_usec() - _probe_t0
				stage_probe_us_peak[&"feel_shard"] = maxi(int(stage_probe_us_peak.get(&"feel_shard", 0)), int(stage_probe_us[&"feel_shard"]))
				_probe_t0 = Time.get_ticks_usec()
			frame_order.append(&"feel")
			game_feel.tick(p_raw_delta)
			set_time_scale(game_feel.desired_time_scale(), &"gamefeel")
			if stage_probe_enabled:
				# R207 探针拆段：感=溢出消化+game_feel（R213 磁吸已独立计）
				stage_probe_us[&"feel"] = Time.get_ticks_usec() - _probe_t0
				stage_probe_us_peak[&"feel"] = maxi(int(stage_probe_us_peak.get(&"feel", 0)), int(stage_probe_us[&"feel"]))
				_probe_t0 = Time.get_ticks_usec()
			# ⑦b 元素签名特效层（连锁闪电/冲击环/火星）——R207 mobile 半频：纯视觉 FX
			# 30Hz 驱动（2δ 补齐，衰减/寿命全 dt 化语义恒等；手机掉帧期屏幕本就 <40fps）
			# R233 T4 决策2：模拟本身降到 30Hz 后隔帧相位会把本面打到 15Hz——谓词成立时
			# 短路直驱（每步 1/30 delta；回退 60Hz 档半频相位原样恢复）
			if elemental_fx != null:
				if OS.has_feature("mobile") and not sim30_effective():
					_fx_subtick_left -= 1
					if _fx_subtick_left <= 0:
						_fx_subtick_left = 2
						elemental_fx.tick(p_raw_delta * 2.0)
				else:
					elemental_fx.tick(p_raw_delta)
			if stage_probe_enabled:
				stage_probe_us[&"fx"] = Time.get_ticks_usec() - _probe_t0
				stage_probe_us_peak[&"fx"] = maxi(int(stage_probe_us_peak.get(&"fx", 0)), int(stage_probe_us[&"fx"]))
				_probe_t0 = Time.get_ticks_usec()
			# R220 刀11：damage_resolved 帧队列统一保序派发（时点定死⑧段前——最后一个
			# 结算产生段之后、_tick_ui 之前；popup tick 在 _tick_ui 内 ⇒ 跳字当帧起跳）。
			# 结算期只入队（DamagePipeline._broadcast）；pipeline.end_frame（帧序最末）
			# 不派发仅清队兜底。桩管线无 dispatch_resolved_frame 方法时跳过（桩不走
			# 真件 _broadcast，本调用零副作用）。开关常量回退（false）时管线即时同步
			# 派发 EventBus 原路径，本调用为 no-op（dispatch 内部队列恒空）。
			# R235 搭车③：派发段独立计时（&"dispatch" 键——原成本混入⑧ UI 段读数；
			# _probe_t0 在派发后复位 ⇒ UI 段只量 _tick_ui 本体。键不进 DIAG_STAGE_ORDER
			#（行中段不印——1Hz 行尾「派µs」键直读），进「他」段差分和（互斥段语义不变）。
			var _disp_t0 := Time.get_ticks_usec() if stage_probe_enabled else 0
			if pipeline != null and pipeline.has_method(&"dispatch_resolved_frame"):
				pipeline.call(&"dispatch_resolved_frame")
			if stage_probe_enabled:
				stage_probe_us[&"dispatch"] = Time.get_ticks_usec() - _disp_t0
				stage_probe_us_peak[&"dispatch"] = maxi(int(stage_probe_us_peak.get(&"dispatch", 0)), int(stage_probe_us[&"dispatch"]))
				_probe_t0 = Time.get_ticks_usec()
			# ⑧ UI（raw 通道：跳字/HUD/Boss 条——顿帧期间照常，Q-14）
			frame_order.append(&"ui")
			_tick_ui(p_raw_delta)
			if stage_probe_enabled:
				# R218 刀C：跳=⑧ 段内跳字池 tick（含 R212 排版批），UI=HUD/Boss条/震屏
				var _ui_total_us := Time.get_ticks_usec() - _probe_t0
				stage_probe_us[&"popup"] = _ui_popup_us
				stage_probe_us_peak[&"popup"] = maxi(int(stage_probe_us_peak.get(&"popup", 0)),
					int(stage_probe_us[&"popup"]))
				stage_probe_us[&"ui"] = _ui_total_us - _ui_popup_us
				stage_probe_us_peak[&"ui"] = maxi(int(stage_probe_us_peak.get(&"ui", 0)),
					int(stage_probe_us[&"ui"]))
			# R215 刀A：延迟开窗消费（磁吸收链同帧升级在此开窗——⑧ 后帧尾，中场切
			# LEVEL_UP/树暂停不再打断任何段）
			_consume_deferred_level_open()
		GameConst.GameStatus.LEVEL_UP, GameConst.GameStatus.PAUSED:
			# tree.paused=true 冻结全部 PAUSABLE 子系统（AC-16.2 战斗完全冻结）；
			# 仅 ⑦⑧ 以 raw 通道运行（架构帧序契约）。
			# 用户反馈 2026-08-29：PAUSED 期 GameFeel 计时（顿帧/震屏衰减）一并冻结——
			# ⑦ 标签保留（帧序契约），以零时长驱动；LEVEL_UP 沿用 raw 通道原口径
			frame_order.clear()
			# R212 刀6：选卡/暂停期探针补洞——原 stage_probe 只在 PLAYING 分支记录，
			# LEVEL_UP 期（选卡 UI 创建+磁吸+HUD 刷新的尖峰窗）完全盲区，vc18 的
			# 247/138/164ms 尖峰只能来自 PLAYING 帧口径（低估选卡期真实卡顿）。
			# feel/ui 两键照 PLAYING 同口径（逐帧重建 + peak 通道），供 vc19 验刀
			var _probe_t0 := Time.get_ticks_usec() if stage_probe_enabled else 0
			if stage_probe_enabled:
				stage_probe_us.clear()
				_probe_active = true
			# R26：磁吸态碎片在选卡/暂停期继续飞向玩家（Boss 巨额经验连环选卡时
			# 「球冻半空」终解——磁吸=收割演出，吸收走 pending 升级队列安全）
			# R212 刀3（mobile 门）：磁吸碎片隔帧 2δ 驱动——Boss 大珠吸收风暴期
			# xp_gained→HUD 置脏与 gain_xp 入账的源头频率减半（碎片在选卡覆盖层后，
			# 30Hz 推进观感无损；R26 收割演出语义恒等——磁吸照常飞、入账照常走
			# pending/溢出批，仅驱动粒度变化；桌面每帧驱动原样）
			# R233 T4 决策2：模拟 30Hz 下隔帧相位=15Hz——谓词成立时短路直驱
			# （每步 1/30 delta；回退 60Hz 档半频相位原样恢复）
			_fullload_absorb_frame_open()     # R225 刀a：② 未运行的帧序（选卡/暂停）在此开帽
			if OS.has_feature("mobile") and not sim30_effective():
				_shard_subtick_left -= 1
				if _shard_subtick_left <= 0:
					_shard_subtick_left = 2
					_tick_magnetized_shards(p_raw_delta * 2.0)
			else:
				_tick_magnetized_shards(p_raw_delta)
			if stage_probe_enabled:
				# R213 拆键：磁=选卡期磁吸碎片飞行/吸收（→gain_xp→pending 排队链）独立计
				# ——vc20 三次选卡窗跨窗尖峰 感83/感129ms 的归因粒度（与 PLAYING 同键）
				stage_probe_us[&"feel_shard"] = Time.get_ticks_usec() - _probe_t0
				stage_probe_us_peak[&"feel_shard"] = maxi(int(stage_probe_us_peak.get(&"feel_shard", 0)),
					int(stage_probe_us[&"feel_shard"]))
				_probe_t0 = Time.get_ticks_usec()
			frame_order.append(&"feel")
			game_feel.tick(0.0 if state == GameConst.GameStatus.PAUSED else p_raw_delta)
			set_time_scale(game_feel.desired_time_scale(), &"gamefeel")
			if stage_probe_enabled:
				stage_probe_us[&"feel"] = Time.get_ticks_usec() - _probe_t0
				stage_probe_us_peak[&"feel"] = maxi(int(stage_probe_us_peak.get(&"feel", 0)),
					int(stage_probe_us[&"feel"]))
				_probe_t0 = Time.get_ticks_usec()
			frame_order.append(&"ui")
			_tick_ui(p_raw_delta)
			if stage_probe_enabled:
				# R218 刀C：跳/UI 双键同 PLAYING 臂（选卡期 HUD 刷新尖峰 vs 跳字归因）
				var _ui_total_us := Time.get_ticks_usec() - _probe_t0
				stage_probe_us[&"popup"] = _ui_popup_us
				stage_probe_us_peak[&"popup"] = maxi(int(stage_probe_us_peak.get(&"popup", 0)),
					int(stage_probe_us[&"popup"]))
				stage_probe_us[&"ui"] = _ui_total_us - _ui_popup_us
				stage_probe_us_peak[&"ui"] = maxi(int(stage_probe_us_peak.get(&"ui", 0)),
					int(stage_probe_us[&"ui"]))
			# R188-idle：挂机自动出口驱动（选卡展示窗/商店出击窗——raw 通道，模态期可走）
			_tick_auto_idle(p_raw_delta)
		GameConst.GameStatus.GAME_OVER:
			# R188-idle：帧序新增分支（原 `_:` pass）——重开倒计时（mode 1/2）raw 通道
			# 驱动 + 每帧刷新结算卡面秒数；mode 0/每日局不挂起即零成本 pass 等价
			_tick_auto_restart(p_raw_delta)
		GameConst.GameStatus.MENU:
			# R215 刀C：菜单期分帧贴图预热（静态屏 12ms/帧空闲消化队列——boot 集中
			# 生成实测 6.8s 超预算；进战斗前消化完=首次登场变体零战斗帧成本）
			# R215 修：boss 双面 88-245ms 单帧顿挫从『开局必现』改『挂机才发生』——
			# 停留累计 <3s 时队首 boss 项暂停；快速开局者剩余项走惰性路径（不劣于现状）
			_menu_dwell_s += p_raw_delta
			# R244 物理相冲刷桶批：预热消费迁渲染轴（_process 侧调用——见 _process 头注；
			# dwell 计时留物理侧 60Hz 精度，boss 挂机门读同一变量语义不变）
			_maybe_start_phase0_calib()     # R235 搭车④：菜单停留门后一次性挂载六臂校准件
		_:
			pass                                  # BOOT：无战斗帧序（MENU 见上臂）
	if death_flush_frame:
		_flush_deaths()                     # R285 T3 冲刷点③：帧末兜底（pipeline.end_frame
		                                    # 同位——防 ⑥⑦ 段意外入队跨帧滞留，同帧内闭合）
	if pipeline != null:
		pipeline.end_frame()
	EventBus.end_frame()                          # 事件风暴计数清零（§六.4）
	if _probe_active:
		# R218 刀A（二j #1）：他=物理帧全函数 − 全键互斥和（十六段+派µs+entry——R220 卡键
		# 拆分/R235 派发分键/R244 帧入口键递进；循环遍历全键自动含后来者）——
		# 段间空隙/编排/事件派发等未捕获 GDScript 的归因粒度（vc25 引擎侧 余15-56ms
		# 先切出我方部分；段和去 移/火 两子集键——与 debug_stats 余值同口径。
		# R268 性能刀 P2：popup 出排除表（跳与 UI 兄弟互斥段非子集）——popup tick 在
		# 物理帧内执行原被他键独吞 → 物步残差双计；三表同步：debug_stats 物步减项/余值段和）
		var _seg_sum := 0
		for key in stage_probe_us:
			if key != &"player_mv" and key != &"player_wp":
				_seg_sum += int(stage_probe_us[key])
		var _other_us := maxi(int(Time.get_ticks_usec() - _phys_t0) - _seg_sum, 0)
		# 修轮#3（评审）：段测量各自取时/写字典开销错位下段和可虚高超全函数——钳 0
		# 防 diag 出「他-3ms」噪音行（peak 通道 maxi 本就免疫负值）
		stage_probe_us[&"other"] = _other_us
		stage_probe_us_peak[&"other"] = maxi(int(stage_probe_us_peak.get(&"other", 0)), _other_us)
	_ip_snapshot_pass()                     # R233 T6：帧末快照（_ip_prev=_ip_curr; _ip_curr=
	                                        # global_position——步内一切写位帧末统一收编；
	                                        # 挂探针段之后不污染「他」键）。
	                                        # R233 T7 切换态保鲜：快照无条件（两态同价）——
	                                        # 谓词关期实体每帧移动而缓冲若冻结，复机帧入口
	                                        # 恢复会把全体实体拽回冻结位（撕裂+穿透重复
	                                        # 覆盖）；保鲜后恢复恒 no-op。恢复遍历与插值写
	                                        # 仍同谓词零执行（关态零写契约不变）。
	# R271 P1：步出口时戳（步µs 收口——主哨兵前，同函数面只加不改）
	DebugStats.diag_step_end()
	# R269 B 轨：物理相末尾冲刷窗哨兵（延µs 键源）——入队时刻=本行 Time 读数，deferred
	# 在 message_queue 冲刷点执行（DebugStats.diag_flush_sentinel 收差值入秒窗桶）。
	# 只加计时不改行为：目标是 DebugStats（autoload）方法，零场景树副作用零分支变更。
	DebugStats.call_deferred(&"diag_flush_sentinel", Time.get_ticks_usec())


# ── 状态机（迁移矩阵仲裁，E-16） ─────────────────────────────────
var _bad_transition_warn_ms: int = -100000     # R256：非法迁移告警节流游标（卡死进程逐帧
                                               # 重试迁移在 headless 无帧帽下可刷 GB 级日志
                                               # ——R205 EventBus 同款 5s 一条封顶）

func change_state(p_new: int) -> bool:
	# 仲裁：迁移矩阵校验 → tree.paused 联动 → state_changed 广播
	var allowed: Array = TRANSITIONS.get(state, [])
	if not allowed.has(p_new):
		rejected_transitions += 1
		var now_ms := Time.get_ticks_msec()
		if now_ms - _bad_transition_warn_ms >= 5000:
			_bad_transition_warn_ms = now_ms
			# R257 评审M1：拒绝也入环（与成功迁移对称）——否则「出发被仲裁拒」与
			# 「start_run 后中途崩」在 diag 导出里形态同构不可分；同 5s 节流防刷环
			DebugStats.event("迁移拒绝 %d→%d（计数 %d）" % [
				state, p_new, rejected_transitions])
			push_warning("[GameLoop] 非法状态迁移拒绝：%d → %d（计数 %d）" % [
				state, p_new, rejected_transitions])
		return false
	DebugStats.event("状态 %d→%d" % [state, p_new])   # R257：迁移入环（出发链事件间的骨架）
	state = p_new
	# R262e ②：菜单态帧率帽 60（mobile 门内——桌面/headless 零写护 120Hz 基准口径）。
	# vc71 真机日志实证：菜单动画期渲ms 9.2-10.8 波动、模 44-59=fps 79-120 抖动
	# （超 120 档预算线 8.33ms 即掉档）——抖动帧率比稳定 60 更卡眼（「不丝滑」观感
	# 根源，与渲染质量无关）。稳 60 的 16.6ms 预算全容纳菜单负载=零掉帧；物理 60Hz
	# 与渲染 60 对齐。离 MENU 恢复用户 fps_cap 帽（_apply_fps_cap 同式：0=不限复位）。
	if OS.has_feature("mobile"):
		if p_new == GameConst.GameStatus.MENU:
			Engine.max_fps = 60
		else:
			Engine.max_fps = int(Meta.settings("fps_cap"))
	# 修轮#4（评审）：离开战斗态（MENU/GAME_OVER）清空探针段——否则回菜单后 diag 行
	# 以状态字 M 复读离场前最后帧的冻结段值（含 R218 他键），误导判读；PAUSED/LEVEL_UP
	# 期照常记录（R212 补洞口径），不清
	if p_new == GameConst.GameStatus.MENU or p_new == GameConst.GameStatus.GAME_OVER:
		stage_probe_us.clear()
	# R189：溢出批分帧消化批中断收口——离局迁移（GAME_OVER/MENU）把未消化残余清零
	# 并强制结清成就/落盘抑制态（否则结算侧 _check_achievements/_save 被抑制挂起，
	# 结算记录不落盘；重开/续档路径由 _reset_run_state/serialize 同名清零位覆盖）
	if _merged_overflow_draining and (p_new == GameConst.GameStatus.GAME_OVER
			or p_new == GameConst.GameStatus.MENU):
		_merged_overflow_draining = false
		merged_overflow_level_ups = 0
		_merged_overflow_deferred = {}   # R212 刀4：让渡卡随批一并废弃（离局无下一帧）
		Meta.cancel_persist_defer()
	get_tree().paused = (p_new == GameConst.GameStatus.PAUSED
		or p_new == GameConst.GameStatus.LEVEL_UP)
	# R18 残留根修：进 LEVEL_UP/PAUSED/GAME_OVER → 全场碎片立即转磁吸飞行态——
	# Boss 死爆出的大珠 + 升级选卡（tree.paused 冻结 shard tick）是「球不动不消失」
	# 观感的根因；磁吸姿态冻结在覆盖层后 = 有意的收集演出，恢复后即刻吸完
	if p_new == GameConst.GameStatus.PAUSED or p_new == GameConst.GameStatus.LEVEL_UP \
			or p_new == GameConst.GameStatus.GAME_OVER:
		for shard in active_shards:
			if is_instance_valid(shard):
				shard.force_magnet()
	# R266：进冻结模态（LEVEL_UP 选卡/PAUSED 暂停——tree.paused 把玩家冻在原地）时
	# 清空全部爆虫引导。弹卡瞬间已贴脸引导中的爆虫，收卡后残余引信不足（贴脸冲刺
	# 260px/s + 爆炸半径 110px——剩 <0.5s 数学上躲不掉），玩家被冻结期间无从规避
	# =「升级选卡被自爆兵贴脸炸」体感（vc75 用户澄清反馈）。清引导=收卡后重新接触
	# 重新计 1.2s 完整引信，玩家有完整反应窗（击退打断同款 _cancel_fuse 语义）。
	if p_new == GameConst.GameStatus.LEVEL_UP or p_new == GameConst.GameStatus.PAUSED:
		if spawner != null and spawner.active != null and not spawner.active.is_empty():
			var defused := 0
			for e_v: Variant in spawner.active:
				var e := e_v as Enemy
				if e != null and is_instance_valid(e) and e.defuse_if_armed():
					defused += 1
			if defused > 0:
				DebugStats.event("模态冻结清爆虫引导 %d 只（态 %d）" % [defused, p_new])
	if p_new == GameConst.GameStatus.GAME_OVER:
		time_scale = 1.0                          # 结算屏恢复常态缩放（下一局干净起步）
		# R66 残留收口：死亡局掉落（含 Boss 大珠）不再冻屏——进结算屏立即回收全场碎片
		#（胜利路径 R15 收尾窗本就回收，此处统一死亡路径口径——玩家被 Boss 打死同帧
		# 其掉落冻在结算屏后不消失 =「boss 尸体依旧不消失」体感源之一）
		for shard in active_shards.duplicate():
			if is_instance_valid(shard):
				(pools[&"xp"] as XPPool).release(shard)
		active_shards.clear()
		if not _victory_pending_active():         # 夜间R24：非通关（死亡/暂停中放弃）→ 失败音
			sfx.play(&"defeat")
	# BGM 场景运输（R75 六轨）：战斗/选卡连续播放（LEVEL_UP 不掐音乐——选卡高频，
	# 掐断听感差）；暂停/结算全场静默；MENU 换大厅曲（Boss 层随回菜单收起）
	if sfx != null:
		var in_combat := p_new == GameConst.GameStatus.PLAYING 			or p_new == GameConst.GameStatus.LEVEL_UP
		sfx.bgm_set_active(in_combat)
		sfx.bgm_set_scene_menu(p_new == GameConst.GameStatus.MENU)
		if p_new == GameConst.GameStatus.MENU:
			sfx.bgm_set_boss_layer(false)
			sfx.bgm_roll_menu_variant()         # R79 回大厅换曲（2 套轮换）
	# R270 修复①（vc79 真机主页回归）：分辨率降档随状态迁移收放——进活战态应用、
	# 回 MENU/GAME_OVER 恢复 720×1280（菜单/结算 UI 按 720×1280 布点，boot 全局应用
	# =主页按钮溢出 612×1088 画布被裁的根因）。幂等零成本（同档直返）。
	_apply_boost_resolution()
	EventBus.emit_state_changed(p_new)
	return true


func request_pause() -> bool:
	# M-16/M-17 暂停申请（仲裁后生效）
	return change_state(GameConst.GameStatus.PAUSED)


func _on_elite_summon(p_uid: int, p_id: StringName, p_pos: Vector2, p_ratio: float) -> void:
	# 夜间R40 唤潮者：cap 判定（场上该精英所召同种 <2）→ 精英环带落点入队
	var alive := 0
	for e in spawner.active:
		if is_instance_valid(e) and not bool(e.get("dead")) 				and (e as Enemy).data != null and (e as Enemy).data.id == p_id 				and int(e.get_meta(&"_summoned_by", -1)) == p_uid:
			alive += 1
	if alive >= 2:
		return
	var ring := Vector2.from_angle(randf() * TAU) * randf_range(64.0, 110.0)
	spawner.enqueue({"data_id": String(p_id), "wave": wave_director.current_wave,
		"tags": 0, "pos": p_pos + ring, "hp_ratio": p_ratio, "summon_uid": p_uid})


func _play_boss_phase_sfx(p_phase: int, p_enraged: bool) -> void:
	# 夜间R19：Boss 阶段切换/狂暴音（phase=0 表狂暴）
	if not _fx_sfx_allowed():
		return
	if p_enraged:
		sfx.play(&"boss_enrage")
	else:
		sfx.play(&"boss_phase")


func _play_state_trigger_sfx(p_code: int, _p_pos: Vector2) -> void:
	# 夜间R16：满槽状态触发音（点燃/寒滞+冻结共用冰音/感电）
	if not _fx_sfx_allowed():
		return
	match p_code:
		ElementalState.TRIGGER_BURN:
			sfx.play(&"ele_ignite")
		ElementalState.TRIGGER_CHILL, ElementalState.TRIGGER_FREEZE:
			sfx.play(&"ele_frost")
		ElementalState.TRIGGER_SHOCK:
			sfx.play(&"ele_zap")


func _fx_sfx_allowed() -> bool:
	# 夜间R37：低特效档（0）静音表现增强类音效——与 R23 施法音同政策
	#（结算音 victory/defeat 为关键结果反馈，不受此门）
	return clampi(int(Meta.settings("fx_quality")), 0, 2) > 0


func _on_graze_feedback(p_pos: Vector2) -> void:
	# c4① 掠过微光消费侧（二cp#1 表现收口）：无敌窗静默吞没的轻反馈——池化粒子一次性
	# 发射（AMBIENT 档：满池最先被抢占丢弃，绝不挤掉 KILL/CRIT/HIT 结算反馈）。headless
	# 无显示服务 → 零副作用仅计数（新套件断言 graze_fx 与 graze_hits 同步计数）。
	DebugStats.count(&"graze_fx", 1)
	if DisplayServer.get_name() == "headless":
		return
	if fx_particles != null:
		fx_particles.burst(&"particle", p_pos, ParticleDirector.PRIORITY_AMBIENT)


func _play_reaction_sfx(p_rxn: int, _p_pos: Vector2, _p_target_uid: int) -> void:
	# 夜间R15：元素反应音（按反应类型分音色）→ R192 矩阵扩 20 臂（零新音频资产——
	# 族级复用既有 3 条流：冲击读感=shatter / 爆发读感=overload / 减益工具读感=super）
	if not _fx_sfx_allowed():
		return
	match p_rxn:
		GameConst.ReactionType.RXN_FIR_ICE, GameConst.ReactionType.RXN_FIR_HYD, \
		GameConst.ReactionType.RXN_HYD_DEN:
			sfx.play(&"rxn_shatter")               # 碎裂 / 蒸发 / 绽放（冲击结算族）
		GameConst.ReactionType.RXN_FIR_LTG, GameConst.ReactionType.RXN_FIR_ANE, \
		GameConst.ReactionType.RXN_ICE_ANE, GameConst.ReactionType.RXN_LTG_ANE, \
		GameConst.ReactionType.RXN_HYD_ANE, GameConst.ReactionType.RXN_ANE_DEN:
			sfx.play(&"rxn_overload")              # 过载 / 扩散族×5（AoE 爆发族）
		GameConst.ReactionType.RXN_ICE_LTG, GameConst.ReactionType.RXN_ICE_HYD, \
		GameConst.ReactionType.RXN_LTG_HYD, GameConst.ReactionType.RXN_FIR_DEN, \
		GameConst.ReactionType.RXN_LTG_DEN, GameConst.ReactionType.RXN_FIR_GEO, \
		GameConst.ReactionType.RXN_ICE_GEO, GameConst.ReactionType.RXN_LTG_GEO, \
		GameConst.ReactionType.RXN_HYD_GEO, GameConst.ReactionType.RXN_DEN_GEO, \
		GameConst.ReactionType.RXN_ANE_GEO:
			sfx.play(&"rxn_super")                 # 超导 / 冻结 / 感电 / 燃烧 / 激化 / 结晶族×6（减益工具族）


func _on_shop_requested(p_wave: int, p_pre_boss: bool = false) -> void:
	# 战地黑市开店仲裁（M7）：PLAYING 态 → LEVEL_UP（复用弹卡态，E-16 仲裁同源）
	# R188-idle：开店即挂自动出击窗（黑市波/战前补给三源汇总口共用；重入重置计时）。
	# 一期固定自动跳过（不做商店购买策略——吃 shop_ui.buyable_count()/has_stock()
	# 谓词为二期自动购买硬前置，本项只站稳不消费）
	# R189：p_pre_boss = 战前补给态标题位（此前该源绕过本口直开 shop_ui，自动窗漏挂
	# → 挂机态商店永不离店；现与波表/遗物排程同汇本口）
	_auto_card_left = -1.0                       # 商店模态优先——选卡窗撤销
	_auto_shop_seen_purchases = -1               # 采购计数基线（下帧对账重建）
	_auto_shop_seen_refresh = -1                 # R189c：刷新基线一并重建（旧值残留 → 重开店首帧误判手动，出击窗翻倍一拍）
	_auto_shop_left = AUTO_SHOP_WINDOW_S
	if state != GameConst.GameStatus.PLAYING:
		return
	if change_state(GameConst.GameStatus.LEVEL_UP):
		shop_ui.open(player, p_wave, p_pre_boss)


# ── R188-idle 挂机自动驱动（消费 Meta.settings("auto_select_on"/"auto_restart_mode")） ──
func _tick_auto_idle(p_raw_delta: float) -> void:
	# LEVEL_UP/PAUSED raw 分支挂点（模态期驱动；关挂机零成本直返并撤销挂起窗）
	if not bool(Meta.settings("auto_select_on")):
		_auto_card_left = -1.0
		_auto_sublime_left = -1.0               # R245：大屏自动确认窗一并撤销（挂机关=零成本）
		_auto_shop_left = -1.0
		return
	# ⓪ 红卡大屏自动确认窗（R245 设计 §1.5/§6.4-2：不扩此臂 = auto_select_on 用户
	# 永久停大屏〔P0 级死锁〕；1.5s=选卡窗 3 倍阅读时间。手动按下「确认」即 is_open
	# 翻 false → 窗撤销——不与玩家抢操作节奏）
	if _auto_sublime_left >= 0.0:
		if sublime_confirm_ui == null or not sublime_confirm_ui.is_open():
			_auto_sublime_left = -1.0           # 玩家已手动确认/界面已收 → 撤销
		else:
			_auto_sublime_left -= p_raw_delta
			if _auto_sublime_left <= 0.0:
				_auto_sublime_left = -1.0
				sublime_confirm_ui.confirm()    # confirmed → _finish_card_choice（真链同手动）
				return
	# ① 商店自动出击窗（玩家买货/刷新/出击/关店 → 窗撤销或重置——手动操作即时取消）
	if _auto_shop_left >= 0.0:
		if shop_ui == null or not shop_ui.is_shop_visible() \
				or state != GameConst.GameStatus.LEVEL_UP:
			_auto_shop_left = -1.0               # 玩家已手动出击/关店
		else:
			var purchases := shop_ui.purchase_count()
			var refreshes := shop_ui.refresh_count_used()
			if _auto_shop_seen_purchases < 0 or _auto_shop_seen_refresh < 0:
				# R189c：双基线任一未建 → 本帧对账重建（-1 哨兵口径）
				_auto_shop_seen_purchases = purchases
				_auto_shop_seen_refresh = refreshes
			elif purchases != _auto_shop_seen_purchases or refreshes != _auto_shop_seen_refresh:
				# 玩家手动买货/刷新 → 计时重置（不与玩家抢操作节奏）
				_auto_shop_seen_purchases = purchases
				_auto_shop_seen_refresh = refreshes
				_auto_shop_left = AUTO_SHOP_WINDOW_S
			else:
				_auto_shop_left -= p_raw_delta
				if _auto_shop_left <= 0.0:
					_auto_shop_left = -1.0
					shop_ui.close()               # closed → request_resume（回 PLAYING）
					return
	# ② 选卡自动窗（真实弹窗批：card_select_ui.is_open 口径——连升合并溢出批不弹卡窗，
	# 本计时器只消化真实弹窗批）
	if _auto_card_left >= 0.0:
		if card_select_ui == null or not card_select_ui.is_open \
				or state != GameConst.GameStatus.LEVEL_UP:
			_auto_card_left = -1.0               # 界面已收（手动已选/流关闭）→ 撤销
			_auto_card_shown_index = -1
			_auto_card_retries = 0
		else:
			_auto_card_left -= p_raw_delta
			# 展示窗首帧：策略预选描金（成对同行双亮——「自动将要选」的 0.5s 预告）
			if _auto_card_shown_index < 0:
				var picked := AutoIdleStrategy.pick(current_candidates, _dual_pending)
				if picked >= 0:
					_auto_card_shown_index = picked
					card_select_ui.highlight_candidate(picked)
			if _auto_card_left <= 0.0:
				_auto_card_choose()


func _auto_card_choose() -> void:
	# choose 真链（与手动点击同一条 choice_made 信号链——严禁 open() 栈内同步 choose）。
	# 防重试帽：候选空/槽位无效帽内重挂窗，超帽弃选停窗（防死循环）；is_open 翻 false
	# 即自然重置（窗口撤销）
	if card_select_ui == null or not card_select_ui.is_open \
			or state != GameConst.GameStatus.LEVEL_UP:
		_auto_card_left = -1.0
		return
	var picked := AutoIdleStrategy.pick(current_candidates, _dual_pending)
	if picked < 0:
		_auto_card_retries += 1
		if _auto_card_retries > AUTO_RETRY_CAP:
			_auto_card_left = -1.0
			return
		_auto_card_left = AUTO_CARD_WINDOW_S
		return
	card_select_ui.choose(picked)                 # choice_made → _on_card_choice（窗撤销）


func _tick_auto_restart(p_raw_delta: float) -> void:
	# GAME_OVER 帧序分支：mode∈{1,2} 且非每日局 → 3s 倒计时自动重开（mode0/每日局回退
	# 停结算）；每帧刷新结算卡面倒计时 Label；玩家三出口任一按下 → 状态迁移侧取消
	var mode := clampi(int(Meta.settings("auto_restart_mode")), 0, 2)
	if mode <= 0 or Meta.is_run_daily():
		if _auto_restart_left >= 0.0:
			_auto_restart_left = -1.0             # 开关切走/每日局回退 → 撤销
			if game_over_screen != null:
				game_over_screen.cancel_auto_countdown()   # R189c：Label 残留收口（潜伏路径对齐到期分支）
		return
	if _auto_restart_left < 0.0:
		_auto_restart_left = AUTO_RESTART_WINDOW_S   # 进 GAME_OVER 首帧挂起
	_auto_restart_left -= p_raw_delta
	if game_over_screen != null:
		game_over_screen.set_auto_countdown(_auto_restart_left)
	if _auto_restart_left <= 0.0:
		_auto_restart_left = -1.0
		if game_over_screen != null:
			game_over_screen.cancel_auto_countdown()
		# mode2 通关屏（无尽出口可见）先 continue_endless，失败回落 restart_run；
		# 死亡屏/无尽出口不可见 → restart_run（continue_endless 自拒每日局，双重防线）
		if mode == 2 and game_over_screen != null \
				and game_over_screen.is_endless_offer_visible() and continue_endless():
			return
		restart_run()


func _on_wave_cleared_collect(_p_wave: int) -> void:
	# R7：波清空全屏碎片磁吸回收（含 Boss 大珠——残留不消失兜底；资源不丢）
	# R62 自查连带修复：本回调签名原为 0 参——signal wave_cleared(wave) 带 1 参派发，
	# 每次清波都报「Method expected 0 arguments」且**回调不执行**（磁吸兜底长期失效）
	for shard in active_shards:
		if is_instance_valid(shard):
			shard.force_magnet()


func _on_wave_cleared_victory(p_wave: int) -> void:
	# 通关即结算（R10 用户反馈「波次结束不结束当前关卡吗，波次怎么还在叠加」）：
	# 清完 final 波（Boss 波）→ 胜利结算屏；下一关由选关解锁链承接。
	# R15：不立刻切结算——Boss 爆炸的碎片球/彩纸需要收尾（用户实测「彩色球残留屏幕」
	# =结算瞬间停帧把表现件冻在屏上）。开 2.2s 收尾窗：波末磁吸继续工作，窗口结束
	# 回收残余碎片 + RunSave.clear + 胜利结算
	# R62：无尽继续局不再重复胜利——打到死亡为止（本局记录由死亡结算统一落账）
	if _endless_mode:
		return
	if state != GameConst.GameStatus.PLAYING or current_map_id == StringName(""):
		return
	var final_wave := int(MapTable.get_map(current_map_id).get("final_wave", 1 << 30))
	if p_wave < final_wave:
		return
	_victory_pending_left = 2.2


func _victory_pending_active() -> bool:
	# 夜间R24：通关收尾窗内（=即将 show_victory）返回 true——change_state(GAME_OVER)
	# 的失败音兜底要跳过这条胜利路径（victory 音已在 _tick_victory_pending 播放）
	return _victory_pending_left > 0.0


func _tick_victory_pending(p_raw_delta: float) -> void:
	# R62：收尾窗期间闸住驱动器自动开波（窗 2.2s > 波间缓冲 1.8s，不闸则第 final+1 波
	# 被短暂开出 → wave_started 派发 → Meta 误记 endless_depth=1）；窗结束/未开窗即复位
	wave_director.advance_blocked = _victory_pending_left > 0.0
	if _victory_pending_left <= 0.0:
		return
	_victory_pending_left = maxf(_victory_pending_left - p_raw_delta, 0.0)
	if _victory_pending_left > 0.0 or state != GameConst.GameStatus.PLAYING:
		return
	for shard in active_shards.duplicate():
		if is_instance_valid(shard):
			(pools[&"xp"] as XPPool).release(shard)
			active_shards.erase(shard)
	RunSave.clear()
	# R62：非每日局延迟结算——通关屏提供「继续挑战·无尽」出口，玩家未选出口前
	# Meta 不落账（选重开/回菜单 → settle_now 兑现；选无尽 → 本局合并到死亡一次结算）
	var allow_endless := not Meta.is_run_daily()
	if allow_endless:
		Meta.mark_run_victory()               # R263：通关位写入（星尘产出 V 加成源；无尽合并
		                                          # = 之后死亡一次结算 V 恰加一次；不用 W≥final_wave 近似）
		Meta.defer_settle_once()
		_victory_settle_pending = true
	if change_state(GameConst.GameStatus.GAME_OVER):
		sfx.play(&"victory")                 # 夜间R24：通关结算音
		game_over_screen.show_victory(allow_endless)


func continue_endless() -> bool:
	# R62 无尽继续（通关屏「▶ 继续挑战 · 无尽」）：GAME_OVER → PLAYING，本局构筑/数值
	# 原样保留，自 final_wave+1 波续打；此局转为无尽态（不再重复胜利，打到死亡为止）。
	# 延迟结算取消（与死亡结算合并为一次——total_runs/结晶不双记）
	if state != GameConst.GameStatus.GAME_OVER or current_map_id == StringName("") \
			or Meta.is_run_daily():
		return false
	if not change_state(GameConst.GameStatus.PLAYING):
		return false
	PopupGlyphAtlas.ensure_runstart_bake()    # R227 评审 L1：今日经已挂口传递安全——补挂把
	                                          # 隐式不变量变结构（未来新增直进局路径不静默失效）
	_arm_resume_grace()                        # R199-P18：通关屏直迁 PLAYING 与暂停恢复同款
	                                           # 输入宽限（结算屏期拖动残留不落位）
	if _victory_settle_pending:
		Meta.cancel_deferred_settle()
		_victory_settle_pending = false
	_auto_restart_left = -1.0                   # R188-idle：无尽续打 → 重开倒计时撤销
	_endless_mode = true
	var map_def := MapTable.get_map(current_map_id)
	hud.endless_depth_base = int(map_def.get("final_wave", 1 << 30))
	var next_wave := hud.endless_depth_base + 1
	wave_director.advance_blocked = false      # 收尾窗闸复位（防御）
	_reorder_tex_prewarm_wave_first()          # R267 刀P1：无尽续打同图波表在册——队列波序重排
	wave_director.start_wave(next_wave)
	return true


var _corpse_watch_left: float = 0.0            # R66 尸体看门狗降频计时（1Hz）


func _reap_corpses_soon(p_game_delta: float) -> void:
	# R66 尸体看门狗（用户反馈「boss尸体依旧不消失」）：正常死亡链
	#（_on_died → enemy_killed → spawner 池归还 → 隐藏）真件复现验证无缺口，
	# 本看门狗为保底 + 诊断——active 中出现 dead 且 visible 的敌（异常态尸体）
	# 强制归还并告警留痕；若真实局再现，日志可定位真源
	_corpse_watch_left -= p_game_delta
	if _corpse_watch_left > 0.0:
		return
	_corpse_watch_left = 1.0
	for e in spawner.active.duplicate():
		if e is Enemy and (e as Enemy).dead and (e as CanvasItem).visible:
			push_warning("[GameLoop] 尸体看门狗：死亡敌仍可见，强制归还 %s（uid=%d）"
				% [str(e.name), int((e as Enemy).uid)])
			spawner.active.erase(e)
			(pools[&"enemy"] as EnemyPool).release(e)


func _on_boss_spawned_track_summons(p_boss: Node2D) -> void:	# B4 裂变召唤调度注册（summons 数据此前全 Boss 零消费者——R18 P3 死数据接线）
	if p_boss == null or not is_instance_valid(p_boss):
		return
	var bdata: Variant = p_boss.get("data")
	if bdata == null or (bdata as EnemyData).boss.get("summons", {}).is_empty():
		return
	var cfg: Dictionary = (bdata as EnemyData).boss["summons"]
	if String(cfg.get("enemy_id", "")) == "":
		return
	_boss_summons[int(p_boss.get("uid"))] = {
		"boss": p_boss, "left": float(cfg.get("interval_s", 10.0)), "cfg": cfg,
	}


func _tick_boss_summons(p_gd: float) -> void:
	# 每 Boss 召唤节拍：phase 门控（summons.phase）→ 场上同种小怪 < cap 才补员
	# → spawner.enqueue（Boss 环带落点 + hp_ratio 面值折算）
	# R262b L3：keys() 快照分配改成员缓冲（带 summons 的 Boss 战期间每帧税）
	_boss_summon_keys.clear()
	for key_v: Variant in _boss_summons:
		_boss_summon_keys.append(key_v)
	for key: Variant in _boss_summon_keys:
		var st: Dictionary = _boss_summons[key]
		var boss: Node2D = st["boss"]
		if not is_instance_valid(boss) or bool(boss.get("dead")):
			_boss_summons.erase(key)
			continue
		var cfg: Dictionary = st["cfg"]
		if int(cfg.get("phase", 1)) > int(boss.get("boss_phase")):
			continue
		st["left"] = float(st["left"]) - p_gd
		if float(st["left"]) > 0.0:
			continue
		st["left"] = float(cfg.get("interval_s", 10.0))
		var eid := StringName(String(cfg.get("enemy_id", "")))
		var cap := int(cfg.get("cap", 4))
		var alive := 0
		for e in spawner.active:
			if is_instance_valid(e) and not bool(e.get("dead")) 					and (e as Enemy).data != null and (e as Enemy).data.id == eid 					and int(e.get_meta(&"_summoned_by", -1)) == key:
				alive += 1
		if alive >= cap:
			continue
		var count := int(cfg.get("count", 2))
		if int(boss.get("boss_phase")) >= 2:
			count = int(cfg.get("count_phase2", count))
		for i in range(mini(count, cap - alive)):
			var ring := Vector2.from_angle(randf() * TAU) * randf_range(64.0, 110.0)
			spawner.enqueue({"data_id": eid, "wave": wave_director.current_wave,
				"tags": 0, "pos": (boss as Node2D).global_position + ring,
				"hp_ratio": float(cfg.get("hp_ratio", 0.5)), "summon_uid": key})


func _on_relic_shop_wave(p_wave: int) -> void:
	# REL_BLACK_MARKET 追加商店波（w8 起每 5 波，排程真源 relic_handler）：波清空后
	# 消费一次排程开黑市——同波表 SHOP 事件口径（PLAYING 守卫在 _on_shop_requested）
	if relic_handler != null and relic_handler.pending_shop_waves > 0:
		relic_handler.pending_shop_waves -= 1
		_on_shop_requested(p_wave)


func _on_wave_cleared_pre_boss_shop(p_wave: int) -> void:
	# 战前补给（R5.12-P1）：每图 final Boss 波的前一波清空 → 固定商店（不算波表 SHOP
	# 事件位、不占黑市排程；标题走 shop_ui 战前补给态）。final 波清空走胜利结算，互斥。
	# R189：开店改走 _on_shop_requested 汇总口（战前补给态经 p_pre_boss 透传）——
	# 此前直开 shop_ui 漏挂挂机自动出击窗，商店永不离店（D2 验收口径）。
	if state != GameConst.GameStatus.PLAYING or current_map_id == StringName(""):
		return
	var final_wave := int(MapTable.get_map(current_map_id).get("final_wave", 1 << 30))
	if p_wave + 1 != final_wave:
		return
	_on_shop_requested(p_wave, true)


func _on_build_details() -> void:
	# 左下角构筑面板点击（用户反馈「点击左下角，可以看 buff 详情」）：战斗中 → 申请暂停
	# 并进详情卡；已暂停 → 暂停卡/详情卡切换；LEVEL_UP/GAME_OVER 等态不响应
	if state == GameConst.GameStatus.PLAYING:
		if request_pause():
			var relic_infos: Array = []
			for rid in card_generator.owned_relics:
				var rdata := registry.get_relic(rid)
				if rdata != null:
					relic_infos.append({"name": String(rdata.display_name),
						"desc": String(rdata.description)})
			pause_overlay.open_details(player, relic_infos)
	elif state == GameConst.GameStatus.PAUSED:
		pause_overlay.toggle_details()


func request_resume() -> bool:
	# 恢复申请：自 PAUSED 恢复时启动 0.5s 输入忽略期（防误触，用户反馈 2026-08-29）。
	# R199-P18：宽限置位/input_enabled 同步收敛为 _arm_resume_grace（选卡收口/无尽继续
	# 直迁 PLAYING 同款宽限——本函数不再持有专属置位逻辑）
	var resumed := change_state(GameConst.GameStatus.PLAYING)
	if resumed:
		_arm_resume_grace()
	return resumed


func _arm_resume_grace() -> void:
	# R199-P18：进 PLAYING 的 0.5s 输入忽略期申请口（暂停恢复/选卡收口/无尽继续同款）。
	# 动机：模态覆盖层（选卡/商店/暂停）开启期手指仍会累计拖动（player._unhandled_input
	# 照常采样 _drag_accum，player.gd:288-309），直迁无宽限时残留位移在收口瞬间全额落位
	# = 机体瞬移（300px 级，可能被拉进敌群/顶墙角）。input_enabled 即时同步（宽限自进入
	# 瞬间生效）——写权仍归 ① 步每帧口径（§1.3 单写者：帧外写点族=「申请瞬间」语义，
	# request_resume/_reset_run_state/本函数；每帧倒计时与放行仍归 _physics_process ①）。
	if resume_grace_left <= 0.0:
		resume_grace_left = RESUME_GRACE_S
	player.input_enabled = false


# ── R186 新角色首发（改造者自定义首发 / 回响随机双武装） ────────────
func _starting_weapon_id(p_char: StringName) -> StringName:
	# 首发仲裁：非 fission 恒手枪（角色门——防 custom 键泄漏给旧角色）；fission → 存档
	# 自定义（脏 id registry 查 null → 兜底手枪，Meta 侧无 registry 引用）
	if p_char != &"fission":
		return STARTING_WEAPON_ID
	var saved := Meta.custom_weapon()
	if saved != &"" and registry.get_weapon(saved) != null:
		# R253（二dc L2 缓办清账）：自定义首发过难度武器门——地狱限定的近战/法器不得
		# 作为首发带入普通/困难局（「获得优先于门」在卡池/echo 双武装生效，首发口径
		# 从严：难度层「普通见不到近战法器」的体验意图优先，菜单侧候选已同步过滤）。
		# 门不过 → 回落手枪（横幅 :1652 fission 宣告段自动随之不播）
		if MechanicGate.weapon_difficulty_min(saved) <= _difficulty:
			return saved
		return STARTING_WEAPON_ID
	return STARTING_WEAPON_ID


func _equip_starting_weapon(p_char: StringName) -> void:
	# 装备首发 + 注入即计图鉴（幂等；W1 入图鉴 = 修「手枪永不解锁」旧缺，军火大亨
	# 抽卡口径不受扰）。首获横幅走 add_weapon 既有 mark_first_met 链。
	var wid := _starting_weapon_id(p_char)
	player.add_weapon(registry.get_weapon(wid))
	Meta.mark_weapon_codex(wid)


func _reconcile_starting_weapon(p_char: StringName) -> void:
	# 开局对账（MF1 双保险）：slot0 ≠ 应配首发 → 清全部槽重装。装备时点 ≠ 选角时点
	#（set_character 不清槽 + boot 期选角未定），必须双保险。仅 start_run 调用——
	# 对账禁放 player.set_character（_reset_run_state 序：respawn 先于清槽/重装，会双装）。
	var expected := _starting_weapon_id(p_char)
	var s0: WeaponBase = player.weapon_slots[0] if player.weapon_slots.size() > 0 else null
	if s0 != null and is_instance_valid(s0) and s0.data != null \
			and StringName(String(s0.data.id)) == expected:
		return
	for i in range(player.weapon_slots.size()):   # 开局期构筑应为空，防御性全清
		var w: WeaponBase = player.weapon_slots[i] if i < player.weapon_slots.size() else null
		if w != null and is_instance_valid(w):
			w.queue_free()
		player.weapon_slots[i] = null
	_equip_starting_weapon(p_char)


func _append_difficulty_intro_lines() -> void:
	# R253 抽公共（原 start_run 内联段——continue_run 补发复用，二dc M4 缓办清账）：
	# 二dc 难度武器门横幅（近战/法器族分批——普通全锁/困难 1+1/地狱全开；W10 投掷
	# 类不属此族不受限）。三档都提示：普通玩家须知道「本局抽不到近战/法器」不是 bug。
	# ★调用方落位约定：须在 _grant_random_dual_loadout 之后（非 echo 角色 :1532 清残留
	# 行会吞掉之前追加的横幅——QA BUG-1 实证）；R72 行同侧幸存区。
	match _difficulty:
		GameConst.Difficulty.NORMAL:
			_run_intro_lines.append("【普通】近战/法器类武器未开放（困难解锁首对，地狱全开）")
		GameConst.Difficulty.HARD:
			_run_intro_lines.append("【困难】新武器：天狼刀（近战）· 旋风刀（法器）——第 4 关起上架，地狱全开")
		_:
			_run_intro_lines.append("【地狱】近战/法器类全部开放（仍按大关推进）")
	if _difficulty != GameConst.Difficulty.NORMAL:
		# R72 难度横幅（R186 起改收口追加：与随机武装/大关段合并为至多一条开场 toast，
		# 消费点 = _on_menu_start / _on_menu_start_daily / restart_run——单 Label toast
		# 后到覆写，直发多条会互相吞）
		_run_intro_lines.append("【%s】敌人数值 ×%d · 复活 %d 次 · 奖励 ×%.1f%s"
			% [GameConst.difficulty_name(_difficulty),
			int(GameConst.difficulty_dmg_mult(_difficulty)),
			GameConst.difficulty_revives(_difficulty),
			GameConst.difficulty_reward_mult(_difficulty),
			" · 每级双选" if _difficulty == GameConst.Difficulty.HELL else ""])   # R72 难度附赠复活


func _grant_random_dual_loadout(p_seed: int = -1) -> void:
	# R186 回响·伊可（random_dual）：开局随机双武器，池 = 注册表 − W1（基线手枪
	# weapon_note 空）− 门外武器（R196 武器准入门：echo 双武装与卡池同门——池 =
	# 门内集 − W1）× 2 次独立有放回抽取。局部 RNG：每日局 hash 确定性（同日同配置
	# 含双武器），常规局 randomize；不触碰 card_generator/spawner RNG 流。
	# 序：①角色门 → ②清全部槽（顺带清 boot 期预发手枪）→ ③预吞首遇横幅 + 计图鉴 + 装备
	# → ④追加【随机武装】行（开场 toast 唯一收口，不直接 emit）。
	if not bool(CharacterTable.get_character(player.character_id).get("random_dual", false)):
		_run_intro_lines.clear()              # ★R2①：非双武装角色入口清残留（防换角色误播）
		return
	for i in range(player.weapon_slots.size()):
		var w: WeaponBase = player.weapon_slots[i] if i < player.weapon_slots.size() else null
		if w != null and is_instance_valid(w):
			w.queue_free()
		player.weapon_slots[i] = null
	var pool: Array[StringName] = []
	for wid_v: Variant in registry.weapons.keys():
		var sid := StringName(String(wid_v))
		if sid != STARTING_WEAPON_ID and MechanicGate.weapon_allowed(sid):
			pool.append(sid)                  # R196：双武装同门（池 = 门内集 − W1）
	if pool.is_empty():
		# R196 契约变更（原 early-return = echo 角色空手开局）：池空回退双首发手枪。
		# 门分批上架后池空只可能发生在注册表空（致命配置已拦）/门内除 W1 无货——
		# 空手是体验缺陷非合理态，回退保武装 + 横幅文案照常收口（画 [W1,W1] 恒抽手枪）。
		pool = [STARTING_WEAPON_ID, STARTING_WEAPON_ID]
	var rng := RandomNumberGenerator.new()
	if p_seed >= 0:
		rng.seed = hash("dual|%d" % p_seed)   # 每日：同日同双武器（零全局 RNG 副作用）
	else:
		rng.randomize()
	var names: Array[String] = []
	for _k in range(2):
		var pick: StringName = pool[rng.randi_range(0, pool.size() - 1)]
		Meta.mark_first_met(StringName("W_" + String(pick)))   # 预吞 G8 首遇横幅
		Meta.mark_weapon_codex(pick)                           # 白拿计图鉴（不增抽卡计数）
		var wdata := registry.get_weapon(pick)
		player.add_weapon(wdata)                               # 无去重——同 id 可双持
		names.append(String(wdata.display_name) if wdata != null else String(pick))
	var line: String
	if names[0] == names[1]:
		line = "【随机武装】%s ×2" % names[0]
	else:
		line = "【随机武装】%s + %s" % [names[0], names[1]]
	_run_intro_lines.append(line)


func start_run(p_daily_seed: int = -1) -> bool:
	# MENU → PLAYING：波次 1 开局（当前地图波表 + 主题色 + Meta 记图——M2 多地图）。
	# p_daily_seed ≥ 0 = 每日挑战（P2）：当日固定种子局部注入卡池+出生流（不改 RNG 全局
	# 口径）+ 应用当日三词缀；-1 = 常规局（卡池每局随机）
	var _start_run_t0 := Time.get_ticks_usec()   # R262e ②：出发链耗时观测（尾部入事件环）
	if not change_state(GameConst.GameStatus.PLAYING):
		return false
	PerfGovernor.notify_new_run()             # R222 Fix G：新局重臂（正信号——评审修轮）
	# R267 刀P1【偏差声明】：设计处方 6「4 调用点统一改分档口径」未从——
	# qa_r227_bake_a:83（continue_run→built==12+ready）/ bake_b:121（restart→built==12）/
	# probe_r267_coldstart:49（start_run 直调→built==12）锁死「override=1 冷图集时入口
	# 同步全量补烤」——分档化必破三套不可改套件。保持全量兜底（≤30ms 档单独落账），
	# ≤8ms 常态档由祝福模态开帧暖通道交付（menu_screen.set_blessing_modal→
	# warm_runstart_cells；确认即出发的流程模态后无 MENU 泵窗口，暖在模态帧全量做）。
	PopupGlyphAtlas.ensure_runstart_bake()    # R227：位图激活兜底（菜单停留不足时补烤 ≤42ms 一次性）
	_endless_mode = false                       # R62：新局非无尽态（continue_endless 置位）
	_active_daily_seed = p_daily_seed           # R186：每日种子留存（echo 重开重 roll 确定性源）
	_run_intro_lines.clear()                    # R186：开场横幅收口复位（消费点外残留防御）
	# R198（R192-low4）：告警双闸以局为界——进局复位（R_alarm/R_rxn 广播闸跨局残留，
	# pipeline 进程级单实例；restart_run 经本路径天然覆盖）
	if pipeline != null and pipeline.has_method(&"reset_run_alarms"):
		pipeline.call(&"reset_run_alarms")
	if sfx != null:
		sfx.bgm_roll_combat_variant()          # R79 每局随机战斗套（首播前换流）
	_combo_count = 0                            # E9：连杀窗口复位
	_combo_tier_paid = 0                        # G9：连杀档位同步复位
	_combo_left = 0.0
	_victory_settle_pending = false
	_run_blessing_paid = false                 # R263：已购位随新局复位（新局 = 新扣费）
	merged_overflow_level_ups = 0               # R188-perf：连升合并溢出批随局清
	_deferred_level_open = -1                   # R215 刀A：延迟开窗档随局清（防跨局陈旧档）
	if _merged_overflow_draining:
		_merged_overflow_draining = false         # R189：分帧消化批中断——抑制态强制结清
		Meta.cancel_persist_defer()
	_merged_overflow_deferred = {}              # R212 刀4：让渡卡随局清（新局无残留）
	_auto_card_left = -1.0                      # R188-idle：挂机挂起窗全清（新局干净起步）
	_auto_shop_left = -1.0
	_auto_restart_left = -1.0
	_auto_card_shown_index = -1
	_auto_card_retries = 0
	wave_director.advance_blocked = false        # R62：收尾窗闸复位（防御）
	wave_director.wave_table = MapTable.load_table(current_map_id, registry)
	_reorder_tex_prewarm_wave_first()     # R267 刀P1：波表 roll 后队列波序重排
	Meta.set_run_map(current_map_id)
	if p_daily_seed >= 0:
		Meta.set_run_daily(true)
		card_generator.rng.seed = p_daily_seed    # 每日：确定性卡池（同日同配置口径）
		spawner.rng.seed = p_daily_seed           # 每日：确定性出生流（挑战内局部注入）
		card_generator.reseed_sublime(p_daily_seed)   # R246 每日：红色传说流同日定种（全服同日同批口径）
	else:
		Meta.set_run_daily(false)
		card_generator.rng.randomize()            # 卡池每局随机（固定种子=「选项写死」观感根因；pkg 测试自行定种子）
		card_generator.reseed_sublime()           # R246 常规局：红色传说流每局随机（0.001% 独立掷流）
	player.set_character(Meta.character_id)   # 角色应用（含养成加成——M8/角色系统）
	_reconcile_starting_weapon(Meta.character_id)   # R186 MF1：开局首发对账（boot/换角装错纠正）
	spawner.difficulty = _difficulty             # R72 敌数值乘区（出生管线单点）
	wave_director.difficulty = _difficulty        # R72 波表织入（新形态敌伴随）
	player.set_difficulty(_difficulty)             # R73 风险回报（经验侧乘区镜像）
	player.unlocked_slots = GameConst.difficulty_slot_default(_difficulty)   # R183 开局默认 2/3/3
	elemental.clear_reaction_mults()             # R183 反应乘区局清空（武器全量重建 uid 全换，旧注册作废——根治既有跨局慢性泄漏）
	Meta.set_run_difficulty(_difficulty)           # E11：结算分档记录 + 结晶乘区（二dc 兼难度门武装）
	player.revives_left += GameConst.difficulty_revives(_difficulty)
	_grant_random_dual_loadout(_active_daily_seed)   # R186：echo 随机双武装（非 echo 入口清残留行）
	_append_difficulty_intro_lines()              # R253 抽公共（continue_run 补发复用）
	if Meta.character_id == &"fission":
		# R186：改造者宣告（对账后追加——与实装一致；仅自定义非手枪时播）
		var swid := _starting_weapon_id(Meta.character_id)
		if swid != STARTING_WEAPON_ID:
			var swdata := registry.get_weapon(swid)
			_run_intro_lines.append("【%s】初始武器：%s（本局固定）" % [
				String(CharacterTable.get_character(Meta.character_id).get("name", "改造者·枢")),
				String(swdata.display_name) if swdata != null else String(swid)])
	_apply_start_blessing()                   # R252 需求②：开局祝福挂载（落 R250/R72/fission 横幅之后——
	                                          # 含每日种子守卫 _active_daily_seed>=0 自拒；B5 行序断言锚）
	# R253（R252 QA 缓办清账）遗物保底：进第 2 关起（relics_unlocked 门开）且本局尚无
	# 遗物 → 保底激活 1 件随机（原第 1 关零遗物+单件净获取 ÷1.44 构筑真空——保底打底）。
	# 局部 RNG（每日同日同保底件——_grant_random_dual_loadout 同口径，不碰卡池流）。
	if MechanicGate.relics_unlocked() and relic_handler.owned_count() == 0:
		var g_pool: Array[StringName] = card_generator._unowned_relic_ids()
		if not g_pool.is_empty():
			var g_rng := RandomNumberGenerator.new()
			if _active_daily_seed >= 0:
				g_rng.seed = hash("relicguarantee|%d" % _active_daily_seed)
			else:
				g_rng.randomize()
			var g_rid: StringName = g_pool[g_rng.randi_range(0, g_pool.size() - 1)]
			if relic_handler.activate(g_rid):
				card_generator.owned_relics.append(g_rid)   # 卡池 owned 同步（防保底件再上架）
				Meta.mark_relic_codex(g_rid)            # R253 评审 M4：保底同享「获得即收录」
				                                        #（card_chosen RELIC 分支同款——白送不解锁
				                                        # 打破口径；私有扫描走 call 先例 :3320）
				Meta.call(&"_check_achievements_of", [&"codex_relics"])
				var g_data := registry.get_relic(g_rid)
				_run_intro_lines.insert(0, "保底遗物：%s（本局构筑打底）"
					% (String(g_data.display_name) if g_data != null else String(g_rid)))
				                                        # R253 评审 M2：行首保活——TOAST_MAX_LINES=3
				                                        # 截尾保前 3 行，append 位（第 4+）在困难+祝福
				                                        # 场景整行被截（本批主打不可见即失效）
				DebugStats.count(&"relic_guarantee")
	hud.refresh_stats()                          # R186 MF2：角色/首发就位后显式刷（技能键可见性单写口，1Hz 兜底外的即时自愈）
	var map_def := MapTable.get_map(current_map_id)
	_apply_map_affixes(map_def)                  # 词缀二期：双词缀注入（祝→玩家 / 诅→敌侧）
	if p_daily_seed >= 0:
		# 每日挑战：重置后改施当日三词缀（2 诅咒 + 1 祝福——由日期种子决定，覆盖地图词缀）
		_reset_affixes()
		var affixes := Meta.daily_affixes(Meta.daily_date_key())
		var daily_curses: Array = affixes.get("curses", [])
		_apply_affix_ids(daily_curses, StringName(String(affixes.get("bless", ""))))
	if _backdrop != null:
		_backdrop.modulate = map_def.get("tint", Color.WHITE)   # 分图云层主题色
		# E8 地狱氛围（self-evolution）：难度染色——普通原色 / 困难暖橙压 / 地狱红移
		#（选关面板文案之外的「画面一眼可辨」通道；g 通道压暗 + r 抬升近似红移）
		if _difficulty == GameConst.Difficulty.HARD:
			_backdrop.modulate = _backdrop.modulate * Color(1.06, 0.94, 0.88)
		elif _difficulty == GameConst.Difficulty.HELL:
			_backdrop.modulate = _backdrop.modulate * Color(1.16, 0.82, 0.78)
	hud.set_map_name(("每日挑战 · " if p_daily_seed >= 0 else "")
		+ String(map_def.get("name", ""))
		+ ("" if _difficulty == GameConst.Difficulty.NORMAL
			else " · %s" % GameConst.difficulty_name(_difficulty)))
	hud.endless_depth_base = 0                  # R62：波次徽标回常规口径
	wave_director.start_wave(1)
	# R262e ②：出发链总耗时入事件环——vc71 真机 P 行物步µs41612（出发帧 41.6ms 物理
	# 残差，桌面同链仅 ~2.7ms）的构成定罪口：桌面测不全项（bgm 换流/首波生成/纹理
	# 上传）分离靠下版真机日志「start_run 链 Xms」vs 残差差值
	DebugStats.event("start_run 链 %.1fms（map=%s 难度=%d）" % [
		float(Time.get_ticks_usec() - _start_run_t0) / 1000.0,
		String(current_map_id), _difficulty])
	return true


func _on_menu_start_daily() -> void:
	# 每日挑战启动（大厅「每日挑战」入口；锁定主表 + 当日种子 + 当日三词缀，P2）
	if state != GameConst.GameStatus.MENU:
		return
	if _blessing_pending:
		# R254 评审#4：祝福模态期每日出发=吞掉+面板强制可见（模态期恰是 MENU 态，
		# 旧态守卫拦不住——模态 STOP 挡穿透后此路仅剩测试直调可达，防御双 start_run）
		blessing_pick_ui.open(_blessing_pool(),
			Meta.blessing_trait(), _difficulty,
			_starting_weapon_id(Meta.character_id))   # R263：附赠标记首发上下文同源注入
		if menu_screen != null:
			menu_screen.set_blessing_modal(true)   # R260 评审 LOW-4：自愈重开=模态位同步（pending⇒模态真不变式的显式重申）
		return
	_difficulty = GameConst.Difficulty.NORMAL   # R253（二dc L1 缓办清账·R72 归属）：每日挑战固定普通——原不设档继承上一局残留（上局地狱→每日按地狱跑且结算分档污染）
	current_map_id = MapTable.FIRST_MAP_ID
	start_run(Meta.daily_seed(Meta.daily_date_key()))
	if not _run_intro_lines.is_empty():       # R186：每日局开场横幅消费（无大关段）
		EventBus.emit_mechanics_intro("\n".join(_run_intro_lines))
		_run_intro_lines.clear()


func _apply_map_affixes(p_map_def: Dictionary) -> void:
	# 地图词缀二期（双词缀祝/诅咒，P1 2026-08-31；数值真源 = map_table.gd MAPS 注释块）：
	# 诅咒（利敌）→ spawner.map_mods（spawner._apply_map_mods 出生差分应用）；
	# 祝福（利好玩家）→ player.map_* 字段——金币（本类掉账）/ 经验（Player.gain_xp）/
	# 射速（WeaponBase._fire_interval rof 乘区）/ 每波回血（本类 _on_wave_cleared_bless_heal）。
	# 旧 mod_id 单向词缀键保留兼容（断言锁定），应用口径由本表替代。
	_reset_affixes()
	_apply_affix_ids([p_map_def.get("curse_id", "")],
		StringName(String(p_map_def.get("bless_id", ""))))


func _reset_affixes() -> void:
	# 词缀态复位（地图词缀 / 每日三词缀共用起点——P2 每日覆盖前先归零）
	spawner.map_mods = {}
	player.map_xp_mult = 1.0
	player.map_gold_mult = 1.0
	player.map_rof_mult = 1.0
	player.map_wave_heal_pct = 0.0


func _apply_affix_ids(p_curses: Array, p_bless: StringName) -> void:
	# 词缀 id → 数值注入核心（地图词缀与每日挑战共用本表；逐条应用、同键后者覆盖——
	# 5 诅咒键集互斥（mob_hp_mult/ice_resist/spd_mult/contact_mult/hp_mult），不冲突）
	for curse: Variant in p_curses:
		match String(curse):
			&"curse_swarm":
				spawner.map_mods["mob_hp_mult"] = 1.08    # 虫群：小怪 HP +8%（Boss 免除）
			&"curse_frost_armor":
				spawner.map_mods["ice_resist"] = 0.2      # 霜甲：敌冰抗 +20%
			&"curse_swift_demon":
				spawner.map_mods["spd_mult"] = 1.10       # 疾魔：敌移速 +10%
			&"curse_toxic_skin":
				spawner.map_mods["contact_mult"] = 1.08   # 毒肤：敌接触伤 +8%
			&"curse_mire":
				spawner.map_mods["hp_mult"] = 1.10        # 泥沼：敌 HP +10%
	match String(p_bless):
		&"bless_harvest":
			player.map_gold_mult = 1.10                 # 丰饶：金币 +10%
		&"bless_frost_crystal":
			player.map_xp_mult = 1.10                   # 寒晶：经验 +10%
		&"bless_fervor":
			player.map_rof_mult = 1.06                  # 狂热：射速 +6%
			player.refresh_weapon_intervals()           # R29：祝福到手即缩武器当前倒计时
		&"bless_nurture":
			player.map_wave_heal_pct = 0.02             # 滋养：每波回 2% max_hp
		&"bless_rich_vein":
			player.map_xp_mult = 1.08                   # 富矿：经验 +8% 且金币 +8%
			player.map_gold_mult = 1.08


func _on_wave_cleared_bless_heal(_p_wave: int) -> void:
	# 祝福·滋养（树海）：波次清空回复 map_wave_heal_pct × max_hp（数值真源 map_table.gd）。
	# 死亡/GAME_OVER 后 wave_cleared 不再派发（GameLoop 帧序仅 PLAYING 驱动⑥），此处为防御。
	if player == null or not is_instance_valid(player):
		return
	if player.map_wave_heal_pct <= 0.0 or player.hp <= 0.0:
		return
	player.hp = minf(player.hp + player.max_hp * player.map_wave_heal_pct, player.max_hp)


func _on_menu_start(p_map_id: StringName, p_difficulty: int = 0) -> void:
	# 选图启动（大厅出发/地图卡；未解锁拒绝——解锁判据 = 上一关已通关）。
	# R72：携带难度档（普通/困难/地狱——数值乘区 + 复活 + 双选卡口径见 GameConst）
	# R252 需求②：解锁门过后、start_run 前插入「祝福面板」一步——档位候选池非空才弹
	#（合规退化：新玩家 0 解锁词条/该档全未解锁 → 不弹面板直达战斗）；确认/不选后经
	# _finish_menu_start 继续（面板期 GameStatus 保持 MENU 模态，二次 start_map_requested
	# 由 _blessing_pending 闸吞——仅防二次启动，每日隔离靠面板层不插 + 挂载层种子守卫）。
	if _blessing_pending:
		# R254-2：模态期二次出发不再静默吞——若面板因故丢失（真机渲染异常/意外关闭
		# 等路径不发三收口信号），玩家会卡在「看不见的模态」上（出发永远无响应=用户
		# 反馈「点了出发回到主页」）。自愈：无条件 open（幂等只刷内容——兼「开着但
		# 渲染异常不可见」的引擎级兜底）；并采用本次出发上下文（丢视野窗口玩家可能
		# 改选了难度/地图），未解锁的新选被拒则维持原上下文（评审#5）。
		DebugStats.event("出发二次（模态期）map=%s 难度=%d 采用=%s"
			% [String(p_map_id), p_difficulty, str(Meta.is_map_unlocked(p_map_id, p_difficulty))])
		if Meta.is_map_unlocked(p_map_id, p_difficulty):
			_blessing_pick_map = p_map_id
			current_map_id = p_map_id   # R254 QA-D4：start_run 波表/Meta.set_run_map 真源是
			                            # current_map_id（_finish_menu_start 收口即读）——采用
			                            # 块漏写会「横幅新图/实跑旧图」错位，与首启 :1827 同步
			_difficulty = clampi(p_difficulty, 0, 2)
		blessing_pick_ui.open(_blessing_pool(),
			Meta.blessing_trait(), _difficulty,
			_starting_weapon_id(Meta.character_id))   # R263：附赠标记首发上下文同源注入
		if menu_screen != null:
			menu_screen.set_blessing_modal(true)   # R260 评审 LOW-4：自愈重开=模态位同步（pending⇒模态真不变式的显式重申）
		return
	if not Meta.is_map_unlocked(p_map_id, p_difficulty):   # 二cs：解锁链分档（同难度一关关过）
		# R257：拒绝可见化（修前静默 push_warning+return=真机「点出发没反应」形态）+
		# 事件入环（diag 导出定罪口）
		var prev_name := String(MapTable.get_map(MapTable.MAPS[maxi(MapTable.get_map_index(p_map_id) - 1, 0)].id).get("name", ""))
		DebugStats.event("出发拒绝：map=%s 难度=%d 未解锁（需先通关 %s·%s）"
			% [String(p_map_id), p_difficulty, prev_name, GameConst.difficulty_name(clampi(p_difficulty, 0, 2))])
		if menu_screen != null:
			menu_screen.flash_hint("尚未解锁：需先通关【%s · %s】" % [prev_name,
				GameConst.difficulty_name(clampi(p_difficulty, 0, 2))])
		push_warning("[GameLoop] 地图未解锁（%s）——拒绝启动" % String(p_map_id))
		return
	current_map_id = p_map_id
	_difficulty = clampi(p_difficulty, 0, 2)
	if _try_open_blessing_pick():
		return                                   # 面板已弹：缓存出发上下文，确认/不选后收口
	_finish_menu_start(p_map_id)


func _finish_menu_start(p_map_id: StringName) -> void:
	# R252 需求②：_on_menu_start 后半段收口（祝福面板确认/不选与直通路径共用）
	DebugStats.event("start_run map=%s 难度=%d" % [String(p_map_id), _difficulty])
	start_run()
	# 大关新机制横幅（2026-09-13 解锁节奏表：每张大关一个新体验主题，开局宣告。
	# 第 1 关为起点口径不上横幅；continue_run 不重复宣告——选关面板行已常驻展示）
	# R186：改收口追加，与难度/随机武装段合并为至多一条开场 toast 后统一消费
	var m_idx := MapTable.get_map_index(p_map_id)
	var intro := MechanicGate.intro_for_map(m_idx, _difficulty)   # 二dc H1：开局横幅同过滤（防「新武器」假话）
	if m_idx >= 1 and not intro.is_empty():
		_run_intro_lines.append("【%s】新解锁：%s"
			% [String(MapTable.get_map(p_map_id).get("name", "")), intro])
	if not _run_intro_lines.is_empty():
		EventBus.emit_mechanics_intro("\n".join(_run_intro_lines))
		_run_intro_lines.clear()              # 消费即清（防下一局残留误播）


# ── R252 需求②：祝福（开局自选词条）· R262 全档开放 ────────────────
func _blessing_pool(p_tier: int = -1) -> Array[StringName]:
	# 祝福候选池（数据驱动过滤，零 id 硬编码、零 rng——按 id 序返回）。
	# R262：池扩全档——p_tier >= 0 保留分档探针（测试/诊断口）；生产三调用点
	#（:1755 每日 pending 自愈、:1849 模态自愈、_try_open_blessing_pick）传全池，
	# 品级筛选交 UI 侧「品级签」（默认签=当前难度档，可跨档切签）。遍历
	# registry.traits 同时满足五条（R262 图鉴解锁全池 + 首发适配门）：
	# ① p_tier >= 0 时 rarity == p_tier（GameConst.blessing_rarity_tier——按 .tres
	#   声明档直接分池，零 roll 零缩放）；② 非阈值型（threshold_only——
	#   card_generator 卡架同滤先例 THRESHOLD_ONLY_KEY）；③ 无前置组合
	#   （requires_trait 空——需局内上下文的组合词条不进开局池）；④ 图鉴已解锁
	#   （Meta.is_trait_unlocked——「开局可选 buff 必须是图鉴解锁过的」，解锁口径
	#   = 局内抽到该词条卡）；⑤ 首发适配门三态（R263）——适配上池为普通项；不适配但
	#   MechanicGate.blessing_gift_weapon 送得出（武器绑定词条）上池为「附赠武器」项
	#   （_blessing_fits_start_weapon 六键静态判定复刻 card_generator.mount_gate_allows：
	#   required_weapon/required_forms/required_class/excluded_weapons/requires_projectile/
	#   requires_weapon_keys）；纯形态失配送不出则出局（现状）。
	var out: Array[StringName] = []
	if registry == null:
		return out
	# R262：循环外求首发口径（_starting_weapon_id 既有仲裁：非 fission 恒手枪、
	# fission 自定义过难度门——禁裸读 Meta.custom_weapon，难度门回落已内聚）。
	var start_wid := _starting_weapon_id(Meta.character_id)
	var start_wd: WeaponData = registry.get_weapon(start_wid)
	var start_form := int(start_wd.form) if start_wd != null else -1
	var start_class := "melee"
	if start_wd != null and start_wd.melee is Dictionary:
		start_class = String((start_wd.melee as Dictionary).get("weapon_class", "melee"))
	# 排序载体用 Array[String]：Godot 4.3 的 Array.sort() 对 STRING_NAME↔STRING_NAME
	# 比较无 variant case（逐对 false → 排序静默无效），STRING↔STRING 才有字典序实现
	#（B1 池序断言实证）。过滤保持数据驱动条件，序恒 id 字典序（零 rng）。
	var keys: Array[String] = []
	for tid_v: Variant in registry.traits.keys():
		keys.append(String(tid_v))
	keys.sort()
	for key: String in keys:
		var tid := StringName(key)
		var td := registry.get_trait(tid)
		if td == null or (p_tier >= 0 and int(td.rarity) != p_tier):
			continue
		if bool(td.params.get("threshold_only", false)):
			continue                          # 阈值型（TH_*）不上开局祝福
		if String(td.params.get("requires_trait", "")) != "":
			continue                          # 前置组合词条需局内上下文
		if not Meta.is_trait_unlocked(tid):
			continue                          # 图鉴解锁门
		if not _blessing_fits_start_weapon(td, start_wd, start_form, start_class):
			# R263 第五滤三态化：不适配但送得出（required_weapon/required_class 武器绑定
			# 词条——MechanicGate.blessing_gift_weapon 单源）→ 上池走「附赠武器」通道
			#（难度门/大关门对送通道开例·设计 §2.4）；纯形态类（AFF_RANGE/AFF_CDR 等
			# 无绑定键）→ 送不出，维持出局不上池（现状不变）。
			if MechanicGate.blessing_gift_weapon(td, registry.weapons) == StringName(""):
				continue
		out.append(tid)
	return out


func _blessing_fits_start_weapon(p_td: TraitData, p_wd: WeaponData, p_form: int, p_class: String) -> bool:
	# R262 首发适配门（static 判定照 card_generator.mount_gate_allows 数据键口径复刻
	# ——面板期无 WeaponBase 实例不可直调其门，六键全查为完整闭环：required_weapon
	#（R65 数组/单值双口径）、required_forms、required_class（R243 form==MELEE 族
	# + weapon_class∈所列）、excluded_weapons（R199 D04）、requires_projectile
	#（R199 D03）、requires_weapon_keys（R199 D01/D02：WeaponData 顶层属性键+四形态
	# 段 Dictionary 键直读版——同源 _weapon_data_has_key）。全键缺省早退 true；
	# p_wd == null 从严 false（首发数据不可证实 → 词条不上池）；requires_trait /
	# exclusive_group 动态门开局空栈恒过不查（池滤条件 ③ 已前置组合词条）。
	if p_td == null or p_wd == null:
		return false
	var forms: Variant = p_td.params.get("required_forms", null)
	var weapon_req: Variant = p_td.params.get("required_weapon", null)
	var wkeys: Variant = p_td.params.get("requires_weapon_keys", null)
	var need_proj: bool = bool(p_td.params.get("requires_projectile", false))
	var excluded: Variant = p_td.params.get("excluded_weapons", null)
	var class_req: Variant = p_td.params.get("required_class", null)
	if forms == null and weapon_req == null and wkeys == null and not need_proj \
			and excluded == null and class_req == null:
		return true
	var wid := StringName(String(p_wd.id))
	if weapon_req != null:
		if weapon_req is Array:
			var allowed := false
			for wv in (weapon_req as Array):
				if wid == StringName(String(wv)):
					allowed = true
					break
			if not allowed:
				return false
		elif wid != StringName(String(weapon_req)):
			return false
	if wkeys != null:
		# R199 D01/D02 能力键直读版（顶层属性键或四形态段 Dictionary 键任一实有）
		var key_list: Array = (wkeys as Array) if wkeys is Array else [wkeys]
		for kv in key_list:
			var kname := String(kv)
			var found := p_wd.get(kname) != null
			if not found:
				for section in [p_wd.ballistic, p_wd.laser, p_wd.homing, p_wd.melee]:
					if section is Dictionary and section.has(kname):
						found = true
						break
			if not found:
				return false
	if need_proj and p_form != GameConst.WeaponForm.BALLISTIC \
			and p_form != GameConst.WeaponForm.HOMING:
		return false
	if excluded != null:
		if excluded is Array:
			for wv in (excluded as Array):
				if wid == StringName(String(wv)):
					return false
		elif wid == StringName(String(excluded)):
			return false
	if forms is Array and not (forms as Array).is_empty() and not (forms as Array).has(p_form):
		return false
	if class_req != null:
		# R243 类别门：目标必须 form 3（MELEE 族）且 weapon_class ∈ 所列类别数组
		if p_form != GameConst.WeaponForm.MELEE:
			return false
		var class_ok := false
		if class_req is Array:
			for cv in (class_req as Array):
				if String(cv) == p_class:
					class_ok = true
					break
		else:
			class_ok = String(class_req) == p_class
		if not class_ok:
			return false
	return true


func _try_open_blessing_pick() -> bool:
	# 面板层入口（_on_menu_start 专用）：全池空 → false（不弹面板直达战斗——
	# 合规退化）；非空 → 缓存出发上下文 + 弹面板，返 true（_finish_menu_start 挂起待确认）。
	# R262：池改全池（品级筛选交面板品级签，默认签=当前难度档）。
	var pool := _blessing_pool()
	if pool.is_empty():
		DebugStats.event("祝福池空（图鉴解锁词条均不适配当前首发或未解锁）——直达战斗 map=%s" % [
			String(current_map_id)])
		return false
	_blessing_pick_map = current_map_id
	_blessing_pending = true
	DebugStats.event("祝福面板弹：池 %d 项 · 默认档 %d · map=%s"
		% [pool.size(), GameConst.blessing_rarity_tier(_difficulty), String(current_map_id)])
	# R263：附赠标记判定的首发上下文随池注入（UI 单源判定「该行走挂载还是送武」——
	# 与 _blessing_pool 同一 _starting_weapon_id 仲裁）。
	blessing_pick_ui.open(pool, Meta.blessing_trait(), _difficulty,
		_starting_weapon_id(Meta.character_id))
	if menu_screen != null:
		menu_screen.set_blessing_modal(true)   # R260：弹层模态期 menu 双泵挂起（动画帧预算让给前景）
	return true


func _on_blessing_confirmed(p_trait_id: String) -> void:
	# 「出发」：选中项写记忆键（写口守卫图鉴解锁；R262 全档合法——池全档开放，
	# 跨档记忆进局直接生效）后继续启动。
	# 空串（未选直出发）同「不选祝福」语义——不覆盖记忆键。
	DebugStats.event("祝福确认：%s" % (p_trait_id if not p_trait_id.is_empty() else "（未选直出发）"))
	if not p_trait_id.is_empty():
		Meta.set_blessing_trait(StringName(p_trait_id))
	_blessing_pending = false
	if menu_screen != null:
		menu_screen.set_blessing_modal(false)  # R260：泵恢复（条件合并——大厅面板开着时仍挂起）
	_finish_menu_start(_blessing_pick_map)


func _on_blessing_dismissed() -> void:
	# 「不选祝福」/防御收口：本局无祝福且不覆盖记忆键（下次仍默认带上——设计 §2.4-4）
	DebugStats.event("祝福收口：dismiss（不选）")
	_blessing_pending = false
	if menu_screen != null:
		menu_screen.set_blessing_modal(false)  # R260
	_finish_menu_start(_blessing_pick_map)


func _on_blessing_cleared() -> void:
	# R252-QA第1轮 B3：「清除记忆」收口——永久退出祝福携带（写口 clear_blessing_trait
	# 清键+落盘），下次出发面板仍弹但预选为空。
	DebugStats.event("祝福收口：清除记忆")
	Meta.clear_blessing_trait()
	_blessing_pending = false
	if menu_screen != null:
		menu_screen.set_blessing_modal(false)  # R260
	_finish_menu_start(_blessing_pick_map)


func _on_blessing_unlock_note(p_trait_id: StringName) -> void:
	# R252-QA第1轮 B2：词条首获 → 新开局祝福解锁的局内 toast（mechanics_intro 通道，
	# hud.gd:1106 金卡解锁播报同款先例——非阻塞、复用波次 toast 位加长展示）。
	# Meta 只广播 id（不持 registry），词条名在此组装；悬空 id 降级显示 id 字面。
	var td: TraitData = null
	if registry != null:
		td = registry.get_trait(p_trait_id)
	var tname := String(td.display_name) if td != null else String(p_trait_id)
	EventBus.emit_mechanics_intro("新祝福已解锁：%s——下次出发可选" % tname)


func _apply_start_blessing(p_allow_charge: bool = true) -> void:
	# 开局祝福挂载 + R263 收费/送武（start_run 常规段传 true / restart_run 重挂传 false；
	# 零 rng——确定性首匹配 + Array 拍序解析，不消费卡架/出生 RNG 流）。
	# 每日隔离·挂载层守卫：每日种子 ≥0（start_run 留存、restart_run 不清）→ 一律不挂
	# 不送不扣。「每日 = 固定种子全服同配置」裁定第二道防线——面板层（_on_menu_start_daily
	# 直调 start_run 不插面板）之外的程序化路径（直调 start_run(daily_seed)/R188 自动重开）全覆盖。
	if _active_daily_seed >= 0:
		return
	var bid := Meta.blessing_trait()
	if bid.is_empty():
		return                                  # 无记忆（含「不选祝福」未覆盖口径）→ 零挂载
	var td := registry.get_trait(StringName(bid))
	if td == null:
		return                                  # 记忆 id 悬空（词条被删）→ 视作空记忆，不挂不预选
	# R263 已购位闸：新局首购 = start_run（p_allow_charge=true）且本局未买成；已购局
	#（_run_blessing_paid）重开重挂不重复扣费；未购局（含首局余额不足被拒）重开不白捡
	#——堵「首局买不起→死亡结算补星尘→重开免费挂载」套利（S4；重开重播短横幅提示，
	# R263 修轮起评审-5 口径——首局已披露具体拒因，重开只提醒不重复展开）。
	var first_buy := p_allow_charge and not _run_blessing_paid
	if not first_buy and not _run_blessing_paid:
		# R263 修轮（评审-5）：未购局重开不再纯静默——重播一句简短横幅（首局已披露
		# 具体拒因：星尘不足/槽满/不适配；此处仅提醒「记忆在但未购不随重开生效」，
		# 防玩家重开后疑惑祝福去向）。不挂载不扣费语义不变（S4 套利防线不动）。
		_run_intro_lines.append("【祝福】%s（未携带·未购不随重开生效）" % td.display_name)
		return
	# R262：跨难度挂载门拆除——R252 §2.1-8「跨难度回落=不挂载不预选」定案随池全档
	# 开放作废（拆锁档后跨档记忆合法生效，挂载只看武器适配；原「与本难度档位不符」
	# 横幅句退役）。
	# 挂载宿主：按槽序 0→6 首个 mount_gate_allows 通过的武器（同 card_generator
	# _pick_attach_target 过滤语义；确定性首匹配替代其 rng 抽样——零 rng 消费，
	# pkg4 seed=42 选卡流不位移）。R263 fits 优先于送：fission 首发恰=绑定武器
	#（如首发 W8 选环绕词条）→ 直接挂 slot0，不送只挂，照常扣费。
	var target: WeaponBase = null
	for i in range(player.weapon_slots.size()):
		var w: WeaponBase = player.weapon_slots[i] if i < player.weapon_slots.size() else null
		if w is WeaponBase and is_instance_valid(w) and CardGenerator.mount_gate_allows(td, w):
			target = w
			break
	if target != null:
		# 适配既有武器路径——R263 收费与送武同一实现序（设计 §3.3 唯一定案）：
		# ① 余额检查前置（不足即拒、不挂不扣）→ ② attach 成功 → ③ 扣费+写即落盘 →
		# ④ 横幅。全序同步执行同一调用栈（无 await 间隙），失败一律扣费前早退（无退款路径）。
		if first_buy:
			var fit_cost := Meta.blessing_cost(int(td.rarity))
			if Meta.stardust < fit_cost:
				_run_intro_lines.append("【祝福】星尘不足，「%s」本局未携带（现有 %d/%d）"
					% [td.display_name, Meta.stardust, fit_cost])
				return
			if not target.attach_trait(td):
				return                          # 挂载失败早退（扣费前——无「先扣后退」）
			Meta.charge_stardust(fit_cost)      # 余额已查同帧同栈——必成功+写即落盘
			_run_blessing_paid = true
			_run_intro_lines.append("【祝福】%s（开局生效·-%d 星尘）" % [td.display_name, fit_cost])
			return
		if not target.attach_trait(td):         # 已购重挂：不重复扣费（横幅复现无价签）
			return
		_run_intro_lines.append("【祝福】%s（开局生效）" % td.display_name)
		return
	# 全槽失配 → R263 送武分支：武器绑定词条（required_weapon/required_class）附赠对应
	# 武器+挂词条（难度门/大关门对送通道开例——设计 §2.4；局内 weapon_allowed 零改动）。
	var gift_wid := MechanicGate.blessing_gift_weapon(td, registry.weapons)
	if gift_wid == StringName(""):
		# 送不出（纯 required_forms 形态类等——池三态第三态哨兵）→ 维持 R262 拒挂横幅。
		_run_intro_lines.append("上次祝福「%s」与当前首发武器不适配，本局未生效（可在出发前重选）"
			% td.display_name)
		return
	if not first_buy:
		# 已购重挂：重送+重挂不重复扣费（mark_weapon_codex 幂等；G6 余额不变断言锚）。
		var remount := player.add_weapon(registry.get_weapon(gift_wid))
		if remount == null:
			_run_intro_lines.append("【祝福】武器槽已满，「%s」本局未生效" % td.display_name)
			return
		Meta.mark_weapon_codex(gift_wid)
		if not remount.attach_trait(td):
			return
		_run_intro_lines.append("【祝福】%s（开局生效·附赠 %s）"
			% [td.display_name, remount.data.display_name])
		return
	var gift_cost := Meta.blessing_cost(int(td.rarity))
	if Meta.stardust < gift_cost:
		_run_intro_lines.append("【祝福】星尘不足，「%s」本局未携带（现有 %d/%d）"
			% [td.display_name, Meta.stardust, gift_cost])
		return
	var gift := player.add_weapon(registry.get_weapon(gift_wid))   # :969 首个可用槽（slot0 被
	                                              # 首发占 → 非echo恒落 slot1；开局解锁槽恒≥2 无解锁时序冲突）
	if gift == null:
		# 无空槽（echo×普通双武装占满 2 槽等）→ 不送不挂不扣（扣费前早退）+ 横幅披露。
		_run_intro_lines.append("【祝福】武器槽已满，「%s」本局未生效" % td.display_name)
		return
	Meta.mark_weapon_codex(gift_wid)           # 送出武器计图鉴（白拿口径先例 :827：幂等不增
	                                              # _run_weapons_drawn，军火大亨成就不受扰）
	if not gift.attach_trait(td):
		return                                  # 双成功前早退——扣费只发生在单一成功点之后
	Meta.charge_stardust(gift_cost)             # add_weapon+attach 双成功 → 扣费+写即落盘
	_run_blessing_paid = true
	_run_intro_lines.append("【祝福】%s（开局生效·附赠 %s·-%d 星尘）"
		% [td.display_name, gift.data.display_name, gift_cost])   # 落 R250/R72/fission 横幅之后（同队列至多一条 toast）


func restart_run() -> bool:
	# GAME_OVER → PLAYING（结算重开）/ PAUSED → PLAYING（暂停面板「重新开始」，
	# 用户反馈 2026-08-29；PAUSED→PLAYING 为既有合法迁移）：数值重置 + 波次 1 重开。
	# 重开 = 放弃旧档（局内存档清除——「重新开始」语义下继续入口不再指向被放弃的进度）
	if state != GameConst.GameStatus.GAME_OVER and state != GameConst.GameStatus.PAUSED:
		return false
	# R62：通关屏延迟结算兑现（玩家选「再来一局」放弃无尽继续——本局在此落账）
	if _victory_settle_pending:
		Meta.settle_now()
		_victory_settle_pending = false
	if not change_state(GameConst.GameStatus.PLAYING):
		return false
	PerfGovernor.notify_new_run()             # R222 Fix G：重开=新局（暂停面板重开/结算重开
	                                          # 都在此口——评审 high：观测闩漏臂路径）
	PopupGlyphAtlas.ensure_runstart_bake()    # R227：位图激活兜底（同 start_run 口）
	RunSave.clear()
	# R198（R192-low4）：重开同为进局路径——规划原注「restart_run 经 start_run 天然覆盖」
	# 与实码不符（本函数不经 start_run：change_state + _reset_run_state + start_wave 直达），
	# 故显式复位告警双闸（start_run/continue_run 同口径）。
	if pipeline != null and pipeline.has_method(&"reset_run_alarms"):
		pipeline.call(&"reset_run_alarms")
	_reset_run_state()
	# R199-P01（R72 难度附赠复活）：_reset_run_state → player.respawn → set_character 已把
	# revives_left 复位为养成值——重开须按当前难度补授附赠复活（与 start_run :837 /
	# continue_run :1780 同口径），否则困难/地狱「再来一局」后复活次数缩水（附赠清零）
	player.revives_left += GameConst.difficulty_revives(_difficulty)
	_apply_start_blessing(false)              # R263：重开重挂走已购位（paid=true 才重送重挂，
	                                          # 不重复扣费；每日局 _active_daily_seed 留存 → 挂载
	                                          # 层守卫自拒——R188 自动重开同覆盖）
	if not _run_intro_lines.is_empty():       # R186：重开消费开场横幅（普通角色数组空不 emit——现版零回归）
		EventBus.emit_mechanics_intro("\n".join(_run_intro_lines))
		_run_intro_lines.clear()
	_reorder_tex_prewarm_wave_first()         # R267 刀P1：重开同图波表在册——队列波序重排
	wave_director.start_wave(1)
	return true


func quit_to_menu() -> bool:
	# PAUSED → MENU（暂停面板「回主菜单」；新增合法迁移）：回菜单前静默清场 +
	# 数值复位（等同 restart 口径——防残留敌/弹在下次 start_run 时叠进波次 1）。
	# 局内存档（2026-08-31 用户反馈「回到菜单再进入可选择继续上次进度」）：仅 PAUSED
	# 主动退出落盘（GAME_OVER → MENU 的同路径退出不存——死亡局已由 _on_player_died
	# 清档，此处再存会把 hp≤0 的尸体局写进「继续」入口）
	var was_paused := state == GameConst.GameStatus.PAUSED
	# R62：通关屏延迟结算兑现（玩家选「回主菜单」放弃无尽继续——本局在此落账）
	if _victory_settle_pending:
		Meta.settle_now()
		_victory_settle_pending = false
	if not change_state(GameConst.GameStatus.MENU):
		return false
	# R245 §1.6 顺带小修：回主菜单补强制结清一行——修「暂停回主菜单丢本局敌人图鉴/
	# total_kills 增量」的两套落盘口径问题（change_state 内仅溢出批消化中〔draining〕
	# 才 cancel；此处无条件兜底批作用域残余抑制态——depth==0 时 Meta 侧守卫空转零成本）
	Meta.cancel_persist_defer()
	if was_paused:
		RunSave.save_run(serialize_run())
	_reset_run_state()
	_run_intro_lines.clear()                  # R186 ★R2⑥：回菜单路径无 emit 点——清残留防误播
	return true


func set_time_scale(p_value: float, p_source: StringName) -> void:
	# ★ time_scale 唯一写入口（§1.3-7：audit 调用者；绝不写 Engine.time_scale，§8.7）
	time_scale = clampf(p_value, 0.0, 1.0)
	time_scale_source = p_source


func _game_delta(p_raw_delta: float) -> float:
	# raw × time_scale（子系统唯一时间源；顿帧 ≈0 → 全部游戏计时自然冻结，E-11）
	# R194 契约变更（P2-10 时序鲁棒）：结果 clamp ≤0.25s——巨 delta（断点/卡顿/后台恢复
	# 后单帧补账数秒）原口径一次吞掉整段波窗口 → 硬上限直接连环叠波；钳后逐帧消化，
	# 至多叠 1 波。1/120 正常路径（≈0.0083s）与 time_scale 缩放输出零变化（钳只在
	# >0.25s 时触发，计时语义其余不动）。
	var gd := p_raw_delta * time_scale
	if gd <= GAME_DELTA_CLAMP_S:
		return gd
	DebugStats.count(&"game_delta_clamped")
	return GAME_DELTA_CLAMP_S


func _on_player_died() -> void:
	# 死亡仲裁（E-16：优先级最高；任何状态 → GAME_OVER）
	if state == GameConst.GameStatus.GAME_OVER or state == GameConst.GameStatus.BOOT \
			or state == GameConst.GameStatus.MENU:
		return                                    # 未开局/已结算：忽略
	RunSave.clear()                             # 局终清档（继续入口随死亡失效）
	change_state(GameConst.GameStatus.GAME_OVER)


const MAGNET_ABSORB_PER_FRAME := 24           # R214：同帧吸收帽——选卡窗/波末回收 160 片
                                              # 风暴的单帧 gain_xp 链尖峰根治（vc21 磁键 156ms）；
                                              # 160 片 ~7 帧摊开（0.12s@60Hz）收割演出观感无损
                                              # 口径（评审 R215）：②常规帽与⑦磁吸帽是两个独立
                                              # 24/帧帽——最坏合计 48 片/帧；②帽只冻结圈内非磁片
                                              # 契约变更（R225 刀a）：满载门内并单帽——②⑦共享
                                              # 一顶 24/帧 总预算（_fullload_absorb_left），磁吸
                                              # 优先（② 段按磁吸圈内置片数预留，只花盈余）；
                                              # 最坏吸收 48→24 片/帧（满载吸收链成本减半，为
                                              # 「满载 dc 减半」让路）。非满载维持双帽 48 最坏
                                              # 原口径，零扰动。
const MAGNET_ABSORB_PER_FRAME_30HZ := 48      # R233 T3 决策6-R2：30Hz 档（≈1440/s 与 60Hz 口径
                                              # 对齐——24 片/步@30Hz=720/s 会把 160 片回收从
                                              # 0.12s 摊开变 0.23s；48/步 3-4 步摊开，vc21 磁键
                                              # 尖峰口径不回退）。原 const 值不动（r225 套件
                                              # 字面量 24 断言同款保护）；消费点全部走
                                              # magnet_absorb_cap_now() 单源选择器（与帽表/
                                              # 派发同谓词联动，禁脱钩——决策6 防半回退态）。


static func magnet_absorb_cap_now() -> int:
	# R233 T3：吸收帽选表（② _tick_xp_shards / ⑦ _tick_magnetized_shards / 满载开帽
	# _fullload_absorb_frame_open 三处同源）——sim30_effective 单源谓词选档。
	return MAGNET_ABSORB_PER_FRAME_30HZ if sim30_effective() else MAGNET_ABSORB_PER_FRAME

const BOSS_PREWARM_IDLE_S := 3.0              # R215 修：boss 双面预热挂机门（MENU 停留秒阈值）
const DescPrewarm := preload("res://scripts/cards/card_desc_prewarm.gd")   # R222 Fix P：折臂纯函数复用


func _fullload_absorb_frame_open() -> void:
	# R225 刀a：满载吸收单帽每帧序开帽一次（帧序②入口 PLAYING 分支 / ⑦入口
	# LEVEL_UP/PAUSED 分支各调一处——⑦ 的所有调用点同帧必先经其一）。门关帧照开
	# （预算休眠：②⑦ 各用本地双帽，预算不被读/扣）。
	_fullload_absorb_left = magnet_absorb_cap_now()
	_fullload_absorb_open = true


func _tick_magnetized_shards(p_raw: float) -> void:
	# 选卡/暂停期仅推进「已磁吸」碎片（未磁吸的自然静止在原地——不打架）
	# R214：吸收分帧帽——已到吸收圈但本帧帽满的碎片冻结一帧（下帧再入账）
	# R225 刀a：满载门内改吃共享单帽剩余预算（同帧②段先跑、其未运行的帧序由帧序
	# 开帽兜底 fresh 24）——②+⑦ 合计 ≤24 片/帧；非满载本地 24 帽原样。
	var shared := Enemy.fullload_dim()
	var absorbed := 0
	var cap := magnet_absorb_cap_now()
	if shared:
		if not _fullload_absorb_open:          # 兜底开帽（门中途翻转/未经理序入口的调用）
			_fullload_absorb_frame_open()
		cap = _fullload_absorb_left
	var idx := active_shards.size() - 1
	while idx >= 0:
		var shard := active_shards[idx]
		if is_instance_valid(shard) and shard.is_magnet():
			if shard.ready_to_absorb() and absorbed >= cap:
				idx -= 1                       # 帽满冻结（吸收圈内原地等下帧）
				continue
			if shard.tick(p_raw):
				active_shards.remove_at(idx)
				(pools[&"xp"] as XPPool).release(shard)
				absorbed += 1
				if shared:
					_fullload_absorb_left -= 1   # R225 刀a：扣共享预算（⑦ 份额）
		idx -= 1


func _on_level_up(p_new_level: int) -> void:
	# 升级仲裁（E-16）：GameOver 丢弃 + 计数；PLAYING 进选卡流；LEVEL_UP 中 → 排队（A3
	# §6.2）。R188-perf 档3 连升合并：排队帽 ≤3（深局巨额经验 4.8 万次连升的结构性失控
	# 修复），溢出批不排队——_on_card_choice 收口时同分布自动抽卡（merged_overflow）
	match state:
		GameConst.GameStatus.GAME_OVER:
			dropped_level_ups += 1
		GameConst.GameStatus.PLAYING:
			_request_card_flow_deferred(p_new_level)
		GameConst.GameStatus.LEVEL_UP:
			if pending_level_ups < PENDING_LEVEL_UP_CAP:
				pending_level_ups += 1
			else:
				merged_overflow_level_ups += 1
		_:
			pass                                  # 其余状态（MENU 等）：升级请求不应存在，忽略


func _on_level_up_batch(p_levels: int) -> void:
	# R189 连升批仲裁：与逐级 _on_level_up 逐位同口径——首级开卡流（PLAYING）/
	# 其余入排队帽 ≤3 / 帽满入溢出批；GAME_OVER 丢弃计数。单信号入账省去
	# 巨批逐级 emit 的每级信号税（gain_xp(1e12) 爆发帧 387ms 的结构性主头）。
	match state:
		GameConst.GameStatus.GAME_OVER:
			dropped_level_ups += p_levels
		GameConst.GameStatus.PLAYING:
			if _deferred_level_open < 0:
				_deferred_level_open = player.level - maxi(p_levels - 1, 0)   # 首级新档位（与逐级首 emit 同参）
				var rest0 := maxi(p_levels - 1, 0)
				var queued0 := mini(rest0, PENDING_LEVEL_UP_CAP)
				pending_level_ups += queued0
				merged_overflow_level_ups += rest0 - queued0
			else:
				var room0 := maxi(PENDING_LEVEL_UP_CAP - pending_level_ups, 0)
				var queued0b := mini(p_levels, room0)
				pending_level_ups += queued0b
				merged_overflow_level_ups += p_levels - queued0b
		GameConst.GameStatus.LEVEL_UP:
			var room := maxi(PENDING_LEVEL_UP_CAP - pending_level_ups, 0)
			var queued := mini(p_levels, room)
			pending_level_ups += queued
			merged_overflow_level_ups += p_levels - queued
		_:
			pass


func _request_card_flow_deferred(p_new_level: int) -> void:
	# R215 刀A：PLAYING 期升级请求只记档（首级），开窗延迟到帧尾——同步开窗会把
	# 卡流生成/LEVEL_UP 迁移/全场 force_magnet 级联全部记进调用方探针（vc22 磁键
	# 183ms 实锤）。同帧后续升级走既有排队帽/溢出批口径（与 LEVEL_UP 态逐位一致）。
	if _deferred_level_open < 0:
		_deferred_level_open = p_new_level
	elif pending_level_ups < PENDING_LEVEL_UP_CAP:
		pending_level_ups += 1
	else:
		merged_overflow_level_ups += 1


func _consume_deferred_level_open() -> void:
	# R215 刀A：延迟开窗消费点（产品路径=PLAYING 分支 ⑧ UI 段后帧尾自动调；
	# 测试路径=gain_xp 后手动驱动一次等价一帧）。开窗成本记卡键（R216 与 UI 分离归因）。
	if _deferred_level_open < 0:
		return
	var lv_open := _deferred_level_open
	_deferred_level_open = -1
	if state != GameConst.GameStatus.PLAYING:
		dropped_level_ups += 1                 # 同帧先 GAME_OVER：开窗作废（与仲裁丢弃同口径计数）
		return
	# R216 修（评审#1）：卡键计量下沉进 _open_card_flow 单一咽喉——延迟消费/排队续开
	#（_on_card_choice）/任何直开路径统一归卡键（原外层测量会漏 LEVEL_UP 态续开）
	_open_card_flow(lv_open)


func _announce_weapon_first_shelf(p_candidates: Array) -> void:
	# R251 需求③ 武器「上架即算」首遇卡（设计 §3.2：选卡窗出现即算第一次出现在玩家
	# 面前）：扫本批候选 WEAPON 项，mark_first_met("W_"+id) 首见 → 发卡。与获取路径
	# 同键（codex_first_met W_ 前缀）先到先得天然互斥——本窗烧键后玩家若选了该武器，
	# add_weapon 路径因键已烧静默，无双弹；没选则获取时也不再弹（「第一次就行」）。
	# echo 双武装装备前预吞（:1557 既有 mark_first_met）先例不受扰（预吞在前=键已烧）。
	if p_candidates.is_empty():
		return
	for c: Variant in p_candidates:
		if not (c is Dictionary):
			continue
		if int(c.get("kind", -1)) != CardGenerator.CardKind.WEAPON:
			continue
		var wid := StringName(String(c.get("id", &"")))
		# QA B-3（三口纪律对齐）：note 空串守卫先于烧键（与 enemy_spawner.gd 发卡口、
		# player.gd add_weapon 回退口同款 not note.is_empty() 前置——空 note 不烧键不发卡）
		var note := GameConst.weapon_note(String(wid))
		if wid == &"" or note.is_empty():
			continue
		if not Meta.mark_first_met(StringName("W_" + String(wid))):
			continue
		var wdata: WeaponData = registry.get_weapon(wid)
		var wname := String(wdata.display_name) if wdata != null else String(wid)
		EventBus.emit_first_encounter_card("【新武器】%s" % wname, note, &"weapon", wid)


func _open_card_flow(p_new_level: int) -> void:
	# 三选一流程：roll 3 张 → LEVEL_UP（暂停战斗）→ 选卡界面打开。
	# R216 修（评审#1）：全路径唯一计量点——本函数头尾计「卡」键（延迟消费/排队续开/
	# 任何直开统一归因；LEVEL_UP 态续开时 1Hz 均值不被采样但峰值键存活到下一采样行）
	var _card_flow_t0 := Time.get_ticks_usec() if stage_probe_enabled else 0
	# 集成包 B.2：遗物改写发牌参数（GAMBLER 四选一+诅咒 / OVERCLOCK 稀有度保底），
	# WORDS_TIDE 每波一次重随货架（保留稀有度 roll 序列）
	# R72 成对抉择（用户裁定：困难 5% 概率 / 地狱每次）：2 列 6 卡、必选同一行两张。
	# 判定留在本流程入口（换一批沿用同一模式——同一次升级内体验一致）
	_dual_pending = GameConst.difficulty_dual_pick(_difficulty, randf())
	var deal_n := 6 if _dual_pending else relic_handler.deal_count()
	# R199-N13：首 roll 消费即焚的保底值留存本类（relic_handler.take_rarity_floor 取后
	# 即清）——本流程内「换一批」复传同一保底（卡面承诺「本波下一张卡稀有度保底紫+」
	# 对玩家实际选走的卡成立，重发批次不再洗掉保底）
	_card_rarity_floor = relic_handler.take_rarity_floor()
	var context := {
		"player": player,
		"wave": wave_director.current_wave,
		"level": p_new_level,
		"deal_count": deal_n,
		"curse_last": relic_handler.curse_requested(),
		"min_rarity_floor": _card_rarity_floor,
	}
	current_candidates = card_generator.generate_candidates(context)
	_announce_weapon_first_shelf(current_candidates)
	if relic_handler.consume_reroll():
		var rarities: Array[int] = []
		for c in current_candidates:
			rarities.append(int(c.get("rarity", 0)))
		var reroll_context := context.duplicate()
		# R199-N13 口径保持：WORDS_TIDE 自动重随走 fixed_rarities 保序（保底已折入首 roll
		# 稀有度序列并被 fixed_rarities 逐位固化）——floor 置 -1 勿复施，勿回归
		reroll_context["min_rarity_floor"] = -1
		reroll_context["fixed_rarities"] = rarities
		current_candidates = card_generator.generate_candidates(reroll_context)
		_announce_weapon_first_shelf(current_candidates)
	change_state(GameConst.GameStatus.LEVEL_UP)
	card_select_ui.open(current_candidates, _dual_pending)
	card_select_ui.update_reroll(player.reroll_charges, not _free_reroll_used)
	# R188-idle：选卡展示窗挂起（0.5s 描金预告 → choose 真链；手动/自动共用同一窗口，
	# 手动先选即撤销——open 在 change_state 之后，类型化时序与既有口径一致）
	_auto_card_left = AUTO_CARD_WINDOW_S
	_auto_card_retries = 0
	_auto_card_shown_index = -1
	if stage_probe_enabled:
		# get 兜底：帧外驱动路径探针字典可能尚无 card_open 键（合法——累计语义）
		# R220 刀1：原 &"card" 同键混合拆分——开窗级联归 card_open（开），溢出批消化归
		# card_drain（消，_tick_merged_overflow 调用处计量）；LEVEL_UP 态续开时 1Hz 均值
		# 行不被采样但峰值键存活到下一采样行（既有语义保持）。
		stage_probe_us[&"card_open"] = int(stage_probe_us.get(&"card_open", 0)) + int(Time.get_ticks_usec() - _card_flow_t0)
		stage_probe_us_peak[&"card_open"] = maxi(int(stage_probe_us_peak.get(&"card_open", 0)), int(stage_probe_us[&"card_open"]))


func _on_card_reroll() -> void:
	# 换一批仲裁（选卡刷新机制，2026-08-31）：本局首次免费（一次性刷新）→ 之后每次消耗
	# 1 次刷新次数；重新发牌（诅咒等遗物改写不重复消费；R199-N13：稀有度保底随本流程
	# 留存复传——首 roll 已自 relic_handler 消费即焚，重发批次带同一保底，不再按无保底
	# 白板 roll 洗掉「超频核心」承诺）
	if state != GameConst.GameStatus.LEVEL_UP or card_select_ui == null \
			or not card_select_ui.is_open or player == null or not is_instance_valid(player):
		return
	if not _free_reroll_used:
		_free_reroll_used = true               # 免费位扣减（不消耗次数）
	elif player.reroll_charges <= 0:
		return
	else:
		player.reroll_charges -= 1
	var context := {
		"player": player,
		"wave": wave_director.current_wave,
		"level": player.level,
		"deal_count": 6 if _dual_pending else relic_handler.deal_count(),
		"curse_last": relic_handler.curse_requested(),
		"min_rarity_floor": _card_rarity_floor,   # R199-N13：传首 roll 留存保底（原写死 -1 洗掉保底）
	}
	current_candidates = card_generator.generate_candidates(context)
	_announce_weapon_first_shelf(current_candidates)
	card_select_ui.open(current_candidates, _dual_pending)
	card_select_ui.update_reroll(player.reroll_charges, not _free_reroll_used)
	# R188-idle：换一批 = 玩家手动操作 → 自动窗重置（重开 0.5s 展示窗，不吞手动节奏）
	_auto_card_left = AUTO_CARD_WINDOW_S
	_auto_card_retries = 0
	_auto_card_shown_index = -1
	if sfx != null:
		sfx.play(&"buy")


func _on_card_choice(p_cards: Array) -> void:
	# 选卡应用（CardGenerator）→ 恢复 PLAYING；连升排队继续弹（A3 §6.2）。
	# R72 成对抉择：p_cards 为同行两张（普通模式单元素数组——协议统一为数组）
	# R189：落盘/成就摊薄入位——批作用域自 apply_choice 前开启（单张 card_chosen 的
	# ConfigFile 同步写 ~30-60ms 曾把收口帧顶到 50ms 线上）；无溢出批挂起时函数尾
	# 立即结清（成就判定+落盘语义与逐张落盘一致，只是合并到选择批收口）
	# R245 红卡门：批内含 SUBLIME 卡 → 不直通 PLAYING，改弹大屏确认卡
	# （sublime_confirm_ui），confirmed 信号经 _finish_card_choice 收口（尾段提取）。
	if state != GameConst.GameStatus.LEVEL_UP:
		return
	Meta.begin_persist_defer()
	# R188-idle：手动/自动选卡落地 → 挂起窗即时撤销（自动链经 choose 亦走此处）
	_auto_card_left = -1.0
	_auto_card_shown_index = -1
	_auto_card_retries = 0
	var applied := 0
	var sublime_hit := false
	for card_v: Variant in p_cards:
		if card_v is Dictionary and not (card_v as Dictionary).is_empty():
			var card := card_v as Dictionary
			card_generator.apply_choice(card, player)
			applied += 1
			# R245 红卡门判据：本批**应用列表**内任一张 kind==SUBLIME（成对模式整行
			# 两张一起应用——勿按槽位/首张判；apply 即生效，大屏是效果告知非效果选择）
			if int(card.get("kind", -1)) == CardGenerator.CardKind.SUBLIME:
				sublime_hit = true
	card_select_ui.close()
	# E3 升级波纹（self-evolution）：确认瞬间以玩家为心的金色扩散环——奖励即刻感。
	# 成对抉择双环错峰（两张卡两次脉冲）
	if applied > 0 and player != null and is_instance_valid(player):
		for k in range(applied):
			_spawn_level_burst(player.global_position, 0.12 * float(k))
	if sublime_hit and sublime_confirm_ui != null:
		# R245 persist 摊薄窗结清提前：进大屏前结清（成就判定+落盘即结清——玩家停留
		# 大屏任意久不再抑制；确认链 _finish_card_choice 尾的对应结清在 depth==0 时为
		# Meta 侧守卫空转，语义等价「已删除」）。仅溢出批消化中（draining）时保持抑制
		# ——批清零由 _tick_merged_overflow 结清（R189 口径不破）。
		if not _merged_overflow_draining:
			Meta.end_persist_defer()
		# 弹出规则（设计 §1.5）：每批必弹、每批至多一次（红卡注入点每批发牌只掷一次
		# 天然保证）、同局不去重（enable_sublime 幂等，无去重状态位）
		sublime_confirm_ui.open(player.character_id)
		# 挂机防死锁臂挂起（auto_select_on 关时 _tick_auto_idle 首段即撤销，零成本）
		_auto_sublime_left = AUTO_SUBLIME_WINDOW_S
		return
	_finish_card_choice()


func _finish_card_choice() -> void:
	# R245 红卡门收口：原 _on_card_choice 尾段（:2073-2086）整段提取——普通路径直调
	# （链路与旧版逐位一致），红卡路径经 sublime_confirm_ui.confirmed 信号确认后调用。
	# 迁移矩阵/仲裁/探针清空逻辑一律不动（E-16 冻结）。
	# R199-P18：选卡收口直迁 PLAYING 与暂停恢复同款 0.5s 输入宽限——选卡模态期手指
	# 照常累计拖动（_drag_accum），无宽限时残留位移在收口瞬间全额落位 = 机体瞬移；
	# 宽限置位后残留拖动被吞（若收口即接续连升排队回 LEVEL_UP，宽限保留待最终收口生效；
	# 红卡大屏确认链同款——_arm_resume_grace 只在最终恢复 PLAYING 时置位一次，重复
	# 置位无害〔resume_grace_left>0 守卫〕）
	if change_state(GameConst.GameStatus.PLAYING):
		_arm_resume_grace()
	if pending_level_ups > 0:
		pending_level_ups -= 1
		_open_card_flow(player.level)
	elif merged_overflow_level_ups > 0:
		# R188-perf 档3 连升合并溢出批：同分布自动抽卡收口（不弹卡窗——逐批 roll 后
		# 按自动选卡同策略评分取首选应用；永不选诅咒不变量由策略侧保证）。
		# R189 分帧消化：收口帧只挂起批计数，逐帧按时间预算抽卡（_tick_merged_overflow）
		# ——巨批同帧串行 generate+apply 曾实测单帧 72s（47,954 张 × ~1.5ms）。
		# 抑制态保持（begin 已入位），批清零由 _tick_merged_overflow end 结清。
		# （R245 注：红卡门路径若于进大屏前已结清且本分支挂起溢出批——depth==0 下批
		# 逐帧消化无摊薄保护；0.001%×连升溢出同批窗为 1e-5 级角案，如实记录不修）
		_merged_overflow_draining = true
	if not _merged_overflow_draining:
		Meta.end_persist_defer()


func _apply_merged_level_ups(p_count: int) -> void:
	# R188-perf 档3 连升合并溢出批：同分布自动抽卡（gain_xp 巨额经验 4.8 万张选卡
	# 冻结的结构性修复——帽外升级不再排队弹窗，逐批 generate_candidates 保持 roll
	# 分布 + AutoIdleStrategy 评分取首选；零弹窗零逐张人工交互）
	# R189：同步巨批入口保留（测试/特殊路径）；挂机链路走 _tick_merged_overflow 分帧
	Meta.begin_persist_defer()
	for _i in range(maxi(p_count, 0)):
		_apply_one_merged_level_up()
	Meta.end_persist_defer()


func _apply_one_merged_level_up() -> void:
	# R212 刀4：generate+pick 抽为 _pick_merged_card（apply 前可做超帽预判的分步点）；
	# 本体语义与 R189 逐位一致（同步巨批入口/测试路径直用）
	card_generator.apply_choice(_pick_merged_card(), player)


func _pick_merged_card() -> Dictionary:
	# R212 刀4 分步：抽卡（generate ~0.74ms + 策略评分取首选 ~0.6ms——廉价步）；
	# 空货架兜底（generate 恒有 fallback 卡）与原 _apply_one_merged_level_up 同口径
	var context := {
		"player": player,
		"wave": wave_director.current_wave,
		"level": player.level,
		"deal_count": relic_handler.deal_count(),
		"curse_last": relic_handler.curse_requested(),
		"min_rarity_floor": relic_handler.take_rarity_floor(),
	}
	var candidates := card_generator.generate_candidates(context)
	var picked := AutoIdleStrategy.pick(candidates, false)
	if picked < 0 or picked >= candidates.size():
		picked = 0                              # 空货架兜底（generate 恒有 fallback 卡）
	# R253（R245 遗留 a 清账）：溢出批自动抽卡排除升华卡——SUBLIME 是唯一须用户确认
	# 门（sublime_confirm_ui）的红卡，自动静默应用=绕门（~0.0x% 概率真实可达）。顺位
	# 轮换取次选（不重 generate——昂贵步），帽 20 防退化数据死循环，帽尽放行（货架
	# 永不为空的兜底口径优先）
	for _retry in range(20):
		if int(candidates[picked].get("kind", -1)) != CardGenerator.CardKind.SUBLIME:
			break
		picked = (picked + 1) % candidates.size()
	return candidates[picked]


static func _is_expensive_merged_card(p_card: Dictionary) -> bool:
	# R212 刀4 高成本卡判据：WEAPON 类 apply 走 player.add_weapon 形态工厂（实例化 +
	# setup + 装槽，单次实测 70-100ms——预算 35ms 的 2-3 倍超帽源）；其余类别（词条/
	# 精通/遗物/保底/槽位）apply 均 ≤1ms 量级
	return int(p_card.get("kind", -1)) == CardGenerator.CardKind.WEAPON


func _merged_overflow_budget_ms() -> float:
	# R212 刀4 预算真源：mobile 8ms / 桌面·headless 35ms（R189 原口径）；测试覆写优先
	if merged_overflow_budget_override_ms >= 0.0:
		return merged_overflow_budget_override_ms
	return MERGED_OVERFLOW_BUDGET_MS_MOBILE if OS.has_feature("mobile") \
		else MERGED_OVERFLOW_BUDGET_MS


func _tick_merged_overflow() -> void:
	# R189 溢出批分帧消化：每帧按时间预算抽卡，批清零时 end_persist_defer 一次结清
	# 成就扫描 + 落盘。PLAYING 态逐帧调用。
	# R212 刀4：①预算 mobile 门收紧 8ms（35ms 每帧常态超 mobile 帧预算——感段尖峰
	# 主头）；②高成本卡（WEAPON 实例化）启动闸——帧内已耗超闸值即让渡该张至下一帧
	# 首位应用（_merged_overflow_deferred 留存，roll 不作废），挡住「while 先检后做
	# 挡不住单次 apply 独占 70-100ms」的同帧连环超帽。
	if not _merged_overflow_draining:
		return
	var t0 := Time.get_ticks_usec()
	var deadline := t0 + int(_merged_overflow_budget_ms() * 1000.0)
	while merged_overflow_level_ups > 0:
		var card: Dictionary = _merged_overflow_deferred
		if card.is_empty():
			var now_us := Time.get_ticks_usec()
			if now_us >= deadline:
				break
			card = _pick_merged_card()
			if _is_expensive_merged_card(card) and now_us - t0 > MERGED_EXPENSIVE_GUARD_US:
				_merged_overflow_deferred = card   # 让渡下一帧首位（帧已近耗尽不再启动重活）
				break
		_merged_overflow_deferred = {}
		merged_overflow_level_ups -= 1
		card_generator.apply_choice(card, player)
	if merged_overflow_level_ups <= 0:
		_merged_overflow_draining = false
		_merged_overflow_deferred = {}
		Meta.end_persist_defer()


# ── Boot 各段 ─────────────────────────────────────────────────────
func _boot_load_data() -> void:
	# DataRegistry 启动期一次性加载（运行期零 .tres 加载，E-08）
	registry = DataRegistry.new()
	registry.load_all(MANIFEST_PATH)
	# R194 空表闸（bug#4 RC3 静默降级根治）：enemies 空 / 校验报告零条目 = 数据未入包
	#（导出缺 *.cfg 或 remap 扫描漏）——原口径 DataRegistry 仅 push_warning 静默跳类目，
	# boot 照常进 MENU、场上恒无怪（不可见故障）。本闸走既有 config_fatal/boot_error 屏
	# 口径（:137-140 同款：boot_fatal 置位 + _build_boot_error_screen + push_error），
	# _ready 在本函数返回后查 boot_fatal 中止后续 boot 段 → 拒绝入局。契约变更注释 R194。
	# R199-C10：闸谓词扩 weapons 同判（判据详见 _boot_check_empty_registry 注）。
	# R194 修复环：闸体抽为 _boot_check_empty_registry()——registry 由本函数直
	# DataRegistry.new() 构造，扫描层无拦截点（动态子类覆写不可达且编译不过），
	# 抽方法供 export_data_cases.gd T4 负态直驱（裸实例 + 真实扫描终态输入）。
	_boot_check_empty_registry()
	_scan_xp_tier_anchor()


func _scan_xp_tier_anchor() -> void:
	# R202 经验四色断环修复：分档基线锚 = 注册表最低 exp_base，boot 一次扫描缓存
	#（运行期逐击零遍历——掉落路径不新增每击成本）。断环根因（probe_r202_xpcolor 实证）：
	# 旧 baseline = 死者自身 exp_base×通胀^(w-1)，而 value = exp_value×点金×early =
	# exp_base×通胀^(w-1)×e_exp×点金×early（enemy.gd spawn 同式）→ 通胀与 exp_base
	# 全部自相消，比值恒 = e_exp×点金×early → 普通/Boss 恒白档、精英恒金档，四色断环
	#（E6_boss 实测 ratio=1.250 白档）。锚=注册表最低 exp_base 后比值=面值/杂兵锚，
	# 普通 1×白 / 中价 3~4×绿 / 精英 ~19×金 / Boss ~200×七彩 分化恢复。
	# 直遍先例 wave_director._cheapest_enemy（registry.enemies 公有 Dictionary）；
	# 非法值（null/≤0）跳过；全空保持默认 3.0（空表另有 R194 boot 闸拦截）。
	if registry == null or registry.enemies.is_empty():
		return
	var best := -1.0
	for id in registry.enemies:
		var e: EnemyData = registry.enemies[id]
		if e == null or e.exp_base <= 0.0:
			continue
		if best < 0.0 or e.exp_base < best:
			best = e.exp_base
	if best > 0.0:
		_xp_tier_anchor_base = best


func _boot_check_empty_registry() -> void:
	# R194 空表闸本体（语义不变，仅抽方法——判据/置位/诊断计数与抽出前逐行一致）
	# R199-C10：谓词扩为 enemies/total/weapons 同判（R194 同族防线缺口）——weapons 类目
	# 单独丢失（导出 include_filter/remap 漏一类目）原口径静默放行：boot 照常进 MENU、
	# 首发 registry.get_weapon 全 null = 静默空手开局，全程零告警。
	if registry.enemies.is_empty() or registry.weapons.is_empty() \
			or int(registry.report.get("total", 0)) == 0:
		boot_fatal = [
			"DataRegistry 空注册表：enemies=%d / weapons=%d / report.total=%d / rejected=%d——数据文件缺失（导出 include_filter 或 remap 扫描）" % [
				registry.enemies.size(), registry.weapons.size(),
				int(registry.report.get("total", 0)),
				int(registry.report.get("rejected", 0))],
		]
		_build_boot_error_screen()
		DebugStats.count(&"boot_empty_registry")
		push_error("[GameLoop] 空注册表，拒绝进入 MENU：%s" % str(boot_fatal))


func _boot_build_pools() -> void:
	# 池×6（容量真源 BalanceTables.pool_prewarm；xp 池集成包 B.1 挂载——XpShard 真件落地）
	_projectile_pool = ProjectilePool.new()
	_projectile_pool.name = "ProjectilePool"
	add_child(_projectile_pool)
	_projectile_pool.setup(&"projectile", load(SCENE_PROJECTILE),
		GameConfig.get_pool_capacity(&"projectile"))
	_projectile_pool.soft_limit = int(GameConfig.balance.projectile_soft_limit)
	_projectile_pool.hard_limit = int(GameConfig.balance.projectile_hard_limit)
	# R271 V-C1（verdict：S1 延µs 塌缩 49%+加摘 17k/s 相关坐实 → §3.3 刀 C1 boost 门内默认）：
	# 弹池惰性归位接线——boost 开时 release 留桶不 reparent（同变体复用零树进出）。
	_projectile_pool.lazy_bucket_release = true
	# R94 homing 池（追踪/爆炸/AoE 真件）：容量与软硬限沿 projectile 同源（导弹量级小）
	_homing_pool = ProjectilePool.new()
	_homing_pool.name = "HomingPool"
	add_child(_homing_pool)
	_homing_pool.setup(&"homing", load(SCENE_HOMING), 24)   # 容量=预热数（AC-14.2 对账口径）
	_homing_pool.soft_limit = 64
	_homing_pool.hard_limit = 96
	var enemy_pool := EnemyPool.new()
	enemy_pool.name = "EnemyPool"
	add_child(enemy_pool)
	enemy_pool.setup(&"enemy", load(SCENE_ENEMY), GameConfig.get_pool_capacity(&"enemy"))
	var popup_pool := PopupPool.new()
	popup_pool.name = "PopupPool"
	add_child(popup_pool)
	popup_pool.setup(&"popup", load(SCENE_POPUP), GameConfig.get_pool_capacity(&"popup"))
	var particle_pool := ParticlePool.new()
	particle_pool.name = "ParticlePool"
	add_child(particle_pool)
	particle_pool.setup(&"particle", load(SCENE_PARTICLE), GameConfig.get_pool_capacity(&"particle"))
	var laser_pool := LaserBeamPool.new()
	laser_pool.name = "LaserPool"
	add_child(laser_pool)
	laser_pool.setup(&"laser", load(SCENE_LASER), GameConfig.get_pool_capacity(&"laser"))
	var xp_pool := XPPool.new()
	xp_pool.name = "XPPool"
	add_child(xp_pool)
	xp_pool.setup(&"xp", load(SCENE_XP_SHARD), GameConfig.get_pool_capacity(&"xp"))
	pools = {
		&"projectile": _projectile_pool,
		&"homing": _homing_pool,
		&"enemy": enemy_pool,
		&"popup": popup_pool,
		&"particle": particle_pool,
		&"laser": laser_pool,
		&"xp": xp_pool,
	}
	# 预热（AC-14.2，Boot 期完成）
	_projectile_pool.prewarm(GameConfig.get_pool_capacity(&"projectile"))
	_homing_pool.prewarm(24)                    # R94：导弹并发小，24 预热足够
	enemy_pool.prewarm(GameConfig.get_pool_capacity(&"enemy"))
	popup_pool.prewarm(GameConfig.get_pool_capacity(&"popup"))
	particle_pool.prewarm(GameConfig.get_pool_capacity(&"particle"))
	laser_pool.prewarm(GameConfig.get_pool_capacity(&"laser"))
	xp_pool.prewarm(GameConfig.get_pool_capacity(&"xp"))
	# R214 E'：敌/弹池挂树序分桶 host（vc21 定案 dc≤400 才能稳 90-120fps；敌 120+弹百发
	# 的同贴图实体树序交错断批 → 按贴图分桶相邻合批）。R216 刀①：xp 池补挂（碎片 18
	# 贴图变体后树序交错同样断批——vc23 桶遥测定案 dc 大头）。popup 池同字体本就天然
	# 相邻，laser/particle 走 Line2D/发射器路径不在刀面——均不挂
	_attach_bucket_host(_projectile_pool)
	_attach_bucket_host(enemy_pool)
	_attach_bucket_host(pools[&"xp"] as ObjectPool)
	# R272 V-C2（vc82 真机定谳敌侧桶链→升格接线，用户「最大程度保帧」授权）：敌每次死亡
	# 归池 unplace 整子树 reparent 回池根+波补 acquire place 再 reparent——深载敌周转
	# ~1300 组/s×两次整树摘挂（子树含 Area2D=物理空间重注册），直方图 enemy.gd/Area2D/
	# CollisionShape2D 各 7923 added 同数坐实；步µs 27-33ms/步顶死 30Hz 档 33.3ms 步预算
	# =深载 fps 22-30 主因。本刀=V-C1 同款升格：boost 开 release 留桶（unplace_lazy 仅
	# 镜像注销防幽灵绘制），acquire 同贴图 place 免搬零 reparent、换贴图自然换桶（低频）；
	# boost 关侧 unplace 现状逐位（r214「release 归位池根」旧断言=关态口径不受扰）。
	# xp 池同款接线（周流量小一级，接线零成本顺手收口）；homing 池未挂桶（无 reparent
	# 链）不在刀面。
	enemy_pool.lazy_bucket_release = true
	(pools[&"xp"] as ObjectPool).lazy_bucket_release = true


func _attach_bucket_host(p_pool: ObjectPool) -> void:
	# R214 E'：池下挂 TexBucketHost（桶=host 子级；place 由实体激活期自报、unplace 由
	# ObjectPool.release 统一）。desktop/headless 同样生效——合批对 gl_compatibility/
	# forward_plus 2D 均成立且视觉等价（仅同 z 覆盖序变化），无桌面扰动面。
	# preload 直载（新 class_name 首次出现——全局类缓存未刷新前 -s headless 不可见）。
	if p_pool == null:
		return
	var host: Node = (load("res://scripts/core/tex_bucket_host.gd") as GDScript).new()
	host.name = "TexBuckets"
	p_pool.add_child(host)
	host.setup(p_pool)
	p_pool.bucket_host = host


func _boot_prewarm_textures() -> void:
	# R215 刀C（菜单分帧版）：boot 只建队（零贴图生成——boot 集中生成实测 6.8s 超预算），
	# MENU 态 12ms/帧消化（_process_tex_prewarm）。队列序：共享域（弹珠/星/影——开局
	# 弹尖峰主源）→ 常规 kind → 特殊脸/精英 → boss 双面（越晚出场越后）。
	# kind 真源=Enemy.visual_kind_for（与 _visual_kind 同一实现，防映射漂移）。
	# 共享域拆粒入队（QA-R215-OBS-1：op:1 整域单帧 218ms 超 12ms 预算 ×19——
	# 每贴图一队列项，预算名实相符）。TextureFactory.prewarm_shared 保留为
	# 测试/诊断整域口（产品路径不调）。
	# R227：字形 cell 前移队首（vc32 全轮 位图0 实证：原排在敌贴图后 ~40 项+仅 MENU 态
	# 消化，菜单停留 ~2s 的真实玩家永远排不到→整局 Label 回退=渲染首刀从未激活）。
	# 整套 12 cell 实测 ~42ms——队首消化 ≈0.3s 菜单停留即就绪；敌贴图后移仍有菜单泵/
	# 惰性双兜底（表现不劣化于现状）。新局入口另有 ensure_runstart_bake 结构化兜底。
	for gi in range(PopupGlyphAtlas.glyph_count()):
		_tex_prewarm_queue.append({&"op": 6, &"cell": gi})
	var fills: Array = [PopPalette.PLAYER, PopPalette.ENEMY, PopPalette.GOLD]
	for c in PopPalette.ELEMENT_COLORS.values():
		if not fills.has(c):
			fills.append(c)
	for f in fills:
		_tex_prewarm_queue.append({&"op": 2, &"fill": f})
	_tex_prewarm_queue.append({&"op": 2, &"fill": PopPalette.GOLD, &"size": 16, &"hl": false})
	# R216 刀①：碎片星 18 变体（4 档×3 量化 alpha + 彩档 6 色相）——W1 首批死亡前烤好；
	# star() 缓存键含填充色+alpha 自动分键（白体 star(44,WHITE) 仍被池预热 160 实例的
	# 初始贴图消费〔boot 一次性进缓存〕——预热队列不再单列白体项，op:3 改带 fill）
	for t in 4:
		for q in 3:
			var xc := PopPalette.xp_tier_color(t)
			xc.a = 0.5 + 0.25 * q
			_tex_prewarm_queue.append({&"op": 3, &"fill": xc})
	for h in 6:
		_tex_prewarm_queue.append({&"op": 3, &"fill": Color.from_hsv(float(h) / 6.0, 0.7, 1.0)})
	_tex_prewarm_queue.append({&"op": 4})
	var seen := {}
	for eid in registry.enemies:
		var ed: EnemyData = registry.enemies[eid]
		if ed == null or seen.has(eid):
			continue
		var k := Enemy.visual_kind_for(ed, int(ed.tags))
		if seen.has(k):
			continue
		seen[k] = true
		# R215 修（评审 E3/键漂移）：剔死键——"bastion" 生产面走 bastion_core（下方显式
		# 项已列，enemy_tex("bastion") 无消费方）；"elite" _sync_visual 精英 elif 先截流
		# 只调 scale、enemy_tex("elite") match 臂不可达（脸疑案已登记 tracker 二e 低危）
		if k == &"bastion" or k == &"elite":
			continue
		_tex_prewarm_queue.append({&"op": 0, &"kind": k, &"angry": false})
	_tex_prewarm_queue.append({&"op": 0, &"kind": &"volatile_scared", &"angry": false})
	_tex_prewarm_queue.append({&"op": 0, &"kind": &"volatile", &"angry": true})
	# R215 修（评审 E3/首精英残留尖峰）：补真键——E3 装甲两态 + 精英皇冠（挂件小图，
	# 随常规段消化不设挂机门；crown 非 enemy_tex 路径走 op:5）
	_tex_prewarm_queue.append({&"op": 0, &"kind": &"bastion_core", &"angry": false})
	_tex_prewarm_queue.append({&"op": 0, &"kind": &"bastion_armor", &"angry": false})
	_tex_prewarm_queue.append({&"op": 0, &"kind": &"bastion_armor_cracked", &"angry": false})
	_tex_prewarm_queue.append({&"op": 5})
	# R225 跳字位图化：伤害数字字形图集逐 cell 入队（R216 碎片星逐项拆粒同款）——
	# R227 前移队首（见上）；未消化完即开局的局由 ensure_runstart_bake 新局兜底，
	# ready() 为假 → bitmap 门自动回退 Label 路径（表现不劣化于现状）
	for i in range(1, 8):
		# boss1~7 双面（boss 位=波表 TAG_BOSS 注入，registry tags 触不到——显式补）
		var bk := StringName("boss%d" % i)
		_tex_prewarm_queue.append({&"op": 0, &"kind": bk, &"angry": false})
		_tex_prewarm_queue.append({&"op": 0, &"kind": bk, &"angry": true})
	# R252D P3：图鉴域贴图并入本队列（op:7，排 boss 段后——boss 3s 挂机门语义不变，
	# 门未放行时队列暂停在其首项、图鉴域随后消化；页签点击零首生成，M1 首建上限的
	# 贴图支撑。每贴图一队列项=拆粒口径，预算名实相符；队列复用不加新通道）
	for wid_v: Variant in registry.weapons:
		_tex_prewarm_queue.append({&"op": 7, &"tex": &"weapon", &"id": wid_v})
	for cid_v: Variant in CharacterTable.CHARACTERS:
		_tex_prewarm_queue.append({&"op": 7, &"tex": &"skill", &"id": cid_v.id})
	var pools_seen: Dictionary = {}
	for td_v: Variant in registry.traits:
		var td_row: TraitData = registry.traits[td_v]
		if td_row != null and not pools_seen.has(int(td_row.pool)):
			pools_seen[int(td_row.pool)] = true
			_tex_prewarm_queue.append({&"op": 7, &"tex": &"type", &"pool": int(td_row.pool)})
	_tex_prewarm_queue.append({&"op": 7, &"tex": &"gem"})
	for fill_v: Variant in PopPalette.ELEMENT_COLORS.values():
		_tex_prewarm_queue.append({&"op": 7, &"tex": &"ring", &"fill": fill_v})
	DebugStats.count(&"tex_prewarm_kinds", _tex_prewarm_queue.size())


func _process_tex_prewarm(p_budget_us: int, p_playing: bool = false) -> void:
	# R215 刀C：菜单期预算消化（每帧 ≤p_budget_us；队列空=零成本早退）。
	# 未消化完即开局的剩余变体走原惰性路径（表现不劣化于现状）。
	# R222 Fix P（vc28 日志 ❌：回菜单挂机 fps33→10 余100ms）：成本自适应占空——
	# boss 双面单项 88-245ms 远超 12ms 预算，逐帧连泵把挂机菜单钉死 fps10；末项超支
	# → 后续 ceil(cost/budget)−1 帧零成本直返还账（R221 Fix A 同款；单项原子不可分，
	# 占空后工作帧仍 88-245ms 一次、但频率摊到 ~1/N 帧，整体脱离持续冻结）。
	# R267 刀P1：p_playing=true = PLAYING 泵口径（渲染轴尾 4ms/帧）——
	#   · op:6 字形 cell 跳过不烤（桌面 bitmap 门恒 Label 零扰动；cell 归 MENU 泵/
	#     runstart 兜底域；确认即出发的流程模态后无 MENU 窗口——R260 模态期泵挂起）；
	#   · boss 双面波次门槛：current_wave ≥ 首现波−1 才出队（88-245ms 原子项从
	#     「Boss 出场帧」挪到「出场前一波低强度窗」）；未放行**跳过不 break**——
	#     其后廉价项照常消化（v2 评审①：整队停摆是 v1 处方的确定性破面）；
	#   · MENU 口径（p_playing=false）原样：dwell 挂机门 break 语义/预算/还账不动。
	if _tex_prewarm_queue.is_empty():
		return
	if _tex_prewarm_skip > 0:
		_tex_prewarm_skip -= 1
		return
	var t0 := Time.get_ticks_usec()
	var it0 := t0
	var last_us := 0
	while not _tex_prewarm_queue.is_empty():
		var pick := 0
		if p_playing:
			# 首个可出队项扫描（跳过 op:6 与未达波次门槛的 boss 项——skip 语义）
			pick = -1
			for i in range(_tex_prewarm_queue.size()):
				var jt: Dictionary = _tex_prewarm_queue[i]
				var jop := int(jt.get(&"op", 0))
				if jop == 6:
					continue
				if jop == 0 and String(jt.get(&"kind", &"")).begins_with("boss"):
					var bfw := int(jt.get(&"wave", -1))
					if bfw < 0 or wave_director == null \
							or wave_director.current_wave < bfw - 1:
						continue
				pick = i
				break
			if pick < 0:
				return                      # 全队列无可出队项（零成本早退）
		var job: Dictionary = _tex_prewarm_queue[pick]
		# R215 修（评审菜单顿挫）：boss 双面=重活（单项 88-245ms）——挂机门未到不出队
		# 不计时，队列暂停在队首（boss 项全在队尾，常规段含新真键先消化完）
		if not p_playing and int(job.get(&"op", 0)) == 0 \
				and String(job.get(&"kind", &"")).begins_with("boss") \
				and _menu_dwell_s < BOSS_PREWARM_IDLE_S:
			break
		it0 = Time.get_ticks_usec()
		match int(job.get(&"op", 0)):
			0:
				TextureFactory.enemy_tex(job[&"kind"], bool(job[&"angry"]))
			1:
				TextureFactory.prewarm_shared()          # 整域口（测试/诊断；产品建队走拆粒 2/3/4）
			2:
				TextureFactory.bead(job[&"fill"], int(job.get(&"size", 64)), bool(job.get(&"hl", true)))
			3:
				TextureFactory.star(44, job.get(&"fill", Color.WHITE))    # R216：星变体带填充色
			4:
				TextureFactory.shadow_ellipse()          # boss/精英底影
			5:
				TextureFactory.crown()                   # R215 修：精英皇冠真键（_cached "crown"）
			6:
				PopupGlyphAtlas.build_cell(int(job[&"cell"]))   # R225：跳字字形 cell（幂等）
			7:
				# R252D P3：图鉴域贴图（weapon/skill/type/gem/ring——页签点击零首生成；
				# TextureFactory 各口自带 _cached 键缓存，重复入队/重复调用零成本）
				match String(job.get(&"tex", &"")):
					&"weapon":
						TextureFactory.weapon_icon(job[&"id"])
					&"skill":
						TextureFactory.skill_icon(job[&"id"])
					&"type":
						TextureFactory.type_icon(1, int(job[&"pool"]))
					&"gem":
						TextureFactory.ui_gem()
					&"ring":
						TextureFactory.ring_tex(job[&"fill"], 36, 5.0)
		_tex_prewarm_queue.remove_at(pick)
		last_us = int(Time.get_ticks_usec() - it0)
		if Time.get_ticks_usec() - t0 >= p_budget_us:
			break
	if p_budget_us > 0 and last_us > p_budget_us:
		# R222 修轮（评审 medium）：折臂公式复用 Fix A 纯函数（r221_fixreg ① 5 边界
		# 断言既有覆盖——内联副本零覆盖且未来一处改一处漏）
		# R267 刀P1 观测口：原子超支项计数（boss 双面 88-245ms 不可分——错峰缓解非
		# 根治的设计诚实声明判读源）
		DebugStats.count(&"tex_prewarm_atom_overruns")
		_tex_prewarm_skip = DescPrewarm.skip_frames_for(last_us, p_budget_us)


func _reorder_tex_prewarm_wave_first() -> void:
	# R267 刀P1：队列波序重排（设计 §1.1 处方 1）——波表 roll 后按本局出场
	# (kind, 首现波) 重排 op:0 段：wave1 廉价 kind（单项 1-3ms）最前，boss 双面按
	# 各自首现波序入段（不提队首——PLAYING 泵波次门槛靠 &"wave" 键放行）。
	# kind 真源 = Enemy.visual_kind_for（与 _boot_prewarm_textures :2905 同源防漂移）。
	# 无尽口径（v3 评审②）：清单 = 波表全量去重 kind 集（主体段+无尽段），首现波 =
	# 首次出场位；循环不引入新 kind。**只动 op:0 段内部序**——op:6 队首前移
	# （qa_r227_bake_b ①）与其余域相对序原样（splice 回原槽位）。
	# 纯读波表 + registry 静态数据，零 rng 消费（红线）。
	if wave_director == null or wave_director.wave_table == null \
			or _tex_prewarm_queue.is_empty():
		return
	var first_wave := {}
	var rows: Array = []
	rows.append_array(wave_director.wave_table.entries)
	rows.append_array(wave_director.wave_table.endless_entries)
	for entry_v: Variant in rows:
		var entry: WaveEntryData = entry_v as WaveEntryData
		if entry == null:
			continue
		var w := int(entry.index)
		for comp: Dictionary in entry.composition:
			var eid := StringName(String(comp.get("enemy_id", "")))
			if eid == StringName(""):
				continue
			var etags := int(comp.get("tags", 0))
			var ed: EnemyData = registry.get_enemy(eid) if registry != null else null
			var k := Enemy.visual_kind_for(ed, etags)
			if not first_wave.has(k) or w < int(first_wave[k]):
				first_wave[k] = w
	# 收集 op:0 项（槽位/项分离），装饰序 = (首现波, 原序) 稳定排序（sort_custom
	# 不稳定——显式 pos 键钉死同波内原相对序）
	var slots: Array[int] = []
	var items: Array = []
	for i in range(_tex_prewarm_queue.size()):
		var it: Dictionary = _tex_prewarm_queue[i]
		if int(it.get(&"op", -1)) != 0:
			continue
		slots.append(i)
		items.append(it)
	if items.size() < 2:
		return
	var deco: Array = []
	for j in range(items.size()):
		var dj: Dictionary = items[j]
		var dk := String(dj.get(&"kind", &""))
		var fw := int(first_wave.get(dk, 999))     # 表外 kind（volatile/bastion_* 等）殿后
		deco.append({"fw": fw, "pos": j, "it": dj})
	deco.sort_custom(func(a, b) -> bool:
		if int(a["fw"]) != int(b["fw"]):
			return int(a["fw"]) < int(b["fw"])
		return int(a["pos"]) < int(b["pos"]))
	for j in range(slots.size()):
		var nj: Dictionary = deco[j]["it"]
		var fw := int(deco[j]["fw"])
		if fw < 999:
			nj[&"wave"] = fw        # PLAYING 泵波次门槛键（boss 判据；非 boss 项无害随行）
		_tex_prewarm_queue[slots[j]] = nj


func _boot_build_grids() -> void:
	# SpaceGrid ×2（§1.3-6：GameLoop 持有；720×1280 + 192px 出屏余量）
	enemy_grid = SpaceGrid.new()
	enemy_grid.configure(Vector2(GameConfig.balance.res_logic), 192.0)
	enemy_bullet_grid = SpaceGrid.new()
	enemy_bullet_grid.configure(Vector2(GameConfig.balance.res_logic), 192.0)


func _boot_build_actors() -> void:
	# 管线（工厂自动切真件）→ 遗物处理器 → 敌波（spawner/wave_director）→ 玩家 → 元素系统
	# ★ 经验掉落订阅必须先于 EnemySpawner 入树（信号连接序 = 派发序：掉落侧读取
	#   exp_value/position 必须先于 spawner 的死亡归还清零，集成包 B.1）
	EventBus.enemy_killed.connect(_on_enemy_killed_drop_xp)
	pipeline = DamagePipelineStub.get_pipeline()
	relic_handler = RelicHandler.new()
	relic_handler.name = "RelicHandler"
	add_child(relic_handler)
	# ★ 遗物事件绑定提前至 Boot（连接序 = 派发序）：enemy_killed 的精英 tag/治疗读取
	#   必须先于 EnemySpawner 的死亡归还清零（_reset_state 置 tags=0），集成包 B.2
	relic_handler.bind_events()
	elemental = ElementalSystem.new()
	elemental.name = "ElementalSystem"
	add_child(elemental)
	elemental.pipeline = pipeline
	elemental.enemy_grid = enemy_grid
	# ★ wave_director 先于 spawner 入树（连接序 = 派发序）：F-19 Boss 击杀解锁读取
	#   enemy.tags 必须先于 spawner 死亡归还的 tags 清零（_reset_state）——与上方 xp 掉落
	#   订阅提前同因（集成包修复：此前 Boss 击杀解锁恒读 tags=0 失效，集成冒烟补断言）
	wave_director = WaveDirector.new()
	wave_director.name = "WaveDirector"
	add_child(wave_director)
	# ★ GameFeel 前置组装 + enemy_killed 前置订阅（连接序 = 派发序，F-19 同纪律）：
	#   Boss 击杀打击感读取 enemy.tags 必须先于 EnemySpawner 死亡归还的 tags 清零
	#   （_reset_state 置 0）——审查 Fix 2：此前 GameFeel 在 presentation 段订阅，派发序
	#   恒排在 spawner 之后（读 tags=0），Boss 击杀 120ms 顿帧永不触发。setup（其余职责）
	#   仍在 _boot_build_presentation 完成
	game_feel = GameFeelDirector.new()
	game_feel.name = "GameFeelDirector"
	add_child(game_feel)
	game_feel.early_bind()
	# ★ 方向 C 彩纸屑前置组装 + enemy_killed 前置订阅（连接序 = 派发序，F-19 同纪律）：
	#   Boss 击杀庆祝读取 enemy.tags 必须先于 EnemySpawner 死亡归还的 tags 清零
	#   （_reset_state 置 0）——否则彩纸屑恒不触发
	confetti = ConfettiBurst.new()
	confetti.name = "ConfettiBurst"
	add_child(confetti)
	# ★ BGM Boss 层前置订阅（2026-08-31 修复：原连接在 presentation 段——晚于 spawner
	#   _ready 的 enemy_killed 订阅，派发时 tags 已被死亡归还清零 → Boss 击杀后战鼓层
	#   永不收起，持续低频脉冲加重「电流嗡鸣」听感）；同处并入刷新次数授予（Boss +1）
	EventBus.boss_spawned.connect(func(_b: Node2D) -> void:
		if sfx != null:
			sfx.bgm_set_boss_layer(true))
	EventBus.enemy_killed.connect(_on_boss_killed_bgm)
	spawner = EnemySpawner.new()
	spawner.name = "EnemySpawner"
	add_child(spawner)
	spawner.pool = pools[&"enemy"]
	spawner.registry = registry
	spawner.projectile_pool = _projectile_pool
	spawner.enemy_grid = enemy_grid
	spawner.elemental_system = elemental
	spawner.prewarm()
	wave_director.spawner = spawner
	wave_director.registry = registry
	wave_director.wave_table = registry.get_wave_table()
	wave_director.enemy_grid = enemy_grid
	player = (load(SCENE_PLAYER) as PackedScene).instantiate() as Player
	player.name = "Player"
	player.z_index = 6
	add_child(player)
	player.setup({
		"pipeline": pipeline,
		"projectile_pool": _projectile_pool,
		"homing_pool": _homing_pool,             # R94：homing 真件池（W6/W7/子弹头）
		"enemy_grid": enemy_grid,
		"enemy_bullet_grid": enemy_bullet_grid,
		"laser_pool": pools[&"laser"],
		"elemental": elemental,
		"relic_handler": relic_handler,           # B.2：遗物命中乘区问询通道
		"wave_director": wave_director,           # B.4：SYN_FIRST_STRIKE 波首命中位
	})
	relic_handler.setup({"registry": registry, "player": player})
	# Q-4：首发手枪（R186：改走首发仲裁——fission 存档自定义首发；boot 期选角未定，
	# 装错由 start_run 对账纠正）
	_equip_starting_weapon(Meta.character_id)


func _boot_build_presentation() -> void:
	# 表现层组装：淡云背景 → 粒子导演 → GameFeel → 跳字 → HUD/Boss 条/结算屏 → 卡牌流
	# （方向 C：淡云蓝白底 z=-20——纯视觉层，零事件依赖；彩纸屑已在 actors 段前置订阅）
	var backdrop := CloudBackdrop.new()
	backdrop.name = "CloudBackdrop"
	_backdrop = backdrop
	add_child(backdrop)
	# R195 适配底座：逻辑域边界线（res_logic 四边 1px 低透明描边——expand 后平板横向
	# 延展区可见反弹沿需界示；z=-10 压云不压弹幕，仅 size_changed 重绘）
	var outline := PlayfieldOutline.new()
	outline.name = "PlayfieldOutline"
	add_child(outline)
	var particles := ParticleDirector.new()
	particles.name = "ParticleDirector"
	add_child(particles)
	particles.setup(pools[&"particle"])
	fx_particles = particles                     # c4①：graze 微光发射口（同实例复用——不另建导演）
	for emitter in (pools[&"particle"] as ParticlePool).get_children():
		particles.apply_placeholder_material(emitter as GPUParticles2D)
	# GameFeel 实例已在 _boot_build_actors 前置组装并 early_bind（Fix 2）——
	# 此处补全 setup 其余职责（config/shake/色差/其余事件订阅）
	game_feel.setup({
		"config": registry.get_game_feel(),
		"particles": particles,
		"chromatic_host": self,
	})
	popup_manager = PopupManager.new()
	popup_manager.name = "PopupManager"
	add_child(popup_manager)
	popup_manager.setup(pools[&"popup"])
	# 量级分级注入（P2）：单发基准供给（主武器面板 base_atk × crit_mult）+ 金档轻震动钩子
	#（trauma 复用既有 hit 档——GameFeelDirector.add_trauma_for_level(0)）
	popup_manager.baseline_provider = _popup_tier_baseline
	popup_manager.tier_shake_hook = func() -> void: game_feel.add_trauma_for_level(0)
	# 方向 C 元素签名特效层（连锁闪电/碎裂冲击环/DOT 火星；事件订阅在其 _ready 自挂）
	elemental_fx = ElementalFxLayer.new()
	elemental_fx.name = "ElementalFxLayer"
	add_child(elemental_fx)
	hud = HUD.new()
	hud.name = "HUD"
	add_child(hud)
	hud.setup(player)
	hud.bind_events()
	hud.pause_requested.connect(request_pause)   # 暂停按钮申请（仲裁权在 GameLoop）
	hud.build_details_requested.connect(_on_build_details)   # 左下角 → buff 详情（用户反馈）
	pause_overlay = PauseOverlay.new()
	pause_overlay.name = "PauseOverlay"
	add_child(pause_overlay)
	pause_overlay.resume_requested.connect(request_resume)
	pause_overlay.restart_requested.connect(restart_run)
	pause_overlay.menu_requested.connect(quit_to_menu)
	shop_ui = ShopUi.new()
	shop_ui.name = "ShopUi"
	add_child(shop_ui)
	shop_ui.closed.connect(request_resume)       # 出击 → LEVEL_UP → PLAYING（含宽限）
	wave_director.shop_requested.connect(_on_shop_requested)
	# R10 通关即结算：清完 final Boss 波 → 胜利结算（波次不再无限叠加；先于黑市消费连接
	# ——final 波清空优先结算，此时黑市店因 state 非 PLAYING 自动跳过）
	EventBus.wave_cleared.connect(_on_wave_cleared_victory)
	# REL_BLACK_MARKET 追加商店波消费（R10 重调 w8 起每 5 波——原 w35 起每 10 波在
	# 新阶梯下永不触发；兼做「Boss 前商店」§5.12 待办。连接序在 relic_handler 之后）
	EventBus.wave_cleared.connect(_on_relic_shop_wave)
	# 战前补给（R5.12-P1）：final Boss 波前一波清空 → 固定商店（不占波表 SHOP 位/黑市排程）
	EventBus.wave_cleared.connect(_on_wave_cleared_pre_boss_shop)
	# R7：波次清空 → 全屏经验碎片强制磁吸（Boss 大珠残留兜底）
	EventBus.wave_cleared.connect(_on_wave_cleared_collect)
	sfx = SfxBank.new()
	sfx.name = "SfxBank"
	add_child(sfx)
	EventBus.damage_resolved.connect(func(_r: DamageResult) -> void: sfx.play(&"hit"))
	EventBus.enemy_killed.connect(func(_e: Node2D) -> void:
		# G1：连杀音调爬升（每杀 +2% 音高，封顶 ×1.5——听觉上的 combo 档位）
		sfx.play(&"kill", minf(1.0 + float(_combo_count) * 0.02, 1.5)))
	EventBus.level_up.connect(func(_l: int) -> void: sfx.play(&"level"))
	EventBus.card_chosen.connect(func(_i: StringName, _k: int) -> void: sfx.play(&"coin"))
	# 玩家侧词条挂卡生效刷新（2026-09-13 死卡接线：AFF_PICKUP 磁吸 / AFF_SKILL_HASTE 技能急速）
	EventBus.card_chosen.connect(func(_i: StringName, _k: int) -> void:
		if player != null and is_instance_valid(player):
			player.refresh_pickup_radius()
			var cd_before: float = float(player.get("skill_cd_base"))
			player.refresh_skill_cd()
			var cd_after: float = float(player.get("skill_cd_base"))
			# R82 生效显形：技能急速/时之沙改动基线 → 横幅直给前后值（-12% 在 120s
			# 上要等下次施放才可见——用户实测「选了好像没用」，缺的是即时确认）
			if cd_before - cd_after >= 1.0:
				var toast_txt := "⚡ 冷却加速生效：%.0fs → %.0fs（技能急速/时之沙）" % [cd_before, cd_after]
				EventBus.emit_mechanics_intro(toast_txt))
	EventBus.shield_blocked.connect(func(_p: Vector2) -> void: sfx.play(&"shield"))
	# 二db M1：躲雷授盾轻提示（shield 同源 1.3 高调变体——与蓝盾挡下音区分解因果）
	EventBus.mine_dodged.connect(func(_p: Vector2) -> void: sfx.play(&"shield", 1.3))
	# c4① 掠过微光（二cp#1：无敌帧静默吞没零反馈——4s 内 80 发穿身敌弹仅 6 发落账）：
	# 玩家周身一次性池化粒子微光（W9 bullet_nullified 涟漪同族的一次性 FX 通道，AMBIENT
	# 档=满池最先被抢占；事件驱动一次性 + 发射侧 0.25s 节流，无逐帧分配）。headless
	# 无显示服务零副作用仅计数（测试回归面 r213_fullload/r202_perf 不涉 graze）。
	EventBus.graze.connect(_on_graze_feedback)
	# R83 导弹爆反馈：低音轰 + CRIT 级震屏（专用爆炸件配套——比普命中重一档；
	# 大范围爆（Boss 级 blast_r）低沉变调）
	# R94：星爆走 GameLoop 顶层（E3 升级波纹同通道，已验证可见）——不依赖特效层
	# R187 表现分档：小爆（blast_r<50，W6 L1 档）走 HIT 档震屏，≥50 保持 CRIT 档
	EventBus.missile_blast.connect(func(p_pos: Vector2, p_r: float) -> void:
		sfx.play(&"boom", 0.8 if p_r >= 100.0 else 1.0)
		game_feel.add_trauma_for_level(
			GameConst.FeelLevel.HIT if p_r < 50.0 else GameConst.FeelLevel.CRIT)
		BlastStarFx.spawn(self, p_pos, maxf(p_r, 60.0)))   # R253 池化发射口
	# R184 反弹音：子弹边界弹开清脆 tick（加特林+反弹词条下高频触发——节流走
	# SfxBank 既有 THROTTLE_MS，事件侧不自造节流）
	EventBus.bullet_bounced.connect(func(_p: Vector2) -> void: sfx.play(&"bounce"))
	EventBus.boss_spawned.connect(func(_b: Node2D) -> void: sfx.play(&"boss"))
	# 夜间R15：元素反应音（按反应类型分音色——碎裂/过载/超导）
	EventBus.reaction_triggered.connect(_play_reaction_sfx)
	EventBus.state_triggered.connect(_play_state_trigger_sfx)
	EventBus.boss_phase_changed.connect(_play_boss_phase_sfx)
	EventBus.elite_summon_requested.connect(_on_elite_summon)
	EventBus.boss_spawned.connect(_on_boss_spawned_track_summons)   # B4 召唤调度注册
	EventBus.wave_cleared.connect(_on_wave_cleared_bless_heal)   # 祝福·滋养（词缀二期）
	boss_bar = BossBar.new()
	boss_bar.name = "BossBar"
	add_child(boss_bar)
	hurt_indicator = HurtIndicator.new()         # F2：受击方向屏缘红弧（方向感补全）
	hurt_indicator.name = "HurtIndicator"
	add_child(hurt_indicator)
	game_over_screen = GameOverScreen.new()
	game_over_screen.name = "GameOverScreen"
	add_child(game_over_screen)
	game_over_screen.setup(hud)
	game_over_screen.restart_requested.connect(restart_run)
	game_over_screen.endless_continue_requested.connect(continue_endless)   # R62 通关屏无尽继续
	game_over_screen.menu_requested.connect(quit_to_menu)   # R13 结算屏回主菜单
	card_generator = CardGenerator.new()
	card_generator.setup(registry)
	shop_ui.card_generator = card_generator      # 黑市货架走同一条卡链（注入须在创建后）
	card_select_ui = CardSelectUI.new()
	card_select_ui.name = "CardSelectUI"
	add_child(card_select_ui)
	card_select_ui.choice_made.connect(_on_card_choice)
	card_select_ui.reroll_requested.connect(_on_card_reroll)   # 换一批仲裁（刷新机制）
	# R245 红卡大屏确认卡（选卡 UI 之后组装=同层绘制序在上；confirmed → 收口直通
	# _finish_card_choice——LEVEL_UP 保持/PLAYING 恢复/pending 续开/溢出批挂起全在收口内）
	sublime_confirm_ui = SublimeConfirmUI.new()
	sublime_confirm_ui.name = "SublimeConfirmUI"
	add_child(sublime_confirm_ui)
	sublime_confirm_ui.confirmed.connect(_finish_card_choice)
	# R251 需求③ 首遇介绍卡（敌/武器/反应三域统一弹卡；UI 自连 EventBus 零接线，
	# layer 50 高于 HUD——设计 §3.3）
	first_encounter_card_ui = FirstEncounterCardUI.new()
	first_encounter_card_ui.name = "FirstEncounterCardUI"
	add_child(first_encounter_card_ui)
	# R252 需求② 祝福（开局自选词条）面板（选图确认后 GameLoop 侧弹层；menu_screen
	# 归 R252-D 独占不动——SublimeConfirmUI 弹层先例。registry 注入供面板读词条名）
	blessing_pick_ui = BlessingPickUI.new()
	blessing_pick_ui.name = "BlessingPickUI"
	blessing_pick_ui.registry = registry
	# R258：★add_child 挪至 menu_screen 之后——修前面板先挂（本函数原位）被后挂的
	# 菜单整层盖住（菜单 root 不透明 bg）：面板自 R252 上线起真机/桌面均不可见，
	# is_open() 标志位测试假绿（vc65 真机日志定罪——事件网两对「选关出发钮+出发
	# 二次」=tap 穿透到菜单层）。绘制序=兄弟序后挂上层，面板必须后于菜单挂。
	blessing_pick_ui.confirmed.connect(_on_blessing_confirmed)
	blessing_pick_ui.dismissed.connect(_on_blessing_dismissed)
	blessing_pick_ui.cleared.connect(_on_blessing_cleared)   # R252-QA第1轮 B3：清除记忆→永久退出携带
	# R252-QA第1轮 B2：词条首获=新开局祝福解锁的局内反馈（Meta 只广播 id——registry
	# 在本侧，文本组装此处做；mechanics_intro toast 通道 = hud.gd:1106 金卡解锁播报
	# 同款先例，非阻塞不抢选卡窗）
	Meta.blessing_unlocked.connect(_on_blessing_unlock_note)
	# 集成包 A：震屏宿主相机（trauma² 偏移在 ⑧ raw 通道应用）+ 主菜单屏
	camera = Camera2D.new()
	camera.name = "Camera"
	camera.position = Vector2(GameConfig.balance.res_logic) * 0.5
	add_child(camera)
	camera.make_current()
	# R269 A-1：保帧分辨率 boot 期初应用（相机创建后——mobile 垫值默认开即生效；桌面
	# 默认关=关态零写点，§3.2「恒不被写」红线）+ 设置订阅热切（perf_boost/boost_res
	# 两键短路——设置行 cycle 写口即时应用/回退）
	_apply_boost_resolution()
	Meta.settings_changed.connect(_on_boost_setting_changed)
	# R269 修3（评审中#3）：mobile 首启垫值默认开的一次性告知——mechanics_intro 横幅
	# 既有通道（HUD 订阅 :3284 hud._ready 已挂，先于本点；desktop/headless 垫 0 恒返
	# 空串零触发——既有套件口径不动）
	var _boost_intro := Meta.consume_boost_intro()
	if not _boost_intro.is_empty():
		EventBus.mechanics_intro.emit(_boost_intro)
	menu_screen = MenuScreen.new()
	menu_screen.name = "MenuScreen"
	menu_screen.registry = registry             # 图鉴全量清单（大厅面板，用户反馈 M4+M6）
	add_child(menu_screen)
	add_child(blessing_pick_ui)                 # R258：面板后于菜单挂=画在菜单上（见上注）
	menu_screen.start_requested.connect(func() -> void: _on_menu_start(MapTable.FIRST_MAP_ID))
	menu_screen.start_map_requested.connect(_on_menu_start)   # 选图启动（M2 多地图）
	menu_screen.start_daily_requested.connect(_on_menu_start_daily)   # 每日挑战启动（P2）
	menu_screen.continue_requested.connect(continue_run)   # 继续上次进度（局内存档，2026-08-31）
	# P3 设置页（META_ROADMAP §5.10）：独立全屏面板（layer 10 盖过菜单/暂停卡），
	# 大厅按钮行 + 暂停卡「设置」双入口，纯 UI——打开/关闭不改 GameLoop 状态机
	# R252D P6：设置面板作用域批落盘——open 侧两入口改经具名回调先 begin（拖动滑条
	# 期间 set_setting 的 _save 被深度门抑制、应用即时不变），closed 信号 → end 统一
	# 落盘一次结清（14 步拖动 = 1 次写盘；回调具名非 lambda——信号连接纪律）
	settings_panel = SettingsPanel.new()
	settings_panel.name = "SettingsPanel"
	add_child(settings_panel)
	menu_screen.settings_requested.connect(_on_settings_open_defer)
	pause_overlay.settings_requested.connect(_on_settings_open_defer)
	settings_panel.closed.connect(_on_settings_closed_persist)
	# 仲裁订阅（E-16：死亡最高优先 / 升级弹卡排队）
	EventBus.player_died.connect(_on_player_died)
	EventBus.level_up.connect(_on_level_up)
	EventBus.level_up_batch.connect(_on_level_up_batch)
	# 每 5 波 +1 刷新次数（获取来源之二；连接序无 tags/状态依赖，位置不限）
	EventBus.wave_started.connect(_on_wave_started_reroll_grant)
	# R194 fx_opacity 单源应用器（fx 方案）：boot 末段初次应用（池已满量预热后）+ 设置页
	# 拖动实时应用（仿 SfxBank 先例）。应用体三单点：A 元素特效层根 modulate.a 罩全层
	# （ElementalFxLayer 全部池件为直接子嗣，子件渐隐与根 alpha 引擎级相乘）；B 粒子池
	# 子发射器 modulate.a（:1375 同款遍历——池满量预热、懒增长不可达无需钩子）；
	# C DamagePopup.fx_opacity static 折乘（helper 在 damage_popup.gd，本侧只写值）。
	# 只乘 alpha 永不写 visible（四层爆 visible==4 锁）；枪口星闪 TINT/色差链/弹体拖尾/
	# DeathPop/HUD 白闪/CloudBackdrop 等排除清单不接入（fx 方案排除清单）。
	_apply_fx_opacity()
	Meta.settings_changed.connect(_on_fx_opacity_setting_changed)
	# R195 适配底座：aspect=expand 超限钳制挂接（表现层窗口设置读写，零战斗依赖）
	_bind_stretch_aspect_clamp()


func _on_settings_open_defer() -> void:
	# R252D P6：设置面板 open → 批落盘开包络。is_open 守卫保证 begin/end 严格配对
	#（面板已开时的重复 settings_requested 不叠深度——防 end 单次收口后深度残留）
	if not settings_panel.is_open():
		Meta.begin_persist_defer()
	if menu_screen != null:
		menu_screen.set_settings_modal(true)    # R260 评审 MED-1：设置卡同款 Q 弹动画——模态期 menu 双泵挂起
	settings_panel.open()


func _on_settings_closed_persist() -> void:
	# R252D P6：设置面板 closed → end 统一落盘（open 侧唯一接线口径下深度恰 1，
	# 归零即 _save；崩溃窗口披露：面板开着被强杀丢面板内变更——已判定接受）
	if menu_screen != null:
		menu_screen.set_settings_modal(false)   # R260 评审 MED-1
	Meta.end_persist_defer()


func _bind_stretch_aspect_clamp() -> void:
	# R195：boot 挂接 + 初次评估。项目设置 aspect=keep（单行整体回退位）→ 不 armed，
	# 钳制函数全程零触发=现状黑边；aspect=expand → armed（含 boot 时已超限窗口的初次
	# 评估；headless 默认窗 ratio≈1.78 → 不变）。
	# ★ 引擎语义（4.3 headless 探针实证，矩阵套件驱动协议须知情）：
	# · aspect=EXPAND 态：窗口每次 resize 均发 Window.size_changed → 本钳制正常联动；
	# · aspect=KEEP 态：画布钉在 720×1280 基准，窗口 resize **不发** size_changed
	#   （待发信号在切回 EXPAND 时合并冲刷）——故 KEEP 回落后恢复评估走两条路：
	#   真机 OS resize 事件（NOTIFICATION_WM_SIZE_CHANGED 通知钩子）或套件直驱
	#   公开函数 apply_stretch_aspect_clamp()（幂等，无副作用可重入）。
	var win := get_window()
	if win == null:
		return
	_stretch_clamp_armed = win.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_EXPAND
	if not _stretch_clamp_armed:
		return
	apply_stretch_aspect_clamp()
	if not win.size_changed.is_connected(apply_stretch_aspect_clamp):
		win.size_changed.connect(apply_stretch_aspect_clamp)


func _notification(p_what: int) -> void:
	# R195：真机 KEEP 回落态下的 resize 重评估口（headless 脚本改 win.size 不走
	# DisplayServer 事件、本通知不触发=矩阵套件须直驱公开函数；真机折叠/分屏/拖窗
	# 走 OS 事件可达）。幂等纯评估，零分配
	if p_what == NOTIFICATION_WM_SIZE_CHANGED:
		apply_stretch_aspect_clamp()


func apply_stretch_aspect_clamp() -> void:
	# R195：钳制体（公开=矩阵套件可直驱；运行期 KEEP↔EXPAND 双向切换可逆——超限回落
	# KEEP 后，比例恢复正常即回 EXPAND）。纯枚举比较+一次浮点除，事件频率非每帧路径
	#（R188 纪律：零分配零轮询）；幂等（同值重写引擎不重发 size_changed，探针实证收敛 2 次）
	if not _stretch_clamp_armed:
		return
	var win := get_window()
	if win == null:
		return
	var w := float(win.size.x)
	var ratio := (float(win.size.y) / w) if w > 0.0 else 0.0
	win.content_scale_aspect = (Window.CONTENT_SCALE_ASPECT_KEEP
		if ratio > STRETCH_ASPECT_RATIO_MAX else Window.CONTENT_SCALE_ASPECT_EXPAND)


# ── R269 A-1：保帧模式分辨率降档应用器（§3.2——本模式最大 GPU 杠杆） ──
# 路径定案：Window.content_scale_size 降档（viewport 拉伸模式下根视口内部渲染分辨率=
# 本值——填充率 0.72×/0.56×）+ Camera2D.zoom 补偿（zoom<1 拉远——expand 下可见世界
# rect 数学上逐位还原 720×~1559；出生点/场地/反弹沿全在世界域零变化）。桌面 Vulkan
# 真窗口热切实测通过（分析轮收录）；Android GLES3 真机冒烟四项为 P0 硬门（§3.2）。
var _boost_applied_notch: int = 0            # R269：已应用档（0=关基线态 720×1280+zoom1——
                                             # boot 即真；关态恒不写，§3.2 红线）
static var _s_boost_applied_notch: int = 0   # R270：已应用档静态镜像（boost_world_div 单源——
                                             # 设置开但非活战态已回退时，云补偿除数须与画布一致）


static func _boost_target_scale(p_notch: int) -> Vector3:
	# R269：notch → (宽, 高, zoom) 数学（纯函数可测，§5-a6）：1（85 档）→ (612,1088,0.85)
	# = round(720×0.85)×round(1280×0.85)；2（75 档）→ (540,960,0.75)；0（关）→ (720,1280,1.0)。
	# 两开档保 0.5625 纵横比整尺寸（720/1280=612/1088=540/960）。
	match p_notch:
		1:
			return Vector3(612.0, 1088.0, 0.85)
		2:
			return Vector3(540.0, 960.0, 0.75)
	return Vector3(720.0, 1280.0, 1.0)


static func boost_world_div() -> float:
	# R269：世界域铺展补偿分母（cloud_backdrop 铺云域 ÷ 本值——get_visible_rect 在
	# content_scale_size 降档后=坐标空间≠可见世界，除回原域）：boost 关=1.0（x/1.0
	# 浮点恒等 → r195_adapt 逐位不变）；开=zoom 分母（0.85/0.75）。
	# R270 修复①：改读已应用档镜像——设置开但 MENU/GAME_OVER 态已回退 720×1280 时
	# 除数必须同为 1.0（读设置会让菜单云域 ÷0.85 超铺 17%）。
	match _s_boost_applied_notch:
		1:
			return 0.85
		2:
			return 0.75
	return 1.0


func _boost_live_state() -> bool:
	# R270 修复①：分辨率降档仅活战态（世界活动画面——PLAYING/PAUSED/LEVEL_UP）；
	# MENU/GAME_OVER/BOOT 恒全分辨率：菜单与结算 UI 按 720×1280 布点，612×1088/540×960
	# 画布下溢出被裁（vc79 真机「主页分辨率乱、按钮显示不全」根因——zoom 补偿只救
	# Camera2D 世界视图救不了 Control 布局）。菜单渲染负载本就低（fps 108-120）无需降档。
	return state == GameConst.GameStatus.PLAYING \
		or state == GameConst.GameStatus.PAUSED \
		or state == GameConst.GameStatus.LEVEL_UP


func _apply_boost_resolution() -> void:
	# R269：应用器单点（幂等——同档重入零写；boost_override 注入态亦走本口=测试可直驱）。
	# 回退=关模式即回 720×1280 + zoom 1.0（单函数单点，§6 回滚共用开关）。桌面默认关 →
	# content_scale 与 camera.zoom 恒不被写（含 headless 全部既有套件）。
	# R270 修复①：生效条件加活战态门（_boost_live_state）——非活战态一律回退档 0。
	var notch := 0
	if PerfGovernor.boost_mode() and _boost_live_state():
		notch = 1 if PerfGovernor.boost_res_notch() == 85 else 2
	if notch == _boost_applied_notch:
		return                              # 同档零写（关态首调亦零写——_boost_applied_notch 初值 0）
	var t := _boost_target_scale(notch)
	# R270 修P2（评审高）：镜像先于视口写——content_scale_size 赋值同步发射 viewport
	# size_changed（cloud 铺域 handler 即时读 boost_world_div 除数），镜像晚写=信号期
	# 读到旧档（战斗侧云右缘欠铺 15%/结算侧超铺 17.5%）。
	_s_boost_applied_notch = notch
	var win := get_window()
	if win != null:
		win.content_scale_size = Vector2i(int(t.x), int(t.y))
	if camera != null:
		camera.zoom = Vector2(t.z, t.z)
	_boost_applied_notch = notch


func _on_boost_setting_changed(p_key: String) -> void:
	# R269：设置行写口 → 即时热切（仅两键短路，其余键零成本——_on_fx_opacity_setting_changed 先例）
	if p_key == "perf_boost" or p_key == "boost_res":
		_apply_boost_resolution()


func _apply_fx_opacity() -> void:
	# R194：特效透明度应用体（读口 Meta.settings；归一/钳制真源在 Meta 写口——本侧
	# 同域 clampf 仅防串档，读口缺键回默认 1.0 = 恒等）
	var raw: Variant = Meta.settings("fx_opacity")
	var f := 1.0
	if raw != null:
		f = clampf(float(raw), 0.3, 1.0)
	if elemental_fx != null:
		elemental_fx.modulate.a = f             # A) 层根罩全层
	for emitter in (pools[&"particle"] as ParticlePool).get_children():
		var gp := emitter as GPUParticles2D
		if gp != null:
			gp.modulate.a = f                   # B) 粒子池子发射器（池件为场景根直挂，无脚本侧 modulate 写点）
	DamagePopup.fx_opacity = f                  # C) 跳字折乘（tick/_reset_state 消费，防池复用首帧闪帧）


func _on_fx_opacity_setting_changed(p_key: String) -> void:
	# R194：设置页「特效透明度」写口 → 实时应用（仅本键短路，其余键零成本）
	if p_key == "fx_opacity":
		_apply_fx_opacity()


# ── 帧序支撑 ──────────────────────────────────────────────────────
func _popup_tier_baseline() -> float:
	# 跳字量级分级基准（P2 口径真源）：主武器（槽 0）面板 base_atk × crit_mult——
	# 单发基准伤害，稳定不受瞬时乘区/易伤波动影响；主武器缺失/面板 0 → 0（分级安全关闭）
	if player == null or not is_instance_valid(player) or player.weapon_slots.is_empty():
		return 0.0
	var w: WeaponBase = player.weapon_slots[0]
	if w == null or not is_instance_valid(w):
		return 0.0
	var panel := w.build_panel_snapshot()
	return float(panel.get("base_atk", 0.0)) * float(panel.get("crit_mult", 2.0))


func _on_wave_started_reroll_grant(p_wave: int) -> void:
	# 波次里程碑授予（选卡刷新机制「获取或许次数」方向）：每 5 波 +1 换一批次数
	#（MENU 态回流的 wave_started 不存在——⑥ 波次推进仅 PLAYING 驱动；防御性判 player）
	# R75 音乐强度档：w1-4 pad+贝斯 / w5-9 +琶音 / w10+ +踩镲（Boss 战鼓独立叠加）
	if sfx != null:
		sfx.bgm_set_intensity(0 if p_wave < 5 else (1 if p_wave < 10 else 2))
	if p_wave > 0 and p_wave % 5 == 0 and player != null and is_instance_valid(player):
		player.reroll_charges += 1
		EventBus.emit_reroll_granted(1)
	# 局内存档自动落盘（波次边界粒度——2026-08-31 用户反馈「继续上次进度」）：
	# 仅 PLAYING 存活期写（死亡波的 wave_started 早于 player_died，但死亡时
	# _on_player_died 的 clear 在其后执行——最终态正确为无档）
	if state == GameConst.GameStatus.PLAYING and player != null and is_instance_valid(player) \
			and float(player.get("hp")) > 0.0:
		RunSave.save_run(serialize_run())


# ── 局内存档（RunSave 单槽：序列化 / 继续 / 恢复） ──────────────────
func serialize_run() -> Dictionary:
	# 本局快照（波次边界口径）：地图/波次/玩家数值/武器构筑（词条层数）/刷新态
	if player == null or not is_instance_valid(player):
		return {}
	var weapons: Array[Dictionary] = []
	for w in player.weapon_slots:
		if w == null or not is_instance_valid(w):
			continue
		var traits: Array[Dictionary] = []
		if w.trait_stack != null:
			for mounted in w.trait_stack.traits:
				if mounted.data != null:
					# R262b M1：补落逐层品级——原快照只落 {id,layers}，continue_run 逐层
					# 重挂注册表基准 .tres，混合品级词条全部静默降回基准值（例：白+金双
					# 护盾充能 2.12s→5.5s）。lv=ADD 逐层值/lr=ADD 逐层品级/dv·dr=当前定义
					# 值与品级（MULT/ELE 取优定义真源）；纯基本类型 ConfigFile 透传；
					# 旧档无键走 get 默认（基准口径零迁移）。
					traits.append({"id": String(mounted.data.id), "layers": mounted.layers,
						"lv": mounted.layer_values.duplicate(),
						"lr": mounted.layer_rarities.duplicate(),
						"dv": float(mounted.data.value), "dr": int(mounted.data.rarity)})
		var wid := &""
		if w.data != null:
			wid = StringName(String(w.data.id))
		weapons.append({"id": String(wid), "level": int(w.level), "traits": traits})
	# R198（二aw-1）：遗物随档（修复「继续局丢遗物」——存档 17 键原无 relics，继续后
	# owned 空白）。纯基本类型容器（String id），RunSave ConfigFile 透传无擦写。
	var relics: Array[Dictionary] = []
	if relic_handler != null and is_instance_valid(relic_handler):
		for r in relic_handler.owned:
			if r != null:
				relics.append({"id": String(r.id)})
	# R246 技能升华随档（本局语义——继续局保持升华态）→ R247 终修单源化：改走
	# player.resonance_snapshot() 同构口（player.gd:1740——键 {on, fission_layers}
	# 唯一权威源，消除此处 duck 读口手组第二源漂移风险，card_generator 预热变体
	# 同款单源惯例）；skills 泳道未合入期 duck 手组兜底保留（守卫语义不变）。
	var sublime_snap := {}
	if player.has_method(&"resonance_snapshot"):
		sublime_snap = player.resonance_snapshot()
	else:
		var reson_v: Variant = player.get("_reson_layers")
		sublime_snap = {
			"on": bool(player.get("skill_sublime")),
			"fission_layers": maxi(int(reson_v), 0) if reson_v is int else 0,
		}
	return {
		"map_id": String(current_map_id),
		"difficulty": _difficulty,               # R72：继续局保持难度档
		"daily": Meta.is_run_daily(),
		"wave": maxi(wave_director.current_wave, 1),
		"kills": hud.kills,
		"elapsed": hud.run_elapsed,
		"character": String(player.character_id),
		"level": player.level,
		"xp": player.xp,
		"hp": player.hp,
		"max_hp": player.max_hp,
		"gold": player.gold,
		"rerolls": player.reroll_charges,
		"skill_cd": player.skill_cd_left,      # R212：技能冷却随档（修复「回主菜单再继续，技能被刷新」）
		"revives": maxi(player.revives_left, 0),   # 需求④：复活次数随档（快照值已含难度附赠）
		"free_reroll": not _free_reroll_used,
		"unlocked_slots": player.unlocked_slots,
		"slot_bonus": player.slot_bonus,          # R185 金卡解锁计数落档（不再参与有效帽）
		"weapons": weapons,
		"relics": relics,                          # R198（二aw-1）：遗物 id 集随档
		"sublime": sublime_snap,                   # R246：技能升华态随档（单键 {on, fission_layers}）
		"fallback_atk": clampf(float(player.get("run_fallback_atk_pct")), 0.0, 99.0),   # R262d：应急强化全局累计随档
		"blessing_paid": _run_blessing_paid,   # R263 修轮（评审-1）：已购祝福位随档——跨进程「继续→重开」链恢复
	}


func continue_run() -> bool:
	# MENU → PLAYING（继续上次进度，2026-08-31 用户反馈）：读 RunSave → 恢复地图/词缀/
	# 玩家构筑/波次。无档/坏档 → false（菜单「继续」入口本就只在有档时可见，此处为兜底）
	if state != GameConst.GameStatus.MENU:
		return false
	var data := RunSave.load_run()
	if data.is_empty():
		return false
	var map_id := StringName(String(data.get("map_id", "")))
	if MapTable.get_map(map_id).is_empty():
		RunSave.clear()
		return false
	current_map_id = map_id
	_difficulty = clampi(int(data.get("difficulty", 0)), 0, 2)   # R72 继续局保持难度档
	if not change_state(GameConst.GameStatus.PLAYING):
		return false
	PerfGovernor.notify_new_run()             # R222 Fix G：继续存档=新局（正信号重臂）
	PopupGlyphAtlas.ensure_runstart_bake()    # R227：位图激活兜底（同 start_run 口）
	# R198（R192-low4）：继续局进局路径同样复位告警双闸（与 start_run 同口径）
	if pipeline != null and pipeline.has_method(&"reset_run_alarms"):
		pipeline.call(&"reset_run_alarms")
	wave_director.wave_table = MapTable.load_table(current_map_id, registry)
	_reorder_tex_prewarm_wave_first()     # R267 刀P1：波表 roll 后队列波序重排（continue_run）
	spawner.difficulty = _difficulty
	wave_director.difficulty = _difficulty       # R72 继续局保持织入口径
	player.set_difficulty(_difficulty)             # R73 继续局保持风险回报
	elemental.clear_reaction_mults()             # R183 反应乘区局清空（恢复流程武器重建 uid 全换，重挂卡自然重注册）
	Meta.set_run_difficulty(_difficulty)           # E11：继续局结算分档
	Meta.set_run_map(current_map_id)
	var is_daily := bool(data.get("daily", false))
	Meta.set_run_daily(is_daily)
	card_generator.rng.randomize()            # 继续局卡池重新随机（存档不含 RNG 状态）
	card_generator.reseed_sublime()           # R246 继续局红色传说流重掷（存档不含 RNG 状态同口径）
	var map_def := MapTable.get_map(current_map_id)
	_apply_map_affixes(map_def)               # 词缀恢复（每日局：地图词缀后再施当日三词缀）
	if is_daily:
		_reset_affixes()
		var affixes := Meta.daily_affixes(Meta.daily_date_key())
		_apply_affix_ids(affixes.get("curses", []), StringName(String(affixes.get("bless", ""))))
	if _backdrop != null:
		_backdrop.modulate = map_def.get("tint", Color.WHITE)
	hud.set_map_name(("每日挑战 · " if is_daily else "") + String(map_def.get("name", ""))
		+ ("" if _difficulty == GameConst.Difficulty.NORMAL
			else " · %s" % GameConst.difficulty_name(_difficulty)))
	_append_difficulty_intro_lines()             # R253（二dc M4 缓办清账）：续局补发难度横幅（原仅 start_run 路径有——continue 玩家无从得知本局武器门档位）
	if not _run_intro_lines.is_empty():
		EventBus.emit_mechanics_intro("\n".join(_run_intro_lines))
		_run_intro_lines.clear()
	_restore_run_state(data)
	# R263 修轮（评审-1）：已购祝福位随档恢复——跨进程链「暂停退出→（杀进程重进）→
	# 继续→死亡→再来一局」中若丢 _run_blessing_paid（新实例恒 false），重开走未购
	# 路径=已购祝福静默蒸发（30/50 星尘买的效果消失无提示）。旧档无键 → false
	#（R263 前存档从未扣费，重开不白捡口径不变）。
	if data.has("blessing_paid"):
		_run_blessing_paid = bool(data.get("blessing_paid", false))
	if data.has("revives"):
		# 需求④：复活次数随档恢复（快照值已含难度附赠——set_character 已重置为养成
		# 应急协议口径，此处整值覆写；防「用掉→暂停→继续」无刷回满的复活套利）
		player.revives_left = maxi(int(data.get("revives", 0)), 0)
	else:
		player.revives_left += GameConst.difficulty_revives(_difficulty)   # R72 旧档无键：难度复活随恢复补齐（兼容口径）
	# R62：恢复档波次已过 final_wave → 无尽局续打（波次徽标切无尽口径）
	var final_wave := int(MapTable.get_map(map_id).get("final_wave", 1 << 30))
	var resume_wave := maxi(int(data.get("wave", 1)), 1)
	_endless_mode = resume_wave > final_wave and not is_daily
	hud.endless_depth_base = final_wave if _endless_mode else 0
	wave_director.start_wave(resume_wave)
	hud.kills = int(data.get("kills", 0))
	hud.run_elapsed = float(data.get("elapsed", 0.0))
	hud.refresh_stats()
	return true


func _restore_run_state(p_data: Dictionary) -> void:
	# 快照 → 玩家/构筑恢复：清场（Quit 后本就干净——防御再清）→ 重建武器（id/等级/
	# 词条层数）→ 数值覆写（顺序敏感：set_character 与词条挂载都会改 max_hp/gold，
	# 覆写必须在其后）
	_clear_battlefield()
	for i in range(player.weapon_slots.size()):
		var w: WeaponBase = player.weapon_slots[i] if i < player.weapon_slots.size() else null
		if w != null and is_instance_valid(w):
			w.queue_free()
		player.weapon_slots[i] = null
	# R185：slot_bonus 恢复（仅计数，不参与有效帽）；旧档 unlocked（=1 时代）抬到当前难度默认
	#（否则第 2 把武器重建被「槽未解锁」拒绝后 break 静默丢构筑——QA BUG-3）
	player.slot_bonus = clampi(int(p_data.get("slot_bonus", 0)), 0, 99)
	player.unlocked_slots = clampi(
		maxi(int(p_data.get("unlocked_slots", 1)), GameConst.difficulty_slot_default(_difficulty)),
		1, player.slot_cap_total())
	# 武器重建（空表 → 首发仲裁兜底，恒有槽 0 武器；R186：必须传快照角色——
	# :1305 才恢复角色，读 Meta.character_id 会装错）
	var weapons: Array = p_data.get("weapons", [])
	# R262d：旧档武器栈内 FALLBACK_ATK 词条（vc71 前挂单武器栈时代）迁移收集——运行期
	# 构造不进注册表（E-08），registry.get_trait 恒 null 原路径直接丢层；改按快照逐层值
	# 求和转入全局累计（lv 空旧旧档按 dv×layers 兜底）。时序：先局部收集，set_character
	# 复位清零后再与顶层键合并回填（weapons 重建在 set_character 之前，注入需重推）。
	var migrated_fallback := 0.0
	if weapons.is_empty():
		_equip_starting_weapon(StringName(String(p_data.get("character", "sentinel"))))
	else:
		for entry_v: Variant in weapons:
			var entry: Dictionary = entry_v if entry_v is Dictionary else {}
			var wdata := registry.get_weapon(StringName(String(entry.get("id", ""))))
			if wdata == null:
				continue
			var weapon := player.add_weapon(wdata)
			if weapon == null:
				break                          # 槽满（快照异常防御）：后续武器丢弃
			for i in range(maxi(int(entry.get("level", 1)) - 1, 0)):
				weapon.level_up()             # 等级恢复（含 Lv5 终极形态播报的幂等短路）
			var traits: Array = entry.get("traits", [])
			for trait_v: Variant in traits:
				var tr_entry: Dictionary = trait_v if trait_v is Dictionary else {}
				var tdata := registry.get_trait(StringName(String(tr_entry.get("id", ""))))
				if tdata == null:
					# R262d：旧档 FALLBACK_ATK 词条迁移（vc71 前挂单武器栈）——逐层求和
					# 转全局累计，静默不弹横幅（继续局还原语义）；其余未知 id 维持丢弃
					if String(tr_entry.get("id", "")) == "FALLBACK_ATK":
						var lv_old: Array = tr_entry.get("lv", [])
						if not lv_old.is_empty():
							for v_old in lv_old:
								migrated_fallback += maxf(float(v_old), 0.0)
						else:
							migrated_fallback += maxf(float(tr_entry.get("dv", 0.0)), 0.0) \
								* float(maxi(int(tr_entry.get("layers", 1)), 1))
					continue
				# R262b M1：品级恢复——lv 非空=ADD 逐层按快照值/品级重挂副本；
				# lv 空但 dv≠基准=MULT/ELE 取优定义回放；全基准（旧档/纯白）零副本直挂。
				# duplicate 隔离：绝不直改注册表基准 .tres（E-08）。逐层 attach 中消费端
				# 重扫自然重触发满层质变（value_mult=MILESTONE，S2 支线同路闭合）。
				var lv: Array = tr_entry.get("lv", [])
				var lr: Array = tr_entry.get("lr", [])
				var dv := float(tr_entry.get("dv", float(tdata.value)))
				var dr := int(tr_entry.get("dr", int(tdata.rarity)))
				for i in range(maxi(int(tr_entry.get("layers", 1)), 1)):
					if lv.is_empty() and is_equal_approx(dv, float(tdata.value)) \
							and dr == int(tdata.rarity):
						weapon.attach_trait(tdata)
						continue
					var t_copy: TraitData = tdata.duplicate()
					if not lv.is_empty() and i < lv.size():
						t_copy.value = float(lv[i])
						if i < lr.size():
							t_copy.rarity = int(lr[i])
					else:
						t_copy.value = dv
						t_copy.rarity = dr
					weapon.attach_trait(t_copy)
	# R198（二aw-1）：遗物恢复（修复「继续局丢遗物」）——activate 幂等（has_relic 拒重；
	# 时序：进局路径 _reset_run_state 已清 owned〔boot setup / restart / quit_to_menu〕，
	# 此处必在其后=安全）。旧档无 relics 键 → get 默认空表，零分支兼容。
	# 位置注记（R198 实现裁定）：激活放「武器重建后、数值覆写前」——REL_EF_GLASS 的一次性
	# max_hp −25% 代价在存档时刻已折入快照（存档值即已减 25% 的终值），覆写在后直接还原
	# 快照值；若按「覆写完成后」激活会二次扣 25%（恢复语义=还原存档时刻状态）。
	# REL_EF_ATTACK_CDR 常驻位 _apply_passive 自拉满每击谐振预算存款（relic_handler.gd
	# _attack_cdr_bank_cap），REL_EF_SKILL_HASTE 的 skill_cd_relic_mult 不被 set_character
	# 触碰（player.gd set_character 只复位 comp_rof_mult）——两常驻位先于此处生效均正确。
	var relics: Array = p_data.get("relics", [])
	for relic_v: Variant in relics:
		var r_entry: Dictionary = relic_v if relic_v is Dictionary else {}
		var rid := StringName(String(r_entry.get("id", "")))
		if not rid.is_empty() and relic_handler != null:
			relic_handler.activate(rid)
	# 数值覆写（后置：set_character / 词条挂载的 max_hp / gold / 刷新次数均被快照覆盖）
	player.set_character(StringName(String(p_data.get("character", "sentinel"))))
	player.level = maxi(int(p_data.get("level", 1)), 1)
	player.xp = maxf(float(p_data.get("xp", 0.0)), 0.0)
	player.xp_need = player.call(&"_xp_need_for", player.level)
	player.max_hp = maxf(float(p_data.get("max_hp", player.max_hp)), 1.0)
	player.hp = clampf(float(p_data.get("hp", player.max_hp)), 1.0, player.max_hp)
	player.gold = maxi(int(p_data.get("gold", 0)), 0)
	player.reroll_charges = maxi(int(p_data.get("rerolls", 0)), 0)
	# R212：技能冷却随档恢复（用户 bug「返回主菜单再回到游戏，角色技能被刷新」——根因：
	# set_character 内 player.gd:494 skill_cd_left=0.0，快照原无此键，恢复后技能立即可用）。
	# 位置必须在 set_character 之后（其内部清零 + refresh_skill_cd 已按重建后的词条/遗物
	# 定好 skill_cd_base 基线）；clamp 到该基线防脏档超界。旧档无键 → 0，保持原行为零迁移。
	player.skill_cd_left = clampf(float(p_data.get("skill_cd", 0.0)), 0.0, player.skill_cd_base)
	# R246 技能升华随档恢复（本局语义）：位置必须在 set_character 之后（skills 泳道复位
	# 区清 skill_sublime=false——player.gd:44 注释「继续局回填在 set_character 之后执行
	# 天然不冲突」同口径，与 skill_cd 同位）。enable_sublime 幂等（has_method 鸭子守卫，
	# skills 泳道未合入期零崩溃）；fission 本命同调层数经专用 restore 口回填
	#（_reson_layers 私有位 duck set，clamp 0..500 帽）。旧档无 sublime 键 → 不动零迁移。
	var sublime_snap: Dictionary = p_data.get("sublime", {}) if p_data.get("sublime", {}) is Dictionary else {}
	if bool(sublime_snap.get("on", false)) and player.has_method(&"enable_sublime"):
		player.call(&"enable_sublime")
		if player.get("_reson_layers") is int and sublime_snap.has("fission_layers"):
			player.set("_reson_layers",
				clampi(int(sublime_snap.get("fission_layers", 0)), 0, 500))
	# R262d 应急强化全局累计随档：顶层键 + 旧档武器栈词条迁移量合并回填（位置必须在
	# set_character 之后——其复位区清零；重推走 _apply_resonance(-1) 静默口覆盖全部
	# 已重建武器的 meta_atk_pct 注入）。旧档无键 → 0，零迁移。
	player.run_fallback_atk_pct = clampf(
		float(p_data.get("fallback_atk", 0.0)) + migrated_fallback, 0.0, 99.0)
	player.call(&"_apply_resonance", -1)
	_free_reroll_used = not bool(p_data.get("free_reroll", false))
	player.invuln_left = RESUME_GRACE_S          # 继续局保护帧（重开同口径）
	player.input_enabled = true
	pending_level_ups = 0
	merged_overflow_level_ups = 0               # R188-perf：连升合并溢出批随续档清
	_deferred_level_open = -1                   # R215 刀A：延迟开窗档随局清（防跨局陈旧档）
	if _merged_overflow_draining:
		_merged_overflow_draining = false         # R189：分帧消化批中断——抑制态强制结清
		Meta.cancel_persist_defer()
	_auto_card_left = -1.0                      # R188-idle：挂机挂起窗全清
	_auto_shop_left = -1.0
	_auto_restart_left = -1.0
	_auto_card_shown_index = -1
	_auto_card_retries = 0
	_reset_separation_wheel()
	resume_grace_left = 0.0
	set_time_scale(1.0, &"continue")
	if sfx != null:
		sfx.bgm_set_boss_layer(false)             # 恢复期无 Boss 存活（波次重开）


func _on_boss_killed_bgm(p_enemy: Node2D) -> void:
	# Boss 击杀 → BGM 战鼓层收起（tags 判定；连接序先于 spawner 归还清零——2026-08-31
	# 修复：连接已前置至 actors 段）+ 刷新次数 +1（选卡刷新机制的「获取」来源之一）。
	# 位运算次序：先归一取值再 & TAG_BOSS——旧写法把 `& TAG_BOSS` 挂在三元 else 分支的
	# 字面量 0 上（优先级陷阱），真实 tags 整值放行：精英击杀被当 Boss，刷新次数经济被
	# 系统性灌水 + 战鼓层误收
	var tags: int = int(p_enemy.get("tags")) if p_enemy.get("tags") != null else 0
	var is_boss := (tags & GameConst.TAG_BOSS) != 0
	if sfx != null and is_boss:
		sfx.bgm_set_boss_layer(false)
	if is_boss and player != null and is_instance_valid(player):
		player.reroll_charges += 1
		EventBus.emit_reroll_granted(1)


func _tick_projectiles(p_gd: float) -> void:
	# 投射物逐弹 tick（R220 刀8④ 起 release 为 O(1) swap-remove——tick 遍历走快照缓冲
	# 防「尾元素移入当前槽」的重入错位；快照同时承担刀9 team 分区）
	_tick_one_pool(_projectile_pool, p_gd)
	_tick_one_pool(_homing_pool, p_gd)


# ── R285 T1/T3：boost 网格命中对缓冲 + 死亡冲刷队列（帧头 clear 复用零分配——
#    R188 档0 纪律；三平行成员缓冲消除逐对 Dictionary/对象分配） ─────────
# 静态化注记（实现层对设计 §3.1.6「成员缓冲」的一处形变，机制等价）：GDScript 禁止
# 以 `GameLoop.xxx` 类名语法调用实例方法（弹/敌热路径收集段/入队口唯一可用的调用
# 形态），故缓冲与冲刷函数落 static——与 R223 pool_valve_override / 本批两门同构的
# 静态注入口先例；零分配/帧头清/快照冲刷语义逐字保留（生产单实例，测试双 boot 经
# 帧头清/兜底冲刷天然复位）。
static var _hp_proj: Array[ProjectileBase] = []   # 命中对：弹（tick 序收集自然序）
static var _hp_target: Array[Node2D] = []         # 命中对：目标（格行主序×桶内插入序候选）
static var _hp_serial: PackedInt32Array = []      # 命中对：落对时弹的 run_serial（序守卫）
static var _death_queue: Array[Enemy] = []        # T3 死亡冲刷队列（FIFO=死亡发生序）


static func append_hit_pair(p_proj: ProjectileBase, p_target: Node2D) -> void:
	# R285 T1：收集段落对口（projectile_base._collect_hit_pairs 窄相通过者调用——
	# 不结算不派发，④ 尾 _flush_hit_pairs 统一提交）。
	_hp_proj.append(p_proj)
	_hp_target.append(p_target)
	_hp_serial.append(p_proj.run_serial)


static func _flush_hit_pairs() -> void:
	# R285 T1 冲刷段：④ 尾按「弹 tick 序×格行主序×桶内插入序」统一提交 _submit_hit
	#（提交链零改动——帧聚合/生命周期去重/反弹盾/回旋 ICD/词条/管线/暴击/附着/穿透/
	# 回收全在原函数内）。冲刷段以冲刷开始时的对数快照为准（段内不会再落对——击杀爆
	# AOE 走 settle_aoe 直结算不入对；防御口）。关态恒空直返（零遍历）。
	var n0 := _hp_proj.size()
	if n0 == 0:
		return
	var timed := prof_buckets_frame
	if timed:
		DebugStats.bucket_begin(&"hit_flush")     # R285 P0：提µs（提交链——R286 行键名，避撞 R232 结µs）
	for i in range(n0):
		var proj: ProjectileBase = _hp_proj[i]
		# R285 序守卫：冲刷中段弹被回收（pierce 耗尽 _recycle）→ 同节点可能被 FRACTAL
		# 子代 pool.acquire 复用（projectile_base.request_split）——serial 变/失活即跳过
		# 该弹剩余对（等价关态 _check_collision 的 `if not _live: break`，防幻影对以
		# 「子代身份」误结算）。
		if not is_instance_valid(proj) or not proj._live or proj.run_serial != _hp_serial[i]:
			continue
		proj._submit_hit(_hp_target[i])
	hit_pairs_flushed += n0
	_hp_proj.clear()
	_hp_target.clear()
	_hp_serial.clear()
	if timed:
		DebugStats.bucket_end(&"hit_flush")


static func enqueue_death(p_enemy: Enemy) -> void:
	# R285 T3：死亡 fan-out 入队口（enemy._on_died 死亡冲刷模式调用——FIFO=死亡序）。
	_death_queue.append(p_enemy)


static func _flush_deaths() -> void:
	# R285 T3 冲刷段（〔v2·M3〕快照计数制）：只处理冲刷开始时已在队的快照段 n0——
	# 冲刷期间新入队（防御面）不顺延执行、留给下一冲刷点（⑤尾）或帧末兜底点吸收
	#（同帧闭合，循环有界、读数确定）。逐敌 is_instance_valid ∧ dead ∧ 非 in-pool
	# 复验（防看门狗/其他路径先行归还后误 fan-out——in-pool meta 直读 ObjectPool 真源）。
	var n0 := _death_queue.size()
	if n0 == 0:
		return
	for i in range(n0):
		var e: Enemy = _death_queue[i]
		if is_instance_valid(e) and e.dead \
				and not bool(e.get_meta(ObjectPool._META_IN_POOL, false)):
			e._death_fanout()
	deaths_flushed += n0
	if _death_queue.size() == n0:
		_death_queue.clear()                # 常态：冲刷期零入队——O(1) 清空
	else:
		# 防御面：冲刷期再入队——保留新段（FIFO 尾段原样），当帧兜底点吸收
		var tail: Array[Enemy] = []
		tail.assign(_death_queue.slice(n0))
		_death_queue = tail


# R220 刀9 分区开关（false=原统一 tick 路径——快照缓冲迭代但全走 proj.tick 慢路径）
const ENEMY_BULLET_FAST_PATH := true
# R231 刀B 分区开关（true=team0 直线池 _pfast 弹走 _tick_fast_player 内联快路径；
# false=全量回落 proj.tick 慢路径）。回退口兼同进程 A/B 测试口——R223
# pool_valve_override / R223 settle_budget_override 静态注入先例（const 无法运行时
# 翻转，T5 开关双跑全等 / T6 同进程仲裁需要）；测试翻转后必须复位 true（teardown 纪律）。
static var PLAYER_BULLET_FAST_PATH := true
# 分区复用缓冲（成员级零每帧分配；顺序=active_projectiles 快照序，倒序驱动保持
# 原统一倒序 tick 的组内时序——同组内先 spawned 后驱动）
var _proj_slow_buf: Array[Node2D] = []         # team0 非 pfast / team1 非 fast 弹（走 proj.tick 慢路径）
var _proj_fast_buf: Array[Node2D] = []         # team1 且 _fast_path（走 _tick_fast 直排）
var _proj_pfast_buf: Array[Node2D] = []        # R231 刀B：team0 且 _pfast（走 _tick_fast_player 直排）
var _pfast_live: int = 0                       # R231 刀B：当帧 pfast 分区计数（诊断快N 采样源——
                                               # _proj_pfast_buf 为帧内瞬态缓冲，1Hz 诊断拉取须读成员计数）


func _tick_one_pool(p_pool: ProjectilePool, p_gd: float) -> void:
	# R94：投射物逐弹 tick 抽出（弹道/追踪双池同驱动）。
	# R220 刀9：每步一次 O(n) 分区到复用缓冲——team1 且弹侧 spawn 期已缓存 _fast_path
	# 的敌弹走 ProjectileBase._tick_fast 内联快路径（直线+寿命+出界+撞玩家四断言，跳过
	# converge steer/双重 edge bounce/_sync_visual floorf/ON_TICK 闸——逐项 no-op 证据
	# 见 projectile_base._tick_fast 头注；敌弹仅 enemy.gd:1006-1014/:1581-1587 两处
	# spawn 点、参数最小已核实）；team0 与不满足快路径判据的弹照走原 tick 序列。
	# R231 刀B：三缓冲分区——team0 直线池且 spawn 期（ON_SPAWN 派发后）缓存 _pfast 的
	# 玩家弹走 _tick_fast_player（寿命+hits clear+直线+range 超程+出界五断言+接触预检
	# 回落 _check_collision 全链——伤害/词条/穿透链零改动，跳过项 no-op 证据见 spawn 尾部
	# 判据清单）。pfast 池判据=p_pool==_projectile_pool（homing 池 _move 覆写有转向/重索敌，
	# 池判据排除——分析 AC-6）。
	# R220 刀8④：遍历用快照缓冲（非直接迭代 _active_list）——release 已改 O(1)
	# swap-remove，tick 内回收（自身/它弹）不再移动未遍历元素，单帧每活弹恰 tick 一次；
	# tick 期内新 spawn（分裂子代/敌弹）只追加 active 表不入快照 → 出生帧不 tick（原
	# 倒序遍历语义保持）。
	# 组内倒序驱动（与原统一倒序遍历同序）；跨组先后：敌弹不查敌网格、玩家弹不撞玩家
	# ——组间零直交互。慢/efast 先后 R220 已定案（efast 无结算通道，settle FIFO 序不受
	# 影响）；慢/pfast 跨组序披露：pfast 弹驱动序整体后移（慢组全驱完后才驱动 pfast 组），
	# 预算关（S0 override=-2）全即时结算无 FIFO 位次问题=逐位等价；预算饱和帧（S1/S2）
	# 提交 FIFO 位次与旧交错序可能有差——顺延/丢弃按 (source,target) 对累积（R223 期望
	# 守恒口径），DPS 期望不变、轴读数（顺/弃）或有秒级漂移=AC-E4 ±10% 容差内观察项。
	var actives := p_pool.active_projectiles()
	_proj_slow_buf.clear()
	_proj_fast_buf.clear()
	_proj_pfast_buf.clear()
	var pfast_pool := p_pool == _projectile_pool
	if ENEMY_BULLET_FAST_PATH or PLAYER_BULLET_FAST_PATH:
		for proj in actives:
			var pb := proj as ProjectileBase
			if ENEMY_BULLET_FAST_PATH and pb != null and pb.team == 1 and pb._fast_path:
				_proj_fast_buf.append(proj)
			elif PLAYER_BULLET_FAST_PATH and pfast_pool and pb != null \
					and pb.team == 0 and pb._pfast:
				_proj_pfast_buf.append(proj)
			else:
				_proj_slow_buf.append(proj)
	else:
		_proj_slow_buf.append_array(actives)
	if pfast_pool:
		_pfast_live = _proj_pfast_buf.size()     # 诊断快N 采样源（homing 池分区不覆写）
	# 组内倒序驱动（与原统一倒序遍历同序）；先慢、次敌弹快、末玩家弹快
	var idx := _proj_slow_buf.size() - 1
	while idx >= 0:
		var proj := _proj_slow_buf[idx]
		if is_instance_valid(proj):
			proj.tick(p_gd)
		idx -= 1
	if not _proj_fast_buf.is_empty():
		# 玩家半径逐池一次解析（typed 直读；桩玩家回落 Variant get——r210 双轨口径）
		var pr := 0.0
		if player != null and is_instance_valid(player):
			if player is Player:
				pr = player.hitbox_radius
			else:
				var pr_v: Variant = player.get("hitbox_radius")
				pr = float(pr_v) if pr_v != null else 0.0
		idx = _proj_fast_buf.size() - 1
		while idx >= 0:
			var fproj := _proj_fast_buf[idx]
			if is_instance_valid(fproj):
				(fproj as ProjectileBase)._tick_fast(p_gd, player, pr)
			idx -= 1
	idx = _proj_pfast_buf.size() - 1
	while idx >= 0:
		var pproj := _proj_pfast_buf[idx]
		if is_instance_valid(pproj):
			(pproj as ProjectileBase)._tick_fast_player(p_gd)
		idx -= 1


var _enemy_bullet_buf: Array[Node2D] = []     # E7 复用缓冲（敌弹网格快照——零每帧分配）
var _combo_count: int = 0                     # E9 连杀计数（1.2s 窗口；割草爽感跳字）
var _combo_tier_paid: int = 0                 # G9 连杀奖励已发档位（每窗口每档一次）
var _combo_reward_line := ""                  # G9 本跳奖励行（跳字消费后即清）
var _combo_left: float = 0.0                  # 连杀窗口剩余
var _combo_label: Label = null                # ×N 连杀跳字（复用单 Label 重写文本）
var _combo_tween: Tween = null                # R262b L1：跳字 tween 引用（新跳 kill 旧防叠加写）


func _collect_enemy_bullets() -> Array[Node2D]:
	# 敌弹列表（team==1；供消弹查询网格重建——上一帧位置的确定性快照口径）。
	# E7 审查后微优化：复用成员缓冲（rebuild 只读遍历一帧内完成，覆写安全）
	_enemy_bullet_buf.clear()
	for proj in _projectile_pool.active_projectiles():
		if proj is ProjectileBase and (proj as ProjectileBase).team == 1:
			_enemy_bullet_buf.append(proj)
	return _enemy_bullet_buf


var _ui_popup_us: int = 0                        # R218 刀C：⑧ 段内跳字池 tick 耗时（跳键——
                                                 # UI 拆 HUD/Boss条/震屏 vs 跳字归因）


func _tick_ui(p_raw_delta: float) -> void:
	# ⑧ UI 阶段（raw 通道）：跳字 → HUD → Boss 条 → 相机震屏偏移（trauma² 映射应用位）
	# R206 真机日志：UI 段秒内尖峰 36ms（合并排版=字体排版，Android 系统字体回退链贵）
	# ——mobile 跳字半频驱动（隔帧 tick、delta×2 累积：漂浮/淡出/合并窗全 dt 化语义
	# 恒等，仅驱动粒度 60→30Hz；手机掉帧期本就 10-30fps，观感无损）。桌面每帧驱动不变。
	# R218 刀C：popup_manager.tick 独立计时入 跳键（vc25 UI 尖峰 53-200ms 与 跳N≈40
	# 强相关——排版批在 tick 侧，拆键后 vc26 直接归因 跳 vs HUD）
	# R233 T4 决策2：模拟 30Hz 下隔帧相位=15Hz——谓词成立时短路直驱（每步 1/30 delta；
	# 回退 60Hz 档半频相位原样恢复；桌面/headless 本就走每帧直驱分支）
	var _pop_t0 := Time.get_ticks_usec()
	if OS.has_feature("mobile") and not sim30_effective():
		_ui_subtick_left -= 1
		if _ui_subtick_left > 0:
			pass                                # 空转帧整段跳过（dt 量下帧 2δ 补齐——语义恒等）
		else:
			_ui_subtick_left = 2
			popup_manager.tick(p_raw_delta * 2.0)
	else:
		popup_manager.tick(p_raw_delta)
	_ui_popup_us = Time.get_ticks_usec() - _pop_t0
	hud.tick(p_raw_delta)
	boss_bar.tick(p_raw_delta)
	_apply_camera_shake()


func diag_reset_stage_peaks() -> void:
	# R206：诊断日志每秒采样读走峰值后清零（DebugStats 调用；探针关时零成本空字典）
	stage_probe_us_peak.clear()


func diag_reset_stage_win_sums() -> void:
	# R286：诊断日志每秒采样读走段窗和后清零（DebugStats 调用——diag_reset_stage_peaks
	# 同款时序；非 PLAYING 态窗不累计，读数天然 0）
	_stage_win_sum_us = 0
	_stage_win_proj_us = 0
	_stage_win_grid_us = 0
	_stage_win_enemy_us = 0
	_stage_win_popup_us = 0
	_stage_win_player_us = 0
	_stage_win_fx_us = 0
	_stage_win_ui_us = 0
	_stage_win_other_us = 0
	_stage_win_dispatch_us = 0


func _apply_camera_shake() -> void:
	# 集成包 A：CameraShake 纯计算输出 → 相机 transform（headless 无相机也安全）。
	# PAUSED：震屏冻结（用户反馈 2026-08-29——暂停期画面完全静止）
	if camera == null or game_feel == null or game_feel.shake == null:
		return
	if state == GameConst.GameStatus.PAUSED:
		camera.offset = Vector2.ZERO
		camera.rotation = 0.0
		return
	var v := game_feel.shake.offset_and_rotation()
	camera.offset = Vector2(v.x, v.y)
	camera.rotation = v.z


func _unhandled_input(p_event: InputEvent) -> void:
	# 桌面键盘暂停（用户反馈 2026-08-29）：Esc / P 在 PLAYING⇄PAUSED 间切换——
	# 仅真实输入事件触发（headless 手动驱动 _physics_process 的测试零影响）；
	# 本节点 PROCESS_MODE_ALWAYS（tree.paused 期仍收输入，Q-14 同口径）
	if not (p_event is InputEventKey) or not (p_event as InputEventKey).pressed \
			or (p_event as InputEventKey).echo:
		return
	var key := (p_event as InputEventKey).keycode
	if key != KEY_ESCAPE and key != KEY_P:
		return
	match state:
		GameConst.GameStatus.PLAYING:
			request_pause()
			get_viewport().set_input_as_handled()
		GameConst.GameStatus.PAUSED:
			request_resume()
			get_viewport().set_input_as_handled()
		_:
			pass                                  # 其余状态：键盘暂停不介入


# ── 经验链路（集成包 B.1：击杀掉落 → 磁吸 → 经验 → 升级仲裁 E-16） ──
func _on_enemy_killed_drop_xp(p_enemy: Node2D) -> void:
	# 掉落值真源：Enemy.exp_value（波次通胀已缩放）× 遗物点金手倍率（REL_MIDAS +20%，A3 §5）
	# × 早期经验加速（early_xp_boost：第 1 波起 ×1.25，until_wave 波起回落——掉落侧折算，
	# 同点金手口径；gain_xp/xp 曲线测试口径保持纯净）
	if not (p_enemy is Enemy):
		return                                  # 裸实体探针/非敌事件防御
	var value := (p_enemy as Enemy).exp_value * relic_handler.xp_mult() * _early_xp_mult()
	# R196 分档基线：通胀真源 balance_tables.gd；wave_director 缺失 → w=1 → 基线=锚。
	# R202 断环修复：基线锚 = 注册表最低 exp_base（boot 扫描缓存 _xp_tier_anchor_base，
	# 现值 3.0=E1_grunt，与设计锚「杂兵」等价）× inflation^(w-1)——原「死者自身
	# exp_base」与 value 同乘通胀 → 比值=exp_base/自身基线 自相消，普通/Boss 恒白档、
	# 精英恒金档（probe_r202_xpcolor 实证 E6_boss ratio=1.250 白档）。逐击一次的掉落
	# 事件路径，非每帧——R188 红线不涉。面值/基线比 → 白/绿/金/七彩（阈值单源
	# XpShard.XP_TIER_THRESHOLDS，色源 PopPalette.XP_TIER_COLORS）
	var bal := GameConfig.balance
	var inflation := 1.085 if bal == null else bal.exp_inflation_per_wave
	var w := maxi(wave_director.current_wave if wave_director != null else 1, 1)
	# 迟到击杀对齐（R202）：data 池归还清零（enemy.gd _reset_state 置 null）后到账的
	# 击杀事件（测试 stub 重复 emit / 池化竞态）与正常击杀同口径锚式基线——原兜底
	# exp_value 面值随死者通胀漂移，改锚后迟到 Boss 碎片 baseline 大幅回落（颜色边界
	# 事件，接受：纯表现色变、数值零损）；基线计算不读 data，null 安全——本段必须先于
	# 连杀计数，异常不得中断后续 _combo_count += 1（E9/G9 计数依赖）
	# R208 五色递进：基线额外 ×0.982^(w-1) 随波轻衰减——通胀 1.085 同乘两端相消后
	# 比值仍随波 ×1.105^(w-1) 上移（w10≈×2.1 / w20≈×4.4 / w40≈×19）：同怪开局低档色、
	# 后半程逐级爬色（杂兵 w12 蓝档起步、中价 w8 紫/w15 金、末期彩档常见）——颜色随
	# 进程递进展开（用户口径「白-蓝-紫-金-彩 递进出现」）；阈值侧见 XpShard 五档表。
	var baseline := _xp_tier_anchor_base * pow(inflation, float(maxi(w - 1, 0))) * pow(0.982, float(maxi(w - 1, 0)))
	_spawn_xp_shard(p_enemy.global_position, value, baseline)
	# R18 残留根修：Boss/精英死亡 → 全场碎片（含刚爆出的大珠）立即磁吸——奖励即刻
	# 飞向玩家，不再依赖 4.5s/2s 超时回归（「大怪碎片残留不消失」终解）
	if (p_enemy as Enemy).is_boss() or (p_enemy as Enemy).is_elite():
		for shard in active_shards:
			if is_instance_valid(shard):
				shard.force_magnet()
	# E9 连杀：窗口内击杀 +1；≥5 起显示 ×N 跳字（档位色阶 5/10/20——爽感可视化）
	_combo_count += 1
	_combo_left = 1.2
	if hud != null:
		hud.combo_peak = maxi(hud.combo_peak, _combo_count)   # G10 本局峰值（结算行）
	# G9 连杀奖励：×10/×20 档位各发一次金币滴灌（同掉账乘区口径；先于跳字结算）
	if _combo_count >= 10 and _combo_tier_paid < 1:
		_combo_tier_paid = 1
		_pay_combo_reward(6)
	if _combo_count >= 20 and _combo_tier_paid < 2:
		_combo_tier_paid = 2
		_pay_combo_reward(14)
	if _combo_count >= 5:
		_show_combo_toast()
	# 金币掉账（M7 战地黑市货币：gold_drop = {chance, min, max}，首次接线——此前为死数据；
	# 词缀二期：祝福·丰饶/富矿金币倍率在掉账额入账（player.map_gold_mult，真源 map_table.gd）；
	# R5.12-P1 AFF_GOLD 点金：掉率（钳 ≤1）与掉量两处 ×(1+gold_find_pct)）
	var gdrop: Variant = (p_enemy as Enemy).data.gold_drop
	if gdrop is Dictionary and not (gdrop as Dictionary).is_empty():
		var gd := gdrop as Dictionary
		var gold_find := player.gold_find_pct()
		if randf() < minf(float(gd.get("chance", 0.0)) * (1.0 + gold_find), 1.0):
			player.gold += int(round(randf_range(float(gd.get("min", 1)), float(gd.get("max", 1)))
				* player.map_gold_mult * (1.0 + gold_find)
				* GameConst.difficulty_reward_mult(_difficulty)))   # R73 难度风险回报


func _early_xp_mult() -> float:
	# 早期经验加速倍率（2026-09-13 用户反馈「早期叠不起来，要让用户始终保持期待」）：
	# current_wave ∈ [1, until_wave) → ×mult（默认 ×1.25 至第 5 波）；数值真源
	# BalanceTables.early_xp_boost。波次源 wave_director（无尽/续局波数自然越界回落 1.0）
	var mult := 1.25
	var until_wave := 6
	if GameConfig.balance != null:
		mult = float(GameConfig.balance.early_xp_boost.get("mult", 1.25))
		until_wave = maxi(int(GameConfig.balance.early_xp_boost.get("until_wave", 6)), 1)
	var wave := wave_director.current_wave if wave_director != null else 0
	return mult if wave >= 1 and wave < until_wave else 1.0


func _spawn_level_burst(p_pos: Vector2, p_delay: float = 0.0) -> void:
	# E3 升级波纹：一次性自清表现件（双环：亮芯扩散 + 淡晕跟随；0.5s 生命周期）
	var burst := LevelBurst.new()
	burst.name = "LevelBurst"
	burst.position = p_pos
	burst.delay = p_delay
	add_child(burst)


func spawn_probe_star() -> Node:
	# R94 渲染冒烟探针口（probe_star.gd 用——无游戏内消费者）
	var fx = BlastStarFx.spawn(self, Vector2.ZERO, 90.0)   # R253 池化发射口
	return fx


class BlastStarFx:
	# R94 导弹爆金边五角星：顶层一次性星爆（弹入放大 + 白闪 + 快速淡出 0.5s）
	# ——用户三轮点名「明显的金边五角星」，此件不依赖任何特效层/质量档
	# R253（c9a 缓办清账）入池复用：MissileBlastFx.spawn 静态池协议同款（LIFO 空闲栈 +
	# 归还 visible=false/停处理 + 悬挂引用 is_instance_valid 剔除）——导弹爆密集期
	# 每爆 new+queue_free 两 Sprite 分配税；发射期只重置 _t，读感与新建一致。
	extends Node2D

	const LIFE := 0.5
	const POOL_MAX := 8                          # 池上限（星爆并发峰值余量）

	static var _free: Array = []                 # 空闲件栈（LIFO）
	static var _pool_news: int = 0
	static var _pool_hits: int = 0

	var radius := 90.0
	var _t := 0.0
	var _sprite: Sprite2D = null
	var _flash: Sprite2D = null

	static func spawn(p_layer: Node, p_pos: Vector2, p_radius: float) -> Object:
		# R253 池化发射口（替代 add_child(new)）
		if p_layer == null:
			return null
		var item = _acquire(p_layer)
		item.position = p_pos
		item.radius = p_radius
		item._t = 0.0
		item.visible = true
		item.set_process(true)
		return item

	static func _acquire(p_layer: Node) -> Object:
		while not _free.is_empty():
			var cand = _free.pop_back()
			if cand != null and is_instance_valid(cand):
				_pool_hits += 1
				if cand.get_parent() != p_layer:
					cand.get_parent().remove_child(cand)
					p_layer.add_child(cand)
				return cand
		_pool_news += 1
		var item = BlastStarFx.new()
		p_layer.add_child(item)
		return item

	static func _release(p_item) -> void:
		if p_item == null or not is_instance_valid(p_item):
			return
		p_item.visible = false
		p_item.set_process(false)
		if _free.size() < POOL_MAX:
			_free.append(p_item)
		else:
			p_item.queue_free()

	func _ready() -> void:
		z_index = 100                            # 顶层（覆盖敌我所有实体）
		_sprite = Sprite2D.new()
		_sprite.texture = TextureFactory.blast_star()
		add_child(_sprite)
		_flash = Sprite2D.new()
		_flash.texture = TextureFactory.soft_dot(64)
		_flash.modulate = Color(1.0, 0.95, 0.7, 0.55)
		add_child(_flash)

	func _process(p_delta: float) -> void:
		_t += p_delta
		if _t >= LIFE:
			_release(self)                      # R253：归还池（原 queue_free）
			return
		var k := _t / LIFE
		var pop := 1.0 - pow(1.0 - minf(k * 2.2, 1.0), 3.0)   # easeOut 弹入
		var s := (radius * 2.0 / 110.0) * (0.35 + 0.85 * pop)
		_sprite.scale = Vector2(s, s)
		_sprite.rotation = k * 0.9                             # 微旋（星爆动感）
		_sprite.modulate.a = 1.0 - pow(k, 2.0)
		_flash.scale = Vector2.ONE * (radius * 1.2 / 64.0) * (1.0 - k)
		_flash.modulate.a = 0.55 * (1.0 - k * 1.6)


class LevelBurst:
	extends Node2D

	const LIFE := 0.5
	const MAX_R := 150.0

	var _t: float = 0.0
	var delay: float = 0.0                       # 错峰延迟（成对抉择第二环）

	func _process(p_delta: float) -> void:
		if delay > 0.0:
			delay -= p_delta
			return
		_t += p_delta
		if _t >= LIFE:
			queue_free()
			return
		queue_redraw()

	func _draw() -> void:
		# R271 P4：绘µs wrap（自绘件 _draw 计时入 &"draw" 桶——只加计不改行为；
		# 原体迁 _draw_r271，早退 return 由委托面兜底不漏收口）
		DebugStats.bucket_begin(&"draw")
		_draw_r271()
		DebugStats.bucket_end(&"draw")


	func _draw_r271() -> void:
		var k := clampf(_t / LIFE, 0.0, 1.0)
		var ease_out := 1.0 - pow(1.0 - k, 3.0)   # easeOutCubic 扩散
		var r := 24.0 + MAX_R * ease_out
		var a := (1.0 - k)
		var gold := Color(1.0, 0.84, 0.29)
		draw_arc(Vector2.ZERO, r, 0.0, TAU, 40, Color(gold.r, gold.g, gold.b, 0.85 * a), 4.0, true)
		draw_arc(Vector2.ZERO, r * 0.72, 0.0, TAU, 32, Color(gold.r, gold.g, gold.b, 0.3 * a), 9.0, true)


func _pay_combo_reward(p_gold: int) -> void:
	# G9 连杀奖励：金币入账（map_gold/点金/难度三乘区同掉账口径）+ 跳字奖励行
	var mult: float = player.map_gold_mult * (1.0 + player.gold_find_pct()) 		* GameConst.difficulty_reward_mult(_difficulty)
	var paid := int(round(float(p_gold) * mult))
	player.gold += paid
	_combo_reward_line = "  奖励+%d金" % paid


func _show_combo_toast() -> void:
	# E9 ×N 连杀跳字：屏幕中带单 Label 复用（低频事件零池化压力）——
	# 果冻弹入 + 上浮自隐；档位色阶（5 白 / 10 蓝 / 20 金）
	if _combo_label == null or not is_instance_valid(_combo_label):
		_combo_label = Label.new()
		StickerTheme.label_sticker(_combo_label, 30, Color.WHITE, 10, Color(0.13, 0.15, 0.29), true)
		_combo_label.z_index = 60
		add_child(_combo_label)
	var col := Color.WHITE
	if _combo_count >= 20:
		col = PopPalette.GOLD
	elif _combo_count >= 10:
		col = PopPalette.XP
	_combo_label.add_theme_color_override("font_color", col)
	_combo_label.text = "×%d 连杀！%s" % [_combo_count, _combo_reward_line]
	_combo_reward_line = ""                     # 消费即清（下一跳不残留）
	if hud != null:
		hud._fit_font_size(_combo_label, _combo_label.text, 690.0)   # R86 奖励行加长不溢出
	_combo_label.reset_size()
	_combo_label.position = Vector2(360.0 - _combo_label.size.x * 0.5, 420.0)
	_combo_label.pivot_offset = _combo_label.size * 0.5
	_combo_label.scale = Vector2(0.3, 0.3)
	_combo_label.modulate = Color(1, 1, 1, 1)
	# R262b L1：旧 tween 即杀（照 hud._revive_flash 先例）——击杀风暴期旧淡出未完时
	# 新弹入不再叠加写同一 Label 的 scale/modulate（省每击 create_tween 并发税+互顶抖动）
	if _combo_tween != null and _combo_tween.is_valid():
		_combo_tween.kill()
	var tw := _combo_label.create_tween()
	_combo_tween = tw
	tw.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tw.tween_property(_combo_label, "scale", Vector2.ONE, 0.10) 		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_interval(0.55)
	tw.tween_property(_combo_label, "modulate:a", 0.0, 0.30)


func _spawn_xp_shard(p_pos: Vector2, p_value: float, p_baseline: float = 0.0) -> void:
	# R196：p_baseline 可选参（旧调用零破坏——测试/降级路径缺省 0 → 恒白档）
	if p_value <= 0.0:
		return
	# R213 D案：满载并珠——敌≥80 满载高击杀下碎片堆积（每片 1 Sprite2D 独立 item、
	# 池 160；vc20 满载 o2635 的弹性大头）→ 新掉落不占新珠，面值并入场上最近碎片
	# （merge_value 数值守恒+涨档变色机制现成；观感=「碎片变大珠」）。满载高击杀与
	# 碎片堆积强相关，不另设碎片数阈（桌面基准零扰动）；敌数回落自动恢复独立掉落。
	if not active_shards.is_empty() and Enemy.fullload_dim():
		var best: XpShard = active_shards[0]
		var best_d := best.global_position.distance_squared_to(p_pos)
		for s in active_shards:
			var d: float = (s as XpShard).global_position.distance_squared_to(p_pos)
			if d < best_d:
				best_d = d
				best = s
		best.merge_value(p_value, p_baseline)
		return
	var shard := (pools[&"xp"] as XPPool).acquire()
	if shard == null:
		# 满池合并为大面值碎片（数值守恒，架构 §5.1 XPPool 行）；基线同传
		#（merge_value 内取 max 重分档）
		if not active_shards.is_empty():
			active_shards[0].merge_value(p_value, p_baseline)
		return
	shard.position = p_pos
	shard.bucket_host = (pools[&"xp"] as ObjectPool).bucket_host    # R216 刀①：分桶 host 注入（同敌 spawner 口径）
	shard.activate(p_value, p_baseline)
	active_shards.append(shard)


func _tick_xp_shards(p_gd: float) -> void:
	# 磁吸/吸收推进（帧序②玩家阶段内；倒序遍历——吸收即归还擦除当前索引安全）
	# R214 双驱动修复：磁吸态碎片本段跳过——原 ②全量 + ⑦磁吸段各 tick 一次（磁吸片
	# PLAYING 期每帧两次位移=速度双倍；磁吸链成本也在玩段/感段各跑一次）。⑦磁吸段
	# 独占磁吸片；MAGNET_SPEED 520→1040 补偿（单 tick 位移恒等，观感零变化）。
	# R215 刀B（QA DEF-3 收口）：②段「非磁吸片圈内即时吸收」（pickup.tick 内当帧
	# 转磁吸即吸收）并入 24/帧帽——玩家脚下死亡堆单帧全额入账=vc22 玩段尖峰 119ms
	# 真身。帽满时圈内片冻结在场（与⑦同口径），下帧帽预算恢复即收。
	# R225 刀a：满载门内本段只花共享单帽的「总预算 − 磁吸预留」（磁吸优先：段首
	# 快照 ready_to_absorb 磁片数预留，预留 ≥ 总帽时圈内片全冻结——磁吸收割演出
	# 优先入账）；非满载本地 24 帽原样零扰动。
	var fullload := Enemy.fullload_dim()
	var absorbed := 0
	var cap := magnet_absorb_cap_now()
	if fullload:
		var reserved := 0
		for s in active_shards:
			if is_instance_valid(s) and (s as XpShard).is_magnet() \
					and (s as XpShard).ready_to_absorb():
				reserved += 1
		cap = maxi(_fullload_absorb_left - reserved, 0)
	var player_pos: Vector2 = player.global_position
	var idx := active_shards.size() - 1
	while idx >= 0:
		var shard := active_shards[idx]
		if is_instance_valid(shard) and not shard.is_magnet():
			if absorbed >= cap \
					and shard.global_position.distance_to(player_pos) <= XpShard.ABSORB_DISTANCE:
				idx -= 1                        # 帽满冻结：圈内待收片本帧不动（tick 会即收）
				continue
			if shard.tick(p_gd):
				absorbed += 1
				if fullload:
					_fullload_absorb_left -= 1   # R225 刀a：扣共享预算（② 份额）
				active_shards.remove_at(idx)
				(pools[&"xp"] as XPPool).release(shard)
		idx -= 1


# ── E-10 敌间分离力（软分离防重叠；10Hz 分片轮转 + 网格邻域查询） ──────────
# R256 序2：原 10Hz 单帧全量（enemy 段实测尖峰 10.7-12.3ms，满屏敌推挤周期性
# 「咯噔」）改分片轮——敌按 uid%SHARDS 归片，各片独立 10Hz 到期各自结：每敌服务
# 频率不变（10Hz），单帧分离成本 ÷SHARDS（60fps 时每帧恰 1 片）。_apply_enemy_
# separation() 保留全量口径（pkg5 E-10 直调契约 + 一次性全场结的场景复用）。
func _tick_separation(p_delta: float) -> void:
	_sep_clock += p_delta
	if _sep_due.is_empty():
		_sep_due.resize(SEPARATION_SHARDS)
		for i in SEPARATION_SHARDS:
			# 首轮按 interval*i/SHARDS 错峰铺开——首轮即摊平，无开局全量帧
			_sep_due[i] = _sep_clock + SEPARATION_INTERVAL * float(i) / float(SEPARATION_SHARDS)
	for i in SEPARATION_SHARDS:
		if _sep_clock >= _sep_due[i]:
			# 相位保持重排（R256 修轮 QA-R256-02/评审 M1）：整步进续期锚定初铺相位网格
			# ——长帧追赶批后各片仍按原错峰续期，不并相锁步（首版 snap-to-now 在一次
			# ≥interval 长帧后六片重排到同一到期时刻=永久退回全量形态，QA 探针实证相位
			# 散布 0.0000）；积压以每帧每片一结的速率排干（反螺旋），暂停期时钟冻结无积压。
			while _sep_clock >= _sep_due[i]:
				_sep_due[i] += SEPARATION_INTERVAL
			_apply_enemy_separation_shard(i)


func _reset_separation_wheel() -> void:
	_sep_clock = 0.0
	_sep_due.clear()


func _apply_enemy_separation() -> void:
	if enemy_grid == null:
		return
	var actives := spawner.active
	for i in range(actives.size() - 1, -1, -1):
		var enemy := actives[i] as Enemy
		if enemy == null or enemy.dead:
			continue
		_separate_one(enemy)


func _apply_enemy_separation_shard(p_shard: int) -> void:
	if enemy_grid == null:
		return
	var actives := spawner.active
	for i in range(actives.size() - 1, -1, -1):
		var enemy := actives[i] as Enemy
		if enemy == null or enemy.dead:
			continue
		if enemy.uid % SEPARATION_SHARDS != p_shard:
			continue
		_separate_one(enemy)


func _separate_one(p_enemy: Enemy) -> void:
	# 邻域查询（网格保守半径超集）；查询缓冲顺序消费后即失效 → 不留存引用
	var neighbors := enemy_grid.query_circle(p_enemy.global_position, p_enemy.hitbox_r)
	for j in range(neighbors.size() - 1, -1, -1):
		var other := neighbors[j] as Enemy
		if other == null or other == p_enemy or other.dead:
			continue
		var delta := p_enemy.global_position - other.global_position
		var min_d := p_enemy.hitbox_r + other.hitbox_r
		var d := delta.length()
		if d >= min_d:
			continue
		# 完全重叠（同点）时按敌 uid 定向散开（确定性，无 RNG）
		var dir := delta / d if d >= 0.01 \
			else Vector2.RIGHT.rotated(float(p_enemy.uid % 16) * TAU / 16.0)
		var push := dir * ((min_d - d) * 0.5)          # 各让一半重叠量
		p_enemy.global_position += push.limit_length(SEPARATION_MAX_STEP)


# ── 致命配置错误清单屏（§六.2 boot_error 占位；程序化美术） ───────
func _build_boot_error_screen() -> void:
	var layer := CanvasLayer.new()
	layer.name = "BootErrorScreen"
	layer.layer = 100
	add_child(layer)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)
	var dim := ColorRect.new()
	dim.color = Color(0.12, 0.02, 0.02, 0.97)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(dim)
	var title := Label.new()
	title.text = "启动失败：致命配置错误"
	title.add_theme_font_size_override("font_size", 30)
	title.position = Vector2(40.0, 320.0)
	root.add_child(title)
	var lines := Label.new()
	var text := ""
	for err in boot_fatal:
		text += String(err) + "\n"
	lines.text = text
	lines.add_theme_font_size_override("font_size", 15)
	lines.position = Vector2(40.0, 400.0)
	root.add_child(lines)


func _reset_run_state() -> void:
	# 重开重置：★ 战场清场（敌/弹/光束/跳字/粒子——残留半血 Boss 原位冻结后会叠进
	# 新波次 1、残留敌弹重生首帧秒杀，审查 Fix 1 Critical）→ 玩家（复活含死亡短路清除/
	# HP/经验/槽位解锁）/ HUD 统计 / 卡牌流 / 顿帧态
	_clear_battlefield()
	player.respawn()
	for i in range(player.weapon_slots.size()):
		var w: WeaponBase = player.weapon_slots[i] if i < player.weapon_slots.size() else null
		if w != null and is_instance_valid(w):
			w.queue_free()
		player.weapon_slots[i] = null
	# R186：首发分支——random_dual 重开 = 新局重 roll（每日传留存种子保确定）；其余按角色首发
	#（门读 player.character_id：set_character 锁定回落 sentinel 后两处口径一致）
	if bool(CharacterTable.get_character(player.character_id).get("random_dual", false)):
		_grant_random_dual_loadout(_active_daily_seed)
	else:
		_equip_starting_weapon(Meta.character_id)
	hud.refresh_stats()                           # R186 MF2：respawn（→set_character）+ 首发就位后显式刷（换角首波技能键可见性即时自愈）
	hud.kills = 0
	hud.wave = 0
	hud.total_damage = 0.0
	hud.run_elapsed = 0.0
	card_generator.owned_relics.clear()
	relic_handler.reset_run()                     # B.2：遗物每场重新获取（owned/常驻位清零）
	for shard in active_shards:                   # B.1：清场归还经验碎片
		if is_instance_valid(shard):
			(pools[&"xp"] as XPPool).release(shard)
	active_shards.clear()
	_reset_separation_wheel()
	pending_level_ups = 0
	merged_overflow_level_ups = 0               # R188-perf：连升合并溢出批随局清
	_deferred_level_open = -1                   # R215 刀A：延迟开窗档随局清（防跨局陈旧档）
	if _merged_overflow_draining:
		_merged_overflow_draining = false         # R189：分帧消化批中断——抑制态强制结清
		Meta.cancel_persist_defer()
	_merged_overflow_deferred = {}              # R212 刀4：让渡卡随局清（新局无残留）
	_auto_card_left = -1.0                      # R188-idle：挂机挂起窗全清（重开干净起步）
	_auto_shop_left = -1.0
	_auto_restart_left = -1.0
	_auto_card_shown_index = -1
	_auto_card_retries = 0
	resume_grace_left = 0.0
	_free_reroll_used = false                  # 刷新机制：本局首次免费位复位
	_card_rarity_floor = -1                    # R199-N13：选卡流保底留存随局清（防跨局残留）
	_endless_mode = false                       # R62：无尽态/延迟结算位/驱动器闸 一并复位
	_victory_settle_pending = false
	wave_director.advance_blocked = false
	hud.endless_depth_base = 0
	player.input_enabled = true
	game_feel.hit_stop_left = 0.0
	game_feel.hit_stop_active_ms = 0.0
	set_time_scale(1.0, &"reset")
	if sfx != null:
		sfx.bgm_set_boss_layer(false)             # 清场收 Boss 层（重开无残留脉冲）


func _clear_battlefield() -> void:
	# 残留清场序（审查 Fix 1）：生成队列 → 在场敌（快照遍历归还 EnemyPool）→ 投射物
	#（含敌弹）→ 活跃光束 → 跳字 → 粒子。敌/弹为静默回收：不经 enemy_killed / ON_EXPIRE——
	# 防死亡新星/分裂请求在清场期再结算、防重复击杀计数（非战斗语义归还）；
	# 光束经 _recycle 统一收束（ON_EXPIRE 仅词条派发，无次级结算通道，安全）。
	if spawner != null:
		spawner.spawn_queue.clear()
		for enemy in spawner.active.duplicate():  # 快照遍历（on_enemy_killed 内部 erase active）
			if is_instance_valid(enemy):
				spawner.on_enemy_killed(enemy)    # 活跃表移除 + 元素宿主注销 + 池归还
	for proj in _projectile_pool.active_projectiles().duplicate():
		if is_instance_valid(proj):
			_projectile_pool.release(proj)        # 直接归还（池侧 _reset_state 清零）
	for child in (pools[&"laser"] as LaserBeamPool).get_children():
		var beam := child as LaserBeam
		if beam != null and beam.is_live():
			if beam.weapon != null and is_instance_valid(beam.weapon):
				beam.weapon.active_beams.erase(beam)   # 先摘宿主（防宿主 tick 已归还光束）
			beam._recycle()                       # 统一收束：ON_EXPIRE → 清零 → 池归还
	if popup_manager != null:
		popup_manager.clear_all()
	(pools[&"particle"] as ParticlePool).release_active_all()


func _tick_combo_for_test() -> void:
	# E9 测试观测口：手动推进连杀窗口衰减（帧序内联逻辑的测试直调副本）
	if _combo_left > 0.0:
		_combo_left -= 0.05
		if _combo_left <= 0.0:
			_combo_count = 0
			_combo_tier_paid = 0            # G9 档位随窗口复位（与帧序内联同口径）
