# scripts/entities/player/pickup.gd
# M-02 XpShard（架构 §1.4/§2.12）：经验碎片（Area2D，池化实体——XPPool 模板）。
# 掉落链路（集成包 B.1；AC-16.1）：Enemy 死亡 → GameLoop 掉落侧 spawn → 玩家磁吸半径内
# 自动飞向玩家（Q-13：120px + pickup_pct 词条加成经 Player.pickup_radius 读取）→
# 吸收距离内 gain_xp（升级仲裁 E-16 由 GameLoop 承担）→ 调用方归还池。
# 数值真源：掉落值 = Enemy.exp_value（波次通胀已在 Enemy.spawn 缩放）× 遗物点金手倍率
#（REL_MIDAS +20%，A3 §5——GameLoop 掉落侧折算，碎片值即最终入账值，数值守恒）。
# 满池合并（架构 §5.1 XPPool 行：合并为大面值碎片）：merge_value 由 GameLoop 调用。
#
# 拾取链路重做（用户实测反馈 2026-08-29 裁定：玩家活动区=下半屏，敌死掉落全屏分布，
# 上半屏碎片永远捡不到 → 四段行为）：
#   ① 出生弹跳散开（activate 期一次性水平散射 + 原地果冻弹跳表现）
#   ② 下漂：落定 1s 后缓慢下沉 80px/s（带左右轻摆），直到进入下半屏活动带（y>55% 屏高）
#   ③ 活动带内原地果冻 bob
#   ④ 超时 8s 未拾取：亮一下 → 全屏追踪玩家（加速飞、无视距离）——任何位置经验必可回收
# 磁吸口径不变：任意阶段进入 120px（Q-13）即转磁吸飞行（优先级最高）。
# 编排说明：tick(game_delta) 由 GameLoop 帧序②（玩家/拾取阶段）驱动——不自跑
# _physics_process（池 _prepare_for_pool 亦会关闭）；拾取判定用距离（拾取量少，免物理回调）。
class_name XpShard
extends Area2D

var value: float = 0.0                        # 面值（已含点金手倍率；gain_xp 直收入账）

var _magnet: bool = false                     # 已进入磁吸半径（加速飞向玩家）
var _sprite: Sprite2D = null
var _player_cache: Node2D = null

# 下漂/回归行为（用户裁定 2026-08-29；磁吸 120 与 MAGNET_SPEED 手感口径不变）
const PHASE_BURST := 0                        # 出生弹跳（0.25s 表现）
const PHASE_REST := 1                         # 落定等待（至 1.0s）
const PHASE_SINK := 2                         # 缓慢下沉（进入活动带为止）
const PHASE_BOB := 3                          # 活动带内果冻 bob
const BURST_TIME := 0.25                      # 出生弹跳时长 s
const REST_TIME := 1.0                        # 落定后等待时长 s（阶段②起点）
const SINK_SPEED := 80.0                      # 下沉速度 px/s
const SINK_BAND := 0.55                       # 下半屏活动带 y 阈值（屏高比例）
const SWAY_AMP := 26.0                        # 下沉左右摆幅度 px/s
const RETURN_TIME := 4.5                      # 超时回归阈值 s（8s 太久——大怪掉的大珠「不消失」观感，缩到 4.5s）
const HOMING_SPEED_INIT := 240.0              # 追踪初速 px/s
const HOMING_ACCEL := 620.0                   # 追踪加速度 px/s²
const HOMING_SPEED_MAX := 760.0               # 追踪速度上限 px/s
const HOMING_FLASH_TIME := 0.3                # 回归前亮一下时长 s
const ABSORB_DISTANCE := 24.0                 # 吸收判定距离 px（玩家 hitbox 16 + 碎片半径 ~6 + 余量）
const MAGNET_SPEED := 520.0                   # 磁吸飞行速度 px/s（A3 未给吸附速度——手感占位值）
const TEX_SIZE := 44                          # 星星贴图画布边长（TextureFactory 口径）

var _phase: int = PHASE_BURST                 # 行为阶段（见常量块）
var _age: float = 0.0                         # 存活时长 s（超时回归判据）
var _anim_t: float = 0.0                      # 表现时钟（bob/弹跳相位）
var _homing: bool = false                     # 超时全屏追踪态
var _homing_speed: float = HOMING_SPEED_INIT
var _homing_flash: float = 0.0                # 回归亮一下剩余
var _value_scale: float = 1.0                 # 面值缩放（bob 动画的乘算基准）


func _ready() -> void:
	# 池化实例化期组装渲染（代码组装为主；.tscn 仅做容器）
	_sprite = Sprite2D.new()
	_sprite.name = "Visual"
	_sprite.centered = true
	_sprite.texture = TextureFactory.star(TEX_SIZE, PopPalette.XP)
	add_child(_sprite)
	visible = false                            # 池内不可见（activate 后可见）


func activate(p_value: float) -> void:
	# 池取出后统一初始化（掉落侧：GameLoop._spawn_xp_shard 已设置 position）。
	# 出生散射在本函数一次性完成（落点即定——tick 期位置只按下沉/追踪推进，口径可测）
	value = maxf(p_value, 0.0)
	_magnet = false
	_player_cache = null
	_phase = PHASE_BURST
	_age = 0.0
	_anim_t = 0.0
	_homing = false
	_homing_speed = HOMING_SPEED_INIT
	_homing_flash = 0.0
	# 出生随机水平散射（±26px；纯表现散开，Y 不动——不改变掉落行分布）
	global_position.x = clampf(global_position.x + randf_range(-26.0, 26.0), 12.0, 708.0)
	visible = true
	_sync_visual()


