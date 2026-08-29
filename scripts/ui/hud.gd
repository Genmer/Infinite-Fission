# scripts/ui/hud.gd
# M-16 HUD（架构 §2.15）：HP/经验/等级/波次/击杀/计时 + 词条栏（构筑统计）。
# 方向 B「街机 CRT」终端面板重设计（类名与公开/观测 API 不变——pkg4 锁定口径）：
# 顶部终端状态栏（SENTINEL-9 头行 + 磷光血条 + ASCII 血条 [■■■■□□□□] + WAVE/KILL 行）+
# 波次 toast（> 第 N 波 · 裂变密度 +Δ）+ 状态提示闪烁（文本保持测试锚点原样）。
# process_mode = ALWAYS（暂停/顿帧期间 UI 照常，Q-14）；刷新 = 事件驱动 + 1Hz 兜底。
# 数值源：Player（HP/经验/等级/词条栏）+ wave_started / enemy_killed 事件（波次/击杀）。
class_name HUD
extends CanvasLayer

var player: Node2D = null                     # 注入（数值源；Player 宽类型规避循环解析）
var total_damage: float = 0.0                 # 造成的总伤害（damage_resolved 累计；结算屏数据源）

var _hp_fill: ColorRect = null                # HP 条填充（比例缩放）
var _hp_label: Label = null
var _hp_ascii_label: Label = null             # ASCII 式血条 [■■■■□□□□]（配合真实血条）
var _xp_fill: ColorRect = null                # 经验条填充
var _level_label: Label = null
var _wave_label: Label = null
var _kill_label: Label = null
var _time_label: Label = null
var _build_label: Label = null                # 词条栏（武器/词条计数行）
var _state_label: Label = null                # 状态提示（LEVEL_UP/PAUSED/GAME_OVER）
var _toast_label: Label = null                # 波次 toast（终端行）
var _toast_left: float = 0.0                  # toast 剩余展示时长（raw 通道）
var _blink_t: float = 0.0                     # 状态提示闪烁时钟（raw 通道）

var kills: int = 0
var wave: int = 0
var run_elapsed: float = 0.0                  # 计时（raw 通道累计——含顿帧，观感口径）
var _fallback_timer: float = 0.0              # 1Hz 兜底刷新

const HP_BAR_SIZE := Vector2(320.0, 12.0)
const XP_BAR_SIZE := Vector2(320.0, 8.0)
const TOAST_TIME := 1.6                       # 波次 toast 展示时长 s
const HP_LOW_PCT := 0.3                       # 低血量阈值（血条转热红）


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
		_hp_fill.color = Palette.HOT_RED if pct < HP_LOW_PCT else Palette.PHOS
		_hp_label.text = "HP %d/%d" % [int(round(hp)), int(round(max_hp))]
		_hp_ascii_label.text = Lore.hp_ascii(pct)
		var xp: float = player.get("xp")
		var need: float = player.get("xp_need")
		var xp_pct := 0.0 if need <= 0.0 else clampf(xp / need, 0.0, 1.0)
		_xp_fill.size = Vector2(XP_BAR_SIZE.x * xp_pct, XP_BAR_SIZE.y)
		_level_label.text = "Lv %d" % int(player.get("level"))
		_build_label.text = _build_summary()
	_wave_label.text = "WAVE %02d" % wave
	_kill_label.text = "KILL %04d" % kills
	_time_label.text = "%d:%02d" % [int(run_elapsed) / 60, int(run_elapsed) % 60]


func tick(p_raw_delta: float) -> void:
	# ①~⑧ 帧序 UI 阶段（raw 通道）：计时累计 + 1Hz 兜底刷新 + toast/闪烁推进
	run_elapsed += p_raw_delta
	_fallback_timer += p_raw_delta
	if _fallback_timer >= 1.0:
		_fallback_timer = 0.0
		refresh_stats()
	if _toast_left > 0.0:
		_toast_left = maxf(_toast_left - p_raw_delta, 0.0)
		_toast_label.modulate.a = clampf(_toast_left / TOAST_TIME * 1.6, 0.0, 1.0)
		if _toast_left <= 0.0:
			_toast_label.visible = false
	if _state_label.visible:
		_blink_t += p_raw_delta
		_state_label.modulate.a = 0.62 + 0.38 * sin(_blink_t * 6.0)


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
	_show_toast(Lore.wave_toast(p_wave))
	refresh_stats()


func _on_enemy_killed(_p_enemy: Node2D) -> void:
	kills += 1
	refresh_stats()


func _on_state_changed(p_state: int) -> void:
	# 状态提示（LEVEL_UP/PAUSED/GAME_OVER 覆盖显示；PLAYING 隐藏）+ 状态切换刷新
	# （升级→LEVEL_UP 的 state_changed 晚于 xp_gained——等级数值在此同步）
	# 文本锚点保持 pkg4 断言原样；终端化只动颜色/闪烁
	match p_state:
		GameConst.GameStatus.LEVEL_UP:
			_state_label.text = "LEVEL UP - choose a card"
			_state_label.self_modulate = Palette.PHOS
			_state_label.visible = true
		GameConst.GameStatus.PAUSED:
			_state_label.text = "PAUSED"
			_state_label.self_modulate = Palette.AMBER
			_state_label.visible = true
		GameConst.GameStatus.GAME_OVER:
			_state_label.text = "GAME OVER"
			_state_label.self_modulate = Palette.HOT_RED
			_state_label.visible = true
		_:
			_state_label.visible = false
	refresh_stats()


