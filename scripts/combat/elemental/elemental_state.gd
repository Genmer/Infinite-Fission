# scripts/combat/elemental/elemental_state.gd
# M-11 ElementalState（架构 §2.10）：单敌状态容器（A2 §4.1 附着—衰减—触发—消耗）。
# · gauges：附着计量 G（5 槽，下标 = GameConst.Element 枚举值直索引：KIN=0 槽恒 0 弃用，
#   FIR/ICE/LTG/WAT = 1/2/3/4；容量 100，满槽触发状态并清空该槽，F19/F20 稳态免疫线；
#   v1.2.0 4 槽 → 5 槽，A11 §2）。
# · 状态运行时：点燃 DOT（15%ATK/0.5s×3s，层 ≤5——第 6 次附着拒绝）；寒滞（−40% 移速）
#   + 易伤（×1.25 独立乘区，vuln 池注入）；二次满槽 → 完全冻结 1.2s（定身，受 immune_mask）；
#   感电连锁参数（3 目标/160px/35%每跳/深度 2 衰减 60%——执行在 ElementalSystem）。
# · λ 比例衰减：G *= (1 − λ_ele×dt)（F-22；λ 数组真源 BalanceTables.element_decay_lambda）。
class_name ElementalState
extends RefCounted

const GAUGE_MAX: float = 100.0
# 满槽触发码（apply 返回值；0 = 无状态触发）
const TRIGGER_NONE: int = 0
const TRIGGER_BURN: int = 1
const TRIGGER_CHILL: int = 2
const TRIGGER_FREEZE: int = 3
const TRIGGER_SHOCK: int = 4

var gauges: Array[float] = [0.0, 0.0, 0.0, 0.0, 0.0]  # 元素枚举直索引（KIN 槽恒 0 弃用）：FIR/ICE/LTG/WAT = 1/2/3/4（v1.2.0 5 槽，A11 §2）
var immune_mask: int = 0                       # 宿主 Enemy 注入（F-17 免疫矩阵）
# 状态运行时
var burn_layers: int = 0                       # ≤5（第 6 次附着拒绝）
var burn_timer: float = 0.0
var dot_tick_left: float = 0.5                 # 每 0.5s 一跳
var burn_tick: float = 0.5                     # 跳伤间隔快照（触发期写入）
var burn_dot_ratio: float = 0.15               # DOT 比例（ELE_IGNITE 层 2 → 0.22 覆写）
var burn_snapshot_atk: float = 0.0             # 攻击者面板快照 S（15%ATK 基数）
var chill_timer: float = 0.0                   # 寒滞（移速 −40%）
var chill_slow: float = 0.4
var freeze_timer: float = 0.0                  # 完全冻结（定身，受 immune_mask）
var vuln_timer: float = 0.0                    # 易伤 ×1.25（目标侧独立乘区）
var vuln_mult: float = 1.25
var shock_chain_cd: float = 0.0
var shock_chain_targets: int = 3               # ELE_SHOCK 层 2 → 4 覆写
var reaction_cd: Dictionary = {}               # rxn -> 剩余（v1.1.0 按 rule.cd 分立，缺省回退 cd_rxn）
var superconduct_left: float = 0.0             # 超导削抗剩余（−30% 全抗，6s）
var superconduct_active: bool = false
var last_attach_snapshot: float = 0.0          # 最近一次附着的攻击者面板快照（过载 120%ATK 基数）
var _chill_from_full: bool = false             # 寒滞已由满槽触发（二次满槽 → 冻结判定位）
# v1.2.0 冻结破碎（A11 §3：RXN_WAT_ICE；冻结期内 3 次 NORMAL/CRIT 直击 → 解冻 + 帧末结算）
var freeze_hits: int = 0                       # 冻结期内直击计数（满 3 触发破碎）
var freeze_shatter_pending: bool = false       # 破碎待结算（帧末 ElementalSystem.tick 消费）
var freeze_shatter_snapshot: float = 0.0       # 破碎结算快照（第 3 击 panel_snapshot）


func apply(p_element: int, p_value: float, p_snapshot: float = 0.0,
		p_overrides: Dictionary = {}) -> int:
	# 附着：计量累计 → 满槽触发状态并清空该槽（返回触发码；快照为攻击者面板 S）
	if p_element < GameConst.Element.FIR or p_element > GameConst.Element.WAT:
		return TRIGGER_NONE
	if p_snapshot > 0.0:
		last_attach_snapshot = p_snapshot
	gauges[p_element] = minf(gauges[p_element] + maxf(p_value, 0.0), GAUGE_MAX * 2.0)
	if gauges[p_element] < GAUGE_MAX:
		return TRIGGER_NONE
	gauges[p_element] = 0.0
	return _trigger(p_element, p_overrides)


