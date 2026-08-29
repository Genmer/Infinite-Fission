# scripts/entities/player/pickup.gd
# M-02 XpShard（架构 §1.4/§2.12）：经验碎片（Area2D，池化实体——XPPool 模板）。
# 掉落链路（集成包 B.1；AC-16.1）：Enemy 死亡 → GameLoop 掉落侧 spawn → 玩家磁吸半径内
# 自动飞向玩家（Q-13：120px + pickup_pct 词条加成经 Player.pickup_radius 读取）→
# 吸收距离内 gain_xp（升级仲裁 E-16 由 GameLoop 承担）→ 调用方归还池。
# 数值真源：掉落值 = Enemy.exp_value（波次通胀已在 Enemy.spawn 缩放）× 遗物点金手倍率
#（REL_MIDAS +20%，A3 §5——GameLoop 掉落侧折算，碎片值即最终入账值，数值守恒）。
# 满池合并（架构 §5.1 XPPool 行：合并为大面值碎片）：merge_value 由 GameLoop 调用。
# 编排说明：tick(game_delta) 由 GameLoop 帧序②（玩家/拾取阶段）驱动——不自跑
# _physics_process（池 _prepare_for_pool 亦会关闭）；拾取判定用距离（拾取量少，免物理回调）。
class_name XpShard
extends Area2D

var value: float = 0.0                        # 面值（已含点金手倍率；gain_xp 直收入账）

var _magnet: bool = false                     # 已进入磁吸半径（加速飞向玩家）
var _sprite: Sprite2D = null
var _halo: Sprite2D = null                    # 底光晕（吸附光迹：磁吸时拉长指向玩家）
var _player_cache: Node2D = null

const ABSORB_DISTANCE := 24.0                 # 吸收判定距离 px（玩家 hitbox 16 + 碎片半径 ~6 + 余量）
const MAGNET_SPEED := 520.0                   # 磁吸飞行速度 px/s（A3 未给吸附速度——手感占位值）
const SHARD_COLOR := Palette.AMBER            # 琥珀（经验/稀有识别色——视觉单源）


func _ready() -> void:
	# 池化实例化期组装渲染（代码组装为主；.tscn 仅做容器）
	_halo = Sprite2D.new()
	_halo.name = "Halo"
	_halo.texture = TextureFactory.glow_dot()
	_halo.material = TextureFactory.mat_add()
	_halo.self_modulate = Color(SHARD_COLOR, 0.4)
	_halo.scale = Vector2.ONE * (44.0 / float(TextureFactory.GLOW_DOT_SIZE))
	add_child(_halo)
	_sprite = Sprite2D.new()
	_sprite.name = "Visual"
	_sprite.centered = true
	_sprite.texture = TextureFactory.diamond()
	_sprite.material = TextureFactory.mat_add()
	_sprite.self_modulate = SHARD_COLOR
	add_child(_sprite)
	visible = false                            # 池内不可见（activate 后可见）


func activate(p_value: float) -> void:
	# 池取出后统一初始化（掉落侧：GameLoop._spawn_xp_shard 已设置 position）
	value = maxf(p_value, 0.0)
	_magnet = false
	_player_cache = null
	visible = true
	_sync_visual()


func merge_value(p_extra: float) -> void:
	# 满池合并为大面值碎片（数值守恒，架构 §5.1；不重置磁吸态）
	value += maxf(p_extra, 0.0)
	_sync_visual()


func tick(p_game_delta: float) -> bool:
	# 磁吸推进；返回 true = 已吸收（调用方负责池归还）。无玩家引用 → 原地等待。
	if value <= 0.0:
		return true                            # 零面值碎片直接回收（防御）
	var player := _player()
	if player == null:
		return false
	var d := global_position.distance_to(player.global_position)
	if not _magnet:
		if d > _pickup_radius(player):
			return false
		_magnet = true
	if d <= ABSORB_DISTANCE:
		player.gain_xp(value)                  # 经验入账（升级仲裁 E-16 在 GameLoop）
		return true
	global_position = global_position.move_toward(player.global_position,
		MAGNET_SPEED * p_game_delta)
	_sync_streak(player.global_position)       # 吸附光迹（指向玩家的拉长光条）
	return false


# ── 池归还清零契约（E-04/E-05） ───────────────────────────────────
func _reset_state() -> void:
	value = 0.0
	_magnet = false
	_player_cache = null
	_sync_visual()


# ── 内部 ──────────────────────────────────────────────────────────
func _pickup_radius(p_player: Node2D) -> float:
	# 玩家磁吸半径（Q-13：120px；pickup_pct 词条加成在 Player.pickup_radius 落地）
	var r: Variant = p_player.get("pickup_radius")
	return float(r) if r != null else 120.0


func _player() -> Node2D:
	# 玩家引用缓存（组查找——与 Enemy/ProjectileBase 同口径）
	if _player_cache == null or not is_instance_valid(_player_cache):
		_player_cache = null
		var tree := get_tree()
		if tree != null:
			_player_cache = tree.get_first_node_in_group(&"player") as Node2D
	return _player_cache


func _sync_visual() -> void:
	# 面值越大越醒目（1.2×~1.6× 等比；琥珀菱形晶体）
	if _sprite == null:
		return
	var scale_f := 1.0 + clampf(value / 30.0, 0.0, 0.6)
	_sprite.scale = Vector2(scale_f, scale_f)
	_sprite.rotation = 0.0
	if _halo != null:
		_halo.scale = Vector2.ONE * ((36.0 + 20.0 * (scale_f - 1.0))
			/ float(TextureFactory.GLOW_DOT_SIZE))


func _sync_streak(p_target: Vector2) -> void:
	# 吸附光迹：磁吸飞行中晶体沿速度方向拉长（菱形纵轴对齐目标方向）
	if _sprite == null:
		return
	var dir := p_target - global_position
	if dir.length_squared() < 0.01:
		return
	_sprite.rotation = dir.angle() - PI / 2.0   # 菱形纵轴（本地 Y）对齐飞行方向
	_sprite.scale.y *= 1.9
