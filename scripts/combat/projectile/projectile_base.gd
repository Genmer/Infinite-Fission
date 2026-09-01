# scripts/combat/projectile/projectile_base.gd
# M-09 ProjectileBase（架构 §2.7.1）：投射物系统抽象基类。
# Q-15：弹-敌碰撞走 SpaceGrid 自管查询——不用 Area2D 回调，故基类为 Node2D（Sprite2D 子节点渲染）。
# 契约：
#   ① 六大生命周期事件唯一派发点（OnSpawn/OnTick/OnHit/OnPierce/OnBounce/OnExpire），
#      派发顺序 = 词条挂载顺序（确定性，B_spec M-09）；
#   ② 回收五路径统一收束 _recycle（EXPIRED/PIERCE_DEPLETED/BOUNCE_DEPLETED/NULLIFIED/FORCED）：
#      OnExpire 派发 → 状态清零 → 池归还（E-04 顺序断言）；
#   ③ 同帧同目标去重（E-03 帧聚合：hits_this_frame，一帧一目标一条）。
# 编排说明（§2.17）：本实体只做自身运动/碰撞/结算提交；tick(game_delta) 由 GameLoop 固定帧序驱动。
class_name ProjectileBase
extends Node2D

var uid: int = 0                              # GameConst.next_uid()
var team: int = 0                             # 0=玩家弹 1=敌方弹（消弹/命中判定分流）
var velocity: Vector2 = Vector2.ZERO
var lifetime_left: float = 0.0                # 寿命（超程/超时 → EXPIRED）
var pierce_left: int = 0                      # 穿透计数器（剩余可命中目标数）
var bounces_left: int = 0                     # 反弹计数器
var generation: int = 0                       # 分裂代数（≤3，E-01）
var hitbox_radius: float = 6.0
var element: int = GameConst.Element.KIN
var attach_value: float = 0.0                 # 元素附着负载（命中时提交 ElementalSystem）
var size_mult: float = 1.0                    # 体积极限累计（碰撞盒/精灵等比）
var weapon_uid: int = 0                       # 来源武器（面板快照归属）
var weapon_ref: WeaponBase = null             # 来源武器引用（spawn 参数字典可选键——词条效果引擎侧结算通道，池化复位清零防陈旧引用）
var panel_snapshot: Dictionary = {}           # 武器面板快照 {base_atk, crit_rate, crit_mult, flat_bonus, add_entries[]}
# 包 3 收口：真件 TraitStack 替换鸭子接口（spawn 参数字典契约不变；引用类型收紧）
var trait_stack: TraitStack = null            # 本弹词条宿主（M-10 运行时栈副本）
var damage_pipeline: RefCounted = null        # 注入（结算入口；DamagePipelineStub 或包 1 真件）
var hits_this_frame: Dictionary = {}          # target_uid -> true（帧聚合，E-03）
var enemy_grid: SpaceGrid = null              # 注入（碰撞查询）
var pool: ProjectilePool = null               # 注入（回收归属）
# 包 3 收口：ElementalSystem 真件类型收紧（§4.4 ⑤ 附着通道）
var elemental: ElementalSystem = null         # 注入（元素附着入口）
# 包 3 收口：击杀证据（MEC_KILL_BLAST 死亡新星的 ON_EXPIRE 期判定输入）
var killed_target: bool = false               # 本弹存活期曾击杀（结算结果回填）
var last_hit_pos: Vector2 = Vector2.ZERO      # 最近命中位置（死亡新星锚点）
var is_clean: bool = true                     # 池清洁标记（归还/取出双向断言口径）

# ── 内部运行时 ─────────────────────────────────────────────────
var _traits_cache: Array = []                 # 挂载词条数组快照（trait_stack.traits 引用；派发序=挂载序）
var _live: bool = false                       # 生命周期存活标志（spawn 置位 / _recycle 清除）
var _in_recycle: bool = false                 # _recycle 重入保护
var _had_bounces: bool = false                # 出生时携带反弹预算（区分 BOUNCE_DEPLETED / EXPIRED）
var _bounces_done: int = 0                    # 已反弹次数（HIT_IS_BOUNCE 条件）
var _pierce_hits: int = 0                     # 已命中序数（HIT_AFTER_PIERCE 条件）
var _player_cache: Node2D = null              # 敌弹/条件求值用玩家引用（组查找缓存）
var _screen := Vector2(720.0, 1280.0)        # 逻辑分辨率缓存（spawn 期从 GameConfig 刷新）
var _sprite: Sprite2D = null                  # 占位渲染子节点（美术后续替换）

