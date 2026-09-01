# scripts/combat/trait/trait_stack.gd
# M-10 TraitStack（架构 §2.9.3，引擎核心）。
# · 挂载序 = 派发序（确定性，AC-07.2）；同 ID 叠层 / 新建；单栈词条上限 MAX_TRAITS=12。
# · 链式深度 3 熔断（>3 → chain_fused 事件 + 计数，M-10）+ 同事件重入保护（E-03）。
# · copy_runtime：武器主栈 → 投射物/光束运行时栈（全定义复制 + 运行时重置；
#   定义引用复制非深拷贝，E-13）。
# · copy_for_split：F-13 分裂继承——inheritable 定义复制 + 运行时状态重置；
#   TH_FRACTAL_ECHO（深度 ≥3）扩展至乘区词条（含乘区，定义复制子代自评）。
class_name TraitStack
extends RefCounted

const MAX_CHAIN_DEPTH: int = 3                # 链式反应深度上限（B_spec M-10）
const MAX_TRAITS: int = 12                    # 单投射物词条上限（B_spec §1.2）
# 整数语义加算池（线性全额，不走 F3 衰减：穿透/弹丸数为整数增量）
const LINEAR_ADD_POOLS: Array[StringName] = [&"add_pierce", &"add_pellets"]

var traits: Array[TraitBase] = []             # 挂载序 = 派发序（确定性，AC-07.2）
var _depth: int = 0                           # 当前派发链深度
var _dispatching: bool = false
var _current_event: int = -1                  # 重入保护：同事件递归派发拦截
var _fused_count: int = 0                     # 熔断计数


func attach(p_data: TraitData) -> bool:
	# 挂载：同 ID 叠层（至 stack_max）/ 新建；超 12 拒绝 + 计数
	if p_data == null:
		return false
	for mounted in traits:
		if mounted.data.id == p_data.id:
			if mounted.layers >= p_data.stack_max:
				DebugStats.count(&"trait_attach_rejected_stack")
				return false
			mounted.layers += 1
			return true
	if traits.size() >= MAX_TRAITS:
		DebugStats.count(&"trait_attach_rejected_max")
		return false
	var instance := TraitBase.new()
	instance.setup(p_data)
	traits.append(instance)
	return true


func dispatch(p_event: int, p_ctx: TraitContext) -> bool:
	# ★ 按挂载序派发；同事件重入拦截；深度+1，>3 熔断 + chain_fused（M-10/E-03）
	if traits.is_empty():
		return false
	if _dispatching and p_event == _current_event:
		DebugStats.count(&"trait_reentry_blocked")
		return false                        # 重入保护：同事件递归派发拦截
	_depth += 1
	if _depth > MAX_CHAIN_DEPTH:
		_fused_count += 1
		DebugStats.count(&"trait_chain_fused")
		EventBus.emit_chain_fused(_depth, &"")
		_depth -= 1
		return false                        # 链式深度熔断
	var prev_event := _current_event
	var prev_dispatching := _dispatching
	_current_event = p_event
	_dispatching = true
	for mounted in traits:
		mounted.on_event(p_event, p_ctx)    # 挂载序 = 派发序（AC-07.2）
	_dispatching = prev_dispatching
	_current_event = prev_event
	_depth -= 1
	return true


func copy_runtime() -> TraitStack:
	# 武器主栈 → 投射物/光束运行时栈：全定义复制（引用复制非深拷贝，E-13）+ 运行时重置
	var out := TraitStack.new()
	for mounted in traits:
		out.traits.append(_clone_trait(mounted))
	return out


func copy_for_split(p_generation: int, p_echo: bool = false) -> TraitStack:
	# F-13：inheritable 定义复制 + 运行时状态重置（引用复制非深拷贝，E-13）。
	# 分裂词条自身默认 false（E-01——否则指数裂变）；p_echo（TH_FRACTAL_ECHO，深度 ≥3）
	# 扩展至乘区词条：定义复制、子代条件自评、独立过护栏。
	var out := TraitStack.new()
	for mounted in traits:
		var inherit: bool = mounted.data.inheritable
		if not inherit and p_echo and mounted.data.pool == GameConst.PoolClass.MULT:
			inherit = true
		if not inherit:
			continue
		out.traits.append(_clone_trait(mounted))
	return out


func collect_mult_pools(p_ctx: TraitContext) -> Array[Dictionary]:
	# §4.4 ② 乘区预聚合：MULT 池词条条件自评 → {pool_id, source_uid, contrib, cap_pool, priority}
	var out: Array[Dictionary] = []
	var source_uid := 0
	if p_ctx.projectile != null:
		source_uid = p_ctx.projectile.uid
	elif p_ctx.beam != null:
		source_uid = p_ctx.beam.uid
	elif p_ctx.weapon != null:
		source_uid = p_ctx.weapon.uid
	for mounted in traits:
		if mounted.data.pool != GameConst.PoolClass.MULT:
			continue
		var contrib := mounted.get_contribution(p_ctx)
		if contrib == 0.0:
			continue                        # 条件不满足 → 该区不注入
		out.append({
			"pool_id": mounted.data.pool_id,
			"source_uid": source_uid,
			"contrib": contrib,
			"cap_pool": mounted.data.cap_pool_p,
			"priority": 0,
		})
	return out


func aggregate_panel() -> Dictionary:
	# 常驻加算聚合（build ctx 时求值）：pool_id → 有效和（F3 衰减 / 整数池线性全额）
	var sums: Dictionary = {}
	for mounted in traits:
		if mounted.data.pool != GameConst.PoolClass.ADD:
			continue
		var pool_id: StringName = mounted.data.pool_id
		var effective := 0.0
		if LINEAR_ADD_POOLS.has(pool_id):
			effective = mounted.data.value * float(mounted.layers)
		else:
			effective = decay_sum(mounted.data.value, mounted.layers, mounted.data.decay_delta)
		sums[pool_id] = float(sums.get(pool_id, 0.0)) + effective
	return sums


