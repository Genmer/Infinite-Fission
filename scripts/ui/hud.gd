# scripts/ui/hud.gd
# M-16 HUD（架构 §2.15）：HP/经验/等级/波次/击杀/计时 + 词条栏（构筑统计）。
# 程序化占位美术（纯色 ColorRect + Label；正式美术后续迭代）。
# process_mode = ALWAYS（暂停/顿帧期间 UI 照常，Q-14）；刷新 = 事件驱动 + 1Hz 兜底
# （架构 refresh_stats 口径：计时兜底走 raw 通道 tick）。
# 数值源：Player（HP/经验/等级/词条栏）+ wave_started / enemy_killed 事件（波次/击杀）。
class_name HUD
extends CanvasLayer

var player: Node2D = null                     # 注入（数值源；Player 宽类型规避循环解析）
var total_damage: float = 0.0                 # 造成的总伤害（damage_resolved 累计；结算屏数据源）

var _hp_fill: ColorRect = null                # HP 条填充（比例缩放）
var _hp_label: Label = null
var _xp_fill: ColorRect = null                # 经验条填充
var _level_label: Label = null
var _wave_label: Label = null
var _kill_label: Label = null
var _time_label: Label = null
var _build_label: Label = null                # 词条栏（武器/词条计数行）
var _state_label: Label = null                # 状态提示（LEVEL_UP/PAUSED/GAME_OVER）

var kills: int = 0
var wave: int = 0
var run_elapsed: float = 0.0                  # 计时（raw 通道累计——含顿帧，观感口径）
var _fallback_timer: float = 0.0              # 1Hz 兜底刷新

const HP_BAR_SIZE := Vector2(320.0, 22.0)
const XP_BAR_SIZE := Vector2(320.0, 10.0)


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


func setup(p_player: Node2D) -> void:
	# 数值源注入
	player = p_player


func refresh_stats() -> void:
	# HP/经验/等级/波次/击杀/计时（事件驱动 + 1Hz 兜底刷新共用）
	if player != null and is_instance_valid(player):
		var hp: float = player.get("hp")
		var max_hp: float = player.get("max_hp")
		var pct := 0.0 if max_hp <= 0.0 else clampf(hp / max_hp, 0.0, 1.0)
		_hp_fill.size = Vector2(HP_BAR_SIZE.x * pct, HP_BAR_SIZE.y)
		_hp_label.text = "HP %d/%d" % [int(round(hp)), int(round(max_hp))]
		var xp: float = player.get("xp")
		var need: float = player.get("xp_need")
		var xp_pct := 0.0 if need <= 0.0 else clampf(xp / need, 0.0, 1.0)
		_xp_fill.size = Vector2(XP_BAR_SIZE.x * xp_pct, XP_BAR_SIZE.y)
		_level_label.text = "Lv %d" % int(player.get("level"))
		_build_label.text = _build_summary()
	_wave_label.text = "Wave %d" % wave
	_kill_label.text = "Kills %d" % kills
	_time_label.text = "%d:%02d" % [int(run_elapsed) / 60, int(run_elapsed) % 60]


func tick(p_raw_delta: float) -> void:
	# ①~⑧ 帧序 UI 阶段（raw 通道）：计时累计 + 1Hz 兜底刷新
	run_elapsed += p_raw_delta
	_fallback_timer += p_raw_delta
	if _fallback_timer >= 1.0:
		_fallback_timer = 0.0
		refresh_stats()


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
	refresh_stats()


func _on_xp_gained(_p_amount: float) -> void:
	refresh_stats()


func _on_wave_started(p_wave: int) -> void:
	wave = p_wave
	refresh_stats()


func _on_enemy_killed(_p_enemy: Node2D) -> void:
	kills += 1
	refresh_stats()


func _on_state_changed(p_state: int) -> void:
	# 状态提示（LEVEL_UP/PAUSED/GAME_OVER 覆盖显示；PLAYING 隐藏）+ 状态切换刷新
	# （升级→LEVEL_UP 的 state_changed 晚于 xp_gained——等级数值在此同步）
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
	return "Build  W:%d T:%d" % [wcount, tcount]


# ── 程序化 UI 组装 ────────────────────────────────────────────────
func _build_ui() -> void:
	# 纯色占位美术（ColorRect + Label；竖屏顶部信息区）
	var root := Control.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	var hp_bg := ColorRect.new()
	hp_bg.name = "HpBg"
	hp_bg.color = Color(0.15, 0.16, 0.2, 0.9)
	hp_bg.position = Vector2(24.0, 24.0)
	hp_bg.size = HP_BAR_SIZE
	root.add_child(hp_bg)
	_hp_fill = ColorRect.new()
	_hp_fill.name = "HpFill"
	_hp_fill.color = Color(0.9, 0.3, 0.3)
	_hp_fill.position = Vector2.ZERO
	_hp_fill.size = HP_BAR_SIZE
	hp_bg.add_child(_hp_fill)
	_hp_label = _add_label(root, Vector2(24.0, 48.0), "HP 100/100", 15)

	var xp_bg := ColorRect.new()
	xp_bg.name = "XpBg"
	xp_bg.color = Color(0.15, 0.16, 0.2, 0.9)
	xp_bg.position = Vector2(24.0, 72.0)
	xp_bg.size = XP_BAR_SIZE
	root.add_child(xp_bg)
	_xp_fill = ColorRect.new()
	_xp_fill.name = "XpFill"
	_xp_fill.color = Color(0.35, 0.8, 1.0)
	_xp_fill.size = Vector2.ZERO
	xp_bg.add_child(_xp_fill)

	_level_label = _add_label(root, Vector2(352.0, 44.0), "Lv 1", 15)
	_wave_label = _add_label(root, Vector2(24.0, 92.0), "Wave 0", 15)
	_kill_label = _add_label(root, Vector2(120.0, 92.0), "Kills 0", 15)
	_time_label = _add_label(root, Vector2(224.0, 92.0), "0:00", 15)
	_build_label = _add_label(root, Vector2(24.0, 112.0), "Build -", 13)
	_state_label = _add_label(root, Vector2(0.0, 560.0), "", 22)
	_state_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_state_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_state_label.visible = false
	refresh_stats()


func _add_label(p_parent: Control, p_pos: Vector2, p_text: String, p_size: int) -> Label:
	# 程序化 Label（默认主题字体；尺寸占位）
	var label := Label.new()
	label.position = p_pos
	label.text = p_text
	label.add_theme_font_size_override("font_size", p_size)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p_parent.add_child(label)
	return label
