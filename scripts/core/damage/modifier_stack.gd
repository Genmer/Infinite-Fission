# scripts/core/damage/modifier_stack.gd
# A2 §7.2：聚合与护栏的唯一执行点（管线步骤 3~6 的产物，只算不改语义）。
# 四层护栏顺序固定：池聚合 → 单区 cap → 数量截断(top-N) → 乘积 cap（A2 §2.2 工程契约）。
# 本类不修改任何传入条目，不产生副作用（审计只记录不改结果，保证确定性与可复现）。
class_name ModifierStack
extends RefCounted

# ── R232 刀1e：⑤③聚合 typed 累加（回滚开关） ────────────────────────
# STEP 表定位（probe_r232_knife）：5_agg_mults ≈18µs/结=resolve 核 37% 唯一大项——
# 每命中 grouped/caps_seen/pool_priority 三层 Dictionary 哈希交通（≈10+ 次查/条目）
# 改 typed 平行数组累加（StringName 线性扫，池/实例数 ≤ 名额 8 量级），聚合语义逐位：
# ①池/实例分组按首现序（Dictionary 插入序=原实现求和序，浮点累加序不变）；②uid==0
# 线性合并/同实例取最大+audit.dedup_defense 按条目扫描序；③caps/priority 区内取最大；
# ④mult_pools/add_pool_sum/resolved_mults 物化时机/形状/键值与原路径逐位一致（消费面
#=relic_handler 2 has + burn_dmg + breakdown 快照断言，输入 ctx 三池对外读面零改动）。
# ⚠R232 收口实测（专用证伪档 docs/qa/probe_r232_knife1e_falsified_2026-10-05.json，
# 双序平衡配对 dict→typed→typed→dict）：dict 44.3 vs typed 43.3µs/结——Δ=−1.0µs
# （−2.2%）噪声级持平，typed 化无收益（主探针同进程配对曾读 +4-7µs，判读=机器热漂移
# 混杂非路径回归）。4.3 Dictionary（StringName 内联键 C++ 哈希）在小聚合规模已近
# 最优，聚合内部改写无可兑现收益。默认 false=字典原路径现行；开关留档供后续
# 「ctx 侧 typed 结构格式」路线（R233 候选，另立）复评，勿在无新数据时翻真。
static var AGG_TYPED: bool = false

# pool_id -> 衰减后有效和 Σ_add（F3 衰减 + F4 池钳后）
var add_pool_sum: Dictionary = {}
var flat_clamped: float = 0.0
# pool_id -> {contrib_sum: float, cap_pool: float, merged_M: float}（F6）
var mult_pools: Dictionary = {}
# top-N（≤cap_mul_count）截断后的有序乘区表；每项 {pool_id, agg, M}，按 (M−1) 降序
var resolved_mults: Array[Dictionary] = []
var product_clamped: float = 1.0              # min(∏ M_p, cap_prod)（F9）
var local_product: float = 1.0                # ∏ L_l（独立段）
var audit: DamageAudit = null                 # 审计（只记录不改结果）


# ── 步骤 3：Add 池聚合 ─────────────────────────────────────────────
# 同 ID 叠层过 F3 几何衰减 → 跨 ID 线性求和 → 负贡献（诅咒）全额不衰减 → F4 池钳。
# entries 每项：{trait_id, pool_id, layer, contrib, decay_delta, is_curse}
# pool_caps：pool_id -> cap_add_*（BalanceTables.add_pool_caps；缺项不钳制）
func aggregate_add(entries: Array[Dictionary], pool_caps: Dictionary) -> void:
	# R232 刀1e：AGG_TYPED=true 走 typed 累加（分组语义/求和序/物化形状逐位同字典路径）
	if AGG_TYPED:
		var tp_ids: Array[StringName] = []
		var tp_sums: Array[float] = []
		for e: Dictionary in entries:
			var pid_t: StringName = e.get("pool_id", &"")
			var idx_t := tp_ids.find(pid_t)
			var eff := _effective_add(e)
			if idx_t < 0:
				tp_ids.append(pid_t)
				tp_sums.append(eff)
			else:
				tp_sums[idx_t] = float(tp_sums[idx_t]) + eff
		for i in range(tp_ids.size()):
			add_pool_sum[tp_ids[i]] = float(tp_sums[i])
		return
	var grouped: Dictionary = {}          # pool_id -> Array[Dictionary]
	for e: Dictionary in entries:
		var pid: StringName = e.get("pool_id", &"")
		if not grouped.has(pid):
			grouped[pid] = []
		(grouped[pid] as Array).append(e)
	for pid in grouped:
		var total := 0.0
		for e: Dictionary in (grouped[pid] as Array):
			total += _effective_add(e)
		# R226 有意契约变更（用户拍板「肉鸽别搞上限，就是给人爽叠的」）：F4 池钳退役——
		# 原「pool 级保险丝（add_atk 钳 2.0 等，超帽记 audit.clamped_add）」拆除，加算池
		# 总额全额入伤害式（成长上限≠性能阀门，帧率保险丝在帧率优先数值刀/结算预算侧）。
		# pool_caps 入参保留（管线侧 :552 零改动、BalanceTables schema/校验不 churn），
		# 数据自此为不消费的遗留键
		add_pool_sum[pid] = total


