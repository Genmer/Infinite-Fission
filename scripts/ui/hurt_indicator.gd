# scripts/ui/hurt_indicator.gd
# F2 受击方向指示（self-evolution）：受击瞬间屏幕中带朝伤害来源方向泛红弧光——
# 玩家现在只有震屏没有方向感，被围时不知道该往哪滚。
# 方向源 = 最近的活敌（接触伤害来源必然贴身，最近敌方向 ≈ 伤害方向——零签名改动）。
# 单 Node2D 自绘（draw_arc 弧段），0.45s 淡出自清；战斗通道（PAUSABLE）。
class_name HurtIndicator
extends Node2D

const LIFE := 0.45                            # 弧光存活时长 s
const RADIUS := 150.0                         # 玩家周向弧半径 px
const ARC_SPAN := deg_to_rad(80.0)            # 弧段张开角（指向扇区）

var _t: float = LIFE
var _angle: float = 0.0                       # 伤害来源方向角（世界系）
var _active: bool = false


func _ready() -> void:
	visible = false
	z_index = 55                                # 世界顶层（BossBar 之下、弹幕之上）
	EventBus.player_hit.connect(_on_player_hit)


func _on_player_hit(_p_damage: float, _p_source_uid: int) -> void:
	# 方向解算：最近活敌（供弹等远程源不在 active 也兜底取最近——
	# 受击帧敌群重心方向对玩家仍有逃生意义）
	var tree := get_tree()
	var player := tree.get_first_node_in_group(&"player") as Node2D if tree != null else null
	if player == null:
		return
	var nearest_dir := Vector2.ZERO
	var nearest_d := INF
	var spawner: Node = tree.get_first_node_in_group(&"enemy_spawner")
	if spawner != null and spawner.get("active") != null:
		for e: Node2D in (spawner.get("active") as Array):
			if e == null or not is_instance_valid(e) or bool(e.get("dead")):
				continue
			var d := e.global_position.distance_to(player.global_position)
			if d < nearest_d:
				nearest_d = d
				nearest_dir = e.global_position - player.global_position
	if nearest_dir == Vector2.ZERO:
		return                                   # 场上无敌（异常路径：不乱指）
	_angle = nearest_dir.angle()
	_t = LIFE
	_active = true
	visible = true
	position = player.global_position
	queue_redraw()


func _process(p_delta: float) -> void:
	if not _active:
		return
	_t -= p_delta
	if _t <= 0.0:
		_active = false
		visible = false
		return
	queue_redraw()


func _draw() -> void:
	var k := clampf(_t / LIFE, 0.0, 1.0)
	var col := Color(1.0, 0.25, 0.22, 0.65 * k)  # 珊瑚红警示（§1.2 敌向语义）
	# 双弧：内亮弧（实指）+ 外宽晕弧（方向体感）
	draw_arc(Vector2.ZERO, RADIUS, _angle - ARC_SPAN * 0.5, _angle + ARC_SPAN * 0.5,
		18, col, 6.0, true)
	draw_arc(Vector2.ZERO, RADIUS + 14.0, _angle - ARC_SPAN * 0.32,
		_angle + ARC_SPAN * 0.32, 14, Color(col.r, col.g, col.b, 0.35 * k), 14.0, true)
