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

# ── R232 T1b：结算段诊断计时（vc37 真机判读——刀3 标定输入） ──────────
# 口径=结算轴（resolve 全分支含顺延占位/-4 弃档 + 冲刷 _flush_entry 内 _resolve_core）；
# 反应通道 resolve_reaction 与弹侧 ctx 构建/词条预聚合（①②段）不在窗内——全链口径见
# probe_r232_knife FULL 臂。累计值经 settle_us_total() 出口，GameLoop.diag_counts 秒差分
# ÷ 结N 秒差分 → DebugStats 1Hz 行「结µs」（R231 快N 同款行尾直读键）。
const SETTLE_PROBE := true                    # 诊断计时闸（false=零打点原路径）
var _settle_us_total: int = 0                 # 结算轴累计 µs（局内累计，单调增）


func settle_us_total() -> int:
	# R232 T1b：结算轴累计 µs 读数（GameLoop 秒差分源；不入 _stats——避免 end_frame
	# 增量落账通道每帧多发一条 DebugStats 计数）
	return _settle_us_total


func reset_run_alarms() -> void:
	# R198（R192-low4）：告警双闸每局复位。pipeline 为进程级单实例（GameLoop.
	# _boot_build_actors 建立后跨局复用），原「一局一次」注释实为「进程一次」——闸置位后
	# 次局同条件超告警线不再广播（诊断可见性静默丢失）。R_alarm/R_rxn 双闸一并复位，
	# 语义更正为以局为界：start_run/continue_run 两条进局路径调用（restart_run 经
	# start_run 天然覆盖）。
	_alarm_emitted = false
	_rxn_alarm_emitted = false


func _init() -> void:
	_stats = {
		"settles": 0, "reaction_settles": 0, "dropped_dupe": 0,
		"dropped_dead": 0, "dropped_invalid": 0, "sanitized_negative": 0, "alarms": 0,
		"rxn_alarms": 0,
		"settle_deferred": 0, "settle_flush": 0, "settle_stale_flush": 0,
		"settle_flush_dead": 0, "settle_flush_reuse": 0, "settle_overload_drop": 0,
		"separate_drop": 0,   # R225 全弃档计数（-4 哨兵专用——仅供分离测量，玩法恒 0）
		"agg_merged": 0, "agg_flush": 0, "agg_overflow_defer": 0,
		# ↑ R236 A 案计数（OVERKILL_AGGREGATE 关=恒 0）：agg_merged=组内后续命中并入数、
		# agg_flush=组真结算数（结N 语义切换：聚合开=组数口径）、agg_overflow_defer=组数
		# 超帽并入 R223 顺延的组数（极端构筑回潮闸，深载结构性≈0）。
	}


# ── 公共入口（§2.5 冻结签名） ────────────────────────────────────

# R236 A 案：同帧同目标提交前聚合（回退开关——false=零扰动原路径，vc40 随包关态）。
# 依据：probe_r234_overkill_baseline.json S0——同帧同目标组 34804（39.1% 命中、组均
# 2.46 发、max 51），提交前聚合实测砍需求 −59.4%（47.5→19.3 提交/步 < 60Hz tier1 帽
# 48 → 顺N/弃N 结构性归零）。组键=纯 target_uid（跨源合并是收益主体——source_uid 为
# 弹级唯一（projectile_base.gd:858），对键 (source,target) 近零收益）。合并语义=R223
# 顺延合并同构：后续命中 base/flat 累积进首发袋，crit/乘区/元素参数不合并（首发参数
# 代表组——同构筑同参域实测零暴露；跨武器异参域=披露项，DPS 期望守恒 E[(Σd)×C]=
# Σd×E[C] 在同均值 C 域成立）。冲刷时点=dispatch_resolved_frame 头（⑧ 段——跳字当帧
# 起跳保真）；死亡短路在冲刷时点经 _flush_entry 复检（uid 复验同款）。依赖 CTX_REUSE
# （false 回退态聚合不启用——双回退开关叠加无意义）。默认恒 false：vc41 翻开试验被
# 开态电池 28 红否决（2026-10-06 证据 docs/qa/2026-10-06-R236-翻开态电池28红-证据.txt——
# 必暴/乘区链/元素反应等逐命中语义被首发代表破坏，DPS 期望守恒≠玩法语义守恒）。
# 后续=R236b 精化：合并域收窄到死目标 overkill（活目标逐命中不合并），收益重测后再议翻开。
static var OVERKILL_AGGREGATE: bool = false
var _frame_agg: Dictionary = {}               # target_uid → {"bag":…, "frame":…}（袋 shape
                                              # 与 R223 顺延项同构——超帽并 FIFO 零转换）
var _frame_agg_fifo: Array[int] = []          # 组创建序（冲刷保序=首发时序）

func resolve(p_ctx: DamageContext) -> DamageResult:
	# ★ 唯一公共结算入口（§4.2 九步序列，顺序禁止重排）。
	# R232 T1b：结算段诊断计时包口（诊断 only 零行为改动——原主体整体移 _resolve_body，
	# 签名/语义逐位；两次 usec 读/命中 <0.1µs，桌面零扰动门 <0.1ms/帧不可达）。
	if SETTLE_PROBE:
		var t0 := Time.get_ticks_usec()
		var r := _resolve_body(p_ctx)
		_settle_us_total += Time.get_ticks_usec() - t0
		return r
	return _resolve_body(p_ctx)


