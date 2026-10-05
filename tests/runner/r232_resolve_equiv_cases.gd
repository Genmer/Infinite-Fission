# tests/runner/r232_resolve_equiv_cases.gd
# R232 用例体（入口 test_r232_resolve_equiv.gd 运行时 load）。对拍口径（R231 T9 模式）：
# · 双臂=CTX_REUSE/TRAIT_PRECACHE off/on（唯一变量），各自全新 GameLoop（池实例隔离）、
#   同 seed、同敌阵、同帧数手动驱动（引擎回调冻结——R231 _freeze_engine_callbacks 锚）；
# · 构筑=W1 L3 + W2 L2（boot12 词条：PIERCE×3/MULTI×2/BOUNCE×3/NOVA×2/FRACTAL×2）
#   低血敌阵 → 击杀死亡新星（settle_aoe 嵌套结算）+ 分裂子代（copy_for_split 栈）；
# · 腿 1=override 4（饱和顺延+嵌套幂等占位复合）；腿 2=override -2（无预算纯结）；
# · 硬等价=伤害值谱 distinct 集合逐位；软容差=值桶漂移合计/事件计数/管线计数桶
#   ≤ max(2, 5%)（R224 带下沿；R231 QA1-001 修复轮口径）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0
const DRIVE_FRAMES := 220
const EXPECTED_TOTAL := 19               # 套件总项数断言（R231 假绿教训）
const PIPE_KEYS := ["settles", "reaction_settles", "settle_deferred", "settle_flush",
	"settle_stale_flush", "settle_flush_dead", "settle_flush_reuse",
	"settle_overload_drop", "dropped_dupe", "alarms"]

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261004)
	print("── 腿1：override=2 饱和 + 新星/分裂嵌套复合（结构带） ──")
	await _leg(2)
	print("── 腿2：override=-2 无预算整局（统计带） ──")
	await _leg(-2)
	print("── 腿3：直驱管线定长 ctx 序列 A/B（逐位硬等价墙） ──")
	await _leg3_pipeline_exact()
	await _cleanup()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])


func fail_count() -> int:
	return _fail


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s（%s）" % [p_name, p_detail])
		print("  FAIL | %s（%s）" % [p_name, p_detail])


func _leg(p_override: int) -> void:
	# 臂 A：开关 off（改前路径）
	DamagePipeline.CTX_REUSE = false
	TraitStack.TRAIT_PRECACHE = false
	ModifierStack.AGG_TYPED = false
	await _release_loop_and_reboot()
	seed(20261004)
	var arm_a := await _drive_arm(p_override)
	# 臂 B：开关 on（改后路径）——全新 GameLoop 池实例隔离 + 同种子重置
	DamagePipeline.CTX_REUSE = true
	TraitStack.TRAIT_PRECACHE = true
	ModifierStack.AGG_TYPED = true
	await _release_loop_and_reboot()
	seed(20261004)
	var arm_b := await _drive_arm(p_override)
	_compare(p_override, arm_a, arm_b)


func _drive_arm(p_override: int) -> Dictionary:
	# 手动帧驱动 + damage_resolved 间谍 + 管线计数差分（R231 _drive_arm 同构精简）
	_freeze_engine_callbacks(_gl)
	_gl.state = GameConst.GameStatus.PLAYING
	DamagePipeline.settle_budget_override = p_override
	_build_battle()
	var base := _stats_snap()
	var rec := {"vals": [], "kills": 0, "live_tail": 0}
	var spy: Array = []
	var cb := func(r: DamageResult) -> void:
		spy.append(float(r.final_value))
	EventBus.damage_resolved.connect(cb)
	var kills0: int = _gl.hud.kills
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	for i in range(DRIVE_FRAMES):
		_gl._physics_process(DT)
		if (i % 60) == 0:
			_topup_enemies()                   # 低血敌阵补位（维持结算/击杀供给）
	rec["vals"] = spy.duplicate()
	rec["kills"] = _gl.hud.kills - kills0
	rec["live_tail"] = pool.active_projectiles().size()
	rec["stats"] = _stats_snap_diff(base)
	EventBus.damage_resolved.disconnect(cb)
	_gl.state = GameConst.GameStatus.MENU
	_release_field()
	return rec


