# scripts/ui/hud.gd
# M-16 HUD（架构 §2.15）：HP/经验/等级/波次/击杀/计时/金币 + 词条栏 + 波次横幅。
# 程序化占位美术（纯色 ColorRect + Label；正式美术后续迭代）。
# process_mode = ALWAYS（暂停/顿帧期间 UI 照常，Q-14）；刷新 = 事件驱动 + 1Hz 兜底
# （架构 refresh_stats 口径：计时兜底走 raw 通道 tick）。
# 数值源：Player（HP/经验/等级/词条栏）+ wave_started / enemy_killed / gold_changed 事件。
# v0.6.0 布局（720×1280 全量坐标表，A4 §7；layout_rects 断言两两不相交）：
#   HP 条 (24,16) 600×22（HP 文本条内左置 (34,18)）· Lv (634,14) · XP 条 (24,44) 560×12
#   （宽度从 600 缩到 560 给金币标签让位）· 金币 (596,40) · Wave/Kills/Time y=64 ·
#   Build (24,88)（上移修复与 BossBar y=118 重叠）· 波次横幅居中 y=430（2.0s 三段动画）。
# 全文本加描边（font_outline_color 0.9 黑 + outline_size 4，可读性）。
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
var _gold_label: Label = null                 # v0.6.0 金币标签（临时位；T2 全量重排定坐标）

var kills: int = 0
var wave: int = 0
var gold: int = 0                             # v0.6.0 金币余额显示值（gold_changed 驱动）
var run_elapsed: float = 0.0                  # 计时（raw 通道累计——含顿帧，观感口径）
var _fallback_timer: float = 0.0              # 1Hz 兜底刷新
var _banner_label: Label = null               # 波次横幅（居中，2.0s 三段动画）
var _banner_left: float = 0.0                 # 横幅剩余时长（raw 通道；>0 = 可见）

const HP_BAR_SIZE := Vector2(600.0, 22.0)
const XP_BAR_SIZE := Vector2(560.0, 12.0)     # v0.6.0：600→560（金币标签让位，A4 §7）
const BANNER_TIME := 2.0                      # 横幅总时长 s（raw 通道三段）
const BANNER_FADE := 0.25                     # 淡入/淡出段时长 s
const BANNER_Y := 430.0                       # 横幅驻留 y（PRESET_TOP_WIDE）
const BANNER_Y_START := 442.0                 # 淡入起点 y（442→430 上浮入场）
const OUTLINE_COLOR := Color(0.0, 0.0, 0.0, 0.9)   # 全文本描边色
const OUTLINE_SIZE := 4


func _ready() -> void:
	# ALWAYS：暂停/顿帧期间 UI 照常（Q-14）
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()


func bind_events() -> void:
	# 订阅 player_hit / xp_gained / gold_changed / wave_started / enemy_killed / state_changed / damage_resolved
	EventBus.player_hit.connect(_on_player_hit)
	EventBus.xp_gained.connect(_on_xp_gained)
	EventBus.gold_changed.connect(_on_gold_changed)
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
	# ①~⑧ 帧序 UI 阶段（raw 通道）：计时累计 + 横幅动画 + 1Hz 兜底刷新
	run_elapsed += p_raw_delta
	_tick_banner(p_raw_delta)
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


func displayed_gold() -> int:
	# v0.6.0 金币余额观测口（headless 断言用）
	return gold


func banner_visible() -> bool:
	# v0.6.0 波次横幅观测口（动画期 = true）
	return _banner_left > 0.0


func layout_rects() -> Array[Rect2]:
	# v0.6.0 顶部信息区占位矩形（布局契约断言口：两两 intersects()==false）。
	# HP 文本条内左置（嵌套于 HP 条矩形）不入列；状态提示/横幅为全屏覆盖层不入列。
	# 标签行高取设计口径（font_size + 8）：headless fallback 字体行高膨胀 ~3×（get_height
	# 48@size16），与坐标表前提（真实字体 ~1.4×）不符——布局契约按设计口径声明（A4 §7）。
	var out: Array[Rect2] = []
	out.append(Rect2(Vector2(24.0, 16.0), HP_BAR_SIZE))
	out.append(Rect2(Vector2(24.0, 44.0), XP_BAR_SIZE))
	out.append(_label_rect(_gold_label, 16))
	out.append(_label_rect(_level_label, 18))
	out.append(_label_rect(_wave_label, 16))
	out.append(_label_rect(_kill_label, 16))
	out.append(_label_rect(_time_label, 16))
	out.append(_label_rect(_build_label, 13))
	return out


func _label_rect(p_label: Label, p_font_size: int) -> Rect2:
	# 标签占位矩形：位置 + 实测文本宽（水平占位真源）× 设计行高（垂直契约，见 layout_rects 注）
	return Rect2(p_label.position,
		Vector2(p_label.get_minimum_size().x, float(p_font_size) + 8.0))


