# scripts/combat/weapon/weapon_base.gd
# M-05~M-08 WeaponBase（架构 §2.8.1）：武器抽象基类（四形态子类按 form 分派）。
# · 冷却/射速节拍 tick(game_delta)：冷却推进 → 满足节拍时 try_fire（射速上限 30/s 双护栏）。
# · 词条挂载 trait_stack（武器主栈 ≤12）：常驻面板聚合（build_panel_snapshot，F-13 母本）
#   + OnHit 注入源（copy_runtime → 投射物/光束运行时栈）。
# · 面板快照：{base_atk, crit_rate, crit_mult, flat_bonus, add_entries[]}——分裂继承比例的
#   母本（F-13）；add_atk 池经 add_entries 入管线步骤 3（F3 衰减真源），其余加算池
#   参数侧聚合（rof/cdr/crit/critdmg/spd/pierce/pellets）。
class_name WeaponBase
extends Node2D

signal leveled(new_level: int)

const MAX_LEVEL: int = 5                       # L1~L5（升级表终值口径）
const AIM_FALLBACK := Vector2.UP               # 无目标时的默认指向（全自动开火持续）
const MILESTONE_VALUE_MULT: float = 1.6         # 满层质变乘区（ADD 池词条挂至 stack_max ×1.6）

var data: WeaponData = null                    # 形态参数（M-14 注入）
var uid: int = 0
var level: int = 1                             # L1~L5（升级表终值口径）
var player: Node2D = null                      # 宿主注入（Player；宽类型规避循环解析）
var meta_atk_pct: float = 0.0                 # 局外养成攻击 + 角色攻击修正（Player 注入）
var trait_stack: TraitStack = null             # 武器级词条（常驻面板聚合 + OnHit 注入源）
var target_strategy: int = GameConst.TargetStrategy.NEAREST
var cooldown_left: float = 0.0
var damage_pipeline: RefCounted = null          # 注入（DamagePipeline / 桩——resolve 签名一致）
var projectile_pool: ProjectilePool = null      # 注入（ballistic 场景池）
var enemy_grid: SpaceGrid = null               # 注入（索敌）
var laser_pool: LaserBeamPool = null           # 注入（LASER 形态）
var elemental: ElementalSystem = null          # 注入（元素附着通道）
var relic_handler: RelicHandler = null         # 注入（集成包 B.2：遗物命中乘区问询）
var wave_director: WaveDirector = null         # 注入（集成包 B.4：SYN_FIRST_STRIKE 波首命中位）

var _panel_cache: Dictionary = {}              # 面板快照缓存（词条挂载/升级时失效）


func setup(p_data: WeaponData, p_player: Node2D, p_deps: Dictionary) -> void:
	# 绑定数据/宿主/依赖注入包（§2.8.1：deps = pipeline/projectile_pool/enemy_grid/…）
	data = p_data
	player = p_player
	uid = GameConst.next_uid()
	trait_stack = TraitStack.new()
	damage_pipeline = p_deps.get("pipeline")
	projectile_pool = p_deps.get("projectile_pool")
	enemy_grid = p_deps.get("enemy_grid")
	laser_pool = p_deps.get("laser_pool")
	elemental = p_deps.get("elemental")
	relic_handler = p_deps.get("relic_handler")
	wave_director = p_deps.get("wave_director")
	cooldown_left = 0.0
	level = 1
	_invalidate_panel()


func tick(p_game_delta: float) -> void:
	# 冷却推进 → 满足节拍时 try_fire（子类行为）；词条冷却推进
	if data == null:
		return
	if trait_stack != null:
		trait_stack.advance_cooldowns(p_game_delta)
	if cooldown_left > 0.0:
		cooldown_left = maxf(cooldown_left - p_game_delta, 0.0)
	else:
		if try_fire():
			cooldown_left = _fire_interval()
	_on_tick_post(p_game_delta)


func try_fire() -> bool:
	# ★ 开火入口（抽象：子类实现开火行为；软上限检查在 ProjectilePool）
	return false


