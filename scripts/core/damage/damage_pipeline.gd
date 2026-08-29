# scripts/core/damage/damage_pipeline.gd
# M-12 伤害结算管线（架构 §2.5 骨架签名 + §4.2 九步调用序列；B_spec §2 最终裁定实现）。
#
# 设计要点：
# · 九步顺序即护栏顺序（L5 幂等 → L2 衰减 → L3 结构钳制 → L4 总量封顶 → 审计广播），
#   禁止重排；同输入必同输出（配合固定 RNG 种子支撑模式 A/B/C 回归，A2 §2.4）。
# · 聚合与池护栏全部委托 ModifierStack（包 0 冻结件：F3 几何衰减/双层乘区合并/
#   名额 top-8/整体钳 8.0），本管线只编排不改聚合语义。
# · 死亡短路/无效输入返回 null（调用方对 null 直接跳过）；幂等命中返回缓存结果。
# · 目标侧 Enemy（包 2 在途）按架构 §2.11 窄接口 duck-typing 收窄点：
#   get_resist(element)/resist[] → 抗性；status_vuln → 状态易伤；
#   take_result/apply_damage → 扣血与 killed；字段或方法不存在时回退安全中性值
#   （抗性 0 / 易伤 0 / killed=false），包 2 合入后自然收紧为强类型。
class_name DamagePipeline
extends RefCounted

var _idempotent_cache: Dictionary = {}        # int64 键 -> DamageResult（每帧 begin_frame 清空）
var _rng_streams: Dictionary = {}             # stream_id -> RandomNumberGenerator（种子可注入）
var _stats: Dictionary = {}                   # {settles, reaction_settles, dropped_*, alarms, ...}

var _alarm_emitted: bool = false              # R_alarm 广播闸（一局一次；后续触发仅记审计+计数）
var _rxn_alarm_emitted: bool = false          # R_rxn 反应通道广播闸（集成包 B.6：独立双闸，同语义）
var _default_rng_seed: int = 0                # 未绑定流的确定性默认种子（保证同输入同输出）
var _last_flush: Dictionary = {}              # end_frame 增量基线（累计计数 → 帧增量落 DebugStats）
var _balance_fallback: BalanceTables = null   # GameConfig 未就绪兜底（schema 默认值即合法值）


func _init() -> void:
	_stats = {
		"settles": 0, "reaction_settles": 0, "dropped_dupe": 0,
		"dropped_dead": 0, "dropped_invalid": 0, "sanitized_negative": 0, "alarms": 0,
		"rxn_alarms": 0,
	}


# ── 公共入口（§2.5 冻结签名） ────────────────────────────────────

func resolve(p_ctx: DamageContext) -> DamageResult:
	# ★ 唯一公共结算入口（§4.2 九步序列，顺序禁止重排）。
	# 0. 入口防御（§六.4，先于九步，不改语义）：NaN/Inf → 丢弃；负 base_atk → 0 + 计数
	if not _sanitize(p_ctx):
		_stats["dropped_invalid"] += 1
		return null
	# ① 幂等检查：(source_uid, target_uid, frame_stamp) 已结算 → 短路返回缓存结果
	var cached: DamageResult = _check_idempotent(p_ctx)
	if cached != null:
		_stats["dropped_dupe"] += 1
		return cached
	# ② 目标存活检查：dead/null → 丢弃 + 计数（E-06 死亡短路）
	if not _target_alive(p_ctx):
		_stats["dropped_dead"] += 1
		return null
	var stack := ModifierStack.new()
	stack.audit = DamageAudit.new()
	# ③ Add 池聚合（同 ID 叠层 F3 衰减 + 跨 ID 线性 + 负贡献全额 + F4 池钳）
	_aggregate_add(p_ctx, stack)
	# ④ Flat 加入（Σ_flat ≤ f_flat × base_atk 比例钳制）
	_apply_flat(p_ctx, stack)
	# ⑤ 乘区聚合（聚合层合并 → 防御层去重 → 单区 cap → 名额 top-8 → 整体钳 8.0）
	_aggregate_mults(p_ctx, stack)
	# ⑥ Local 池独立聚合（不入名额、不受 cap_prod，自有 cap_local，F-15）
	_aggregate_local(p_ctx, stack)
	# ⑦ 暴击掷骰（独立 RNG 流；HIT_NO_CRIT → C=1，不掷骰不消耗序列）
	var crit := _roll_crit(p_ctx)
	var result := DamageResult.new()
	_populate_result(p_ctx, stack, crit, result)   # ⑦b 四段中间量落字段（S/M/L/C + 表现级派生）
	# ⑧ 目标侧修正：V = (1 − resist[element]) × (1 + 状态易伤)
	_apply_target_side(p_ctx, stack, result)
	# ⑨ 终值钳制 + R_alarm 双闸 + killed 判定 → 广播 → 幂等缓存写入
	_finalize(p_ctx, stack, result)
	_broadcast(result)
	_cache_result(p_ctx, result)
	_stats["settles"] += 1
	return result