func _resolve_body(p_ctx: DamageContext) -> DamageResult:
	# 0. 入口防御（§六.4，先于九步，不改语义）：NaN/Inf → 丢弃；负 base_atk → 0 + 计数
	# R232 刀1d-①：_idem_key 一算多用（R220 刀8② 先例延伸）——原每结 2 次
	# （_check_idempotent + _cache_result）+ 每顺延再 1 次（_defer_settle）位拼接；
	# 现入口算一次向下传递（可选参缺省 -1=自算，直调调用方/回退零改动）。
	var key := _idem_key(p_ctx)
	if not _sanitize(p_ctx):
		_stats["dropped_invalid"] += 1
		return null
	# ① 幂等检查：(source_uid, target_uid, frame_stamp) 已结算 → 短路返回缓存结果
	# （预算闸之后：同帧重复命中先折返回真结果，不占预算不顺延——dupe 语义不动）
	var cached: DamageResult = _check_idempotent(p_ctx, key)
	if cached != null:
		_stats["dropped_dupe"] += 1
		return cached
	# ② 目标存活检查：dead/null → 丢弃 + 计数（E-06 死亡短路）
	if not _target_alive(p_ctx):
		_stats["dropped_dead"] += 1
		return null
	# R225 分离测量档（仅供测量，非玩法刀）：-4 全弃哨兵——把通过入口防御/幂等/存活
	# 三闸的全部待结算提交直接丢弃并计数 separate_drop，返回零值占位（与 -3 顺延占位
	# 同构：不落血/不入派发队/穿透与节拍照常消费——弹 tick 侧行为与结算臂逐位同构，
	# 两臂弹段差集≈纯结算成本）。理由：R224 §四读数二——~300-500µs/结算=弹段÷结算数
	# 的混组成上界（对刀不敏感即证），「帽内结算占弹段大头」需 tick-only 空载对照分离
	# 实测后再立验收门。语义边界：①占位同步写幂等缓存（R223 QA-2 先例——同帧同键
	# 重复命中折返 dropped_dupe，不入 separate_drop，计数口径=去重后的独立提交）；
	# ②跨帧无积压合并（全弃档无 FIFO，每条提交各自弃各计）；③反应通道 resolve_reaction
	# 不受影响（分离对象=弹段主结算链）；④-1/-2/-3/≥0 既有语义零改动。
	if settle_budget_override == -4:
		var ph_drop := _synthetic_deferred(p_ctx)
		_idempotent_cache[key] = ph_drop
		_stats["separate_drop"] += 1
		return ph_drop
	# R236 A 案：同帧同目标提交前聚合（OVERKILL_AGGREGATE 开 ∧ 战斗态 ∧ CTX_REUSE）。
	# 已有组 → base/flat 并入首发袋（R223 _defer_settle 累积分支同款语义）+ agg_merged
	# 计数，折返该组占位（不入队不双计——首发占位已入幂等缓存）；新目标 → 建组袋入
	# FIFO，返回合成占位（弹侧 _on_settled 对 deferred_merge 结果的容忍=R223 超帽先例
	# ——深载顺延态本就常态返回占位）。真结算推迟到 dispatch 头冲刷（_flush_frame_agg
	# ——⑧ 段时点，跳字当帧起跳）；组数超帽的余组并入 R223 顺延 FIFO（回潮闸）。
	# 注：同 (source,target,frame) 重复提交在 ① 幂等闸已折返（本块只见跨源组员）。
	if OVERKILL_AGGREGATE and _combat_armed and CTX_REUSE:
		var tkey := p_ctx.target_uid & GameConst.UID_MAX
		var agg: Dictionary = _frame_agg.get(tkey, {})
		if not agg.is_empty():
			var bag: Dictionary = agg["bag"]
			bag["base_atk"] = float(bag["base_atk"]) + p_ctx.base_atk
			bag["flat_bonus"] = float(bag["flat_bonus"]) + p_ctx.flat_bonus
			bag["last_frame"] = p_ctx.frame_stamp
			_stats["agg_merged"] += 1
			return agg["placeholder"]
		var ph_agg := _synthetic_deferred(p_ctx)
		_frame_agg[tkey] = {"bag": _bag_acquire(p_ctx), "frame": p_ctx.frame_stamp,
			"placeholder": ph_agg}
		_frame_agg_fifo.append(tkey)
		_idempotent_cache[key] = ph_agg
		return ph_agg
	# R223 刀R：全局每帧结算预算（真机深载门——详见 _settle_cap_now 头注）。超帽命中
	# FIFO 顺延（同对 base 累积，期望 DPS 守恒），调用方收零值占位结果（穿透/节拍照常
	# 消费、不落血不入派发队——「无管线防御」零值先例）；积压帧头按预算冲刷、过期强冲。
	var cap := _settle_cap_now()
	if cap > 0:
		if _settle_left <= 0:
			var ph := _synthetic_deferred(p_ctx)
			_defer_settle(p_ctx, ph, key)
			return ph
		_settle_left -= 1
	return _resolve_core(p_ctx, key)


func _resolve_core(p_ctx: DamageContext, p_key: int = -1) -> DamageResult:
	# ③~⑨ 九步主体（resolve 前置闸通过后的真结算；R223 刀R 冲刷路径共用）。
	# R220 刀8③：ModifierStack 复用（借出即全字段重置——重置清单见 _acquire_stack）；
	# DamageAudit 仍每命中 new（p_result.audit = p_stack.audit 使 audit 随 DamageResult
	# 逃逸到五订阅者/测试断言——复用=跨命中污染，方案书刀8-③ 评审修正）；
	# DamageResult 每命中 new 不动。
	# R232 刀1d-②：_balance() 入口取一次向下传递（原 ③④⑤⑨a 四次 autoload 链读）；
	# 可选参缺省 null=各步自算（直调调用方/回退零改动）。
	var bal := _balance()
	var stack := _acquire_stack()
	stack.audit = DamageAudit.new()
	_resolve_depth += 1
	# ③ Add 池聚合（同 ID 叠层 F3 衰减 + 跨 ID 线性 + 负贡献全额 + F4 池钳）
	_aggregate_add(p_ctx, stack, bal)
	# ④ Flat 加入（Σ_flat ≤ f_flat × base_atk 比例钳制）
	_apply_flat(p_ctx, stack, bal)
	# ⑤ 乘区聚合（聚合层合并 → 防御层去重 → 单区 cap → 名额 top-8 → 整体钳 8.0）
	_aggregate_mults(p_ctx, stack, bal)
	# ⑥ Local 池独立聚合（不入名额、不受 cap_prod，自有 cap_local，F-15）
	_aggregate_local(p_ctx, stack)
	# ⑦ 暴击掷骰（独立 RNG 流；HIT_NO_CRIT → C=1，不掷骰不消耗序列）
	var crit := _roll_crit(p_ctx)
	var result := DamageResult.new()
	_populate_result(p_ctx, stack, crit, result)   # ⑦b 四段中间量落字段（S/M/L/C + 表现级派生）
	# ⑧ 目标侧修正：V = (1 − resist[element]) × (1 + 状态易伤)
	_apply_target_side(p_ctx, stack, result)
	# ⑨ 终值钳制 + R_alarm 双闸 + killed 判定 → 广播 → 幂等缓存写入
	_finalize(p_ctx, stack, result, bal)
	_broadcast(result)
	_cache_result(p_ctx, result, p_key)
	_resolve_depth -= 1                        # R220 刀8③：复用栈深度哨兵（见 _acquire_stack）
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
	# R220 刀8③：反应通道同构复用（ModifierStack 借出重置；DamageAudit 每命中 new）
	var stack := _acquire_stack()
	stack.audit = DamageAudit.new()
	_resolve_depth += 1
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
	_resolve_depth -= 1                        # R220 刀8③：复用栈深度哨兵
	_stats["reaction_settles"] += 1
	return result


@warning_ignore("unused_parameter")
func begin_frame(frame: int = -1, p_combat: bool = true) -> void:
	# GameLoop 投射物阶段前挂接：清幂等缓存（§4.1 缓存每帧清空）。
	# frame 为调用方帧号对账参数（幂等键第三元取 ctx.frame_stamp；默认参数兼容架构
	# §2.5 无参签名 begin_frame()，两种调用形态等价）。
	# R221 修轮 D1：带参调用同步 _cur_frame_stamp（dispatch 过期守卫的帧基准——
	# GameLoop 传 frame_stamp，无参调用/测试直构保持 -1 守卫关闭）。
	# R223 修轮（评审下次项升级）：p_combat=本帧战斗态（GameLoop state==PLAYING）——
	# 暂停/选卡窗（AC-16.2 战斗完全冻结契约）内积压不冲刷不强冲（冻结世界零落账），
	# 恢复战斗首帧统一冲刷（过期窗按游戏帧计——含暂停期推进，超窗项恢复即强冲落账）。
	if frame >= 0:
		_cur_frame_stamp = frame
	_combat_armed = p_combat
	_idempotent_cache.clear()
	_agg_residual_to_pending()                 # R236：残留组并入顺延（⑧ 冲刷后的 FIFO 应空——防御口）
	if p_combat:
		_drain_pending_budget()
	else:
		_settle_left = 0                # 暂停期预算不武装——偶发泄漏 resolve 走顺延，恢复后冲刷


