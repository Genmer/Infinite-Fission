# scripts/ui/boss_bar.gd
# M-16 BossBar（架构 §1.4/§2.1 事件表）：Boss 血条——订阅 boss_spawned 登场 /
# enemy_killed（Boss 死亡）隐藏；每帧从 Boss 实例拉取 HP 比例。
# 方向 B 重设计：ALERT 闪烁边框 + 线框条 + 预警行「!! ALERT !! 高能聚合体接近 —— 波次代号」
#（代号单源 Lore.BOSS_CODENAMES；.tres display_name 不动，仍作条目名）。
# displayed_pct()/is_visible_bar() 观测口口径不变（pkg5 锁定）。process_mode = ALWAYS。
class_name BossBar
extends CanvasLayer

var boss: Node2D = null                       # 当前 Boss 引用（boss_spawned 注入）

var _root: Control = null
var _fill: ColorRect = null
var _name_label: Label = null
var _alert_label: Label = null                # 预警行（闪烁琥珀）
var _frame: Panel = null                      # 线框边框（ALERT 闪烁）
var _current_wave: int = 0                    # 波次代号解析（wave_started 跟踪）
var _t: float = 0.0                           # 闪烁时钟（raw 通道）

const BAR_SIZE := Vector2(560.0, 18.0)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	EventBus.boss_spawned.connect(_on_boss_spawned)
	EventBus.enemy_killed.connect(_on_enemy_killed)
	EventBus.state_changed.connect(_on_state_changed)
	EventBus.wave_started.connect(_on_wave_started)


func tick(p_raw_delta: float) -> void:
	# 每帧拉取 Boss HP 比例（⑧ UI 阶段，raw 通道）+ ALERT/边框闪烁
	if boss == null or not is_instance_valid(boss):
		return
	var max_hp: float = boss.get("max_hp")
	var hp: float = boss.get("hp")
	var pct := 0.0 if max_hp <= 0.0 else clampf(hp / max_hp, 0.0, 1.0)
	_fill.size = Vector2(BAR_SIZE.x * pct, BAR_SIZE.y)
	_t += p_raw_delta
	var blink := 0.55 + 0.45 * sin(_t * 10.0)
	_frame.modulate.a = blink
	_alert_label.modulate.a = 0.45 + 0.55 * blink


func displayed_pct() -> float:
	# 测试观测口
	if _fill == null or BAR_SIZE.x <= 0.0:
		return 0.0
	return _fill.size.x / BAR_SIZE.x


func is_visible_bar() -> bool:
	return _root.visible


func _on_boss_spawned(p_enemy: Node2D) -> void:
	# Boss 登场（HUD 血条/GameFeel——架构 §2.1 事件表）
	boss = p_enemy
	_name_label.text = str(p_enemy.get("data").get("display_name")) if p_enemy.get("data") != null else "BOSS"
	_alert_label.text = Lore.boss_alert(_current_wave)   # 波次代号（Lore 单源）
	_root.visible = true
	tick(0.0)


func _on_enemy_killed(p_enemy: Node2D) -> void:
	# Boss 死亡 → 隐藏
	if p_enemy == boss:
		boss = null
		_root.visible = false


func _on_state_changed(p_state: int) -> void:
	# 回 MENU/GAME_OVER 时收起（新一局由 boss_spawned 重新唤起）
	if p_state == GameConst.GameStatus.MENU or p_state == GameConst.GameStatus.GAME_OVER:
		boss = null
		_root.visible = false


func _on_wave_started(p_wave: int) -> void:
	# 波次代号跟踪（w10/w20/w30 → 质子洪流/重核壁垒/裂变之心）
	_current_wave = p_wave


func _build_ui() -> void:
	_root = Control.new()
	_root.name = "BossBarRoot"
	_root.theme = TerminalTheme.theme()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.visible = false
	add_child(_root)
	_alert_label = Label.new()
	_alert_label.name = "AlertLine"
	_alert_label.text = ""
	_alert_label.add_theme_font_size_override("font_size", TerminalTheme.SIZE_BODY)
	_alert_label.add_theme_color_override("font_color", Palette.AMBER)
	_alert_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_alert_label.position = Vector2(0.0, 124.0)
	_alert_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_alert_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_alert_label)
	var bg := ColorRect.new()
	bg.name = "BarBg"
	bg.color = Color(Palette.HOT_RED.r, Palette.HOT_RED.g, Palette.HOT_RED.b, 0.10)
	bg.position = Vector2(80.0, 166.0)
	bg.size = BAR_SIZE
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(bg)
	_fill = ColorRect.new()
	_fill.name = "BarFill"
	_fill.color = Palette.HOT_RED
	_fill.size = BAR_SIZE
	_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_child(_fill)
	_frame = Panel.new()
	_frame.name = "AlertFrame"
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0, 0, 0, 0)
	box.border_color = Palette.HOT_RED
	box.set_border_width_all(1)
	box.set_corner_radius_all(0)
	_frame.add_theme_stylebox_override("panel", box)
	_frame.position = Vector2(77.0, 163.0)
	_frame.size = BAR_SIZE + Vector2(6.0, 6.0)
	_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_frame)
	_name_label = Label.new()
	_name_label.position = Vector2(80.0, 146.0)
	_name_label.text = "BOSS"
	_name_label.add_theme_font_size_override("font_size", TerminalTheme.SIZE_LOG + 1)
	_name_label.add_theme_color_override("font_color", Palette.WHITE_HOT)
	_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_name_label)
