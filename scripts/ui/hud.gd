# scripts/ui/hud.gd
# M-16 HUD（架构 §2.15）：HP/经验/等级/波次/击杀/计时 + 词条栏（构筑统计）+ 波次 toast。
# 方向 C「晴空糖果」贴纸风：白胶囊 HP 条（纯渐变薄荷→柠檬→珊瑚）+ 经验星条 + 波次圆形
# 徽章 + 击杀/计时气泡 + 果冻波次 toast（lore 文案）。process_mode = ALWAYS（暂停/顿帧
# 期间 UI 照常，Q-14）；刷新 = 事件驱动 + 1Hz 兜底（架构 refresh_stats 口径：计时兜底走
# raw 通道 tick）。数值源：Player（HP/经验/等级/词条栏）+ wave_started / enemy_killed 事件。
# R186：+ TargetBar（左上「当前攻击单位」血条，修订 R2 状态机：O(1) 聚合 → 帧结算降序
# 回退解析 → HIDDEN/LOCKED/FADING；续窗口径/切换滞回/死亡出口优先级/Boss 让位）+
# 复活全屏反馈（白闪/大字横幅/✚×N 徽标，订阅 EventBus.revive_burst）+ 技能键无技能
# 角色置灰（player.has_skill() 契约，has_method 守卫向后兼容）。
class_name HUD
extends CanvasLayer

signal pause_requested()                      # 暂停按钮申请（→ GameLoop.request_pause 仲裁）
signal build_details_requested()              # 构筑面板点击（→ 暂停 + buff 详情；R197 竖两列，落位三档可设）

var player: Node2D = null                     # 注入（数值源；Player 宽类型规避循环解析）
var total_damage: float = 0.0                 # 造成的总伤害（damage_resolved 累计；结算屏数据源）

var _hp_fill: Panel = null                    # HP 条填充（比例缩放；圆角 StyleBoxFlat）
var _hp_fill_style: StyleBoxFlat = null       # 填充色随血量渐变（薄荷→柠檬→珊瑚）
var _hp_label: Label = null
var _xp_fill: Panel = null                    # 经验条填充
var _level_label: Label = null
var _wave_label: Label = null
var _wave_left_label: Label = null            # R209 波次余敌副行（「余 N」=待出生+场上活跃）
var map_name: String = ""                  # 当前地图名（M2 多地图，HUD 波次前缀）
var endless_depth_base: int = 0            # R62 无尽徽标基准（final_wave）：wave 超基后波次
                                            # 徽章切「无尽 N」（N = 超出波数）；0 = 常规口径
var _skill_btn: Button = null              # 角色技能键（右下角；冷却中置灰倒计时）
var _skill_icon: TextureRect = null        # 技能键底图（28% 印刷感）
var _skill_icon_fg: TextureRect = null     # 技能键前景图标（就绪亮显 / 冷却压暗）
var _skill_sublime_ring: TextureRect = null    # R246 升华红环覆盖层（技能已升华态描边）
var _skill_cd_label: Label = null          # 冷却数字覆盖层（仅冷却中非空）
var _skill_active_bar: ColorRect = null    # 技能效果剩余时长条（R19：增益期金色倒计时）
var _skill_auto_btn: Button = null         # R241 ④ 技能自动施放开关（技能键正下方）
var _skill_auto_label: Label = null        # 开关文案（开=金「自动施放」/关=灰「手动施放」）
var _gold_label: Label = null                 # 金币（战地黑市货币，M7）
var _boss_banner: Label = null                # Boss 出场横幅（表现层一期）
var _kill_label: Label = null
var _time_label: Label = null
var _build_label: Label = null                # 构筑统计行（面板底行计数，延续原词条栏）
var _build_panel: Control = null              # 构筑面板（竖排两列：左列武器槽/右列词条宝石——R197 用户反馈）
var _build_sig: String = ""                   # 构筑签名缓存（变化才重建，1Hz 兜底下的防抖）
var _build_press_pos: Vector2 = Vector2.ZERO  # R194 构筑面板松手判定：按下锚点（纯会话态）
var _build_armed: bool = false                # R194 松手判定武装态（位移 <16px 的释放才发详情申请）
var _shield_panel: Control = null             # 护盾条（MEC_SHIELD 持有时显示——用户反馈）
var _shield_fill: Panel = null
var _shield_fill_style: StyleBoxFlat = null
var _shield_layers_label: Label = null         # 二cv#1：层数读数「X N」（用户「有几条显示几条」）
# ── 二db 橙盾条（躲雷奖励 10s 临时盾：蓝条正下方，层数>0 才显） ──
var _temp_panel: Control = null
var _temp_fill: Panel = null
var _temp_fill_style: StyleBoxFlat = null
var _temp_label: Label = null                  # 层数×剩余秒读数「N·Xs」（用户「显示过期时间」）
var _state_label: Label = null                # 状态提示（LEVEL_UP/PAUSED/GAME_OVER——测试锁定节点名）
var _toast_label: Label = null                # 波次 toast（果冻 pop + lore 文案）
var _toast_left: float = 0.0                  # toast 剩余展示时长（raw 通道）
# ── R191#6 成就 toast 同帧合批（批量解锁风暴逐条滑入→同位叠放互相遮挡） ──
var _ach_toast_pending: Array[StringName] = []   # 本帧待播成就 id（flush 时一次聚合）
var _ach_toast_scheduled: bool = false           # flush 已排程标记（同帧只排一次）
# R13 自绘悬停说明（引擎默认 tooltip 在弹幕游戏里延迟大/样式弱——自绘卡即时跟随）
var _hover_zones: Array[Dictionary] = []      # [{rect: Rect2, text: String}]
var _hover_card: PanelContainer = null
var _hover_label: Label = null
var _hud_root: Control = null                 # HUD 根容器（悬停检测用——R13）
var _pause_btn: Button = null                 # 暂停按钮（▶⏸ 图形化贴纸；仅 PLAYING 态显示）

# ── R188-idle AUTO 挂机开关（右上角 x644-704×y126-190 空闲带；R194 放大 56×64） ──
var _auto_btn: Button = null                  # AUTO 开关（StyleBoxEmpty+文字胶囊，复刻暂停钮工厂）
var _auto_capsule: Panel = null               # 开关胶囊底（OFF 弱灰 / ON 金色）
var _auto_capsule_style: StyleBoxFlat = null
var _auto_label: Label = null                 # 开关文字（无缓存 bool——读写走 Meta 单一真源）

# ── R186 TargetBar（左上「当前攻击目标」血条；修订 R2 状态机） ──────────
enum TbState { HIDDEN, LOCKED, FADING }       # 小状态机：隐藏 → 锁定 → 收尾（白闪/淡出）
var _spawner: Node = null                     # EnemySpawner 宽类型（setup 注入；组兜底解析）
var _agg: Dictionary = {}                     # uid → 本帧合格伤害和（回调侧 O(1) 累加）
var _agg_frame: int = 0                       # 最近聚合帧号（damage_resolved 记录；观测用）
var _tb_cand_buf: Array[int] = []             # R188⑤：帧结算候选缓冲（原每帧 Array[int]+
                                              # assign(_agg.keys()) 双分配——成员原地重建）
var _tb_hp_q: int = -1                        # R188⑥：HP 文本量化缓存 hp 档（-1=未建）
var _tb_mh_q: int = -1                        # R188⑥：同上 max_hp 档
var _tb_hp_text_last: String = ""             # R188⑥：档位未变直出的缓存文本（省每帧构造）
var _tb_state: TbState = TbState.HIDDEN       # 状态机 HIDDEN → LOCKED → FADING
var _tb_lock_uid: int = 0                     # 锁定敌 uid（0 = 无）
var _tb_lock_node: Node2D = null              # 锁定敌节点引用（每帧有效性三查）
var _tb_lock_dying: bool = false              # 殒命/三查失败出口标志（R2 修③：不当场收起）
var _tb_retain_left: float = 0.0              # 续窗剩余（仅锁定 uid 合格伤害刷新）
var _tb_cand_uid: int = 0                     # 切换滞回候选 uid（帧间变化即重置计时）
var _tb_switch_left: float = 0.0              # 连续胜出剩余（0.3s 滞回）
var _tb_last_frame: int = -1                  # 帧结算检测（GameConfig.frame_stamp 前进）
var _tb_boss_on_field: bool = false           # Boss 在场（让位下移 y190，同 boss_bar 事件源）
var _tb_boss_node: Node2D = null              # 在场 Boss 引用（死亡判定走引用比对——
                                              # enemy_killed 时 tags 已被池归还清零，is_boss 失效）
var _tb_frozen: bool = false                  # PAUSED/LEVEL_UP 冻结续窗/出口衰减
var _tb_exit_left: float = 0.0                # FADING 剩余（白闪 0.25s / 淡出 0.3s）
var _tb_exit_white: bool = false              # FADING 风味：true=死亡白残影闪白 / false=续窗淡出
var _tb_pct: float = 1.0                      # 锁定敌当前 HP 比例（残影段锚点）
var _tb_displayed_pct: float = 1.0            # 平滑跟随显示比例（残影追速 0.4/s）
var _tb_last_pct: float = 1.0                 # 上一帧 HP 比例（掉血检测 → 受击白闪）
var _tb_hurt_flash: float = 0.0               # 受击白闪剩余（raw 通道衰减）
var _tb_root: Control = null                  # TargetBarRoot（Root 首子：内容下层+安全区随根）
var _tb_panel: Panel = null                   # 白胶囊贴纸条（_sticker_panel 复用）
var _tb_fill: Panel = null                    # 珊瑚填充（displayed_pct 口径同 BossBar）
var _tb_fill_style: StyleBoxFlat = null
var _tb_ghost: Panel = null                   # E6 白残影段（boss_bar.gd:169-180 复刻）
var _tb_name_label: Label = null              # 条内左名字（◆ 精英前缀）
var _tb_hp_label: Label = null                # 条内右 HP 绝对值（k 缩写防溢出）

# ── R186 复活全屏反馈 ─────────────────────────────────────────────
var _revive_flash: ColorRect = null           # 整屏白闪（fx_quality 三档；MOUSE_FILTER_IGNORE）
var _revive_flash_tween: Tween = null         # kill 旧 tween 防叠加（Boss 同帧口径）
var _revive_banner: Label = null              # 复活大字横幅（金/警示双色；boss_banner 三段式）
var _revive_banner_tween: Tween = null
var _revive_badge: Label = null               # 血条右上「✚×N」常驻徽标（归零置灰）
var _r187_readout: Label = null                # R187 武器形态读数位（W4 束数徽标 / W5 镜面 ×N / W8 引爆数）
var _fps_label: Label = null                   # R202：FPS 读数小字（show_fps 键控 visible；急切
                                              # 创建于 _build_ui，禁懒创建——见 _build_ui 内注）

# ── R199（P08）首局拖动教学一次性标志 ──────────────────────────────
# 进程级一次（static）：跨局持久化须往 Meta settings 白名单加键，而键表/写口归
# meta_manager.gd（R199 分组归其它组独占）——不越界改，static 记「本次启动首局已提示」。
static var _move_hint_shown: bool = false
var _move_hint_wait: float = -1.0             # ≥0 = 倒计时中；<0 = 闲置（仅 PLAYING 走秒）
var _state_cur: int = -1                      # 最近状态（state_changed 记录；教学倒计时冻结门）

var kills: int = 0
var combo_peak: int = 0                   # G10 本局最高连杀（结算行数据源）
var wave: int = 0
var run_elapsed: float = 0.0                  # 计时（raw 通道累计——含顿帧，观感口径）
var _fallback_timer: float = 0.0              # 1Hz 兜底刷新

# ── R188-perf refresh_stats 脏标记 ────────────────────────────────
# 事件回调（player_hit/xp_gained/wave_started/enemy_killed）只置脏不逐次全量刷新——
# 风暴帧（同帧 10+ 杀）由「帧末同帧 flush」合并为一次 refresh_stats（displayed_* 文本
# 口径零改动）；1Hz 兜底保留。refresh_stats_calls 为测试观测口（perf 组计数断言）。
var _stats_dirty: bool = false
var refresh_stats_calls: int = 0              # 测试观测口：refresh_stats 全量执行次数

# ── R212 刀2：选卡/暂停期 HUD 全量刷新节流（mobile 门） ──────────────
# vc18 真机取证：选卡期（LEVEL_UP）磁吸碎片持续吸收（R26）→ xp_gained 风暴逐帧置脏
# → _tick_ui 每帧 flush_stats_dirty 全量 refresh_stats（多 Label.text 重排 +
# _compute_build_sig 遍历武器词条 + _refresh_wave_left 扫生成队列）——选卡覆盖层下
# 这些排版每帧白刷。mobile 门：LEVEL_UP/PAUSED 态帧末 flush 降频至 0.25s 一档；
# 离开模态态（PLAYING/GAME_OVER）即回每帧 flush（战斗口径零变化）。
# 1Hz 兜底 refresh_stats 照常（tick 前段，不经本门）；displayed_* 读口直调
# flush_stats_dirty 亦不经本门（读取即最新语义不变）。flush_throttle_override 为
# 测试观测口：-1=平台自动（mobile+模态才节流）/ 0=强制不节流 / 1=强制节流。
const LEVELUP_FLUSH_INTERVAL_S := 0.25        # 模态态帧末 flush 节流档（4Hz）
var _flush_gate_left: float = 0.0             # 节流相位剩余 s
var flush_throttle_override: int = -1         # 测试覆写口（套件用毕复位 -1）

const HP_BAR_SIZE := Vector2(340.0, 30.0)
const XP_BAR_SIZE := Vector2(292.0, 14.0)
const TOAST_TIME := 1.7                       # 波次 toast 展示时长 s
const TOAST_MAX_LINES := 3                     # R253 toast 多行钳制帽（44px 带 34pt 行最多 3 行——超出截尾省略）
const INTRO_TOAST_TIME := 3.4                 # 大关新机制横幅时长 s（文案长，需读完）
const TOAST_FADE := 0.3                       # 末段淡出 s
const ACH_TOAST_MAX_NAMES := 3                # 成就合批 toast 最多列名数（R191 评审#3：截断保读）
const BUILD_CLICK_SLOP_PX := 16.0             # R194 构筑面板松手判定位移阈（超出=拖动不视为点击）

# ── R199（P08）首局拖动教学提示（战斗内一次性；文案真源 GameConst.TUTORIAL_MOVE_BATTLE，
#    UI 禁手抄——移动是唯一输入与生存手段，全游戏此前无一处告知） ──
const MOVE_HINT_DELAY := 2.2                  # 进战斗后延迟 s（避让第 1 波波次 toast TOAST_TIME 1.7）
const MOVE_HINT_TIME := 3.4                   # 展示时长 s（文案长，同 INTRO_TOAST_TIME 口径）

# ── R186 TargetBar 数值参数（修订 R2 §2 表） ─────────────────────────
const TB_SIZE := Vector2(280.0, 26.0)         # 280×26 @(24,136)：pill 行 y92–128 正下
const TB_POS_Y := 136.0                       # 常规落位
const TB_POS_Y_BOSS := 190.0                  # Boss 在场让位（BossBar 占 y112–184，留 6px）
const TB_RETAIN_TIME := 2.5                   # 续窗 s（停火后自然淡出）
const TB_FADE_TIME := 0.3                     # 续窗耗尽淡出 s（TOAST_FADE 口径）
const TB_SWITCH_HYSTERESIS := 0.3             # 切换滞回 s（帧间主目标变化即重置）
const TB_RESOLVE_BUDGET := 4                  # 帧结算解析预算（uid/帧，≤4×120 扫描封顶）
const TB_KILL_FLASH := 0.25                   # 死亡白残影闪白 s（boss_bar.gd:33 同款）
const TB_HURT_FLASH := 0.12                   # 掉血端白闪 s
const TB_GHOST_CHASE := 0.4                   # 白残影追速 /s（boss_bar.gd:60 复刻）
const TB_BASE_ALPHA := 0.88                   # 比 BossBar 弱一档

# ── R186 复活反馈数值（设计案 §2 表） ────────────────────────────────
const REVIVE_FLASH_ALPHA := 0.85              # 2 档全量白闪 alpha（0/1 档 fx_quality 降档）
const REVIVE_FLASH_TIME := 0.45               # 2 档白闪时长 s（EASE_OUT）
const REVIVE_BANNER_HOLD := 2.2               # 横幅停留 s（二cs：1.2→2.2；0.22 弹入 + 2.2 + 0.4 ≈2.82 < 5s 无敌）


func _ready() -> void:
	# ALWAYS：暂停/顿帧期间 UI 照常（Q-14）
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	# R195 适配：安全区接入（底座组 SafeAreaHelper 单点引用，不复写）。守卫外
	# （桌面窗口化/headless）insets 恒零 → offset 写 0 = 默认窗逐位恒等；真机延迟
	# ≥1 帧重读兜首帧 transform 未定型，size_changed/重获焦点由 helper 重放回调。
	_apply_safe_area()
	if SafeAreaHelper.enabled(get_window()):          # 守卫外恒零→零协程悬挂（headless 全绿面）
		_apply_safe_area_deferred()                # 真值环境延迟重读（SafeAreaHelper 契约）
	SafeAreaHelper.bind_reread(get_window(), _apply_safe_area)


func _apply_safe_area_deferred() -> void:
	# realize 后延迟 ≥1 帧重读（首帧查询为未 realize 真值——SafeAreaHelper 契约）；
	# 协程即发即续，不阻塞 _ready（调用方已守卫 enabled 才进来；二次应用幂等）
	await SafeAreaHelper.read_deferred(get_window())
	_apply_safe_area()


