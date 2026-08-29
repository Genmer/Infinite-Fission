# scripts/ui/hud.gd
# M-16 HUD（架构 §2.15）：HP/经验/等级/波次/击杀/计时 + 词条栏（构筑统计）。
# 方向 A 重排：顶部琥珀经验条（屏宽）+ 渐变 HP 条（受击抖动 + 低血压红呼吸）+ 波次徽章
# + 等宽击杀数 + 词条徽章栏；波次 toast（2s 淡入出）+ Boss 预警横幅（Lore 单源文案）。
# process_mode = ALWAYS（暂停/顿帧期间 UI 照常，Q-14）；刷新 = 事件驱动 + 1Hz 兜底
# （架构 refresh_stats 口径：计时兜底走 raw 通道 tick）。
# 数值源：Player（HP/经验/等级/词条栏）+ wave_started / enemy_killed 事件（波次/击杀）。
class_name HUD
extends CanvasLayer

var player: Node2D = null                     # 注入（数值源；Player 宽类型规避循环解析）
var total_damage: float = 0.0                 # 造成的总伤害（damage_resolved 累计；结算屏数据源）

var _hp_fill: TextureProgressBar = null       # HP 条填充（渐变纹理；低血切红态纹理）
var _root: Control = null                     # HUD 根（MENU 态整层隐藏用）
var _hp_frame: Control = null                 # HP 条宿主（受击抖动作用位）
var _hp_label: Label = null
var _xp_fill: TextureProgressBar = null       # 经验条填充（琥珀渐变）
var _level_label: Label = null
var _wave_label: Label = null
var _kill_label: Label = null
var _time_label: Label = null
var _build_label: Label = null                # 词条栏（武器/词条计数徽章）
var _state_label: Label = null                # 状态提示（LEVEL_UP/PAUSED/GAME_OVER）
var _toast_label: Label = null                # 波次 toast
var _alert_label: Label = null                # Boss 预警横幅

var kills: int = 0
var wave: int = 0
var run_elapsed: float = 0.0                  # 计时（raw 通道累计——含顿帧，观感口径）
var _fallback_timer: float = 0.0              # 1Hz 兜底刷新
var _hp_shake: float = 0.0                    # HP 条受击抖动强度（raw 通道衰减）
var _toast_left: float = 0.0                  # toast 剩余（总 2s：0.35 淡入 + 1.3 停 + 0.35 淡出）
var _alert_left: float = 0.0                  # Boss 横幅剩余（2.6s）

const LAYER_ORDER := 10
const HP_BAR_SIZE := Vector2(320.0, 18.0)
const XP_BAR_SIZE := Vector2(720.0, 5.0)
const HP_LOW_PCT := 0.3                       # 低血压阈值（红呼吸）
const TOAST_TOTAL := 2.0
const TOAST_FADE := 0.35
const ALERT_TOTAL := 2.6
const HP_FRAME_POS := Vector2(24.0, 18.0)


func _ready() -> void:
	# ALWAYS：暂停/顿帧期间 UI 照常（Q-14）
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = LAYER_ORDER
	_build_ui()


func bind_events() -> void:
	# 订阅 player_hit / xp_gained / wave_started / enemy_killed / state_changed / damage_resolved
	# + boss_spawned（预警横幅——表现层增订，不改既有订阅序）
	EventBus.player_hit.connect(_on_player_hit)
	EventBus.xp_gained.connect(_on_xp_gained)
	EventBus.wave_started.connect(_on_wave_started)
	EventBus.enemy_killed.connect(_on_enemy_killed)
	EventBus.state_changed.connect(_on_state_changed)
	EventBus.damage_resolved.connect(_on_damage_resolved)
	EventBus.boss_spawned.connect(_on_boss_spawned)


func setup(p_player: Node2D) -> void:
	# 数值源注入
	player = p_player


func refresh_stats() -> void:
	# HP/经验/等级/波次/击杀/计时（事件驱动 + 1Hz 兜底刷新共用）
	if player != null and is_instance_valid(player):
		var hp: float = player.get("hp")
		var max_hp: float = player.get("max_hp")
		var pct := 0.0 if max_hp <= 0.0 else clampf(hp / max_hp, 0.0, 1.0)
		_apply_hp_pct(pct)
		_hp_label.text = "HP %d/%d" % [int(round(hp)), int(round(max_hp))]
		var xp: float = player.get("xp")
		var need: float = player.get("xp_need")
		var xp_pct := 0.0 if need <= 0.0 else clampf(xp / need, 0.0, 1.0)
		_xp_fill.value = xp_pct * 100.0
		_level_label.text = "Lv %d" % int(player.get("level"))
		_build_label.text = _build_summary()
	_wave_label.text = "WAVE %d" % wave
	_kill_label.text = "KILLS %04d" % kills
	_time_label.text = "%d:%02d" % [int(run_elapsed) / 60, int(run_elapsed) % 60]


