# scripts/ui/confetti.gd
# 方向 C「晴空糖果」签名瞬间：Boss 死亡 = 全屏彩纸屑爆发 + 「叮！」大跳字。
# 多色小矩形/圆（共享 TextureFactory 贴图，self_modulate 上色），简单抛体物理下落 1.5s
# 后清理本轮节点——宿主随 GameLoop 常驻，w10/w20/w30 每次 Boss 死亡均可再次爆发。
# 订阅 enemy_killed（连接序：GameLoop 在 spawner 入树前挂本节点——
# Boss tags 读取先于死亡归还清零，GameFeel.early_bind 同纪律）。
class_name ConfettiBurst
extends Node2D

const PIECE_COUNT := 64
const RAIN_COUNT := 26                       # 顶部全宽落雨枚数（全屏覆盖）
const LIFE_TIME := 1.5
const FADE_LAST := 0.35                       # 末段淡出
const GRAVITY := 920.0
const DRAG := 0.9                             # 空气阻尼（每秒保留比例）

var _pieces: Array[Dictionary] = []           # {node: Sprite2D, vel: Vector2, spin: float, left: float}
var _ding: Label = null
var _origin: Vector2 = Vector2.ZERO          # 本轮爆发爆点（Boss 死亡位置）
var _alive: bool = false


func _ready() -> void:
	z_index = 50                                 # 世界顶层（庆祝覆盖）
	EventBus.enemy_killed.connect(_on_enemy_killed)


func _on_enemy_killed(p_enemy: Node2D) -> void:
	# Boss 死亡 → 全屏彩纸屑（连接序在 spawner 之前，tags/位置读取安全）
	if p_enemy == null:
		return
	var tags_v: Variant = p_enemy.get("tags")
	var tags := int(tags_v) if tags_v != null else 0
	if (tags & GameConst.TAG_BOSS) == 0:
		return
	_celebrate(p_enemy.global_position)


func _celebrate(p_pos: Vector2) -> void:
	# 一次性爆发：彩纸 fountain（全扇面上抛）+ 顶部全宽落雨（「全屏」观感，与 Boss
	# 死亡位置无关）+「叮！」果冻跳字（上轮残留跳字先清）
	if _ding != null and is_instance_valid(_ding):
		_ding.queue_free()
	_ding = null
	_origin = p_pos
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var piece_count := PIECE_COUNT
	for i in range(piece_count):
		var sprite := _make_piece(rng)
		# 全扇面上抛（-180°~0°：左右铺开为主，少量近垂直——爆点上方也有效覆盖）
		var ang := deg_to_rad(rng.randf_range(-180.0, 0.0))
		var speed := rng.randf_range(320.0, 780.0)
		_pieces.append({
			"node": sprite,
			"vel": Vector2(cos(ang), sin(ang)) * speed,
			"spin": rng.randf_range(-9.0, 9.0),
			"left": LIFE_TIME * rng.randf_range(0.8, 1.0),
		})
	# 顶部全宽落雨（跨屏铺开、初速向下小——保证「全屏」覆盖观感）
	for i in range(RAIN_COUNT):
		var sprite := _make_piece(rng)
		sprite.position = Vector2(rng.randf_range(0.0, 720.0), rng.randf_range(-80.0, -10.0))
		_pieces.append({
			"node": sprite,
			"vel": Vector2(rng.randf_range(-60.0, 60.0), rng.randf_range(60.0, 200.0)),
			"spin": rng.randf_range(-9.0, 9.0),
			"left": LIFE_TIME * rng.randf_range(0.85, 1.0),
		})
	_spawn_ding(p_pos)
	_alive = true


func _make_piece(p_rng: RandomNumberGenerator) -> Sprite2D:
	# 单枚彩纸（共享贴图 + 多色 + 随机缩放/旋转；爆点 = Boss 位置）
	var sprite := Sprite2D.new()
	sprite.texture = TextureFactory.confetti_piece(p_rng.randi_range(0, 1))
	sprite.modulate = PopPalette.CONFETTI[p_rng.randi_range(0, PopPalette.CONFETTI.size() - 1)]
	sprite.position = _origin + Vector2(p_rng.randf_range(-14.0, 14.0), p_rng.randf_range(-10.0, 10.0))
	sprite.scale = Vector2.ONE * p_rng.randf_range(0.85, 1.5)
	sprite.rotation = p_rng.randf_range(0.0, TAU)
	add_child(sprite)
	return sprite


func _spawn_ding(p_pos: Vector2) -> void:
	# 「叮！」大跳字（柠檬金 + 藏青厚描边，果冻弹跳后上浮）
	_ding = Label.new()
	StickerTheme.label_sticker(_ding, 76, PopPalette.GOLD, 14, PopPalette.OUTLINE, true)
	_ding.text = Lore.BOSS_DING
	add_child(_ding)
	_ding.reset_size()
	var pos := p_pos - _ding.size * 0.5 - Vector2(0.0, 60.0)
	pos.x = clampf(pos.x, 20.0, 700.0 - _ding.size.x)   # 跳字不出屏
	pos.y = clampf(pos.y, 260.0, 1120.0)                # 避让 HUD 顶带与底部构筑条
	_ding.position = pos
	_ding.pivot_offset = _ding.size * 0.5
	_ding.scale = Vector2(0.2, 0.2)
	var tw := _ding.create_tween()
	tw.tween_property(_ding, "scale", Vector2(1.25, 0.9), 0.12) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(_ding, "scale", Vector2.ONE, 0.14)
	tw.tween_property(_ding, "position:y", _ding.position.y - 46.0, 0.9) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_callback(_ding.queue_free)   # 跳字演完自清（下次爆发新建）


func _process(p_delta: float) -> void:
	# 彩纸抛体推进（视觉层；到期清理本轮节点——宿主节点存活，Boss 可再次庆祝）
	if not _alive:
		return
	var all_done := true
	for piece: Dictionary in _pieces:
		var sprite: Sprite2D = piece["node"]
		if not is_instance_valid(sprite):
			continue
		var left: float = piece["left"] - p_delta
		piece["left"] = left
		if left <= 0.0:
			sprite.queue_free()
			continue
		all_done = false
		var vel: Vector2 = piece["vel"]
		vel.y += GRAVITY * p_delta
		vel *= pow(DRAG, p_delta)
		piece["vel"] = vel
		sprite.position += vel * p_delta
		sprite.rotation += float(piece["spin"]) * p_delta
		if left < FADE_LAST:
			sprite.modulate.a = clampf(left / FADE_LAST, 0.0, 1.0)
	if all_done:
		_pieces.clear()                     # 复位待发（w10/w20/w30 每次 Boss 死亡都爆发）
		_alive = false