func resolve_reaction(snapshot_atk: float, coefficient: float, p_ctx: DamageContext) -> DamageResult:
	# F20/F21 反应独立结算通道：D = χ_rxn × φ × S_snap（快照面板，不含乘区/Local/暴击）。
	# · snapshot_atk：触发时刻面板快照 S_snap（来源：先前结算结果的 panel_snapshot 字段）
	# · coefficient：χ_rxn × φ（反应系数 × 反应强化乘区，由 ElementalSystem 侧聚合后传入）
	# · p_ctx：ElementalSystem 预构造（target/pos；element 字段承载 GameConst.ReactionType
	#   中性 ID，供 reaction_triggered 广播——反应通道专用约定）
	# 上界：D ≤ S_snap × r_alarm_ratio（独立告警线，同 R_alarm 双闸机制；R_rxn 专用值
	# 待 A3 落数后在 BalanceTables 扩展字段替换此默认口径）。
	if not is_finite(snapshot_atk) or not is_finite(coefficient) \
			or snapshot_atk < 0.0 or coefficient < 0.0:
		_stats["dropped_invalid"] += 1
		return null
	p_ctx.hit_flags |= GameConst.HIT_IS_REACTION    # 强制反应标记（⑦ 跳过掷骰 + REACTION 表现级）
	var cached: DamageResult = _check_idempotent(p_ctx)
	if cached != null:
		_stats["dropped_dupe"] += 1
		return cached
	if not _target_alive(p_ctx):
		_stats["dropped_dead"] += 1
		return null
	var stack := ModifierStack.new()
	stack.audit = DamageAudit.new()
	var result := DamageResult.new()
	_populate_result(p_ctx, stack, false, result)   # 空聚合占位（元数据/表现级派生）
	result.panel_snapshot = snapshot_atk             # 快照口径：覆盖 ctx 面板字段（含加算池的终值）
	var d := coefficient * snapshot_atk
	var alarm_ratio := _balance().r_rxn_ratio      # R_rxn 反应独立告警线（集成包 B.6 落字段，原 ×500 兜底）
	result.final_value = clampf(d, 0.0, maxf(snapshot_atk * alarm_ratio, 0.0))
	if not is_finite(result.final_value):
		result.final_value = 0.0                     # NaN 兜底（±Inf 已被 clamp 正确钳制）
	stack.audit.ratio = coefficient if snapshot_atk > 0.0 else 0.0
	if snapshot_atk > 0.0 and coefficient > alarm_ratio:
		stack.audit.alarm = true
		_stats["rxn_alarms"] += 1
	result.killed = _apply_to_target(p_ctx, result)  # 9b killed 判定（死亡只执行一次）
	_broadcast(result)
	if stack.audit.alarm and not _rxn_alarm_emitted:
		# R_rxn 双闸（同 R_alarm 语义：一局一次广播，后续仅记审计+计数）
		_rxn_alarm_emitted = true
		EventBus.emit_damage_alarm(result)
	EventBus.emit_reaction_triggered(int(p_ctx.element), p_ctx.pos, p_ctx.target_uid)
	_cache_result(p_ctx, result)
	_stats["reaction_settles"] += 1
	return result


@warning_ignore("unused_parameter")
func begin_frame(frame: int = -1) -> void:
	# GameLoop 投射物阶段前挂接：清幂等缓存（§4.1 缓存每帧清空）。
	# frame 为调用方帧号对账参数（幂等键第三元取 ctx.frame_stamp；默认参数兼容架构
	# §2.5 无参签名 begin_frame()，两种调用形态等价）。
	_idempotent_cache.clear()


func end_frame() -> void:
	# GameLoop 帧末挂接：遥测计数增量落 DebugStats（累计值 → 本帧增量）
	for key in _stats:
		var cur := int(_stats[key])
		var prev := int(_last_flush.get(key, 0))
		if cur != prev:
			DebugStats.count(StringName("damage." + String(key)), cur - prev)
		_last_flush[key] = cur