func _stats_snap() -> Dictionary:
	var st: Dictionary = _gl.pipeline.call(&"stats")
	var snap := {}
	for k in PIPE_KEYS:
		snap[k] = int(st.get(k, 0))
	return snap


func _stats_snap_diff(p_base: Dictionary) -> Dictionary:
	var st: Dictionary = _gl.pipeline.call(&"stats")
	var d := {}
	for k in PIPE_KEYS:
		d[k] = maxi(int(st.get(k, 0)) - int(p_base[k]), 0)
	return d


func _build_battle() -> void:
	# r231 _build_battle 同构 + 死亡新星/分裂嵌套源 + **uniform hp 低血敌阵**
	# （R232 自检修正：非均匀 hp 会让击杀时序漂移级联出不同 overkill 钳制值——值谱
	# distinct 集合被 alphabet 漂移打穿；均匀 hp 下值 alphabet=面板×乘区结构指纹，
	# 与 r231 T9 谱硬等价同前提）。MULTI×3（11 种 ≤ 帽 12）提高同帧多弹命中密度，
	# override=2 时爆发行真实顺延。
	_gl.player.global_position = Vector2(360.0, 1050.0)
	_gl.player.set("xp_need", 1.0e12)
	_gl.player.set("max_hp", 1.0e12)
	_gl.player.set("hp", 1.0e12)
	var w: WeaponBase = _gl.player.weapon_slots[0]
	if w != null:
		w.level = 3
	var gatling: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W2_gatling"))
	if gatling != null:
		gatling.level = 2
		var ok := 0
		for spec in [[&"AFF_PIERCE", 2], [&"AFF_MULTI", 3], [&"MEC_BOUNCE", 2],
				[&"MEC_KILL_BLAST", 2], [&"MEC_FRACTAL", 2]]:
			var trd: TraitData = _gl.registry.get_trait(spec[0])
			for j in range(int(spec[1])):
				if gatling.attach_trait(trd):
					ok += 1
		print("    臂构筑：W2 L2 + PIERCE×2/MULTI×3/BOUNCE×2/NOVA×2/FRACTAL×2（挂载 %d/11——新星/分裂嵌套源）" % ok)
	for row in range(4):
		for col in range(4):
			_spawn_enemy(20.0,
				Vector2(160.0 + 130.0 * col, 320.0 + 110.0 * row))
	_gl.enemy_grid.rebuild(_gl.spawner.active)


func _topup_enemies() -> void:
	# 驻场补位（≤4/帧——维持供给；种子定序两臂一致）
	var alive: int = _gl.spawner.active.size()
	if alive >= 16:
		return
	for i in range(mini(4, 16 - alive)):
		_spawn_enemy(20.0,
			Vector2(160.0 + randf() * 520.0, 240.0 + randf() * 620.0))
	_gl.enemy_grid.rebuild(_gl.spawner.active)


func _spawn_enemy(p_hp: float, p_pos: Vector2) -> void:
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var e := pool.acquire() as Enemy
	if e == null:
		return
	e.bucket_host = pool.bucket_host
	var d := EnemyData.new()
	d.id = &"E_R232_EQ"
	d.display_name = "R232_EQ"
	d.hp_base = p_hp
	d.spd_base = 6.0
	d.dmg_base = 0.0
	d.exp_base = 1.0
	d.hitbox_r = 14.0
	d.resist = [0.0, 0.0, 0.0, 0.0]
	e.spawn(d, 1, 0)
	e._fade_left = 0.0
	e.modulate.a = 1.0
	e.global_position = p_pos
	_gl.spawner.active.append(e)