const OFFSCREEN_MARGIN := 96.0                # 出界回收余量（半径 + 边距）
const TEX_SIZE := 32                          # 占位圆形纹理边长（共享静态）
static var _shared_texture: ImageTexture = null
const ELEMENT_COLORS: Array[Color] = [
	Color(0.92, 0.92, 0.92),                 # KIN
	Color(1.0, 0.45, 0.2),                    # FIR
	Color(0.4, 0.8, 1.0),                     # ICE
	Color(0.75, 0.5, 1.0),                    # LTG
]
const ENEMY_TEAM_TINT := Color(1.0, 0.35, 0.45)   # 敌弹统一染色（敌我识别）


func _ready() -> void:
	# 池化实例化期组装占位渲染（代码组装为主；.tscn 仅做容器，§1.4）
	_sprite = Sprite2D.new()
	_sprite.name = "Visual"
	_sprite.centered = true
	_sprite.texture = _get_placeholder_texture()
	add_child(_sprite)
	visible = false                            # 池内不可见（取出 spawn 后激活）


func spawn(p_params: Dictionary) -> void:
	# ★ 池取出后统一初始化（参数字典契约，冻结给包 3——架构 §2.7.1 注）：
	#   基础键：{velocity, lifetime, pierce, bounces, hitbox_radius, element, attach_value,
	#            generation, weapon_uid, panel_snapshot, trait_stack, team}
	#   可选键：{weapon_ref（来源武器引用——TH_SIZE_NOVA/MEC 系效果引擎侧结算通道，
	#            Variant 判 is WeaponBase 后赋值；飞行中武器可能被移除，消费侧须守卫）}
	#   Homing 追加：{target_uid, turn_rate, speed_init, speed_max, accel, arm_delay,
	#                blast_radius, blast_falloff}
	#   Ballistic 可选：{accel（默认 0）, range（默认 0 = 仅寿命过期）}
	#   便捷扩展键（可选）：{traits（直接词条数组——测试/过渡期）, position（出生点）}
	# 依赖注入（非初始值，不走参数字典）：damage_pipeline / enemy_grid / pool / elemental 由武器侧 acquire 后设置。
	uid = GameConst.next_uid()
	velocity = p_params.get("velocity", Vector2.ZERO)
	lifetime_left = maxf(float(p_params.get("lifetime", 2.0)), 0.0)
	pierce_left = maxi(int(p_params.get("pierce", 1)), 0)
	bounces_left = maxi(int(p_params.get("bounces", 0)), 0)
	_had_bounces = bounces_left > 0
	hitbox_radius = maxf(float(p_params.get("hitbox_radius", 6.0)), 0.0)
	element = int(p_params.get("element", GameConst.Element.KIN))
	attach_value = float(p_params.get("attach_value", 0.0))
	generation = int(p_params.get("generation", 0))
	weapon_uid = int(p_params.get("weapon_uid", 0))
	team = int(p_params.get("team", 0))
	var snap: Variant = p_params.get("panel_snapshot", {})
	panel_snapshot = snap if typeof(snap) == TYPE_DICTIONARY else {}
	# 包 3 收口：TraitStack 真件类型收窄（契约键 trait_stack 语义不变）
	trait_stack = p_params.get("trait_stack", null) as TraitStack
	weapon_ref = null                            # 默认清零（可选键缺省 = 无宿主武器）
	var wref: Variant = p_params.get("weapon_ref", null)
	if wref is WeaponBase:
		weapon_ref = wref
	_traits_cache = []
	if trait_stack != null:
		var mounted: Variant = trait_stack.get("traits")
		if mounted is Array:
			_traits_cache = mounted
	var direct: Variant = p_params.get("traits", [])
	if direct is Array and not (direct as Array).is_empty():
		_traits_cache = direct
	if p_params.has("position"):
		position = p_params["position"]
	_read_form_params(p_params)
	hits_this_frame.clear()
	_bounces_done = 0
	_pierce_hits = 0
	killed_target = false                     # 包 3 收口：击杀证据复位
	last_hit_pos = Vector2.ZERO
	is_clean = false
	_live = true
	_in_recycle = false
	if GameConfig.balance != null:
		_screen = Vector2(GameConfig.balance.res_logic)
	visible = true
	_sync_visual()
	_dispatch_event(GameConst.TraitEvent.ON_SPAWN)


