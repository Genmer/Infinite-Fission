# scripts/core/damage/modifier_stack.gd
# A2 §7.2：聚合与护栏的唯一执行点（管线步骤 3~6 的产物，只算不改语义）。
# 四层护栏顺序固定：池聚合 → 单区 cap → 数量截断(top-N) → 乘积 cap（A2 §2.2 工程契约）。
# 本类不修改任何传入条目，不产生副作用（审计只记录不改结果，保证确定性与可复现）。
class_name ModifierStack
extends RefCounted

# pool_id -> 衰减后有效和 Σ_add（F3 衰减 + F4 池钳后）
var add_pool_sum: Dictionary = {}
var flat_clamped: float = 0.0
# pool_id -> {contrib_sum: float, cap_pool: float, merged_M: float}（F6）
var mult_pools: Dictionary = {}
# top-N（≤cap_mul_count）截断后的有序乘区表；每项 {pool_id, agg, M}，按 (M−1) 降序
var resolved_mults: Array[Dictionary] = []
var product_clamped: float = 1.0              # min(∏ M_p, cap_prod)（F9）
var local_product: float = 1.0                # ∏ L_l（独立段）
var chip_product: float = 1.0                 # v0.7.0：1 + Σchip（cap_chip_zone 钳后；独立乘区段）
var audit: DamageAudit = null                 # 审计（只记录不改结果）


# ── 步骤 3：Add 池聚合 ─────────────────────────────────────────────
# 同 ID 叠层过 F3 几何衰减 → 跨 ID 线性求和 → 负贡献（诅咒）全额不衰减 → F4 池钳。
# entries 每项：{trait_id, pool_id, layer, contrib, decay_delta, is_curse}
# pool_caps：pool_id -> cap_add_*（BalanceTables.add_pool_caps；缺项不钳制）
func aggregate_add(entries: Array[Dictionary], pool_caps: Dictionary) -> void:
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
		var cap = pool_caps.get(pid)
		if cap != null and total > float(cap):
			# F4 池级保险丝（正常游玩不可达，触发即记审计）
			total = float(cap)
			if audit != null:
				audit.clamped_add.append(pid)
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


# ── 步骤 6b：芯片独立乘区段聚合（v0.7.0，A6 §3） ────────────────────
# entries 每项：{stat: StringName, contrib: float}。负贡献钳 0（芯片无诅咒语义）；
# Σ > p_cap → 截断 + audit.clamped_chip；chip_product = 1 + Σ_clamped。
# 与乘区段互相独立：不入名额、不占 cap_mul_count，联合钳制在管线 _finalize
#（joint = min(mult_product × chip_product, cap_prod)）。
func aggregate_chip(entries: Array[Dictionary], p_cap: float) -> void:
	var total := 0.0
	for e: Dictionary in entries:
		total += maxf(float(e.get("contrib", 0.0)), 0.0)
	if total > p_cap:
		total = p_cap
		if audit != null:
			audit.clamped_chip = true
	chip_product = 1.0 + total
	if audit != null:
		audit.chip_product = chip_product