# F3：T(n) = c × (1−δ^n)/(1−δ)；首层全额；δ≥1 退化为线性（校验层已拦 δ>0.92）；
# 负贡献/诅咒线性全额不衰减（A2 §1.3 裁定 #10：惩罚语义必须全额）。
func _effective_add(e: Dictionary) -> float:
	var contrib := float(e.get("contrib", 0.0))
	var layer := int(e.get("layer", 1))
	var delta := float(e.get("decay_delta", 0.0))
	var is_curse := bool(e.get("is_curse", false))
	if is_curse or contrib < 0.0:
		return contrib * float(maxi(layer, 0))
	if layer <= 1:
		return contrib
	if delta >= 1.0:
		return contrib * float(layer)
	return contrib * (1.0 - pow(delta, float(layer))) / (1.0 - delta)


# ── 步骤 4：Flat 比例钳制 ──────────────────────────────────────────
# Σ_flat ≤ f_flat × base_atk（超限截断 + audit.clamped_flat）；负值（诅咒）全额放行。
func apply_flat(flat_sum: float, base_atk: float, ratio_cap: float) -> void:
	var cap := ratio_cap * base_atk
	if flat_sum > cap:
		flat_clamped = cap
		if audit != null:
			audit.clamped_flat = true
	else:
		flat_clamped = flat_sum


# ── 步骤 5：乘区聚合（双层规则 + 单区钳 + 名额截断 + 整体钳） ──────
# a. 聚合层：按 pool_id 分组 → 贡献加算合并（F6，多实例合法来源）
# b. 防御层：同 (pool_id, source_uid) 多条 → 去重取最大 + audit.dedup_defense（恒空为健康）
# c. 单区钳制：每区 agg ≤ cap_pool_p（截断，设计内行为不审计）
# d. 名额截断：按 (M_p−1) 降序取 top-cap_mul_count（同值按 priority 决胜，再按 pool_id 定序——确定性）
# e. 整体钳制：∏ M_p ≤ cap_prod（min 截断 + audit.compressed，F9/F-16）
# entries 每项：{pool_id, source_uid, contrib, cap_pool}（可选 priority）
func aggregate_mults(entries: Array[Dictionary], cap_mul_count: int, cap_prod: float) -> void:
	# R232 刀1e：AGG_TYPED=true 走 typed 平行数组累加（分组语义/求和序/排序全序/
	# 物化形状逐位同字典路径——头注见 AGG_TYPED）
	if AGG_TYPED:
		_aggregate_mults_typed(entries, cap_mul_count, cap_prod)
		return
	_aggregate_mults_dict(entries, cap_mul_count, cap_prod)