func tick(p_game_delta: float) -> void:
	# 运动学 → 出界/寿命 → 网格查询 → 帧聚合命中提交（GameLoop ④ 驱动）
	if not _live:
		return
	hits_this_frame.clear()
	lifetime_left -= p_game_delta
	if lifetime_left <= 0.0:
		_recycle(GameConst.RecycleReason.EXPIRED)
		return
	_move(p_game_delta)
	if not _live:
		return
	_check_offscreen()
	if not _live:
		return
	_sync_visual()
	_dispatch_event(GameConst.TraitEvent.ON_TICK,
		{"game_delta": p_game_delta})
	_check_collision()


func _move(p_game_delta: float) -> void:
	# 抽象：子类运动模型（直线/转向插值）。基类=匀速直线。
	global_position += velocity * p_game_delta


func _read_form_params(p_params: Dictionary) -> void:
	# 子类形态参数读取钩子（Homing 八键 / Ballistic 可选 accel、range）
	pass


func _reset_form_state() -> void:
	# 子类形态清零钩子（与 _reset_state 同步）
	pass


func is_player_projectile() -> bool:
	return team == 0


func effective_radius() -> float:
	# 碰撞半径（体积极限词条等比放大）
	return hitbox_radius * size_mult


# ── 碰撞（SpaceGrid 自管查询，Q-15） ────────────────────────────
func _check_collision() -> void:
	if team == 1:
		_check_player_hit()
		return
	if enemy_grid == null:
		return
	# 候选复制（query_circle 返回内部复用缓冲；提交链路内的 AOE/重索敌查询会复用同一缓冲）
	# + 窄相判定（§4.4 候选语义：网格保守半径超集 → 实际 hitbox_r 收窄）
	var candidates: Array[Node2D] = []
	candidates.append_array(enemy_grid.query_circle(global_position, effective_radius()))
	for target in candidates:
		if not _live:
			break
		if _in_reach(target, effective_radius()):
			_submit_hit(target)


func _in_reach(p_target: Node2D, p_radius: float) -> bool:
	# 窄相判定：圆距 ≤ 自身查询半径 + 目标实际 hitbox_r（Enemy.hitbox_r 快照）
	if p_target == null:
		return false
	var r: Variant = p_target.get("hitbox_r")
	var tr := float(r) if r != null else 0.0
	return global_position.distance_to(p_target.global_position) <= p_radius + tr


func _check_player_hit() -> void:
	# 敌弹 × 玩家：单目标距离判定（玩家命中盒为 Area2D 低频通道 Q-15 例外；
	# 敌弹量少，直接距离判定避免物理回调开销）。伤害走简化路径（Q-16：不入 M-12）。
	var player := _find_player()
	if player == null:
		return
	var pr: Variant = player.get("hitbox_radius")
	var reach := effective_radius() + (float(pr) if pr != null else 0.0)
	if global_position.distance_to(player.global_position) > reach:
		return
	if player.has_method(&"take_contact_damage"):
		player.call(&"take_contact_damage", float(panel_snapshot.get("base_atk", 0.0)))
	_recycle(GameConst.RecycleReason.PIERCE_DEPLETED)