func _apply_safe_area() -> void:
	# R195 安全区应用（消费式契约=SafeAreaHelper.insets 注释）：根 FULL_RECT
	# offset 左/上取正、右/下取负——左上锚组随根让位，右上/底带锚组在让位域内再贴边。
	# 仅 realize/size_changed/焦点事件驱动，非每帧路径（R188 纪律）。
	var ins := SafeAreaHelper.insets(get_window())
	_hud_root.offset_left = ins.position.x
	_hud_root.offset_top = ins.position.y
	_hud_root.offset_right = -ins.size.x
	_hud_root.offset_bottom = -ins.size.y


func bind_events() -> void:
	# 订阅 player_hit / xp_gained / wave_started / enemy_killed / state_changed / damage_resolved
	EventBus.player_hit.connect(_on_player_hit)
	EventBus.xp_gained.connect(_on_xp_gained)
	EventBus.wave_started.connect(_on_wave_started)
	EventBus.enemy_killed.connect(_on_enemy_killed)
	EventBus.state_changed.connect(_on_state_changed)
	EventBus.damage_resolved.connect(_on_damage_resolved)
	EventBus.boss_spawned.connect(_on_boss_banner)
	Meta.achievements_changed.connect(_on_achievement_toast)   # 信号在 Meta（非 EventBus）
	Meta.settings_changed.connect(_on_meta_setting_changed)   # R196：构筑面板位置写口即时重挂
	EventBus.card_chosen.connect(_on_card_chosen_build)
	EventBus.trait_milestone.connect(_on_trait_milestone_toast)
	EventBus.reroll_granted.connect(_on_reroll_toast)
	EventBus.mechanics_intro.connect(_on_mechanics_intro)
	EventBus.slot_unlocked.connect(_on_slot_unlocked_toast)   # R183 解锁提示 + 面板即时重绘
	# R186 复活全屏反馈（G1 契约：EventBus.revive_burst(pos, charges_left)——has_signal
	# 守卫使本文件在信号落地前可独立编译，G1 落地后自动接线生效；行为等价直连）
	if EventBus.has_signal(&"revive_burst"):
		EventBus.connect(&"revive_burst", _on_revive_burst)
	# R187 共享组新信号（束数徽标/镜面角标/引爆读数即时刷新 + 镜面生成 toast）
	EventBus.laser_subbeam_spawned.connect(_on_r187_stats_dirty)
	EventBus.mirror_formed.connect(_on_mirror_formed_toast)
	EventBus.w8_detonated.connect(_on_r187_stats_dirty)
	EventBus.mine_dodged.connect(_on_mine_dodged_hud)   # 二db：躲过敌方爆炸授盾即时显条（专属 handler 小刷新）
	EventBus.shield_blocked.connect(_on_shield_blocked_hud)   # 二db L1：橙盾层数读数挡下即刷（四控件小刷新）


func setup(p_player: Node2D, p_spawner: Node = null) -> void:
	# 数值源注入（p_spawner：EnemySpawner 宽类型规避循环解析，同 player 惯例——
	# TargetBar 解析数据源；缺省 null 时走 enemy_spawner 组兜底查找）
	player = p_player
	_spawner = p_spawner


func refresh_stats() -> void:
	# HP/经验/等级/波次/击杀/计时（事件驱动 + 1Hz 兜底刷新共用）
	refresh_stats_calls += 1                     # R188-perf 测试观测口
	if player != null and is_instance_valid(player):
		var hp: float = player.get("hp")
		var max_hp: float = player.get("max_hp")
		var pct := 0.0 if max_hp <= 0.0 else clampf(hp / max_hp, 0.0, 1.0)
		_hp_fill.size = Vector2(maxf((HP_BAR_SIZE.x - 8.0) * pct, 16.0), HP_BAR_SIZE.y - 8.0)
		_hp_fill_style.bg_color = PopPalette.hp_fill(pct)
		_hp_label.text = "HP %d/%d" % [int(round(hp)), int(round(max_hp))]
		var xp: float = player.get("xp")
		var need: float = player.get("xp_need")
		var xp_pct := 0.0 if need <= 0.0 else clampf(xp / need, 0.0, 1.0)
		_xp_fill.size = Vector2(maxf((XP_BAR_SIZE.x - 6.0) * xp_pct, 3.0), XP_BAR_SIZE.y - 6.0)
		_level_label.text = "Lv %d" % int(player.get("level"))
		_build_label.text = _build_summary()
		# 护盾条（MEC_SHIELD 持有才显示：就绪满条亮青；充能期按剩余比例灰蓝）
		var s_interval: float = player.get("shield_interval")
		_shield_panel.visible = s_interval > 0.0
		if s_interval > 0.0:
			var s_ready: bool = player.get("shield_ready")
			var s_timer: float = player.get("shield_timer")
			var s_pct := 1.0 if s_ready else clampf(1.0 - s_timer / maxf(s_interval, 0.01), 0.05, 1.0)
			_shield_fill.size = Vector2(maxf((148.0 - 34.0 - 3.0) * s_pct, 8.0), 36.0 - 6.0)
			_shield_fill_style.bg_color = PopPalette.PLAYER.lerp(
				PopPalette.INK_SOFT, 0.35 * (1.0 - s_pct)) if not s_ready else PopPalette.PLAYER
			# 二cv#1：层数透出「X N」（有几层显示几层；typeof 判型防缺属性运行时错）
			var s_layers_v: Variant = player.get("shield_layers")
			var s_layers: int = int(s_layers_v) if typeof(s_layers_v) in [TYPE_INT, TYPE_FLOAT] else 0
			_shield_layers_label.text = "X %d" % s_layers if s_layers > 0 else ""
		# 二db 橙盾条（躲雷奖励：层>0 才显；填充=剩余时间比例〔10s=Player.TEMP_SHIELD_TIME，
		# 字面量同源〕，右端「N·Xs」=层数·剩余秒）
		_refresh_temp_shield_bar()               # 二db 橙盾条（1Hz 兜底通道；即时显条走 _on_mine_dodged_hud）
		var sig := _compute_build_sig()
		if sig != _build_sig:
			_build_sig = sig
			_refresh_build()
	# R7 修复（§5.12 P0）：徽章只显波数——图名前缀在 106px 圆内溢出裁切 = 波次看不见根因
	# R62 无尽局：超基波切「无尽 N」（N = wave − final_wave）——玩家可见的无尽深度进度
	if endless_depth_base > 0 and wave > endless_depth_base:
		_wave_label.text = "无尽 %d" % (wave - endless_depth_base)
	else:
		_wave_label.text = "第 %d 波" % wave
	_refresh_wave_left()                      # R209：1Hz 兜底（伴生/硬上限叠波等非击杀增量）
	if _gold_label != null and player != null and is_instance_valid(player):
		_gold_label.text = "◎ %d" % int(player.get("gold"))
	if _skill_btn != null and player != null and is_instance_valid(player):
		# R186 无技能角色置灰（G1 契约：player.has_skill() -> bool；has_method 守卫
		# 保证契约未落地环境维持现状，落地即自动生效）
		var has_skill := true
		if player.has_method(&"has_skill"):
			has_skill = bool(player.call(&"has_skill"))
		var ready_now: bool = has_skill and bool(player.call(&"skill_ready"))
		_skill_btn.disabled = not ready_now
		if not has_skill:
			_skill_btn.modulate.a = 0.3                              # 无技能：整键深置灰
		else:
			_skill_btn.modulate.a = 1.0 if ready_now else 0.55
		# 图标随角色切换（选人后开局/继续存档即时同步）
		var icon := TextureFactory.skill_icon(StringName(String(player.get("character_id"))))
		if _skill_icon.texture != icon:
			_skill_icon.texture = icon
			_skill_icon_fg.texture = icon
		if not has_skill:
			_skill_cd_label.text = ""
			_skill_icon_fg.modulate = Color(0.6, 0.62, 0.7, 1.0)     # 无技能：图标压暗灰
		elif ready_now:
			_skill_cd_label.text = ""
			_skill_icon_fg.modulate = Color.WHITE
		else:
			_skill_cd_label.text = "%ds" % ceili(float(player.get("skill_cd_left")))
			_skill_icon_fg.modulate = Color(0.72, 0.74, 0.82, 1.0)   # 冷却压灰（图标读感保留）
		# R246 升华态读口（HUD 升华反馈）：skills 泳道 Player.skill_sublime 局内布尔
		#（enable_sublime() 契约置位，拾取红色传说卡生效）→ 技能键红环描边
		#（PopPalette.RARITY_SUBLIME 单源取色）。has_method 守卫（R186 同式）保证契约
		# 未落地环境维持现状，skills 合入后自动生效；无技能角色置灰逻辑不动
		#（红环仅在 has_skill 角色上显示，深置灰键不叠加红反馈）
		var sublime_on := has_skill and player.has_method(&"enable_sublime") \
			and bool(player.get("skill_sublime"))
		if _skill_sublime_ring != null:
			_skill_sublime_ring.visible = sublime_on
		# R186 复活次数常驻徽标（血条右上「✚×N」：revive_burst 即时 + 1Hz 兜底；归零置灰）
		if _revive_badge != null:
			var rc := int(player.get("revives_left"))
			_revive_badge.text = "✚×%d" % rc
			# R230 K4：动态色同样走量化口（品质金/弱化灰蓝角色切换）
			_revive_badge.add_theme_color_override("font_color",
				StickerTheme.label_color(StickerTheme.LabelRole.GOLD) if rc > 0
				else StickerTheme.label_color(StickerTheme.LabelRole.SOFT))
		_refresh_r187_readout()
		# R19 技能效果时长条（增益期金色倒数——「不知道效果何时结束」终解）
		var fx_ratio: float = float(player.call(&"skill_active_ratio")) 			if player.has_method(&"skill_active_ratio") else 0.0
		if _skill_active_bar != null:
			_skill_active_bar.visible = fx_ratio > 0.0
			if fx_ratio > 0.0:
				_skill_active_bar.size.x = (_skill_btn.size.x - 8.0) * fx_ratio
			if fx_ratio > 0.0:
				_skill_icon_fg.modulate = Color(1.0, 0.85, 0.4, 1.0)   # 增益期金色高亮
	_kill_label.text = "击杀 %d" % kills
	_time_label.text = "%d:%02d" % [int(run_elapsed) / 60, int(run_elapsed) % 60]


func tick(p_raw_delta: float) -> void:
	# ①~⑧ 帧序 UI 阶段（raw 通道）：计时累计 + 1Hz 兜底刷新 + 波次 toast 衰减
	_tick_skill_auto_cast()                # R241 ④ 自动施放仲裁（内部五重门，非 PLAYING 直返）
	run_elapsed += p_raw_delta
	_fallback_timer += p_raw_delta
	if _fallback_timer >= 1.0:
		_fallback_timer = 0.0
		refresh_stats()
	if _toast_left > 0.0:
		_toast_left = maxf(_toast_left - p_raw_delta, 0.0)
		if _toast_left <= 0.0:
			_toast_label.visible = false
		elif _toast_left < TOAST_FADE:
			_toast_label.modulate.a = _toast_left / TOAST_FADE
	# R199（P08）首局拖动教学倒计时（raw 通道；仅 PLAYING 走秒——升级/暂停/结算态冻结，
	# 回 PLAYING 从冻结值续走；一次性标志防重弹）
	if _move_hint_wait >= 0.0 and not _move_hint_shown:
		if _state_cur == GameConst.GameStatus.PLAYING:
			_move_hint_wait -= p_raw_delta
			if _move_hint_wait <= 0.0:
				_move_hint_shown = true
				_move_hint_wait = -1.0
				_show_toast(GameConst.TUTORIAL_MOVE_BATTLE, MOVE_HINT_TIME)
	# R207：悬停说明卡=光标特性，触屏设备无 hover——mobile 整段跳过（vc14 真机
	# UI 段持续 10-20ms 之一刀；桌面行为不变）
	if not OS.has_feature("mobile"):
		_tick_hover()
	_tb_tick(p_raw_delta)   # R186 TargetBar（帧结算 + 每帧读血，并入 ⑧ UI 阶段既有调用）
	_flush_stats_tick(p_raw_delta)   # R188-perf 帧末同帧 flush + R212 刀2 模态态节流门


func _flush_stats_tick(p_raw_delta: float) -> void:
	# R212 刀2：帧末 flush 的节流门（mobile + LEVEL_UP/PAUSED 才生效；桌面/战斗态
	# 每帧 flush 原样）。进模态态首帧门全开（gate=0 → 首个脏帧立即 flush，HUD 进
	# 选卡期先同步一次），其后 0.25s 一档；xp_gained 风暴期 _stats_dirty 持真，
	# 中间帧跳过的是重复全量排版（displayed 值到档即同步，中间值本就不可见）。
	var throttled: bool = flush_throttle_override == 1 \
		or (flush_throttle_override < 0 and OS.has_feature("mobile") \
			and (_state_cur == GameConst.GameStatus.LEVEL_UP
				or _state_cur == GameConst.GameStatus.PAUSED))
	if not throttled:
		_flush_gate_left = 0.0
		flush_stats_dirty()     # R188-perf：帧末同帧 flush（事件风暴合并为一次全量刷新）
		return
	_flush_gate_left -= p_raw_delta
	if _flush_gate_left > 0.0:
		return
	_flush_gate_left = LEVELUP_FLUSH_INTERVAL_S
	flush_stats_dirty()


# ── R13 自绘悬停说明 ──────────────────────────────────────────────
func _add_hover(p_ctrl: Control, p_text: String) -> void:
	# 注册悬停区域（控制节点位置为显式布局值，构建期即可定矩形）
	_hover_zones.append({"rect": Rect2(p_ctrl.position, p_ctrl.size), "text": p_text,
		"ctrl": p_ctrl})


func _tick_hover() -> void:
	# 光标命中任一指标区 → 样式化说明卡跟随（屏幕坐标钳制；无命中即隐藏）
	if _hover_card == null:
		return
	var mouse := _hud_root.get_global_mouse_position()
	for zone: Dictionary in _hover_zones:
		var zc: Control = zone["ctrl"]
		if not is_instance_valid(zc) or not zc.is_visible_in_tree():
			continue
		# R195 适配：命中矩形取活全局矩形（右上锚组随视口宽移动，建期快照会陈旧；
		# 默认窗下根在原点、与建期快照逐位同值，行为零变化）
		if zc.get_global_rect().has_point(mouse):
			_hover_label.text = zone["text"]
			_hover_card.visible = true
			# R195 适配：钳制界改活画布（visible_rect；720×1280 下与原硬编码恒等）
			_hover_card.position = (mouse + Vector2(18.0, 18.0)).clamp(
				Vector2(8.0, 8.0),
				get_viewport().get_visible_rect().size - Vector2(340.0, 130.0))
			return
	_hover_card.visible = false


# ── 测试观测口（displayed 值，headless 断言用——文本口径锁定，勿改） ──
# R188-perf：读口兜底 flush（无帧推进的直发事件环境——读即见最新值，与逐次刷新等价）
func displayed_hp_text() -> String:
	flush_stats_dirty()
	return _hp_label.text


func displayed_wave() -> int:
	flush_stats_dirty()
	return wave


func displayed_kills() -> int:
	flush_stats_dirty()
	return kills


func displayed_level_text() -> String:
	flush_stats_dirty()
	return _level_label.text


# ── 事件 ──────────────────────────────────────────────────────────
# R188-perf：四个高频事件回调改「置脏 + 帧末同帧 flush」（此前逐次全量 refresh_stats
# =每事件 87~100µs，风暴帧线性劣化）。displayed_* 文本口径零改动：flush 时机在帧末/
# 观测口读取，内容与逐次刷新逐位一致。
func _on_player_hit(_p_damage: float, _p_source_uid: int) -> void:
	_stats_dirty = true


func _on_xp_gained(_p_amount: float) -> void:
	_stats_dirty = true


func _refresh_wave_left() -> void:
	# R209 波次余敌：spawner 待出生队列 + 场上活跃之和（「这波还要杀多少」；敌不含
	# 尸体/召唤伴生入队也计入——伴生 enqueue 同走队列，口径自洽）。宽类型读：setup
	# 注入缺失时走 enemy_spawner 组兜底（同 TargetBar 数据源惯例）
	if _wave_left_label == null:
		return
	var sp: Node = _spawner if _spawner != null and is_instance_valid(_spawner) \
		else get_tree().get_first_node_in_group("enemy_spawner")
	if sp == null:
		return
	var queue_v: Variant = sp.get("spawn_queue")
	var act_v: Variant = sp.get("active")
	if not (queue_v is Array) or not (act_v is Array):
		return
	var left: int = (queue_v as Array).size() + (act_v as Array).size()
	_wave_left_label.text = "余 %d" % left
	_wave_left_label.visible = left > 0


func _on_wave_started(p_wave: int) -> void:
	wave = p_wave
	_show_toast(Lore.wave_toast(p_wave))
	_stats_dirty = true
	_refresh_wave_left()                      # 发射在 start_wave enqueue 之后 → 直接读到整队


func _on_enemy_killed(p_enemy: Node2D) -> void:
	kills += 1
	# R186 TargetBar：Boss 在场旗清 + 锁定敌殒命只置出口标志不当场收起（R2 修③：
	# 下一次帧结算有合格候选优切，无候选才白闪收起）。注意连接序：本处理器晚于
	# spawner 死亡归还执行，tags 已被 _reset_state 清零（enemy.gd:1539）——Boss 判定
	# 只能走引用比对（同 boss_bar.gd:116 先例），is_boss() 标签在此不可用
	if p_enemy != null and p_enemy == _tb_boss_node:
		_tb_boss_node = null
		_tb_boss_on_field = false
	# R189：uid 缺省安全读（测试桩 Dictionary 无 uid 键 → get 返回 null，int(null)
	# 曾抛「Nonexistent 'int' constructor」脚本错误并中止本处理器——脏标记不置位）
	var killed_uid: Variant = p_enemy.get("uid") if p_enemy != null else null
	if killed_uid is int and int(killed_uid) == _tb_lock_uid:
		_tb_lock_dying = true
	_stats_dirty = true
	_refresh_wave_left()   # 本处理器晚于 spawner 归还（active 已减）→ 杀一只掉一号


