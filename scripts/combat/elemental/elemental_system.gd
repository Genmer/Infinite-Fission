# scripts/combat/elemental/elemental_system.gd
# M-11 ElementalSystem（架构 §2.10）：元素附着/衰减/状态/反应编排（Node，帧序⑤挂入）。
# · tick(delta)：全敌 λ 比例衰减 → 状态计时 → DOT 跳伤调度（HIT_IS_DOT 不掷暴击）
#   → 超导削抗到期恢复；GameLoop 集成期在敌人阶段后调用（包 4 接线）。
# · detect_reactions()：帧末统一检测（E-07）：优先级 碎裂>过载>超导；一帧一反应（每敌）；
#   v1.1.0 反应 CD 分立（rule.cd 键，缺省回退 cd_rxn）；反应走 resolve_reaction 独立结算
#   （F20/F21 快照通道）。
# · _shock_chain：感电连锁 3 目标/160px/35%每跳/深度 2 衰减 60%（同周期同目标去重）。
# · DOT/连锁跳伤/反应三类结算各持独立 source_uid（管线幂等键分流，防同帧互撞）。
class_name ElementalSystem
extends Node

# v1.1.0 增幅双轨（A10 §2）：融化 = ICE 附着 + FIR 直击 ×1.5 / 蒸发 = FIR 附着 + ICE 直击 ×2.0
#（模块常量待升格 BalanceTables——A10 §7 假设 E-AMP-2）
const AMP_MELT_FACTOR := 1.5
const AMP_VAPOR_FACTOR := 2.0
const MASTERY_LAYER_CAP := 3                   # v1.1.0 元素精通全局层数封顶（唯一裁定点）

var pipeline: RefCounted = null                # 注入（DamagePipeline 或桩；独立结算通道）
var enemy_grid: SpaceGrid = null               # 注入（连锁传导/范围扩散目标查询）
var chip_handler: ChipHandler = null           # 注入（v0.7.0 A6 §3：附着强度芯片 ×(1+K_attach)）
var _hosts: Array[Node2D] = []                 # 已挂载状态容器的敌人（§1.3-3 白名单：状态宿主）

var _reaction_mults: Dictionary = {}           # source_uid -> mult（ELE_REACTION_VOID ×1.8 聚合）
var _mastery_reg: Dictionary = {}              # source_uid -> int 层数（v1.1.0 ELE_MASTERY 跨武器注册）
var _mastery_step := 0.0                       # 精通每层步长（后写覆盖）
var _uid_dot: int = 0                          # DOT 结算幂等键 source_uid（分流）
var _uid_chain: int = 0                        # 连锁跳伤 source_uid
var _uid_reaction: int = 0                     # 反应结算 source_uid


func _init() -> void:
	_uid_dot = GameConst.next_uid()
	_uid_chain = GameConst.next_uid()
	_uid_reaction = GameConst.next_uid()


func register_host(p_enemy: Node2D) -> void:
	# 敌人出生时挂载 ElementalState（immune_mask 注入，F-17）
	if p_enemy == null or _hosts.has(p_enemy):
		return
	var state := ElementalState.new()
	state.immune_mask = int(p_enemy.get("immune_mask"))
	p_enemy.set("elemental", state)
	_hosts.append(p_enemy)


func unregister_host(p_enemy: Node2D) -> void:
	# 死亡/回收时移除（清 DOT，AC-11.1）——ReFCounted 容器随之释放
	if p_enemy == null:
		return
	if p_enemy.get("elemental") != null:
		(p_enemy.get("elemental") as ElementalState).reset()
		p_enemy.set("elemental", null)
	_hosts.erase(p_enemy)


func register_reaction_mult(p_source_uid: int, p_mult: float) -> void:
	# ELE_REACTION_VOID（元素裂变 ×1.8）注册：全部混合反应结算值乘区（来源侧聚合）
	if p_mult > 0.0:
		_reaction_mults[p_source_uid] = p_mult


func reset_run() -> void:
	# v1.1.0 审查 Critical 修复：重开清零注册表。本系统是 boot 期跨局常驻单例，
	# 旧武器 queue_free 后其 source_uid 注册键（reaction_mult ×1.8 既有缺口 + mastery
	# 精通层）永不复用 → 跨局残留虚增反应伤害且与 HUD 活栈显示不一致（XE1 坐实）。
	# 与 relic/chip/curse/blessing 的 reset_run 同位，_reset_run_state 统一调用。
	_reaction_mults.clear()
	_mastery_reg.clear()
	_mastery_step = 0.0


