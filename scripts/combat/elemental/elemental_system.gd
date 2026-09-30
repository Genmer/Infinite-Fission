# scripts/combat/elemental/elemental_system.gd
# M-11 ElementalSystem（架构 §2.10）：元素附着/衰减/状态/反应编排（Node，帧序⑤挂入）。
# · tick(delta)：全敌 λ 比例衰减 → 状态计时 → DOT 跳伤调度（HIT_IS_DOT 不掷暴击）
#   → 绽放到期爆发（R192）→ 超导削抗到期按记录 delta 恢复（M0 账本）；
#   GameLoop 集成期在敌人阶段后调用（包 4 接线）。
# · detect_reactions()：帧末统一检测（E-07）：优先级走 RXN_ORDER（R192 矩阵 20 序）；
#   检测 = 元素位掩码 → 有序候选短表（k≤1 宿主零候选；一帧一反应/每敌；cd_rxn=2s）；
#   反应走 resolve_reaction 独立结算（F20/F21 快照通道）。
# · _shock_chain：感电连锁 3 目标/160px/35%每跳/深度 2 衰减 60%（同周期同目标去重）。
# · DOT/连锁跳伤/反应三类结算各持独立 source_uid（管线幂等键分流，防同帧互撞）。
# R192 反应矩阵（id 契约 §3 唯一真源；低枚举序元素在前）：碎裂/蒸发/绽放/过载/
# 扩散×5/冻结/感电/燃烧/激化/超导/结晶×6 共 20 键；冰+草留白（无枚举成员无表键）。
class_name ElementalSystem
extends Node

# R192：反应结算优先级（伤害转化 χ>0 头部 → 减益/工具层化；碎裂>过载>超导相对位保持）
const RXN_ORDER: Array[int] = [
	GameConst.ReactionType.RXN_FIR_ICE,        # 碎裂 1
	GameConst.ReactionType.RXN_FIR_HYD,        # 蒸发 2
	GameConst.ReactionType.RXN_HYD_DEN,        # 绽放 3
	GameConst.ReactionType.RXN_FIR_LTG,        # 过载 4
	GameConst.ReactionType.RXN_FIR_ANE,        # 扩散·火 5
	GameConst.ReactionType.RXN_ICE_ANE,        # 扩散·冰 6
	GameConst.ReactionType.RXN_LTG_ANE,        # 扩散·雷 7
	GameConst.ReactionType.RXN_HYD_ANE,        # 扩散·水 8
	GameConst.ReactionType.RXN_ANE_DEN,        # 扩散·草 9
	GameConst.ReactionType.RXN_ICE_HYD,        # 冻结 10
	GameConst.ReactionType.RXN_LTG_HYD,        # 感电 11
	GameConst.ReactionType.RXN_FIR_DEN,        # 燃烧 12
	GameConst.ReactionType.RXN_LTG_DEN,        # 激化 13
	GameConst.ReactionType.RXN_ICE_LTG,        # 超导 14
	GameConst.ReactionType.RXN_FIR_GEO,        # 结晶·火 15
	GameConst.ReactionType.RXN_ICE_GEO,        # 结晶·冰 16
	GameConst.ReactionType.RXN_LTG_GEO,        # 结晶·雷 17
	GameConst.ReactionType.RXN_HYD_GEO,        # 结晶·水 18
	GameConst.ReactionType.RXN_DEN_GEO,        # 结晶·草 19
	GameConst.ReactionType.RXN_ANE_GEO,        # 结晶·风 20
]