func end_frame() -> void:
	# GameLoop 帧末挂接：遥测计数增量落 DebugStats（累计值 → 本帧增量）
	# R220 刀11：damage_resolved 帧队列在此只清空不派发（兜底——正常派发时点=⑧ UI 段
	# 前 game_loop dispatch_resolved_frame；帧序最末清队防异常帧残留跨帧派发）
	# R221 修轮 D1：批化态下本清队击穿 Fix C 顺延语义（dispatch 留队余量同帧被清，
	# 深载超帽事件静默丢失——QA P3/评审 blocker 同锤）——批化态队列归 dispatch 自管：
	# 正常余量保序跨帧续派，跨局/超载残留由 dispatch 过期守卫（STALE_FRAME_WINDOW）
	# 前缀丢弃，本口不再清队；回滚开关 false 时队列本就不入（即时派发），清空为无操
	# 作保留。
	if not DAMAGE_RESOLVED_BATCHED:
		_resolved_queue.clear()
	if _combat_armed:
		_agg_residual_to_pending()             # R236：⑧ 冲刷后残留并入顺延（异常帧防御）
		_end_frame_pending_maintenance()
	for key in _stats:
		var cur := int(_stats[key])
		var prev := int(_last_flush.get(key, 0))
		if cur != prev:
			DebugStats.count(StringName("damage." + String(key)), cur - prev)
		_last_flush[key] = cur


# ── R220 刀8③：ModifierStack per-frame 复用件（回滚开关） ────────────
const REUSE_MODIFIER_STACK := true           # false=每次 new 原路径（一键回退）
var _reused_stack: ModifierStack = null      # 顺序复用栈（resolve 无同步重入——借出即重置）
var _resolve_depth: int = 0                  # 深度哨兵：嵌套 resolve（如 bank-shot 弹片在
                                             # inject 期先行 resolve）各取新件防跨层改写


func _acquire_stack() -> ModifierStack:
	# R220 刀8③：ModifierStack 复用借出——每命中省 1 次 RefCounted 分配（原 :63-64/:107-108
	# 两分配点）。per-use 全字段重置清单（ModifierStack 全部 7 字段，借出即清）：
	#   add_pool_sum.clear() / flat_clamped=0.0 / mult_pools.clear() /
	#   resolved_mults.clear() / product_clamped=1.0 / local_product=1.0 /
	#   audit=由调用方紧跟赋新 DamageAudit（不复用——audit 随 DamageResult 逃逸）。
	# DamageAudit / DamageResult 不复用（评审修正：audit 复用=先前 result 的审计被后续
	# 命中改写的跨命中污染，比漏清更隐蔽）。深度哨兵>0（嵌套 resolve）时各取新件。
	if REUSE_MODIFIER_STACK and _resolve_depth <= 0:
		if _reused_stack == null:
			_reused_stack = ModifierStack.new()
		var s := _reused_stack
		s.add_pool_sum.clear()
		s.flat_clamped = 0.0
		s.mult_pools.clear()
		s.resolved_mults.clear()
		s.product_clamped = 1.0
		s.local_product = 1.0
		return s
	return ModifierStack.new()


# ── R220 刀11：damage_resolved 帧队列（回滚开关） ───────────────────
const DAMAGE_RESOLVED_BATCHED := true        # false=即时同步派发 EventBus 原路径（一键回退）
const DISPATCH_FRAME_CAP := 48               # R221 Fix C：每帧派发帽（条）——cap1 低帧率下单步
                                              # ~90 条结算全量突发派发 5 订阅者（popup 合并桶/
                                              # HUD 批存/relic/gamefeel/sfx）是「他/跳」尖峰主源；
                                              # 48 ≥ 轻载结N/步均值的 2 倍余量（结N≤2100/s ÷
                                              # 60fps ≈ 35/步），深载余量保序顺延下帧消化
const STALE_FRAME_WINDOW := 30               # R221 修轮 D1：顺延项过期窗（游戏帧 ≈0.5s@60Hz，
                                             # 双向距离判——GameConfig 2^24 回绕安全）
# R233 T3 决策6-R2：30Hz 档（与帽同谓词联动，见 SETTLE_BUDGET_T1_30HZ 注块）——
# 96 条/步=比例平价（≈2880/s=60Hz 原口径，反馈不比现状更糟）；15 帧=0.5s 时间语义
# 守恒（顺延亏空有界卸载兜底窗，不无界增长）。原 const 值不动（r221 套件直断言 48/30）。
const DISPATCH_FRAME_CAP_30HZ := 96          # 每步派发帽 30Hz 档（192 条/步=vc38 条件触发，
                                             # 与帽 240 同族——AC-V② 体感不足+stale_drop 超口径时触发）
const STALE_FRAME_WINDOW_30HZ := 15          # 派发顺延过期窗 30Hz 档
var _resolved_queue: Array[DamageResult] = []  # 帧内结算结果保序队列（⑧段前统一派发）
var _cur_frame_stamp: int = -1               # begin_frame 注入的当前游戏帧号（-1=未知 → 过期
                                              # 守卫关闭，兼容无参调用/测试直构管线）


func dispatch_resolved_frame() -> void:
	# R220 刀11 派发口（GameLoop PLAYING 分支 ⑧ UI 段前调用——最后一个结算产生段之后）：
	# 帧队列保序逐条经 EventBus.emit_damage_resolved 派发（popup merge/暴击升格逐条时序
	# 依赖保序；popup tick 在 _tick_ui 内 ⇒ 跳字当帧起跳）。队列空时零成本直返。
	# R221 Fix C：每帧至多 DISPATCH_FRAME_CAP 条，余量保序留在队头下帧续派（原地
	# 前移免分配）；顺延计数 dispatch_deferred 可观测（真机诊断「他」尖峰对照）。
	# R221 修轮 D1（QA/评审同锤 blocker）：顺延余量的存续由两处共同保证——
	# ① end_frame 批化态不再清队（下条注释）；② 本口前缀丢弃过期项（跨局残留/极端
	# 超载下的诚实卸载：过期窗外的顺延已无时序意义，静默丢弃计数 dispatch_stale_drop）。
	# R236 A 案：聚合冲刷挂本口最前（先于空队早退——聚合开时弹段零即时结算，队列为空
	# 是常态，冲刷产出的真结算结果恰在本口统一派发=跳字当帧起跳时点不变）。
	_flush_frame_agg()
	if _resolved_queue.is_empty():
		return
	if _cur_frame_stamp >= 0:
		var drop_from := 0
		while drop_from < _resolved_queue.size() \
				and absi(_resolved_queue[drop_from].frame_stamp - _cur_frame_stamp) > stale_frame_window_now():
			drop_from += 1
		if drop_from > 0:
			DebugStats.count(&"dispatch_stale_drop", drop_from)
			for i in range(drop_from, _resolved_queue.size()):
				_resolved_queue[i - drop_from] = _resolved_queue[i]
			_resolved_queue.resize(_resolved_queue.size() - drop_from)
			if _resolved_queue.is_empty():
				return
	var total := _resolved_queue.size()
	var n := mini(total, dispatch_frame_cap_now())
	for i in n:
		EventBus.emit_damage_resolved(_resolved_queue[i])
	if n < total:
		DebugStats.count(&"dispatch_deferred", total - n)
		for i in range(n, total):
			_resolved_queue[i - n] = _resolved_queue[i]
		_resolved_queue.resize(total - n)
	else:
		_resolved_queue.clear()