func _submit_hit(p_target: Node2D) -> void:
	# §4.4 时序：① ctx = 面板快照展开 + 运行态 → ② 词条乘区预聚合（条件自评）→
	# ③ ON_HIT 派发（挂载序）→ ④ pipeline.resolve → ⑤ 附着/穿透/回收后处理
	if p_target == null:
		return
	var t_uid: Variant = p_target.get("uid")
	if t_uid == null:
		return
	if hits_this_frame.has(t_uid):
		return                                # E-03 帧聚合：一帧一目标一条
	hits_this_frame[t_uid] = true
	if bool(p_target.get("dead")):
		return                                # E-06 死亡短路
	_pierce_hits += 1                        # 命中序数（HIT_AFTER_PIERCE 条件）
	var ctx := _build_damage_ctx(p_target)
	# 包 3 收口（§4.4 ②）：TraitStack 真件乘区预聚合 + 目标易伤乘区注入（A2 §1.8）
	var tctx := _prepare_hit_traits(ctx, p_target)
	var result: DamageResult = null
	if damage_pipeline != null and damage_pipeline.has_method(&"resolve"):
		result = damage_pipeline.call(&"resolve", ctx)
	else:
		result = DamageResult.new()          # 无管线防御：零伤害直通（集成期注入后不可达）
		result.final_value = 0.0
		result.killed = false
	_on_settled(p_target, result, tctx)


func _prepare_hit_traits(p_ctx: DamageContext, p_target: Node2D) -> TraitContext:
	# 包 3 收口（§4.4 ②③）：乘区预聚合（collect_mult_pools 条件自评注入 mult_pools）
	# + 易伤乘区（vuln 池）+ ON_HIT 派发（TraitStack 真件通道 / 直挂数组兼容通道）
	# + 集成包 B.2：遗物命中时点独立乘区（经 weapon_ref 的 RelicHandler 通道）
	var tctx := _build_trait_ctx(GameConst.TraitEvent.ON_HIT,
		{"target": p_target, "damage_ctx": p_ctx})
	if weapon_ref != null and is_instance_valid(weapon_ref):
		(weapon_ref as WeaponBase).inject_relic_pools(p_ctx, p_target)
	if trait_stack is TraitStack:
		for pool in (trait_stack as TraitStack).collect_mult_pools(tctx):
			p_ctx.mult_pools.append(pool)
		_inject_vuln_pool(p_ctx, p_target)
		(trait_stack as TraitStack).dispatch(GameConst.TraitEvent.ON_HIT, tctx)
	elif not _traits_cache.is_empty():
		for mounted in _traits_cache:
			if mounted is Object and (mounted as Object).has_method(&"on_event"):
				(mounted as Object).call(&"on_event", GameConst.TraitEvent.ON_HIT, tctx)
	return tctx


func _inject_vuln_pool(p_ctx: DamageContext, p_target: Node2D) -> void:
	# 包 3 收口：目标侧易伤乘区注入（冰冻易伤 ×1.25——vuln 池在管线步骤⑤入池，A2 §1.8）。
	# 集成包 B.7 去重：同 ctx 已含 vuln 池（如来源武器已注入）时跳过。
	if p_target == null or WeaponBase.has_mult_pool(p_ctx, &"vuln"):
		return
	var state: Variant = p_target.get("elemental")
	if state is ElementalState:
		var factor := (state as ElementalState).get_vuln_factor()
		if factor > 1.0:
			p_ctx.mult_pools.append({
				"pool_id": &"vuln",
				"source_uid": 0,
				"contrib": factor - 1.0,
				"cap_pool": factor - 1.0,
				"priority": 0,
			})


