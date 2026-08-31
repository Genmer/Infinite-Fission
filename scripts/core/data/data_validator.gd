# scripts/core/data/data_validator.gd
# M-14 DataValidator：启动校验 + 降级 + 错误清单（架构 §2.6/§六.2）。
# 原则：内容数据"剔除 + 清单"不崩溃；错误条目含文件名（validate_all 经 DataRegistry 补全）
# 与字段名（field）。返回格式：Array[Dictionary]，每项 {field, message, severity}
#（severity ∈ {SEV_ERROR, SEV_WARNING}；仅 SEV_ERROR 触发剔除宿主）。
# 架构补充说明：架构 §2.2 点名 "_load_balance → DataValidator 校验"，故本类在骨架方法之外
# 追加 validate_balance（§三.8 校验列；致命集口径见 §六.2）。
class_name DataValidator
extends RefCounted

const SEV_ERROR := "error"
const SEV_WARNING := "warning"

# ── 封闭注册表（A2 §1.9 守门；来源：A3 §4.2/§4.3 + BalanceTables.add_pool_caps + A2 §1.8）──
# 加算池 id 全集（A3 §4.2 十二条 + v0.6.0 金币两条；BalanceTables.add_pool_caps 覆盖前五项的池钳）
# ★ 金币两池不入 LINEAR_ADD_POOLS——走 F3 衰减（TraitStack.aggregate_panel 消费）
const ADD_POOL_IDS: Array[StringName] = [
	&"add_atk", &"add_rof", &"add_cdr", &"add_crit", &"add_critdmg",
	&"add_spd", &"add_hp", &"add_move", &"add_pickup", &"add_size", &"add_pierce", &"add_pellets",
	&"add_gold_drop", &"add_gold_value",
]
# 独立乘区池 id 全集（§三.5 + A3 §4.3；vuln 为目标侧易伤区，A2 §1.8）
const MULT_POOL_IDS: Array[StringName] = [
	&"frost_dmg", &"burn_dmg", &"bounce_dmg", &"pierce_dmg",
	&"fury_dmg", &"opening_dmg", &"elite_dmg", &"vuln",
]
# Local 私有池 id 全集（F-15：当前唯一实例 = 光束灼焦）
const LOCAL_POOL_IDS: Array[StringName] = [&"scorch"]
# EventBus 事件名注册表镜像（§2.1 18 信号清单——包 0 冻结；与 autoload/event_bus.gd 信号表双源，改动需同步；
# v0.6.0 增 gold_changed；v0.7.0 增 chip_slot_unlocked / gold_rush_started，共 21）
const EVENT_NAMES: Array[StringName] = [
	&"state_changed", &"config_fatal", &"data_validated", &"damage_resolved", &"damage_alarm",
	&"enemy_killed", &"boss_spawned", &"player_hit", &"player_died", &"level_up", &"xp_gained",
	&"gold_changed",
	&"wave_started", &"wave_cleared", &"slot_unlocked", &"reaction_triggered", &"pool_exhausted",
	&"chain_fused", &"card_chosen",
	&"chip_slot_unlocked", &"gold_rush_started",
]
# contribution_expr 白名单模板（§三.5：两个模板，编译期映射；禁运行时 Expression）
const CONTRIBUTION_EXPRS: Array[String] = ["value", "value * (ctx.pierce_index - 1)"]
# builtin 效果处理器注册表镜像（AC-13.3；与 TraitEffect._BUILTIN_PATHS 七家族键对账——
# EF_CRIT_SHARD 随审查 Fix 4 落地，双清单必须同步）
const TECH_EFFECT_IDS: Array[StringName] = [
	&"EF_STAT", &"EF_SIZE", &"EF_FRACTAL", &"EF_BOUNCE", &"EF_ELEMENTAL", &"EF_MECH",
	&"EF_CRIT_SHARD",
]
# F-21 硬约束（与 BalanceTables.decay_delta_max 默认值一致；单一常数避免加载循环依赖）
const MAX_DECAY_DELTA := 0.92