# R192：反应配对表（rxn → [元素 A, 元素 B]；id 契约 §3 逐字）。
# A 位语义（消费契约）：扩散族 5 键 A = 被扩元素（转移元素——_spread_attach 落槽目标，
# §3.3「转移X」列），其余键 A/B 为无序配对（检测/清槽按集合消费）。A 默认取低枚举序；
# 两处例外均系设计 §3.3 原文自身：RXN_DEN_GEO（id 写 DEN_GEO 而配对低序在前）、
# RXN_ANE_DEN（id 低序在前而 A=被扩元素 DEN——风扩草转移草，非转移风）。
# 检测条件/扩散转移元素/清槽契约同源此表——禁散落第二份配对。
const RXN_PAIRS: Dictionary = {
	GameConst.ReactionType.RXN_FIR_ICE: [GameConst.Element.FIR, GameConst.Element.ICE],
	GameConst.ReactionType.RXN_FIR_HYD: [GameConst.Element.FIR, GameConst.Element.HYD],
	GameConst.ReactionType.RXN_HYD_DEN: [GameConst.Element.HYD, GameConst.Element.DEN],
	GameConst.ReactionType.RXN_FIR_LTG: [GameConst.Element.FIR, GameConst.Element.LTG],
	GameConst.ReactionType.RXN_FIR_ANE: [GameConst.Element.FIR, GameConst.Element.ANE],
	GameConst.ReactionType.RXN_ICE_ANE: [GameConst.Element.ICE, GameConst.Element.ANE],
	GameConst.ReactionType.RXN_LTG_ANE: [GameConst.Element.LTG, GameConst.Element.ANE],
	GameConst.ReactionType.RXN_HYD_ANE: [GameConst.Element.HYD, GameConst.Element.ANE],
	GameConst.ReactionType.RXN_ANE_DEN: [GameConst.Element.DEN, GameConst.Element.ANE],
	GameConst.ReactionType.RXN_ICE_HYD: [GameConst.Element.ICE, GameConst.Element.HYD],
	GameConst.ReactionType.RXN_LTG_HYD: [GameConst.Element.LTG, GameConst.Element.HYD],
	GameConst.ReactionType.RXN_FIR_DEN: [GameConst.Element.FIR, GameConst.Element.DEN],
	GameConst.ReactionType.RXN_LTG_DEN: [GameConst.Element.LTG, GameConst.Element.DEN],
	GameConst.ReactionType.RXN_ICE_LTG: [GameConst.Element.ICE, GameConst.Element.LTG],
	GameConst.ReactionType.RXN_FIR_GEO: [GameConst.Element.GEO, GameConst.Element.FIR],
	GameConst.ReactionType.RXN_ICE_GEO: [GameConst.Element.GEO, GameConst.Element.ICE],
	GameConst.ReactionType.RXN_LTG_GEO: [GameConst.Element.GEO, GameConst.Element.LTG],
	GameConst.ReactionType.RXN_HYD_GEO: [GameConst.Element.GEO, GameConst.Element.HYD],
	GameConst.ReactionType.RXN_DEN_GEO: [GameConst.Element.GEO, GameConst.Element.DEN],
	GameConst.ReactionType.RXN_ANE_GEO: [GameConst.Element.ANE, GameConst.Element.GEO],
}

# R192：λ 兜底缺省（FIR/ICE/LTG/HYD/ANE/GEO/DEN；真源 BalanceTables.element_decay_lambda）
const LAMBDA_FALLBACK: Array[float] = [0.35, 0.30, 0.40, 0.35, 0.50, 0.25, 0.30]

var pipeline: RefCounted = null                # 注入（DamagePipeline 或桩；独立结算通道）
var enemy_grid: SpaceGrid = null               # 注入（连锁传导/范围扩散目标查询）
var relic_handler: RelicHandler = null         # R199 D07：遗物命中乘区问询（_ready 树解析——
                                               # GameLoop Boot 段 relic_handler 先于本系统建并持成员
                                               # 引用；测试无宿主保持 null → 注入零操作零回归）
var _hosts: Array[Node2D] = []                 # 已挂载状态容器的敌人（§1.3-3 白名单：状态宿主）

var _reaction_mults: Dictionary = {}           # source_uid -> mult（ELE_REACTION_VOID ×1.8 聚合）
var _uid_dot: int = 0                          # DOT 结算幂等键 source_uid（分流）
var _uid_chain: int = 0                        # 连锁跳伤 source_uid
var _uid_reaction: int = 0                     # 反应结算 source_uid

# R192-low1（R198）：结算臂级硬默认缺键告警会话一次闸（"rxn|键" → true）——照
# wave_director.gd:43 _empty_comp_errored 先例（一次性旗防同键同帧刷屏；成员域即
# 本系统实例生命周期一次，测试可观测）。
var _rule_missing_warned: Dictionary = {}

# R192：位掩码 → 有序候选短表缓存（静态惰性建——同掩码只扫一次 RXN_ORDER）
static var _mask_candidates: Dictionary = {}


func _init() -> void:
	_uid_dot = GameConst.next_uid()
	_uid_chain = GameConst.next_uid()
	_uid_reaction = GameConst.next_uid()


func _ready() -> void:
	# 点燃蔓延质变（ELE_IGNITE 层 2）：燃烧中的敌死亡 → 半径内传火。★ 连接序纪律（F-19
	# 同源）：本系统在 Boot actors 段先于 EnemySpawner 入树 → 本连接先于 spawner 的死亡
	# 归还订阅 → 派发时 elemental 状态仍在（spawner 的 unregister_host 后执行）
	EventBus.enemy_killed.connect(_on_enemy_killed_spread_burn)
	# R199 D07：遗物乘区问询通道树解析（GameLoop._boot_build_actors 段 relic_handler 于
	# 本系统前置建并赋成员——game_loop.gd:1346→1355；测试环境无 GameLoop 宿主 → 保持
	# null，注入零操作）。照 weapon_base.gd:49 deps 注入同语义，仅取道不同。
	var rh: Variant = get_parent().get("relic_handler") if get_parent() != null else null
	if rh is RelicHandler:
		relic_handler = rh


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