func _build_damage_ctx(p_target: Node2D) -> DamageContext:
	# DamageContext 构建（B_spec §2.2；乘区 contrib 由词条在 ON_HIT 期注入）
	var ctx := DamageContext.make()
	ctx.source_uid = uid
	ctx.target_uid = int(p_target.get("uid"))
	ctx.target = p_target
	ctx.frame_stamp = GameConfig.frame_stamp
	ctx.base_atk = float(panel_snapshot.get("base_atk", 0.0))
	ctx.flat_bonus = float(panel_snapshot.get("flat_bonus", 0.0))
	ctx.crit_chance = float(panel_snapshot.get("crit_rate", 0.0))
	ctx.crit_mult = float(panel_snapshot.get("crit_mult", 2.0))
	var adds: Variant = panel_snapshot.get("add_entries", [])
	if adds is Array and not (adds as Array).is_empty():
		for entry in adds:
			ctx.add_entries.append(entry)     # 逐项入列（类型化数组不接受整批 Array 直赋）
	# v0.7.0（A6 §3）：芯片 ATK% 独立乘区段注入（快照键 >0 才入列——零芯片零开销）
	var chip_pct := float(panel_snapshot.get("chip_atk_pct", 0.0))
	if chip_pct > 0.0:
		ctx.chip_entries.append({"stat": &"atk_pct", "contrib": chip_pct})
	ctx.element = element
	# v1.1.0 增幅双轨（A10 §2）：FIR/ICE 直击且目标带反向附着 → amplify 乘区池注入
	#（字段逐字对齐 vuln 池先例；KIN/LTG/光束/近战/settle_aoe/DOT/连锁跳不经此门——天然排除）
	if elemental != null and (element == GameConst.Element.FIR or element == GameConst.Element.ICE):
		var amp := elemental.try_amplify_factor(p_target, element)
		if amp > 1.0:
			ctx.mult_pools.append({
				"pool_id": &"amplify",
				"source_uid": uid,
				"contrib": amp - 1.0,
				"cap_pool": amp - 1.0,
				"priority": 0,
			})
	ctx.hit_flags = _hit_flags()
	if p_target.has_method(&"get_resist"):
		ctx.target_resist = float(p_target.call(&"get_resist", element))
	ctx.bounce_count = _bounces_done
	ctx.pierce_index = _pierce_hits + 1
	ctx.generation = generation
	# is_first_hit_of_wave：波首命中位（集成包 B.4 接线——WaveDirector.wave_first_kill_done
	# 置位前为 true，SYN_FIRST_STRIKE「本波首杀前」条件真源；无来源武器引用 → false 安全）
	ctx.is_first_hit_of_wave = _wave_first_hit()
	ctx.player_hp_pct = _player_hp_pct()
	ctx.pos = global_position
	return ctx


func _wave_first_hit() -> bool:
	# 经来源武器查询波首命中位（weapon_ref 为空 = 无宿主通道 → false 安全，pkg2 口径不变）
	if weapon_ref != null and is_instance_valid(weapon_ref):
		return (weapon_ref as WeaponBase).is_wave_first_hit()
	return false


func _hit_flags() -> int:
	# hit_flags 位标志（词条条件自评，B_spec §2.2）
	var flags := 0
	if _bounces_done > 0:
		flags |= GameConst.HIT_IS_BOUNCE
	if _pierce_hits >= 1:
		flags |= GameConst.HIT_AFTER_PIERCE
	if generation > 0:
		flags |= GameConst.HIT_IS_SPLIT_CHILD
	return flags


func _on_settled(p_target: Node2D, p_result: DamageResult, p_tctx: TraitContext = null) -> void:
	# 结算后（§4.4 ⑤）：结果应用 → 元素附着（本弹载荷 + ELE 词条请求）→ 穿透计数 →
	# OnPierce 或回收判定；击杀证据回填（死亡新星输入）
	_apply_result_to(p_target, p_result)
	if p_result != null:
		killed_target = killed_target or p_result.killed
		last_hit_pos = global_position
	# v1.1.0 增幅消耗（A10 §2）：结算成功且目标未 dead → 清反向附着（重判同条件幂等）
	if elemental != null and p_result != null and not p_result.killed:
		elemental.consume_amplify(p_target, element)
	_apply_elemental(p_target, p_result, p_tctx)
	pierce_left -= 1
	if pierce_left > 0:
		_dispatch_event(GameConst.TraitEvent.ON_PIERCE, {"target": p_target})
	else:
		_recycle(GameConst.RecycleReason.PIERCE_DEPLETED)


