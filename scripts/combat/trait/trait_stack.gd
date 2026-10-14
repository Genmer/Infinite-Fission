# scripts/combat/trait/trait_stack.gd
# M-10 TraitStack（架构 §2.9.3，引擎核心）。
# · 挂载序 = 派发序（确定性，AC-07.2）；同 ID 叠层 / 新建；单栈词条上限 MAX_TRAITS=12。
# · 链式深度 3 熔断（>3 → chain_fused 事件 + 计数，M-10）+ 同事件重入保护（E-03）。
# · copy_runtime：武器主栈 → 投射物/光束运行时栈（全定义复制 + 运行时重置；
#   定义引用复制非深拷贝，E-13）。
# · copy_for_split：F-13 分裂继承——inheritable 定义复制 + 运行时状态重置；
#   TH_FRACTAL_ECHO（深度 ≥3）扩展至乘区词条（含乘区，定义复制子代自评）。
# · R220 刀5 运行栈池化：acquire_runtime/release_to_pool 借还对（copy_runtime 的池化
#   升级——开关 POOLING_ENABLED=false=每次 new 原路径逐位等价）。主栈三失效面
#   （①选卡 attach ②MILESTONE 质变 value_mult ③MULT/ELE 取优换定义）统一经
#   bump_runtime_generation 世代失效——借出件按旧世代克隆的（词条集/×1.6 乘区/定义
#   已陈旧）在借出时弃件重建（trait_pool_discarded 通用通道计数），防「新弹带旧栈」。
class_name TraitStack
extends RefCounted

const MAX_CHAIN_DEPTH: int = 3                # 链式反应深度上限（B_spec M-10）
const MAX_TRAITS: int = 12                    # 单投射物词条上限（B_spec §1.2）
# 整数语义加算池（线性全额，不走 F3 衰减：穿透/弹丸数为整数增量）
const LINEAR_ADD_POOLS: Array[StringName] = [&"add_pierce", &"add_pellets"]
# R196 超质变叠层（有意契约变更——原「至 stack_max 拒绝」，测试断言改动须落 R196 注释）：
# R226 有意契约变更（用户拍板「肉鸽别搞上限，就是给人爽叠的」）：叠层帽与 ×0.7 超帽衰减
# 全量拆除——所有池无限叠、每层全额（OVERCAP_VALUE_MULT/OVERCAP_EXT_MAX 两常量退役删除）。
# stack_max 语义收窄为「满层质变里程碑触发点」（WeaponBase.attach_trait：达层 ×1.6 一次性
# 奖励 + 金色 toast，幂等）；构筑宽度帽 MAX_TRAITS=12（词条种类数）保留不动——与同种叠层
# 不同轴，且受构筑面板 UI 承载限制（用户点名再扩）。

var traits: Array[TraitBase] = []             # 挂载序 = 派发序（确定性，AC-07.2）
var _depth: int = 0                           # 当前派发链深度
var _dispatching: bool = false
var _current_event: int = -1                  # 重入保护：同事件递归派发拦截
var _fused_count: int = 0                     # 熔断计数
var _hooked_cache: Dictionary = {}            # R210 event→bool 静态挂钩缓存（attach/clear 失效）

# ── R220 刀5：运行栈池化借还（主栈侧借出池 + 运行栈侧归池回指） ──────────
static var POOLING_ENABLED: bool = true       # 池化开关（R220 修轮开启：弹侧归还口
                                              # （projectile_base._reset_state/_recycle）已合入，
                                              # 契约 §6.1 落地序前置满足——刀5 收益（火段对齐帧
                                              # 主构成）产品侧兑现；false=每次 new 原路径=回滚开关）