func merge_value(p_extra: float) -> void:
	# 满池合并为大面值碎片（数值守恒，架构 §5.1；不重置磁吸/阶段态）
	value += maxf(p_extra, 0.0)
	_sync_visual()


func tick(p_game_delta: float) -> bool:
	# 磁吸/下漂/追踪推进；返回 true = 已吸收（调用方负责池归还）。无玩家引用 → 原地等待。
	if value <= 0.0:
		return true                            # 零面值碎片直接回收（防御）
	var player := _player()
	_age += p_game_delta
	_anim_t += p_game_delta
	_tick_visual_anim(p_game_delta)
	if player == null:
		return false
	var d := global_position.distance_to(player.global_position)
	# 磁吸优先（任意阶段；Q-13 半径口径不变）
	if not _magnet and d <= _pickup_radius(player):
		_magnet = true
	if _magnet:
		if d <= ABSORB_DISTANCE:
			player.gain_xp(value)              # 经验入账（升级仲裁 E-16 在 GameLoop）
			return true
		global_position = global_position.move_toward(player.global_position,
			MAGNET_SPEED * p_game_delta)
		return false
	# 超时回归（用户裁定：任何位置的经验最终都能捡到）：亮一下 → 全屏加速追踪
	if not _homing and _age >= RETURN_TIME:
		_homing = true
		_homing_flash = HOMING_FLASH_TIME
		_homing_speed = HOMING_SPEED_INIT
	if _homing:
		if _homing_flash > 0.0:
			_homing_flash = maxf(_homing_flash - p_game_delta, 0.0)
		_homing_speed = minf(_homing_speed + HOMING_ACCEL * p_game_delta, HOMING_SPEED_MAX)
		global_position = global_position.move_toward(player.global_position,
			_homing_speed * p_game_delta)
		if d <= ABSORB_DISTANCE:
			player.gain_xp(value)
			return true
		return false
	# ①→②→③：出生弹跳 → 落定 1s → 下沉至下半屏活动带 → 原地 bob
	match _phase:
		PHASE_BURST:
			if _age >= BURST_TIME:
				_phase = PHASE_REST
		PHASE_REST:
			if _age >= REST_TIME:
				_phase = PHASE_BOB if _in_sink_band() else PHASE_SINK
		PHASE_SINK:
			global_position.y += SINK_SPEED * p_game_delta
			global_position.x = clampf(
				global_position.x + sin(_age * 3.1) * SWAY_AMP * p_game_delta, 12.0, 708.0)
			if _in_sink_band():
				_phase = PHASE_BOB
		PHASE_BOB:
			pass                               # 原地果冻 bob（纯表现，_tick_visual_anim）
	return false


# ── 池归还清零契约（E-04/E-05） ───────────────────────────────────
func _reset_state() -> void:
	value = 0.0
	_magnet = false
	_player_cache = null
	_phase = PHASE_BURST
	_age = 0.0
	_anim_t = 0.0
	_homing = false
	_homing_speed = HOMING_SPEED_INIT
	_homing_flash = 0.0
	_value_scale = 1.0
	if _sprite != null:
		_sprite.modulate = Color.WHITE
		_sprite.scale = Vector2.ONE
		_sprite.position = Vector2.ZERO
		_sprite.rotation = 0.0


# ── 内部 ──────────────────────────────────────────────────────────
func _in_sink_band() -> bool:
	# 下半屏活动带判定（y > 55% 屏高；res 真源 GameConfig.balance.res_logic）
	var h := 1280.0
	if GameConfig.balance != null:
		h = float(GameConfig.balance.res_logic.y)
	return global_position.y > h * SINK_BAND


func _tick_visual_anim(_p_game_delta: float) -> void:
	# 纯表现（不触碰 global_position）：出生弹跳 / 下沉左右倾摆 / 果冻 bob / 回归亮起
	if _sprite == null:
		return
	var f := 1.0
	if _phase == PHASE_BURST:
		# 出生弹跳：1.35 → 1 弹性回落
		var bt := clampf(_age / BURST_TIME, 0.0, 1.0)
		f = 1.0 + 0.35 * (1.0 - bt) * cos(bt * PI * 2.2)
	elif _homing:
		if _homing_flash > 0.0:
			# 回归前亮一下：提亮 + 脉冲
			var ft := _homing_flash / HOMING_FLASH_TIME
			_sprite.modulate = Color(1.0 + 0.9 * ft, 1.0 + 0.9 * ft, 1.0 + 0.6 * ft, 1.0)
			f = 1.0 + 0.3 * ft
		else:
			_sprite.modulate = Color(1.15, 1.15, 1.0, 1.0)
			f = 1.0 + 0.08 * sin(_anim_t * 18.0)
	elif _phase == PHASE_SINK:
		# 下漂：轻微左右倾摆（旋转）+ 微 bob
		_sprite.rotation = sin(_anim_t * 3.1) * 0.14
		f = 1.0 + 0.05 * sin(_anim_t * 5.2)
	else:
		# 落定 bob：果冻呼吸（下漂/活动带内同享基调）
		_sprite.rotation = 0.0
		f = 1.0 + 0.09 * sin(_anim_t * 5.2)
	_sprite.scale = Vector2(_value_scale * f, _value_scale * (2.0 - f))


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
	# 柠檬星星：面值越大越醒目（0.9×~1.5× 等比；方向 C 口径）
	if _sprite == null:
		return
	_value_scale = 0.9 + clampf(value / 30.0, 0.0, 0.6)
	_sprite.scale = Vector2(_value_scale, _value_scale)