func validate_all(registry: DataRegistry) -> Dictionary:
	# 全量校验 → {fatal[], rejected[], warnings[], errors[], total}
	var fatal: Array = []
	var rejected: Array = []
	var errors: Array = []
	var warnings: Array = []
	var total := 0
	total += _run_category(registry, &"weapons", registry.weapons, "validate_weapon", rejected, errors, warnings)
	total += _run_category(registry, &"enemies", registry.enemies, "validate_enemy", rejected, errors, warnings)
	total += _run_category(registry, &"traits", registry.traits, "validate_trait", rejected, errors, warnings)
	total += _run_category(registry, &"relics", registry.relics, "validate_relic", rejected, errors, warnings)
	total += _run_category(registry, &"synergies", registry.synergies, "validate_synergy", rejected, errors, warnings)
	total += _run_category(registry, &"chips", registry.chips, "validate_chip", rejected, errors, warnings)
	# 单件类目：波表 / GameFeel（条目级问题已就地降级；字段级错误 → 剔除整件）
	if registry.wave_table != null:
		total += 1
		_absorb_single(registry, &"wave_table", registry.wave_table, "validate_wave_table", rejected, errors, warnings)
	if registry.game_feel != null:
		total += 1
		_absorb_single(registry, &"game_feel", registry.game_feel, "validate_game_feel", rejected, errors, warnings)
	# 引用完整性（AC-13.3：悬空引用剔除/降级 + 告警）
	for issue in check_references(registry):
		if String(issue.get("severity", SEV_WARNING)) == SEV_ERROR:
			errors.append(issue)
		else:
			warnings.append(issue)
	return {"fatal": fatal, "rejected": rejected, "errors": errors, "warnings": warnings, "total": total}


func validate_weapon(w: WeaponData) -> Array:
	# 单类校验（规则见 §三.1）
	var out: Array = []
	_err(out, &"id", w.id == &"", "id 非空")
	_warn(out, &"display_name", w.display_name == "", "display_name 为空（仅告警）")
	_err(out, &"form", w.form < 0 or w.form > 3, "form ∈ {0,1,2,3}")
	_err(out, &"crit_rate", w.crit_rate < 0.0 or w.crit_rate > 1.0, "crit_rate ∈ [0, 1]")
	_err(out, &"crit_dmg", w.crit_dmg < 1.0 or w.crit_dmg > 5.0, "crit_dmg ∈ [1, 5]（F-30 基线 ×2.0）")
	_err(out, &"hitbox_r", w.hitbox_r <= 0.0 or w.hitbox_r > 64.0, "hitbox_r ∈ (0, 64]")
	_err(out, &"upgrade_table", w.upgrade_table.size() != 5, "upgrade_table 恰好 5 项（L1~L5），当前 %d 项" % w.upgrade_table.size())
	for i in range(w.upgrade_table.size()):
		var lv: WeaponLevelStats = w.upgrade_table[i]
		var f := "upgrade_table[%d]." % i
		_err(out, StringName(f + "base_atk"), lv.base_atk <= 0.0, "base_atk > 0（负攻 → 剔除宿主，AC-13.2）")
		_err(out, StringName(f + "rof"), lv.rof <= 0.0 or lv.rof > 30.0, "rof ∈ (0, 30]（cap_rof 双护栏；负射速 → 剔除宿主，AC-13.2）")
		if w.form != GameConst.WeaponForm.BALLISTIC:
			_err(out, StringName(f + "cd"), lv.cd <= 0.0, "LASER/HOMING/MELEE 形态 cd > 0")
		_err(out, StringName(f + "pierce"), lv.pierce < 0, "pierce ≥ 0")
		_err(out, StringName(f + "pellets"), lv.pellets < 1, "pellets ≥ 1")
	# threshold_traits：必填键完整（metric 封闭枚举与 effect 处理器注册表校验属包 3，此处查结构）
	for i in range(w.threshold_traits.size()):
		var tt: Dictionary = w.threshold_traits[i]
		var f := "threshold_traits[%d]." % i
		for key in [&"threshold_id", &"metric", &"threshold", &"effect_id", &"params"]:
			_err(out, StringName(f + String(key)), not tt.has(String(key)), "缺键 %s" % String(key))
		if tt.has("effect_id") and StringName(str(tt.get("effect_id"))) == &"":
			_err(out, StringName(f + "effect_id"), true, "effect_id 非空")
	# 形态专属段（按 form 取用；未启用段忽略校验）
	match w.form:
		GameConst.WeaponForm.BALLISTIC:
			_validate_ballistic_segment(w.ballistic, out)
		GameConst.WeaponForm.LASER:
			_validate_laser_segment(w.laser, out)
		GameConst.WeaponForm.HOMING:
			_validate_homing_segment(w.homing, out)
		GameConst.WeaponForm.MELEE:
			_validate_melee_segment(w.melee, out)
	return out