# ── R232 刀1c：MULT 乘区贡献缓存（回滚开关） ─────────────────────────
# 「静态贡献缓存 × 条件活评」：贡献值是词条数据纯函数（分析 AC-5——9/11 条件纯，
# PIERCE_INDEX_GE 非纯读 ctx.pierce_index → 贡献式缓存：缓存 base value，每命中现乘
# (pierce_index−1)）；条件判定路径不动（目标态/hit_flags/pierce_index/血线逐命中活评）。
# 生效面=投射物载体（tctx.projectile != null，运行栈随弹冻结于 spawn/borrow——分析
# AC-4 弹/束轴飞行中写者清零）；orbit/arc 读武器主栈 LIVE 排除出 v1 维持活评；激光束
# 自持运行栈为 v2 可选（本版一并排除，披露）。池 dict 复用改值不重建（前提=分析
# AC-7：resolve 返回后零持有者；R1 别名污染已由刀1b defer 袋浅拷贝解除）。
static var TRAIT_PRECACHE: bool = true
var _pre_cache: Array[Dictionary] = []        # MULT 子集缓存条目 {cond, params, base, dict}
var _pre_built: bool = false                  # 缓存有效位（attach/clear 失效；惰性首命中构建）
var runtime_generation: int = 0               # 主栈运行世代（三失效面 bump：attach/质变/取优）
# R262b M3：aggregate_panel 栈级世代缓存——面板聚合是「层数纯函数」（layer_values×
# value_mult），runtime_generation 三 bump 口（attach/质变/取优）已覆盖全部写面，命中即
# 免 O(Σ层) 重求和。此前逐击/逐挂/逐升级直调全层求和+新建字典=累积型二次方（R257
# 挂机三杀 300/580/700s 根因族）。返回本体的只读契约同 R232 _pre_cache 先例（AC-7：
# 全部调用点 .get() 取标量零持有——R262b 审计逐一核过）；破坏契约者需自 duplicate。
var _panel_cache: Dictionary = {}             # 世代内面板聚合快照（pool_id → 有效和）
var _panel_cache_gen: int = -1                # 缓存所属世代（-1=从未构建）
var _runtime_pool: Array[TraitStack] = []     # 主栈借出池（退役运行栈——世代匹配才复用）
var _home_stack: WeakRef = null               # 运行栈实例侧：主栈回指（release_to_pool 归池口）
var _borrow_gen: int = -1                     # 运行栈实例侧：借出时主栈世代（复用/弃件判据）


func bump_runtime_generation() -> void:
	# R220 刀5 三失效面统一失效口（weapon_base._invalidate_panel 两调用口：attach_trait /
	# MILESTONE 质变；第三面 MULT/ELE 取优换定义在本类 attach 内自调）：世代 +1 并清空
	# 借出池——池内件按旧世代克隆（词条集/value_mult/定义陈旧），复用=「新弹带旧栈」
	# （丢新卡效果/丢 ×1.6 乘区）。存活弹晚归带的旧世代件在借出时弃件拦截（双保险）。
	runtime_generation += 1
	_runtime_pool.clear()


func acquire_runtime() -> TraitStack:
	# R220 刀5 运行栈借出（ballistic/homing/laser spawn 侧调用点）：池化关 = copy_runtime
	# 原 new 路径（逐位等价零回归）；开 = 池优先借出，世代不匹配弃件重建。
	# R220 修轮（QA S2 三缺陷）：①查池提前——池命中路径零 copy_runtime（原实现先无条件
	# 全额克隆再查池，命中时克隆白做，「消灭每弹 copy_runtime」落空且多付池记账）；
	# ②借出统一恢复 _home_stack 回指（原实现仅新件设置——复用件随弹回收时
	# release_to_pool 因 _home_stack==null 早退，池件只能被复用一次，稳态池化退化）。
	if POOLING_ENABLED:
		while not _runtime_pool.is_empty():
			var cand: TraitStack = _runtime_pool.pop_back()
			if cand != null and cand._borrow_gen == runtime_generation:
				cand._home_stack = weakref(self)    # 复用件回指恢复（归还口判据）
				cand._borrow_gen = runtime_generation
				return cand
			DebugStats.count(&"trait_pool_discarded")   # 弃件（通用通道——不进 R220_COUNTER_KEYS）
		var out := copy_runtime()
		out._home_stack = weakref(self)
		out._borrow_gen = runtime_generation
		return out
	return copy_runtime()