func _aggregate_mults_typed(entries: Array[Dictionary], cap_mul_count: int,
		cap_prod: float) -> void:
	# ① 条目扫描（池表 StringName 线性扫——池数 ≤ 名额 8 量级；组内实例表同法）
	var tp_ids: Array[StringName] = []    # 池首现序
	var tp_caps: Array[float] = []        # 区内最大 cap_pool
	var tp_prio: Array[int] = []          # 区内最大 priority（决胜破序键）
	var tp_uids: Array = []               # 池内实例 uid 首现序（组内求和序=原插入序）
	var tp_vals: Array = []               # 与 tp_uids 平行的合并贡献
	for e: Dictionary in entries:
		var pid: StringName = e.get("pool_id", &"")
		var idx := tp_ids.find(pid)
		if idx < 0:
			idx = tp_ids.size()
			tp_ids.append(pid)
			tp_caps.append(0.0)
			tp_prio.append(0)
			tp_uids.append([])
			tp_vals.append([])
		var uid := int(e.get("source_uid", 0))
		var contrib := float(e.get("contrib", 0.0))
		var uids: Array = tp_uids[idx]
		var vals: Array = tp_vals[idx]
		var uidx := uids.find(uid)
		if uid == 0:
			# 无实例标识（构造期安全来源）：聚合层线性合并
			if uidx < 0:
				uids.append(0)
				vals.append(contrib)
			else:
				vals[uidx] = float(vals[uidx]) + contrib
		elif uidx >= 0:
			# ⑤b 防御层：同实例重入 → 取最大（B_spec M2 AC：×1.5 两次 → 150 而非 225）
			if contrib > float(vals[uidx]):
				vals[uidx] = contrib
			if audit != null:
				audit.dedup_defense.append({"pool_id": pid, "source_uid": uid})
		else:
			uids.append(uid)
			vals.append(contrib)
		var cap_f := float(e.get("cap_pool", 0.0))
		if cap_f > float(tp_caps[idx]):
			tp_caps[idx] = cap_f
		var prio := int(e.get("priority", 0))
		if prio > int(tp_prio[idx]):
			tp_prio[idx] = prio
	# ② 求和 + ⑤c 单区钳制 → 虚拟乘区 M_p = 1 + min(Σ, cap_pool_p)
	#（池序=首现序=原 grouped 插入序；组内求和序=实例首现序——浮点累加序逐位不变）
	for i in range(tp_ids.size()):
		var agg := 0.0
		var vals: Array = tp_vals[i]
		for j in range(vals.size()):
			agg += float(vals[j])
		var cap_p := float(tp_caps[i])
		if cap_p > 0.0 and agg > cap_p:
			agg = cap_p
		mult_pools[tp_ids[i]] = {"contrib_sum": agg, "cap_pool": cap_p, "merged_M": 1.0 + agg}
	# ③ ⑤d 名额截断：稳定全序（agg 降序 → priority 降序 → pool_id 字典序）
	#（索引排序+typed 平行键——全序比较器下与原 row-of-Array 排序逐位同结果）
	var n := tp_ids.size()
	var rows_m: Array[float] = []
	rows_m.resize(n)
	var rows_p: Array[int] = []
	rows_p.resize(n)
	var rows_id: Array[StringName] = []
	rows_id.resize(n)
	for i in range(n):
		var info: Dictionary = mult_pools[tp_ids[i]]
		rows_m[i] = float(info["merged_M"])
		rows_p[i] = int(tp_prio[i])
		rows_id[i] = tp_ids[i]
	var order: Array[int] = []
	order.resize(n)
	for i in range(n):
		order[i] = i
	order.sort_custom(func(a, b) -> bool:
		if not is_equal_approx(rows_m[a], rows_m[b]):
			return rows_m[a] > rows_m[b]
		if rows_p[a] != rows_p[b]:
			return rows_p[a] > rows_p[b]
		return String(rows_id[a]) < String(rows_id[b])
	)
	resolved_mults.clear()
	var truncated: Array[StringName] = []
	for oi in order:
		var pid: StringName = rows_id[oi]
		var info: Dictionary = mult_pools[pid]
		if resolved_mults.size() < maxi(cap_mul_count, 0):
			resolved_mults.append({"pool_id": pid, "agg": float(info["contrib_sum"]), "M": float(info["merged_M"])})
		else:
			truncated.append(pid)
	# ④ ⑤e 整体钳制（F9）+ 审计（与字典路径同形状同序）
	var raw_product := 1.0
	for m: Dictionary in resolved_mults:
		raw_product *= float(m["M"])
	product_clamped = minf(raw_product, cap_prod)
	if audit != null:
		audit.truncated_mults = truncated
		audit.compressed = raw_product > cap_prod
		audit.pool_count = resolved_mults.size()
		audit.mult_product = product_clamped