# ── R223 刀R：全局每帧结算预算（深载突发削峰） ──────────────────────
# vc29 实锤：敌120 无尽16 深载结N 1000-2600/s（均值 43/帧）叠加死亡新星级联的帧内
# 突发（尖峰他 33-126ms ≈ 单帧 200-400 结算——resolve 九步+每结算 DamageResult/
# DamageAudit/breakdown 字典分配，及其在次帧 begin_frame 幂等缓存清空时的成批析构
# 全落未归因段）。刀＝帧级预算帽：超帽命中 FIFO 顺延（同 (source,target) 对 base/
# flat 累积——一次掷骰 E[Σ]=Σ×E[单发]，期望 DPS 守恒），积压帧头按预算冲刷、
# 12 帧过期强冲（击杀时序后移 ≤0.2s 体感边界）、256 项硬帽诚实丢弃（持续超载保底）。
# 顺延返回零值占位 DamageResult（deferred_merge=true）：不落血/不入派发队/无跳字，
# 调用方穿透消耗/命中序数/节拍照常（weapon_base.settle_aoe / projectile_base.
# _on_settled / laser _settle_one_tick / orbit _charge_settle 四路尾段均已核实只在
# 桩管线才本侧落血——零值占位无双血）。
# 门控（_settle_cap_now）：mobile ∧ 帧率优先 ∧ tier1-3（tier1 帽 48 / tier2、tier3
# 帽 96——二cv#8 帧率：tier3 并档，vc48 全程调3 时削峰器曾恒缺席）——特效优先/
# 桌面/headless 恒 0=零扰动（r220_simchain 等 tier 注入+结算共存的既有套件不受自动门
# 影响；测试经 settle_budget_override 显式驱动）。
# R225：另设 -4 全弃档（**仅供分离测量**，非玩法刀）——resolve 层把全部待结算提交
# 直接丢弃并计数 separate_drop，语义与边界见 resolve 内 R225 注块。
const SETTLE_BUDGET_T1 := 48                   # tier1（低特效深谷）每帧真结算帽
const SETTLE_BUDGET_T2 := 96                   # tier2（中特效）每帧真结算帽
const SETTLE_STALE_FRAME := 12                 # 顺延过期窗（游戏帧 ≈0.2s@60Hz——强冲边界）
const SETTLE_PENDING_HARD_CAP := 256           # 积压硬帽（对数上限=武器×敌；超帽丢最老）
# ── R233 T3 决策6：30Hz 档位常量（const 断言保护策略——六个原 const 值一律不动：
#    SETTLE_BUDGET_T1/T2=48/96、SETTLE_STALE_FRAME=12（本块）+ DISPATCH_FRAME_CAP=48/
#    STALE_FRAME_WINDOW=30（上方 R220 刀11 块）+ MAGNET_ABSORB_PER_FRAME=24（game_loop），
#    r223/r221/r225 套件直断言；30Hz 档=新增 *_30HZ 常量+选择器按
#    GameLoop.sim30_effective() 单源谓词选表，禁任何一参与开关脱钩——防半回退态）。
#    供给算术：帽×步率——tier1 96×30=2880/s / tier2 192×30=5760/s（>典型需求 4500-5500/s）；
#    SETTLE_STALE 12→6 帧=0.2s 时间语义守恒（12 帧@30Hz=0.4s 会把击杀后移体感翻倍）；
#    DISPATCH 96/步=比例平价（≈2880/s=60Hz 原口径，反馈不比现状更糟）；
#    STALE_FRAME_WINDOW 15 帧=0.5s 时间语义守恒（派发亏空有界卸载兜底窗）。
const SETTLE_BUDGET_T1_30HZ := 96              # tier1 30Hz 档（vc38 真机标定项）
const SETTLE_BUDGET_T2_30HZ := 192             # tier2 30Hz 档——已定案 192（R4 T8 桌面步耗 FAIL
                                               # 记档、主控拍板进 T3，vc38 真机终审）
const SETTLE_STALE_FRAME_30HZ := 6             # 顺延过期窗 30Hz 档（≈0.2s 时间语义守恒）
static var settle_budget_override: int = -1    # -1=真机自动门 / -2=强制关 / -3=自动门
                                              # （模拟 mobile——tier 映射分支无头可测）/
                                              # ≥0=强制帽（测试）/ -4=全弃档（R225 分离
                                              # 测量专用——resolve 全部丢弃并计数
                                              # separate_drop，仅供探针勿在玩法路径置位）
var _settle_left: int = 0                      # 本帧剩余预算（begin_frame 重置=帽值-冲刷）
var _combat_armed: bool = true                 # R223 修轮：本帧战斗态（begin_frame 注入——
                                              # 暂停/选卡窗内冲刷与帧末维护挂起）
var _pending_pair: Dictionary = {}             # pair_key -> {"ctx": DamageContext, "frame": int}
                                              # （CTX_REUSE=false 原路径）/ {"bag": Dictionary,
                                              # "frame": int}（R232 刀1b 字段袋路径）
var _pending_fifo: Array[int] = []             # pair_key 先入先出（冲刷序；同对合并不重排）

# ── R232 刀1b：DamageContext 复用 + pending 字段袋（回滚开关） ─────────
# 弹侧 ctx 成员级复用（projectile_base._ctx_scratch，借出即全字段重置）解除「每命中 1 次
# RefCounted 分配+三池数组重建」；顺延积压从「持有 ctx 对象」改「纯值字段袋」（分析
# AC-3：全仓唯一跨帧持有者=_pending_pair，词条 handle 九族派发期内只读——完整档放行），
# 冲刷用 pipeline 侧复用 ctx 从袋重建再走 _resolve_core（重建值=顺延时快照，九步输入
# 与原 held-ctx 路径逐位相同）。false=两条路径双双回落原实现（一键回退，一键回退先例
# REUSE_MODIFIER_STACK/POOLING_ENABLED）。
static var CTX_REUSE: bool = true
var _flush_ctx: DamageContext = null           # 冲刷侧复用 ctx（袋→ctx 重建件；顺延路径
                                              # 专用——与弹侧 scratch 无交集，帧界使用）