func release_to_pool() -> void:
	# R220 刀5 归还口（契约 §6.1 接口冻结；弹侧 _reset_state/_recycle 收束处经
	# has_method 守卫调用——池化关/无主栈/已归还 = no-op 安全可调）：运行位清零
	# （E-13 逐弹独立触发冷却承重）→ _assert_clean 污染断言 → 回池。
	if not POOLING_ENABLED or _home_stack == null:
		return
	var home := _home_stack.get_ref() as TraitStack
	if home == null:
		return                              # 主栈已亡（武器销毁）：件作普通垃圾回收
	for mounted in traits:
		mounted.reset_runtime()             # cooldown_left/frame_triggered/in_dispatch/帧号清零
	_depth = 0
	_dispatching = false
	_current_event = -1
	_fused_count = 0                        # R220 修轮：熔断读数随归还清零（与全新克隆件口径一致）
	_assert_clean()
	home._runtime_pool.append(self)
	_home_stack = null                      # 幂等：二次归还直接 no-op（弹侧双收束防御；
	                                      # 复用件下次借出时 acquire_runtime 重设回指）


func _assert_clean() -> void:
	# R220 刀5 池污染断言（dev 断言口——release_to_pool 清位后兑底；违例计数不中断）
	if not DebugStats.dev_assertions:
		return
	for mounted in traits:
		if mounted == null or mounted.data == null:
			continue
		if mounted.cooldown_left != 0.0 or mounted.frame_triggered or mounted.in_dispatch:
			push_error("[TraitStack] 池污染：归还件运行位未清（%s）" % String(mounted.data.id))
			DebugStats.count(&"trait_pool_dirty")


func has_event_hook(p_event: int) -> bool:
	# R210：栈内是否有词条「可能」响应该事件——on_event 静态闸门同口径（data/effect
	# 非空、非 MULT 声明性池、event_hooks 含该事件；can_trigger 动态闸不计——保守超集）。
	# 消费点=projectile_base._dispatch_event 无挂钩事件提前直通（真机 vc17 弹段 9-12ms
	# 主犯：词条弹每帧 ON_TICK 空转分发——payload 字典+TraitContext 分配+全词条虚调用，
	# 而数据侧 ON_TICK 挂钩为零、on_event 闸门全灭=零行为差异）。
	if not _hooked_cache.has(p_event):
		var hooked := false
		for mounted in traits:
			if mounted.data != null and mounted.effect != null \
					and mounted.data.pool != GameConst.PoolClass.MULT \
					and mounted.data.event_hooks.has(p_event):
				hooked = true
				break
		_hooked_cache[p_event] = hooked
	return _hooked_cache[p_event]


func attach(p_data: TraitData) -> bool:
	# 挂载：同 ID 叠层（R226 起无限叠，全池）／新建；超 MAX_TRAITS 种类拒绝 + 计数
	# R196 有意契约变更（原「至 stack_max 拒绝」）：ADD 池帽放宽至 stack_max+OVERCAP_EXT_MAX。
	# R226 有意契约变更（用户拍板「肉鸽别搞上限」）：同 ID 叠层帽全池拆除——stack_max 只剩
	# 满层质变里程碑语义（消费端 WeaponBase.attach_trait）；层级超 stack_max 仍计
	# trait_attach_overcap 遥测（语义=里程碑后叠层数，观测爽叠深度用）。
	# ADD 池逐层独立品级追加（layer_values append）天然支持无限层；MULT/ELE 取优语义不变。
	if p_data == null:
		return false
	_hooked_cache.clear()                     # R210：叠层/MULT 取优换定义均可变挂钩面
	_pre_built = false                        # R232 刀1c：词条面变化 → 贡献缓存失效重建
	_panel_cache.clear()                      # R262b M3：ADD append 不走世代 bump（历史设计
	_panel_cache_gen = -1                     # ——_runtime_pool 不清），面板缓存须在此直失
	for mounted in traits:
		if mounted.data.id == p_data.id:
			if mounted.layers >= p_data.stack_max:
				DebugStats.count(&"trait_attach_overcap")   # 里程碑后叠层（R226 起全额放行）
			# R12c 分池语义：
			# · ADD（可叠数值型）→ 逐层独立品级：每张卡按自身数值贡献（白+蓝=白全额+蓝×δ），
			#   没有任何一张「白选」；层基数不再取优覆盖
			# · MULT/ELE（机制合并表/每次附着定值）→ 取优（高品级定义覆盖），叠加计层
			if p_data.pool == GameConst.PoolClass.ADD:
				mounted.layer_values.append(p_data.value)
				mounted.layer_rarities.append(p_data.rarity)
			elif float(p_data.value) > float(mounted.data.value):
				mounted.data = p_data
				bump_runtime_generation()   # R220 刀5 失效面③：MULT/ELE 取优换定义——
				                             # 借出池件按旧定义克隆，弃（同 _hooked_cache 失效口径）
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