func flush_stats_dirty() -> void:
	# R188-perf：脏标记同帧 flush（tick 帧末调用；displayed_* 观测口亦兜底直读）——
	# 同帧 N 次事件合并为一次全量 refresh_stats
	if not _stats_dirty:
		return
	_stats_dirty = false
	refresh_stats()


func _on_state_changed(p_state: int) -> void:
	# 状态提示（LEVEL_UP/PAUSED/GAME_OVER 覆盖显示；PLAYING 隐藏）+ 状态切换刷新
	# （升级→LEVEL_UP 的 state_changed 晚于 xp_gained——等级数值在此同步）
	_state_cur = p_state
	# R199（P08）：首次进入 PLAYING 排程拖动教学倒计时（一次性标志见 _move_hint_shown 注）
	if p_state == GameConst.GameStatus.PLAYING and not _move_hint_shown \
			and _move_hint_wait < 0.0:
		_move_hint_wait = MOVE_HINT_DELAY
	match p_state:
		GameConst.GameStatus.LEVEL_UP:
			_state_label.text = "LEVEL UP - choose a card"   # 文案锁定（pkg4 断言）
			_state_label.visible = true
		GameConst.GameStatus.PAUSED:
			_state_label.text = "PAUSED"
			_state_label.visible = true
		GameConst.GameStatus.GAME_OVER:
			_state_label.text = "GAME OVER"
			_state_label.visible = true
		_:
			_state_label.visible = false
	_pause_btn.visible = p_state == GameConst.GameStatus.PLAYING
	# R188-idle：AUTO 开关可见态 = PLAYING + LEVEL_UP（升级选卡/黑市模态期仍可切——
	# 「看着货架才想关挂机」；不照抄暂停钮仅 PLAYING 的口径）
	if _auto_btn != null:
		_auto_btn.visible = p_state == GameConst.GameStatus.PLAYING \
			or p_state == GameConst.GameStatus.LEVEL_UP
	if _skill_btn != null:
		_skill_btn.visible = p_state == GameConst.GameStatus.PLAYING   # 暂停按钮仅战斗态显示
	if _skill_auto_btn != null:
		_skill_auto_btn.visible = p_state == GameConst.GameStatus.PLAYING   # R241 ④ 自动施放键同技能键门
	if p_state != GameConst.GameStatus.PLAYING:
		_toast_left = 0.0                     # 状态覆盖期收起波次 toast
		_toast_label.visible = false
	# R186 TargetBar 状态联动（同 boss_bar.gd:121-127 事件源）：MENU/GAME_OVER 清空隐藏；
	# PAUSED/LEVEL_UP 冻结续窗/出口衰减，恢复 PLAYING 续计（不误消失）
	match p_state:
		GameConst.GameStatus.MENU, GameConst.GameStatus.GAME_OVER:
			_tb_hard_reset()
		GameConst.GameStatus.PAUSED, GameConst.GameStatus.LEVEL_UP:
			_tb_frozen = true
		_:
			_tb_frozen = false
	refresh_stats()


func set_map_name(p_name: String) -> void:
	# 地图名注入（GameLoop.start_run → HUD 波次前缀，M2 多地图）
	map_name = p_name


func _on_pause_pressed() -> void:
	# 暂停按钮回调（果冻 punch + 申请信号——仲裁权在 GameLoop）
	StickerTheme.press_punch(_pause_btn)
	pause_requested.emit()


func _on_skill_pressed() -> void:
	# 角色技能键（仲裁在 player.skill_ready；PLAYING 态才生效）；R186 无技能角色不可按
	if player != null and is_instance_valid(player):
		if player.has_method(&"has_skill") and not bool(player.call(&"has_skill")):
			return
		if bool(player.call(&"skill_ready")):
			player.call(&"activate_skill")


# ── R241 ④ 技能自动施放（Meta 单一真源，R188 AUTO 开关同款式样） ──────
func _on_skill_auto_pressed() -> void:
	var on := not bool(Meta.settings("skill_auto_cast"))
	Meta.set_setting("skill_auto_cast", on)
	_sync_skill_auto_visual()
	_show_toast("技能自动施放：%s" % ("开（冷却完成即自动施放）" if on else "关"), TOAST_TIME)


func _sync_skill_auto_visual() -> void:
	# 文案/配色双态（开=金;关=灰）；无技能角色压灰只读（施放链 has_skill 守卫仍拦）
	var on := bool(Meta.settings("skill_auto_cast"))
	if _skill_auto_label != null:
		_skill_auto_label.text = "自动施放" if on else "手动施放"
		_skill_auto_label.add_theme_color_override("font_color",
			StickerTheme.label_color(StickerTheme.LabelRole.GOLD) if on
			else StickerTheme.label_color(StickerTheme.LabelRole.SOFT))


func _tick_skill_auto_cast() -> void:
	# R241 ④ 施放帧：开态+PLAYING（state_changed 记录态）+未暂停（选卡/商店模态）+
	# 有技能+冷却完成 → 自动施放。逐帧两 call 仲裁（skill_ready 内含死亡守卫）。
	if player == null or not is_instance_valid(player):
		return
	if _state_cur != GameConst.GameStatus.PLAYING:
		return
	if not bool(Meta.settings("skill_auto_cast")):
		return
	if get_tree().paused:
		return
	if player.has_method(&"has_skill") and not bool(player.call(&"has_skill")):
		return
	if bool(player.call(&"skill_ready")):
		player.call(&"activate_skill")


# ── R188-idle AUTO 挂机开关（读写 Meta 单一真源，无缓存 bool） ──────
func _on_auto_toggle_pressed() -> void:
	# 点击翻转 → Meta.set_setting 落盘 → settings() 回填（单写口）→ toast 一次
	var on := not bool(Meta.settings("auto_select_on"))
	Meta.set_setting("auto_select_on", on)
	_sync_auto_visual()
	# 开关 toast 一次（逐次自动选卡禁 toast——噪音纪律见 idle 定案六）
	_show_toast("挂机模式：%s" % ("开（升级自动选卡 · 黑市自动出击）" if on else "关"),
		TOAST_TIME)


func _sync_auto_visual() -> void:
	# 胶囊态：OFF 弱灰描边（无填充）/ ON 金色填充（描边同步）——文字色随行
	if _auto_capsule_style == null:
		return
	var on := bool(Meta.settings("auto_select_on"))
	if on:
		_auto_capsule_style.bg_color = Color(PopPalette.GOLD.r, PopPalette.GOLD.g,
			PopPalette.GOLD.b, 0.92)
		_auto_capsule_style.border_color = PopPalette.GOLD.darkened(0.25)
	else:
		_auto_capsule_style.bg_color = Color(0.97, 0.97, 0.99, 0.86)
		_auto_capsule_style.border_color = PopPalette.INK_SOFT
	_auto_capsule.add_theme_stylebox_override("panel", _auto_capsule_style)
	if _auto_label != null:
		_auto_label.text = "AUTO"
		# R230 K4：动态色同样走量化口（正文墨/弱化灰蓝角色切换）
		_auto_label.add_theme_color_override("font_color",
			StickerTheme.label_color(StickerTheme.LabelRole.INK) if on
			else StickerTheme.label_color(StickerTheme.LabelRole.SOFT))


func is_auto_on() -> bool:
	# 测试观测口：当前挂机开关态（Meta 单一真源透传）
	return bool(Meta.settings("auto_select_on"))


# ── R187 武器形态读数（W4 束数 / W5 镜面 / W8 引爆——共享组读数位） ──
func _refresh_r187_readout() -> void:
	# 单行读数：仅显示在场武器对应段（束 ×N = 1+MEC_SPLIT_PRISM 层数、镜 ×N = 镜面数组、
	# 爆 ×N = DebugStats.w8_detonations）；全无则隐藏整行（零持有零视觉噪音）
	if _r187_readout == null:
		return
	var segments: Array[String] = []
	var sub_beams := 0
	var has_w4 := false
	var has_w8 := false
	if player != null and is_instance_valid(player):
		var slots: Array = player.get("weapon_slots")
		for w in slots:
			if w == null or not is_instance_valid(w):
				continue
			var wd: Variant = w.get("data")
			if wd == null:
				continue
			match String(wd.get("id")):
				"W4_pulse_beam":
					has_w4 = true
					sub_beams += 1 + _trait_layers_of(w, &"MEC_SPLIT_PRISM")
				"W8_orbit_field":
					has_w8 = true
		if player.has_method(&"mirror_count"):
			var mc := int(player.call(&"mirror_count"))
			if mc > 0:
				segments.append("镜 ×%d" % mc)
	if has_w4:
		segments.push_front("束 ×%d" % mini(sub_beams, 4))   # 主束 + 副束帽 3
	if has_w8:
		segments.append("爆 %d" % DebugStats.get_counter(&"w8_detonations"))
	if segments.is_empty():
		_r187_readout.visible = false
		return
	_r187_readout.visible = true
	_r187_readout.text = "  ".join(segments)


func _trait_layers_of(p_weapon: Node, p_tid: StringName) -> int:
	# 武器栈内指定词条总层数（HUD 只读口径——与武器侧直读挂载表同源）
	var total := 0
	var tstack: Variant = p_weapon.get("trait_stack")
	if tstack == null or tstack.get("traits") == null:
		return 0
	for tb: Variant in (tstack.get("traits") as Array):
		var td: Variant = tb.get("data")
		if td != null and StringName(str(td.get("id"))) == p_tid:
			total += int(tb.get("layers"))
	return total


func _on_r187_stats_dirty(_p_arg: Variant = null, _p_arg2: Variant = null) -> void:
	# 束数/引爆变化即时刷新（信号载荷两种签名——单参/双参统一可调用适配）
	_refresh_r187_readout()


func _on_mine_dodged_hud(_p_pos: Vector2) -> void:
	# 二db 躲过敌方爆炸授盾即时显条（R187 同款专属 handler——不走 _stats_dirty 全量 flush：
	# 橙条仅 4 控件小刷新，不背 laser 风暴的合并刷新语义；1Hz 兜底继续走 refresh_stats）
	_refresh_temp_shield_bar()


func _on_shield_blocked_hud(_p_pos: Vector2) -> void:
	# 二db L1：橙盾被消耗（挡下一次伤害）读数即时（层 N 秒级递减不误读）；蓝条维持
	# 1Hz 宅风不动——橙条是本批新读数，即时性优先
	_refresh_temp_shield_bar()


func _refresh_temp_shield_bar() -> void:
	# 二db 橙盾条刷新共用口（refresh_stats 1Hz 兜底 + mine_dodged 即时通道）
	if _temp_panel == null or player == null or not is_instance_valid(player):
		return
	var t_stacks_v: Variant = player.get("temp_shield_stacks")
	var t_stacks: int = int(t_stacks_v) if typeof(t_stacks_v) in [TYPE_INT, TYPE_FLOAT] else 0
	_temp_panel.visible = t_stacks > 0
	if t_stacks > 0:
		var t_left: float = float(player.get("temp_shield_left"))
		var t_pct := clampf(t_left / Player.TEMP_SHIELD_TIME, 0.0, 1.0)   # R253：读真源常量（原 /10.0 字面量与 player 脱钩风险）
		_temp_fill.size = Vector2(maxf((148.0 - 34.0 - 3.0) * t_pct, 8.0), 36.0 - 6.0)
		_temp_fill_style.bg_color = PopPalette.ORANGE.lerp(
			PopPalette.INK_SOFT, 0.35 * (1.0 - t_pct))
		_temp_label.text = "%d·%ds" % [t_stacks, int(ceil(t_left))]