func _apply_elemental(p_target: Node2D, p_result: DamageResult, p_tctx: TraitContext) -> void:
	# 包 3 收口（§4.4 ⑤）：元素附着——本弹载荷（element/attach_value，武器/词条注入）
	# + ELE 词条 attach_request（引擎侧统一提交 ElementalSystem；快照取当跳结算结果）
	if elemental == null or p_target == null:
		return
	var snapshot := 0.0
	var hit_damage := 0.0
	if p_result != null:
		snapshot = p_result.panel_snapshot
		hit_damage = p_result.final_value
	else:
		snapshot = float(panel_snapshot.get("base_atk", 0.0))
	if element != GameConst.Element.KIN and attach_value > 0.0:
		elemental.apply_attach(p_target, element, attach_value,
			{"snapshot": snapshot, "hit_damage": hit_damage})
	if p_tctx != null and not p_tctx.attach_request.is_empty():
		var request: Dictionary = p_tctx.attach_request
		elemental.apply_attach(p_target, int(request.get("element", GameConst.Element.KIN)),
			float(request.get("value", 0.0)), {
				"snapshot": snapshot,
				"hit_damage": hit_damage,
				"overrides": request.get("overrides", {}),
			})


func _apply_result_to(p_target: Node2D, p_result: DamageResult) -> void:
	# Enemy.take_result（扣血/易伤标记/死亡广播——pipeline 步骤 9 之后由本侧应用）。
	# 落血口径双轨（同 weapon_base.settle_aoe 审查修复）：真件 DamagePipeline 九步 9b
	# 在 resolve 内部已 take_result 落血（_apply_to_target——killed 判定/死亡广播唯一
	# 执行点），本侧再落血即直击伤害 ×2（主路径 _submit_hit / Homing 集束次级）；透传
	# 桩 resolve 只算不落血，落血职责在调用方（pkg2/pkg3 桩用例锁定口径，保持不变）。
	# 管线为 null（无管线防御零伤直通）非真件，仍走本侧落血（行为不变）。
	if p_target == null or damage_pipeline is DamagePipeline:
		return
	if p_target.has_method(&"take_result"):
		p_target.call(&"take_result", p_result)


# ── 六大生命周期事件唯一派发点 ──────────────────────────────────
func _dispatch_event(p_event: int, p_extra: Dictionary = {}) -> TraitContext:
	# ★ M-09 契约：派发顺序 = 挂载顺序（确定性）；无词条零开销直通（载荷惰性构造）。
	# 包 3 收口：TraitStack 真件派发通道（链式深度 3 熔断 + 同事件重入保护，M-10）；
	# 直挂数组通道（spawn 参数字典 "traits" 便捷键）保留为测试/过渡期兼容路径。
	var ctx := _build_trait_ctx(p_event, p_extra)
	if trait_stack is TraitStack:
		(trait_stack as TraitStack).dispatch(p_event, ctx)
	elif not _traits_cache.is_empty():
		for mounted in _traits_cache:
			if mounted is Object and (mounted as Object).has_method(&"on_event"):
				(mounted as Object).call(&"on_event", p_event, ctx)
	return ctx


func _build_trait_ctx(p_event: int, p_extra: Dictionary = {}) -> TraitContext:
	# 包 3 收口：单点改构 TraitContext 实例（原 Dictionary 载荷——架构 §2.9.1 真件替换）
	var ctx := TraitContext.new()
	ctx.event = p_event
	ctx.projectile = self
	ctx.beam = null
	ctx.melee = null
	ctx.weapon = null
	ctx.target = p_extra.get("target")
	ctx.damage_ctx = p_extra.get("damage_ctx")
	ctx.game_delta = float(p_extra.get("game_delta", 0.0))
	# 来源武器接线（TH_SIZE_NOVA/MEC 系效果依赖 ctx.weapon 的 get_threshold/settle_aoe）；
	# 武器可能中途被移除——飞行中弹体守卫，失效引用按无武器处理
	ctx.weapon = weapon_ref if is_instance_valid(weapon_ref) else null
	return ctx