var _bag_pool: Array[Dictionary] = []          # 袋对象池（冲刷/丢弃还池；容量=硬帽 256
                                              # 同量级封顶，防驻留膨胀）


static func _settle_cap_now() -> int:
	# 预算帽解析（每帧一次于 begin_frame；resolve 逐命中直读——门参数会话内短窗稳定，
	# 逐命中重读保证 tier 档变即时生效）。-3=无头测试的「模拟真机」哨兵：跳过
	# OS.has_feature("mobile") 检查直入 tier 映射（tier_override 注入即生效）——
	# 自动门真机语义与测试口径共用同一条映射分支。
	if settle_budget_override >= 0:
		return settle_budget_override
	if settle_budget_override == -2:
		return 0
	if settle_budget_override == -4:
		return 0                            # R225 全弃档：预算恒 0（resolve 层已拦截
		                                    # 全部提交，此处兜底——冲刷/帧末维护零扰动）
	if settle_budget_override != -3 and not OS.has_feature("mobile"):
		return 0
	if not PerfGovernor.frame_priority():
		return 0
	var t := PerfGovernor.effective_tier()
	if t <= 1:
		return SETTLE_BUDGET_T1_30HZ if GameLoop.sim30_effective() else SETTLE_BUDGET_T1
	# 二cv#8 帧率：tier3 并入 tier2 同帽——深载恰是削峰器最需要在场时（vc48 全程调3
	# 期间深载单帧 200-400 结算突发完全无帽）。帽表本身不动（const 断言锁 48/96 与
	# 30Hz 档 96/192），仅 tier3 不再落到恒 0 尾档；预算=DPS 守恒 FIFO 顺延（同对合并
	# 顺延），数值面零变化只挪时序，跳字/击杀时序后移 ≤0.2s 有 SETTLE_STALE 兜底。
	return SETTLE_BUDGET_T2_30HZ if GameLoop.sim30_effective() else SETTLE_BUDGET_T2


static func settle_stale_frame_now() -> int:
	# R233 T3 决策6：顺延过期强冲边界选表（settle_stale_flush 扫描消费）——
	# 谓词联动与帽表同源（sim30_effective 单源，禁脱钩防半回退态）。
	return SETTLE_STALE_FRAME_30HZ if GameLoop.sim30_effective() else SETTLE_STALE_FRAME


static func dispatch_frame_cap_now() -> int:
	# R233 T3 决策6-R2：每步派发帽选表（dispatch_resolved_frame 消费）——
	# 30Hz 档 96/步=比例平价；与结算帽同谓词（脱钩则反馈饿死，决策6 禁令）。
	return DISPATCH_FRAME_CAP_30HZ if GameLoop.sim30_effective() else DISPATCH_FRAME_CAP


static func stale_frame_window_now() -> int:
	# R233 T3 决策6-R2：派发顺延过期窗选表（dispatch_resolved_frame 前缀丢弃消费）——
	# 30Hz 档 15 帧=0.5s 时间语义守恒（亏空有界卸载兜底）。
	return STALE_FRAME_WINDOW_30HZ if GameLoop.sim30_effective() else STALE_FRAME_WINDOW


static func _pair_key(p_ctx: DamageContext) -> int:
	# 同对合并键（_idem_key 同风格位拼接，无帧元——跨帧顺延按对合并）
	return (p_ctx.source_uid & GameConst.UID_MAX) << 20 \
		| (p_ctx.target_uid & GameConst.UID_MAX)


func _defer_settle(p_ctx: DamageContext, p_placeholder: DamageResult, p_key: int = -1) -> void:
	# 超帽顺延：同对已有积压 → base/flat 累积进既有项（一次冲刷掷骰）；新对建项
	# 入 FIFO 尾。crit 参数/乘区不合并——同对同源（同武器），逐命中本就同参。
	# R223 修轮 QA-2：占位同步写入幂等缓存——同 (source,target,frame) 二次 resolve
	# 折返占位（dropped_dupe），不再并入 base（预算前幂等语义逐位保持——同键双发
	# = 同命中，不得双计）；缓存随 begin_frame 清空，跨帧同对自然走累积合并路径。
	# R232 刀1b：CTX_REUSE 时新对存「字段袋」（_bag_acquire——AC-6 完备清单+三池
	# dict 浅拷贝，解除对 ctx 对象的跨帧持有=弹侧 scratch 复用前提）；同对累积改对袋
	# 累加（语义等价：原实现对 held ctx 的 base_atk/flat_bonus +=）。false=存 ctx
	# 对象原路径（一键回退）。R232 刀1d-①：p_key 可选注入（-1=自算）。
	var key := _pair_key(p_ctx)
	var e: Dictionary = _pending_pair.get(key, {})
	if e.is_empty():
		if CTX_REUSE:
			_pending_pair[key] = {"bag": _bag_acquire(p_ctx), "frame": p_ctx.frame_stamp}
		else:
			_pending_pair[key] = {"ctx": p_ctx, "frame": p_ctx.frame_stamp}
		_pending_fifo.append(key)
	else:
		if CTX_REUSE:
			var bag: Dictionary = e["bag"]
			bag["base_atk"] = float(bag["base_atk"]) + p_ctx.base_atk
			bag["flat_bonus"] = float(bag["flat_bonus"]) + p_ctx.flat_bonus
			bag["last_frame"] = p_ctx.frame_stamp   # AC-6 簿记：最近合并帧随合并刷新
			                                          #（e["frame"] 同值——过期强冲判定源）
		else:
			var held: DamageContext = e["ctx"]
			held.base_atk += p_ctx.base_atk
			held.flat_bonus += p_ctx.flat_bonus
		e["frame"] = p_ctx.frame_stamp
	_idempotent_cache[p_key if p_key >= 0 else _idem_key(p_ctx)] = p_placeholder
	_stats["settle_deferred"] += 1


func _flush_frame_agg() -> void:
	# R236 A 案冲刷口（dispatch_resolved_frame 头主调；end_frame 兜底不直调本口——
	# 经 _agg_residual_to_pending 并入 R223 顺延，避免帧末绕过维护序）。逐组过
	# _flush_entry（uid 复验/死亡复检/真结算/击杀回填全复用 R223 统一冲刷口）；
	# 预算防护：_settle_left 耗尽后余组整袋并入 R223 顺延 FIFO（袋 shape 同构零转换
	# ——帧头 _drain_pending_budget 接管；聚合后组数 19.3/步 < 帽 48，此路径深载
	# 结构性≈0，仅极端构筑帧的结算风暴回潮闸）。清空即幂等（异常帧残留防御同满足）。
	while not _frame_agg_fifo.is_empty():
		var tkey: int = _frame_agg_fifo.pop_front()
		var e: Dictionary = _frame_agg.get(tkey, {})
		_frame_agg.erase(tkey)
		if e.is_empty():
			continue
		if _settle_left > 0:
			_settle_left -= 1
			var outcome := _flush_entry(e)
			if outcome == 0:
				_stats["agg_flush"] += 1
			elif outcome == 1:
				_stats["settle_flush_dead"] += 1
			else:
				_stats["settle_flush_reuse"] += 1
		else:
			_pending_pair[tkey] = e
			_pending_fifo.append(tkey)
			_stats["agg_overflow_defer"] += 1