func validate_enemy(e: EnemyData) -> Array:
	# 单类校验（规则见 §三.2）
	var out: Array = []
	_err(out, &"id", e.id == &"", "id 非空")
	_err(out, &"behavior", e.behavior < 0 or e.behavior > 4, "behavior ∈ EnemyBehavior 枚举")
	if e.behavior > GameConst.EnemyBehavior.RANGED:
		# M1 只支持 CHASE/RANGED：其余告警降级为 CHASE（§三.2 校验列）
		_warn(out, &"behavior", true, "M1 仅支持 CHASE/RANGED，降级为 CHASE")
		e.behavior = GameConst.EnemyBehavior.CHASE
	_err(out, &"hp_base", e.hp_base <= 0.0, "hp_base > 0")
	_err(out, &"spd_base", e.spd_base < 0.0 or e.spd_base > 600.0, "spd_base ∈ [0, 600]")
	_err(out, &"dmg_base", e.dmg_base < 0.0 or e.dmg_base > 200.0, "dmg_base ∈ [0, 200]")
	_err(out, &"exp_base", e.exp_base < 0.0, "exp_base ≥ 0")
	_err(out, &"tp_cost", e.tp_cost <= 0.0, "tp_cost > 0")
	_err(out, &"resist", e.resist.size() != 4, "resist 恰好 4 项（KIN/FIR/ICE/LTG）")
	for i in range(e.resist.size()):
		_err(out, StringName("resist[%d]" % i), e.resist[i] < -0.8 or e.resist[i] > 0.8, "resist[%d] ∈ [-0.8, 0.8]" % i)
	_err(out, &"immune_mask", e.immune_mask & ~(GameConst.IMMUNE_FREEZE | GameConst.IMMUNE_CHILL | GameConst.IMMUNE_BURN | GameConst.IMMUNE_SHOCK) != 0, "immune_mask 已知位组合（IMMUNE_* 位）")
	_err(out, &"tags", e.tags & ~(GameConst.TAG_ELITE | GameConst.TAG_BOSS) != 0, "tags 仅 TAG_ELITE/TAG_BOSS 位")
	_err(out, &"hitbox_r", e.hitbox_r <= 0.0 or e.hitbox_r > 64.0, "hitbox_r ∈ (0, 64]")
	if e.behavior == GameConst.EnemyBehavior.RANGED:
		_err(out, &"ranged", e.ranged.is_empty(), "behavior=RANGED 必填 ranged 段")
		for key in ["bullet_speed", "fire_cd", "bullet_atk_ratio", "spread"]:
			_err(out, StringName("ranged." + key), not e.ranged.has(key), "ranged 缺键 %s" % key)
		if e.ranged.has("fire_cd"):
			_err(out, &"ranged.fire_cd", float(e.ranged["fire_cd"]) <= 0.0, "fire_cd > 0")
	if e.tags & GameConst.TAG_BOSS:
		_err(out, &"boss", e.boss.is_empty(), "tags 含 BOSS 必填 boss 段")
		for key in ["phases", "bullet_patterns", "summons", "phase2_resist"]:
			_err(out, StringName("boss." + key), not e.boss.has(key), "boss 缺键 %s" % key)
	# v0.6.0 金币掉落段结构校验（仅告警——空段 = 不掉金币，合法；坏值 → 告警 + 掉落侧 guard 兜底）
	if not e.gold_drop.is_empty():
		_warn(out, &"gold_drop.chance", not e.gold_drop.has("chance")
			or float(e.gold_drop["chance"]) < 0.0 or float(e.gold_drop["chance"]) > 1.0,
			"gold_drop.chance ∈ [0, 1]")
		_warn(out, &"gold_drop.min", not e.gold_drop.has("min")
			or float(e.gold_drop["min"]) < 0.0, "gold_drop.min ≥ 0")
		_warn(out, &"gold_drop.min", not e.gold_drop.has("min") or not e.gold_drop.has("max")
			or float(e.gold_drop["min"]) > float(e.gold_drop["max"]), "gold_drop.min ≤ gold_drop.max")
	return out