# ── 分裂（三重闸门 §六.3） ──────────────────────────────────────
func request_split(p_count: int, p_spread_deg: float, p_inherit_ratio: float,
		p_echo: bool = false) -> void:
	# 代数 ≤3 + 单次子数 ≤8 + 全场软上限；F-13：子代仅继承面板快照比例（不继承乘区/元素附着）
	# 包 3 收口：p_echo（TH_FRACTAL_ECHO，分裂深度 ≥3）——词条定义继承扩展至乘区词条
	if pool == null:
		return
	var max_gen: int = 3 if GameConfig.balance == null else GameConfig.balance.split_max_generation
	if generation + 1 > max_gen:
		DebugStats.count(&"split_rejected_generation")
		return
	var max_children: int = 8 if GameConfig.balance == null else GameConfig.balance.split_max_children
	if p_count > max_children:
		DebugStats.count(&"split_rejected_children")
		return
	if pool.total_active() >= pool.soft_limit:
		DebugStats.count(&"split_rejected_soft_limit")
		return
	for i in range(p_count):
		var child := pool.acquire() as ProjectileBase
		if child == null:
			return                            # 池满：后续子代丢弃（AC-14.4）
		child.damage_pipeline = damage_pipeline
		child.enemy_grid = enemy_grid
		child.pool = pool
		child.elemental = elemental
		child.position = position
		var angle_offset := 0.0
		if p_count > 1:
			angle_offset = deg_to_rad(p_spread_deg) * (float(i) / float(p_count - 1) - 0.5) * 2.0
		var child_panel: Dictionary = panel_snapshot.duplicate(true)
		child_panel["base_atk"] = float(child_panel.get("base_atk", 0.0)) * p_inherit_ratio
		var params := {
			"velocity": velocity.rotated(angle_offset),
			"lifetime": lifetime_left,
			"pierce": 1,
			"bounces": 0,
			"hitbox_radius": hitbox_radius,
			"element": element,
			"attach_value": 0.0,             # F-13：不继承元素附着
			"generation": generation + 1,
			"weapon_uid": weapon_uid,
			"weapon_ref": weapon_ref,            # 分裂子代继承来源武器（效果引擎侧通道）
			"panel_snapshot": child_panel,
			"team": team,
		}
		# F-13：inheritable 词条定义复制（TraitStack.copy_for_split——包 3 真件；
		# 定义引用复制非深拷贝，子代条件自评、独立过护栏）
		if trait_stack is TraitStack:
			params["trait_stack"] = (trait_stack as TraitStack).copy_for_split(
				generation + 1, p_echo)
		child.spawn(params)


# ── 反弹（反射角镜像） ──────────────────────────────────────────
func _apply_bounce(p_normal: Vector2) -> void:
	# 边界反弹：反射角镜像 v' = v − 2(v·n)n + bounces_left-- + ON_BOUNCE 派发
	velocity = velocity - 2.0 * velocity.dot(p_normal) * p_normal
	var r := effective_radius()
	if p_normal.x > 0.0:
		global_position.x = r
	elif p_normal.x < 0.0:
		global_position.x = _screen.x - r
	if p_normal.y > 0.0:
		global_position.y = r
	elif p_normal.y < 0.0:
		global_position.y = _screen.y - r
	bounces_left -= 1
	_bounces_done += 1
	_dispatch_event(GameConst.TraitEvent.ON_BOUNCE)


func _check_edge_bounce() -> void:
	# 屏幕四边反射判定（Ballistic 反弹路径）：预算内反射；预算耗尽（曾有预算）BOUNCE_DEPLETED；
	# 从未携带预算的子弹不在此拦截（出屏后由 _check_offscreen 以 EXPIRED 回收）。
	var r := effective_radius()
	var pos := global_position
	var normal := Vector2.ZERO
	if pos.x <= r:
		normal = Vector2(1, 0)
	elif pos.x >= _screen.x - r:
		normal = Vector2(-1, 0)
	elif pos.y <= r:
		normal = Vector2(0, 1)
	elif pos.y >= _screen.y - r:
		normal = Vector2(0, -1)
	if normal == Vector2.ZERO:
		return
	if bounces_left > 0:
		_apply_bounce(normal)
	elif _had_bounces:
		_recycle(GameConst.RecycleReason.BOUNCE_DEPLETED)


func _check_offscreen() -> void:
	# 出界判定：屏外余量（半径 + OFFSCREEN_MARGIN）→ EXPIRED
	var m := effective_radius() + OFFSCREEN_MARGIN
	if global_position.x < -m or global_position.x > _screen.x + m \
			or global_position.y < -m or global_position.y > _screen.y + m:
		_recycle(GameConst.RecycleReason.EXPIRED)


