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
signal build_details_requested()              # 左下角构筑面板点击（→ 暂停 + buff 详情，用户反馈）

var player: Node2D = null                     # 注入（数值源；Player 宽类型规避循环解析）
var total_damage: float = 0.0                 # 造成的总伤害（damage_resolved 累计；结算屏数据源）

var _hp_fill: Panel = null                    # HP 条填充（比例缩放；圆角 StyleBoxFlat）
var _hp_fill_style: StyleBoxFlat = null       # 填充色随血量渐变（薄荷→柠檬→珊瑚）
var _hp_label: Label = null
var _xp_fill: Panel = null                    # 经验条填充
var _level_label: Label = null
var _wave_label: Label = null
var map_name: String = ""                  # 当前地图名（M2 多地图，HUD 波次前缀）
var endless_depth_base: int = 0            # R62 无尽徽标基准（final_wave）：wave 超基后波次
                                            # 徽章切「无尽 N」（N = 超出波数）；0 = 常规口径
var _skill_btn: Button = null              # 角色技能键（右下角；冷却中置灰倒计时）
var _skill_icon: TextureRect = null        # 技能键底图（28% 印刷感）
var _skill_icon_fg: TextureRect = null     # 技能键前景图标（就绪亮显 / 冷却压暗）
var _skill_cd_label: Label = null          # 冷却数字覆盖层（仅冷却中非空）
var _skill_active_bar: ColorRect = null    # 技能效果剩余时长条（R19：增益期金色倒计时）
var _gold_label: Label = null                 # 金币（战地黑市货币，M7）
var _boss_banner: Label = null                # Boss 出场横幅（表现层一期）
var _kill_label: Label = null
var _time_label: Label = null
var _build_label: Label = null                # 构筑统计行（面板底行计数，延续原词条栏）
var _build_panel: Control = null              # 构筑面板（左下角：武器图标行 + 词条宝石行——用户反馈）
var _build_sig: String = ""                   # 构筑签名缓存（变化才重建，1Hz 兜底下的防抖）
var _shield_panel: Control = null             # 护盾条（MEC_SHIELD 持有时显示——用户反馈）
var _shield_fill: Panel = null
var _shield_fill_style: StyleBoxFlat = null
var _state_label: Label = null                # 状态提示（LEVEL_UP/PAUSED/GAME_OVER——测试锁定节点名）
var _toast_label: Label = null                # 波次 toast（果冻 pop + lore 文案）
var _toast_left: float = 0.0                  # toast 剩余展示时长（raw 通道）
# R13 自绘悬停说明（引擎默认 tooltip 在弹幕游戏里延迟大/样式弱——自绘卡即时跟随）
var _hover_zones: Array[Dictionary] = []      # [{rect: Rect2, text: String}]
var _hover_card: PanelContainer = null
var _hover_label: Label = null
var _hud_root: Control = null                 # HUD 根容器（悬停检测用——R13）
var _pause_btn: Button = null                 # 暂停按钮（▶⏸ 图形化贴纸；仅 PLAYING 态显示）

# ── R186 TargetBar（左上「当前攻击目标」血条；修订 R2 状态机） ──────────
enum TbState { HIDDEN, LOCKED, FADING }       # 小状态机：隐藏 → 锁定 → 收尾（白闪/淡出）
var _spawner: Node = null                     # EnemySpawner 宽类型（setup 注入；组兜底解析）
var _agg: Dictionary = {}                     # uid → 本帧合格伤害和（回调侧 O(1) 累加）
var _agg_frame: int = 0                       # 最近聚合帧号（damage_resolved 记录；观测用）
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
var _tb_root: Control = null                  # TargetBarRoot（HUD CanvasLayer 直挂）
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

var kills: int = 0
var combo_peak: int = 0                   # G10 本局最高连杀（结算行数据源）
var wave: int = 0
var run_elapsed: float = 0.0                  # 计时（raw 通道累计——含顿帧，观感口径）
var _fallback_timer: float = 0.0              # 1Hz 兜底刷新