func validate_trait(t: TraitData) -> Array:
	# 单类校验（B_spec §2.5 L1 守门：pool 合法/δ≤0.92/cap_pool_p；规则见 §三.3）
	var out: Array = []
	_err(out, &"id", t.id == &"", "id 非空")
	_err(out, &"pool", t.pool < GameConst.PoolClass.ADD or t.pool > GameConst.PoolClass.ELEM, "pool ∈ {ADD, MULT, LOCAL, MECH, ELEM}")
	# pool_id：ADD/MULT/LOCAL 类必填且 ∈ 封闭枚举注册表；MECH/ELEM 可空
	match t.pool:
		GameConst.PoolClass.ADD:
			_err(out, &"pool_id", t.pool_id == &"" or not ADD_POOL_IDS.has(t.pool_id), "pool_id 必填且 ∈ 加算池封闭注册表")
		GameConst.PoolClass.MULT:
			_err(out, &"pool_id", t.pool_id == &"" or not MULT_POOL_IDS.has(t.pool_id), "pool_id 必填且 ∈ 乘区封闭注册表")
		GameConst.PoolClass.LOCAL:
			_err(out, &"pool_id", t.pool_id == &"" or not LOCAL_POOL_IDS.has(t.pool_id), "pool_id 必填且 ∈ Local 池封闭注册表")
	# effect_id 必填且 ∈ builtin 处理器注册表（AC-13.3 悬空 effect_id 剔除）
	_err(out, &"effect_id", t.effect_id == &"" or not TECH_EFFECT_IDS.has(t.effect_id),
		"effect_id 必填且 ∈ TECH_EFFECT_IDS（EF_STAT/EF_SIZE/EF_FRACTAL/EF_BOUNCE/EF_ELEMENTAL/EF_MECH/EF_CRIT_SHARD）")
	_err(out, &"stack_max", t.stack_max < 1, "stack_max ≥ 1")
	if t.pool == GameConst.PoolClass.ADD:
		_err(out, &"decay_delta", t.decay_delta <= 0.0 or t.decay_delta > MAX_DECAY_DELTA,
			"ADD 类必填 decay_delta 且 ∈ (0, 0.92]（F-21；当前 %.4f）" % t.decay_delta)
	if t.pool == GameConst.PoolClass.MULT:
		_err(out, &"cap_pool_p", t.cap_pool_p <= 0.0, "MULT 类必填 cap_pool_p > 0（F-14）")
	if t.pool == GameConst.PoolClass.LOCAL:
		_err(out, &"cap_local", t.cap_local <= 0.0, "LOCAL 类必填 cap_local > 0（F-15）")
	_err(out, &"proc_chance", t.proc_chance <= 0.0 or t.proc_chance > 1.0, "proc_chance ∈ (0, 1]")
	_err(out, &"cooldown", t.cooldown < 0.0, "cooldown ≥ 0")
	# MULT 类条件：{condition_id, params}；condition_id ∈ ConditionId 封闭枚举
	if t.pool == GameConst.PoolClass.MULT and not t.condition.is_empty():
		_err(out, &"condition.condition_id", not t.condition.has("condition_id"), "MULT 类 condition 缺 condition_id")
		if t.condition.has("condition_id"):
			var cid := int(t.condition["condition_id"])
			_err(out, &"condition.condition_id", cid < 0 or cid > GameConst.ConditionId.NONE, "condition_id ∈ ConditionId 枚举（0~8）")
	return out


func validate_relic(r: RelicData) -> Array:
	# 单类校验（规则见 §三.4）
	var out: Array = []
	_err(out, &"id", r.id == &"", "id 非空")
	_warn(out, &"rarity", r.rarity != 3, "稀有度统一金（=3）")
	for i in range(r.listen_events.size()):
		var ev: StringName = r.listen_events[i]
		_err(out, StringName("listen_events[%d]" % i), not EVENT_NAMES.has(ev),
			"listen_events ∈ EventBus 事件名注册表（悬空 → 剔除，AC-13.3）：%s" % String(ev))
	_err(out, &"effect_id", r.effect_id == &"", "effect_id 必填（遗物效果处理器注册表校验属包 3/4）")
	return out


func validate_synergy(s: SynergyRuleData) -> Array:
	# 单类校验（规则见 §三.5）
	var out: Array = []
	_err(out, &"id", s.id == &"", "id 非空")
	_err(out, &"pool_id", s.pool_id == &"" or not MULT_POOL_IDS.has(s.pool_id), "pool_id ∈ 乘区封闭枚举")
	_err(out, &"condition_id", s.condition_id < 0 or s.condition_id > GameConst.ConditionId.NONE, "condition_id ∈ ConditionId 枚举（0~8）")
	_err(out, &"contribution_expr", not CONTRIBUTION_EXPRS.has(s.contribution_expr),
		"contribution_expr ∈ 白名单模板（禁运行时 Expression）：%s" % s.contribution_expr)
	_err(out, &"cap_pool_p", s.cap_pool_p <= 0.0, "cap_pool_p > 0 必填（F-14）")
	return out


func validate_chip(c: ChipData) -> Array:
	# v0.7.0 单类校验（A6 §1）：id 非空 / stat_key ∈ CHIP_STAT_KEYS / values 恰好 4 档
	# 且全 >0 单调不减；display_name 空 → warning。
	var out: Array = []
	_err(out, &"id", c.id == &"", "id 非空")
	_err(out, &"stat_key", c.stat_key == &"" or not GameConst.CHIP_STAT_KEYS.has(c.stat_key),
		"stat_key ∈ GameConst.CHIP_STAT_KEYS（悬空 → 剔除）：%s" % String(c.stat_key))
	_err(out, &"values", c.values.size() != 4, "values 恰好 4 档（白/蓝/紫/金），当前 %d 项" % c.values.size())
	for i in range(c.values.size()):
		_err(out, StringName("values[%d]" % i), c.values[i] <= 0.0, "values[%d] > 0" % i)
		if i > 0:
			_err(out, StringName("values[%d]" % i), c.values[i] < c.values[i - 1],
				"values 单调不减（values[%d] < values[%d]）" % [i, i - 1])
	_warn(out, &"display_name", c.display_name == "", "display_name 为空（仅告警）")
	return out