func bind_rng_stream(stream_id: int, p_seed: int) -> void:
	# 独立 RNG 流种子注入（架构 §2.5；AC-12.5 固定种子回归——多武器可各持独立流）
	var rng := RandomNumberGenerator.new()
	rng.seed = p_seed
	_rng_streams[stream_id] = rng


func set_rng_seed(seed_value: int) -> void:
	# 模式 A/B 测试共用：默认流（stream 0）固定种子注入；未绑定流惰性创建时同用此种子
	_default_rng_seed = seed_value
	bind_rng_stream(0, seed_value)


func stats() -> Dictionary:
	# DebugStats / 测试查询（快照拷贝）
	return _stats.duplicate()


# ── 九步私有方法（顺序即 B_spec §2.3，禁止重排） ─────────────────

func _sanitize(p_ctx: DamageContext) -> bool:
	# 0. NaN/Inf/负数入口防御（§六.4，先于九步，不改语义）：
	#    NaN/Inf（base/flat/暴击参数/各 contrib）→ 丢弃该结算 + 告警计数；
	#    负 base_atk → 钳 0 + 计数（flat 负值为诅咒语义，全额放行）。
	if not is_finite(p_ctx.base_atk) or not is_finite(p_ctx.flat_bonus) \
			or not is_finite(p_ctx.crit_chance) or not is_finite(p_ctx.crit_mult):
		return false
	for e: Dictionary in p_ctx.add_entries:
		if not is_finite(float(e.get("contrib", 0.0))):
			return false
	for e: Dictionary in p_ctx.mult_pools:
		if not is_finite(float(e.get("contrib", 0.0))):
			return false
	for e: Dictionary in p_ctx.local_pools:
		if not is_finite(float(e.get("contrib", 0.0))):
			return false
	if p_ctx.base_atk < 0.0:
		p_ctx.base_atk = 0.0
		_stats["sanitized_negative"] += 1
	return true


func _check_idempotent(p_ctx: DamageContext) -> DamageResult:
	# 1. 幂等检查（命中返回缓存结果；§4.1 int64 位拼接键）
	if _idempotent_cache.has(_idem_key(p_ctx)):
		return _idempotent_cache[_idem_key(p_ctx)] as DamageResult
	return null


func _target_alive(p_ctx: DamageContext) -> bool:
	# 2. 目标存活（死亡短路 E-06）：null / dead → false
	if p_ctx.target == null:
		return false
	var d: Variant = p_ctx.target.get("dead")
	if d != null:
		return not bool(d)
	return true


func _aggregate_add(p_ctx: DamageContext, p_stack: ModifierStack) -> void:
	# 3. Add 池聚合（F3 衰减 + 跨 ID 线性 + 负贡献全额 + F4 池钳——委托 ModifierStack）
	p_stack.aggregate_add(p_ctx.add_entries, _balance().add_pool_caps)


func _apply_flat(p_ctx: DamageContext, p_stack: ModifierStack) -> void:
	# 4. Flat 加入（Σ_flat ≤ f_flat × base_atk 比例钳制，超限截断 + 审计）
	p_stack.apply_flat(p_ctx.flat_bonus, p_ctx.base_atk, _balance().flat_ratio_cap)


func _aggregate_mults(p_ctx: DamageContext, p_stack: ModifierStack) -> void:
	# 5. 乘区聚合（聚合层合并 → 防御层去重 → 单区 cap_pool_p → 名额 top-8 → 整体钳 8.0）
	var bal := _balance()
	p_stack.aggregate_mults(p_ctx.mult_pools, bal.cap_mul_count, bal.cap_prod)


func _aggregate_local(p_ctx: DamageContext, p_stack: ModifierStack) -> void:
	# 6. Local 池独立聚合（∏ L_l：不入名额、不受 cap_prod，自有 cap_local，F-15）
	p_stack.aggregate_local(p_ctx.local_pools)


func _roll_crit(p_ctx: DamageContext) -> bool:
	# 7. 暴击掷骰：独立 RNG 流 Bernoulli(crit_chance)（F7）。
	#    HIT_NO_CRIT（DOT/反应）→ C=1，不掷骰不消耗序列（A2 §1.7 排除项）；
	#    chance 0/1 边界短路（同样不消耗序列——确定性友好）。
	if (p_ctx.hit_flags & GameConst.HIT_NO_CRIT) != 0:
		return false
	var chance := clampf(p_ctx.crit_chance, 0.0, 1.0)
	if chance <= 0.0:
		return false
	if chance >= 1.0:
		return true
	return _get_rng(p_ctx.rng_stream_id).randf() < chance