func tick(p_raw_delta: float) -> void:
	# ①~⑧ 帧序 UI 阶段（raw 通道）：计时累计 + 1Hz 兜底刷新 + 表现层动画（抖动/呼吸/toast）
	run_elapsed += p_raw_delta
	_fallback_timer += p_raw_delta
	if _fallback_timer >= 1.0:
		_fallback_timer = 0.0
		refresh_stats()
	# HP 条受击抖动（衰减 + 随机偏移）
	if _hp_shake > 0.0:
		_hp_shake = maxf(_hp_shake - p_raw_delta * 5.0, 0.0)
		_hp_frame.position = HP_FRAME_POS + Vector2(
			randf_range(-1.0, 1.0) * _hp_shake * 6.0, randf_range(-1.0, 1.0) * _hp_shake * 4.0)
	# 低血压红呼吸（≤30%：红态纹理 + 呼吸明度）
	_breath_low_hp(p_raw_delta)
	# 波次 toast（2s：淡入 → 停 → 淡出）
	if _toast_left > 0.0:
		_toast_left = maxf(_toast_left - p_raw_delta, 0.0)
		_toast_label.modulate.a = _toast_alpha(_toast_left, TOAST_TOTAL)
	# Boss 预警横幅（2.6s 同口径 + 微闪）
	if _alert_left > 0.0:
		_alert_left = maxf(_alert_left - p_raw_delta, 0.0)
		_alert_label.modulate.a = _toast_alpha(_alert_left, ALERT_TOTAL)
		_alert_label.visible = _alert_left > 0.0


# ── 测试观测口（displayed 值，headless 断言用） ────────────────────
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
	_hp_shake = 1.0                              # 受击抖动（raw 通道 tick 衰减）
	refresh_stats()


func _on_xp_gained(_p_amount: float) -> void:
	refresh_stats()


func _on_wave_started(p_wave: int) -> void:
	wave = p_wave
	_show_toast(Lore.wave_toast_text(p_wave))    # 波次 toast（第 N 波 · 后缀递进）
	refresh_stats()


func _on_enemy_killed(_p_enemy: Node2D) -> void:
	kills += 1
	refresh_stats()


func _on_boss_spawned(_p_enemy: Node2D) -> void:
	# Boss 预警横幅（⚠ 高能反应体接近 —— Boss 名按波次；Lore 单源）
	_alert_label.text = Lore.boss_alert_text(maxi(wave, 1))
	_alert_left = ALERT_TOTAL
	_alert_label.visible = true
	_alert_label.modulate.a = 0.0


func _on_state_changed(p_state: int) -> void:
	# 状态提示（LEVEL_UP/PAUSED/GAME_OVER 覆盖显示；PLAYING 隐藏）+ 状态切换刷新
	# （升级→LEVEL_UP 的 state_changed 晚于 xp_gained——等级数值在此同步）
	# 方向 A：MENU 态整层隐藏（主菜单透出星空，HUD 信息不穿帮）
	_root.visible = p_state != GameConst.GameStatus.MENU
	match p_state:
		GameConst.GameStatus.LEVEL_UP:
			_state_label.text = "LEVEL UP - choose a card"
			_state_label.visible = true
		GameConst.GameStatus.PAUSED:
			_state_label.text = "PAUSED"
			_state_label.visible = true
		GameConst.GameStatus.GAME_OVER:
			_state_label.text = "GAME OVER"
			_state_label.visible = true
		_:
			_state_label.visible = false
	refresh_stats()


func _on_damage_resolved(p_result: DamageResult) -> void:
	# 总伤害统计（结算屏数据源；HUD 不逐次刷新——1Hz 兜底承担）
	total_damage += p_result.final_value


