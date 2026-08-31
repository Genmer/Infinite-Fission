# scripts/entities/player/gold_coin.gd
# v0.6.0 GoldCoin（A4 §3）：金币实体（Area2D，池化实体——GoldPool 模板，镜像 pickup.gd）。
# 掉落链路：Enemy 死亡 → GameLoop 掉落侧 spawn（roll data.gold_drop + 金币词条加成，
# A4 §3 公式）→ 玩家磁吸半径内自动飞向玩家（520px/s，吸收 24px，同 XpShard 口径）→
# tick 返回 true = 已吸收。★ 吸收不直接入账——入账由 GameLoop 承担
#（_add_gold → EventBus.emit_gold_changed，与 XpShard 的 gain_xp 内嵌口径解耦）。
# 满池合并（数值守恒）：merge_value 由 GameLoop 调用，不重置磁吸态（同 XpShard 口径）。
# 编排说明：tick(game_delta) 由 GameLoop 帧序②（玩家/拾取阶段）驱动——不自跑
# _physics_process（池 _prepare_for_pool 亦会关闭）；拾取判定用距离（免物理回调）。
class_name GoldCoin
extends Area2D

var value: int = 0                            # 面值（已含词条加成；入账由 GameLoop 承担）

var _magnet: bool = false                     # 已进入磁吸半径（加速飞向玩家）
var _sprite: Sprite2D = null
var _player_cache: Node2D = null

const ABSORB_DISTANCE := 24.0                 # 吸收判定距离 px（与 XpShard 同口径）
const MAGNET_SPEED := 520.0                   # 磁吸飞行速度 px/s（与 XpShard 同口径）
const TEX_SIZE := 12                          # 占位金币纹理边长
static var _shared_texture: ImageTexture = null
const COIN_COLOR := Color(1.0, 0.78, 0.15)    # 亮金占位（金币识别色）


func _ready() -> void:
	# 池化实例化期组装占位渲染（代码组装为主；.tscn 仅做容器）
	_sprite = Sprite2D.new()
	_sprite.name = "Visual"
	_sprite.centered = true
	_sprite.texture = _get_placeholder_texture()
	_sprite.self_modulate = COIN_COLOR
	add_child(_sprite)
	visible = false                            # 池内不可见（activate 后可见）


func activate(p_value: int) -> void:
	# 池取出后统一初始化（掉落侧：GameLoop._spawn_gold_coin 已设置 position）
	value = maxi(p_value, 0)
	_magnet = false
	_player_cache = null
	visible = true
	_sync_visual()


func merge_value(p_extra: int) -> void:
	# 满池合并为大面值金币（数值守恒，A4 §3；不重置磁吸态）
	value += maxi(p_extra, 0)
	_sync_visual()


func tick(p_game_delta: float) -> bool:
	# 磁吸推进；返回 true = 已吸收（调用方负责入账 + 池归还）。无玩家引用 → 原地等待。
	if value <= 0:
		return true                            # 零面值金币直接回收（防御）
	var player := _player()
	if player == null:
		return false
	var d := global_position.distance_to(player.global_position)
	if not _magnet:
		if d > _pickup_radius(player):
			return false
		_magnet = true
	if d <= ABSORB_DISTANCE:
		return true                            # 已吸收（入账在 GameLoop._tick_gold_coins）
	global_position = global_position.move_toward(player.global_position,
		MAGNET_SPEED * p_game_delta)
	return false


# ── 池归还清零契约（E-04/E-05） ───────────────────────────────────
func _reset_state() -> void:
	value = 0
	_magnet = false
	_player_cache = null


# ── 内部 ──────────────────────────────────────────────────────────
func _pickup_radius(p_player: Node2D) -> float:
	# 玩家磁吸半径（Q-13：120px；pickup_pct 词条加成在 Player.pickup_radius 落地）
	var r: Variant = p_player.get("pickup_radius")
	return float(r) if r != null else 120.0


func _player() -> Node2D:
	# 玩家引用缓存（组查找——与 XpShard/Enemy/ProjectileBase 同口径）
	if _player_cache == null or not is_instance_valid(_player_cache):
		_player_cache = null
		var tree := get_tree()
		if tree != null:
			_player_cache = tree.get_first_node_in_group(&"player") as Node2D
	return _player_cache


func _sync_visual() -> void:
	# 面值越大越醒目（1.2×~1.6× 等比；程序化占位表现）
	if _sprite == null:
		return
	var scale_f := 1.2 + clampf(float(value) / 120.0, 0.0, 0.4)
	_sprite.scale = Vector2(scale_f, scale_f)


static func _get_placeholder_texture() -> ImageTexture:
	# 共享静态占位圆形纹理（程序化生成；美术后续替换——仿 pickup.gd 静态共享口径）
	if _shared_texture == null:
		var img := Image.create(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8)
		var c := float(TEX_SIZE) * 0.5 - 0.5
		for y in range(TEX_SIZE):
			for x in range(TEX_SIZE):
				var dx := float(x) - c
				var dy := float(y) - c
				if dx * dx + dy * dy <= c * c:
					img.set_pixel(x, y, Color.WHITE)
		_shared_texture = ImageTexture.create_from_image(img)
	return _shared_texture