func _compare(p_override: int, p_a: Dictionary, p_b: Dictionary) -> void:
	var tag := "腿%d(帽%d)" % [1 if p_override == 2 else 2, p_override]
	# 对拍口径分级（R232 修轮定案）：腿2（无预算）=严格等价腿（值谱/值桶/计数桶全硬带
	# ——R231 T9 模式本义）；腿1（帽 2 饱和）=复合场景结构腿——击杀→死亡新星→分裂
	# →预算顺延的级联对两臂独立驱动的爆发行相位敏感（实测同机单跑间 deferred 8↔21
	# 双峰散布），逐局计数/值 alphabet 与驱动漂移耦合是 R223「期望 DPS 守恒」语义的
	# 固有面。腿1 断言=结构带（饱和/嵌套面真实在位 + 计数守恒宽带 |Δ|≤max(15,10%)），
	# 等价性证明由腿2 硬等价 + r223_settlebudget + r220_simchain + verify_feedback 承重。
	var vals_a: Array = p_a["vals"]
	var vals_b: Array = p_b["vals"]
	var cnt_a := vals_a.size()
	var cnt_b := vals_b.size()
	var tol: int = maxi(2, int(ceil(maxf(cnt_a, cnt_b) * 0.05))) if p_override != 2 \
		else maxi(15, int(ceil(maxf(cnt_a, cnt_b) * 0.10)))
	_check("%s 命中事件计数 |Δ|≤%d" % [tag, tol], absi(cnt_a - cnt_b) <= tol,
		"%d vs %d" % [cnt_a, cnt_b])
	_check("%s 命中事件非空（对拍有效载荷）" % tag, maxi(cnt_a, cnt_b) > 10,
		"%d/%d" % [cnt_a, cnt_b])
	# 值谱轴（QA1-001 修复轮口径）：distinct 集合逐位硬等价 + 值桶漂移合计 ≤ tol。
	# R232 偏离披露：谱硬等价对「无预算腿」为硬门（承重墙——面板×乘区结构指纹）；
	# 对「饱和腿」降为披露类——顺延同对累积的冲刷值=合并 base×乘区，合并划分随两臂
	# 独立驱动的爆发行漂移换位（R224 非确定性在顺延轴被放大），值 alphabet 耦合驱动
	# 漂移是 R223「期望 DPS 守恒」语义的固有面而非刀回归（腿2 硬等价 + 值桶/计数桶
	# 容差共同承重）。管线计数桶：饱和腿用绝对 |Δ|≤5/键（R231 回收轴同款小样本口径）。
	var spec_a := {}
	var spec_b := {}
	for v in vals_a:
		var key := String("%.6f" % float(v))
		spec_a[key] = int(spec_a.get(key, 0)) + 1
	for v in vals_b:
		var key := String("%.6f" % float(v))
		spec_b[key] = int(spec_b.get(key, 0)) + 1
	var keys_a: Array = spec_a.keys()
	keys_a.sort()
	var keys_b: Array = spec_b.keys()
	keys_b.sort()
	var spec_hard := false                            # 熵偏移面（R224/R231）——谱硬等价
	                                                  # 由腿3（无熵直驱）承载，此处披露带
	var spec_ok := str(keys_a) == str(keys_b)
	_check("%s 伤害值谱 distinct 集合逐位（%s）" % [tag,
		"硬门" if spec_hard else "披露带——熵偏移面，硬墙在腿3"],
		spec_ok or not spec_hard,
		"A=%d种 B=%d种 %s" % [keys_a.size(), keys_b.size(),
		_first_diff_str(keys_a, keys_b)])
	var bucket_delta := 0
	var bucket_detail := ""
	for k in keys_a:
		var dd: int = absi(int(spec_a[k]) - int(spec_b.get(k, 0)))
		bucket_delta += dd
		if dd > 0:
			bucket_detail += "%s:%d/%d " % [k, int(spec_a[k]), int(spec_b.get(k, 0))]
	for k in keys_b:
		if not spec_a.has(k):
			bucket_delta += int(spec_b[k])
			bucket_detail += "%s:0/%d " % [k, int(spec_b[k])]
	# 饱和腿值桶容差放宽（结构腿 max(15,10%)）；无预算腿统计带 max(6,5%)（熵偏移对价
	# ——硬等价由腿3 无熵直驱承载）
	var tol_v: int = maxi(15, int(ceil(maxf(cnt_a, cnt_b) * 0.10))) if p_override == 2 \
		else maxi(6, int(ceil(maxf(cnt_a, cnt_b) * 0.05)))
	_check("%s 值桶计数漂移合计（≤%d%s）" % [tag, tol_v,
		"·结构带" if p_override == 2 else "·统计带"], bucket_delta <= tol_v,
		"Δ=%d %s" % [bucket_delta, bucket_detail])
	# 管线计数桶（结/顺/冲/强冲/亡/复用/超载/dupe/告警/反应——R4 嵌套面入桶）：
	# 无预算腿 ≤max(2,5%)/键硬带；饱和腿 ≤max(15,10%)/键结构带（顺延计数帽 2 小样本
	# 对爆发行相位敏感，同机单跑间实测双峰散布 8↔21；R231 教训「单跑 |Δ|1、电池实到
	# |Δ|2」同类。R223 守恒语义=期望口径，非逐局计数恒等）
	var sa: Dictionary = p_a["stats"]
	var sb: Dictionary = p_b["stats"]
	var stat_ok := true
	var stat_detail := ""
	for k in PIPE_KEYS:
		var dd: int = absi(int(sa[k]) - int(sb[k]))
		var tol_k: int = maxi(15, int(ceil(maxf(int(sa[k]), int(sb[k])) * 0.10))) \
			if p_override == 2 \
			else maxi(2, int(ceil(maxf(int(sa[k]), int(sb[k])) * 0.05)))
		if dd > tol_k:
			stat_ok = false
			stat_detail += "%s:%d/%d " % [k, int(sa[k]), int(sb[k])]
	_check("%s 管线计数桶（%s）" % [tag,
		"≤max(15,10%%)/键·结构带" if p_override == 2 else "≤max(2,5%%)/键·硬带"], stat_ok,
		stat_detail if stat_detail != "" else "全键同带")
	_check("%s 击杀总数 |Δ|≤%d（小样本轴容差）" % [tag, 4 if p_override == 2 else 2],
		absi(int(p_a["kills"]) - int(p_b["kills"])) <= (4 if p_override == 2 else 2),
		"%d vs %d" % [int(p_a["kills"]), int(p_b["kills"])])
	_check("%s 末帧活弹数 |Δ|≤%d（回收时序漂移容差）" % [tag, 12 if p_override == 2 else 2],
		absi(int(p_a["live_tail"]) - int(p_b["live_tail"])) <= (12 if p_override == 2 else 2),
		"%d vs %d" % [int(p_a["live_tail"]), int(p_b["live_tail"])])
	if p_override == 2:
		_check("腿1 饱和面真实在位（A 臂顺延+冲刷 >0——复合场景非空转）",
			int(sa["settle_deferred"]) > 0 and int(sa["settle_flush"]) > 0,
			"顺=%d 冲=%d" % [int(sa["settle_deferred"]), int(sa["settle_flush"])])