# ── v0.6.0 波次横幅（raw 通道 2.0s 三段：0~0.25 淡入上浮 / 0.25~1.75 保持 / 1.75~2.0 淡出） ──
func show_banner(p_text: String) -> void:
	_banner_label.text = p_text
	_banner_left = BANNER_TIME
	_banner_label.visible = true
	_banner_label.modulate.a = 0.0
	_banner_label.position.y = BANNER_Y_START


func _tick_banner(p_raw_delta: float) -> void:
	if _banner_left <= 0.0:
		return
	_banner_left -= p_raw_delta
	if _banner_left <= 0.0:
		_banner_left = 0.0
		_banner_label.visible = false
		return
	var t := BANNER_TIME - _banner_left        # 已进行时间 s
	if t < BANNER_FADE:
		var k := t / BANNER_FADE               # 段一：alpha 0→1 + y 442→430
		_banner_label.modulate.a = k
		_banner_label.position.y = lerpf(BANNER_Y_START, BANNER_Y, k)
	elif t <= BANNER_TIME - BANNER_FADE:
		_banner_label.modulate.a = 1.0         # 段二：保持
		_banner_label.position.y = BANNER_Y
	else:
		var k2 := (t - (BANNER_TIME - BANNER_FADE)) / BANNER_FADE   # 段三：alpha →0
		_banner_label.modulate.a = clampf(1.0 - k2, 0.0, 1.0)
		_banner_label.position.y = BANNER_Y


func _on_gold_changed(p_total: int) -> void:
	# 金币余额刷新（gold_changed 事件驱动；GameLoop._add_gold 唯一来源）
	gold = p_total
	_gold_label.text = "G %d" % gold


# ── 事件 ──────────────────────────────────────────────────────────
func _on_player_hit(_p_damage: float, _p_source_uid: int) -> void:
	refresh_stats()


func _on_xp_gained(_p_amount: float) -> void:
	refresh_stats()


func _on_wave_started(p_wave: int) -> void:
	wave = p_wave
	show_banner("WAVE %d" % p_wave)           # v0.6.0：波次横幅（2.0s 三段动画）
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


# ── 程序化 UI 组装（v0.6.0 720×1280 全量坐标表，见类头） ──────────
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
	hp_bg.position = Vector2(24.0, 16.0)
	hp_bg.size = HP_BAR_SIZE
	root.add_child(hp_bg)
	_hp_fill = ColorRect.new()
	_hp_fill.name = "HpFill"
	_hp_fill.color = Color(0.9, 0.3, 0.3)
	_hp_fill.position = Vector2.ZERO
	_hp_fill.size = HP_BAR_SIZE
	hp_bg.add_child(_hp_fill)
	_hp_label = _add_label(root, Vector2(34.0, 18.0), "HP 100/100", 14)   # 条内左置（嵌套不入 layout_rects）

	var xp_bg := ColorRect.new()
	xp_bg.name = "XpBg"
	xp_bg.color = Color(0.15, 0.16, 0.2, 0.9)
	xp_bg.position = Vector2(24.0, 44.0)
	xp_bg.size = XP_BAR_SIZE
	root.add_child(xp_bg)
	_xp_fill = ColorRect.new()
	_xp_fill.name = "XpFill"
	_xp_fill.color = Color(0.35, 0.8, 1.0)
	_xp_fill.size = Vector2.ZERO
	xp_bg.add_child(_xp_fill)

	_level_label = _add_label(root, Vector2(634.0, 14.0), "Lv 1", 18)
	_gold_label = _add_label(root, Vector2(596.0, 40.0), "G 0", 16)
	_gold_label.add_theme_color_override("font_color", Color(1.0, 0.83, 0.25))   # 金币识别色（A4 §7）
	_wave_label = _add_label(root, Vector2(24.0, 64.0), "Wave 0", 16)
	_kill_label = _add_label(root, Vector2(150.0, 64.0), "Kills 0", 16)
	_time_label = _add_label(root, Vector2(300.0, 64.0), "0:00", 16)
	_build_label = _add_label(root, Vector2(24.0, 88.0), "Build -", 13)   # 上移修复与 BossBar y=118 重叠
	_state_label = _add_label(root, Vector2(0.0, 560.0), "", 22)
	_state_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_state_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_state_label.visible = false
	# 波次横幅（居中 y=430；动画由 tick raw 通道驱动）
	_banner_label = _add_label(root, Vector2(0.0, BANNER_Y), "", 42)
	_banner_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_banner_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner_label.visible = false
	refresh_stats()


func _add_label(p_parent: Control, p_pos: Vector2, p_text: String, p_size: int) -> Label:
	# 程序化 Label（默认主题字体；全文本描边提升可读性——v0.6.0）
	var label := Label.new()
	label.position = p_pos
	label.text = p_text
	label.add_theme_font_size_override("font_size", p_size)
	label.add_theme_color_override("font_outline_color", OUTLINE_COLOR)
	label.add_theme_constant_override("outline_size", OUTLINE_SIZE)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p_parent.add_child(label)
	return label