const HP_BAR_SIZE := Vector2(340.0, 30.0)
const XP_BAR_SIZE := Vector2(292.0, 14.0)
const TOAST_TIME := 1.7                       # 波次 toast 展示时长 s
const INTRO_TOAST_TIME := 3.4                 # 大关新机制横幅时长 s（文案长，需读完）
const TOAST_FADE := 0.3                       # 末段淡出 s

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
const REVIVE_BANNER_HOLD := 1.2               # 横幅停留 s（0.22 弹入 + 1.2 + 0.4 ≈1.82 < 3s 无敌）


func _ready() -> void:
	# ALWAYS：暂停/顿帧期间 UI 照常（Q-14）
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()


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


func setup(p_player: Node2D, p_spawner: Node = null) -> void:
	# 数值源注入（p_spawner：EnemySpawner 宽类型规避循环解析，同 player 惯例——
	# TargetBar 解析数据源；缺省 null 时走 enemy_spawner 组兜底查找）
	player = p_player
	_spawner = p_spawner


func refresh_stats() -> void:
	# HP/经验/等级/波次/击杀/计时（事件驱动 + 1Hz 兜底刷新共用）
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
		# R186 复活次数常驻徽标（血条右上「✚×N」：revive_burst 即时 + 1Hz 兜底；归零置灰）
		if _revive_badge != null:
			var rc := int(player.get("revives_left"))
			_revive_badge.text = "✚×%d" % rc
			_revive_badge.add_theme_color_override("font_color",
				PopPalette.GOLD if rc > 0 else PopPalette.INK_SOFT)
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
	_tick_hover()
	_tb_tick(p_raw_delta)   # R186 TargetBar（帧结算 + 每帧读血，并入 ⑧ UI 阶段既有调用）


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
		if (zone["rect"] as Rect2).has_point(mouse):
			_hover_label.text = zone["text"]
			_hover_card.visible = true
			_hover_card.position = (mouse + Vector2(18.0, 18.0)).clamp(
				Vector2(8.0, 8.0), Vector2(720.0, 1280.0) - Vector2(340.0, 130.0))
			return
	_hover_card.visible = false


# ── 测试观测口（displayed 值，headless 断言用——文本口径锁定，勿改） ──
func displayed_hp_text() -> String:
	return _hp_label.text


func displayed_wave() -> int:
	return wave


func displayed_kills() -> int:
	return kills


func displayed_level_text() -> String:
	return _level_label.text


# ── 事件 ──────────────────────────────────────────────────────────
func _on_player_hit(_p_damage: float, _p_source_uid: int) -> void:
	refresh_stats()


func _on_xp_gained(_p_amount: float) -> void:
	refresh_stats()


func _on_wave_started(p_wave: int) -> void:
	wave = p_wave
	_show_toast(Lore.wave_toast(p_wave))
	refresh_stats()


func _on_enemy_killed(p_enemy: Node2D) -> void:
	kills += 1
	# R186 TargetBar：Boss 在场旗清 + 锁定敌殒命只置出口标志不当场收起（R2 修③：
	# 下一次帧结算有合格候选优切，无候选才白闪收起）。注意连接序：本处理器晚于
	# spawner 死亡归还执行，tags 已被 _reset_state 清零（enemy.gd:1539）——Boss 判定
	# 只能走引用比对（同 boss_bar.gd:116 先例），is_boss() 标签在此不可用
	if p_enemy != null and p_enemy == _tb_boss_node:
		_tb_boss_node = null
		_tb_boss_on_field = false
	if p_enemy != null and int(p_enemy.get("uid")) == _tb_lock_uid:
		_tb_lock_dying = true
	refresh_stats()


func _on_state_changed(p_state: int) -> void:
	# 状态提示（LEVEL_UP/PAUSED/GAME_OVER 覆盖显示；PLAYING 隐藏）+ 状态切换刷新
	# （升级→LEVEL_UP 的 state_changed 晚于 xp_gained——等级数值在此同步）
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
	if _skill_btn != null:
		_skill_btn.visible = p_state == GameConst.GameStatus.PLAYING   # 暂停按钮仅战斗态显示
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