func reaction_mult() -> float:
	# 反应强化聚合（多源连乘；金卡唯一 → 实际单源 ×1.8）× 精通乘区（v1.1.0 E3：
	# 1 + step×Σ层，全局 ≤3 层）——剧变与增幅同源消费，同构乘算自动同乘；
	# 仅 VOID 注册（精通 0 层）时恒等 ×1.8（pkg3 面零改动）
	var product := 1.0
	for key in _reaction_mults:
		product *= float(_reaction_mults[key])
	var total := mastery_layers()
	if total > 0:
		product *= 1.0 + _mastery_step * float(total)
	return product


func register_mastery(p_source_uid: int, p_layers: int, p_step: float) -> void:
	# v1.1.0 ELE_MASTERY 注册：layers>0 且 step>0 才收（防御零/负值残留）；step 后写覆盖。
	# 无注销通道（武器不可卸载，A10 §7 E-AMP-1）；attach 期全量重报幂等覆盖。
	if p_layers <= 0 or p_step <= 0.0:
		return
	_mastery_reg[p_source_uid] = p_layers
	_mastery_step = p_step


func mastery_layers() -> int:
	# 跨武器层数合计 → 全局封顶（mini(total, MASTERY_LAYER_CAP)——唯一裁定点）
	var total := 0
	for uid in _mastery_reg:
		total += int(_mastery_reg[uid])
	return mini(total, MASTERY_LAYER_CAP)


# ── v1.1.0 增幅双轨（A10 §2：直击通道只读判定 + 结算后幂等消耗） ──
func try_amplify_factor(p_target: Node2D, p_hit_element: int) -> float:
	# 增幅系数试算（只读快照，无副作用）：融化/蒸发命中因子（无触发 → 1.0）。
	# 消耗由弹侧在结算成功且目标未 dead 后调 consume_amplify（重判同条件，幂等）。
	return maxf(_amplify_snapshot(p_target, p_hit_element), 1.0)


func consume_amplify(p_target: Node2D, p_hit_element: int) -> void:
	# 增幅消耗：重判同条件（已清则 no-op）→ clear_element(反向) 全清 + 分键遥测
	if p_target == null or bool(p_target.get("dead")):
		return
	var state: Variant = p_target.get("elemental")
	if not (state is ElementalState):
		return
	var st := state as ElementalState
	if p_hit_element == GameConst.Element.FIR and st.gauges[GameConst.Element.ICE] > 0.0:
		st.clear_element(GameConst.Element.ICE)
		DebugStats.count(&"amplify_melt")
	elif p_hit_element == GameConst.Element.ICE and st.gauges[GameConst.Element.FIR] > 0.0:
		st.clear_element(GameConst.Element.FIR)
		DebugStats.count(&"amplify_vapor")


func _amplify_snapshot(p_target: Node2D, p_hit_element: int) -> float:
	# 增幅快照判定（只读）：反向附着非零才触发；×reaction_mult() 与剧变同源消费。
	# KIN/LTG 直击、null/无状态宿主 → 0.0（= 不触发）；immune_mask 不查（吃附着计量）。
	if p_target == null:
		return 0.0
	var state: Variant = p_target.get("elemental")
	if not (state is ElementalState):
		return 0.0
	var st := state as ElementalState
	if p_hit_element == GameConst.Element.FIR and st.gauges[GameConst.Element.ICE] > 0.0:
		return AMP_MELT_FACTOR * reaction_mult()
	if p_hit_element == GameConst.Element.ICE and st.gauges[GameConst.Element.FIR] > 0.0:
		return AMP_VAPOR_FACTOR * reaction_mult()
	return 0.0


func apply_attach(p_enemy: Node2D, p_element: int, p_value: float,
		p_info: Dictionary = {}) -> void:
	# 附着入口（§4.4 ⑤）：immune_mask 检查在状态触发位；满槽 → 状态/连锁调度。
	# v0.7.0（A6 §3）：入口统一 ×(1+K_attach)（芯片 attach_strength）——覆盖弹载荷与
	# ELE 词条请求两条路（projectile_base._apply_elemental 双路都经本入口）。
	var state: Variant = p_enemy.get("elemental") if p_enemy != null else null
	if not (state is ElementalState):
		return
	var value := p_value
	if chip_handler != null:
		value *= 1.0 + maxf(chip_handler.stat_bonus(&"attach_strength"), 0.0)
	var snapshot := float(p_info.get("snapshot", 0.0))
	var overrides: Dictionary = p_info.get("overrides", {})
	var code: int = (state as ElementalState).apply(p_element, value, snapshot, overrides)
	if code == ElementalState.TRIGGER_SHOCK:
		var hit_damage := float(p_info.get("hit_damage", snapshot))
		if (state as ElementalState).shock_chain_cd <= 0.0:
			_shock_chain(p_enemy, hit_damage, (state as ElementalState).shock_chain_targets)
			(state as ElementalState).shock_chain_cd = 1.0   # 连锁护栏（槽清空外的二次防抖）