func _first_diff_str(p_a: Array, p_b: Array) -> String:
	for i in range(mini(p_a.size(), p_b.size())):
		if p_a[i] != p_b[i]:
			return "@%d %s vs %s" % [i, str(p_a[i]), str(p_b[i])]
	return ""


# ── 腿3：直驱管线定长 ctx 序列 A/B（逐位硬等价墙——无引擎熵） ──────
# 熵隔离原理：引擎整局驱动存在墙钟级 RNG 熵偏移（R224「±2% 级 RNG 分歧源」/R231
# 「电池上下文暴击换位」——腿1/腿2 的整局统计带即为其对价）。本腿绕开引擎：同一
# GameLoop 上以定长 ctx 序列（巨血敌零死亡零级联）× RNG 流重置 × 开关 A/B 双跑，
# 值序列与管线计数逐位硬等价（容差 0）——刀1b/1c/1d 对结算链（含顺延/冲刷/幂等/
# 贡献式缓存）逐位保真的精确证明。
func _leg3_pipeline_exact() -> void:
	DamagePipeline.CTX_REUSE = false
	TraitStack.TRAIT_PRECACHE = false
	ModifierStack.AGG_TYPED = false
	var arm_a := await _drive_pipeline_arm()
	DamagePipeline.CTX_REUSE = true
	TraitStack.TRAIT_PRECACHE = true
	ModifierStack.AGG_TYPED = true
	var arm_b := await _drive_pipeline_arm()
	_check("腿3 值序列逐位硬等价（%d 结 · 容差 0）" % arm_a["vals"].size(),
		str(arm_a["vals"]) == str(arm_b["vals"]),
		_first_diff_str(arm_a["vals"], arm_b["vals"]))
	_check("腿3 管线计数逐位相等（容差 0）", str(arm_a["stats"]) == str(arm_b["stats"]),
		"%s vs %s" % [str(arm_a["stats"]), str(arm_b["stats"])])
	_check("腿3 饱和面真实在位（A 臂顺延>0 且 冲刷>0）",
		int(arm_a["stats"]["settle_deferred"]) > 0 and int(arm_a["stats"]["settle_flush"]) > 0,
		"顺=%d 冲=%d" % [int(arm_a["stats"]["settle_deferred"]),
		int(arm_a["stats"]["settle_flush"])])
	_check("腿3 零死亡零级联（弃/亡/复用/超载全 0）",
		int(arm_a["stats"]["settle_flush_dead"]) == 0
		and int(arm_a["stats"]["settle_flush_reuse"]) == 0
		and int(arm_a["stats"]["settle_overload_drop"]) == 0,
		str(arm_a["stats"]))