func unregister_reaction_mult(p_source_uid: int) -> void:
	# R183 注销口：僚机复制武器到期回收时撤销其反应乘区（此前全工程零注销——
	# 副本每次施放换新 uid 注册，reaction_mult 全表连乘 → 长局反应伤害无上界滚雪球）
	_reaction_mults.erase(p_source_uid)


func clear_reaction_mults() -> void:
	# R183 局清空：新局/继续局武器全量重建（uid 全换），旧注册全部作废——
	# 开局清表根治既有跨局慢性泄漏（原武器重建换 uid 也只增不减）
	_reaction_mults.clear()


func reaction_mult() -> float:
	# 反应强化聚合（多源连乘；金卡唯一 → 实际单源 ×1.8）
	var product := 1.0
	for key in _reaction_mults:
		product *= float(_reaction_mults[key])
	return product


func apply_attach(p_enemy: Node2D, p_element: int, p_value: float,
		p_info: Dictionary = {}) -> void:
	# 附着入口（§4.4 ⑤）：immune_mask 检查在状态触发位；满槽 → 状态/连锁调度。
	# R22 P1：元素伤害免疫怪拒绝附着（点燃火怪不燃/冰弹不附冰怪）
	if p_enemy != null and is_instance_valid(p_enemy) 			and p_enemy.has_method(&"is_elem_immune") 			and bool(p_enemy.call(&"is_elem_immune", p_element)):
		return
	var state: Variant = p_enemy.get("elemental") if p_enemy != null else null
	if not (state is ElementalState):
		return
	var snapshot := float(p_info.get("snapshot", 0.0))
	var overrides: Dictionary = p_info.get("overrides", {})
	var code: int = (state as ElementalState).apply(p_element, p_value, snapshot, overrides)
	if code != ElementalState.TRIGGER_NONE and p_enemy != null:
		EventBus.emit_state_triggered(code, (p_enemy as Node2D).global_position)
	if code == ElementalState.TRIGGER_SHOCK:
		var hit_damage := float(p_info.get("hit_damage", snapshot))
		if (state as ElementalState).shock_chain_cd <= 0.0:
			_shock_chain(p_enemy, hit_damage, (state as ElementalState).shock_chain_targets)
			(state as ElementalState).shock_chain_cd = 1.0   # 连锁护栏（槽清空外的二次防抖）


func tick(p_game_delta: float) -> void:
	# 全敌：λ 比例衰减（F19/F-22）→ 状态计时 → DOT 跳伤调度 → 绽放爆发 → 超导到期恢复
	# R188 档0：空宿主早退（无敌人帧零分配零遍历）
	if _hosts.is_empty():
		return
	var lambdas: Array[float] = LAMBDA_FALLBACK
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
		if st.consume_bloom_expired():
			_bloom_burst(host, st)               # R192 绽放：延迟 0.75s 到期 AoE 爆发（R198 契约变更 1.5→0.75）
		if st.consume_superconduct_expired():
			_restore_resist(host, st.superconduct_delta)   # M0：按记录 delta 恢复一次（delta 为负记录，恢复取反）


func detect_reactions() -> void:
	# ★ 帧末统一检测（敌人阶段末调用，E-07）：优先级 RXN_ORDER 20 序；一帧一反应（每敌）。
	# R192：检测改元素位掩码 → 有序候选短表（线性 20 检/宿主/帧是被禁形态；掩码表
	# k≤1 宿主零候选——稳态开销与 3 反应期同量级）。CD/清槽/幂等语义不变。
	if _hosts.is_empty():
		return
	var cd_rxn := 2.0
	if GameConfig.balance != null:
		cd_rxn = GameConfig.balance.cd_rxn
	for host in _hosts.duplicate():
		if host == null or bool(host.get("dead")):
			continue
		var state: Variant = host.get("elemental")
		if not (state is ElementalState):
			continue
		var st := state as ElementalState
		var mask := 0
		for i in range(1, st.gauges.size()):
			if st.gauges[i] > 0.0:
				mask |= 1 << i
		if mask == 0 or (mask & (mask - 1)) == 0:
			continue                             # k≤1：无配对可能，零候选短路
		for rxn in _candidates_for(mask):
			if float(st.reaction_cd.get(rxn, 0.0)) > 0.0:
				continue
			if not _reaction_condition(st, rxn):
				continue
			st.reaction_cd[rxn] = cd_rxn
			_trigger_reaction(host, st, rxn)
			break                                 # 一帧一反应