func attach_trait(p_trait: TraitData) -> bool:
	# 词条挂载（单武器 ≤12，超出拒绝 + 计数；卡牌流前置过滤）
	if trait_stack == null or p_trait == null:
		return false
	var attached := trait_stack.attach(p_trait)
	if attached:
		# 满层质变（2026-08-31 用户反馈「哪些 buff 到什么程度会质变」）：ADD 池词条挂至
		# stack_max → 数值乘区 ×1.6（TraitBase.value_mult，聚合侧消费）+ 里程碑广播
		#（HUD 金色 toast + 音效——「一大波爽感」节点）。幂等：已质变（mult>1）不重触
		if p_trait.pool == GameConst.PoolClass.ADD and p_trait.stack_max >= 2:
			for mounted in trait_stack.traits:
				if mounted.data != null and mounted.data.id == p_trait.id \
						and mounted.layers >= p_trait.stack_max \
						and is_equal_approx(mounted.value_mult, 1.0):
					mounted.value_mult = MILESTONE_VALUE_MULT
					_invalidate_panel()
					EventBus.emit_trait_milestone(p_trait.id, p_trait.display_name,
						MILESTONE_VALUE_MULT)
					DebugStats.count(&"trait_milestone")
					break
		_invalidate_panel()
		if p_trait.pool == GameConst.PoolClass.ADD \
				and p_trait.pool_id == &"add_hp" and player != null:
			# AFF_HP_UP 消费点（原死池接线修复）：add_hp 池逐层落地玩家血条——A3 §4.2
			# 每层 max_hp +25（stack_max 4，线性不衰减）；上限增量同步回补等量当前血
			#（主控裁定 2026-08-29）。挂载收束口接线：选卡与 REL_ECHO 回响复制共用本路径。
			player.call(&"apply_max_hp_up", p_trait.value)
		if p_trait.pool == GameConst.PoolClass.ELEM \
				and p_trait.params.has("reaction_mult") and elemental != null:
			# ELE_REACTION_VOID：反应强化注册到 ElementalSystem（全局 ×1.8 聚合）
			elemental.register_reaction_mult(uid, float(p_trait.params["reaction_mult"]))
		if p_trait.id == &"MEC_SHIELD" and player != null:
			# MEC_SHIELD 消费点接线（A3 §4.4 格挡力场：每 interval_s 护盾挡 1 次接触伤害，
			# 2 层 → 5.5s）。层数取挂载后的 TraitBase（p_trait 是 TraitData 定义，无 layers
			# 运行时字段——2026-08-31 P0 修复：直读 p_trait.layers 运行时崩溃致护盾条不显示）。
			var shield_layers := 0
			for mounted in trait_stack.traits:
				if mounted.data != null and mounted.data.id == p_trait.id:
					shield_layers = mounted.layers
			if shield_layers > 0:
				player.call(&"apply_shield_trait", shield_layers, p_trait.params)
	return attached


func get_stat(p_key: StringName) -> float:
	# 当前等级终值（upgrade_table[level-1]）
	if data == null or level < 1 or level > data.upgrade_table.size():
		return 0.0
	return float(data.upgrade_table[level - 1].get(p_key))


func get_current_atk() -> float:
	# F2：get_stat("base_atk") × g_global（g_global 当前 = 1）
	return get_stat(&"base_atk")


func build_panel_snapshot() -> Dictionary:
	# 面板段快照（分裂继承比例的母本，F-13）：add_atk 池以原始条目入 add_entries
	# （衰减职责在管线步骤 3）；crit 参数武器侧聚合（F3 同式预览）。
	if not _panel_cache.is_empty():
		return _panel_cache
	var aggregate: Dictionary = trait_stack.aggregate_panel() if trait_stack != null else {}
	var crit_rate := 0.05
	var crit_dmg := 2.0
	if data != null:
		crit_rate = data.crit_rate
		crit_dmg = data.crit_dmg
	var crit_cap := 1.0
	if GameConfig.balance != null:
		crit_cap = GameConfig.balance.cap_crit_rate
	var snapshot := {
		"base_atk": get_current_atk() * (1.0 + meta_atk_pct),   # 局外养成/角色修正入面板
		"crit_rate": clampf(crit_rate + float(aggregate.get("add_crit", 0.0)), 0.0, crit_cap),
		"crit_mult": crit_dmg + float(aggregate.get("add_critdmg", 0.0)),
		"flat_bonus": 0.0,
		"add_entries": trait_stack.aggregate_add_entries() if trait_stack != null else [],
	}
	_panel_cache = snapshot
	return snapshot