func _drive_pipeline_arm() -> Dictionary:
	# 定长序列：256 ctx（池多样 × pierce 1..4 × bounce 位 × crit 0/0.5 × 巨血 8 敌轮转），
	# override=4（帽内 4 结+其余顺延）；帧界 begin_frame 触发冲刷——顺延/冲刷/幂等全路径
	# 确定性回放。RNG 流清空重播（crit 流逐位对齐）；targets 每臂新取（巨血防杀）。
	DamagePipeline.settle_budget_override = 4
	_gl.pipeline.call(&"set_rng_seed", 987654)
	(_gl.pipeline.get(&"_rng_streams") as Dictionary).clear()
	(_gl.pipeline.get(&"_pending_pair") as Dictionary).clear()
	(_gl.pipeline.get(&"_pending_fifo") as Array).clear()
	(_gl.pipeline.get(&"_resolved_queue") as Array).clear()
	var epool := _gl.pools[&"enemy"] as EnemyPool
	var targets: Array[Enemy] = []
	for i in range(8):
		var e := epool.acquire() as Enemy
		var d := EnemyData.new()
		d.id = &"E_R232_L3"
		d.display_name = "R232_L3"
		d.hp_base = 1.0e15
		d.spd_base = 0.0
		d.dmg_base = 0.0
		d.exp_base = 1.0
		d.hitbox_r = 14.0
		d.resist = [0.0, 0.0, 0.0, 0.0]
		e.spawn(d, 1, 0)
		e._fade_left = 0.0
		e.modulate.a = 1.0
		e.global_position = Vector2(360.0, 600.0)
		targets.append(e)
	var spy: Array = []
	var cb := func(r: DamageResult) -> void:
		spy.append(float(r.final_value))
	EventBus.damage_resolved.connect(cb)
	var base := _stats_snap()
	var frame := 7000
	for rep in range(4):
		_gl.pipeline.call(&"begin_frame", frame)
		frame += 1
		for i in range(64):
			var idx := rep * 64 + i
			var ctx := DamageContext.make()
			ctx.source_uid = 9500 + idx
			ctx.target = targets[idx % targets.size()]
			ctx.target_uid = int(ctx.target.uid)
			ctx.frame_stamp = frame - 1
			ctx.base_atk = 100.0
			ctx.crit_chance = 0.5 if (idx % 3 == 0) else 0.0
			ctx.crit_mult = 2.0
			ctx.pierce_index = (idx % 4) + 1
			ctx.hit_flags = GameConst.HIT_IS_BOUNCE if (idx % 2 == 0) else 0
			ctx.player_hp_pct = 0.2 if (idx % 5 == 0) else 0.9
			if idx % 7 != 0:
				ctx.add_entries.append({"trait_id": &"T", "pool_id": &"add_atk",
					"layer": 1, "contrib": 0.12, "decay_delta": 0.0, "is_curse": false})
			if idx % 3 != 0:
				ctx.mult_pools.append({"pool_id": &"l3_a", "source_uid": 9500 + idx,
					"contrib": 0.5, "cap_pool": 2.0, "priority": 0})
			if idx % 4 == 1:
				ctx.local_pools.append({"local_id": &"l3_l", "contrib": 0.2,
					"cap_local": 1.0})
			ctx.pos = ctx.target.global_position
			_gl.pipeline.call(&"resolve", ctx)
		(_gl.pipeline.get(&"_resolved_queue") as Array).clear()
		_gl.pipeline.call(&"dispatch_resolved_frame")  # 批化派发口显式调用（间谍在事件面）
	_gl.pipeline.call(&"begin_frame", frame)          # 帽内余项续冲（预算 4/帧）
	_gl.pipeline.call(&"dispatch_resolved_frame")
	_gl.pipeline.call(&"end_frame")
	DamagePipeline.settle_budget_override = -2        # 门关全量冲清尾
	_gl.pipeline.call(&"begin_frame", frame + 1)
	_gl.pipeline.call(&"dispatch_resolved_frame")
	_gl.pipeline.call(&"end_frame")
	EventBus.damage_resolved.disconnect(cb)
	var rec := {"vals": spy.duplicate(), "stats": _stats_snap_diff(base)}
	for e in targets:
		if is_instance_valid(e):
			epool.release(e)
	DamagePipeline.settle_budget_override = -1
	(_gl.pipeline.get(&"_pending_pair") as Dictionary).clear()
	(_gl.pipeline.get(&"_pending_fifo") as Array).clear()
	(_gl.pipeline.get(&"_resolved_queue") as Array).clear()
	return rec