# ── 内部 ──────────────────────────────────────────────────────────
static func _candidates_for(p_mask: int) -> Array:
	# 有序候选短表（R192）：掩码内双元素齐备的反应候选，RXN_ORDER 序；静态缓存
	var cached: Variant = _mask_candidates.get(p_mask)
	if cached != null:
		return cached
	var rows: Array = []
	for rxn in RXN_ORDER:
		var pair: Array = RXN_PAIRS[rxn]
		var need := (1 << int(pair[0])) | (1 << int(pair[1]))
		if (p_mask & need) == need:
			rows.append(rxn)
	_mask_candidates[p_mask] = rows
	return rows


func _reaction_condition(p_state: ElementalState, p_rxn: int) -> bool:
	# 两两反应触发条件：双槽附着量均非零（B_spec §2.4）——配对真源 RXN_PAIRS 20 键
	var pair: Variant = RXN_PAIRS.get(p_rxn)
	if pair is Array and (pair as Array).size() == 2:
		return p_state.has_both(int((pair as Array)[0]), int((pair as Array)[1]))
	return false


func _trigger_reaction(p_enemy: Node2D, p_state: ElementalState, p_rxn: int) -> void:
	# R192 反应结算核（20 臂模板化）：管线结算通道（碎裂/过载/蒸发/绽放/扩散）由
	# pipeline.resolve_reaction 广播 reaction_triggered；纯减益/工具通道（超导/冻结/
	# 感电/燃烧/激化/结晶）无 DamageResult → 此处直接广播。全臂收口：清双槽契约。
	var tables: Dictionary = {}
	if GameConfig.balance != null:
		tables = GameConfig.balance.reaction_table
	var rm := reaction_mult()
	var enemy_uid := int(p_enemy.get("uid"))
	var rule: Dictionary = _rxn_rule(tables, p_rxn)
	var pair: Array = RXN_PAIRS[p_rxn]
	var elem_a := int(pair[0])
	var elem_b := int(pair[1])
	match p_rxn:
		GameConst.ReactionType.RXN_FIR_ICE:
			# 碎裂（融化）：×2.0 × 点燃剩余 DOT 总额（独立结算，清双槽 + 燃尽）
			var base := p_state.remaining_dot_total()
			var coef := _rule_num(rule, p_rxn, "coef", 2.0) * rm
			_settle_reaction(p_enemy, base, coef, GameConst.ReactionType.RXN_FIR_ICE)
			p_state.clear_element(elem_a)
			p_state.clear_element(elem_b)
			p_state.burn_timer = 0.0            # 融化消耗剩余 DOT
			p_state.burn_layers = 0
		GameConst.ReactionType.RXN_FIR_HYD:
			# 蒸发：即时快照 ×1.5 × S_snap（不掷暴击；管线结算通道）
			var coef_h := _rule_num(rule, p_rxn, "coef", 1.5) * rm
			_settle_reaction(p_enemy, p_state.last_attach_snapshot, coef_h,
				GameConst.ReactionType.RXN_FIR_HYD)
			p_state.clear_element(elem_a)
			p_state.clear_element(elem_b)
		GameConst.ReactionType.RXN_HYD_DEN:
			# 绽放：延迟 AoE（delay 0.75s 后 χ1.5 r120 爆发——调度在 tick 绽放消费臂；
			# R192-low6/R198 契约变更：delay 1.5→0.75，表 .gd/.tres 双源同批 + 硬默认同步）
			# 触发即清双槽（爆发时主目标槽已空，副目标半径内落血）
			p_state.arm_bloom(_rule_num(rule, p_rxn, "delay", 0.75), p_state.last_attach_snapshot)
			p_state.clear_element(elem_a)
			p_state.clear_element(elem_b)
		GameConst.ReactionType.RXN_FIR_LTG:
			# 过载：120% ATK × 反应强化，半径 90 爆炸（主目标 + 半径内扩散）
			var snapshot := p_state.last_attach_snapshot
			var coef2 := _rule_num(rule, p_rxn, "coef", 1.2) * rm
			var radius := _rule_num(rule, p_rxn, "radius", 90.0)
			_settle_reaction(p_enemy, snapshot, coef2, GameConst.ReactionType.RXN_FIR_LTG)
			_spread_reaction(p_enemy, radius, snapshot, coef2, GameConst.ReactionType.RXN_FIR_LTG)
			p_state.clear_element(elem_a)
			p_state.clear_element(elem_b)
		GameConst.ReactionType.RXN_FIR_ANE, GameConst.ReactionType.RXN_ICE_ANE, \
		GameConst.ReactionType.RXN_LTG_ANE, GameConst.ReactionType.RXN_HYD_ANE, \
		GameConst.ReactionType.RXN_ANE_DEN:
			# 扩散族×5：主目标直伤 χ0.8×S_snap + 半径 120 内至多 3 敌满槽转移被扩元素
			#（转移元素 = pair[0]，A 位语义见 RXN_PAIRS 注——RXN_ANE_DEN 转移草非风；
			# 照燎原传火——转移物为后续反应燃料）；ANEMO 槽 + 被扩槽全清
			var snapshot_s := p_state.last_attach_snapshot
			var coef_s := _rule_num(rule, p_rxn, "coef", 0.8) * rm
			_settle_reaction(p_enemy, snapshot_s, coef_s, p_rxn)
			_spread_attach(p_enemy, _rule_num(rule, p_rxn, "radius", 120.0),
				int(_rule_num(rule, p_rxn, "targets", 3.0)), snapshot_s, elem_a)
			p_state.clear_element(elem_a)
			p_state.clear_element(elem_b)
		GameConst.ReactionType.RXN_ICE_HYD:
			# 冻结：完全冻结 1.2s + 寒滞 2.5s + 易伤 ×1.25 3s（复用既有 freeze/chill/
			# vuln 字段刷新不改键；IMMUNE_FREEZE 拒定身仍吃寒滞/易伤——F-17 Boss 口径）。
			# R192-low2（R198）：寒滞/易伤/冻结三写前置 IMMUNE_CHILL 检位整段跳过——镜像
			# 附着段先例（elemental_state.gd ICE 臂「冰免疫怪整段不吃寒滞/易伤/冻结」同族
			# 口径：反应通道此前裸奔，冰免疫怪吃冻结反应照样被控）；IMMUNE_FREEZE 半边
			# 语义不变（非寒滞免疫目标仍拒定身吃寒滞/易伤）。
			# :310-312 清槽与 reaction_triggered 广播保持无条件（消费契约不受免疫影响）。
			if (p_state.immune_mask & GameConst.IMMUNE_CHILL) == 0:
				if (p_state.immune_mask & GameConst.IMMUNE_FREEZE) == 0:
					p_state.freeze_timer = _rule_num(rule, p_rxn, "freeze_dur", 1.2)
				p_state.chill_timer = _rule_num(rule, p_rxn, "chill_dur", 2.5)
				p_state.vuln_mult = _rule_num(rule, p_rxn, "vuln_mult", 1.25)
				p_state.vuln_timer = _rule_num(rule, p_rxn, "vuln_dur", 3.0)
			p_state.clear_element(elem_a)
			p_state.clear_element(elem_b)
			EventBus.emit_reaction_triggered(p_rxn, (p_enemy as Node2D).global_position, enemy_uid)
		GameConst.ReactionType.RXN_LTG_HYD:
			# 感电：连锁（读 element_states.shock 全套 3 目标/160px/35%/深 2）+
			# shock_chain_cd=1.0 护栏（零新字段；快照基数 = 最近附着面板）
			if p_state.shock_chain_cd <= 0.0:
				_shock_chain(p_enemy, p_state.last_attach_snapshot, p_state.shock_chain_targets)
				p_state.shock_chain_cd = 1.0
			p_state.clear_element(elem_a)
			p_state.clear_element(elem_b)
			EventBus.emit_reaction_triggered(p_rxn, (p_enemy as Node2D).global_position, enemy_uid)
		GameConst.ReactionType.RXN_FIR_DEN:
			# 燃烧：立即满层点燃（burn_layers_max 5 · burn_dur 3s，快照 = 最近附着）；
			# 无 χ 不进结算管线（DOT 跳伤由既有 _dot_tick 通道承担）
			if (p_state.immune_mask & GameConst.IMMUNE_BURN) == 0:
				p_state.burn_layers = int(_rule_num(rule, p_rxn, "burn_layers_max", 5.0))
				p_state.burn_timer = _rule_num(rule, p_rxn, "burn_dur", 3.0)
				p_state.burn_snapshot_atk = p_state.last_attach_snapshot
				p_state.burn_tick = 0.5
				p_state.dot_tick_left = p_state.burn_tick
			p_state.clear_element(elem_a)
			p_state.clear_element(elem_b)
			EventBus.emit_reaction_triggered(p_rxn, (p_enemy as Node2D).global_position, enemy_uid)
		GameConst.ReactionType.RXN_LTG_DEN:
			# 激化：纯减益——易伤 ×1.25 3s（复用 vuln 池刷新；无 χ）
			p_state.vuln_mult = _rule_num(rule, p_rxn, "vuln_mult", 1.25)
			p_state.vuln_timer = _rule_num(rule, p_rxn, "vuln_dur", 3.0)
			p_state.clear_element(elem_a)
			p_state.clear_element(elem_b)
			EventBus.emit_reaction_triggered(p_rxn, (p_enemy as Node2D).global_position, enemy_uid)
		GameConst.ReactionType.RXN_ICE_LTG:
			# 超导：全抗 −30%（可击破至负值），持续 6s（纯减益；M0：账本记 delta）。
			# M0 账本不对称修复（R192 §6.1）：削抗只在首触落账——激活期重触只刷新
			# superconduct_left（apply_superconduct 内部），不重复 _apply_resist_delta；
			# 到期由 tick 恢复臂按记录 delta 恢复恰一次 → 持续期 N 次重触净恢复 0。
			var delta := _rule_num(rule, p_rxn, "resist_delta", -0.3)
			var duration := _rule_num(rule, p_rxn, "duration", 6.0)
			if not p_state.superconduct_active:
				_apply_resist_delta(p_enemy, delta)
			p_state.apply_superconduct(delta, duration)
			p_state.clear_element(elem_a)
			p_state.clear_element(elem_b)
			EventBus.emit_reaction_triggered(GameConst.ReactionType.RXN_ICE_LTG,
				(p_enemy as Node2D).global_position, enemy_uid)
			DebugStats.count(&"reaction_supercoduct")
		GameConst.ReactionType.RXN_FIR_GEO, GameConst.ReactionType.RXN_ICE_GEO, \
		GameConst.ReactionType.RXN_LTG_GEO, GameConst.ReactionType.RXN_HYD_GEO, \
		GameConst.ReactionType.RXN_DEN_GEO, GameConst.ReactionType.RXN_ANE_GEO:
			# 结晶族×6：玩家获 15% 减伤 6s（刷新不叠加；dr 闸在 Player.take_contact_damage
			# 唯一漏斗——无敌帧/格挡闸后 HP 直减前；纯会话态零存档）
			EventBus.emit_crystal_shield_request(
				_rule_num(rule, p_rxn, "dr", 0.15), _rule_num(rule, p_rxn, "dr_dur", 6.0))
			p_state.clear_element(elem_a)
			p_state.clear_element(elem_b)
			EventBus.emit_reaction_triggered(p_rxn, (p_enemy as Node2D).global_position, enemy_uid)
	DebugStats.count(&"reaction_triggered")