func _on_damage_resolved(p_result: DamageResult) -> void:
	# 总伤害统计（结算屏数据源；HUD 不逐次刷新——1Hz 兜底承担）
	total_damage += p_result.final_value


func _build_summary() -> String:
	# 词条栏：武器数 + 武器词条数（构筑统计；终端行风格）
	if player == null or not is_instance_valid(player):
		return "MODULES W:0 T:0"
	var slots: Array = player.get("weapon_slots")
	var wcount := 0
	var tcount := 0
	for w in slots:
		if w != null and is_instance_valid(w):
			wcount += 1
			var stack: Variant = w.get("trait_stack")
			if stack != null and stack.get("traits") != null:
				tcount += (stack.get("traits") as Array).size()
	return "MODULES W:%d T:%d" % [wcount, tcount]


# ── 程序化 UI 组装（终端面板） ────────────────────────────────────
func _build_ui() -> void:
	# 顶部终端状态栏（竖屏信息区；TerminalTheme 等宽 + 磷光配色）
	var root := Control.new()
	root.name = "Root"
	root.theme = TerminalTheme.theme()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	var panel := ColorRect.new()
	panel.name = "TermPanel"
	panel.color = Color(Palette.BG.r, Palette.BG.g, Palette.BG.b, 0.82)
	panel.position = Vector2.ZERO
	panel.size = Vector2(720.0, 122.0)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(panel)
	var edge := ColorRect.new()
	edge.name = "TermPanelEdge"
	edge.color = Color(Palette.PHOS.r, Palette.PHOS.g, Palette.PHOS.b, 0.28)
	edge.position = Vector2(0.0, 121.0)
	edge.size = Vector2(720.0, 1.0)
	edge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(edge)

	_add_dim_label(root, Vector2(24.0, 12.0), Lore.HUD_HEADER, TerminalTheme.SIZE_MONSTER)

	var hp_bg := ColorRect.new()
	hp_bg.name = "HpBg"
	hp_bg.color = Color(Palette.TEXT_DIM.r, Palette.TEXT_DIM.g, Palette.TEXT_DIM.b, 0.25)
	hp_bg.position = Vector2(24.0, 30.0)
	hp_bg.size = HP_BAR_SIZE
	root.add_child(hp_bg)
	_hp_fill = ColorRect.new()
	_hp_fill.name = "HpFill"
	_hp_fill.color = Palette.PHOS
	_hp_fill.position = Vector2.ZERO
	_hp_fill.size = HP_BAR_SIZE
	hp_bg.add_child(_hp_fill)
	_hp_label = _add_label(root, Vector2(352.0, 26.0), "HP 100/100", TerminalTheme.SIZE_BODY)
	_hp_ascii_label = _add_label(root, Vector2(352.0, 44.0), "[■■■■■■■■]", TerminalTheme.SIZE_LOG)
	_hp_ascii_label.self_modulate = Palette.PHOS

	var xp_bg := ColorRect.new()
	xp_bg.name = "XpBg"
	xp_bg.color = Color(Palette.TEXT_DIM.r, Palette.TEXT_DIM.g, Palette.TEXT_DIM.b, 0.25)
	xp_bg.position = Vector2(24.0, 48.0)
	xp_bg.size = XP_BAR_SIZE
	root.add_child(xp_bg)
	_xp_fill = ColorRect.new()
	_xp_fill.name = "XpFill"
	_xp_fill.color = Palette.AMBER
	_xp_fill.size = Vector2.ZERO
	xp_bg.add_child(_xp_fill)
	_level_label = _add_label(root, Vector2(24.0, 60.0), "Lv 1", TerminalTheme.SIZE_LOG)

	_wave_label = _add_label(root, Vector2(24.0, 80.0), "WAVE 00", TerminalTheme.SIZE_BODY)
	_wave_label.self_modulate = Palette.PHOS
	_kill_label = _add_label(root, Vector2(150.0, 80.0), "KILL 0000", TerminalTheme.SIZE_BODY)
	_time_label = _add_label(root, Vector2(290.0, 80.0), "0:00", TerminalTheme.SIZE_BODY)
	_build_label = _add_dim_label(root, Vector2(24.0, 100.0), "MODULES W:0 T:0", TerminalTheme.SIZE_MONSTER)

	_state_label = _add_label(root, Vector2(0.0, 560.0), "", TerminalTheme.SIZE_SECTION + 2)
	_state_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_state_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_state_label.visible = false
	_toast_label = _add_label(root, Vector2(0.0, 212.0), "", TerminalTheme.SIZE_SECTION)
	_toast_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.self_modulate = Palette.AMBER
	_toast_label.visible = false
	refresh_stats()


func _show_toast(p_text: String) -> void:
	# 波次 toast（> 第 N 波 · 裂变密度 +Δ）：淡出由 tick 推进
	_toast_label.text = p_text
	_toast_label.modulate.a = 1.0
	_toast_label.visible = true
	_toast_left = TOAST_TIME


func _add_label(p_parent: Control, p_pos: Vector2, p_text: String, p_size: int) -> Label:
	# 程序化 Label（终端等宽字体）
	var label := Label.new()
	label.position = p_pos
	label.text = p_text
	label.add_theme_font_size_override("font_size", p_size)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p_parent.add_child(label)
	return label


func _add_dim_label(p_parent: Control, p_pos: Vector2, p_text: String, p_size: int) -> Label:
	# 弱化注脚行（终端暗绿）
	var label := _add_label(p_parent, p_pos, p_text, p_size)
	label.self_modulate = Palette.TEXT_DIM
	return label