func build_damage_context(p_target: Node2D) -> DamageContext:
	# 武器侧聚合 ctx（近战/光束等无投射物路径；投射物路径经 panel_snapshot 展开）
	var snapshot := build_panel_snapshot()
	var ctx := DamageContext.make()
	ctx.source_uid = uid
	ctx.target = p_target
	ctx.target_uid = int(p_target.get("uid"))
	ctx.frame_stamp = GameConfig.frame_stamp
	ctx.base_atk = float(snapshot.get("base_atk", 0.0))
	ctx.flat_bonus = float(snapshot.get("flat_bonus", 0.0))
	ctx.crit_chance = float(snapshot.get("crit_rate", 0.0))
	ctx.crit_mult = float(snapshot.get("crit_mult", 2.0))
	var entries: Variant = snapshot.get("add_entries", [])
	if entries is Array:
		for entry in entries:
			ctx.add_entries.append(entry)
	ctx.element = GameConst.Element.KIN
	ctx.is_first_hit_of_wave = is_wave_first_hit()   # B.4：波首命中位（SYN_FIRST_STRIKE）
	if p_target != null:
		ctx.pos = p_target.global_position
		ctx.target_resist = _read_resist(p_target)
	inject_vuln_pool(ctx, p_target)
	inject_relic_pools(ctx, p_target)                # B.2：遗物命中时点独立乘区（TROPHY/MOMENTUM）
	return ctx


func collect_context_mults(p_ctx: DamageContext, p_tctx: TraitContext) -> void:
	# 词条乘区预聚合（§4.4 ②：光束/近战路径）+ 目标侧易伤乘区注入（A2 §1.8 vuln 池）
	if trait_stack != null:
		for pool in trait_stack.collect_mult_pools(p_tctx):
			p_ctx.mult_pools.append(pool)
	inject_vuln_pool(p_ctx, p_tctx.target)
	inject_relic_pools(p_ctx, p_tctx.target)         # B.2：同 ctx 二次注入由 has_mult_pool 去重


func get_threshold(p_threshold_id: StringName) -> Dictionary:
	# 通用质变阈值查询（A3 §3.11；threshold_traits 声明，词条效果侧消费）
	if data == null:
		return {}
	for entry in data.threshold_traits:
		if StringName(str(entry.get("threshold_id", ""))) == p_threshold_id:
			return entry
	return {}


func settle_aoe(p_pos: Vector2, p_radius: float, p_atk: float, p_secondary: bool,
		p_exclude: Node2D = null) -> void:
	# 圆查询逐敌独立结算（死亡新星/TH_SIZE_NOVA 冲击波/武器 AOE 通道；网格距离精判口径）。
	# p_exclude：主结算目标排除（冲击波不重复结算本跳直击目标，同构 Homing._blast_secondaries）
	# 落血口径双轨：真件管线 resolve 内部落血（9b）；透传桩由本方法落血（见循环内注释）
	if enemy_grid == null or damage_pipeline == null:
		return
	var candidates: Array[Node2D] = []
	candidates.append_array(enemy_grid.query_circle(p_pos, p_radius))
	for target in candidates:
		if target == null or target == p_exclude or bool(target.get("dead")):
			continue
		var ctx := DamageContext.make()
		ctx.source_uid = uid
		ctx.target = target
		ctx.target_uid = int(target.get("uid"))
		ctx.frame_stamp = GameConfig.frame_stamp
		ctx.base_atk = maxf(p_atk, 0.0)
		ctx.element = GameConst.Element.KIN
		if p_secondary:
			ctx.hit_flags |= GameConst.HIT_IS_AOE_SECONDARY
		ctx.pos = (target as Node2D).global_position
		var result: DamageResult = damage_pipeline.call(&"resolve", ctx)
		if result == null:
			continue
		# 落血口径双轨（审查修复 A）：真件 DamagePipeline 九步 9b 在 resolve 内部已
		# take_result 落血（_apply_to_target——killed 判定/死亡广播唯一执行点），调用方
		# 再落血即 AOE 范围伤害 ×2（TH_SIZE_NOVA/MEC_KILL_BLAST/遗物清屏冲击）；透传桩
		# resolve 只算不落血，落血职责在调用方（pkg3 桩用例锁定口径，保持不变）。
		if damage_pipeline is DamagePipeline:
			continue
		if target.has_method(&"take_result"):
			target.call(&"take_result", result)


func acquire_target() -> Node2D:
	# 索敌（目标策略：NEAREST/FOREMOST/LOWEST_HP/LOCKED——M1 实现 NEAREST 全量口径）
	if enemy_grid == null:
		return null
	var origin := muzzle_position()
	var found := enemy_grid.query_nearest(origin, 1600.0, null)
	if found != null and bool(found.get("dead")):
		return null
	return found


func aim_direction() -> Vector2:
	# 开火指向：目标方向 / 无目标回退 UP（全自动开火持续）
	var target := acquire_target()
	if target != null:
		var dir := (target.global_position - muzzle_position()).normalized()
		if dir != Vector2.ZERO:
			return dir
	return AIM_FALLBACK


func muzzle_position() -> Vector2:
	# 出射点（宿主位置；武器随宿主平移）
	return global_position


