# scripts/core/damage/damage_pipeline_stub.gd
# 包 2 透传桩：与包 1 真件 DamagePipeline（scripts/core/damage/damage_pipeline.gd）
# 完全同接口（架构 §2.5 公共签名集），仅做 S×M×L×C×V 直算的最小实现：
# 无幂等缓存、无九步护栏（衰减/cap/名额/审计）、无 ×500 告警——真件合入后由
# 工厂 get_pipeline() 自动切换（或经 debug_use_pipeline_stub 显式保持桩）。
# 接口契约（冻结，包 1 合入时逐签名对齐）：
#   bind_rng_stream(stream_id: int, seed: int) -> void
#   begin_frame() -> void            # 真件：清幂等缓存；桩：空操作
#   end_frame() -> void              # 真件：遥测落 DebugStats；桩：空操作
#   resolve(ctx: DamageContext) -> DamageResult
#   resolve_reaction(p_ctx: DamageContext) -> DamageResult   # F21 独立结算通道（不掷暴击）
#   stats() -> Dictionary
class_name DamagePipelineStub
extends RefCounted

const REAL_PIPELINE_PATH := "res://scripts/core/damage/damage_pipeline.gd"   # 包 1 真件（在途，勿创建）

var _rng_streams: Dictionary = {}            # stream_id -> RandomNumberGenerator
var _rng_default: RandomNumberGenerator = RandomNumberGenerator.new()
var _stats: Dictionary = {
	"settles": 0, "reaction_settles": 0, "crits": 0, "begins": 0, "ends": 0,
}


func bind_rng_stream(p_stream_id: int, p_seed: int) -> void:
	# 暴击掷骰流（AC-12.5 固定种子回归；桩仅保存流，掷骰语义同真件）
	var rng := RandomNumberGenerator.new()
	rng.seed = p_seed
	_rng_streams[p_stream_id] = rng


func begin_frame() -> void:
	# 真件：清幂等缓存（GameLoop 投射物阶段前调用）；桩：仅计数
	_stats["begins"] = int(_stats["begins"]) + 1


func end_frame() -> void:
	# 真件：遥测计数落 DebugStats；桩：仅计数
	_stats["ends"] = int(_stats["ends"]) + 1


func resolve(p_ctx: DamageContext) -> DamageResult:
	# 最小实现：S×M×L×C×V 直算（无幂等/无审计/无钳制）
	var result := DamageResult.new()
	var panel := _panel_sum(p_ctx)
	var mult := _mult_product(p_ctx)
	var local := _local_product(p_ctx)
	var crit := _roll_crit(p_ctx)
	var crit_factor := p_ctx.crit_mult if crit else 1.0
	var target_factor := 1.0 - p_ctx.target_resist
	var final := panel * mult * local * crit_factor * target_factor
	result.final_value = maxf(final, 0.0)
	result.is_crit = crit
	result.killed = _target_would_die(p_ctx, result.final_value)
	result.element = p_ctx.element
	result.source_uid = p_ctx.source_uid
	result.target_uid = p_ctx.target_uid
	result.frame_stamp = p_ctx.frame_stamp
	result.pos = p_ctx.pos
	result.panel_snapshot = panel
	result.mult_product = mult
	result.local_product = local
	result.target_factor = target_factor
	result.feel_level = GameConst.FeelLevel.CRIT if crit else GameConst.FeelLevel.HIT
	result.popup_style = GameConst.PopupStyle.CRIT if crit else GameConst.PopupStyle.NORMAL
	_stats["settles"] = int(_stats["settles"]) + 1
	if crit:
		_stats["crits"] = int(_stats["crits"]) + 1
	EventBus.emit_damage_resolved(result)
	return result


func resolve_reaction(p_ctx: DamageContext) -> DamageResult:
	# F21 独立结算通道：反应/DOT 不掷暴击（HIT_IS_REACTION / HIT_IS_DOT）
	var result := resolve(p_ctx)
	result.is_crit = false
	result.feel_level = GameConst.FeelLevel.CATALYST
	result.popup_style = GameConst.PopupStyle.REACTION
	_stats["reaction_settles"] = int(_stats["reaction_settles"]) + 1
	return result


