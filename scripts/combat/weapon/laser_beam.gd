# scripts/combat/weapon/laser_beam.gd
# M-06 LaserBeam（架构 §2.8.3）：光束段实体——不是 M-09 投射物（B_spec M-06），
# 独立实体但共享 M-10 词条（运行时栈）与 M-12 结算。
# · 首敌命中：沿射线方向的网格查询（Q-15 同源：物理 RayCast 语义经 SpaceGrid 实现，
#   规避 Area2D 层配置脆弱性）；持续照射叠「灼焦」≤scorch_max_layers（1 层/0.25s）。
# · 节拍结算：tick_rate 跳/s；每跳 ctx 注入 Local 私有池（灼焦 ×8%/层，F-15——
#   不入全局乘区名额、自有 cap_local）+ 词条乘区（collect_mult_pools 条件自评）。
# · 跳字节流：popup_throttle ≤15Hz/目标（AC-04.2——包 4 跳字管理器消费同一闸门）。
# · 折射：命中新目标 → weapon._on_beam_refracted 分叉子光束（深度 ≤2 引擎侧拒绝）。
class_name LaserBeam
extends Node2D

const SCORCH_LAYER_INTERVAL := 0.25            # 叠层节拍（1 层/0.25s，架构 §2.8.3）
const POPUP_HZ := 15.0                         # 跳字节流上限（AC-04.2）

var uid: int = 0
var depth: int = 0                             # 0=主光束；折射分叉深度上限 2
var dmg_mult: float = 1.0                      # 折射率乘区（二段 = ratio²）
var team: int = 0
var tick_atk: float = 6.0                      # 每跳基础 ATK（L 表 tick_atk × dmg_mult）
var tick_rate: float = 8.0                     # 跳/s
var beam_length: float = 560.0
var beam_width: float = 14.0
var scorch_max_layers: int = 5                 # ≤8（schema 上限；W4 L5 = 8）
var scorch_per_layer: float = 0.08             # 每层 +8%（本光束自身乘算）
var refract_beams: int = 0
var refract_ratio: float = 0.6
var refract_depth: int = 2
var scorch_layers: Dictionary = {}             # target_uid -> 灼焦层数（≤scorch_max_layers）
var popup_throttle: Dictionary = {}            # target_uid -> 跳字下次可发时刻（束内时间轴）
var popup_count: int = 0                       # 跳字放行计数（节流验证口径）
var settle_count: int = 0                      # 总结算跳数
var weapon: LaserWeapon = null                 # 宿主武器（折射调度/词条消费）
var damage_pipeline: RefCounted = null
var enemy_grid: SpaceGrid = null
var pool: ObjectPool = null                    # 归属池（LaserBeamPool）
var trait_stack: TraitStack = null             # 武器运行时栈副本（共享 M-10）
var panel_snapshot: Dictionary = {}
var weapon_uid: int = 0
var target_uid: int = 0                        # 折射子束锁定目标（0 = 主束自由瞄准）

var _aim_dir: Vector2 = Vector2.UP            # 主束指向（武器每帧刷新）
var _tick_left: float = 0.0
var _scorch_accum: Dictionary = {}             # target_uid -> 叠层计时累计
var _hit_exclusions: Dictionary = {}           # target_uid -> true（折射去重：已命中目标）
var _time_alive: float = 0.0
var _live: bool = false
var _line: Line2D = null


func _ready() -> void:
	# 池化实例化期组装渲染（代码组装为主，.tscn 仅做容器，§1.4）
	_line = Line2D.new()
	_line.name = "BeamLine"
	_line.width = beam_width
	_line.default_color = Color(0.4, 0.9, 1.0, 0.75)
	add_child(_line)
	visible = false