func _populate_result(p_ctx: DamageContext, p_stack: ModifierStack, p_crit: bool, p_result: DamageResult) -> void:
	# 7b. 四段中间量落字段：S/M/L/C + 元数据 + 乘区明细 + feel_level/popup_style 派生。
	#     S = base_atk × (1 + Σ_add) + flat_clamped（Σ_add = 面板段加算输入，跨池求和）
	var add_sum := 0.0
	for pid in p_stack.add_pool_sum:
		add_sum += float(p_stack.add_pool_sum[pid])
	p_result.panel_snapshot = p_ctx.base_atk * (1.0 + add_sum) + p_stack.flat_clamped
	p_result.mult_product = p_stack.product_clamped
	p_result.local_product = p_stack.local_product
	p_result.is_crit = p_crit
	p_result.element = p_ctx.element
	p_result.source_uid = p_ctx.source_uid
	p_result.target_uid = p_ctx.target_uid
	p_result.frame_stamp = p_ctx.frame_stamp
	p_result.pos = p_ctx.pos
	p_result.audit = p_stack.audit
	var breakdown := {}
	for m: Dictionary in p_stack.resolved_mults:
		breakdown[m["pool_id"]] = float(m["agg"])
	p_result.pool_breakdown = breakdown
	var is_reaction := (p_ctx.hit_flags & GameConst.HIT_IS_REACTION) != 0
	var is_dot := (p_ctx.hit_flags & GameConst.HIT_IS_DOT) != 0
	if is_reaction:
		p_result.feel_level = GameConst.FeelLevel.CATALYST
		p_result.popup_style = GameConst.PopupStyle.REACTION
	elif is_dot:
		p_result.feel_level = GameConst.FeelLevel.HIT
		p_result.popup_style = GameConst.PopupStyle.DOT
	elif p_crit:
		p_result.feel_level = GameConst.FeelLevel.CRIT
		p_result.popup_style = GameConst.PopupStyle.CRIT
	else:
		p_result.feel_level = GameConst.FeelLevel.HIT
		p_result.popup_style = GameConst.PopupStyle.NORMAL


@warning_ignore("unused_parameter")
func _apply_target_side(p_ctx: DamageContext, p_stack: ModifierStack, p_result: DamageResult) -> void:
	# 8. 目标侧修正：V = (1 − resist[element]) × (1 + 状态易伤)（B_spec §2.1）。
	#    易伤正式路径为 vuln 乘区在⑤入池（A2 §1.8）；此处为 Enemy 快照兜底口径，
	#    鸭子类型缺省时取中性值 1.0（§2.11 收窄点注释，包 2 合入后收紧）。
	p_result.target_factor = (1.0 - _read_resist(p_ctx)) * (1.0 + _read_status_vuln(p_ctx))


func _finalize(p_ctx: DamageContext, p_stack: ModifierStack, p_result: DamageResult) -> void:
	# 9a+9b. 终值钳制 + R_alarm 双闸 + 审计落字段 + killed 判定。
	# 9a. raw = S × M × L × C × V → clamp(raw, 0, base_atk × r_alarm_ratio)（保险钳制）
	var c := p_ctx.crit_mult if p_result.is_crit else 1.0
	var raw := p_result.panel_snapshot * p_result.mult_product * p_result.local_product * c * p_result.target_factor
	var alarm_ratio := _balance().r_alarm_ratio
	var final_val := clampf(raw, 0.0, maxf(p_ctx.base_atk * alarm_ratio, 0.0))
	if not is_finite(final_val):
		final_val = 0.0                    # NaN 兜底（±Inf 已被 clamp 正确钳制）
	p_result.final_value = final_val
	# R_alarm 检查（抗性前口径 F10：S×M×L×C / base_atk > r_alarm_ratio——只测玩家构筑强度）
	if p_ctx.base_atk > 0.0:
		p_stack.audit.ratio = p_result.panel_snapshot * p_result.mult_product \
			* p_result.local_product * c / p_ctx.base_atk
		if p_stack.audit.ratio > alarm_ratio:
			p_stack.audit.alarm = true
			_stats["alarms"] += 1
	else:
		p_stack.audit.ratio = 0.0
	# 9b. killed 判定：target.take_result(result)（apply → 死亡只执行一次；§2.11 包 2 契约）
	p_result.killed = _apply_to_target(p_ctx, p_result)