func level_up() -> void:
	# 武器精通卡应用 → leveled 信号；Lv5 = 终极形态里程碑（质变播报，mult=0 表纯里程碑）
	if level < MAX_LEVEL:
		level += 1
		_invalidate_panel()
		leveled.emit(level)
		if level >= MAX_LEVEL and data != null:
			EventBus.emit_trait_milestone(StringName("max_%s" % String(data.id)),
				String(data.display_name) + " · 终极形态", 0.0)
			DebugStats.count(&"weapon_max_milestone")


# ── 内部 ──────────────────────────────────────────────────────────
func _player_rof_mult() -> float:
	# 玩家侧射速合成倍率：过载咆哮（角色技能）× 地图祝福·射速（词缀二期「狂热」+6%，
	# 数值真源 map_table.gd）——基类与 BallisticWeapon 覆写共用（两形态同一口径）
	if player == null or not is_instance_valid(player):
		return 1.0
	return maxf(float(player.get("rof_mult")) * float(player.get("map_rof_mult")), 0.1)


func _fire_interval() -> float:
	# 节拍间隔：BALLISTIC = 1/rof（子类覆写射速口径）；其余形态 = cd × (1−ΣCDR)
	if data == null:
		return 1.0
	if data.form == GameConst.WeaponForm.BALLISTIC:
		var rof := clampf(get_stat(&"rof"), 0.1, _cap_rof())
		return 1.0 / (rof * _player_rof_mult())
	var cd := maxf(get_stat(&"cd"), 0.01)
	var cdr := 0.0
	var cap_cdr := 0.6
	if trait_stack != null:
		cdr = float(trait_stack.aggregate_panel().get("add_cdr", 0.0))
	if GameConfig.balance != null:
		cap_cdr = GameConfig.balance.cap_cdr_sum
	cdr = clampf(cdr, 0.0, cap_cdr)
	return cd * (1.0 - cdr) / _player_rof_mult()


func _cap_rof() -> float:
	# 单武器射速封顶 30/s（性能双护栏）
	if GameConfig.balance != null:
		return GameConfig.balance.cap_rof_per_weapon
	return 30.0


func _on_tick_post(p_game_delta: float) -> void:
	# 子类逐帧附加调度钩子（光束推进/近战实体推进等）
	pass


func _invalidate_panel() -> void:
	_panel_cache = {}


func _read_resist(p_target: Node2D) -> float:
	# 目标抗性快照（KIN 通道；光束/近战为动能伤害）
	if p_target != null and p_target.has_method(&"get_resist"):
		return float(p_target.call(&"get_resist", GameConst.Element.KIN))
	return 0.0


func inject_vuln_pool(p_ctx: DamageContext, p_target: Node2D) -> void:
	# 目标侧易伤乘区注入（A2 §1.8：vuln 池在⑤入池——冰冻易伤 ×1.25 正式路径）。
	# 集成包 B.7 去重：build_damage_context 与 collect_context_mults 双入口共用本方法，
	# 同一 ctx 已含 vuln 池时跳过（管线防御层虽可 max 合并，注入侧去重保名额/审计干净）。
	if p_target == null or has_mult_pool(p_ctx, &"vuln"):
		return
	var state: Variant = p_target.get("elemental")
	if state is ElementalState:
		var factor := (state as ElementalState).get_vuln_factor()
		if factor > 1.0:
			p_ctx.mult_pools.append({
				"pool_id": &"vuln",
				"source_uid": 0,
				"contrib": factor - 1.0,
				"cap_pool": factor - 1.0,
				"priority": 0,
			})


func inject_relic_pools(p_ctx: DamageContext, p_target: Node2D) -> void:
	# 遗物命中时点独立乘区（集成包 B.2：REL_BOSS_TROPHY / REL_MOMENTUM——
	# 数值/池名/目标 tag 全部由 RelicData.params 数据驱动，问询 RelicHandler）
	if relic_handler != null:
		relic_handler.inject_hit_mult_pools(p_ctx, p_target)


func is_wave_first_hit() -> bool:
	# 波首命中位（B.4 接线：SYN_FIRST_STRIKE「本波首杀前」条件——
	# WaveDirector.wave_first_kill_done 置位前均为 true；无导演引用（测试环境）→ false 安全）
	return wave_director != null and not wave_director.wave_first_kill_done


static func has_mult_pool(p_ctx: DamageContext, p_pool_id: StringName) -> bool:
	# ctx 乘区池去重判据（B.7 易伤去重 / 遗物乘区幂等注入共用）
	if p_ctx == null:
		return false
	for pool in p_ctx.mult_pools:
		if StringName(String(pool.get("pool_id", ""))) == p_pool_id:
			return true
	return false