func _agg_residual_to_pending() -> void:
	# R236 残留防御（begin_frame/end_frame 兜底）：正常序（⑧ 冲刷）后 FIFO 应空；
	# 异常路径（dispatch 未调/非战斗态泄漏提交）残留组整体并入 R223 顺延 FIFO——
	# 帧头预算冲刷接管，零丢失零双计（组袋已从 _frame_agg 摘除，幂等）。
	while not _frame_agg_fifo.is_empty():
		var rkey: int = _frame_agg_fifo.pop_front()
		var re: Dictionary = _frame_agg.get(rkey, {})
		_frame_agg.erase(rkey)
		if not re.is_empty():
			_pending_pair[rkey] = re
			_pending_fifo.append(rkey)


func _bag_acquire(p_ctx: DamageContext) -> Dictionary:
	# R232 刀1b：pending 字段袋获取（池优先借出，空袋全键覆写）。字段完备清单=分析
	# AC-6（17 值字段+簿记 last_frame+可裁 5 字段同构入袋——袋与 DamageContext 同构
	# 便于逐字段对拍）。两个帧字段语义独立：frame_stamp=首顺延帧（幂等键/冲刷结果
	# 键位，bit 级保真）/ last_frame=最近合并帧（过期强冲判定，合并时刷新）。
	# 三池 Array[Dictionary] 逐 dict 浅拷贝（R1 裁定：与刀1c 弹侧池 dict 复用的别名
	# 污染互斥——袋持快照值，后续命中改写源 dict 不漂移冲刷）。
	var bag: Dictionary = _bag_pool.pop_back() if not _bag_pool.is_empty() else {}
	bag["source_uid"] = p_ctx.source_uid
	bag["target_uid"] = p_ctx.target_uid
	bag["target"] = p_ctx.target
	bag["frame_stamp"] = p_ctx.frame_stamp
	bag["last_frame"] = p_ctx.frame_stamp
	bag["rng_stream_id"] = p_ctx.rng_stream_id
	bag["base_atk"] = p_ctx.base_atk
	bag["flat_bonus"] = p_ctx.flat_bonus
	bag["crit_chance"] = p_ctx.crit_chance
	bag["crit_mult"] = p_ctx.crit_mult
	bag["element"] = p_ctx.element
	bag["hit_flags"] = p_ctx.hit_flags
	bag["target_resist"] = p_ctx.target_resist
	bag["pos"] = p_ctx.pos
	bag["kill_backlink"] = p_ctx.kill_backlink
	bag["bounce_count"] = p_ctx.bounce_count
	bag["pierce_index"] = p_ctx.pierce_index
	bag["generation"] = p_ctx.generation
	bag["is_first_hit_of_wave"] = p_ctx.is_first_hit_of_wave
	bag["player_hp_pct"] = p_ctx.player_hp_pct
	bag["add_entries"] = _copy_pool_dicts(p_ctx.add_entries)
	bag["mult_pools"] = _copy_pool_dicts(p_ctx.mult_pools)
	bag["local_pools"] = _copy_pool_dicts(p_ctx.local_pools)
	return bag


func _bag_release(p_e: Dictionary) -> void:
	# R232 刀1b：袋还池（冲刷/丢弃收尾调用——clear 防旧值随复用泄漏；容量与硬帽
	# 同量级封顶，超限交 GC）。e 无袋（原路径/空项）no-op。
	if not p_e.has("bag"):
		return
	var bag: Dictionary = p_e["bag"]
	bag.clear()
	if _bag_pool.size() < SETTLE_PENDING_HARD_CAP:
		_bag_pool.append(bag)
	p_e.erase("bag")


static func _copy_pool_dicts(p_src: Array[Dictionary]) -> Array[Dictionary]:
	# R232 刀1b：池数组浅拷贝（数组新建+逐 dict duplicate——浅层：dict 内无嵌套容器，
	# 键集 = pool_id/source_uid/contrib/cap_pool/priority 或 add 池六键，duplicate 一层
	# 即与源 dict 脱钩）
	var out: Array[Dictionary] = []
	for d in p_src:
		out.append(d.duplicate())
	return out


func _ctx_from_bag(p_bag: Dictionary, p_out: DamageContext) -> DamageContext:
	# R232 刀1b：袋→ctx 重建（全 22 字段覆写——与弹侧 _reset_ctx_scratch 同一清单；
	# 重建值=顺延入袋时快照，_resolve_core 九步输入与原 held-ctx 路径逐位相同）。
	# 三池整批 assign 袋持浅拷贝数组（dict 随 resolve 只读消费，冲刷收束后袋还池时
	# 仅清袋键，数组与 dict 归 ctx 侧 GC）。
	p_out.source_uid = int(p_bag["source_uid"])
	p_out.target_uid = int(p_bag["target_uid"])
	p_out.target = p_bag["target"] as Enemy
	p_out.frame_stamp = int(p_bag["frame_stamp"])
	p_out.rng_stream_id = int(p_bag["rng_stream_id"])
	p_out.base_atk = float(p_bag["base_atk"])
	p_out.flat_bonus = float(p_bag["flat_bonus"])
	p_out.crit_chance = float(p_bag["crit_chance"])
	p_out.crit_mult = float(p_bag["crit_mult"])
	p_out.element = int(p_bag["element"])
	p_out.hit_flags = int(p_bag["hit_flags"])
	p_out.target_resist = float(p_bag["target_resist"])
	p_out.pos = p_bag["pos"]
	p_out.kill_backlink = p_bag["kill_backlink"]
	p_out.bounce_count = int(p_bag["bounce_count"])
	p_out.pierce_index = int(p_bag["pierce_index"])
	p_out.generation = int(p_bag["generation"])
	p_out.is_first_hit_of_wave = bool(p_bag["is_first_hit_of_wave"])
	p_out.player_hp_pct = float(p_bag["player_hp_pct"])
	p_out.add_entries.assign(p_bag["add_entries"])
	p_out.mult_pools.assign(p_bag["mult_pools"])
	p_out.local_pools.assign(p_bag["local_pools"])
	return p_out


func _synthetic_deferred(p_ctx: DamageContext) -> DamageResult:
	# 顺延占位结果：final=0/killed=false/deferred_merge=true（projectile_base 无管线
	# 防御零值直通先例）；panel_snapshot 带当前面板段供元素附着快照读数不归零
	var r := DamageResult.new()
	r.deferred_merge = true
	r.source_uid = p_ctx.source_uid
	r.target_uid = p_ctx.target_uid
	r.frame_stamp = p_ctx.frame_stamp
	r.pos = p_ctx.pos
	r.element = p_ctx.element
	r.panel_snapshot = p_ctx.base_atk
	r.feel_level = GameConst.FeelLevel.HIT
	r.popup_style = GameConst.PopupStyle.NORMAL
	return r