func validate_wave_table(t: WaveTableData) -> Array:
	# 单类校验（规则见 §三.6）：index 唯一（重复 → 后者剔除）；缺失波回退公式（降级不崩溃）
	var out: Array = []
	_err(out, &"id", t.id == &"", "id 非空")
	var seen: Dictionary = {}
	var drop_entries: Array[int] = []
	for i in range(t.entries.size()):
		var entry: WaveEntryData = t.entries[i]
		var f := "entries[%d]." % i
		_err(out, StringName(f + "index"), entry.index < 1 or entry.index > 30, "index ∈ [1, 30]")
		if seen.has(entry.index):
			_err(out, StringName(f + "index"), true, "index 重复（后者剔除）：%d" % entry.index)
			drop_entries.append(i)
		else:
			seen[entry.index] = true
		_err(out, StringName(f + "window"), entry.window <= 0.0, "window > 0")
		# composition 条目结构校验（enemy_id 悬空剔除在 check_references）
		var kept: Array[Dictionary] = []
		for j in range(entry.composition.size()):
			var comp: Dictionary = entry.composition[j]
			var cf := "%scomposition[%d]." % [f, j]
			var bad := false
			if not comp.has("enemy_id") or StringName(str(comp.get("enemy_id", ""))) == &"":
				_err(out, StringName(cf + "enemy_id"), true, "enemy_id 非空")
				bad = true
			if not comp.has("count") or int(comp.get("count", 0)) < 1:
				_err(out, StringName(cf + "count"), true, "count ≥ 1")
				bad = true
			if not bad:
				kept.append(comp)
		entry.composition = kept
	# 剔除重复 index 的后来条目（就地降级）
	if not drop_entries.is_empty():
		var kept_entries: Array[WaveEntryData] = []
		for i in range(t.entries.size()):
			if not drop_entries.has(i):
				kept_entries.append(t.entries[i])
		t.entries = kept_entries
	# 缺失波（非连续）→ 告警（运行时回退 TP 公式生成）
	if not t.entries.is_empty():
		var indices: Array[int] = []
		for entry: WaveEntryData in t.entries:
			indices.append(entry.index)
		indices.sort()
		for i in range(1, indices.size()):
			if indices[i] - indices[i - 1] > 1:
				_warn(out, &"entries", true, "波次非连续（%d→%d，缺失波回退公式生成）" % [indices[i - 1], indices[i]])
	return out


func validate_game_feel(g: GameFeelConfig) -> Array:
	# 单类校验（规则见 §三.7）
	var out: Array = []
	_err(out, &"hit_stop_ms", g.hit_stop_ms.size() != 4, "hit_stop_ms 恰好 4 项（FeelLevel 索引）")
	for i in range(g.hit_stop_ms.size()):
		_err(out, StringName("hit_stop_ms[%d]" % i), g.hit_stop_ms[i] < 0 or g.hit_stop_ms[i] > 200, "hit_stop_ms[%d] ∈ [0, 200]" % i)
	_err(out, &"hit_stop_scale", g.hit_stop_scale <= 0.0 or g.hit_stop_scale >= 1.0, "hit_stop_scale ∈ (0, 1)")
	_err(out, &"hit_stop_merge_ms", g.hit_stop_merge_ms <= 0, "hit_stop_merge_ms > 0（AC-15.2）")
	_err(out, &"shake_trauma", g.shake_trauma.size() != 4, "shake_trauma 恰好 4 项")
	for i in range(g.shake_trauma.size()):
		_err(out, StringName("shake_trauma[%d]" % i), g.shake_trauma[i] < 0.0 or g.shake_trauma[i] > 1.0, "shake_trauma[%d] ∈ [0, 1]" % i)
	_err(out, &"shake_max_offset_px", g.shake_max_offset_px <= 0.0 or g.shake_max_offset_px > 32.0, "shake_max_offset_px ∈ (0, 32]（Q-12）")
	_err(out, &"shake_max_rot_deg", g.shake_max_rot_deg <= 0.0 or g.shake_max_rot_deg > 8.0, "shake_max_rot_deg ∈ (0, 8]")
	_err(out, &"shake_decay_s", g.shake_decay_s <= 0.0 or g.shake_decay_s > 2.0, "shake_decay_s ∈ (0, 2]")
	_err(out, &"ca_base_intensity", g.ca_base_intensity <= 0.0, "ca_base_intensity > 0（Q-12 起跳）")
	_err(out, &"ca_decay_s", g.ca_decay_s <= 0.0 or g.ca_decay_s > 1.0, "ca_decay_s ∈ (0, 1]")
	_err(out, &"ca_level_mult", g.ca_level_mult.size() != 4, "ca_level_mult 恰好 4 项")
	_err(out, &"particle_max_emitters", g.particle_max_emitters <= 0, "particle_max_emitters > 0（AC-15.5）")
	for key in g.particle_priorities:
		var v := int(g.particle_priorities[key])
		_err(out, StringName("particle_priorities." + String(key)), v < 1 or v > 5, "particle_priorities.%s ∈ [1, 5]" % String(key))
	return out