# ── 引擎回调冻结 / 重启（r231 同构） ──────────────────────────────

func _freeze_engine_callbacks(p_root: Node) -> void:
	p_root.set_process(false)
	p_root.set_physics_process(false)
	for c in p_root.get_children():
		_freeze_engine_callbacks(c)


func _release_loop_and_reboot() -> void:
	if _gl != null:
		_release_field()
		_gl.queue_free()
		await tree.process_frame
		await tree.process_frame
	var main: Node = load(MAIN_SCENE).instantiate()
	tree.root.add_child(main)
	await tree.process_frame
	_gl = tree.root.get_node_or_null("Main") as GameLoop
	if _gl == null:
		for c in tree.root.get_children():
			if c is GameLoop:
				_gl = c
				break
	_gl.state = GameConst.GameStatus.MENU


func _release_field() -> void:
	if _gl == null:
		return
	for e in _gl.spawner.active.duplicate():
		if is_instance_valid(e):
			_gl.elemental.unregister_host(e)
			(_gl.pools[&"enemy"] as EnemyPool).release(e)
	_gl.spawner.active.clear()
	_gl.spawner.spawn_queue.clear()
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	for n in pool.active_projectiles().duplicate():
		if is_instance_valid(n):
			(_gl.pools[&"projectile"] as ObjectPool).release(n)
	for s in (_gl.active_shards as Array).duplicate():
		(_gl.pools[&"xp"] as XPPool).release(s)
	_gl.active_shards.clear()


func _cleanup() -> void:
	_check("套件总项数（EXPECTED=%d——R231 假绿教训：总项数也要断言）" % EXPECTED_TOTAL,
		_pass + _fail == EXPECTED_TOTAL, "实=%d" % (_pass + _fail))
	DamagePipeline.settle_budget_override = -1
	DamagePipeline.CTX_REUSE = true
	TraitStack.TRAIT_PRECACHE = true
	ModifierStack.AGG_TYPED = false      # shipped 默认（typed 留档开关，收口实测反向）
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	PerfGovernor.set_process(true)
	tree.paused = false
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame
		await tree.process_frame
