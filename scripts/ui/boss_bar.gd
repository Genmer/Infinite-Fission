# scripts/ui/boss_bar.gd
# M-16 BossBar（架构 §1.4/§2.1 事件表）：Boss 血条——订阅 boss_spawned 登场 /
# enemy_killed（Boss 死亡）隐藏；每帧从 Boss 实例拉取 HP 比例。
# 程序化占位美术（纯色条；正式美术后续迭代）。process_mode = ALWAYS（暂停期间可见）。
class_name BossBar
extends CanvasLayer

var boss: Node2D = null                       # 当前 Boss 引用（boss_spawned 注入）

var _root: Control = null
var _fill: ColorRect = null
var _name_label: Label = null

const BAR_SIZE := Vector2(560.0, 18.0)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	EventBus.boss_spawned.connect(_on_boss_spawned)
	EventBus.enemy_killed.connect(_on_enemy_killed)
	EventBus.state_changed.connect(_on_state_changed)


func tick(_p_raw_delta: float) -> void:
	# 每帧拉取 Boss HP 比例（⑧ UI 阶段，raw 通道）
	if boss == null or not is_instance_valid(boss):
		return
	var max_hp: float = boss.get("max_hp")
	var hp: float = boss.get("hp")
	var pct := 0.0 if max_hp <= 0.0 else clampf(hp / max_hp, 0.0, 1.0)
	_fill.size = Vector2(BAR_SIZE.x * pct, BAR_SIZE.y)


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


func _build_ui() -> void:
	_root = Control.new()
	_root.name = "BossBarRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.visible = false
	add_child(_root)
	var bg := ColorRect.new()
	bg.color = Color(0.12, 0.1, 0.12, 0.92)
	bg.position = Vector2(80.0, 140.0)
	bg.size = BAR_SIZE
	_root.add_child(bg)
	_fill = ColorRect.new()
	_fill.color = Color(0.9, 0.25, 0.3)
	_fill.size = BAR_SIZE
	bg.add_child(_fill)
	_name_label = Label.new()
	_name_label.position = Vector2(80.0, 118.0)
	_name_label.text = "BOSS"
	_name_label.add_theme_font_size_override("font_size", 14)
	_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_name_label)