func spawn(p_params: Dictionary) -> void:
	# 池取出初始化（origin/depth/dmg_mult/武器快照；契约见 LaserWeapon._spawn_beam）
	uid = GameConst.next_uid()
	depth = int(p_params.get("depth", 0))
	dmg_mult = maxf(float(p_params.get("dmg_mult", 1.0)), 0.0)
	team = int(p_params.get("team", 0))
	tick_atk = maxf(float(p_params.get("tick_atk", 6.0)), 0.0)
	tick_rate = maxf(float(p_params.get("tick_rate", 8.0)), 0.1)
	beam_length = maxf(float(p_params.get("beam_length", 560.0)), 1.0)
	beam_width = maxf(float(p_params.get("beam_width", 14.0)), 1.0)
	scorch_max_layers = clampi(int(p_params.get("scorch_max_layers", 5)), 1, 8)
	scorch_per_layer = float(p_params.get("scorch_per_layer", 0.08))
	refract_beams = int(p_params.get("refract_beams", 0))
	refract_ratio = float(p_params.get("refract_ratio", 0.6))
	refract_depth = int(p_params.get("refract_depth", 2))
	target_uid = int(p_params.get("target_uid", 0))
	weapon_uid = int(p_params.get("weapon_uid", 0))
	var snap: Variant = p_params.get("panel_snapshot", {})
	panel_snapshot = snap if typeof(snap) == TYPE_DICTIONARY else {}
	trait_stack = p_params.get("trait_stack", null) as TraitStack
	_aim_dir = p_params.get("dir", Vector2.UP)
	if _aim_dir == Vector2.ZERO:
		_aim_dir = Vector2.UP
	if p_params.has("position"):
		position = p_params["position"]
	scorch_layers.clear()
	popup_throttle.clear()
	_scorch_accum.clear()
	_hit_exclusions.clear()
	var exclusions: Variant = p_params.get("exclusions", [])
	if exclusions is Array:
		for uid_v in exclusions:
			_hit_exclusions[int(uid_v)] = true
	_tick_left = 1.0 / tick_rate
	_time_alive = 0.0
	popup_count = 0
	settle_count = 0
	_live = true
	visible = true
	if _line != null:
		_line.width = beam_width
	_dispatch_event(GameConst.TraitEvent.ON_SPAWN)


func tick(p_game_delta: float) -> void:
	# 朝向解析 → 首敌命中 → 灼焦叠层管理 → 节拍结算 → 渲染同步
	if not _live:
		return
	_time_alive += p_game_delta
	var dir := _resolve_aim()
	var hit := _first_hit(dir)
	var end_pos := global_position + dir * beam_length
	if hit != null:
		end_pos = (hit as Node2D).global_position
		_on_hit_target(hit, p_game_delta)
	_sync_line(end_pos)
	_tick_settle(hit, p_game_delta)


func set_aim(p_dir: Vector2) -> void:
	# 主束指向（武器每帧刷新——目标策略：最近/最前）
	if p_dir != Vector2.ZERO:
		_aim_dir = p_dir.normalized()


func is_live() -> bool:
	return _live


func hit_exclusions() -> Array[int]:
	# 已命中目标 uid 集（折射寻的排除集——子束继承）
	var out: Array[int] = []
	for key in _hit_exclusions:
		out.append(int(key))
	return out


func request_refract(p_count: int) -> void:
	# 分叉请求（深度 >refract_depth 拒绝并计数，AC-04.3；武器 _spawn_beam 同样硬闸 ≤2）
	if depth + 1 > refract_depth:
		DebugStats.count(&"laser_refract_rejected")
		EventBus.emit_chain_fused(depth + 1, &"laser_refract")
		return
	weapon._on_beam_refracted(global_position, self, p_count)


func _recycle() -> void:
	# 统一收束：OnExpire 派发 → 状态清零 → 池归还（E-04 顺序）
	if not _live:
		return
	_live = false
	DebugStats.count(&"laser_beam_recycled")
	_dispatch_event(GameConst.TraitEvent.ON_EXPIRE)
	_reset_state()
	if pool != null:
		pool.release(self)