# ── 消弹（NULLIFIED 路径入口：ArcSlash 弧内敌方弹幕清除，包 3 M-08 调用） ──
func nullify() -> void:
	_recycle(GameConst.RecycleReason.NULLIFIED)


# ── 回收五路径统一收束（E-04） ───────────────────────────────────
func _recycle(p_reason: int, p_released_by_pool: bool = false) -> void:
	# ★ 顺序契约：OnExpire 派发 → 状态清零 → 池归还。
	# p_released_by_pool=true 为 FORCED 直收路径（ProjectilePool.force_recycle_oldest
	# 直接调 release，未经本入口）——归还动作由池侧完成，此处只做派发与清零。
	# 包 3 收口：ON_EXPIRE 期 split_request 输出由引擎在此执行（三重闸门在 request_split）。
	if not _live or _in_recycle:
		return
	_in_recycle = true
	_live = false
	DebugStats.count(&"projectile_recycled")
	DebugStats.count(StringName("recycle_reason_%d" % p_reason))
	var tctx := _dispatch_event(GameConst.TraitEvent.ON_EXPIRE)
	if tctx != null and not tctx.split_request.is_empty():
		var request: Dictionary = tctx.split_request
		request_split(int(request.get("count", 0)), float(request.get("spread_deg", 0.0)),
			float(request.get("inherit_ratio", 0.0)), bool(request.get("echo", false)))
	_reset_state()
	if not p_released_by_pool and pool != null:
		pool.release(self)                    # 池再调 _reset_state（幂等清零）
	_in_recycle = false


func _reset_state() -> void:
	# 归还清零契约（E-04/E-05：速度/计数/词条/帧聚合/计时）。
	# FORCED 直收收束：池侧直接 release（未经 _recycle）→ meta 携带原因在此补走统一收束。
	if _live and has_meta(&"_recycle_reason"):
		var reason: int = int(get_meta(&"_recycle_reason", GameConst.RecycleReason.FORCED))
		remove_meta(&"_recycle_reason")
		_recycle(reason, true)
		return
	velocity = Vector2.ZERO
	lifetime_left = 0.0
	pierce_left = 0
	bounces_left = 0
	_had_bounces = false
	_bounces_done = 0
	_pierce_hits = 0
	generation = 0
	hitbox_radius = 6.0
	element = GameConst.Element.KIN
	attach_value = 0.0
	size_mult = 1.0
	weapon_uid = 0
	weapon_ref = null                           # 池复用防陈旧引用（武器可能已销毁）
	team = 0
	panel_snapshot = {}
	trait_stack = null
	_traits_cache = []
	killed_target = false                     # 包 3 收口：击杀证据清零
	last_hit_pos = Vector2.ZERO
	hits_this_frame.clear()
	_reset_form_state()
	is_clean = true
	_sync_visual()


# ── 支撑 ──────────────────────────────────────────────────────────
func _sync_visual() -> void:
	# 占位渲染同步：半径等比缩放 + 元素染色（敌弹统一敌我识别色）
	if _sprite == null:
		return
	var scale_f := effective_radius() / (TEX_SIZE * 0.5)
	_sprite.scale = Vector2(scale_f, scale_f)
	var color: Color = ELEMENT_COLORS[0]
	if element >= 0 and element < ELEMENT_COLORS.size():
		color = ELEMENT_COLORS[element]
	if team == 1:
		color = ENEMY_TEAM_TINT
	_sprite.self_modulate = color


func _find_player() -> Node2D:
	# 玩家引用缓存（组查找；包 4 集成期可改为显式注入——当前零接线成本）
	if _player_cache == null or not is_instance_valid(_player_cache):
		_player_cache = null
		var tree := get_tree()
		if tree != null:
			_player_cache = tree.get_first_node_in_group(&"player") as Node2D
	return _player_cache


func _player_hp_pct() -> float:
	# 背水协议条件（SYN_LOWHP_FURY ctx；无玩家 → 1.0 满血安全值）
	var player := _find_player()
	if player != null and player.has_method(&"get_hp_pct"):
		return float(player.call(&"get_hp_pct"))
	return 1.0


static func _get_placeholder_texture() -> ImageTexture:
	# 共享静态占位圆形纹理（程序化生成；美术后续替换）
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