func _on_mirror_formed_toast(p_text: String) -> void:
	# R187 镜面生成 toast（「棱镜映照：镜面承接了 X」——与 R183 金色「召唤僚机」句式分界）
	var toast := StickerTheme.label_sticker(Label.new(), 17,
		PopPalette.PLAYER.lerp(Color.WHITE, 0.62), 4, Color.WHITE, true)   # 冰青（禁金）
	toast.text = p_text
	toast.reset_size()
	toast.position = Vector2(150.0, 300.0)
	toast.size = Vector2(420.0, 30.0)
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
	var toast := StickerTheme.label_sticker(Label.new(), 22, PopPalette.GOLD, 5, Color.WHITE, true)
	toast.text = text
	toast.reset_size()
	_fit_font_size(toast, text, 520.0)
	toast.position = Vector2(90.0, 360.0)
	toast.size = Vector2(540.0, 34.0)
	toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toast.pivot_offset = toast.size * 0.5
	add_child(toast)
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
	var toast := StickerTheme.label_sticker(Label.new(), 17, PopPalette.PLAYER, 4, Color.WHITE, true)
	toast.text = "换一批次数 +%d" % p_count
	toast.position = Vector2(150.0, 300.0)
	toast.size = Vector2(420.0, 30.0)
	toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(toast)
	var tw := toast.create_tween()
	tw.tween_property(toast, "position:y", 260.0, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_interval(1.4)
	tw.tween_property(toast, "modulate:a", 0.0, 0.4)
	tw.tween_callback(toast.queue_free)


func _on_mechanics_intro(p_text: String) -> void:
	# 大关新机制解锁横幅（开局宣告）：复用波次 toast 位 + 加长展示时长（文案需读完）
	_show_toast(p_text, INTRO_TOAST_TIME)


func _on_achievement_toast(p_ach_id: StringName) -> void:
	# 成就达成 toast（右上滑入：名称 + 结晶奖励——养成闭环反馈，M8）
	var reward := 10
	var aname := String(p_ach_id)
	for a in Meta.ACHIEVEMENTS:
		if a.id == p_ach_id:
			reward = int(a.get("reward", 10))
			aname = String(a.name)
			break
	var toast := StickerTheme.label_sticker(Label.new(), 17, PopPalette.GOLD, 4, Color.WHITE, true)
	toast.text = "🏆 成就达成：%s（+%d💎）" % [aname, reward]
	toast.position = Vector2(150.0, 300.0)
	toast.size = Vector2(420.0, 30.0)
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
	# 左下角构筑面板点击（左键按下即发——详情申请，GameLoop 仲裁暂停 + 详情模式）
	if p_ev is InputEventMouseButton and (p_ev as InputEventMouseButton).pressed \
			and (p_ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		build_details_requested.emit()


func _on_damage_resolved(p_result: DamageResult) -> void:
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
	# 复用波次 toast 位播报 + 构筑签名失效（下帧 refresh_stats 即时重绘 🔒 → 空槽）。
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
	# R183：解锁态入签名（unlocked/有效帽变化 → 🔒 徽记即时增减，不等下一张卡）
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
	# 构筑面板重建：武器图标行（R183 按有效帽画满槽位——持有=图标+Lv 角标；空槽=圆环；
	# 未解锁=🔒 上锁样式）+ 词条宝石行（跨武器聚合挂载序）
	if _build_panel == null or player == null or not is_instance_valid(player):
		return
	for child in _build_panel.get_children():
		if child.name != "BuildBg":
			child.queue_free()
	var content := Control.new()
	content.name = "BuildContent"
	content.position = Vector2(10.0, 8.0)
	content.size = Vector2(232.0, 98.0)
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_panel.add_child(content)
	# ① 武器图标行（R183：槽位数 = 难度有效帽（5/6/6，金卡越帽同步多画）——
	# 「上限有多少画多少」；6~7 槽时图标缩一档防溢出（232px 内容宽内动态排布）
	var slots: Array = player.get("weapon_slots")
	var unlocked: int = int(player.get("unlocked_slots"))
	var cap := 5
	if player.has_method(&"slot_cap_total"):
		cap = clampi(int(player.call(&"slot_cap_total")), 1, 7)
	var icon_size := 40.0 if cap <= 5 else (36.0 if cap == 6 else 32.0)
	var step := 232.0 / float(cap)
	for i in range(cap):
		var w: Variant = slots[i] if i < slots.size() else null
		var slot_x := float(i) * step + (step - icon_size) * 0.5
		var icon := TextureRect.new()
		icon.name = "Wpn%d" % i
		icon.position = Vector2(slot_x, 0.0)
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
			var tip := "%s Lv%d" % [String(wdata.get("display_name")) if wdata != null else "?", wlv]
			var next_note := _next_level_note(w, wlv)
			if next_note != "":
				tip += "
下一级：%s" % next_note
			else:
				tip += "
已满级 · 终极形态"
			icon.tooltip_text = tip
			icon.mouse_filter = Control.MOUSE_FILTER_STOP
			content.add_child(icon)
			var lv := StickerTheme.label_sticker(Label.new(), 11, PopPalette.INK, 0, Color.WHITE, true)
			lv.text = "Lv%d" % int(w.get("level"))
			lv.size = Vector2(step, 13.0)
			lv.position = Vector2(float(i) * step, 40.0)
			lv.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			content.add_child(lv)
		else:
			# R183 上锁样式：🔒 徽记 + 暗环（用户口径「另外就弄个上锁的样式」）——
			# 解锁靠波次里程碑/金卡扩容，未解锁槽位一眼可辨（原实现仅压暗）
			var locked := i >= unlocked
			icon.texture = TextureFactory.ring_tex(
				PopPalette.INK_SOFT if locked else PopPalette.INK_SOFT.lerp(Color.WHITE, 0.4),
				36, 2.6)
			icon.modulate.a = 0.28 if locked else 0.6
			content.add_child(icon)
			if locked:
				# R183 悬停说明：玩家能看懂怎么解锁（评审反馈「锁着但没说怎么开」）
				icon.tooltip_text = "🔒 尚未解锁——随波次推进与 Boss 掉落逐步解锁（金卡可提前解锁一把）"
				icon.mouse_filter = Control.MOUSE_FILTER_STOP
				var lock := StickerTheme.label_sticker(Label.new(), 13, PopPalette.INK_SOFT,
					0, Color.WHITE, true)
				lock.name = "Lock%d" % i
				lock.text = "🔒"
				lock.size = Vector2(step, 16.0)
				lock.position = Vector2(float(i) * step, 12.0)
				lock.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				content.add_child(lock)
	# ② 词条宝石行（跨武器聚合挂载序，最多 7 枚：类别章形 + ×层数）
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
	for gi in range(mini(gems.size(), 7)):
		var gx := float(gi % 7) * 32.0
		var gem_icon := TextureRect.new()
		gem_icon.name = "Gem%d" % gi
		gem_icon.texture = TextureFactory.type_icon(1, int(gems[gi]["pool"]))
		gem_icon.position = Vector2(gx, 60.0)
		gem_icon.custom_minimum_size = Vector2(24.0, 24.0)
		gem_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		gem_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		gem_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		content.add_child(gem_icon)
		if int(gems[gi]["layers"]) > 1:
			var cnt := StickerTheme.label_sticker(Label.new(), 10, PopPalette.INK, 0, Color.WHITE, true)
			cnt.text = "×%d" % int(gems[gi]["layers"])
			cnt.size = Vector2(20.0, 12.0)
			cnt.position = Vector2(gx + 2.0, 82.0)
			content.add_child(cnt)


# ── 程序化 UI 组装（方向 C 贴纸风） ────────────────────────────────
func _build_ui() -> void:
	# R186 TargetBar（左上「当前攻击单位」白胶囊血条：视觉向 BossBar 看齐弱一档；
	# HUD CanvasLayer 直挂且先于 Root 建 = 画在 HUD 内容下层；节点名锁定设计案 §4）
	_tb_root = Control.new()
	_tb_root.name = "TargetBarRoot"
	_tb_root.theme = StickerTheme.theme()
	_tb_root.position = Vector2(24.0, TB_POS_Y)
	_tb_root.size = TB_SIZE
	_tb_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tb_root.visible = false
	_tb_root.modulate.a = TB_BASE_ALPHA
	add_child(_tb_root)
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
	_tb_name_label = StickerTheme.label_sticker(Label.new(), 13, PopPalette.INK, 0, Color.WHITE, true)
	_tb_name_label.name = "TargetName"
	_tb_name_label.text = ""
	_tb_name_label.position = Vector2(12.0, 3.0)
	_tb_name_label.size = Vector2(140.0, 20.0)
	_tb_name_label.clip_text = true
	_tb_panel.add_child(_tb_name_label)
	_tb_hp_label = StickerTheme.label_sticker(Label.new(), 13, PopPalette.INK, 0, Color.WHITE, true)
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

	# HP 白胶囊（圆角 + 藏青描边；填充 = 纯渐变，克制无表情）
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
	_hp_label = StickerTheme.label_sticker(Label.new(), 18, PopPalette.INK, 0, Color.WHITE, true)
	_hp_label.name = "HpText"
	_hp_label.size = Vector2(HP_BAR_SIZE.x, 24.0)
	_hp_label.position = Vector2(0.0, 3.0)
	_hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hp_panel.add_child(_hp_label)
	# R186 复活次数常驻徽标（血条右上「✚×N」小 label：refresh_stats 驱动，归零置灰）
	_revive_badge = StickerTheme.label_sticker(Label.new(), 13, PopPalette.GOLD, 4, Color.WHITE, true)
	_revive_badge.name = "ReviveBadge"
	_revive_badge.text = "✚×0"
	_revive_badge.size = Vector2(64.0, 16.0)
	_revive_badge.position = Vector2(300.0, 16.0)
	_revive_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_revive_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_revive_badge)
	# R187 武器形态读数位（单行紧凑徽标，refresh_stats 驱动 + 信号即时刷新）：
	# 「束 ×N」= W4 副激光束数徽标 /「镜 ×N」= W5 镜面军团角标 /「爆 ×N」= W8 蓄能引爆读数
	_r187_readout = StickerTheme.label_sticker(Label.new(), 13, PopPalette.SHOCK.lerp(Color.WHITE, 0.25), 4, Color.WHITE, true)
	_r187_readout.name = "R187Readout"
	_r187_readout.text = ""
	_r187_readout.size = Vector2(180.0, 16.0)
	_r187_readout.position = Vector2(300.0, 34.0)
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
	_level_label = StickerTheme.label_sticker(Label.new(), 18, PopPalette.INK, 0, Color.WHITE, true)
	_level_label.name = "LevelText"
	_level_label.text = "Lv 1"
	_level_label.position = Vector2(356.0, 60.0)
	root.add_child(_level_label)

	# 波次圆形徽章（右上）
	var badge := _sticker_panel(root, Vector2(598.0, 16.0), Vector2(106.0, 106.0), 53.0)
	_add_hover(badge, "波次
当前波次；清完最终 Boss 波即通关结算")
	var badge_cap := StickerTheme.label_sticker(Label.new(), 13, PopPalette.INK_SOFT)
	badge_cap.text = "WAVE"
	badge_cap.size = Vector2(106.0, 16.0)
	badge_cap.position = Vector2(0.0, 22.0)
	badge_cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.add_child(badge_cap)
	_wave_label = StickerTheme.label_sticker(Label.new(), 22, PopPalette.INK, 0, Color.WHITE, true)
	_wave_label.name = "WaveText"
	_wave_label.text = "第 0 波"
	_wave_label.size = Vector2(106.0, 34.0)
	_wave_label.position = Vector2(0.0, 42.0)
	_wave_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.add_child(_wave_label)

	# 击杀气泡 + 计时气泡
	var kill_pill := _sticker_panel(root, Vector2(24.0, 92.0), Vector2(150.0, 36.0), 18.0)
	_add_hover(kill_pill, "击杀
本局击杀数（图鉴/成就统计源）")
	_kill_label = StickerTheme.label_sticker(Label.new(), 18, PopPalette.INK, 0, Color.WHITE, true)
	_kill_label.name = "KillText"
	_kill_label.text = "击杀 0"
	_kill_label.size = Vector2(150.0, 24.0)
	_kill_label.position = Vector2(0.0, 6.0)
	_kill_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	kill_pill.add_child(_kill_label)
	var time_pill := _sticker_panel(root, Vector2(184.0, 92.0), Vector2(112.0, 36.0), 18.0)
	_add_hover(time_pill, "时长
本局已经过时间")
	_time_label = StickerTheme.label_sticker(Label.new(), 18, PopPalette.INK_SOFT)
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
	_skill_cd_label = StickerTheme.label_sticker(Label.new(), 26, PopPalette.INK, 4, Color.WHITE, true)
	_skill_cd_label.name = "SkillCd"
	_skill_cd_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_skill_cd_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_skill_cd_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_skill_cd_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_skill_cd_label.text = ""
	skill_btn.add_child(_skill_cd_label)
	# 金币 pill（击杀/计时/护盾同行末段——2026-08-31 P0 反馈「金币压血条」修复落位；
	# 原 (24,44) 与血条 24~54/经验条 63~77 双重叠，现移至护盾条右侧 464~596）
	var gold_pill := _sticker_panel(root, Vector2(464.0, 92.0), Vector2(132.0, 36.0), 18.0)
	_add_hover(gold_pill, "战地金币
击杀掉落，黑市购物专用货币
（「丰饶/富矿」祝福提升获取）")
	gold_pill.name = "GoldPill"
	gold_pill.modulate.a = 0.94
	_gold_label = StickerTheme.label_sticker(Label.new(), 17, PopPalette.XP, 0, Color.WHITE, true)
	_gold_label.text = "◎ 0"
	_gold_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_gold_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_gold_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	gold_pill.add_child(_gold_label)
	# Boss 出场横幅（演出：缩放弹入 → 停留 → 淡出）
	_boss_banner = StickerTheme.label_sticker(Label.new(), 30, PopPalette.ENEMY, 6, Color.WHITE, true)
	_boss_banner.name = "BossBanner"
	_boss_banner.text = ""
	_boss_banner.position = Vector2(0.0, 210.0)
	_boss_banner.size = Vector2(720.0, 46.0)
	_boss_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_boss_banner.visible = false
	_boss_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_boss_banner)
		# 构筑面板（左下角，避开弹幕主区——用户反馈 2026-08-29：当前持有武器+词条要展示；
	# 二轮反馈「点击左下角，可以看 buff 详情」→ 面板可点击 → 暂停 + 构筑详情卡）
	var build_root := Control.new()
	build_root.name = "BuildPanel"
	build_root.position = Vector2(24.0, 1124.0)
	build_root.size = Vector2(252.0, 132.0)
	build_root.mouse_filter = Control.MOUSE_FILTER_STOP
	build_root.gui_input.connect(_on_build_gui_input)
	root.add_child(build_root)
	_build_panel = build_root
	var build_bg := _sticker_panel(build_root, Vector2.ZERO, Vector2(252.0, 132.0), 16.0)
	build_bg.name = "BuildBg"
	build_bg.modulate.a = 0.92
	build_bg.mouse_filter = Control.MOUSE_FILTER_PASS               # 点击穿透到 BuildPanel
	_build_label = StickerTheme.label_sticker(Label.new(), 14, PopPalette.INK_SOFT)
	_build_label.name = "BuildText"
	_build_label.text = "构筑 · 点击查看详情"
	_build_label.size = Vector2(252.0, 18.0)
	_build_label.position = Vector2(0.0, 110.0)
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
	StickerTheme.label_sticker(_hover_label, 14, Color.WHITE, 0, Color.TRANSPARENT)
	_hover_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hover_label.custom_minimum_size = Vector2(300.0, 0.0)
	_hover_card.add_child(_hover_label)
	root.add_child(_hover_card)

	# 护盾条（时间气泡右侧；MEC_SHIELD 持有才显示——用户反馈「单独的护盾条」）
	_shield_panel = _sticker_panel(root, Vector2(306.0, 92.0), Vector2(148.0, 36.0), 18.0)
	_add_hover(_shield_panel, "临时护盾
持有「能量护盾」词条时出现
就绪=挡下一次接触伤害；挡后进入充能")
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
	var shield_tag := StickerTheme.label_sticker(Label.new(), 12, PopPalette.INK_SOFT)
	shield_tag.text = "护盾"
	shield_tag.position = Vector2(36.0, 8.0)
	shield_tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shield_panel.add_child(shield_tag)

	# 暂停按钮（右上角贴纸图标：白底圆角 + 藏青 ⏸ 双竖条；仅 PLAYING 态显示——
	# 用户反馈 2026-08-29「没有暂停的地方」；申请经信号 → GameLoop 仲裁）
	_pause_btn = Button.new()
	_pause_btn.name = "PauseButton"
	for style_name in ["normal", "hover", "pressed", "focus", "disabled"]:
		_pause_btn.add_theme_stylebox_override(style_name, StyleBoxEmpty.new())
	_pause_btn.position = Vector2(514.0, 26.0)
	_pause_btn.size = Vector2(66.0, 66.0)
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

	# 波次 toast（果冻 pop；居中，避开 Boss 条与状态提示行）
	_toast_label = StickerTheme.label_sticker(Label.new(), 34, PopPalette.INK, 12, Color.WHITE, true)
	_toast_label.name = "WaveToast"
	_toast_label.text = ""
	_toast_label.size = Vector2(720.0, 44.0)
	_toast_label.position = Vector2(0.0, 392.0)
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.visible = false
	root.add_child(_toast_label)

	# 状态提示（测试锁定节点名与文案口径）
	_state_label = StickerTheme.label_sticker(Label.new(), 32, PopPalette.INK, 12, Color.WHITE, true)
	_state_label.name = "StateLabel"
	_state_label.text = ""
	_state_label.size = Vector2(720.0, 44.0)
	_state_label.position = Vector2(0.0, 212.0)
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
	# R186 复活大字横幅（金色 48 号；y316 介于状态行 y212 与 toast y392 之间——设计案 §2）
	_revive_banner = StickerTheme.label_sticker(Label.new(), 48, PopPalette.GOLD, 8, Color.WHITE, true)
	_revive_banner.name = "ReviveBanner"
	_revive_banner.text = ""
	_revive_banner.position = Vector2(0.0, 316.0)
	_revive_banner.size = Vector2(720.0, 52.0)
	_revive_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_revive_banner.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_revive_banner.visible = false
	_revive_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_revive_banner)
	refresh_stats()


func _sticker_panel(p_parent: Control, p_pos: Vector2, p_size: Vector2, p_radius: float,
		p_tip: String = "") -> Panel:
	# 贴纸面板工厂（白底 + 藏青描边 + 底部厚投影；HUD 专用轻量版，无投影避免顶部杂乱）。
	# R10：p_tip 非空 → 悬停说明（桌面鼠标悬停即出，移动端无碍）
	var panel := Panel.new()
	var sb := StickerTheme.panel_style(p_radius, 3, false)
	panel.add_theme_stylebox_override("panel", sb)
	panel.position = p_pos
	panel.size = p_size
	if p_tip != "":
		panel.tooltip_text = p_tip
		panel.mouse_filter = Control.MOUSE_FILTER_STOP
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
	_toast_label.text = p_text
	_toast_label.remove_theme_font_size_override("font_size")     # R86：重置后按本文缩放
	_toast_label.add_theme_font_size_override("font_size", 34)
	_fit_font_size(_toast_label, p_text, 700.0)
	_toast_label.reset_size()
	_toast_label.size = Vector2(720.0, 44.0)
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
	var candidates: Array[int] = []
	if not _agg.is_empty():
		candidates.assign(_agg.keys())
		candidates.sort_custom(_tb_uid_desc)
	var primary: Node2D = _tb_first_qualified(candidates)
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
	_tb_hp_label.text = "%s/%s" % [_tb_fmt_num(hp), _tb_fmt_num(mh)]


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
		# 横幅三段式（复制 boss_banner 三段式）：弹入 0.22 → 停留 1.2 → 淡出 0.4
		# ≈1.82s < 3s 无敌；余量 0 切警示色 + 「次数已耗尽」文案
		var text := ("✦ 复活！剩余 %d 次" % p_charges) if p_charges > 0 else "✦ 复活！次数已耗尽"
		_revive_banner.text = text
		_revive_banner.add_theme_color_override("font_color",
			PopPalette.GOLD if p_charges > 0 else PopPalette.ENEMY)
		_revive_banner.remove_theme_font_size_override("font_size")
		_revive_banner.add_theme_font_size_override("font_size", 48)
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