func copy_full() -> TraitStack:
	# 武器主栈 → 僚机复制武器栈（R183）：copy_full 比 copy_runtime 多拷
	# layer_values/layer_rarities（逐层品级数值——_clone_trait 不带，R12c 混合品级
	# ADD 池会回落「基准值×层数」口径，复制武器伤害对不上原武器）
	var out := TraitStack.new()
	for mounted in traits:
		var c := _clone_trait(mounted)
		c.layer_values.assign(mounted.layer_values)   # assign：保类型数组安全搬运（duplicate 回落非类型化）
		c.layer_rarities.assign(mounted.layer_rarities)
		out.traits.append(c)
	return out


func copy_for_split(p_generation: int, p_echo: bool = false) -> TraitStack:
	# F-13：inheritable 定义复制 + 运行时状态重置（引用复制非深拷贝，E-13）。
	# 分裂词条自身默认 false（E-01——否则指数裂变）；p_echo（TH_FRACTAL_ECHO，深度 ≥3）
	# 扩展至乘区词条：定义复制、子代条件自评、独立过护栏。
	# R262b L18 注：p_generation 形参当前未被消费（代数闸真身在 projectile_base
	# split_rejected_generation 三重闸：代数≤3/单次子数≤8/全场软上限）——保留形参
	# 为调用点契约稳定位，若未来把代数闸下沉到栈侧在此消费，勿删签名。
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
	# R232 刀1c：TRAIT_PRECACHE 且投射物载体（tctx.projectile != null）走「静态贡献缓存
	# × 条件活评」——条件判定逐命中活评（SynergyRules.condition_met，目标态/ctx 快照
	# 输入不动）；贡献取缓存（PIERCE_INDEX_GE 贡献式：缓存 base，现乘 (pierce_index−1)，
	# 与 SynergyRules.contribution 同式逐位同值）。池 dict 为缓存件复用改值（contrib/
	# source_uid 两键每命中覆写）——前提=分析 AC-7 resolve 后零持有者 + 刀1b defer 袋
	# 浅拷贝（R1）。orbit/arc（tctx.projectile==null，主栈 LIVE）与激光（v2 预留）走
	# 下方原路径活评（逐词条 evaluate），语义逐位不变。
	var out: Array[Dictionary] = []
	var source_uid := 0
	if p_ctx.projectile != null:
		source_uid = p_ctx.projectile.uid
	elif p_ctx.beam != null:
		source_uid = p_ctx.beam.uid
	elif p_ctx.weapon != null:
		source_uid = p_ctx.weapon.uid
	if TRAIT_PRECACHE and p_ctx.projectile != null:
		if not _pre_built:
			_pre_build_cache()
		for pre in _pre_cache:
			var cond_id := int(pre["cond"])
			if not SynergyRules.condition_met(cond_id, pre["params"], p_ctx):
				continue                        # 条件不满足 → 该区不注入（原路径同语义）
			var d: Dictionary = pre["dict"]
			d["source_uid"] = source_uid
			if cond_id == GameConst.ConditionId.PIERCE_INDEX_GE:
				var pi := 0
				if p_ctx.damage_ctx != null:
					pi = p_ctx.damage_ctx.pierce_index
				d["contrib"] = float(pre["base"]) * float(maxi(pi - 1, 0))
			out.append(d)
		return out
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


func _pre_build_cache() -> void:
	# R232 刀1c：贡献缓存构建（惰性首命中——spawn 期等价时点；弹飞行期词条面不变，
	# 分析 AC-4 清零，故无需逐命中校验世代；失效口=attach/clear——主栈挂卡/取优换
	# 定义/清栈三面全覆盖，runtime_generation 为 v2 扩展保留）。每 MULT 词条一条：
	# cond/params 供条件活评；base=data.value（PIERCE 贡献式基值；纯条件贡献=data.value
	# 原样）；dict=池条目模板（contrib 初值=base——纯条件命中即原值）。
	_pre_cache.clear()
	for mounted in traits:
		if mounted.data == null or mounted.data.pool != GameConst.PoolClass.MULT:
			continue
		var cond: Dictionary = mounted.data.condition
		_pre_cache.append({
			"cond": int(cond.get("condition_id", GameConst.ConditionId.NONE)),
			"params": cond.get("params", {}),
			"base": mounted.data.value,
			"dict": {
				"pool_id": mounted.data.pool_id,
				"source_uid": 0,
				"contrib": mounted.data.value,
				"cap_pool": mounted.data.cap_pool_p,
				"priority": 0,
			},
		})
	_pre_built = true


