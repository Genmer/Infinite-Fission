# scripts/combat/projectile/ballistic_projectile.gd
# M-09 BallisticProjectile（架构 §2.7.2）：直线/穿透/反弹。
# 初速与散射已由武器侧算好入参（velocity 即最终初速）；射程过期走 range 快照或寿命兜底。
class_name BallisticProjectile
extends ProjectileBase

var acceleration: float = 0.0                 # 加特林变体可 >0；手枪/霰弹 = 0（匀速直线）
var range_left: float = 0.0                   # 射程快照（>0 启用超射程判定；≤0 仅寿命过期）
var _traveled: float = 0.0                    # 已飞行里程（射程判定）


func _read_form_params(p_params: Dictionary) -> void:
	# 形态参数：{accel（默认 0）, range（默认 0）}——可选键，缺省即匀速/无射程判定
	acceleration = float(p_params.get("accel", 0.0))
	range_left = maxf(float(p_params.get("range", 0.0)), 0.0)
	_traveled = 0.0


func _reset_form_state() -> void:
	acceleration = 0.0
	range_left = 0.0
	_traveled = 0.0


func _move(p_game_delta: float) -> void:
	# 匀速/加速直线 + 屏幕四边反射判定（bounces_left>0 时）+ 超射程过期
	if acceleration != 0.0:
		var dir := velocity.normalized()
		if dir != Vector2.ZERO:
			var spd := maxf(velocity.length() + acceleration * p_game_delta, 1.0)
			velocity = dir * spd
	global_position += velocity * p_game_delta
	_traveled += velocity.length() * p_game_delta
	if range_left > 0.0 and _traveled >= range_left:
		_recycle(GameConst.RecycleReason.EXPIRED)   # 超射程（range 快照）→ EXPIRED
		return
	_check_edge_bounce()