func _build_summary() -> String:
	# 词条栏：武器数 + 武器词条数（构筑统计占位；正式构筑面板后续迭代）
	if player == null or not is_instance_valid(player):
		return "Build -"
	var slots: Array = player.get("weapon_slots")
	var wcount := 0
	var tcount := 0
	for w in slots:
		if w != null and is_instance_valid(w):
			wcount += 1
			var stack: Variant = w.get("trait_stack")
			if stack != null and stack.get("traits") != null:
				tcount += (stack.get("traits") as Array).size()
	return "W%d · T%d" % [wcount, tcount]


# ── 表现层支撑 ───────────────────────────────────────────────────
func _apply_hp_pct(p_pct: float) -> void:
	# HP 条：渐变填充；低血切红态纹理（呼吸明度在 tick 呼吸函数处理）
	_hp_fill.value = p_pct * 100.0
	_hp_fill.texture_progress = TextureFactory.hp_low_gradient() \
		if p_pct <= HP_LOW_PCT else TextureFactory.hp_gradient()
	_hp_fill.tint_progress = Color.WHITE if p_pct > 0.0 else Color(Palette.RED, 0.4)


func _breath_low_hp(_p_raw_delta: float) -> void:
	# 低血压红呼吸：低血态红条明度呼吸 + 微脉动（满血时无效果；Time 时钟驱动）
	if player == null or not is_instance_valid(player):
		return
	var hp: float = player.get("hp")
	var max_hp: float = player.get("max_hp")
	var pct := 1.0 if max_hp <= 0.0 else hp / max_hp
	if pct <= HP_LOW_PCT and pct > 0.0:
		var t := Time.get_ticks_msec() / 1000.0
		_hp_fill.tint_progress = Color(1.0, 1.0, 1.0).lerp(
			Color(1.6, 1.2, 1.2), 0.5 + 0.5 * sin(t * 6.0))
	elif _hp_fill.tint_progress != Color(Palette.RED, 0.4):
		_hp_fill.tint_progress = Color.WHITE


func _show_toast(p_text: String) -> void:
	_toast_label.text = p_text
	_toast_left = TOAST_TOTAL
	_toast_label.modulate.a = 0.0
	_toast_label.visible = true


func _toast_alpha(p_left: float, p_total: float) -> float:
	# 淡入 → 停 → 淡出 的 alpha 包络
	if p_left >= p_total - TOAST_FADE:
		return clampf((p_total - p_left) / TOAST_FADE, 0.0, 1.0)
	if p_left <= TOAST_FADE:
		return clampf(p_left / TOAST_FADE, 0.0, 1.0)
	return 1.0