func stats() -> Dictionary:
	return _stats.duplicate()


# ── 工厂 ──────────────────────────────────────────────────────────
static func get_pipeline() -> RefCounted:
	# 集成切换点（包 1 真件合入后启用）：
	#   默认真件路径：return load(REAL_PIPELINE_PATH).new()   —— 真件存在时自动切换
	# 切换条件（任一为真 → 返回桩）：
	#   ① 环境变量 IF_USE_PIPELINE_STUB=1
	#   ② GameConfig.debug_use_pipeline_stub > 0（global_constants.cfg 附加键，
	#      GameConfig._load_constants 对超出期望集的附加键亦纳入内存表，无需改包 0 代码）
	var use_stub := OS.get_environment("IF_USE_PIPELINE_STUB") == "1"
	if not use_stub and not Engine.is_editor_hint():
		# 编辑器上下文无 autoload（GameConfig），仅运行时/测试查询该开关
		use_stub = GameConfig.get_constant(&"debug_use_pipeline_stub", 0.0) > 0.0
	if use_stub:
		return DamagePipelineStub.new()
	if ResourceLoader.exists(REAL_PIPELINE_PATH):
		var script: Resource = ResourceLoader.load(REAL_PIPELINE_PATH, "", ResourceLoader.CACHE_MODE_REUSE)
		if script is GDScript:
			return (script as GDScript).new()
	# 包 1 真件未合入：回退透传桩（真件落地后本分支自然失效）
	push_warning("[DamagePipelineStub] 真件未合入（%s），回退透传桩" % REAL_PIPELINE_PATH)
	return DamagePipelineStub.new()


# ── 内部（最小实现） ──────────────────────────────────────────────
func _panel_sum(p_ctx: DamageContext) -> float:
	# S = base_atk × (1 + ΣAdd) + Flat（桩：无 F3 衰减 / 无 F4 池钳 / 无 Flat 比例钳制）
	var add_sum := 0.0
	for entry in p_ctx.add_entries:
		add_sum += float(entry.get("contrib", 0.0))
	return p_ctx.base_atk * (1.0 + add_sum) + p_ctx.flat_bonus


func _mult_product(p_ctx: DamageContext) -> float:
	# M = ∏(1 + contrib)（桩：无单区 cap / 无名额截断 / 无整体钳 8.0）
	var mult := 1.0
	for pool in p_ctx.mult_pools:
		mult *= 1.0 + float(pool.get("contrib", 0.0))
	return mult


func _local_product(p_ctx: DamageContext) -> float:
	# L = ∏(1 + contrib)（桩：无 cap_local）
	var local := 1.0
	for pool in p_ctx.local_pools:
		local *= 1.0 + float(pool.get("contrib", 0.0))
	return local


func _roll_crit(p_ctx: DamageContext) -> bool:
	# 暴击掷骰：HIT_NO_CRIT 掩码（反应/DOT）跳过；独立 RNG 流（桩语义同真件）
	if (p_ctx.hit_flags & GameConst.HIT_NO_CRIT) != 0:
		return false
	if p_ctx.crit_chance <= 0.0:
		return false
	if p_ctx.crit_chance >= 1.0:
		return true
	var rng: RandomNumberGenerator = _rng_default
	if _rng_streams.has(p_ctx.rng_stream_id):
		rng = _rng_streams[p_ctx.rng_stream_id]
	return rng.randf() < p_ctx.crit_chance


func _target_would_die(p_ctx: DamageContext, p_final: float) -> bool:
	# killed 投影（真件口径：目标 hp ≤ 终值；权威死亡判定在 Enemy.apply_damage）
	if p_ctx.target == null:
		return false
	var hp = p_ctx.target.get("hp")
	if hp == null:
		return false
	return float(hp) <= p_final