func _aggregate_mults_dict(entries: Array[Dictionary], cap_mul_count: int,
		cap_prod: float) -> void:
	var grouped: Dictionary = {}          # pool_id -> {source_uid -> 合并贡献}
	var caps_seen: Dictionary = {}        # pool_id -> 区内最大 cap_pool
	var pool_priority: Dictionary = {}    # pool_id -> 区内最大 priority（决胜破序键）
	for e: Dictionary in entries:
		var pid: StringName = e.get("pool_id", &"")
		if not grouped.has(pid):
			grouped[pid] = {}
		var by_source: Dictionary = grouped[pid]
		var uid := int(e.get("source_uid", 0))
		var contrib := float(e.get("contrib", 0.0))
		if uid == 0:
			# 无实例标识（构造期安全来源）：聚合层线性合并
			by_source[uid] = float(by_source.get(uid, 0.0)) + contrib
		elif by_source.has(uid):
			# ⑤b 防御层：同实例重入 → 取最大（B_spec M2 AC：×1.5 两次 → 150 而非 225）
			if contrib > float(by_source[uid]):
				by_source[uid] = contrib
			if audit != null:
				audit.dedup_defense.append({"pool_id": pid, "source_uid": uid})
		else:
			by_source[uid] = contrib
		caps_seen[pid] = maxf(float(caps_seen.get(pid, 0.0)), float(e.get("cap_pool", 0.0)))
		pool_priority[pid] = maxi(int(pool_priority.get(pid, 0)), int(e.get("priority", 0)))
	# ⑤a 求和 + ⑤c 单区钳制 → 虚拟乘区 M_p = 1 + min(Σ, cap_pool_p)
	for pid in grouped:
		var by_source: Dictionary = grouped[pid]
		var agg := 0.0
		for uid in by_source:
			agg += float(by_source[uid])
		var cap_p := float(caps_seen.get(pid, 0.0))
		if cap_p > 0.0 and agg > cap_p:
			agg = cap_p
		mult_pools[pid] = {"contrib_sum": agg, "cap_pool": cap_p, "merged_M": 1.0 + agg}
	# ⑤d 名额截断：稳定全序（agg 降序 → priority 降序 → pool_id 字典序）
	var sort_rows: Array = []
	for pid in mult_pools:
		var info: Dictionary = mult_pools[pid]
		sort_rows.append([float(info["merged_M"]), int(pool_priority.get(pid, 0)), pid])
	sort_rows.sort_custom(func(a, b) -> bool:
		if not is_equal_approx(float(a[0]), float(b[0])):
			return float(a[0]) > float(b[0])
		if int(a[1]) != int(b[1]):
			return int(a[1]) > int(b[1])
		return String(a[2]) < String(b[2])
	)
	resolved_mults.clear()
	var truncated: Array[StringName] = []
	for row in sort_rows:
		var pid: StringName = row[2]
		var info: Dictionary = mult_pools[pid]
		if resolved_mults.size() < maxi(cap_mul_count, 0):
			resolved_mults.append({"pool_id": pid, "agg": float(info["contrib_sum"]), "M": float(info["merged_M"])})
		else:
			truncated.append(pid)
	# ⑤e 整体钳制（F9）
	var raw_product := 1.0
	for m: Dictionary in resolved_mults:
		raw_product *= float(m["M"])
	product_clamped = minf(raw_product, cap_prod)
	if audit != null:
		audit.truncated_mults = truncated
		audit.compressed = raw_product > cap_prod
		audit.pool_count = resolved_mults.size()
		audit.mult_product = product_clamped


# ── 步骤 6：Local 池独立聚合（不入名额、不受 cap_prod，自有 cap_local，F-15） ──
# entries 每项：{local_id, contrib, cap_local}
func aggregate_local(entries: Array[Dictionary]) -> void:
	var by_id: Dictionary = {}           # local_id -> Σ contrib
	var caps: Dictionary = {}            # local_id -> cap_local
	for e: Dictionary in entries:
		var lid: StringName = e.get("local_id", &"")
		by_id[lid] = float(by_id.get(lid, 0.0)) + float(e.get("contrib", 0.0))
		caps[lid] = maxf(float(caps.get(lid, 0.0)), float(e.get("cap_local", 0.0)))
	var product := 1.0
	for lid in by_id:
		var agg := float(by_id[lid])
		var cap := float(caps.get(lid, 0.0))
		if cap > 0.0 and agg > cap:
			agg = cap
		product *= 1.0 + agg
	local_product = product