# ── 程序化 UI 组装 ────────────────────────────────────────────────
func _build_ui() -> void:
	# 深空霓虹 HUD（竖屏顶部信息区 + 底部词条徽章栏）
	var root := Control.new()
	_root = root
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UITheme.apply_theme(root)
	add_child(root)
	# 经验条（最顶全宽琥珀能量槽）
	var xp_bg := TextureProgressBar.new()
	xp_bg.name = "XpBg"
	xp_bg.nine_patch_stretch = true
	xp_bg.texture_under = TextureFactory.white_px()
	xp_bg.tint_under = Color(0.08, 0.09, 0.16, 0.9)
	xp_bg.texture_progress = TextureFactory.xp_gradient()
	xp_bg.fill_mode = TextureProgressBar.FILL_LEFT_TO_RIGHT
	xp_bg.min_value = 0.0
	xp_bg.max_value = 100.0
	xp_bg.position = Vector2.ZERO
	xp_bg.size = XP_BAR_SIZE
	xp_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(xp_bg)
	_xp_fill = xp_bg
	_xp_fill.value = 0.0
	# HP 条（玻璃框 + 渐变填充 + 内嵌数值）
	_hp_frame = Control.new()
	_hp_frame.name = "HpFrame"
	_hp_frame.position = HP_FRAME_POS
	_hp_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_hp_frame)
	var hp_panel := UITheme.make_glass_panel(Palette.PANEL_EDGE)
	hp_panel.position = Vector2.ZERO
	hp_panel.size = HP_BAR_SIZE + Vector2(8.0, 8.0)
	_hp_frame.add_child(hp_panel)
	var hp_bar := TextureProgressBar.new()
	hp_bar.name = "HpBar"
	hp_bar.nine_patch_stretch = true
	hp_bar.texture_under = TextureFactory.white_px()
	hp_bar.tint_under = Color(0.05, 0.06, 0.12, 0.95)
	hp_bar.texture_progress = TextureFactory.hp_gradient()
	hp_bar.fill_mode = TextureProgressBar.FILL_LEFT_TO_RIGHT
	hp_bar.min_value = 0.0
	hp_bar.max_value = 100.0
	hp_bar.position = Vector2(4.0, 4.0)
	hp_bar.size = HP_BAR_SIZE
	hp_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hp_frame.add_child(hp_bar)
	_hp_fill = hp_bar
	_hp_fill.value = 100.0
	# HP 数值（嵌在填充条内层居中：等宽 + 深色描边——亮青渐变上仍可读）
	_hp_label = UITheme.make_label("HP 100/100", Palette.FONT_CAPTION, Palette.TEXT_MAIN, true)
	_hp_label.name = "HpLabel"
	_hp_label.position = Vector2(4.0, 4.0)
	_hp_label.size = HP_BAR_SIZE
	_hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hp_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hp_frame.add_child(_hp_label)
	# 顶部中央：波次徽章（玻璃 chip）
	var wave_chip := UITheme.make_glass_panel(Palette.CYAN)
	wave_chip.name = "WaveChip"
	wave_chip.position = Vector2(310.0, 14.0)
	wave_chip.size = Vector2(100.0, 34.0)
	root.add_child(wave_chip)
	_wave_label = UITheme.make_label("WAVE 0", Palette.FONT_BODY, Palette.CYAN, true)
	_wave_label.name = "WaveLabel"
	_wave_label.position = Vector2(310.0, 14.0)
	_wave_label.size = Vector2(100.0, 34.0)
	_wave_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_wave_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	root.add_child(_wave_label)
	# 右上：击杀（等宽）+ 等级 + 计时
	_kill_label = UITheme.make_label("KILLS 0000", Palette.FONT_NUM, Palette.AMBER, true)
	_kill_label.name = "KillLabel"
	_kill_label.position = Vector2(520.0, 16.0)
	_kill_label.size = Vector2(176.0, 24.0)
	_kill_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	root.add_child(_kill_label)
	_level_label = UITheme.make_label("Lv 1", Palette.FONT_BODY, Palette.CYAN, true)
	_level_label.name = "LevelLabel"
	_level_label.position = Vector2(520.0, 46.0)
	_level_label.size = Vector2(176.0, 22.0)
	_level_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	root.add_child(_level_label)
	_time_label = UITheme.make_label("0:00", Palette.FONT_CAPTION, Palette.TEXT_DIM, true)
	_time_label.name = "TimeLabel"
	_time_label.position = Vector2(520.0, 70.0)
	_time_label.size = Vector2(176.0, 20.0)
	_time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	root.add_child(_time_label)
	# 底部：词条徽章栏（构筑统计 chip）
	var build_chip := UITheme.make_glass_panel(Palette.PANEL_EDGE)
	build_chip.name = "BuildChip"
	build_chip.position = Vector2(24.0, 1216.0)
	build_chip.size = Vector2(110.0, 34.0)
	root.add_child(build_chip)
	_build_label = UITheme.make_label("Build -", Palette.FONT_CAPTION, Palette.TEXT_DIM, true)
	_build_label.name = "BuildLabel"
	_build_label.position = Vector2(24.0, 1216.0)
	_build_label.size = Vector2(110.0, 34.0)
	_build_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_build_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	root.add_child(_build_label)
	# 波次 toast（顶部下 200，居中；title 字重 + 深描边）
	_toast_label = UITheme.make_label("", 22, Palette.CYAN)
	_toast_label.name = "Toast"
	_toast_label.add_theme_font_override("font", UITheme.font_title())
	_toast_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_toast_label.position = Vector2(0.0, 200.0)
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.visible = false
	root.add_child(_toast_label)
	# Boss 预警横幅（Boss 条块 y≈118~164 之下、toast 之上——同屏不重叠）
	_alert_label = UITheme.make_label("", 26, Palette.RED)
	_alert_label.name = "BossAlert"
	_alert_label.add_theme_font_override("font", UITheme.font_title())
	_alert_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_alert_label.position = Vector2(0.0, 172.0)
	_alert_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_alert_label.visible = false
	root.add_child(_alert_label)
	# 状态提示（LEVEL_UP/PAUSED/GAME_OVER；文本为测试锁定断言——仅样式调整）
	_state_label = UITheme.make_label("", 24, Palette.AMBER)
	_state_label.name = "StateLabel"
	_state_label.add_theme_font_override("font", UITheme.font_title())
	_state_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_state_label.position = Vector2(0.0, 560.0)
	_state_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_state_label.visible = false
	refresh_stats()