func _reset_state() -> void:
	# 归还清零契约（E-04/E-05：层数表/节流表/词条/订阅/计时）
	depth = 0
	dmg_mult = 1.0
	tick_atk = 6.0
	tick_rate = 8.0
	beam_length = 560.0
	beam_width = 14.0
	scorch_max_layers = 5
	scorch_per_layer = 0.08
	refract_beams = 0
	refract_ratio = 0.6
	refract_depth = 2
	target_uid = 0
	weapon_uid = 0
	trait_stack = null
	panel_snapshot = {}
	scorch_layers.clear()
	popup_throttle.clear()
	_scorch_accum.clear()
	_hit_exclusions.clear()
	_tick_left = 0.0
	_time_alive = 0.0
	_aim_dir = Vector2.UP
	weapon = null
	damage_pipeline = null
	enemy_grid = null
	pool = null
	if _line != null:
		_line.clear_points()


# ── 内部 ──────────────────────────────────────────────────────────
func _resolve_aim() -> Vector2:
	# 朝向：折射子束锁定目标（死亡 → 回收）/ 主束 = 武器刷新指向
	if target_uid != 0:
		var target := _find_target()
		if target == null:
			_recycle()
			return _aim_dir
		var dir := ((target as Node2D).global_position - global_position).normalized()
		if dir != Vector2.ZERO:
			_aim_dir = dir
	return _aim_dir


func _find_target() -> Node2D:
	# target_uid 解析（网格全域扫描；死亡/失踪 → null → 回收）
	if enemy_grid == null:
		return null
	var candidates: Array[Node2D] = []
	candidates.append_array(enemy_grid.query_circle(global_position, beam_length * 2.0))
	for cand in candidates:
		if int(cand.get("uid")) == target_uid:
			if bool(cand.get("dead")):
				return null
			return cand
	return null


func _first_hit(p_dir: Vector2) -> Node2D:
	# 首敌命中：射线段内垂直距离 ≤ beam_width/2 + 目标半径 的最近者（Q-15 网格实现）
	if enemy_grid == null:
		return null
	var candidates: Array[Node2D] = []
	candidates.append_array(enemy_grid.query_circle(global_position, beam_length))
	var best: Node2D = null
	var best_t := INF
	var half_w := beam_width * 0.5
	for cand in candidates:
		if bool(cand.get("dead")):
			continue
		var rel := (cand as Node2D).global_position - global_position
		var t := rel.dot(p_dir)
		if t < 0.0 or t > beam_length:
			continue
		var perp := (rel - p_dir * t).length()
		var reach := half_w + float(cand.get("hitbox_r"))
		if perp <= reach and t < best_t:
			best_t = t
			best = cand
	return best


func _on_hit_target(p_target: Node2D, p_game_delta: float) -> void:
	# 叠层 +1（1 层/0.25s，上限 scorch_max_layers）→ 折射调度（新目标）
	var target_uid := int(p_target.get("uid"))
	if not _hit_exclusions.has(target_uid):
		_hit_exclusions[target_uid] = true
		if refract_beams > 0 and weapon != null:
			request_refract(refract_beams)
	_scorch_accum[target_uid] = float(_scorch_accum.get(target_uid, 0.0)) + p_game_delta
	var layers := int(scorch_layers.get(target_uid, 0))
	while float(_scorch_accum[target_uid]) >= SCORCH_LAYER_INTERVAL \
			and layers < scorch_max_layers:
		layers += 1
		_scorch_accum[target_uid] = float(_scorch_accum[target_uid]) - SCORCH_LAYER_INTERVAL
	scorch_layers[target_uid] = layers


func _tick_settle(p_hit: Node2D, p_game_delta: float) -> void:
	# 节拍结算（tick_rate 跳/s；HIT 通道——灼焦 Local 池 + 词条乘区 + 暴击每跳独立）
	_tick_left -= p_game_delta
	while _tick_left <= 0.0 and p_hit != null and _live:
		_tick_left += 1.0 / tick_rate
		_settle_one_tick(p_hit)
	if _tick_left < 0.0:
		_tick_left = 0.0