func validate_balance(bt: BalanceTables) -> Array:
	# §三.8 BalanceTables 校验（GameConfig._load_balance 调用；致命集口径 §六.2）：
	# 致命：res_logic 错 / pool_prewarm 任一 ≤0 / cap_prod ≤0 → 拒绝启动；
	# 非致命：范围违规 → 字段级回退默认值 + 告警。
	var out: Array = []
	# —— 致命集 ——
	if bt.res_logic != Vector2i(720, 1280):
		out.append({"field": "res_logic", "fatal": true, "message": "res_logic 必须为 720×1280（F-01 裁定），当前 %s" % str(bt.res_logic)})
	for k in [&"projectile", &"enemy", &"popup", &"particle", &"laser", &"xp", &"gold"]:
		var v = bt.pool_prewarm.get(k)
		if v == null or int(v) <= 0:
			out.append({"field": "pool_prewarm", "fatal": true, "message": "pool_prewarm.%s 缺失或 ≤0（致命：拒绝启动）" % String(k)})
	if bt.cap_prod <= 0.0:
		out.append({"field": "cap_prod", "fatal": true, "message": "cap_prod ≤ 0（致命：拒绝启动）"})
	# —— 非致命范围校验（§三.8 校验列）——
	_nf(out, "cap_prod", bt.cap_prod < 2.0 or bt.cap_prod > 32.0, "cap_prod ∈ [2, 32]")
	_nf(out, "r_alarm_ratio", bt.r_alarm_ratio <= 0.0, "r_alarm_ratio > 0")
	_nf(out, "cap_mul_count", bt.cap_mul_count < 4 or bt.cap_mul_count > 16, "cap_mul_count ∈ [4, 16]")
	_nf(out, "cap_proj_traits", bt.cap_proj_traits <= 0, "cap_proj_traits > 0")
	_nf(out, "flat_ratio_cap", bt.flat_ratio_cap <= 0.0 or bt.flat_ratio_cap > 2.0, "flat_ratio_cap ∈ (0, 2]")
	var bad_add_cap := false
	for k in bt.add_pool_caps:
		if float(bt.add_pool_caps[k]) <= 0.0:
			bad_add_cap = true
	_nf(out, "add_pool_caps", bad_add_cap, "add_pool_caps 每值 > 0（F4 保险丝）")
	_nf(out, "cap_rof_per_weapon", bt.cap_rof_per_weapon <= 0.0, "cap_rof_per_weapon > 0")
	_nf(out, "cap_chip_zone", bt.cap_chip_zone <= 0.0 or bt.cap_chip_zone > 4.0, "cap_chip_zone ∈ (0, 4]")
	_nf(out, "decay_delta_max", bt.decay_delta_max <= 0.0 or bt.decay_delta_max > 1.0, "decay_delta_max ∈ (0, 1]")
	_nf(out, "split_max_generation", bt.split_max_generation <= 0, "split_max_generation > 0（E-01）")
	_nf(out, "split_max_children", bt.split_max_children <= 0, "split_max_children > 0（E-01）")
	_nf(out, "split_inherit_ratio", bt.split_inherit_ratio <= 0.0 or bt.split_inherit_ratio > 1.0, "split_inherit_ratio ∈ (0, 1]")
	_nf(out, "projectile_soft_limit", bt.projectile_soft_limit <= 0, "projectile_soft_limit > 0")
	_nf(out, "projectile_hard_limit", bt.projectile_hard_limit <= 0, "projectile_hard_limit > 0")
	_nf(out, "projectile_limits", bt.projectile_soft_limit > bt.projectile_hard_limit, "软上限 ≤ 硬上限")
	_nf(out, "frame_budget_ms", bt.frame_budget_ms <= 0.0, "frame_budget_ms > 0")
	_nf(out, "contact_tick", bt.contact_tick <= 0.0, "contact_tick > 0（F-35）")
	_nf(out, "pickup_radius", bt.pickup_radius <= 0.0, "pickup_radius > 0（Q-13）")
	_nf(out, "hp_growth_per_wave", bt.hp_growth_per_wave <= 0.0, "hp_growth_per_wave > 0")
	_nf(out, "dmg_growth_per_wave", bt.dmg_growth_per_wave <= 0.0, "dmg_growth_per_wave > 0")
	_nf(out, "spd_growth_per_wave", bt.spd_growth_per_wave < 0.0, "spd_growth_per_wave ≥ 0")
	_nf(out, "exp_inflation_per_wave", bt.exp_inflation_per_wave <= 0.0, "exp_inflation_per_wave > 0")
	_nf(out, "xp_curve", float(bt.xp_curve.get("base", 0.0)) <= 0.0 or float(bt.xp_curve.get("power", 0.0)) <= 0.0, "xp_curve 值 > 0")
	var weight_sum := 0
	for k in bt.rarity_weights:
		weight_sum += int(bt.rarity_weights[k])
	_nf(out, "rarity_weights", weight_sum <= 0, "rarity_weights 权重和 > 0")
	var cat_sum := 0
	for k in bt.category_weights:
		cat_sum += int(bt.category_weights[k])
	_nf(out, "category_weights", cat_sum <= 0, "category_weights 权重和 > 0")
	_nf(out, "cd_rxn", bt.cd_rxn <= 0.0, "cd_rxn > 0（F-34）")
	_nf(out, "element_decay_lambda", bt.element_decay_lambda.size() != 3, "element_decay_lambda 恰好 3 项（FIR/ICE/LTG）")
	for i in range(bt.element_decay_lambda.size()):
		_nf(out, "element_decay_lambda", bt.element_decay_lambda[i] <= 0.0, "element_decay_lambda[%d] > 0（F-22）" % i)
	for k in [&"burn", &"freeze", &"shock"]:
		_nf(out, "element_states", not bt.element_states.has(String(k)), "element_states 缺状态 %s（§2.10 契约键）" % String(k))
	var bad_rxn := false
	for k in bt.reaction_table:
		var rule: Dictionary = bt.reaction_table[k]
		if rule.has("coef") and float(rule["coef"]) <= 0.0:
			bad_rxn = true
	_nf(out, "reaction_table", bad_rxn, "reaction_table 系数 > 0（§2.4）")
	_nf(out, "event_storm_threshold", bt.event_storm_threshold <= 0, "event_storm_threshold > 0（§六.4）")
	return out