func tick(p_game_delta: float) -> void:
	# 全敌：λ 比例衰减（F19/F-22）→ 状态计时 → DOT 跳伤调度 → 超导到期恢复
	var lambdas: Array[float] = [0.35, 0.30, 0.40]
	if GameConfig.balance != null:
		lambdas = GameConfig.balance.element_decay_lambda
	for host in _hosts.duplicate():
		if host == null or bool(host.get("dead")):
			continue
		var state: Variant = host.get("elemental")
		if not (state is ElementalState):
			continue
		var st := state as ElementalState
		st.tick(p_game_delta, lambdas)
		_dot_tick(host, st)
		if st.consume_superconduct_expired():
			_restore_resist(host)


func detect_reactions() -> void:
	# ★ 帧末统一检测（敌人阶段末调用，E-07）：优先级 碎裂>过载>超导；一帧一反应（每敌）。
	# v1.1.0 CD 分立：触发前查 rule.cd（reaction_table 同值镜像），缺键回退 cd_rxn（F-34）。
	var tables: Dictionary = {}
	var cd_fallback := 2.0
	if GameConfig.balance != null:
		tables = GameConfig.balance.reaction_table
		cd_fallback = GameConfig.balance.cd_rxn
	for host in _hosts.duplicate():
		if host == null or bool(host.get("dead")):
			continue
		var state: Variant = host.get("elemental")
		if not (state is ElementalState):
			continue
		var st := state as ElementalState
		var order: Array[int] = [
			GameConst.ReactionType.RXN_FIR_ICE,
			GameConst.ReactionType.RXN_FIR_LTG,
			GameConst.ReactionType.RXN_ICE_LTG,
		]
		for rxn in order:
			if float(st.reaction_cd.get(rxn, 0.0)) > 0.0:
				continue
			if not _reaction_condition(st, rxn):
				continue
			var rule: Dictionary = tables.get(reaction_key(rxn), {})
			st.reaction_cd[rxn] = maxf(float(rule.get("cd", cd_fallback)), 0.01)
			_trigger_reaction(host, st, rxn)
			break                                 # 一帧一反应


static func reaction_key(p_rxn: int) -> String:
	# v1.1.0 CD 分立：ReactionType 中性 ID → reaction_table 键（唯一映射口）
	match p_rxn:
		GameConst.ReactionType.RXN_FIR_ICE:
			return "RXN_FIR_ICE"
		GameConst.ReactionType.RXN_FIR_LTG:
			return "RXN_FIR_LTG"
		GameConst.ReactionType.RXN_ICE_LTG:
			return "RXN_ICE_LTG"
	return ""


# ── 内部 ──────────────────────────────────────────────────────────
func _reaction_condition(p_state: ElementalState, p_rxn: int) -> bool:
	# 两两反应触发条件：双槽附着量均非零（B_spec §2.4）
	match p_rxn:
		GameConst.ReactionType.RXN_FIR_ICE:
			return p_state.has_both(GameConst.Element.FIR, GameConst.Element.ICE)
		GameConst.ReactionType.RXN_FIR_LTG:
			return p_state.has_both(GameConst.Element.FIR, GameConst.Element.LTG)
		GameConst.ReactionType.RXN_ICE_LTG:
			return p_state.has_both(GameConst.Element.ICE, GameConst.Element.LTG)
	return false