func _drain_pending_budget() -> void:
	# 帧头积压冲刷（begin_frame 幂等缓存清空后——冲刷结果可入本帧幂等缓存）：
	# 门开 → 预算=帽值，FIFO 头部按剩余预算逐项真结算（先来先服务，本帧新命中
	# 排队其后）；门关（tier 回 3/切特效优先/override 关）→ 积压立即全量冲刷
	# （伤害不滞留；一次性成本帧头承担）。
	var cap := _settle_cap_now()
	if cap <= 0:
		_settle_left = 0
		if not _pending_fifo.is_empty():
			_flush_all_pending()
		return
	_settle_left = cap
	while _settle_left > 0 and not _pending_fifo.is_empty():
		_flush_pending_head()


func _flush_pending_head() -> void:
	# FIFO 头部单项冲刷（预算冲刷/过期强冲共用 _flush_entry 统一入口）
	var key: int = _pending_fifo.pop_front()
	var e: Dictionary = _pending_pair.get(key, {})
	_pending_pair.erase(key)
	if e.is_empty():
		return
	var outcome := _flush_entry(e)
	if outcome == 0:
		_settle_left -= 1
		_stats["settle_flush"] += 1
	elif outcome == 1:
		_stats["settle_flush_dead"] += 1
	else:
		_stats["settle_flush_reuse"] += 1


func _flush_entry(p_e: Dictionary) -> int:
	# R223 修轮统一冲刷入口：① uid 复验（QA-1 HIGH/评审#3 同锤）——Enemy 死亡即归池
	# （节点身份不变 dead=true），池节点同帧 LIFO/跨帧复用经 spawn() 派**新 uid**——
	# 只查 dead 位会把旧伤落到满血新怪（幻影伤害，事件还带旧 uid 消费面死锚）；
	# uid 不符按诚实丢弃计 settle_flush_reuse（homing_projectile._is_target_valid
	# uid 双重校验同款先例）。② 死亡校验（原语义）→ settle_flush_dead。③ 真结算 +
	# 击杀证据回填（评审 high：弹侧 ctx 带 kill_backlink，冲刷击杀回填 killed_target
	# ——死亡新星 MEC_KILL_BLAST 消费面；_live 守卫防归池弹晚到污染——spawn/
	# _reset_state 虽双清零，回收后的证据已无消费点）。
	# 返回 0=真结算 / 1=亡目标丢弃 / 2=uid 复用丢弃。
	# R232 刀1b：CTX_REUSE 时 e 存袋——冲刷用 pipeline 侧复用 ctx 从袋重建（_ctx_from_bag
	# 全字段覆写）；三条出口均还袋入池（原路径 "ctx" 键无袋 no-op）。
	var ctx: DamageContext
	if p_e.has("ctx"):
		ctx = p_e["ctx"]
	else:
		if _flush_ctx == null:
			_flush_ctx = DamageContext.new()
		ctx = _ctx_from_bag(p_e["bag"], _flush_ctx)
	var t: Enemy = ctx.target
	if t != null and is_instance_valid(t) and t.uid != ctx.target_uid:
		_bag_release(p_e)
		return 2
	if not _target_alive(ctx):
		_bag_release(p_e)
		return 1
	# R232 T1b：冲刷路径真结算同入结算轴计时窗（预算冲刷/过期强冲共用本口）
	var result: DamageResult
	if SETTLE_PROBE:
		var tf := Time.get_ticks_usec()
		result = _resolve_core(ctx)
		_settle_us_total += Time.get_ticks_usec() - tf
	else:
		result = _resolve_core(ctx)
	if result != null and result.killed and ctx.kill_backlink != null:
		var proj: Object = ctx.kill_backlink.get_ref()
		if proj != null and is_instance_valid(proj) and bool(proj.get(&"_live")):
			proj.set(&"killed_target", true)
	_bag_release(p_e)
	return 0


func _flush_all_pending() -> void:
	# 全量冲刷（门关闭/清场路径）
	while not _pending_fifo.is_empty():
		_flush_pending_head()
	_settle_left = 0


func _end_frame_pending_maintenance() -> void:
	# 帧末积压维护：① 硬帽修剪（>256 丢最老+计数——持续超载诚实卸载）② 过期强冲
	#（顺延 >12 帧仍排不上预算：伤害必须落地）。位于 stats 增量落账之前——本帧维护
	# 计数当帧可见。
	while _pending_fifo.size() > SETTLE_PENDING_HARD_CAP:
		var key: int = _pending_fifo.pop_front()
		var e_drop: Dictionary = _pending_pair.get(key, {})
		_pending_pair.erase(key)
		_bag_release(e_drop)                   # R232 刀1b：丢弃项还袋（原路径 no-op）
		_stats["settle_overload_drop"] += 1
	if _cur_frame_stamp < 0:
		return                                 # 帧号未知（无参 begin_frame/测试直构）——强冲守卫关闭
	var i := 0
	while i < _pending_fifo.size():
		var key2: int = _pending_fifo[i]
		var e: Dictionary = _pending_pair.get(key2, {})
		if e.is_empty():
			_pending_fifo.remove_at(i)
			continue
		if _cur_frame_stamp - int(e["frame"]) > settle_stale_frame_now():
			_pending_fifo.remove_at(i)
			_pending_pair.erase(key2)
			var outcome := _flush_entry(e)
			if outcome == 0:
				_stats["settle_flush"] += 1
				_stats["settle_stale_flush"] += 1
			elif outcome == 1:
				_stats["settle_flush_dead"] += 1
			else:
				_stats["settle_flush_reuse"] += 1
			continue
		i += 1


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


func _check_idempotent(p_ctx: DamageContext, p_key: int = -1) -> DamageResult:
	# 1. 幂等检查（命中返回缓存结果；§4.1 int64 位拼接键）
	# R220 刀8②：键一算一用（原 has+取两算 _idem_key——每命中两次位拼接白付）
	# R232 刀1d-①：p_key 可选注入（-1=自算——resolve_reaction/直调调用方零改动）
	var key := p_key if p_key >= 0 else _idem_key(p_ctx)
	if _idempotent_cache.has(key):
		return _idempotent_cache[key] as DamageResult
	return null


func _target_alive(p_ctx: DamageContext) -> bool:
	# 2. 目标存活（死亡短路 E-06）：null / dead → false
	# R232 刀1a：Enemy 类型分支直读 dead 字段（原 .get("dead") String 反射——R220 刀4
	# 漏网第 1 处，每命中 1 次属性查，ARM 放大）；else 保留 Variant 路径供测试桩
	# （R210 双轨先例）。
	if p_ctx.target == null:
		return false
	if p_ctx.target is Enemy:
		return not (p_ctx.target as Enemy).dead
	var d: Variant = p_ctx.target.get("dead")
	if d != null:
		return not bool(d)
	return true