func check_references(registry: DataRegistry) -> Array:
	# 引用完整性（AC-13.3）：
	# ① 波表 composition.enemy_id 悬空 → 剔除该敌条目 + 告警（§三.6）；
	# ② WeaponData.threshold_traits.effect_id 悬空（∉ TECH_EFFECT_IDS）→ 剔除该 threshold
	#    条目 + 告警（不整枪剔除——宿主武器其余词条/形态段合法，AC-13.3 降级不崩溃；
	#    审查 Fix 4 落地，注释原「随包 3 落地」空承诺就此兑现）；
	# ③ RelicData.listen_events 悬空 → validate_relic 内经事件名注册表剔除（无需跨表）。
	var issues: Array = []
	if registry.wave_table != null:
		for entry: WaveEntryData in registry.wave_table.entries:
			var kept: Array[Dictionary] = []
			for comp: Dictionary in entry.composition:
				var eid: StringName = StringName(str(comp.get("enemy_id", "")))
				if eid == &"" or not registry.enemies.has(eid):
					issues.append({
						"category": &"wave_table", "id": registry.wave_table.id,
						"field": "entries.composition.enemy_id", "severity": SEV_WARNING,
						"message": "enemy_id 悬空，剔除该敌条目 + 告警：%s" % String(eid),
					})
				else:
					kept.append(comp)
			entry.composition = kept
	for wid in registry.weapons.keys():
		var weapon: WeaponData = registry.weapons[wid]
		if weapon == null or weapon.threshold_traits.is_empty():
			continue
		var kept_th: Array[Dictionary] = []
		for th: Dictionary in weapon.threshold_traits:
			var fid: StringName = StringName(str(th.get("effect_id", "")))
			if fid == &"" or not TECH_EFFECT_IDS.has(fid):
				issues.append({
					"category": &"weapons", "id": wid,
					"field": "threshold_traits.effect_id", "severity": SEV_WARNING,
					"message": "threshold effect_id 悬空，剔除该 threshold 条目（宿主保留）+ 告警：%s" % String(fid),
				})
			else:
				kept_th.append(th)
		if kept_th.size() != weapon.threshold_traits.size():
			weapon.threshold_traits = kept_th
	return issues


# ── 内部工具 ──────────────────────────────────────────────────────
func _run_category(registry: DataRegistry, category: StringName, table: Dictionary, method: String,
		rejected: Array, errors: Array, warnings: Array) -> int:
	# 校验单类目全部条目；返回处理条数。仅 SEV_ERROR 条目进入 rejected（由 DataRegistry 应用剔除）。
	var count := 0
	for id in table.keys():
		var item: Resource = table[id]
		count += 1
		var verdicts: Array = call(method, item)
		var item_errors: Array = []
		var item_warnings: Array = []
		for v in verdicts:
			if String(v.get("severity", SEV_ERROR)) == SEV_ERROR:
				item_errors.append(v)
			else:
				item_warnings.append(v)
		var file_path := registry.get_source(category, id)
		for v: Dictionary in item_errors:
			errors.append({"category": category, "id": id, "file": file_path,
				"field": v["field"], "message": v["message"], "severity": SEV_ERROR})
		for v: Dictionary in item_warnings:
			warnings.append({"category": category, "id": id, "file": file_path,
				"field": v["field"], "message": v["message"], "severity": SEV_WARNING})
		if not item_errors.is_empty():
			rejected.append({"category": category, "id": id, "file": file_path, "errors": item_errors})
	return count