func _rxn_rule(p_tables: Dictionary, p_rxn: int) -> Dictionary:
	# 反应表行读取：表键 = 枚举成员名（id 契约 §3 逐字对应——零字符串第二真源）
	for key in GameConst.ReactionType:
		if int(GameConst.ReactionType[key]) == p_rxn:
			return p_tables.get(String(key), {})
	return {}


func _rule_num(p_rule: Dictionary, p_rxn: int, p_key: String, p_default: float) -> float:
	# R192-low1（R198）：结算臂取键守卫——各臂不再裸 rule.get 硬默认（表残缺静默不可见），
	# 缺键 push_warning 会话一次（每 rxn×键恰一条，防同帧刷屏），仍回落默认值不中断
	# 结算（表残缺 ≠ 玩家可感的结算崩溃）。合法无键规则（感电 RXN_LTG_HYD = {}）不入
	# 各臂取键路径 → 零误报。
	var gate := "%d|%s" % [p_rxn, p_key]
	if not p_rule.has(p_key):
		if not _rule_missing_warned.has(gate):
			_rule_missing_warned[gate] = true
			push_warning("[ElementalSystem] reaction_table %s 缺键 \"%s\"（回落默认 %s，结算不中断——R192-low1）"
				% [String(GameConst.ReactionType.find_key(p_rxn)), p_key, String.num(p_default, 3)])
		return p_default
	return float(p_rule[p_key])