func aggregate_add_entries() -> Array[Dictionary]:
	# add_atk 池 → DamageContext.add_entries（管线步骤 3 F3 衰减真源；面板段唯一入列池）。
	# v0.8.0：is_curse 判定单源 is_curse_trait（params.is_curse 退役装饰）
	var out: Array[Dictionary] = []
	for mounted in traits:
		if mounted.data.pool != GameConst.PoolClass.ADD:
			continue
		if mounted.data.pool_id != &"add_atk":
			continue
		out.append({
			"trait_id": mounted.data.id,
			"pool_id": mounted.data.pool_id,
			"layer": mounted.layers,
			"contrib": mounted.data.value,
			"decay_delta": mounted.data.decay_delta,
			"is_curse": is_curse_trait(mounted.data),
		})
	return out


# ── v0.8.0 V9 词条移除（商店移除/净化仲裁底座） ───────────────────
static func is_curse_trait(p_data: TraitData) -> bool:
	# ★ 诅咒词条唯一判定：ADD 池 + 负贡献（value<0）。params.is_curse 退役装饰——
	# aggregate_add_entries / peek_last / detach_last 全部经此单源。
	return p_data != null and p_data.pool == GameConst.PoolClass.ADD and p_data.value < 0.0


func peek_last(p_skip_curse: bool) -> Dictionary:
	# 末位词条窥视（不移除）：p_skip_curse=true 跳过诅咒词条（V9 移除口径——只摘非诅咒）。
	# 空栈 / 全被跳过 → {ok:false}。
	for i in range(traits.size() - 1, -1, -1):
		var mounted := traits[i]
		if p_skip_curse and is_curse_trait(mounted.data):
			continue
		return _peek_dict(mounted)
	return _empty_peek()


func detach_last(p_skip_curse: bool) -> Dictionary:
	# 末位词条摘层：p_skip_curse=true 跳过诅咒词条；layers−1，0 摘实例（挂载序保持）。
	# 调用方负责宿主武器 invalidate_panel()。空栈 / 全被跳过 → {ok:false}。
	for i in range(traits.size() - 1, -1, -1):
		var mounted := traits[i]
		if p_skip_curse and is_curse_trait(mounted.data):
			continue
		return _detach_at(i, 1)
	return _empty_peek()


func detach_by_id(p_trait_id: StringName, p_layers: int = 1) -> Dictionary:
	# 同 id 词条摘层（末次挂载优先；净化 GAMBLER_CURSE 消费口）。无命中 / 已无层 → {ok:false}。
	for i in range(traits.size() - 1, -1, -1):
		var mounted := traits[i]
		if mounted.data.id != p_trait_id or mounted.layers <= 0:
			continue
		var actual: int = mini(p_layers, mounted.layers)
		if actual <= 0:
			continue
		return _detach_at(i, actual)
	return _empty_peek()


# ── 内部：摘层共享底座 ────────────────────────────────────────────
func _detach_at(p_index: int, p_layers: int) -> Dictionary:
	# 摘层单点（peek/detach_last/detach_by_id 共用）：layers−n，0 摘实例（保持挂载序）
	var mounted := traits[p_index]
	mounted.layers = maxi(mounted.layers - p_layers, 0)
	if mounted.layers == 0:
		traits.remove_at(p_index)
	var out := _peek_dict(mounted)
	out["ok"] = true
	out["layers_left"] = mounted.layers
	out.erase("layers")
	return out


func _peek_dict(p_mounted: TraitBase) -> Dictionary:
	return {
		"ok": true,
		"trait_id": p_mounted.data.id,
		"display_name": p_mounted.data.display_name,
		"layers": p_mounted.layers,
		"value": p_mounted.data.value,
		"pool_id": p_mounted.data.pool_id,
		"is_curse": is_curse_trait(p_mounted.data),
	}


func _empty_peek() -> Dictionary:
	return {
		"ok": false,
		"trait_id": &"",
		"display_name": "",
		"layers": 0,
		"value": 0.0,
		"pool_id": &"",
		"is_curse": false,
	}


func advance_cooldowns(p_game_delta: float) -> void:
	# 词条触发冷却推进（宿主 tick 期调用）
	for mounted in traits:
		if mounted.cooldown_left > 0.0:
			mounted.cooldown_left = maxf(mounted.cooldown_left - p_game_delta, 0.0)


func clear() -> void:
	# 归还清零（池断言前置）
	traits.clear()
	_depth = 0
	_dispatching = false
	_current_event = -1


func is_empty() -> bool:
	return traits.is_empty()


func size() -> int:
	return traits.size()


func fused_count() -> int:
	return _fused_count


static func decay_sum(p_value: float, p_layers: int, p_delta: float) -> float:
	# F3：T(n) = c × (1−δ^n)/(1−δ)；首层全额；δ≥1 退化为线性（校验层已拦 δ>0.92）。
	# 与管线 ModifierStack._effective_add 同式——本静态供面板/参数侧预览聚合。
	if p_layers <= 0:
		return 0.0
	if p_layers == 1:
		return p_value
	if p_delta >= 1.0:
		return p_value * float(p_layers)
	return p_value * (1.0 - pow(p_delta, float(p_layers))) / (1.0 - p_delta)


static func _clone_trait(p_source: TraitBase) -> TraitBase:
	# 定义引用复制 + 层数保留 + 运行时状态重置（E-13：非深拷贝——TraitData 共享只读）
	var instance := TraitBase.new()
	instance.setup(p_source.data)
	instance.layers = p_source.layers
	return instance
