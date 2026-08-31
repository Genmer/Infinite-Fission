# scripts/combat/weapon/laser_weapon.gd
# M-06 LaserWeapon（架构 §2.8.3，形态 B）：脉冲光束 W4 / 折射棱镜 W5 同构。
# · try_fire：cd 制维持主光束指向（目标策略：最近/最前）；主束常驻、每帧重定向。
# · _spawn_beam：深度 >2 拒绝 + chain_fused 计数（AC-04.3/B_spec 上限——W5 L5 数据
#   refract_depth=3 由引擎侧硬闸拒绝）；折射分叉二段伤害 = ratio²。
# · build_tick_context 每跳 ctx 在 LaserBeam._settle_one_tick 构造（灼焦 Local 池注入，F-15）。
# · 逐级形态参数（scorch_max_layers/refract_beams/refract_ratio/refract_depth）经
#   形态段 <key>_levels 新增键承载（AC-02.1 仅新增键，不改类）。
class_name LaserWeapon
extends WeaponBase

const MAX_REFRACT_DEPTH: int = 2               # 折射分叉深度硬上限（B_spec；AC-04.3）
const REFRACT_SEARCH_RADIUS := 250.0           # 折射寻的半径（§5.2-5）

var active_beams: Array[LaserBeam] = []        # 本武器存活光束段
var tick_accumulator: float = 0.0              # tick_rate 节拍（主束重定向缓存）
var _main_beam: LaserBeam = null


func setup(p_data: WeaponData, p_player: Node2D, p_deps: Dictionary) -> void:
	super(p_data, p_player, p_deps)
	active_beams.clear()
	tick_accumulator = 0.0
	_main_beam = null


func try_fire() -> bool:
	# 维持主光束（无目标也保持指向 UP——全自动开火持续）
	if laser_pool == null:
		return false
	if _main_beam == null or not is_instance_valid(_main_beam) or not _main_beam.is_live():
		var beam := _spawn_beam(muzzle_position(), aim_direction(), 0, 1.0, 0)
		if beam == null:
			return false                       # 池满：拒绝新光束段（AC-14.4）
		_main_beam = beam
	return true


func _on_tick_post(p_game_delta: float) -> void:
	# 主束重定向 + 存活光束推进（死亡段裁剪）
	if _main_beam != null and _main_beam.is_live():
		_main_beam.set_origin(muzzle_position())
		_main_beam.set_aim(aim_direction())
	for beam in active_beams.duplicate():
		if beam.is_live():
			beam.tick(p_game_delta)
		else:
			active_beams.erase(beam)


func _spawn_beam(p_origin: Vector2, p_dir: Vector2, p_depth: int, p_dmg_mult: float,
		p_target_uid: int, p_exclusions: Array[int] = []) -> LaserBeam:
	# 深度 >2 拒绝 + chain_fused 计数（AC-04.3）
	if p_depth > MAX_REFRACT_DEPTH:
		DebugStats.count(&"laser_refract_rejected")
		EventBus.emit_chain_fused(p_depth, &"laser_refract")
		return null
	var beam := laser_pool.acquire() as LaserBeam
	if beam == null:
		return null   # 池满拒绝
	if beam == null:
		return null
	beam.weapon = self
	beam.damage_pipeline = damage_pipeline
	beam.enemy_grid = enemy_grid
	beam.pool = laser_pool
	beam.spawn({
		"position": p_origin,
		"dir": p_dir,
		"depth": p_depth,
		"dmg_mult": p_dmg_mult,
		"tick_atk": get_current_atk(),
		"tick_rate": _leveled_param("tick_rate", get_stat(&"rof")),
		"beam_length": float(data.laser.get("beam_length", 560.0)),
		"beam_width": float(data.laser.get("beam_width", 14.0)),
		# 脉冲寿命 s（0=常驻——W5 折射棱镜口径不变；W4=0.5 数据键 pulse_duration，
		# 2026-08-31 P0 修复：commit 38b87f3 宣称脉冲制但 spawn 参数从未传递，实为常驻）
		"lifetime": _leveled_param("pulse_duration",
			float(data.laser.get("pulse_duration", 0.0))),
		"scorch_max_layers": int(_leveled_param("scorch_max_layers",
			float(data.laser.get("scorch_max_layers", 5)))),
		"scorch_per_layer": float(data.laser.get("scorch_per_layer", 0.08)),
		"refract_beams": int(_leveled_param("refract_beams",
			float(data.laser.get("refract_beams", 0)))),
		"refract_ratio": _leveled_param("refract_ratio",
			float(data.laser.get("refract_ratio", 0.6))),
		"refract_depth": int(_leveled_param("refract_depth",
			float(data.laser.get("refract_depth", 2)))),
		"panel_snapshot": build_panel_snapshot(),
		"trait_stack": trait_stack.copy_runtime() if trait_stack != null else null,
		"weapon_uid": uid,
		"weapon_ref": self,
		"target_uid": p_target_uid,
		"exclusions": p_exclusions,
		"team": 0,
	})
	active_beams.append(beam)
	return beam


func _on_beam_refracted(p_hit_pos: Vector2, p_parent: LaserBeam, p_count: int) -> void:
	# 命中带折射词条 → 分叉子光束：p_count 枚，向最近未命中目标（250px 内 ≠ 原目标，§5.2-5）
	# 排除集语义分离：子束继承「祖先链已命中集」快照（防回打祖先/已打过的目标），
	# 不含子束自己刚锁定的目标——否则子束首触锁定目标即被短路，深度 2 链不可达。
	if enemy_grid == null:
		return
	var exclusions := p_parent.hit_exclusions()
	var remaining := p_count
	while remaining > 0:
		var target := _nearest_unhit(p_hit_pos, exclusions)
		if target == null:
			break
		# 锁定目标只追加进寻的排除集（多分叉兄弟互斥）；子束携带追加前快照
		var child_exclusions: Array[int] = []
		child_exclusions.assign(exclusions)
		exclusions.append(int(target.get("uid")))
		var dir := ((target as Node2D).global_position - p_hit_pos).normalized()
		if dir == Vector2.ZERO:
			dir = Vector2.UP
		# 折射率乘区（二段 = ratio²：子束 dmg_mult = 父 × ratio）
		if _spawn_beam(p_hit_pos, dir, p_parent.depth + 1,
				p_parent.dmg_mult * p_parent.refract_ratio,
				int(target.get("uid")), child_exclusions) == null:
			break                             # 深度拒绝/池满：分叉终止
		remaining -= 1
		DebugStats.count(&"laser_refract_spawned")


func _nearest_unhit(p_pos: Vector2, p_exclusions: Array[int]) -> Node2D:
	# 最近未命中目标（排除集内目标；确定性距离升序）
	if enemy_grid == null:
		return null
	var candidates: Array[Node2D] = []
	candidates.append_array(enemy_grid.query_circle(p_pos, REFRACT_SEARCH_RADIUS))
	var best: Node2D = null
	var best_d := INF
	for cand in candidates:
		if bool(cand.get("dead")) or p_exclusions.has(int(cand.get("uid"))):
			continue
		var d := p_pos.distance_squared_to((cand as Node2D).global_position)
		if d < best_d:
			best_d = d
			best = cand
	return best


func _leveled_param(p_key: String, p_default: float) -> float:
	# 逐级形态参数（形态段新增键 <key>_levels: Array[float]——A3 §3.4/§3.5 逐级递进）
	var levels: Variant = data.laser.get(String(p_key) + "_levels", null)
	if levels is Array and level >= 1 and level <= (levels as Array).size():
		return float((levels as Array)[level - 1])
	return p_default