func _absorb_single(registry: DataRegistry, category: StringName, item: Resource, method: String,
		rejected: Array, errors: Array, warnings: Array) -> void:
	# 单件类目（波表/GameFeel）校验吸收；GameFeelConfig 无 id 字段（单例配置），以类目名代之。
	var id_raw = item.get("id")
	var rid: StringName = StringName(str(id_raw)) if id_raw != null else &""
	var file_path := registry.get_source(category, rid)
	var verdicts: Array = call(method, item)
	var item_errors: Array = []
	for v in verdicts:
		if String(v.get("severity", SEV_ERROR)) == SEV_ERROR:
			item_errors.append(v)
			errors.append({"category": category, "id": rid, "file": file_path,
				"field": v["field"], "message": v["message"], "severity": SEV_ERROR})
		else:
			warnings.append({"category": category, "id": rid, "file": file_path,
				"field": v["field"], "message": v["message"], "severity": SEV_WARNING})
	if not item_errors.is_empty():
		rejected.append({"category": category, "id": rid, "file": file_path, "errors": item_errors})


func _validate_ballistic_segment(seg: Dictionary, out: Array) -> void:
	_err(out, &"ballistic", seg.is_empty(), "form=BALLISTIC 必填 ballistic 段")
	if seg.is_empty():
		return
	_err(out, &"ballistic.proj_speed", float(seg.get("proj_speed", 0.0)) <= 0.0, "proj_speed > 0")
	_err(out, &"ballistic.range", float(seg.get("range", 0.0)) <= 0.0, "range > 0")
	_err(out, &"ballistic.pierce", int(seg.get("pierce", 0)) < 0, "pierce ≥ 0")
	var pellets := int(seg.get("pellets", 0))
	_err(out, &"ballistic.pellets", pellets < 1 or pellets > 16, "pellets ∈ [1, 16]")


func _validate_laser_segment(seg: Dictionary, out: Array) -> void:
	_err(out, &"laser", seg.is_empty(), "form=LASER 必填 laser 段")
	if seg.is_empty():
		return
	var tick := float(seg.get("tick_rate", 0.0))
	_err(out, &"laser.tick_rate", tick <= 0.0 or tick > 30.0, "tick_rate ∈ (0, 30]")
	var layers := int(seg.get("scorch_max_layers", 0))
	_err(out, &"laser.scorch_max_layers", layers < 1 or layers > 8, "scorch_max_layers ∈ [1, 8]")
	_err(out, &"laser.refract_depth", int(seg.get("refract_depth", 0)) > 2, "refract_depth ≤ 2（B_spec 上限，超限剔除）")


func _validate_homing_segment(seg: Dictionary, out: Array) -> void:
	_err(out, &"homing", seg.is_empty(), "form=HOMING 必填 homing 段")
	if seg.is_empty():
		return
	_err(out, &"homing.proj_speed_max", float(seg.get("proj_speed_max", 0.0)) < float(seg.get("proj_speed_init", 0.0)), "speed_max ≥ speed_init")
	_err(out, &"homing.turn_rate", float(seg.get("turn_rate", 0.0)) <= 0.0, "turn_rate > 0")
	var blast := float(seg.get("blast_r", 0.0))
	_err(out, &"homing.blast_r", blast <= 0.0 or blast > 128.0, "blast_r ∈ (0, 128]")
	var sub := int(seg.get("sub_count", 0))
	_err(out, &"homing.sub_count", sub < 0 or sub > 8, "sub_count ∈ [0, 8]")


func _validate_melee_segment(seg: Dictionary, out: Array) -> void:
	_err(out, &"melee", seg.is_empty(), "form=MELEE 必填 melee 段")
	if seg.is_empty():
		return
	var arc := float(seg.get("arc_deg", 0.0))
	_err(out, &"melee.arc_deg", arc <= 0.0 or arc > 360.0, "arc_deg ∈ (0, 360]")
	var orbs := int(seg.get("orbs", 0))
	_err(out, &"melee.orbs", orbs < 1 or orbs > 8, "orbs ∈ [1, 8]")
	_err(out, &"melee.hit_cd", float(seg.get("hit_cd", 0.0)) <= 0.0, "hit_cd > 0")


func _err(out: Array, field: StringName, bad: bool, message: String) -> void:
	if bad:
		out.append({"field": field, "message": message, "severity": SEV_ERROR})


func _warn(out: Array, field: StringName, bad: bool, message: String) -> void:
	if bad:
		out.append({"field": field, "message": message, "severity": SEV_WARNING})


func _nf(out: Array, field: String, bad: bool, message: String) -> void:
	# 非致命（balance 专用）：字段级回退默认值 + 告警
	if bad:
		out.append({"field": field, "fatal": false, "message": message})