func _settle_reaction(p_enemy: Node2D, p_snapshot: float, p_coef: float, p_rxn: int) -> void:
	# 反应独立结算（F20/F21：D = χ×φ×S_snap；HIT_IS_REACTION 不掷暴击）
	# R199 D07：结算前注入遗物命中乘区（玻璃大炮「全部伤害 +40%」等照直击通道同权）。
	# resolve_reaction 为快照独立通道不走⑤乘区聚合（damage_pipeline.gd:87-130 空聚合占位）
	# ——管线外折算：注入池经 ModifierStack.aggregate_mults（管线⑤同款语义：单区 cap/
	# 名额/整体钳）聚合为乘积乘入系数 χ；真/桩两路同折（桩路折进面板口径）。
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
	_inject_relic_pools(ctx, p_enemy)
	var relic_mult := _relic_pool_product(ctx)
	var eff_coef := p_coef * relic_mult
	var result: DamageResult = null
	if pipeline is DamagePipeline:
		result = (pipeline as DamagePipeline).resolve_reaction(p_snapshot, eff_coef, ctx)
	elif pipeline.has_method(&"resolve_reaction"):
		# 桩路径适配（接口差异：桩单参签名，系数折算进面板）
		ctx.base_atk = p_snapshot * eff_coef
		result = pipeline.call(&"resolve_reaction", ctx)
	if result != null:
		DebugStats.count(&"reaction_settled")