func aggregate_panel() -> Dictionary:
	# 常驻加算聚合（build ctx 时求值）：pool_id → 有效和（F3 衰减 / 整数池线性全额）。
	# 满层质变乘区 value_mult 乘在词条有效值上（2026-08-31：挂至 stack_max 时 ×1.6）。
	# R196 曾有「前 stack_max 层全额 + 超帽层 ×0.7」三路折算；
	# R226 有意契约变更：超帽衰减退役——所有层全额（逐层=Σ层值、整数/衰减路=层数展开），
	# 未超帽时与原式逐值一致（存量词条零回归）。
	# R262b M3：世代缓存命中直返（同代无写面=聚合恒不变）；只读契约见成员区注释。
	if _panel_cache_gen == runtime_generation and not _panel_cache.is_empty():
		return _panel_cache
	var sums: Dictionary = {}
	for mounted in traits:
		if mounted.data.pool != GameConst.PoolClass.ADD:
			continue
		var pool_id: StringName = mounted.data.pool_id
		var effective := 0.0
		if mounted.layer_values.size() > 0:
			# R14 直接叠加：每层全额（1 层 12%、2 层 24%），不再 F3 递减；R226 起无超帽折算
			for v_k in mounted.layer_values:
				effective += v_k * mounted.value_mult
		else:
			var effective_value := mounted.data.value * mounted.value_mult
			# R226 起整数/衰减两路同形：按层数全额展开（原 cap+0.7×extra 折算退役）
			effective = effective_value * float(mounted.layers) \
				if LINEAR_ADD_POOLS.has(pool_id) \
				else decay_sum(effective_value, mounted.layers, mounted.data.decay_delta)
		sums[pool_id] = float(sums.get(pool_id, 0.0)) + effective
	_panel_cache = sums
	_panel_cache_gen = runtime_generation
	return sums


func aggregate_add_entries() -> Array[Dictionary]:
	# add_atk 池 → DamageContext.add_entries（管线步骤 3 F3 衰减真源；面板段唯一入列池）
	var out: Array[Dictionary] = []
	# R14 直接叠加：每层一条贡献（层内全额；同 ID 混品级各按自身数值）；
	# R226 有意契约变更：超帽层 ×0.7 折算退役——每层全额入列（"layer"/decay_delta
	# 记账键不变——管线侧零改动）
	for mounted in traits:
		if mounted.data.pool != GameConst.PoolClass.ADD:
			continue
		if mounted.data.pool_id != &"add_atk":
			continue
		for v_k in mounted.layer_values:
			var contrib := v_k * mounted.value_mult
			out.append({
				"trait_id": mounted.data.id,
				"pool_id": mounted.data.pool_id,
				"layer": 1,                     # R14 直接叠加：每层全额（无衰减）
				"contrib": contrib,
				"decay_delta": mounted.data.decay_delta,
				"is_curse": contrib < 0.0,
			})
	return out


func advance_cooldowns(p_game_delta: float) -> void:
	# 词条触发冷却推进（宿主 tick 期调用）
	for mounted in traits:
		if mounted.cooldown_left > 0.0:
			mounted.cooldown_left = maxf(mounted.cooldown_left - p_game_delta, 0.0)


func clear() -> void:
	# 归还清零（池断言前置）
	traits.clear()
	_hooked_cache.clear()                     # R210：挂钩面随词条清空失效
	_pre_built = false                        # R232 刀1c：词条面清空 → 贡献缓存失效
	_panel_cache.clear()                      # R262b M3：面板聚合缓存随词条面失效
	_panel_cache_gen = -1
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
	# 定义引用复制 + 层数/质变乘区保留 + 运行时状态重置（E-13：非深拷贝——TraitData 共享只读）
	var instance := TraitBase.new()
	instance.setup(p_source.data)
	instance.layers = p_source.layers
	instance.value_mult = p_source.value_mult
	return instance