func tick(p_game_delta: float, p_decay_lambdas: Array[float]) -> void:
	# λ 比例衰减（F-22）+ 全部状态计时
	# 槽 0（KIN）弃用跳过；λ 数组真源 BalanceTables.element_decay_lambda 为 [FIR, ICE, LTG]
	# 无 KIN 位——槽 i≥1 取 p_decay_lambdas[i − 1]。
	for i in range(1, gauges.size()):
		var lambda := 0.35
		if i - 1 < p_decay_lambdas.size():
			lambda = p_decay_lambdas[i - 1]
		gauges[i] *= maxf(1.0 - lambda * p_game_delta, 0.0)
	if burn_timer > 0.0:
		burn_timer = maxf(burn_timer - p_game_delta, 0.0)
		dot_tick_left -= p_game_delta
		if burn_timer <= 0.0:
			burn_layers = 0               # 燃尽：层清零（重复附着重新累计）
	if chill_timer > 0.0:
		chill_timer = maxf(chill_timer - p_game_delta, 0.0)
		if chill_timer <= 0.0:
			_chill_from_full = false
	freeze_timer = maxf(freeze_timer - p_game_delta, 0.0)
	if freeze_timer <= 0.0:
		freeze_hits = 0                           # 冻结到期未满 3 击 → 计数清零（A11 §3；二次冻结重计）
	vuln_timer = maxf(vuln_timer - p_game_delta, 0.0)
	shock_chain_cd = maxf(shock_chain_cd - p_game_delta, 0.0)
	for rxn in reaction_cd:
		reaction_cd[rxn] = maxf(float(reaction_cd[rxn]) - p_game_delta, 0.0)
	if superconduct_active:
		superconduct_left = maxf(superconduct_left - p_game_delta, 0.0)


func get_speed_factor() -> float:
	# 寒滞/冻结 → 0.6 / 0.0（行为修正；Boss 免疫定身但保留减速，F-17）
	if freeze_timer > 0.0:
		return 0.0
	if chill_timer > 0.0:
		return 1.0 - chill_slow
	return 1.0


func get_vuln_factor() -> float:
	# 易伤激活 → ×1.25（注入 vuln 乘区，A2 §1.8）
	return vuln_mult if vuln_timer > 0.0 else 1.0


func is_state_active(p_element: int) -> bool:
	# 条件乘区词条自评（SYN_FROST_EXEC 对寒滞/冻结、SYN_BURN_DEVOUR 对点燃等）
	match p_element:
		GameConst.Element.FIR:
			return burn_timer > 0.0
		GameConst.Element.ICE:
			return chill_timer > 0.0 or freeze_timer > 0.0 or vuln_timer > 0.0
		GameConst.Element.LTG:
			return gauges[GameConst.Element.LTG] > 0.0
		GameConst.Element.WAT:
			return gauges[GameConst.Element.WAT] > 0.0   # v1.2.0：水附着态（A11 §2）
	return false


func has_both(p_a: int, p_b: int) -> bool:
	# 反应条件（帧末检测）：双槽附着量均非零
	return gauges[p_a] > 0.0 and gauges[p_b] > 0.0


func clear_element(p_element: int) -> void:
	# 反应消耗/死亡清理
	if p_element >= 0 and p_element < gauges.size():
		gauges[p_element] = 0.0


func remaining_dot_total() -> float:
	# 碎裂结算基数：点燃剩余 DOT 总额（剩余跳数 × 每跳伤害）
	if burn_timer <= 0.0 or burn_layers <= 0:
		return 0.0
	var ticks_left := ceili(burn_timer / maxf(burn_tick, 0.01))
	return burn_dot_ratio * burn_snapshot_atk * float(burn_layers) * float(ticks_left)


func consume_dot_due() -> bool:
	# DOT 跳伤到期消费（ElementalSystem.tick 轮询：到期 → 结算一跳 → 复位间隔）
	if burn_timer > 0.0 and dot_tick_left <= 0.0:
		dot_tick_left += burn_tick
		return true
	return false