func _trigger_reaction(p_enemy: Node2D, p_state: ElementalState, p_rxn: int) -> void:
	# 构造反应 ctx（HIT_IS_REACTION + 快照面板）→ pipeline.resolve_reaction + 清双槽
	var tables: Dictionary = {}
	if GameConfig.balance != null:
		tables = GameConfig.balance.reaction_table
	var rm := reaction_mult()
	var enemy_uid := int(p_enemy.get("uid"))
	match p_rxn:
		GameConst.ReactionType.RXN_FIR_ICE:
			# 碎裂：×2.0 × 点燃剩余 DOT 总额（独立结算，清双槽 + 燃尽）
			var rule: Dictionary = tables.get("RXN_FIR_ICE", {"coef": 2.0})
			var base := p_state.remaining_dot_total()
			var coef := float(rule.get("coef", 2.0)) * rm
			_settle_reaction(p_enemy, base, coef, GameConst.ReactionType.RXN_FIR_ICE)
			p_state.clear_element(GameConst.Element.FIR)
			p_state.clear_element(GameConst.Element.ICE)
			p_state.burn_timer = 0.0            # 碎裂消耗剩余 DOT
			p_state.burn_layers = 0
		GameConst.ReactionType.RXN_FIR_LTG:
			# 过载：120% ATK × 反应强化，半径 90 爆炸（主目标 + 半径内扩散）
			var rule2: Dictionary = tables.get("RXN_FIR_LTG", {"coef": 1.2, "radius": 90.0})
			var snapshot := p_state.last_attach_snapshot
			var coef2 := float(rule2.get("coef", 1.2)) * rm
			var radius := float(rule2.get("radius", 90.0))
			_settle_reaction(p_enemy, snapshot, coef2, GameConst.ReactionType.RXN_FIR_LTG)
			_spread_reaction(p_enemy, radius, snapshot, coef2)
			p_state.clear_element(GameConst.Element.FIR)
			p_state.clear_element(GameConst.Element.LTG)
		GameConst.ReactionType.RXN_ICE_LTG:
			# 超导：全抗 −30%（可击破至负值），持续 6s（纯减益；reaction_triggered 广播）
			var rule3: Dictionary = tables.get("RXN_ICE_LTG", {"resist_delta": -0.3, "duration": 6.0})
			var delta := float(rule3.get("resist_delta", -0.3))
			var duration := float(rule3.get("duration", 6.0))
			_apply_resist_delta(p_enemy, delta)
			p_state.apply_superconduct(delta, duration)
			p_state.clear_element(GameConst.Element.ICE)
			p_state.clear_element(GameConst.Element.LTG)
			EventBus.emit_reaction_triggered(GameConst.ReactionType.RXN_ICE_LTG,
				(p_enemy as Node2D).global_position, enemy_uid)
			DebugStats.count(&"reaction_superconduct")
	DebugStats.count(&"reaction_triggered")


func _settle_reaction(p_enemy: Node2D, p_snapshot: float, p_coef: float, p_rxn: int) -> void:
	# 反应独立结算（F20/F21：D = χ×φ×S_snap；HIT_IS_REACTION 不掷暴击）
	if pipeline == null or p_enemy == null or bool(p_enemy.get("dead")):
		return
	var ctx := DamageContext.make()
	ctx.source_uid = _uid_reaction
	ctx.target = p_enemy
	ctx.target_uid = int(p_enemy.get("uid"))
	ctx.frame_stamp = GameConfig.frame_stamp
	ctx.base_atk = p_snapshot
	ctx.element = p_rxn                         # 反应通道承载 ReactionType 中性 ID（广播约定）
	ctx.hit_flags = 0                           # resolve_reaction 内强制 HIT_IS_REACTION
	ctx.pos = (p_enemy as Node2D).global_position
	var result: DamageResult = null
	if pipeline is DamagePipeline:
		result = (pipeline as DamagePipeline).resolve_reaction(p_snapshot, p_coef, ctx)
	elif pipeline.has_method(&"resolve_reaction"):
		# 桩路径适配（接口差异：桩单参签名，系数折算进面板）
		ctx.base_atk = p_snapshot * p_coef
		result = pipeline.call(&"resolve_reaction", ctx)
	if result != null:
		DebugStats.count(&"reaction_settled")


func _spread_reaction(p_center: Node2D, p_radius: float, p_snapshot: float, p_coef: float) -> void:
	# 过载半径扩散：圆查询逐敌独立结算（去中心；同帧幂等键分流独立 uid）。
	# 网格候选为保守超集（入桶半径 = max_entity_radius）——此处窄相收窄到结算半径 + 目标 hitbox_r
	if enemy_grid == null:
		return
	var center: Vector2 = (p_center as Node2D).global_position
	var candidates: Array[Node2D] = []
	candidates.append_array(enemy_grid.query_circle(center, p_radius))
	for cand in candidates:
		if cand == p_center or bool(cand.get("dead")):
			continue
		var hr: Variant = cand.get("hitbox_r")
		var reach := p_radius + (float(hr) if hr != null else 0.0)
		if (cand as Node2D).global_position.distance_to(center) > reach:
			continue
		_settle_reaction(cand, p_snapshot, p_coef, GameConst.ReactionType.RXN_FIR_LTG)