func _settle_one_tick(p_hit: Node2D) -> void:
	if damage_pipeline == null:
		return
	var ctx := DamageContext.make()
	ctx.source_uid = uid
	ctx.target = p_hit
	ctx.target_uid = int(p_hit.get("uid"))
	ctx.frame_stamp = GameConfig.frame_stamp
	ctx.base_atk = tick_atk * dmg_mult
	ctx.flat_bonus = float(panel_snapshot.get("flat_bonus", 0.0))
	ctx.crit_chance = float(panel_snapshot.get("crit_rate", 0.0))
	ctx.crit_mult = float(panel_snapshot.get("crit_mult", 2.0))
	var entries: Variant = panel_snapshot.get("add_entries", [])
	if entries is Array:
		for entry in entries:
			ctx.add_entries.append(entry)
	ctx.element = GameConst.Element.KIN
	ctx.pos = (p_hit as Node2D).global_position
	# F-15 灼焦 Local 私有池（∏ L_l：不入名额、不受 cap_prod、自有 cap_local）
	var layers := int(scorch_layers.get(ctx.target_uid, 0))
	if layers > 0:
		ctx.local_pools.append({
			"local_id": &"scorch",
			"contrib": float(layers) * scorch_per_layer,
			"cap_local": float(scorch_max_layers) * scorch_per_layer,
		})
	# 词条乘区预聚合（§4.4 ②：光束路径条件自评）+ 目标易伤乘区 + ELE 附着请求
	var tctx := TraitContext.new()
	tctx.event = GameConst.TraitEvent.ON_HIT
	tctx.beam = self
	tctx.weapon = weapon
	tctx.target = ctx.target
	tctx.damage_ctx = ctx
	if trait_stack != null:
		for pool in trait_stack.collect_mult_pools(tctx):
			ctx.mult_pools.append(pool)
	if weapon != null:
		weapon.inject_vuln_pool(ctx, ctx.target)
	if trait_stack != null:
		trait_stack.dispatch(GameConst.TraitEvent.ON_HIT, tctx)
	if not tctx.attach_request.is_empty() and weapon != null and weapon.elemental != null:
		# ELE 词条附着请求（引擎结算后提交——光束路径快照取面板基数）
		var request: Dictionary = tctx.attach_request
		weapon.elemental.apply_attach(ctx.target, int(request["element"]),
			float(request["value"]), {
				"snapshot": ctx.base_atk,
				"hit_damage": 0.0,
				"overrides": request.get("overrides", {}),
			})
	var result: DamageResult = damage_pipeline.call(&"resolve", ctx)
	settle_count += 1
	if result != null:
		if popup_due(ctx.target_uid):
			popup_count += 1
		if ctx.target.has_method(&"take_result"):
			ctx.target.call(&"take_result", result)


func popup_due(p_uid: int) -> bool:
	# 跳字节流闸门：≤15Hz/目标（AC-04.2；包 4 PopupManager 消费同口径）
	var next := float(popup_throttle.get(p_uid, 0.0))
	if _time_alive >= next:
		popup_throttle[p_uid] = _time_alive + 1.0 / POPUP_HZ
		return true
	return false


func _sync_line(p_end: Vector2) -> void:
	# 线段渲染（局部坐标：起点原点）
	if _line == null:
		return
	_line.clear_points()
	_line.add_point(Vector2.ZERO)
	_line.add_point(to_local(p_end))


func _dispatch_event(p_event: int) -> void:
	# 词条事件派发（M-10 链式深度/重入护栏在 TraitStack.dispatch）
	if trait_stack == null:
		return
	var tctx := TraitContext.new()
	tctx.event = p_event
	tctx.beam = self
	tctx.weapon = weapon
	trait_stack.dispatch(p_event, tctx)