func consume_superconduct_expired() -> bool:
	# 超导到期消费（ElementalSystem 恢复抗性 +0.3）
	if superconduct_active and superconduct_left <= 0.0:
		superconduct_active = false
		return true
	return false


func apply_superconduct(p_delta: float, p_duration: float) -> void:
	# 超导：全抗 −|p_delta|，持续 p_duration（抗性改写在宿主 Enemy.resist，系统侧执行）
	superconduct_active = true
	superconduct_left = p_duration


# ── v1.2.0 冻结破碎（A11 §3：RXN_WAT_ICE 通道） ───────────────────
func apply_freeze_reaction(p_duration: float) -> void:
	# 水冰冻结（定身全停 2.5s）：计时置时长 + 直击计数清零（重复触发重新计数）
	freeze_timer = p_duration
	freeze_hits = 0


func register_freeze_hit(p_snapshot: float) -> void:
	# 冻结期直击入账（仅 NORMAL/CRIT 直击，宿主 take_result 判定后调用）；
	# 满 3 → 立即解冻 + 置破碎待发 + 快照落字段（帧末 ElementalSystem.tick 结算）
	freeze_hits += 1
	if freeze_hits >= 3:
		freeze_hits = 0
		freeze_timer = 0.0
		freeze_shatter_pending = true
		freeze_shatter_snapshot = p_snapshot


func consume_freeze_shatter() -> bool:
	# 破碎到期消费（ElementalSystem.tick 宿主循环：pending → true 一次性，结算后快照由系统清零）
	if freeze_shatter_pending:
		freeze_shatter_pending = false
		return true
	return false


func reset() -> void:
	# 归还清零（AC-11.1：死亡/回收清 DOT）
	gauges = [0.0, 0.0, 0.0, 0.0, 0.0]
	burn_layers = 0
	burn_timer = 0.0
	dot_tick_left = 0.5
	burn_tick = 0.5
	burn_dot_ratio = 0.15
	burn_snapshot_atk = 0.0
	chill_timer = 0.0
	chill_slow = 0.4
	freeze_timer = 0.0
	vuln_timer = 0.0
	vuln_mult = 1.25
	shock_chain_cd = 0.0
	shock_chain_targets = 3
	reaction_cd.clear()
	superconduct_left = 0.0
	superconduct_active = false
	last_attach_snapshot = 0.0
	_chill_from_full = false
	freeze_hits = 0
	freeze_shatter_pending = false
	freeze_shatter_snapshot = 0.0


# ── 内部 ──────────────────────────────────────────────────────────
func _trigger(p_element: int, p_overrides: Dictionary) -> int:
	# 满槽状态触发（快照/覆写按 ELE 词条层 2 递进写入；免疫位检查 F-17）
	match p_element:
		GameConst.Element.FIR:
			if (immune_mask & GameConst.IMMUNE_BURN) != 0:
				return TRIGGER_NONE
			var max_layers := 5
			if p_overrides.has("max_layers"):
				max_layers = int(p_overrides["max_layers"])
			if burn_layers >= max_layers:
				return TRIGGER_NONE       # 第 6 次附着拒绝
			burn_layers += 1
			burn_dot_ratio = float(p_overrides.get("dot_ratio", 0.15))
			burn_snapshot_atk = last_attach_snapshot
			burn_tick = 0.5
			burn_timer = 3.0              # 3s（重复命中刷新时长）
			dot_tick_left = burn_tick
			return TRIGGER_BURN
		GameConst.Element.ICE:
			if chill_timer > 0.0 or _chill_from_full:
				# 二次满槽 → 完全冻结（定身；Boss 免疫定身仅保留寒滞/易伤，F-17）
				if (immune_mask & GameConst.IMMUNE_FREEZE) == 0:
					freeze_timer = 1.2
					chill_timer = 2.5
					vuln_timer = 3.0
					_chill_from_full = true
					return TRIGGER_FREEZE
			chill_timer = 2.5             # 寒滞（移速 −40%）
			vuln_timer = 3.0              # 易伤 ×1.25 3s（目标侧独立乘区）
			_chill_from_full = true
			return TRIGGER_CHILL
		GameConst.Element.LTG:
			if (immune_mask & GameConst.IMMUNE_SHOCK) != 0:
				return TRIGGER_NONE
			shock_chain_targets = int(p_overrides.get("chain_targets", 3))
			return TRIGGER_SHOCK
	return TRIGGER_NONE