func _dot_tick(p_enemy: Node2D, p_state: ElementalState) -> void:
	# DOT 跳伤：15%ATK 面板快照 × 层数（HIT_IS_DOT 不掷暴击；走管线主通道）
	if pipeline == null:
		return
	while p_state.consume_dot_due():
		var dot := p_state.burn_dot_ratio * p_state.burn_snapshot_atk \
			* float(p_state.burn_layers)
		var ctx := DamageContext.make()
		ctx.source_uid = _uid_dot
		ctx.target = p_enemy
		ctx.target_uid = int(p_enemy.get("uid"))
		ctx.frame_stamp = GameConfig.frame_stamp
		ctx.base_atk = dot
		ctx.element = GameConst.Element.FIR
		ctx.hit_flags = GameConst.HIT_IS_DOT
		ctx.crit_chance = 0.0
		ctx.pos = (p_enemy as Node2D).global_position
		if pipeline.has_method(&"resolve"):
			pipeline.call(&"resolve", ctx)
		DebugStats.count(&"elemental_dot_tick")


func _shock_chain(p_origin: Node2D, p_hit_damage: float, p_targets_per_hop: int) -> void:
	# 感电连锁：BFS 深度 2——首跳 35% 本次伤害，次跳衰减 60%；同周期同目标去重
	if pipeline == null or enemy_grid == null or p_targets_per_hop <= 0:
		return
	var depth := 2
	var decay := 0.6
	var ratio := 0.35
	var radius := 160.0
	if GameConfig.balance != null:
		var shock: Dictionary = GameConfig.balance.element_states.get("shock", {})
		depth = int(shock.get("chain_depth", 2))
		decay = float(shock.get("chain_decay", 0.6))
		ratio = float(shock.get("chain_ratio", 0.35))
		radius = float(shock.get("chain_radius", 160.0))
	var origin_pos: Vector2 = (p_origin as Node2D).global_position
	var dedup: Dictionary = {int(p_origin.get("uid")): true}
	var frontier: Array[Node2D] = [p_origin]
	var damage := p_hit_damage * ratio
	for _hop in range(depth):
		var next_frontier: Array[Node2D] = []
		for node in frontier:
			for target in _nearest_targets(node, radius, dedup, p_targets_per_hop):
				dedup[int(target.get("uid"))] = true
				_settle_chain_jump(target, damage)
				next_frontier.append(target)
		if next_frontier.is_empty():
			break
		frontier = next_frontier
		damage *= decay                          # 每跳衰减 60%


func _nearest_targets(p_from: Node2D, p_radius: float, p_dedup: Dictionary,
		p_count: int) -> Array[Node2D]:
	# 半径内最近 p_count 个未去重目标（距离升序，确定性）
	var from: Vector2 = (p_from as Node2D).global_position
	var candidates: Array[Node2D] = []
	candidates.append_array(enemy_grid.query_circle(from, p_radius))
	var rows: Array = []
	for cand in candidates:
		if bool(cand.get("dead")) or p_dedup.has(int(cand.get("uid"))):
			continue
		rows.append([from.distance_squared_to((cand as Node2D).global_position), cand])
	rows.sort_custom(func(a, b) -> bool: return float(a[0]) < float(b[0]))
	var out: Array[Node2D] = []
	for row in rows:
		if out.size() >= p_count:
			break
		out.append(row[1])
	return out


func _settle_chain_jump(p_target: Node2D, p_damage: float) -> void:
	# 连锁跳伤（HIT_IS_DOT 不掷暴击；走管线主通道）
	var ctx := DamageContext.make()
	ctx.source_uid = _uid_chain
	ctx.target = p_target
	ctx.target_uid = int(p_target.get("uid"))
	ctx.frame_stamp = GameConfig.frame_stamp
	ctx.base_atk = p_damage
	ctx.element = GameConst.Element.LTG
	ctx.hit_flags = GameConst.HIT_IS_DOT
	ctx.crit_chance = 0.0
	ctx.pos = (p_target as Node2D).global_position
	if pipeline.has_method(&"resolve"):
		pipeline.call(&"resolve", ctx)
	DebugStats.count(&"shock_chain_jump")


func _apply_resist_delta(p_enemy: Node2D, p_delta: float) -> void:
	# 超导削抗：全抗 +p_delta（−0.3；可击破至负值 = 增伤），钳制 [−0.8, 0.8]
	var resist: Variant = p_enemy.get("resist")
	if resist is Array:
		for i in range((resist as Array).size()):
			(resist as Array)[i] = clampf(float((resist as Array)[i]) + p_delta, -0.8, 0.8)


func _restore_resist(p_enemy: Node2D) -> void:
	# 超导到期：全抗恢复（+0.3，钳制上限）
	_apply_resist_delta(p_enemy, 0.3)