func _inject_relic_pools(p_ctx: DamageContext, p_target: Node2D) -> void:
	# R199 D07：元素结算通道（DOT/连锁/反应）遗物命中乘区注入——照 WeaponBase.
	# inject_relic_pools 先例（weapon_base.gd:466 → relic_handler.inject_hit_mult_pools）。
	# 玻璃大炮「全部伤害 +40%」卡面承诺自此覆盖元素流；猎首者/连杀狂热/双重节拍同通道
	# 受益（owned 守卫在问询侧，无遗物零操作；has_mult_pool 去重防同 ctx 重注）。
	if relic_handler != null:
		relic_handler.inject_hit_mult_pools(p_ctx, p_target)


func _relic_pool_product(p_ctx: DamageContext) -> float:
	# R199 D07：反应通道乘区折算——注入池经 ModifierStack.aggregate_mults（管线⑤冻结
	# 语义单源调用，零第二份聚合实现）得 product_clamped；空池恒 1.0。
	if p_ctx.mult_pools.is_empty():
		return 1.0
	var cap_mul_count := 8
	var cap_prod := 8.0
	if GameConfig.balance != null:
		cap_mul_count = GameConfig.balance.cap_mul_count
		cap_prod = GameConfig.balance.cap_prod
	var stack := ModifierStack.new()
	stack.aggregate_mults(p_ctx.mult_pools, cap_mul_count, cap_prod)
	return stack.product_clamped


func _spread_reaction(p_center: Node2D, p_radius: float, p_snapshot: float, p_coef: float,
		p_rxn: int) -> void:
	# 反应半径扩散：圆查询逐敌独立结算（去中心；同帧幂等键分流独立 uid）。
	# R192：rxn 参数化（过载/绽放到期爆发共用——去 RXN_FIR_LTG 硬编码）。
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
		_settle_reaction(cand, p_snapshot, p_coef, p_rxn)


func _spread_attach(p_center: Node2D, p_radius: float, p_targets: int, p_snapshot: float,
		p_element: int) -> void:
	# R192 扩散族满槽转移（族模板）：半径内最近至多 p_targets 只敌满槽附着被扩元素
	#（照燎原传火 apply_attach(cand,X,GAUGE_MAX,{snapshot})——附着保留为反应燃料）。
	# 候选 append_array 拷贝（满槽雷转移可嵌套 _shock_chain 复用网格内部缓冲——
	# space_grid.gd:74 明示返回引用）；去中心 + hitbox_r 窄相。
	if enemy_grid == null or p_targets <= 0:
		return
	var center: Vector2 = (p_center as Node2D).global_position
	var candidates: Array[Node2D] = []
	candidates.append_array(enemy_grid.query_circle(center, p_radius))
	var dedup: Dictionary = {int(p_center.get("uid")): true}
	var rows: Array = []
	for cand in candidates:
		if bool(cand.get("dead")) or dedup.has(int(cand.get("uid"))):
			continue
		var hr: Variant = cand.get("hitbox_r")
		var reach := p_radius + (float(hr) if hr != null else 0.0)
		if (cand as Node2D).global_position.distance_to(center) > reach:
			continue
		rows.append([center.distance_squared_to((cand as Node2D).global_position), cand])
	rows.sort_custom(func(a, b) -> bool: return float(a[0]) < float(b[0]))
	var transferred := 0
	for row in rows:
		if transferred >= p_targets:
			break
		var cand: Node2D = row[1]
		apply_attach(cand, p_element, ElementalState.GAUGE_MAX, {"snapshot": p_snapshot})
		transferred += 1


func _bloom_burst(p_enemy: Node2D, p_state: ElementalState) -> void:
	# R192 绽放到期爆发：χ1.5×S_snap 主目标落血 + r120 半径扩散（管线结算通道广播）。
	# 触发期已清双槽 + 登记 reaction_cd——此处纯结算零槽位副作用。
	var tables: Dictionary = {}
	if GameConfig.balance != null:
		tables = GameConfig.balance.reaction_table
	var rule: Dictionary = _rxn_rule(tables, GameConst.ReactionType.RXN_HYD_DEN)
	var coef := _rule_num(rule, GameConst.ReactionType.RXN_HYD_DEN, "coef", 1.5) * reaction_mult()
	var radius := _rule_num(rule, GameConst.ReactionType.RXN_HYD_DEN, "radius", 120.0)
	var snapshot := p_state.bloom_snapshot_atk
	p_state.bloom_snapshot_atk = 0.0
	_settle_reaction(p_enemy, snapshot, coef, GameConst.ReactionType.RXN_HYD_DEN)
	_spread_reaction(p_enemy, radius, snapshot, coef, GameConst.ReactionType.RXN_HYD_DEN)
	DebugStats.count(&"reaction_bloom_burst")