func _broadcast(p_result: DamageResult) -> void:
	# 9c. EventBus 广播（唯一广播点，禁止绕过）：damage_resolved 每次成功结算；
	#     damage_alarm 一局一次（后续超限仍记 audit.alarm 与 alarms 计数，仅不重复广播）
	EventBus.emit_damage_resolved(p_result)
	if p_result.audit != null and p_result.audit.alarm and not _alarm_emitted:
		_alarm_emitted = true
		EventBus.emit_damage_alarm(p_result)


func _cache_result(p_ctx: DamageContext, p_result: DamageResult) -> void:
	# 9d. 幂等缓存写入（§4.1 位拼接键；begin_frame 每帧清空）
	_idempotent_cache[_idem_key(p_ctx)] = p_result


# ── 内部辅助 ─────────────────────────────────────────────────────

static func _idem_key(p_ctx: DamageContext) -> int:
	# §4.1 幂等键位拼接：source_uid:20bit << 44 | target_uid:20bit << 24 | frame_stamp:24bit
	# （UID/帧号位宽由 GameConst 分配器与 GameConfig.advance_frame 层面钳制回绕）
	return (p_ctx.source_uid & GameConst.UID_MAX) << 44 \
		| (p_ctx.target_uid & GameConst.UID_MAX) << 24 \
		| (p_ctx.frame_stamp & 0xFFFFFF)


func _get_rng(p_stream_id: int) -> RandomNumberGenerator:
	# 独立 RNG 流惰性获取：未绑定流以 _default_rng_seed 创建（确定性默认，同输入同输出）
	if not _rng_streams.has(p_stream_id):
		var rng := RandomNumberGenerator.new()
		rng.seed = _default_rng_seed
		_rng_streams[p_stream_id] = rng
	return _rng_streams[p_stream_id] as RandomNumberGenerator


func _read_resist(p_ctx: DamageContext) -> float:
	# Enemy（包 2 在途）窄接口 duck-typing（§2.11）：get_resist(element) 方法 →
	# resist[element] 数组快照 → ctx.target_resist（来源侧快照，含超导削抗后值）；
	# 均缺省 → 0.0（因子 1.0 中性）。
	if p_ctx.target != null:
		if p_ctx.target.has_method("get_resist"):
			return float(p_ctx.target.call("get_resist", p_ctx.element))
		var arr: Variant = p_ctx.target.get("resist")
		if arr is Array and p_ctx.element >= 0 and p_ctx.element < (arr as Array).size():
			return float((arr as Array)[p_ctx.element])
	return p_ctx.target_resist


func _read_status_vuln(p_ctx: DamageContext) -> float:
	# 目标状态易伤快照（B_spec §2.1 状态修正项，如冰冻易伤 +0.25）；
	# 字段不存在 → 0.0（因子 1.0 中性）。
	if p_ctx.target != null:
		var v: Variant = p_ctx.target.get("status_vuln")
		if v != null:
			return float(v)
	return 0.0


func _apply_to_target(p_ctx: DamageContext, p_result: DamageResult) -> bool:
	# 9b killed 判定：优先 Enemy.take_result（§2.11：apply + 死亡广播 + 掉落触发）；
	# 占位回退 apply_damage(final) -> bool；均缺省 → 纯公式模式 killed=false。
	var t: Object = p_ctx.target
	if t == null:
		return false
	if t.has_method("take_result"):
		t.call("take_result", p_result)
		var d: Variant = t.get("dead")
		return d != null and bool(d)
	if t.has_method("apply_damage"):
		return bool(t.call("apply_damage", p_result.final_value))
	return false


func _balance() -> BalanceTables:
	# GameConfig 护栏常数唯一真源（cap_prod/cap_mul_count/flat_ratio_cap/r_alarm_ratio/
	# add_pool_caps）；autoload 异常时序下回退 BalanceTables schema 默认值（默认即合法）。
	var bal: BalanceTables = null
	if GameConfig != null:
		bal = GameConfig.balance
	if bal == null:
		if _balance_fallback == null:
			_balance_fallback = BalanceTables.new()
		return _balance_fallback
	return bal