func _aggregate_add(p_ctx: DamageContext, p_stack: ModifierStack,
		p_bal: BalanceTables = null) -> void:
	# 3. Add 池聚合（F3 衰减 + 跨 ID 线性 + 负贡献全额 + F4 池钳——委托 ModifierStack）
	# R232 刀1d-②：p_bal 可选注入（null=自算 _balance——直调调用方/回退零改动）
	var bal := p_bal if p_bal != null else _balance()
	p_stack.aggregate_add(p_ctx.add_entries, bal.add_pool_caps)


func _apply_flat(p_ctx: DamageContext, p_stack: ModifierStack,
		p_bal: BalanceTables = null) -> void:
	# 4. Flat 加入（Σ_flat ≤ f_flat × base_atk 比例钳制，超限截断 + 审计）
	var bal := p_bal if p_bal != null else _balance()
	p_stack.apply_flat(p_ctx.flat_bonus, p_ctx.base_atk, bal.flat_ratio_cap)


func _aggregate_mults(p_ctx: DamageContext, p_stack: ModifierStack,
		p_bal: BalanceTables = null) -> void:
	# 5. 乘区聚合（聚合层合并 → 防御层去重 → 单区 cap_pool_p → 名额 top-8 → 整体钳 8.0）
	var bal := p_bal if p_bal != null else _balance()
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
	# R22 P1 元素免疫：目标免疫该元素 → 伤害归零 +「免疫」反馈 + 无顿帧（打不动=无奖励反馈）
	# R232 刀1a：Enemy 类型分支直调 is_elem_immune（原 has_method(&"...")+call String
	# 反射——R220 刀4 漏网第 4 处〔分析新增〕，每命中 1 次方法查+Variant call）；else
	# 保留桩路径（R210 双轨先例）。
	var target: Variant = p_ctx.target
	if target != null and is_instance_valid(target as Object):
		var immune := false
		if target is Enemy:
			immune = (target as Enemy).is_elem_immune(p_ctx.element)
		elif (target as Object).has_method(&"is_elem_immune"):
			immune = bool((target as Object).call(&"is_elem_immune", p_ctx.element))
		if immune:
			p_result.immune = true
			p_result.target_factor = 0.0
			p_result.feel_level = GameConst.FeelLevel.HIT
			p_result.popup_style = GameConst.PopupStyle.IMMUNE
			p_result.is_crit = false
			return
	p_result.target_factor = (1.0 - _read_resist(p_ctx)) * (1.0 + _read_status_vuln(p_ctx))


func _finalize(p_ctx: DamageContext, p_stack: ModifierStack, p_result: DamageResult,
		p_bal: BalanceTables = null) -> void:
	# 9a+9b. 终值钳制 + R_alarm 双闸 + 审计落字段 + killed 判定。
	# 9a. raw = S × M × L × C × V → clamp(raw, 0, base_atk × r_alarm_ratio)（保险钳制）
	var c := p_ctx.crit_mult if p_result.is_crit else 1.0
	var raw := p_result.panel_snapshot * p_result.mult_product * p_result.local_product * c * p_result.target_factor
	var alarm_ratio := (p_bal if p_bal != null else _balance()).r_alarm_ratio
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
	# 9c. EventBus 广播（唯一广播点，禁止绕过）：damage_resolved 每次成功结算——
	#     R220 刀11 批化：结算期只 push 入帧队列（GameLoop ⑧ UI 段前统一保序派发，
	#     dispatch_resolved_frame；弹段内联五路同步扇出vc26 79ms 主构成削减）；
	#     开关 false=即时同步派发 EventBus 原路径（回滚）。
	#     damage_alarm 一局一次（后续超限仍记 audit.alarm 与 alarms 计数，仅不重复广播）；
	#     burn_devour_proc 烈焰吞噬乘区生效（pool_breakdown 含 burn_dmg → 表现层内聚火焰）
	#     ——此两路及 reaction_triggered（resolve_reaction 内）保持同步即时口径。
	if DAMAGE_RESOLVED_BATCHED:
		_resolved_queue.append(p_result)
	else:
		EventBus.emit_damage_resolved(p_result)
	if p_result.pool_breakdown.has(&"burn_dmg"):
		EventBus.emit_burn_devour_proc(p_result.pos)
	if p_result.audit != null and p_result.audit.alarm and not _alarm_emitted:
		_alarm_emitted = true
		EventBus.emit_damage_alarm(p_result)


func _cache_result(p_ctx: DamageContext, p_result: DamageResult, p_key: int = -1) -> void:
	# 9d. 幂等缓存写入（§4.1 位拼接键；begin_frame 每帧清空）
	# R232 刀1d-①：p_key 可选注入（-1=自算——resolve_reaction/直调调用方零改动）
	_idempotent_cache[p_key if p_key >= 0 else _idem_key(p_ctx)] = p_result


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
	# R220 刀4：Enemy 类型分支直调（原 has_method("get_resist") String 字面量反射——
	# 真机命中链 ARM 代价放大）；else 保留旧 Variant 路径供测试桩（R210 双轨先例）。
	if p_ctx.target != null:
		if p_ctx.target is Enemy:
			return (p_ctx.target as Enemy).get_resist(p_ctx.element)
		if p_ctx.target.has_method("get_resist"):
			return float(p_ctx.target.call("get_resist", p_ctx.element))
		var arr: Variant = p_ctx.target.get("resist")
		if arr is Array and p_ctx.element >= 0 and p_ctx.element < (arr as Array).size():
			return float((arr as Array)[p_ctx.element])
	return p_ctx.target_resist


func _read_status_vuln(p_ctx: DamageContext) -> float:
	# 目标状态易伤快照（B_spec §2.1 状态修正项，如冰冻易伤 +0.25）；
	# 字段不存在 → 0.0（因子 1.0 中性）。
	# R232 刀1a 披露（分析 R9）：Enemy 全文无 status_vuln 字段——typed 直读落空，
	# 维持 .get 反射路径（对真敌恒 0.0 中性与改造前逐位一致；桩/未来字段扩展仍可达）。
	if p_ctx.target != null:
		var v: Variant = p_ctx.target.get("status_vuln")
		if v != null:
			return float(v)
	return 0.0


func _apply_to_target(p_ctx: DamageContext, p_result: DamageResult) -> bool:
	# 9b killed 判定：优先 Enemy.take_result（§2.11：apply + 死亡广播 + 掉落触发）；
	# 占位回退 apply_damage(final) -> bool；均缺省 → 纯公式模式 killed=false。
	# R220 刀4：Enemy 类型分支直调（原 has_method("take_result") String 字面量反射）；
	# else 保留旧 Variant 路径供测试桩（R210 双轨先例）。
	var t: Object = p_ctx.target
	if t == null:
		return false
	if t is Enemy:
		var te := t as Enemy
		te.take_result(p_result)
		return te.dead
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