func _dot_tick(p_enemy: Node2D, p_state: ElementalState) -> void:
	# DOT 跳伤：15%ATK 面板快照 × 层数（HIT_IS_DOT 不掷暴击；走管线主通道）。
	# 保底 ≥1/层（2026-08-31 用户反馈「烧伤 0」根因修复：早期武器快照 ~6-12 → 15% = 0.9~1.8/
	# 跳，round 后 0~2 观感即「烧伤 0」——第一关怪火抗全 0 非抗性问题，是纯数值展示问题；
	# 保底后每层每跳至少烧 1，火卡前期即可读）
	if pipeline == null:
		return
	while p_state.consume_dot_due():
		var dot := maxf(p_state.burn_dot_ratio * p_state.burn_snapshot_atk
			* float(p_state.burn_layers), float(p_state.burn_layers))
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
		_inject_relic_pools(ctx, p_enemy)       # R199 D07：DOT 通道遗物乘区（管线⑤主通道直消费）
		if pipeline.has_method(&"resolve"):
			pipeline.call(&"resolve", ctx)
		EventBus.emit_elemental_dot_fired((p_enemy as Node2D).global_position)   # 表现层火星
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
				# 表现层专用广播（签名特效：主锯齿闪电；只读两端位置，零结算时序影响）
				EventBus.emit_chain_lightning((node as Node2D).global_position,
					(target as Node2D).global_position)
				next_frontier.append(target)
		if next_frontier.is_empty():
			break
		frontier = next_frontier
		damage *= _shock_decay_of(p_origin)       # 每跳衰减（ELE_SHOCK 层 2 质变 → 0.75）


func _shock_decay_of(p_origin: Node2D) -> float:
	# 感电每跳衰减：宿主状态覆写优先（层 2 质变 0.75）→ 配置默认 0.6
	var st: Variant = p_origin.get("elemental")
	if st is ElementalState:
		return maxf((st as ElementalState).shock_chain_decay, 0.1)
	return 0.6


func _on_enemy_killed_spread_burn(p_enemy: Node2D) -> void:
	# 点燃蔓延（ELE_IGNITE 层 2 质变「燎原」）：燃烧中的敌死亡 → 半径内至多 3 只敌直接
	# 满槽点燃（快照继承原燃烧者——火种传递）。表现：原点橙色冲击环 + 各点燃点火星。
	# 无蔓延半径（0/未投资层 2）→ 零开销短路
	if enemy_grid == null:
		return
	var st: Variant = p_enemy.get("elemental")
	if not (st is ElementalState):
		return
	var s := st as ElementalState
	if s.burn_timer <= 0.0 or s.burn_spread_radius <= 0.0:
		return
	var pos: Vector2 = (p_enemy as Node2D).global_position
	var radius := s.burn_spread_radius
	var spread := 0
	for cand in enemy_grid.query_circle(pos, radius):
		if cand == p_enemy or bool(cand.get("dead")):
			continue
		if pos.distance_to((cand as Node2D).global_position) > radius:
			continue
		apply_attach(cand, GameConst.Element.FIR, ElementalState.GAUGE_MAX,
			{"snapshot": s.burn_snapshot_atk})
		EventBus.emit_elemental_dot_fired((cand as Node2D).global_position)
		spread += 1
		if spread >= 3:
			break
	if spread > 0:
		# R199 F17：传火是质变点燃不是配对反应——改发独立表现通道（原点橙环由
		# elemental_fx_layer 订阅绘制），不再冒用 reaction_triggered(RXN_FIR_ICE)
		# 污染 Meta 反应成就计数与图鉴「已触发」存档（meta_manager 消费口语义不变）
		EventBus.emit_burn_spread_ignited(pos)
		DebugStats.count(&"burn_spread")


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
	_inject_relic_pools(ctx, p_target)          # R199 D07：连锁通道遗物乘区（管线⑤主通道直消费）
	if pipeline.has_method(&"resolve"):
		pipeline.call(&"resolve", ctx)
	DebugStats.count(&"shock_chain_jump")


func _apply_resist_delta(p_enemy: Node2D, p_delta: float) -> void:
	# 超导削抗：全抗 +p_delta（−0.3；可击破至负值 = 增伤），钳制 [−0.8, 0.8]
	var resist: Variant = p_enemy.get("resist")
	if resist is Array:
		for i in range((resist as Array).size()):
			(resist as Array)[i] = clampf(float((resist as Array)[i]) + p_delta, -0.8, 0.8)


func _restore_resist(p_enemy: Node2D, p_delta: float) -> void:
	# 超导到期：按 apply_superconduct 记录的 delta 全抗恢复一次（M0 账本——
	# 记录值为负向削幅（−0.3），恢复取反施加（+0.3，钳制同界）；持续期 N 次重触
	# 只刷新时长 → 恢复恰一次净 0，原 +0.3 硬编码与削抗幅度解耦的失真就此修复）
	_apply_resist_delta(p_enemy, -p_delta)