func _on_mirror_formed_toast(p_text: String) -> void:
	# R187 镜面生成 toast（「棱镜映照：镜面承接了 X」——与 R183 金色「召唤僚机」句式分界）
	# R230 K4 复核：原冰青 lerp 自由色保留（K4 量化在此处收回——F9 门禁证伪「逐件独立
	# 配色」前提，29 站点本就共享 6 值色板，量化无 dc 收益不值可见配色变更）
	var toast := StickerTheme.label_sticker(Label.new(), 17,
		PopPalette.PLAYER.lerp(Color.WHITE, 0.62), 4, Color.WHITE, true)   # 冰青（禁金）
	toast.text = p_text
	toast.reset_size()
	# R198（r195-3）：720 设计域死坐标 (150,300)/(420,30) → 活宽拉伸锚（R195 波次 toast
	# 范式 :1502-1507 同源）——anchor_l=0/anchor_r=1 + offset 左右归 0 = 父域满宽拉伸，
	# 文本 HORIZONTAL_ALIGNMENT_CENTER 居中随动；y 保持设计位 300，720×1280 视觉逐位
	# 不变（旧中心 x=150+420/2=360 == 拉伸后 720/2=360）
	toast.anchor_right = 1.0
	toast.offset_left = 0.0
	toast.offset_right = 0.0
	toast.offset_top = 300.0
	toast.offset_bottom = 330.0
	toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(toast)
	var tw := toast.create_tween()
	tw.tween_property(toast, "position:y", 260.0, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_interval(1.1)
	tw.tween_property(toast, "modulate:a", 0.0, 0.35)
	tw.tween_callback(toast.queue_free)


func _on_trait_milestone_toast(_p_trait_id: StringName, p_name: String, p_mult: float) -> void:
	# 质变里程碑 toast（用户反馈 2026-08-31「buff 到什么程度会质变」）：词条满层 ×1.6 /
	# 武器 Lv5 终极形态（mult=0）——金色大 toast + 史诗音效，爽感节点可视化
	if SfxBank.I != null:
		SfxBank.I.play(&"tier_epic")
	var text := "◆ 质变！%s 数值 ×%.1f" % [p_name, p_mult] if p_mult > 0.0 \
		else "◆ %s —— 终极形态达成" % p_name
	var toast := StickerTheme.label_sticker(Label.new(), 22, StickerTheme.label_color(StickerTheme.LabelRole.GOLD), 5, Color.WHITE, true)
	toast.text = text
	toast.reset_size()
	_fit_font_size(toast, text, 520.0)
	# R198（r195-3）：活宽拉伸锚（同 :560 镜面 toast 注）——y 保持设计位 360；
	# scale 弹跳 pivot 取活宽中心（挂树后读 size，拉伸锚同帧生效）
	toast.anchor_right = 1.0
	toast.offset_left = 0.0
	toast.offset_right = 0.0
	toast.offset_top = 360.0
	toast.offset_bottom = 394.0
	toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(toast)
	toast.pivot_offset = toast.size * 0.5
	var tw := toast.create_tween()
	tw.tween_property(toast, "scale", Vector2.ONE * 1.18, 0.12).from(Vector2.ONE * 0.6) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_interval(1.6)
	tw.tween_property(toast, "modulate:a", 0.0, 0.4)
	tw.tween_callback(toast.queue_free)


func _on_reroll_toast(p_count: int) -> void:
	# 刷新次数获得 toast（选卡刷新机制）：小 toast + 金币音——「换一批 ×N」余量可见
	if SfxBank.I != null:
		SfxBank.I.play(&"coin")
	var toast := StickerTheme.label_sticker(Label.new(), 17, StickerTheme.label_color(StickerTheme.LabelRole.PLAYER), 4, Color.WHITE, true)
	toast.text = "换一批次数 +%d" % p_count
	# R198（r195-3）：活宽拉伸锚（同 :560 镜面 toast 注）——y 保持设计位 300
	toast.anchor_right = 1.0
	toast.offset_left = 0.0
	toast.offset_right = 0.0
	toast.offset_top = 300.0
	toast.offset_bottom = 330.0
	toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(toast)
	var tw := toast.create_tween()
	tw.tween_property(toast, "position:y", 260.0, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_interval(1.4)
	tw.tween_property(toast, "modulate:a", 0.0, 0.4)
	tw.tween_callback(toast.queue_free)


var _intro_frame_stamp: int = -1                  # R253 QA BUG-1：mechanics_intro 同帧合并账
var _intro_merged_text: String = ""


func _on_mechanics_intro(p_text: String) -> void:
	# 大关新机制解锁横幅（开局宣告）：复用波次 toast 位 + 加长展示时长（文案需读完）。
	# R253 QA BUG-1 同帧合并：apply_choice 先发「词条栏已满」、尾部 emit_card_chosen 触发
	# 词条首获 → 祝福解锁播报同帧后到——单 Label 直发后者覆写前者（R238 H2「栈满降级
	# 不再静默」被吞，新档 r238 ④c 必红）。同帧第二条起拼接重发（TOAST_MAX_LINES 钳制
	# 兜底）；金卡解锁播报（:1106 同通道）同享防覆盖。事件本身仍逐条广播（测试面零改）。
	var frame := Engine.get_process_frames()
	if frame == _intro_frame_stamp:
		_intro_merged_text += "\n" + p_text
		_show_toast(_intro_merged_text, INTRO_TOAST_TIME)
		return
	_intro_frame_stamp = frame
	_intro_merged_text = p_text
	_show_toast(p_text, INTRO_TOAST_TIME)


func _on_achievement_toast(p_ach_id: StringName) -> void:
	# 成就达成 toast（右上滑入）——R191#6 同帧合批：回调只收集 id，call_deferred 一帧后
	# flush 为单条聚合文案「成就达成 ×N：…（+X 结晶）」（同位叠放问题一并消除；
	# 0 奖不显金额、>ACH_TOAST_MAX_NAMES 名截断——见 _flush_achievement_toast；
	# R196：奖杯/结晶 emoji 字面量移除——Android 系统字体链缺字形，apk_menu_no_icons 定案）
	_ach_toast_pending.append(p_ach_id)
	if _ach_toast_scheduled:
		return
	_ach_toast_scheduled = true
	_flush_achievement_toast.call_deferred()


func _flush_achievement_toast() -> void:
	# 一帧 flush：pending 聚合为单条 toast（reward=0 条目不计金额——R191#6 阶梯中间档无奖励）
	_ach_toast_scheduled = false
	if _ach_toast_pending.is_empty():
		return
	var names: Array[String] = []
	var total := 0
	for aid in _ach_toast_pending:
		var aname := String(aid)
		for a in Meta.ACHIEVEMENTS:
			if a.id == aid:
				aname = String(a.name)
				total += int(a.get("reward", 0))
				break
		names.append(aname)
	var count := _ach_toast_pending.size()
	_ach_toast_pending.clear()
	# 名称截断（R191 评审：旧档高计数玩家首启可同帧解锁数十条，全量拼接数千 px 超屏
	# 不可读——只列前 ACH_TOAST_MAX_NAMES 名 + 「…等 N 项」，文本宽度有上界）
	var summary := "、".join(names.slice(0, ACH_TOAST_MAX_NAMES))
	if names.size() > ACH_TOAST_MAX_NAMES:
		summary += "…等 %d 项" % names.size()
	var toast := StickerTheme.label_sticker(Label.new(), 17, StickerTheme.label_color(StickerTheme.LabelRole.GOLD), 4, Color.WHITE, true)
	toast.name = "AchToast"                       # 测试观测口（合批断言按名定位）
	# R191 定案（阶梯中间档 0 结晶）：reward=0 不显示金额——total>0 才拼「（+X）」金额段
	# R196：奖杯/结晶 emoji 字面量移除（Android 系统字体链缺字形——apk_menu_no_icons 定案）
	if total > 0:
		toast.text = "成就达成 ×%d：%s（+%d）" % [count, summary, total]
	else:
		toast.text = "成就达成 ×%d：%s" % [count, summary]
	# R198（r195-3）：活宽拉伸锚（同 :560 镜面 toast 注）——y 保持设计位 300
	toast.anchor_right = 1.0
	toast.offset_left = 0.0
	toast.offset_right = 0.0
	toast.offset_top = 300.0
	toast.offset_bottom = 330.0
	toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(toast)                               # HUD 自身即 CanvasLayer 宿主
	var tw := toast.create_tween()
	tw.tween_property(toast, "position:y", 260.0, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_interval(1.9)
	tw.tween_property(toast, "modulate:a", 0.0, 0.4)
	tw.tween_callback(toast.queue_free)


func _on_boss_banner(p_boss: Node2D) -> void:
	# Boss 出场横幅演出（表现层一期：弹入 → 停留 1.6s → 淡出）
	# R186 TargetBar 让位（同 boss_bar 事件源）：Boss 在场 → 杂兵目标条下移 y190；
	# 引用留档供死亡旗清（连接序晚于池归还，标签已被清——见 _on_enemy_killed 注）
	if p_boss != null:
		_tb_boss_on_field = true
		_tb_boss_node = p_boss
	var ename := "未知聚合体"
	var d: Variant = p_boss.get("data")
	if d != null:
		ename = String(d.get("display_name"))
	_boss_banner.text = "⚠ %s 降临" % ename
	_boss_banner.visible = true
	_boss_banner.pivot_offset = _boss_banner.size * 0.5
	_boss_banner.scale = Vector2(1.6, 1.6)
	_boss_banner.modulate.a = 0.0
	var tw := _boss_banner.create_tween()
	tw.tween_property(_boss_banner, "scale", Vector2.ONE, 0.22)\
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(_boss_banner, "modulate:a", 1.0, 0.18)
	tw.tween_interval(1.6)
	tw.tween_property(_boss_banner, "modulate:a", 0.0, 0.4)
	tw.tween_callback(func() -> void: _boss_banner.visible = false)


func _on_build_gui_input(p_ev: InputEvent) -> void:
	# 左下角构筑面板点击（R194 松手判定：按下武装 → 释放且位移 <16px 才发详情申请——
	# 触控目标贴边易误滑，按下即发会把滑动起点误判为点击；GameLoop 仲裁不变）
	if p_ev is InputEventMouseButton and (p_ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := p_ev as InputEventMouseButton
		if mb.pressed:
			_build_press_pos = mb.position            # 按下记录锚点 + 武装
			_build_armed = true
			return
		_build_armed = _build_armed and mb.position.distance_to(_build_press_pos) < BUILD_CLICK_SLOP_PX
		if _build_armed:
			build_details_requested.emit()
		_build_armed = false
	elif p_ev is InputEventMouseMotion and _build_armed:
		# 按住期间拖出阈值 → 解除武装（本次释放不再视为点击）
		if (p_ev as InputEventMouseMotion).position.distance_to(_build_press_pos) >= BUILD_CLICK_SLOP_PX:
			_build_armed = false


func _apply_build_panel_pos() -> void:
	# R196 构筑面板位置三档（Meta.settings("panel_pos")：0=右上 1=右下 2=左下）；R197 竖排
	# 两列改版：尺寸 252×132 → 140×258（窄高——左列武器/右列词条），三落位随之重排：
	# R208 面板收窄 140→118（真机反馈右侧空白）——三档右沿口径保持（右上右沿 696、
	# 右下右沿 584、左下左沿 24），仅宽收：
	# · 右上 x578-696×y196-454：暂停钮 y26-98 / 金币 pill y92-128 / AUTO y126-190 /
	#   波次徽章 y16-122 / BossBar y112-184 全部 y<196，持久元素零冲突；Boss 出场横幅
	#   y210-256 为 ~2.2s 瞬态 IGNORE 标签，面板（后挂）压其上可短暂遮文案尾——可接受。
	# · 右下 x466-584×y998-1256：右沿 W-136 < 技能键左沿恒 W-110，任意宽度零重叠
	#   （技能键 R196 已改右缘锚）。
	# · 左下 x24-142×y998-1256：贴底 24px 与左沿 24 保持 R195 口径。
	# 驱动双口：_build_ui 末尾（初始落位）+ settings_changed("panel_pos")（写口即时重挂）。
	if _build_panel == null:
		return
	match clampi(int(Meta.settings("panel_pos")), 0, 2):
		0:                                    # 右上（默认）：锚 l/r=1、t/b=0
			_build_panel.anchor_left = 1.0
			_build_panel.anchor_right = 1.0
			_build_panel.anchor_top = 0.0
			_build_panel.anchor_bottom = 0.0
			_build_panel.offset_left = -142.0  # x578
			_build_panel.offset_top = 196.0
			_build_panel.offset_right = -24.0  # x696
			_build_panel.offset_bottom = 454.0
		1:                                    # 右下：全 1 锚
			_build_panel.anchor_left = 1.0
			_build_panel.anchor_right = 1.0
			_build_panel.anchor_top = 1.0
			_build_panel.anchor_bottom = 1.0
			_build_panel.offset_left = -254.0  # x466
			_build_panel.offset_top = -282.0   # y998
			_build_panel.offset_right = -136.0 # x584
			_build_panel.offset_bottom = -24.0  # y1256
		2:                                    # 左下（原位）：贴底/左沿保持 R195 口径
			_build_panel.anchor_left = 0.0
			_build_panel.anchor_right = 0.0
			_build_panel.anchor_top = 1.0
			_build_panel.anchor_bottom = 1.0
			_build_panel.offset_left = 24.0
			_build_panel.offset_top = -282.0
			_build_panel.offset_right = 142.0
			_build_panel.offset_bottom = -24.0


func _on_meta_setting_changed(p_key: String) -> void:
	# R196：设置页「构筑面板位置」循环行 → set_setting 写口经本订阅即时重挂（键守卫）
	# R202：show_fps 同款键守卫接线（fps_cap/fx_opacity 先例——消费端各自订阅/单点应用）
	if p_key == "panel_pos":
		_apply_build_panel_pos()
	elif p_key == "show_fps":
		_apply_show_fps()


# ── R202 帧率显示（设置键 show_fps：HUD 右缘小字读数，纯显示） ──────
func _apply_show_fps() -> void:
	# 消费端单点：boot 末段初值（_build_ui 收口）+ settings_changed("show_fps") 即时切换，
	# 只切 visible（节点急切建好）。与 fps_cap 正交：fps_cap 是 mobile 门内 Engine.max_fps
	# 帽（meta_manager._apply_fps_cap），show_fps 纯显示互不依赖。关态 set_process(false)
	# ——_process 每帧刷新只在开启期挂起，关即零常驻开销。
	if _fps_label == null:
		return
	var on := bool(Meta.settings("show_fps"))
	_fps_label.visible = on
	set_process(on)


var _fps_diag_tick: int = 0                     # R204：诊断节流（dc/obj 15 帧一取）
var _fps_diag_text: String = ""                 # 缓存段（两取之间不重建字符串）
var _fps_last: int = -1                         # R188⑦：FPS 读数缓存（-1=未建；读数与诊断段
                                                # 均不变时整行文本不重建——稳态帧零 String 构造）


func _process(_p_delta: float) -> void:
	# R202：FPS 读数每帧刷新（Engine.get_frames_per_second() 引擎平滑口径）。
	# 仅 show_fps 开启期到达（_apply_show_fps 关态 set_process(false) 挂起本回调）；
	# headless 安全无需门（无渲染循环下读数恒 0，不崩）。
	# R204：附绘制诊断（15 帧一取——RenderingServer 帧级计数 dc/obj）：
	# 真机再遇掉帧时读数直接给出「画布项/绘制调用是否爆炸」的证据，不用猜。
	# R188⑦：读数/诊断段任一未变不重拼文本（诊断段更新帧强制刷一次，防 15 帧节流段
	# 变了却被读数缓存吞掉）；文本内容与旧逐帧拼接逐位一致
	if _fps_label == null or not _fps_label.visible:
		return
	_fps_diag_tick += 1
	var diag_changed := false
	if _fps_diag_tick % 15 == 0:
		var dc := RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
		var obj := RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME)
		_fps_diag_text = " dc %d o %d" % [dc, obj]
		diag_changed = true
	var fps := Engine.get_frames_per_second()
	if diag_changed or fps != _fps_last:
		_fps_last = fps
		_fps_label.text = "FPS %d" % fps + _fps_diag_text


# ── R220 刀11：damage_resolved 累计聚合 30Hz 降频门（R207 半频相位先例） ──
# mobile 门内隔帧消费：关门帧结果引用暂存（保序）、开门帧一并累计——total_damage/
# TargetBar _agg 累计值不丢、时序不变，只把回调频率压半（HUD 常驻订阅的每帧 dict
# 操作 ×N 命中减半）。桌面/headless 与注入口 0=每帧原路径（既有测试同步断言不受扰）。
var dmg_half_freq_override: int = -1         # 测试注入口（-1=平台自动 / 0=每帧 / 1=半频）
var _dmg_subtick_left: int = 1               # 半频相位（1=本帧消费；R206 _ui_subtick 同款）
var _dmg_pending: Array[DamageResult] = []   # 关门帧暂存队列（开门帧保序消费）


func _dmg_half_freq() -> bool:
	if dmg_half_freq_override >= 0:
		return dmg_half_freq_override == 1
	return OS.has_feature("mobile")


func _on_damage_resolved(p_result: DamageResult) -> void:
	# R220 刀11：批化消费入口（EventBus 派发时点=⑧段前 game_loop dispatch——本回调在
	# 派发批内保序到达）；30Hz 门内关门帧暂存、开门帧一并 _apply_damage_result。
	if _dmg_half_freq():
		_dmg_pending.append(p_result)
		_dmg_subtick_left -= 1
		if _dmg_subtick_left > 0:
			return                           # 关门帧：暂存（累计值不丢）
		_dmg_subtick_left = 2
		for r in _dmg_pending:
			_apply_damage_result(r)
		_dmg_pending.clear()
		return
	_apply_damage_result(p_result)


func _apply_damage_result(p_result: DamageResult) -> void:
	# 总伤害统计（结算屏数据源；HUD 不逐次刷新——1Hz 兜底承担）
	total_damage += p_result.final_value
	# R186 TargetBar 聚合（回调纪律 O(1)，严禁扫树——风暴线 event_bus.gd:54）：合格伤害
	# （popup_style ∈ {NORMAL, CRIT, REACTION}）累加伤害和；DOT/HEAL/XP/IMMUNE 不入聚合
	# （天然无提案权与续窗权——停火被烧怪 2.5s 自然淡出）；正面盾 0 伤直击 popup=NORMAL
	# 仍入聚合（恰是需读条场景）。解析只发生在帧结算且受 TB_RESOLVE_BUDGET 封顶。
	match p_result.popup_style:
		GameConst.PopupStyle.NORMAL, GameConst.PopupStyle.CRIT, GameConst.PopupStyle.REACTION:
			var uid := int(p_result.target_uid)
			_agg[uid] = float(_agg.get(uid, 0.0)) + float(p_result.final_value)
			_agg_frame = int(p_result.frame_stamp)
		_:
			pass


func _next_level_note(p_w: Node, p_lv: int) -> String:
	# 下一级质变说明（数据源 = 等级表 note 字段；满级返回空）
	if p_lv >= 5:
		return ""
	var wdata: Variant = p_w.get("data")
	if wdata == null:
		return ""
	var table: Array = wdata.get("upgrade_table")
	if table == null or p_lv >= (table as Array).size():
		return ""
	return String((table as Array)[p_lv].get("note"))


func _build_summary() -> String:
	# 词条栏：武器数 + 武器词条数（构筑统计；正式构筑面板后续迭代）
	if player == null or not is_instance_valid(player):
		return "构筑 -"
	var slots: Array = player.get("weapon_slots")
	var wcount := 0
	var tcount := 0
	for w in slots:
		if w != null and is_instance_valid(w):
			wcount += 1
			var stack: Variant = w.get("trait_stack")
			if stack != null and stack.get("traits") != null:
				tcount += (stack.get("traits") as Array).size()
	return "构筑  W:%d T:%d" % [wcount, tcount]


func _on_slot_unlocked_toast(p_slot: int) -> void:
	# R183 槽位解锁反馈（评审：此前零提示且面板不重绘——「锁一直挂着、莫名其妙开了」）：
	# 复用波次 toast 位播报 + 构筑签名失效（下帧 refresh_stats 即时重绘锁徽 → 空槽）。
	# R185：已解锁不重播（金卡先到后的里程碑重放）+ 被帽截断不播（不误导）；
	# 金卡自己的解锁播报走 mechanics_intro（此事件若再发会被玩家侧解锁处理器二次消费）
	if player == null or not is_instance_valid(player):
		return
	if p_slot <= int(player.get("unlocked_slots")):
		return
	if player.has_method(&"slot_cap_total") and p_slot > int(player.call(&"slot_cap_total")):
		return
	_show_toast("武器槽 %d 解锁" % p_slot)
	_build_sig = ""


func _on_card_chosen_build(_card_id: StringName, _target_kind: int) -> void:
	# 选卡应用 → 构筑面板强制重建（1Hz 兜底之外的即时响应）
	_build_sig = ""


func _compute_build_sig() -> String:
	# 构筑签名：武器 uid:level + 词条 id:layers（挂载序）——变化才重建面板
	if player == null or not is_instance_valid(player):
		return "-"
	var sig := ""
	# R183：解锁态入签名（unlocked/有效帽变化 → 锁徽记即时增减，不等下一张卡）
	if player.has_method(&"slot_cap_total"):
		sig += "u%d.%d;" % [int(player.get("unlocked_slots")),
			int(player.call(&"slot_cap_total"))]
	var slots: Array = player.get("weapon_slots")
	for w in slots:
		if w != null and is_instance_valid(w):
			sig += "w%d:%d;" % [int(w.get("uid")), int(w.get("level"))]
			var stack: Variant = w.get("trait_stack")
			if stack != null and stack.get("traits") != null:
				for t: Variant in (stack.get("traits") as Array):
					var tb: Variant = t
					var td: Variant = tb.get("data")
					if td != null:
						sig += "t%s:%d;" % [String(td.get("id")), int(tb.get("layers"))]
	return sig


func _refresh_build() -> void:
	# 构筑面板重建（R197 竖排两列——用户反馈「右上角落位后横排不如竖着两列」）：
	# 左列 = 武器槽自上而下（R183 按有效帽画满——持有=图标+Lv 右侧；空槽=圆环；
	# 未解锁=锁徽贴纸上锁样式）；右列 = 词条宝石自上而下（跨武器聚合挂载序）
	if _build_panel == null or player == null or not is_instance_valid(player):
		return
	for child in _build_panel.get_children():
		if child.name != "BuildBg":
			child.queue_free()
	var content := Control.new()
	content.name = "BuildContent"
	content.position = Vector2(10.0, 6.0)
	content.size = Vector2(120.0, 228.0)
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_panel.add_child(content)
	# ① 左列·武器槽竖排（R183：槽位数 = 难度有效帽（5/6/6，金卡帽内提前解锁同帽）——
	# 「上限有多少画多少」；内容高 228 按槽均分（cap5=45.6 / cap6=38），图标随行高
	# 自适应（20~32px——帽 7 防御分支自动缩档防溢出）
	var slots: Array = player.get("weapon_slots")
	var unlocked: int = int(player.get("unlocked_slots"))
	var cap := 5
	if player.has_method(&"slot_cap_total"):
		cap = clampi(int(player.call(&"slot_cap_total")), 1, 7)
	var row_h := 228.0 / float(cap)
	var icon_size := clampf(row_h - 8.0, 20.0, 32.0)
	for i in range(cap):
		var w: Variant = slots[i] if i < slots.size() else null
		var row_y := float(i) * row_h
		var icon := TextureRect.new()
		icon.name = "Wpn%d" % i
		icon.position = Vector2(0.0, row_y + (row_h - icon_size) * 0.5)
		icon.custom_minimum_size = Vector2(icon_size, icon_size)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if w != null and is_instance_valid(w):
			var wdata: Variant = w.get("data")
			icon.texture = TextureFactory.weapon_icon(
				StringName(str(wdata.get("id"))) if wdata != null else &"W_MISSING")
			# 悬停说明（R10「每个标识鼠标移上去应有解释」）：名称/等级 + 下一级质变预览
			var wlv: int = int(w.get("level"))
			# R190：机制一句话置顶（GameConst.weapon_note——R187 同步口径，棱镜/蓄能等
			# 特殊机制读图标猜不出，hover 必须先说玩法再说数值）
			var note := GameConst.weapon_note(String(wdata.get("id")) if wdata != null else "")
			var tip := ""
			if note != "":
				tip += note + "\n"
			tip += "%s Lv%d" % [String(wdata.get("display_name")) if wdata != null else "?", wlv]
			var next_note := _next_level_note(w, wlv)
			if next_note != "":
				tip += "\n下一级：%s" % next_note
			else:
				tip += "\n已满级 · 终极形态"
			icon.tooltip_text = tip
			# R196 评审修复（断触补口）：STOP 子件是 GUI 命中最深层——其上起手的
			# ScreenDrag 在此被吞（tooltip 悬停 mouse_entered 与 filter 无关，PASS 仍
			# 可悬停提示）。图标无点击处理器 → PASS：tooltip 保留、拖动链放行
			icon.mouse_filter = Control.MOUSE_FILTER_PASS
			content.add_child(icon)
			# R200（真机反馈「buff 显示的字很小」）：字号 11→14；R203 真机二次反馈
			# 「又变小」→14→16（1.5K-2K 屏 720 逻辑宽下 14pt≈8.2dp 仍低于可读档，
			# HP 条 18pt 为基准）。承载宽 = 宝石列 x74 − (icon+4)（R203 右沿 66→74 让位，
			# 位置仍 icon+4、间隙仍 4px），icon 帽 32 时 = 38px，「Lv10」@16pt ≈ 37px
			var lv := StickerTheme.label_sticker(Label.new(), 16, StickerTheme.label_color(StickerTheme.LabelRole.INK), 0, Color.WHITE, true)
			lv.text = "Lv%d" % int(w.get("level"))
			lv.size = Vector2(74.0 - icon_size - 4.0, 18.0)
			lv.position = Vector2(icon_size + 4.0, row_y + (row_h - 18.0) * 0.5)
			content.add_child(lv)
		else:
			# R183 上锁样式：锁徽 + 暗环（用户口径「另外就弄个上锁的样式」）——
			# 解锁靠波次里程碑/金卡扩容，未解锁槽位一眼可辨（原实现仅压暗）
			var locked := i >= unlocked
			icon.texture = TextureFactory.ring_tex(
				PopPalette.INK_SOFT if locked else PopPalette.INK_SOFT.lerp(Color.WHITE, 0.4),
				36, 2.6)
			icon.modulate.a = 0.28 if locked else 0.6
			content.add_child(icon)
			if locked:
				# R183 悬停说明：玩家能看懂怎么解锁（评审反馈「锁着但没说怎么开」）
				# R196：锁 emoji 字面量 → ui_lock 程序贴纸（Android 系统字体链缺 emoji
				# 字形——apk_menu_no_icons 定案；与上方 ring_tex 同容器口径 TextureRect，
				# 观察名 Lock%d 保留）
				icon.tooltip_text = "尚未解锁——随波次推进与 Boss 掉落逐步解锁（金卡可提前解锁一把）"
				# R196 评审修复（断触补口）：同上——锁槽悬停提示 PASS 仍可触发，
				# 拖动链不再被图标行吞掉
				icon.mouse_filter = Control.MOUSE_FILTER_PASS
				var lock := TextureRect.new()
				lock.name = "Lock%d" % i
				lock.texture = TextureFactory.ui_lock()
				lock.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				lock.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				# R208（真机反馈「锁的图标太小」）：14 固定 → 0.7×行图标比例放大
				# （cap5 行 45.6/icon32 → 锁 22.4；cap6 行 38/icon30 → 锁 21；小屏
				# icon20 → 14 兜底不变），仍居中于暗环
				var lock_sz := maxf(icon_size * 0.7, 14.0)
				lock.size = Vector2(lock_sz, lock_sz)
				lock.position = Vector2((icon_size - lock_sz) * 0.5,
					row_y + (row_h - lock_sz) * 0.5)
				lock.mouse_filter = Control.MOUSE_FILTER_IGNORE
				content.add_child(lock)
	# ② 右列·词条宝石竖排（跨武器聚合挂载序：R284 动态扩容——原硬上限 7 枚行距 30
	# 固定，R226 拆叠层帽后困难局词条种类轻松超 7，第 8 枚起只剩「+N」小字=用户
	# 反馈「两列 buff 显示不全」。修=行距动态均分：≤7 枚行距 30 现状逐位；8-9 枚
	# 压缩至 content 高 228 均分（28.5/25.3px，宝石 22 仍放下）；>9 枚显示 9 枚，
	# 第 9 枚行层数字位替换为「+N」角标（第 9 枚宝石保留）
	var gems: Array = []
	for w in slots:
		if w == null or not is_instance_valid(w):
			continue
		var stack: Variant = w.get("trait_stack")
		if stack == null or stack.get("traits") == null:
			continue
		for t: Variant in (stack.get("traits") as Array):
			var tb: Variant = t
			var td: Variant = tb.get("data")
			if td != null:
				gems.append({"pool": int(td.get("pool")), "layers": int(tb.get("layers")),
					"tid": StringName(str(td.get("id")))})
	var gem_show := mini(gems.size(), 9)
	var gem_step := 30.0
	if gems.size() > 7:
		gem_step = 228.0 / float(maxi(gem_show, 1))
	var gem_last := gem_show - 1
	for gi in range(gem_show):
		var gy := float(gi) * gem_step
		var gem_icon := TextureRect.new()
		gem_icon.name = "Gem%d" % gi
		gem_icon.texture = TextureFactory.type_icon(1, int(gems[gi]["pool"]))
		gem_icon.position = Vector2(74.0, gy + (gem_step - 22.0) * 0.5)
		gem_icon.custom_minimum_size = Vector2(22.0, 22.0)
		gem_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		gem_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		gem_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		content.add_child(gem_icon)
		# 第 9 枚行在溢出态让出层数字位给「+N」（>9 枚才有溢出态）
		if gi == gem_last and gems.size() > gem_show:
			continue
		if int(gems[gi]["layers"]) > 1:
			# R200（真机反馈「buff 显示的字很小」）：字号 10→14；R203 二次反馈→16、
			# 宽 24→28；R208 面板收窄 140→118——x 96→92→88（右沿 88+28=116 ≤ 118，
			# 右对齐收敛保持）。
			# R226 有意契约变更：叠层帽拆除后两位数 ×N 局内可达（原 R196 帽全池最高 ×9）
			# ——承载宽 28→36、x 88→80（右沿 80+36=116 ≤ 118 右对齐收敛保持，
			# ×2..×99 @16pt 字符串度量 ≤36px 承载；三位数按引擎 Label min-width 再议）
			var cnt := StickerTheme.label_sticker(Label.new(), 16, StickerTheme.label_color(StickerTheme.LabelRole.INK), 0, Color.WHITE, true)
			cnt.text = "×%d" % int(gems[gi]["layers"])
			cnt.size = Vector2(36.0, 18.0)
			cnt.position = Vector2(80.0, gy + (gem_step - 18.0) * 0.5)
			cnt.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			content.add_child(cnt)
	# R198（r197-1）：第 gem_show+1 枚起静默截断 → 补「+N」溢出提示（R284：位置从
	# 固定 y=210 改第 9 枚行层数字位——面板满排后无独立溢出行；第 9 枚宝石保留可辨）。
	# 节点名取「OverflowGem」——规划字面「GemOverflow」
	# 恰以 Gem 开头，会使「Gem0..GemN 恰 N 枚」的 begins_with("Gem") 计数断裂
	# （r197_build_panel_cases.gd B③ / r198 G③ / r196_growth_cases 同名前缀消费），
	# 本条自身的「非 Gem* 前缀」约束优先，令名保留语义 token
	if gems.size() > gem_show:
		var overflow := StickerTheme.label_sticker(Label.new(), 16, StickerTheme.label_color(StickerTheme.LabelRole.SOFT))
		overflow.name = "OverflowGem"
		overflow.text = "+%d" % (gems.size() - gem_show)
		overflow.position = Vector2(80.0, float(gem_last) * gem_step + (gem_step - 18.0) * 0.5)
		overflow.size = Vector2(36.0, 18.0)
		overflow.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		content.add_child(overflow)


# ── 程序化 UI 组装（方向 C 贴纸风） ────────────────────────────────
func _build_ui() -> void:
	# R186 TargetBar（左上「当前攻击单位」白胶囊血条：视觉向 BossBar 看齐弱一档；
	# 节点名锁定设计案 §4。挂 Root 首子（Root 建成后 add_child 收口）= 画在 HUD 内容
	# 下层（z 序同旧 CanvasLayer 直挂）且安全区 insets 经 Root offset_* 随根让位——
	# §3.3 #1 顶带左上锚组契约，直挂 CanvasLayer 则让位应用不到）
	_tb_root = Control.new()
	_tb_root.name = "TargetBarRoot"
	_tb_root.theme = StickerTheme.theme()
	_tb_root.position = Vector2(24.0, TB_POS_Y)
	_tb_root.size = TB_SIZE
	_tb_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tb_root.visible = false
	_tb_root.modulate.a = TB_BASE_ALPHA
	_tb_panel = _sticker_panel(_tb_root, Vector2.ZERO, TB_SIZE, 13.0)
	_tb_panel.name = "TargetPanel"
	_tb_fill = Panel.new()
	_tb_fill.name = "TargetFill"
	_tb_fill_style = StyleBoxFlat.new()
	_tb_fill_style.bg_color = PopPalette.ENEMY
	_tb_fill_style.set_corner_radius_all(8)
	_tb_fill.add_theme_stylebox_override("panel", _tb_fill_style)
	_tb_fill.position = Vector2(4.0, 4.0)                    # 4px 内缩同 HP 条口径
	_tb_fill.size = Vector2(TB_SIZE.x - 8.0, TB_SIZE.y - 8.0)
	_tb_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tb_panel.add_child(_tb_fill)
	_tb_ghost = Panel.new()
	_tb_ghost.name = "TargetGhost"
	var tghost_style := StyleBoxFlat.new()
	tghost_style.bg_color = Color(1.0, 1.0, 1.0, 0.85)       # E6 白残影（boss_bar.gd:173 同色）
	tghost_style.set_corner_radius_all(8)
	_tb_ghost.add_theme_stylebox_override("panel", tghost_style)
	_tb_ghost.position = Vector2(4.0, 4.0)
	_tb_ghost.size = Vector2.ZERO
	_tb_ghost.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tb_panel.add_child(_tb_ghost)
	_tb_name_label = StickerTheme.label_sticker(Label.new(), 13, StickerTheme.label_color(StickerTheme.LabelRole.INK), 0, Color.WHITE, true)
	_tb_name_label.name = "TargetName"
	_tb_name_label.text = ""
	_tb_name_label.position = Vector2(12.0, 3.0)
	_tb_name_label.size = Vector2(140.0, 20.0)
	_tb_name_label.clip_text = true
	_tb_panel.add_child(_tb_name_label)
	_tb_hp_label = StickerTheme.label_sticker(Label.new(), 13, StickerTheme.label_color(StickerTheme.LabelRole.INK), 0, Color.WHITE, true)
	_tb_hp_label.name = "TargetHp"
	_tb_hp_label.text = ""
	_tb_hp_label.position = Vector2(140.0, 3.0)
	_tb_hp_label.size = Vector2(128.0, 20.0)
	_tb_hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_tb_panel.add_child(_tb_hp_label)

	var root := Control.new()
	_hud_root = root
	root.name = "Root"
	root.theme = StickerTheme.theme()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	root.add_child(_tb_root)                     # TargetBar 收口为 Root 首子（见 _build_ui 首）

	# HP 白胶囊（圆角 + 藏青描边；填充 = 纯渐变，克制无表情）
	# R195 适配分区：顶带左上锚组（HP/击杀/计时/护盾/金币/Lv/TargetBar/经验条——
	# 默认锚点 0 即设计位，expand 延展下左上不动、恒等零改动；安全区让位经 Root
	# offset_* 统一生效）
	var hp_panel := _sticker_panel(root, Vector2(24.0, 24.0), HP_BAR_SIZE, 15.0)
	_add_hover(hp_panel, "生命
被碰到掉血，短暂无敌帧；升级即回满血。
「生存本能」词条提升生命上限")
	_hp_fill = Panel.new()
	_hp_fill.name = "HpFill"
	_hp_fill_style = StyleBoxFlat.new()
	_hp_fill_style.bg_color = PopPalette.SUCCESS
	_hp_fill_style.set_corner_radius_all(8)
	_hp_fill.add_theme_stylebox_override("panel", _hp_fill_style)
	_hp_fill.position = Vector2(4.0, 4.0)
	_hp_fill.size = HP_BAR_SIZE - Vector2(8.0, 8.0)
	_hp_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hp_panel.add_child(_hp_fill)
	_hp_label = StickerTheme.label_sticker(Label.new(), 18, StickerTheme.label_color(StickerTheme.LabelRole.INK), 0, Color.WHITE, true)
	_hp_label.name = "HpText"
	_hp_label.size = Vector2(HP_BAR_SIZE.x, 24.0)
	_hp_label.position = Vector2(0.0, 3.0)
	_hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hp_panel.add_child(_hp_label)
	# R186 复活次数常驻徽标（血条右上「✚×N」小 label：refresh_stats 驱动，归零置灰）
	# R200：13→16（顶带常驻读数与 R187 读数同族抬档；「✚×3」@16 ≈ 50px ≤ 64 承载）
	_revive_badge = StickerTheme.label_sticker(Label.new(), 16, StickerTheme.label_color(StickerTheme.LabelRole.GOLD), 4, Color.WHITE, true)
	_revive_badge.name = "ReviveBadge"
	_revive_badge.text = "✚×0"
	_revive_badge.size = Vector2(64.0, 16.0)
	_revive_badge.position = Vector2(300.0, 16.0)
	_revive_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_revive_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_revive_badge)
	# R187 武器形态读数位（单行紧凑徽标，refresh_stats 驱动 + 信号即时刷新）：
	# 「束 ×N」= W4 副激光束数徽标 /「镜 ×N」= W5 镜面军团角标 /「爆 ×N」= W8 蓄能引爆读数
	# R200（真机反馈「buff 字很小」）：13→18 对齐 HP 行读数档。QA/评审 D1 修复：盒
	# 右沿 480→592 挪进空走廊——HP 胶囊实宽 340（右沿 24+340=364），盒左沿 368 留
	# 4px 缝（r195 R2 法按矩形判交），最坏三段全文 @18pt ≈ 175px 右对齐起笔 ≥417，
	# 字形彻底不碰血条（旧 480 右沿时起笔 305~327 侵入胶囊 37~59px）；波次徽章
	# 左沿 ~598 → 右沿 592 留 6px。y30+20=50 仍在顶带行内
	# R230 K4：浅紫 lerp 自由色收敛入 SHOCK 角色（紫族色相保持，明度序断言钉——语义色保全）
	_r187_readout = StickerTheme.label_sticker(Label.new(), 18, PopPalette.SHOCK.lerp(Color.WHITE, 0.25), 4, Color.WHITE, true)
	_r187_readout.name = "R187Readout"
	_r187_readout.text = ""
	_r187_readout.size = Vector2(224.0, 20.0)
	_r187_readout.position = Vector2(368.0, 30.0)
	_r187_readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_r187_readout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_r187_readout)

	# 经验星条（柠檬星图标 + 白胶囊细条）
	var star_icon := TextureRect.new()
	star_icon.name = "XpStar"
	star_icon.texture = TextureFactory.star(32)
	star_icon.position = Vector2(26.0, 60.0)
	star_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(star_icon)
	var xp_panel := _sticker_panel(root, Vector2(54.0, 63.0), XP_BAR_SIZE, 7.0)
	_add_hover(xp_panel, "经验
吸收经验碎片升级，每级弹一次强化卡
（「经验萃取」词条提升获取量）")
	_xp_fill = Panel.new()
	_xp_fill.name = "XpFill"
	var xp_style := StyleBoxFlat.new()
	xp_style.bg_color = PopPalette.XP
	xp_style.set_corner_radius_all(4)
	_xp_fill.add_theme_stylebox_override("panel", xp_style)
	_xp_fill.position = Vector2(3.0, 3.0)
	_xp_fill.size = Vector2(3.0, XP_BAR_SIZE.y - 6.0)
	_xp_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	xp_panel.add_child(_xp_fill)
	_level_label = StickerTheme.label_sticker(Label.new(), 18, StickerTheme.label_color(StickerTheme.LabelRole.INK), 0, Color.WHITE, true)
	_level_label.name = "LevelText"
	_level_label.text = "Lv 1"
	_level_label.position = Vector2(356.0, 60.0)
	root.add_child(_level_label)

	# 波次圆形徽章（右上）
	var badge := _sticker_panel(root, Vector2(598.0, 16.0), Vector2(106.0, 106.0), 53.0)
	# R195 适配分区：顶带右上锚（offset=现值−锚点(720,0)：左 598−720、右沿 704−720；
	# 720×1280 恒等，宽视口下贴右沿）
	badge.anchor_left = 1.0
	badge.anchor_right = 1.0
	badge.offset_left = -122.0
	badge.offset_right = -16.0
	badge.offset_top = 16.0
	badge.offset_bottom = 122.0
	_add_hover(badge, "波次
当前波次；清完最终 Boss 波即通关结算")
	var badge_cap := StickerTheme.label_sticker(Label.new(), 13, StickerTheme.label_color(StickerTheme.LabelRole.SOFT))
	badge_cap.text = "WAVE"
	badge_cap.size = Vector2(106.0, 16.0)
	badge_cap.position = Vector2(0.0, 22.0)
	badge_cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.add_child(badge_cap)
	_wave_label = StickerTheme.label_sticker(Label.new(), 22, StickerTheme.label_color(StickerTheme.LabelRole.INK), 0, Color.WHITE, true)
	_wave_label.name = "WaveText"
	_wave_label.text = "第 0 波"
	_wave_label.size = Vector2(106.0, 34.0)
	_wave_label.position = Vector2(0.0, 42.0)
	_wave_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.add_child(_wave_label)
	# R209 余敌副行：徽章下缘空带（y76-106 圆内弦宽 ≥62px，「余 N」13pt 居中可读）；
	# 口径=待出生队列+场上活跃（≤8/帧出生节流下含队列才单调递减不跳变）
	_wave_left_label = StickerTheme.label_sticker(Label.new(), 13, StickerTheme.label_color(StickerTheme.LabelRole.SOFT))
	_wave_left_label.name = "WaveLeftText"
	_wave_left_label.text = "余 0"
	_wave_left_label.size = Vector2(106.0, 18.0)
	_wave_left_label.position = Vector2(0.0, 78.0)
	_wave_left_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_wave_left_label.visible = false
	badge.add_child(_wave_left_label)

	# 击杀气泡 + 计时气泡
	var kill_pill := _sticker_panel(root, Vector2(24.0, 92.0), Vector2(150.0, 36.0), 18.0)
	_add_hover(kill_pill, "击杀
本局击杀数（图鉴/成就统计源）")
	_kill_label = StickerTheme.label_sticker(Label.new(), 18, StickerTheme.label_color(StickerTheme.LabelRole.INK), 0, Color.WHITE, true)
	_kill_label.name = "KillText"
	_kill_label.text = "击杀 0"
	_kill_label.size = Vector2(150.0, 24.0)
	_kill_label.position = Vector2(0.0, 6.0)
	_kill_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	kill_pill.add_child(_kill_label)
	var time_pill := _sticker_panel(root, Vector2(184.0, 92.0), Vector2(112.0, 36.0), 18.0)
	_add_hover(time_pill, "时长
本局已经过时间")
	_time_label = StickerTheme.label_sticker(Label.new(), 18, StickerTheme.label_color(StickerTheme.LabelRole.SOFT))
	_time_label.name = "TimeText"
	_time_label.text = "0:00"
	_time_label.size = Vector2(112.0, 24.0)
	_time_label.position = Vector2(0.0, 6.0)
	_time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	time_pill.add_child(_time_label)

	# 角色技能键（右下角——用户反馈「不同的角色有不同的技能」；2026-08-31 二轮反馈
	# 「技能好歹画个对应的图标」→ 图标化：角色专属技能图标 + 冷却数字覆盖层）
	var skill_btn := Button.new()
	skill_btn.name = "SkillButton"
	skill_btn.text = ""
	skill_btn.position = Vector2(610.0, 1112.0)
	skill_btn.size = Vector2(86.0, 86.0)
	# R195 适配分区：底带下锚（offset=现值−锚点(0,1280)：上 1112−1280、底沿 1198−1280
	# 贴底恒 82px；720×1280 恒等，高视口下贴 vis 底带）
	skill_btn.anchor_top = 1.0
	skill_btn.anchor_bottom = 1.0
	skill_btn.offset_top = -168.0
	skill_btn.offset_bottom = -82.0
	# R196 评审修复：水平改右缘锚（offset −110/−24 = 720 域 x610-696 逐位原值）——
	# 原 position x 固定 610 在 960×1280（3:4 平板，expand 逻辑域宽 960）下与右下档
	# 构筑面板（全 1 锚 x=W-452..W-200 → 960 时 x508-760）重叠 74/86px 高并拦截其
	# 输入；右缘锚后技能键左沿恒 W-110 > 面板右沿恒 W-200，任意宽度零重叠
	skill_btn.anchor_left = 1.0
	skill_btn.anchor_right = 1.0
	skill_btn.offset_left = -110.0
	skill_btn.offset_right = -24.0
	skill_btn.pivot_offset = skill_btn.size * 0.5
	skill_btn.pressed.connect(_on_skill_pressed)
	skill_btn.button_down.connect(func() -> void: StickerTheme.press_punch(skill_btn))
	root.add_child(skill_btn)
	_skill_btn = skill_btn
	var skill_icon_rect := TextureRect.new()
	skill_icon_rect.name = "SkillIcon"
	skill_icon_rect.texture = TextureFactory.skill_icon(&"sentinel")
	skill_icon_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	skill_icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	skill_icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	skill_icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	skill_icon_rect.modulate.a = 0.28                     # 白底按钮上 28% 印刷感底图
	skill_btn.add_child(skill_icon_rect)
	_skill_icon = skill_icon_rect
	var skill_fg := TextureRect.new()
	skill_fg.name = "SkillIconFg"
	skill_fg.texture = skill_icon_rect.texture
	skill_fg.set_anchors_preset(Control.PRESET_FULL_RECT)
	skill_fg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	skill_fg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	skill_fg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	skill_btn.add_child(skill_fg)
	_skill_icon_fg = skill_fg
	# R246 升华红环覆盖层（默认隐藏；refresh_stats 按 player.skill_sublime 态显隐——
	# RARITY_SUBLIME 单源取色，ring_tex 惰性缓存一次生成）；独立节点不占用
	# _skill_icon_fg.modulate 状态机（就绪白/冷却灰/无技能压暗/增益金零扰动）
	var sublime_ring := TextureRect.new()
	sublime_ring.name = "SkillSublimeRing"
	sublime_ring.texture = TextureFactory.ring_tex(PopPalette.RARITY_SUBLIME, 86, 5.5)
	sublime_ring.set_anchors_preset(Control.PRESET_FULL_RECT)
	sublime_ring.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	sublime_ring.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	sublime_ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sublime_ring.visible = false
	skill_btn.add_child(sublime_ring)
	_skill_sublime_ring = sublime_ring
	# R19 技能效果剩余时长条（增益期金色倒数，贴按钮下缘）
	var fx_bar := ColorRect.new()
	fx_bar.name = "SkillActiveBar"
	fx_bar.color = PopPalette.XP
	fx_bar.position = Vector2(4.0, skill_btn.size.y - 8.0)
	fx_bar.size = Vector2(0.0, 5.0)
	fx_bar.visible = false
	fx_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	skill_btn.add_child(fx_bar)
	_skill_active_bar = fx_bar
	_skill_cd_label = StickerTheme.label_sticker(Label.new(), 26, StickerTheme.label_color(StickerTheme.LabelRole.INK), 4, Color.WHITE, true)
	_skill_cd_label.name = "SkillCd"
	_skill_cd_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_skill_cd_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_skill_cd_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_skill_cd_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_skill_cd_label.text = ""
	skill_btn.add_child(_skill_cd_label)
	# R241 ④ 技能自动施法开关（技能键正下方，右缘同列锚）：开=每次技能冷却完成自动
	# 施放（R188-idle AUTO 挂机开关同款 Meta 单一真源持久化；关=手动点按现状）。
	# 观感：小胶囊 56×30，开=金「自动施放」/关=灰「手动施放」；无技能角色按键无效。
	var auto_cast_btn := Button.new()
	auto_cast_btn.name = "SkillAutoCast"
	for style_name in ["normal", "hover", "pressed", "focus", "disabled"]:
		auto_cast_btn.add_theme_stylebox_override(style_name, StyleBoxEmpty.new())
	auto_cast_btn.anchor_left = 1.0
	auto_cast_btn.anchor_right = 1.0
	auto_cast_btn.anchor_top = 1.0
	auto_cast_btn.anchor_bottom = 1.0
	auto_cast_btn.offset_left = -110.0
	auto_cast_btn.offset_right = -24.0
	auto_cast_btn.offset_top = -76.0              # 技能键底 -82 下留 6px 缝
	auto_cast_btn.offset_bottom = -44.0           # 高 32px 触控带（56 宽同 AUTO）
	auto_cast_btn.focus_mode = Control.FOCUS_NONE
	auto_cast_btn.pressed.connect(_on_skill_auto_pressed)
	auto_cast_btn.button_down.connect(func() -> void: StickerTheme.press_punch(auto_cast_btn))
	_skill_auto_label = StickerTheme.label_sticker(Label.new(), 13,
		StickerTheme.label_color(StickerTheme.LabelRole.SOFT), 3, Color.WHITE, true)
	_skill_auto_label.name = "SkillAutoCastText"
	_skill_auto_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_skill_auto_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_skill_auto_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_skill_auto_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	auto_cast_btn.add_child(_skill_auto_label)
	root.add_child(auto_cast_btn)
	_skill_auto_btn = auto_cast_btn
	_add_hover(auto_cast_btn, "技能自动施放
开：角色技能每次冷却完成自动施放
（无技能角色无效；暂停/选卡期不施放）
关：手动点技能键施放")
	_sync_skill_auto_visual()
	auto_cast_btn.visible = false                 # 初始 MENU 态隐藏（state_changed 驱动——与技能键同门）
	# 金币 pill（击杀/计时/护盾同行末段——2026-08-31 P0 反馈「金币压血条」修复落位；
	# 原 (24,44) 与血条 24~54/经验条 63~77 双重叠，现移至护盾条右侧 464~596）
	var gold_pill := _sticker_panel(root, Vector2(464.0, 92.0), Vector2(132.0, 36.0), 18.0)
	_add_hover(gold_pill, "战地金币
击杀掉落，黑市购物专用货币
（「丰饶/富矿」祝福提升获取）")
	gold_pill.name = "GoldPill"
	gold_pill.modulate.a = 0.94
	_gold_label = StickerTheme.label_sticker(Label.new(), 17, StickerTheme.label_color(StickerTheme.LabelRole.GOLD), 0, Color.WHITE, true)
	_gold_label.text = "◎ 0"
	_gold_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_gold_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_gold_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	gold_pill.add_child(_gold_label)
	# Boss 出场横幅（演出：缩放弹入 → 停留 → 淡出）
	_boss_banner = StickerTheme.label_sticker(Label.new(), 30, StickerTheme.label_color(StickerTheme.LabelRole.ENEMY), 6, Color.WHITE, true)
	_boss_banner.name = "BossBanner"
	_boss_banner.text = ""
	# R195 适配分区：全宽标签拉伸锚（anchor_l=0/anchor_r=1、y 不变；720 宽恒等，
	# 宽视口下横向满宽 + 文本居中随动）
	_boss_banner.anchor_right = 1.0
	_boss_banner.offset_left = 0.0
	_boss_banner.offset_right = 0.0
	_boss_banner.offset_top = 210.0
	_boss_banner.offset_bottom = 256.0
	_boss_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_boss_banner.visible = false
	_boss_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_boss_banner)
		# 构筑面板（左下角，避开弹幕主区——用户反馈 2026-08-29：当前持有武器+词条要展示；
	# 二轮反馈「点击左下角，可以看 buff 详情」→ 面板可点击 → 暂停 + 构筑详情卡）
	var build_root := Control.new()
	build_root.name = "BuildPanel"
	# R197 竖排两列：252×132 横排 → 140×258 窄高（左列武器/右列词条——用户反馈）
	build_root.position = Vector2(24.0, 998.0)
	# R208（真机反馈「buff 栏细长一点——长条内部右侧有空白」）：宽 140→118——右列
	# 宝石区收缩（icon x74..96、×N 右沿 116），右沿口径保持；左列武器/锁行 0..74 不动。
	build_root.size = Vector2(118.0, 258.0)
	# R195 适配分区：底带下锚（offset=现值−锚点(0,1280)：上 998−1280=-282、底沿
	# 1256−1280 贴底恒 24px；默认窗 (24,998)118×258 恒等；实际落位由 _apply_build_panel_pos 收口）
	build_root.anchor_top = 1.0
	build_root.anchor_bottom = 1.0
	build_root.offset_top = -282.0
	build_root.offset_bottom = -24.0
	# R196 断触修复：原 STOP 会吞掉面板上起手的 ScreenDrag（GUI 层消费后 player.gd:288
	# _unhandled_input 收不到 → 相对拖动链断）。PASS = 本层 gui_input 仍收点击（R194 松手
	# 判定 16px slop 原样防拖动误触），事件继续放行 → _unhandled_input 拖动恢复；
	# build_bg 保持 PASS；面板内武器图标/锁槽悬停位同为 PASS（R196 评审修复——
	# 悬停 tooltip 走 mouse_entered 与 filter 无关，STOP 会吞图标条上的拖动链）
	build_root.mouse_filter = Control.MOUSE_FILTER_PASS
	build_root.gui_input.connect(_on_build_gui_input)
	root.add_child(build_root)
	_build_panel = build_root
	var build_bg := _sticker_panel(build_root, Vector2.ZERO, Vector2(118.0, 258.0), 16.0)
	build_bg.name = "BuildBg"
	build_bg.modulate.a = 0.92
	build_bg.mouse_filter = Control.MOUSE_FILTER_PASS               # 点击穿透到 BuildPanel
	# R200（真机反馈）：底行字号 12→14；R208 面板收窄 140→118——文案改两段短式
	# 「构筑 · 详情」@14 ≈ 76px ≤ 118（原「构筑 · 点击查看详情」124px 溢出）；居中口径不变
	_build_label = StickerTheme.label_sticker(Label.new(), 14, StickerTheme.label_color(StickerTheme.LabelRole.SOFT))
	_build_label.name = "BuildText"
	_build_label.text = "构筑 · 详情"
	_build_label.size = Vector2(118.0, 18.0)
	_build_label.position = Vector2(0.0, 238.0)
	_build_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	build_bg.add_child(_build_label)

	# 自绘悬停说明卡（最上层；R13）
	_hover_card = PanelContainer.new()
	_hover_card.name = "HoverCard"
	var hsb := StyleBoxFlat.new()
	hsb.bg_color = Color(0.08, 0.11, 0.2, 0.94)
	hsb.set_corner_radius_all(10)
	hsb.border_width_bottom = 2
	hsb.border_color = PopPalette.PLAYER
	_hover_card.add_theme_stylebox_override("panel", hsb)
	_hover_card.visible = false
	_hover_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hover_card.z_index = 50
	_hover_label = Label.new()
	StickerTheme.label_sticker(_hover_label, 14, StickerTheme.label_color(StickerTheme.LabelRole.WHITE), 0, Color.TRANSPARENT)
	_hover_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hover_label.custom_minimum_size = Vector2(300.0, 0.0)
	_hover_card.add_child(_hover_label)
	root.add_child(_hover_card)

	# 护盾条（时间气泡右侧；MEC_SHIELD 持有才显示——用户反馈「单独的护盾条」）
	_shield_panel = _sticker_panel(root, Vector2(306.0, 92.0), Vector2(148.0, 36.0), 18.0)
	_add_hover(_shield_panel, "临时护盾
持有「格挡力场」词条时出现（R238 文案更正：原「能量护盾」为旧名残留）
就绪=挡下一次接触伤害；选卡后立即可用一次，此后进入充能")
	_shield_panel.name = "ShieldBar"
	_shield_panel.modulate.a = 0.94
	_shield_panel.visible = false
	var shield_icon := TextureRect.new()
	shield_icon.name = "ShieldIcon"
	shield_icon.texture = TextureFactory.shield_bubble()
	shield_icon.position = Vector2(4.0, 4.0)
	shield_icon.custom_minimum_size = Vector2(28.0, 28.0)
	shield_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shield_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	shield_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shield_panel.add_child(shield_icon)
	_shield_fill = Panel.new()
	_shield_fill.name = "ShieldFill"
	_shield_fill_style = StyleBoxFlat.new()
	_shield_fill_style.bg_color = PopPalette.PLAYER
	_shield_fill_style.set_corner_radius_all(6)
	_shield_fill.add_theme_stylebox_override("panel", _shield_fill_style)
	_shield_fill.position = Vector2(34.0, 3.0)
	_shield_fill.size = Vector2(3.0, 30.0)
	_shield_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shield_panel.add_child(_shield_fill)
	# R200：护盾是 buff 族常驻条——标签 12→14（「护盾」@14 = 28px，填充区 x34 起左侧富余）
	var shield_tag := StickerTheme.label_sticker(Label.new(), 14, StickerTheme.label_color(StickerTheme.LabelRole.SOFT))
	shield_tag.text = "护盾"
	shield_tag.position = Vector2(36.0, 8.0)
	shield_tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shield_panel.add_child(shield_tag)
	# 二cv#1：层数读数「X N」叠条右端（用户「护盾条里写X 2，有几条显示几条」——白字与
	# SOFT 标签拉开层级，数值是关键读数；每帧随护盾块刷新，见 refresh_stats）
	_shield_layers_label = StickerTheme.label_sticker(Label.new(), 14, StickerTheme.label_color(StickerTheme.LabelRole.WHITE))
	_shield_layers_label.text = ""
	_shield_layers_label.position = Vector2(108.0, 8.0)
	_shield_layers_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shield_panel.add_child(_shield_layers_label)

	# 二db 橙盾条（躲雷奖励：蓝条正下方 y132 = 92+36+4；层数>0 才显——与蓝条互不依赖，
	# 未持有 MEC_SHIELD 词条时橙盾独立存在）
	_temp_panel = _sticker_panel(root, Vector2(306.0, 132.0), Vector2(148.0, 36.0), 18.0)
	_add_hover(_temp_panel, "闪避护盾
躲过敌方爆炸（地雷/自爆虫/闪现爆/法术圈）获得，存在 10 秒，可叠加至 5 层
每层挡下一次接触伤害（敌弹同效）；再次躲过刷新时长")
	_temp_panel.name = "OrangeShieldBar"
	_temp_panel.modulate.a = 0.94
	_temp_panel.visible = false
	_temp_fill = Panel.new()
	_temp_fill.name = "OrangeShieldFill"
	_temp_fill_style = StyleBoxFlat.new()
	_temp_fill_style.bg_color = PopPalette.ORANGE
	_temp_fill_style.set_corner_radius_all(6)
	_temp_fill.add_theme_stylebox_override("panel", _temp_fill_style)
	_temp_fill.position = Vector2(34.0, 3.0)
	_temp_fill.size = Vector2(3.0, 30.0)
	_temp_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_temp_panel.add_child(_temp_fill)
	var temp_tag := StickerTheme.label_sticker(Label.new(), 14, StickerTheme.label_color(StickerTheme.LabelRole.SOFT))
	temp_tag.text = "闪避"
	temp_tag.position = Vector2(36.0, 8.0)
	temp_tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_temp_panel.add_child(temp_tag)
	_temp_label = StickerTheme.label_sticker(Label.new(), 14, StickerTheme.label_color(StickerTheme.LabelRole.WHITE))
	_temp_label.text = ""
	_temp_label.position = Vector2(100.0, 8.0)
	_temp_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_temp_panel.add_child(_temp_label)

	# 暂停按钮（右上角贴纸图标：白底圆角 + 藏青 ⏸ 双竖条；仅 PLAYING 态显示——
	# 用户反馈 2026-08-29「没有暂停的地方」；申请经信号 → GameLoop 仲裁）
	_pause_btn = Button.new()
	_pause_btn.name = "PauseButton"
	for style_name in ["normal", "hover", "pressed", "focus", "disabled"]:
		_pause_btn.add_theme_stylebox_override(style_name, StyleBoxEmpty.new())
	_pause_btn.position = Vector2(514.0, 20.0)
	_pause_btn.size = Vector2(72.0, 72.0)        # R194 触控目标放大（66→72，落位右上角带内）
	# R195 适配分区：顶带右上锚（offset=现值−锚点(720,0)：左 514−720、右沿 586−720
	# 贴右恒 134px；R194 72×72 几何与默认窗落位恒等）
	# R198（r194-2）：y 带 26..98 → 20..92（上移 6px）——底缘 y=92 恰接金币 pill
	# （GoldPill y92..128）顶沿，消除 6px 重叠带；触控目标 72×72 不回退（R195 R7 律）
	_pause_btn.anchor_left = 1.0
	_pause_btn.anchor_right = 1.0
	_pause_btn.offset_left = -206.0
	_pause_btn.offset_right = -134.0
	_pause_btn.offset_top = 20.0
	_pause_btn.offset_bottom = 92.0
	_pause_btn.pivot_offset = _pause_btn.size * 0.5
	_pause_btn.pressed.connect(_on_pause_pressed)
	var pause_icon := TextureRect.new()
	pause_icon.name = "PauseIcon"
	pause_icon.texture = TextureFactory.ui_glyph(0)
	pause_icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	pause_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pause_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	pause_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pause_btn.add_child(pause_icon)
	_pause_btn.visible = false                   # 初始 MENU 态隐藏（state_changed 驱动）
	root.add_child(_pause_btn)

	# AUTO 挂机开关（R188-idle，右上角空闲带 x644-704×y126-190——暂停钮 (514,20)
	# 下方、波次徽章 (598,16)+106 左侧留白带。R194 触控目标放大 56×64：644+56=700≤704、
	# 126+64=190 恰贴 r188 断言带上沿，零断言改动；胶囊复刻暂停钮 StyleBoxEmpty 工厂）。
	# 读写走 Meta 单一真源（无缓存 bool）；可见态 PLAYING+LEVEL_UP（state_changed 联动
	# ——与暂停钮不同：模态选卡/商店期仍可切）。
	_auto_capsule = _sticker_panel(root, Vector2(644.0, 126.0), Vector2(56.0, 64.0), 15.0)
	_auto_capsule.name = "AutoCapsule"
	# R195 适配分区：顶带右上锚（offset=现值−锚点(720,0)：左 644−720、右沿 700−720
	# 贴右恒 20px；r188 断言带 x∈[644,704]×y∈[126,190] 默认窗恒等）
	_auto_capsule.anchor_left = 1.0
	_auto_capsule.anchor_right = 1.0
	_auto_capsule.offset_left = -76.0
	_auto_capsule.offset_right = -20.0
	_auto_capsule.offset_top = 126.0
	_auto_capsule.offset_bottom = 190.0
	_auto_capsule_style = _auto_capsule.get_theme_stylebox("panel").duplicate() as StyleBoxFlat
	_auto_btn = Button.new()
	_auto_btn.name = "AutoToggle"
	for style_name in ["normal", "hover", "pressed", "focus", "disabled"]:
		_auto_btn.add_theme_stylebox_override(style_name, StyleBoxEmpty.new())
	_auto_btn.position = Vector2(644.0, 126.0)
	_auto_btn.size = Vector2(56.0, 64.0)         # R194 触控目标放大（56×30→56×64，r188 带内）
	# R195 适配分区：右上锚（与胶囊同 offsets——视觉/输入两节点同位随动）
	_auto_btn.anchor_left = 1.0
	_auto_btn.anchor_right = 1.0
	_auto_btn.offset_left = -76.0
	_auto_btn.offset_right = -20.0
	_auto_btn.offset_top = 126.0
	_auto_btn.offset_bottom = 190.0
	_auto_btn.pivot_offset = _auto_btn.size * 0.5
	_auto_btn.focus_mode = Control.FOCUS_NONE
	_auto_btn.pressed.connect(_on_auto_toggle_pressed)
	_auto_btn.button_down.connect(func() -> void: StickerTheme.press_punch(_auto_btn))
	_auto_label = StickerTheme.label_sticker(Label.new(), 13, StickerTheme.label_color(StickerTheme.LabelRole.SOFT), 0, Color.WHITE, true)
	_auto_label.name = "AutoToggleText"
	_auto_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_auto_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_auto_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_auto_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_auto_btn.add_child(_auto_label)
	root.add_child(_auto_btn)
	_add_hover(_auto_capsule, "挂机模式\n开：升级自动选卡、黑市自动出击、按档自动重开
（档位在设置页切换：0 停结算 / 1 死亡自动重开 / 2 通关自动无尽+死亡重开；
每日挑战局自动回退为停结算）\n关：全部手动——升级选卡照常弹卡")
	_sync_auto_visual()
	_auto_btn.visible = false                    # 初始 MENU 态隐藏（state_changed 驱动）

	# 波次 toast（果冻 pop；居中，避开 Boss 条与状态提示行）
	_toast_label = StickerTheme.label_sticker(Label.new(), 34, StickerTheme.label_color(StickerTheme.LabelRole.INK), 12, Color.WHITE, true)
	_toast_label.name = "WaveToast"
	_toast_label.text = ""
	# R195 适配分区：全宽标签拉伸锚（y 不变；宽视口下满宽居中，_show_toast 侧活宽同口径）
	_toast_label.anchor_right = 1.0
	_toast_label.offset_left = 0.0
	_toast_label.offset_right = 0.0
	_toast_label.offset_top = 392.0
	_toast_label.offset_bottom = 436.0
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.visible = false
	root.add_child(_toast_label)

	# 状态提示（测试锁定节点名与文案口径）
	_state_label = StickerTheme.label_sticker(Label.new(), 32, StickerTheme.label_color(StickerTheme.LabelRole.INK), 12, Color.WHITE, true)
	_state_label.name = "StateLabel"
	_state_label.text = ""
	# R195 适配分区：全宽标签拉伸锚（y 不变恒等；宽视口下满宽居中）
	_state_label.anchor_right = 1.0
	_state_label.offset_left = 0.0
	_state_label.offset_right = 0.0
	_state_label.offset_top = 212.0
	_state_label.offset_bottom = 256.0
	_state_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_state_label.visible = false
	root.add_child(_state_label)
	# R186 复活全屏白闪（整屏 ColorRect；MOUSE_FILTER_IGNORE 同 chromatic_rect 口径
	# game_loop.gd:223；先于横幅添加 = 横幅浮于白闪上可读。复活成功不进 GAME_OVER，
	# 与结算屏永不同屏；白闪 tween 自结束置 invisible，跨局无需额外收口）
	_revive_flash = ColorRect.new()
	_revive_flash.name = "ReviveFlash"
	_revive_flash.color = Color(1.0, 1.0, 1.0, 0.0)
	_revive_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	_revive_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_revive_flash.visible = false
	root.add_child(_revive_flash)
	# R186 复活大字横幅（金色 48 号基准/显时 64——二cs 加醒；y316 介于状态行 y212 与 toast y392 之间——设计案 §2）
	_revive_banner = StickerTheme.label_sticker(Label.new(), 48, StickerTheme.label_color(StickerTheme.LabelRole.GOLD), 8, Color.WHITE, true)
	_revive_banner.name = "ReviveBanner"
	_revive_banner.text = ""
	# R195 适配分区：全宽标签拉伸锚（y 不变恒等；宽视口下满宽居中）
	_revive_banner.anchor_right = 1.0
	_revive_banner.offset_left = 0.0
	_revive_banner.offset_right = 0.0
	_revive_banner.offset_top = 316.0
	_revive_banner.offset_bottom = 368.0
	_revive_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_revive_banner.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_revive_banner.visible = false
	_revive_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_revive_banner)
	# R202：FPS 读数小字（设置键 show_fps 控 visible，默认隐藏）。⚠急切创建于 _build_ui
	# 期、运行期仅切 visible——禁懒创建：r198_hud_layout_cases.gd:125-131 _toast_by_diff
	# 按「HUD 直挂新 Label 子节点」差集识别 toast，懒建 Label 会被差集误捕砸 T①~T⑧
	#（本标签挂 Root 子树本就不入该差集，双保险）。落位=右缘构筑面板 POS0（y196-454）
	# 正下方 y470 空带（G4 探针 probe_fps_band 实测：BuildPanel 底 454 与技能键顶 1112
	# 之间右缘无持久元素；避开左上 HP/XP 簇 r195_layout R2 对与 _r187_readout(368,30)）；
	# 右缘锚（offset=现值−锚点(720,0)，720×1280 恒等 x604-704）随宽视口贴沿 → R1 界内
	# 恒成立；panel_pos 三档（右上/右下/左下）落位均与本带零冲突。
	_fps_label = StickerTheme.label_sticker(Label.new(), 20, StickerTheme.label_color(StickerTheme.LabelRole.SOFT), 3, Color.WHITE, true)
	_fps_label.name = "FpsLabel"
	_fps_label.text = ""
	_fps_label.anchor_left = 1.0
	_fps_label.anchor_right = 1.0
	# R208（真机反馈「显示靠右没显示全」）：原宽仅 100px，右对齐下「FPS 10 dc 412
	# o 891」@20pt≈215px 左半硬截——拓到 290px（x414..704，诊断行专属带，仅
	# show_fps 开启期可见）
	_fps_label.offset_left = -290.0
	_fps_label.offset_right = -16.0              # x704 == 波次徽章右沿（BADGE 右贴 16px 口径）
	_fps_label.offset_top = 470.0
	_fps_label.offset_bottom = 494.0
	_fps_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_fps_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_fps_label.visible = false
	root.add_child(_fps_label)
	refresh_stats()
	_apply_build_panel_pos()                     # R196：初始落位（Meta.settings("panel_pos")，autoload 已就绪）
	_apply_show_fps()                            # R202：show_fps 初值（默认 false → 隐藏 + set_process(false)）


func _sticker_panel(p_parent: Control, p_pos: Vector2, p_size: Vector2, p_radius: float) -> Panel:
	# 贴纸面板工厂（白底 + 藏青描边 + 底部厚投影；HUD 专用轻量版，无投影避免顶部杂乱）。
	# R191：悬停说明死参删除——原「非空设 tooltip_text+STOP」后被下一行无条件 IGNORE
	# 覆盖，永不触发的死路径（HUD 悬停说明由 R13 自绘 HoverCard 承担，不走引擎 tooltip）
	var panel := Panel.new()
	var sb := StickerTheme.panel_style(p_radius, 3, false)
	panel.add_theme_stylebox_override("panel", sb)
	panel.position = p_pos
	panel.size = p_size
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p_parent.add_child(panel)
	return panel


static func _fit_font_size(p_label: Label, p_text: String, p_max_w: float,
		p_size_floor := 16) -> void:
	# R86 屏中大字自适应：按字体实测宽度缩字号到容器内（长横幅不再溢出裁切）
	var font := p_label.get_theme_font("font")
	if font == null:
		return
	var fs: int = p_label.get_theme_font_size("font")
	while fs > p_size_floor 			and font.get_string_size(p_text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > p_max_w:
		fs -= 2
	if fs != p_label.get_theme_font_size("font"):
		p_label.add_theme_font_size_override("font_size", fs)


func _show_toast(p_text: String, p_time: float = TOAST_TIME) -> void:
	# 波次 toast：果冻 squash & stretch 出现（重要 UI 元素全局动效口径）
	# R253（二dc L3 缓办清账）多行钳制：toast 带 44px（y392~436）装不下多行——开场
	# 横幅 join("\n") 理论可 5+ 行（难度门+难度参数+武装+保底遗物+祝福），超 TOAST_MAX_LINES
	# 截尾加省略行（首行组信息密度最高，尾部「另有 N 条」保留计数可读性）
	var text := p_text
	var lines := p_text.count("\n") + 1
	if lines > TOAST_MAX_LINES:
		var kept := p_text.split("\n")
		text = "\n".join(kept.slice(0, TOAST_MAX_LINES)) \
			+ "\n…（另有 %d 条）" % (lines - TOAST_MAX_LINES)
		# R253 评审 M2：去「见暂停面板」指路——暂停面板只列武器/词条/遗物，难度门/
		# 祝福/大关横幅行无处可查，指路为假承诺（保行数计数可读性）
	_toast_label.text = text
	_toast_label.remove_theme_font_size_override("font_size")     # R86：重置后按本文缩放
	_toast_label.add_theme_font_size_override("font_size", 34)
	_fit_font_size(_toast_label, text, 700.0)
	_toast_label.reset_size()
	# R195 适配：重定位改活宽——拉伸锚下 offset 左/右归 0 = 父域（visible_rect）满宽，
	# 等效原「size=(活宽,44)」且规避非等对锚 set_size 的引擎告警；y 回设计位 392~436
	_toast_label.offset_left = 0.0
	_toast_label.offset_right = 0.0
	_toast_label.offset_top = 392.0
	_toast_label.offset_bottom = 436.0
	_toast_label.visible = true
	_toast_label.modulate.a = 1.0
	_toast_left = p_time
	StickerTheme.squash_pop(_toast_label)


# ── R186 TargetBar：左上「当前攻击目标」血条（修订 R2 状态机） ──────────
# 零新增事件、零契约变更：订阅既有 damage_resolved 按 target_uid 粘性锁定；回调侧只做
# O(1) 字典累加，解析（uid → 敌节点反查）只发生在帧结算且受 TB_RESOLVE_BUDGET 封顶。
func displayed_target_uid() -> int:
	# 测试观测口（对齐 boss_bar.gd:91-99 先例）：当前锁定 uid（收起后清零）
	return _tb_lock_uid


func displayed_target_text() -> String:
	# 测试观测口：条内文本（名字 + HP 绝对值）
	if _tb_name_label == null or _tb_hp_label == null:
		return ""
	return "%s %s" % [_tb_name_label.text, _tb_hp_label.text]


func is_visible_bar() -> bool:
	# 测试观测口：条可见性（含淡出/白闪收尾期）
	return _tb_root != null and _tb_root.visible


func displayed_pct() -> float:
	# 测试观测口：填充比例（内缩 4px 口径，同 BossBar displayed_pct 语义）
	if _tb_fill == null:
		return 0.0
	var inner := TB_SIZE.x - 8.0
	if inner <= 0.0:
		return 0.0
	return _tb_fill.size.x / inner


func _tb_tick(p_raw_delta: float) -> void:
	# 每帧驱动（并入 HUD.tick ⑧ UI 阶段 raw 通道）：帧结算 + 有效性三查 + 续窗/出口
	# 衰减 + 读血刷新。PAUSED/LEVEL_UP 冻结衰减（_on_state_changed 置 _tb_frozen，
	# 恢复 PLAYING 续计——条不误消失）。
	if GameConfig.frame_stamp != _tb_last_frame or not _agg.is_empty():
		# 帧前进必结算（空聚合帧也结——死亡出口裁决依赖）；聚合非空但帧未前进
		# （离线直发事件环境）幂等结算：结算即清空，不会重复计数
		_tb_last_frame = GameConfig.frame_stamp
		_tb_settle(p_raw_delta)
	# Boss 让位旗健壮收口：在场 Boss 引用失效/死亡（手动 pool.release 等无事件路径）
	# → 旗清回 y136（引用比对主路径在 _on_enemy_killed）
	if _tb_boss_node != null and (not is_instance_valid(_tb_boss_node)
			or bool(_tb_boss_node.get("dead"))):
		_tb_boss_node = null
		_tb_boss_on_field = false
	if _tb_frozen:
		return
	match _tb_state:
		TbState.LOCKED:
			# 每帧有效性三查（池化防脏血：uid 单调计数器不回收 game_const.gd:164-168，
			# 杀后即归还 enemy_spawner.gd:153-159——重赋/归还/死亡一律视为失效）
			var n := _tb_lock_node
			if n == null or not is_instance_valid(n) or bool(n.get("dead")) \
					or int(n.get("uid")) != _tb_lock_uid:
				_tb_lock_node = null
				_tb_lock_dying = true          # 出口交下一次帧结算裁决（R2 修③）
			else:
				if _tb_cand_uid != 0:
					_tb_switch_left = maxf(_tb_switch_left - p_raw_delta, 0.0)
				_tb_retain_left -= p_raw_delta
				if _tb_retain_left <= 0.0:
					_tb_begin_exit(false)      # 续窗耗尽 → 0.3s 淡出（TOAST_FADE 口径）
				else:
					_tb_refresh_visual(p_raw_delta)
		TbState.FADING:
			_tb_exit_left -= p_raw_delta
			if _tb_exit_left <= 0.0:
				_tb_hide_bar()
			elif _tb_exit_white:
				var k := clampf(_tb_exit_left / TB_KILL_FLASH, 0.0, 1.0)
				_tb_fill_style.bg_color = PopPalette.ENEMY.lerp(Color.WHITE, 0.9 * k)
			else:
				_tb_root.modulate.a = TB_BASE_ALPHA * clampf(_tb_exit_left / TB_FADE_TIME, 0.0, 1.0)
		TbState.HIDDEN:
			pass


func _tb_settle(_p_dt: float) -> void:
	# 帧结算：① 聚合按「伤害和降序」排候选；② 死亡出口优先级（R2 修③：有合格候选
	# 优切无空白帧，无候选才 0.25s 白残影闪白收尾，白闪期内新提案可打断）；③ 主目标
	# 裁决（HIDDEN 免滞回接管 / LOCKED 滞回+续窗 / FADING 提案打断）。④ 聚合清空。
	# （滞回归零在 _tb_tick 侧按 wall-clock 衰减——无提案帧不清零候选，慢速武器可切换）
	# R188⑤：候选改成员缓冲原地重建（原 `Array[int]+assign(_agg.keys())` 每帧两段
	# 分配——keys() 中转组 + 装箱组；逐帧迭代字典 append 进 _tb_cand_buf 零新建）。
	# 结算同步段内用完即弃（无重入口），排序器 _tb_uid_desc 读 _agg 与原口径一致
	_tb_cand_buf.clear()
	if not _agg.is_empty():
		for uid: int in _agg:
			_tb_cand_buf.append(uid)
		_tb_cand_buf.sort_custom(_tb_uid_desc)
	var primary: Node2D = _tb_first_qualified(_tb_cand_buf)
	if _tb_lock_dying:
		_tb_lock_dying = false
		if primary != null:
			_tb_takeover(primary)              # 殒命帧有合格候选 → 直接切新 uid
		elif _tb_state == TbState.LOCKED:
			_tb_begin_exit(true)               # 无候选 → 白残影闪白收起（提案可打断）
	match _tb_state:
		TbState.HIDDEN:
			if primary != null:
				_tb_takeover(primary)          # 首目标免滞回立即接管，无空白帧
		TbState.LOCKED:
			# 续窗口径（R2 修②）：仅锁定 uid 的合格伤害刷新（O(1) has，无论名次）；
			# 他人伤害一律不续命——多目标扫射不被无限续命
			if _agg.has(_tb_lock_uid):
				_tb_retain_left = TB_RETAIN_TIME
			if primary != null:
				var puid := int(primary.get("uid"))
				if puid == _tb_lock_uid:
					_tb_cand_uid = 0           # 主目标=锁定：滞回复位
					_tb_switch_left = TB_SWITCH_HYSTERESIS
				elif puid == _tb_cand_uid:
					if _tb_switch_left <= 0.0:
						_tb_takeover(primary)  # 连续胜出满 0.3s → 切换
				else:
					_tb_cand_uid = puid        # 帧间主目标变化 → 重置候选计时
					_tb_switch_left = TB_SWITCH_HYSTERESIS
			# 本帧无提案：锁定保持既有衰减不误清，候选计时不清零（tick 侧 wall-clock 衰减）
		TbState.FADING:
			if primary != null:
				_tb_takeover(primary)          # 白闪/淡出收尾期内合格提案打断 → 直接接管
	_agg.clear()


func _tb_first_qualified(p_candidates: Array[int]) -> Node2D:
	# 降序回退解析（R2 修①）：预算内逐个线性扫 spawner.active——解析不到（同帧击杀
	# 已 erase+池归还）/ is_boss（让位 BossBar）/ dead 一律跳过取下一名；首个合格者=
	# 本帧主目标。预算 TB_RESOLVE_BUDGET 封顶（≤4×120 节点迭代/帧，600 结算/帧不失控）。
	var sp := _tb_spawner()
	if sp == null or p_candidates.is_empty():
		return null
	var budget := TB_RESOLVE_BUDGET
	for uid: int in p_candidates:
		if budget <= 0:
			break
		budget -= 1
		var node := _tb_resolve_uid(sp, uid)
		if node == null:
			continue
		if node.has_method(&"is_boss") and bool(node.call(&"is_boss")):
			continue                           # Boss 榜首被跳不阻塞第二名（同帧 AOE 边界）
		if bool(node.get("dead")):
			continue
		return node
	return null


func _tb_resolve_uid(p_sp: Node, p_uid: int) -> Node2D:
	# uid → 敌节点反查（线性扫 active；≤120 同屏上限 enemy_spawner.gd:9/19）
	var actives_v: Variant = p_sp.get("active")
	if actives_v == null:
		return null
	var actives: Array[Node2D] = actives_v
	for n: Node2D in actives:
		if n != null and is_instance_valid(n) and int(n.get("uid")) == p_uid:
			return n
	return null


func _tb_spawner() -> Node:
	# 解析数据源：setup 注入优先；缺省兜底组查找（EnemySpawner 自入组
	# &"enemy_spawner"，enemy_spawner.gd:25——旧接线/测试环境 setup 不带 spawner 仍可用）
	if _spawner != null and is_instance_valid(_spawner):
		return _spawner
	var tree := get_tree()
	if tree != null:
		_spawner = tree.get_first_node_in_group(&"enemy_spawner")
	return _spawner


func _tb_uid_desc(p_a: int, p_b: int) -> bool:
	# 帧结算候选序：聚合伤害和降序（O(1) 字典读）
	return float(_agg.get(p_a, 0.0)) > float(_agg.get(p_b, 0.0))


func _tb_takeover(p_node: Node2D) -> void:
	# 锁定接管（首目标/滞回胜出/死亡出口优切/收尾打断共用）：免滞回，无空白帧
	_tb_lock_uid = int(p_node.get("uid"))
	_tb_lock_node = p_node
	_tb_lock_dying = false
	_tb_state = TbState.LOCKED
	_tb_retain_left = TB_RETAIN_TIME
	_tb_cand_uid = 0
	_tb_switch_left = TB_SWITCH_HYSTERESIS
	_tb_exit_left = 0.0
	var mh := float(p_node.get("max_hp"))
	_tb_pct = 0.0 if mh <= 0.0 else clampf(float(p_node.get("hp")) / mh, 0.0, 1.0)
	_tb_displayed_pct = _tb_pct              # 新目标无残影残留（从真实血量起画）
	_tb_last_pct = _tb_pct
	_tb_hurt_flash = 0.0
	var wdata: Variant = p_node.get("data")
	var dname := "未知单位"
	if wdata != null:
		dname = String(wdata.get("display_name"))
	var elite := p_node.has_method(&"is_elite") and bool(p_node.call(&"is_elite"))
	_tb_name_label.text = ("◆ " if elite else "") + dname
	_tb_root.visible = true
	_tb_root.modulate.a = TB_BASE_ALPHA
	_tb_fill_style.bg_color = PopPalette.ENEMY
	_tb_refresh_visual(0.0)


func _tb_begin_exit(p_white: bool) -> void:
	# 进入 FADING：p_white=死亡白残影闪白（0.25s，残影拉满——整段「刚打掉的量」速读
	# 收尾）/ false=续窗耗尽淡出（0.3s alpha 渐隐）。uid 保持到收起才清（白闪期可被打断）
	_tb_state = TbState.FADING
	_tb_exit_white = p_white
	_tb_exit_left = TB_KILL_FLASH if p_white else TB_FADE_TIME
	if p_white:
		_tb_displayed_pct = 1.0
		_tb_sync_ghost()


func _tb_hide_bar() -> void:
	# 收起（白闪尽/淡出尽）：uid 清零 + 候选/计时/出口状态同步清（R2：清候选随出口同步）
	_tb_state = TbState.HIDDEN
	_tb_lock_uid = 0
	_tb_lock_node = null
	_tb_lock_dying = false
	_tb_cand_uid = 0
	_tb_switch_left = TB_SWITCH_HYSTERESIS
	_tb_retain_left = 0.0
	_tb_exit_left = 0.0
	_tb_pct = 1.0
	_tb_displayed_pct = 1.0
	_tb_last_pct = 1.0
	_tb_hurt_flash = 0.0
	if _tb_root != null:
		_tb_root.visible = false
		_tb_root.modulate.a = TB_BASE_ALPHA
		_tb_root.position.y = TB_POS_Y
	if _tb_fill_style != null:
		_tb_fill_style.bg_color = PopPalette.ENEMY
	if _tb_ghost != null:
		_tb_ghost.size = Vector2.ZERO
		_tb_ghost.visible = false


func _tb_hard_reset() -> void:
	# MENU/GAME_OVER 清场（同 boss_bar.gd:121-127 口径）：聚合/让位旗/冻结态一并清
	_tb_hide_bar()
	_agg.clear()
	_tb_boss_on_field = false
	_tb_boss_node = null
	_tb_frozen = false
	_tb_last_frame = GameConfig.frame_stamp


func _tb_refresh_visual(p_dt: float) -> void:
	# 每帧拉模型读血（⑧ UI 阶段口径）+ Boss 让位 y + 残影追速 + 掉血端白闪 + HP 文本
	var n := _tb_lock_node
	if n == null or not is_instance_valid(n) or _tb_fill == null:
		return
	_tb_root.position.y = TB_POS_Y_BOSS if _tb_boss_on_field else TB_POS_Y
	var mh := float(n.get("max_hp"))
	var hp := float(n.get("hp"))
	var pct := 0.0 if mh <= 0.0 else clampf(hp / mh, 0.0, 1.0)   # max_hp≤0 钳 0 防除零
	if pct < _tb_last_pct - 0.0005 and _tb_hurt_flash <= 0.0:
		_tb_hurt_flash = TB_HURT_FLASH       # 掉血瞬间白闪（回血不上闪，boss_bar.gd:52 同式）
	_tb_last_pct = pct
	_tb_pct = pct
	if _tb_displayed_pct < pct or _tb_displayed_pct - pct < 0.003:
		_tb_displayed_pct = pct
	else:
		_tb_displayed_pct = maxf(_tb_displayed_pct - TB_GHOST_CHASE * p_dt, pct)
	var inner := TB_SIZE.x - 8.0
	_tb_fill.size = Vector2(inner * pct, TB_SIZE.y - 8.0)
	_tb_sync_ghost()
	if _tb_hurt_flash > 0.0:
		_tb_hurt_flash = maxf(_tb_hurt_flash - p_dt, 0.0)
		_tb_fill_style.bg_color = PopPalette.ENEMY.lerp(Color.WHITE,
			0.75 * (_tb_hurt_flash / TB_HURT_FLASH))             # boss_bar.gd:71 同式
	elif not _tb_fill_style.bg_color.is_equal_approx(PopPalette.ENEMY):
		_tb_fill_style.bg_color = PopPalette.ENEMY
	# R188⑥：HP 文本量化显示缓存（口径与 _tb_fmt_num 同——<10000 整数步 / ≥10000 0.1k
	# 步）：档位不变整段跳过。认知口径：Godot 4 Label set_text 同值本就 early-out 无重
	# 排版，此处省的是每帧 "%s/%s" 数组装箱 + 两段 String 构造，非排版
	var hq := _tb_num_quantized(hp)
	var mq := _tb_num_quantized(mh)
	if hq != _tb_hp_q or mq != _tb_mh_q:
		_tb_hp_q = hq
		_tb_mh_q = mq
		_tb_hp_text_last = "%s/%s" % [_tb_fmt_num(hp), _tb_fmt_num(mh)]
		_tb_hp_label.text = _tb_hp_text_last


func _tb_sync_ghost() -> void:
	# E6 白残影段复刻（boss_bar.gd:169-180）：白条更短=本次实际打掉的量，速读 DPS
	var inner := TB_SIZE.x - 8.0
	var gw := inner * (_tb_displayed_pct - _tb_pct)
	_tb_ghost.visible = gw > 1.0
	_tb_ghost.position = Vector2(4.0 + inner * _tb_pct, 4.0)
	_tb_ghost.size = Vector2(maxf(gw, 0.0), TB_SIZE.y - 8.0)


static func _tb_fmt_num(p_v: float) -> String:
	# HP 绝对值格式：<10000 → 1234；≥10000 → 12.3k（地狱 ×9 血量防溢出）
	if p_v < 10000.0:
		return str(int(round(p_v)))
	return "%.1fk" % (p_v / 1000.0)


static func _tb_num_quantized(p_v: float) -> int:
	# R188⑥：HP 显示量化键（与 _tb_fmt_num 同口径——<10000 取整、≥10000 0.1k=百血步）。
	# 两值量化相等 ⇔ 格式化文本相等 → 档位未变跳过写文本零语义差
	if p_v < 10000.0:
		return int(round(p_v))
	return int(roundf(p_v * 0.01))               # 0.1k 一步（%.1fk 一位小数 = /1000 保留 1 位）


# ── R186 复活全屏反馈（订阅 G1 新增 EventBus.revive_burst） ────────────
func _on_revive_burst(_p_pos: Vector2, p_charges: int) -> void:
	# 表现时间轴（设计案 §3）：顿帧/青弧在 player/GameFeel 侧；本件 = 白闪 + 大字横幅
	# + ✚×N 徽标即时刷新。白闪 fx_quality 三档：0 档 0.35/0.25s，1 档 0.6/0.35s，2 档全量
	if _revive_flash != null:
		var q := clampi(int(Meta.settings("fx_quality")), 0, 2)
		var alpha := REVIVE_FLASH_ALPHA
		var dur := REVIVE_FLASH_TIME
		if q == 0:
			alpha = 0.35
			dur = 0.25
		elif q == 1:
			alpha = 0.6
			dur = 0.35
		if _revive_flash_tween != null:
			_revive_flash_tween.kill()         # kill 旧 tween 防叠加（Boss 同帧口径）
		_revive_flash.color = Color(1.0, 1.0, 1.0, alpha)
		_revive_flash.visible = true
		_revive_flash_tween = _revive_flash.create_tween()
		_revive_flash_tween.tween_property(_revive_flash, "color:a", 0.0, dur) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		_revive_flash_tween.tween_callback(func() -> void: _revive_flash.visible = false)
	if _revive_banner != null:
		# 横幅三段式（复制 boss_banner 三段式）：弹入 0.22 → 停留 2.2 → 淡出 0.4
		# ≈2.82s < 5s 无敌（二cs：加「5s 无敌」提示 + 字号 48→64——用户「没反应过来」）；
		# 余量 0 切警示色 + 「次数已耗尽」文案
		var text := ("✦ 复活！5s 无敌 · 剩余 %d 次" % p_charges) if p_charges > 0 else "✦ 复活！5s 无敌 · 次数已耗尽"
		_revive_banner.text = text
		# R230 K4：动态色同样走量化口（品质金/警示红角色切换——警示红硬保全）
		_revive_banner.add_theme_color_override("font_color",
			StickerTheme.label_color(StickerTheme.LabelRole.GOLD) if p_charges > 0
			else StickerTheme.label_color(StickerTheme.LabelRole.ENEMY))
		_revive_banner.remove_theme_font_size_override("font_size")
		_revive_banner.add_theme_font_size_override("font_size", 64)
		_fit_font_size(_revive_banner, text, 680.0)
		if _revive_banner_tween != null:
			_revive_banner_tween.kill()
		_revive_banner.visible = true
		_revive_banner.modulate.a = 0.0
		_revive_banner.pivot_offset = _revive_banner.size * 0.5
		_revive_banner.scale = Vector2(1.6, 1.6)
		_revive_banner_tween = _revive_banner.create_tween()
		_revive_banner_tween.tween_property(_revive_banner, "scale", Vector2.ONE, 0.22) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		_revive_banner_tween.parallel().tween_property(_revive_banner, "modulate:a", 1.0, 0.18)
		_revive_banner_tween.tween_interval(REVIVE_BANNER_HOLD)
		_revive_banner_tween.tween_property(_revive_banner, "modulate:a", 0.0, 0.4)
		_revive_banner_tween.tween_callback(func() -> void: _revive_banner.visible = false)
	refresh_stats()                              # ✚×N 徽标即时刷新（不等 1Hz 兜底）
