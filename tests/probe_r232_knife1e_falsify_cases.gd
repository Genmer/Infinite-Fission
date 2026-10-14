# tests/probe_r232_knife1e_falsify_cases.gd（刀1e 证伪测量用例体——入口运行时加载）
# 协议（评审#2 定案「配对各一轮」的加严实现）：双序平衡 dict→typed→typed→dict，
# 每臂两读数（序漂移对消）各取中位；批 48/96/192（r225 MICRO 同构），批间 begin_frame
# 清幂等缓存（窗外），_resolved_queue 批间清队，巨血真敌轮转（零死亡零级联）。
# 证伪判读写死：typed_us_median ≥ dict_us_median → FALSIFIED（shipped=false 维持）；
# 否则 NOT_REPRODUCED（如实记录，供开关复评）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const OUT_JSON := "res://docs/qa/probe_r232_knife1e_falsified_2026-10-05.json"
const BATCHES := [48, 96, 192]
const MICRO_ENEMIES := 48
const MICRO_BASE_ATK := 100.0
const ARMS := 2                        # 双序 × 两臂 = 4 次测量（平衡顺序漂移）

var tree: SceneTree
var _gl: GameLoop = null
var _targets: Array[Enemy] = []


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261005)
	print("══ R232 刀1e 证伪配对：AGG_TYPED false(字典)/true(typed) 双序各一轮 ══")
	if not _boot():
		_teardown()
		return
	PerfGovernor.set_process(false)
	_gl.state = GameConst.GameStatus.MENU
	DamagePipeline.settle_budget_override = -2
	var dict_readings: Array[float] = []
	var typed_readings: Array[float] = []
	var order_log: Array[String] = []
	for arm in range(ARMS * 2):
		var typed := (arm % 2 == 1) if ARMS == 2 else false
		# 双序平衡：arm0=dict, arm1=typed, arm2=typed, arm3=dict（round 2 反序）
		typed = (arm == 1 or arm == 2)
		ModifierStack.AGG_TYPED = typed
		var us := _arm_once(arm)
		if typed:
			typed_readings.append(us)
		else:
			dict_readings.append(us)
		order_log.append("arm%d=%s(%.1fµs)" % [arm, "typed" if typed else "dict", us])
	var dict_us := _median(dict_readings)
	var typed_us := _median(typed_readings)
	var falsified := typed_us >= dict_us
	var verdict := "FALSIFIED（typed ≥ dict——刀1e 证伪成立，shipped=false 维持）" \
		if falsified else "NOT_REPRODUCED（typed < dict——本轮未复现反向，如实记录供复评）"
	print("证伪配对回执：%s | %s" % [" ".join(order_log), verdict])
	print("  dict 中位=%.1fµs/结（读数 %s）| typed 中位=%.1fµs/结（读数 %s）| Δ=%+.1fµs（%+.1f%%）"
		% [dict_us, _fmt(dict_readings), typed_us, _fmt(typed_readings),
		typed_us - dict_us, (typed_us - dict_us) / dict_us * 100.0 if dict_us > 0.0 else 0.0])
	_store_json(dict_readings, typed_readings, dict_us, typed_us, falsified, order_log)
	_teardown()


func _boot() -> bool:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "ProbeR232Knife1eFalsify"
	tree.root.add_child(_gl)
	if not (_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU):
		push_error("[probe] Boot 失败：%s" % str(_gl.boot_fatal))
		return false
	PerfGovernor.mode_override = 0
	PerfGovernor.tier_override = 2
	_gl.current_map_id = &"world_grove"
	if not _gl.start_run():
		push_error("[probe] start_run 失败")
		return false
	_gl.state = GameConst.GameStatus.MENU
	var epool := _gl.pools[&"enemy"] as EnemyPool
	for i in range(MICRO_ENEMIES):
		var e := epool.acquire() as Enemy
		if e == null:
			continue
		var d := EnemyData.new()
		d.id = &"E_R232_FALSIFY"
		d.display_name = "R232_FALSIFY"
		d.hp_base = 1.0e15
		d.spd_base = 0.0
		d.dmg_base = 0.0
		d.exp_base = 1.0
		d.hitbox_r = 14.0
		d.resist = [0.0, 0.0, 0.0, 0.0]
		e.spawn(d, 16, 0)
		e.global_position = Vector2(360.0, 660.0)
		_targets.append(e)
	print("boot.目标池：%d 巨血真敌（零死亡零级联）" % _targets.size())
	return not _targets.is_empty()


func _arm_once(p_arm: int) -> float:
	# MICRO 同构合成结算：三批各测 µs/结，读数=三批中位（r225 探针同式）
	var frame_no := 880000 + p_arm * 1000
	var batch_us := {}
	for n in BATCHES:
		var batch := int(n)
		var ctxs: Array[DamageContext] = []
		for i in range(batch):
			ctxs.append(_micro_ctx(970000 + p_arm * 1000 + i,
				_targets[i % _targets.size()], frame_no))
		_gl.pipeline.call(&"begin_frame", frame_no)
		frame_no += 1
		var t0 := Time.get_ticks_usec()
		for ctx in ctxs:
			_gl.pipeline.call(&"resolve", ctx)
		batch_us[batch] = float(Time.get_ticks_usec() - t0) / float(batch)
		(_gl.pipeline.get(&"_resolved_queue") as Array).clear()
	return _median_of3(float(batch_us[48]), float(batch_us[96]), float(batch_us[192]))


func _micro_ctx(p_source: int, p_target: Enemy, p_frame: int) -> DamageContext:
	# r225 MICRO 同值合成 ctx（代表负载披露：base100+1add+2mult+1local+crit0.05）
	var ctx := DamageContext.make()
	ctx.source_uid = p_source
	ctx.target_uid = p_target.uid
	ctx.target = p_target
	ctx.frame_stamp = p_frame
	ctx.base_atk = MICRO_BASE_ATK
	ctx.crit_chance = 0.05
	ctx.crit_mult = 2.0
	ctx.add_entries.append({"trait_id": &"AFF_SYN", "pool_id": &"r232_syn",
		"layer": 1, "contrib": 0.15, "decay_delta": 0.0, "is_curse": false})
	ctx.mult_pools.append({"pool_id": &"r232_f1", "source_uid": p_source,
		"contrib": 0.5, "cap_pool": 2.0, "priority": 0})
	ctx.mult_pools.append({"pool_id": &"vuln", "source_uid": 0,
		"contrib": 0.25, "cap_pool": 1.0, "priority": 0})
	ctx.local_pools.append({"local_id": &"r232_fl", "contrib": 0.2, "cap_local": 1.0})
	ctx.pos = p_target.global_position
	return ctx


func _store_json(p_dict_r: Array[float], p_typed_r: Array[float], p_dict_us: float,
		p_typed_us: float, p_falsified: bool, p_order: Array[String]) -> void:
	var root := {
		"meta": {
			"date": Time.get_date_string_from_system(),
			"package": "desktop-headless-probe（R232 刀1e 证伪配对——评审#2 修轮①落档）",
			"protocol": "AGG_TYPED false(字典)/true(typed) 双序平衡（dict→typed→typed→dict）各两读数取中位；批 48/96/192 合成结算（r225 MICRO 同值：base100+1add+2mult+1local+crit0.05）；窗外预构建零打点",
			"verdict_rule": "typed_us_median ≥ dict_us_median → FALSIFIED（shipped=false 维持）；否则 NOT_REPRODUCED",
		},
		"falsify": {
			"dict_readings": p_dict_r, "typed_readings": p_typed_r,
			"dict_us_median": p_dict_us, "typed_us_median": p_typed_us,
			"delta_us": p_typed_us - p_dict_us,
			"delta_pct": (p_typed_us - p_dict_us) / p_dict_us * 100.0 if p_dict_us > 0.0 else 0.0,
			"order_log": p_order,
			"falsified": p_falsified,
			"verdict": "FALSIFIED" if p_falsified else "NOT_REPRODUCED",
		},
		"disclosure": [
			"合成 ctx 为代表负载（≤3 池条目）——与主探针 MICRO 臂同构；FULL-M 规模（5 池）未入本配对（主探针 JSON FULL-M 臂已并记）",
			"单机单轮——绝对 µs 受机器热漂移影响，判定只对本档案内配对差；跨日复评须重跑本探针",
		],
	}
	var f := FileAccess.open(OUT_JSON, FileAccess.WRITE)
	if f == null:
		push_warning("[probe] 证伪 JSON 写入失败：%s" % OUT_JSON)
		return
	f.store_string(JSON.stringify(root, "\t"))
	f.close()
	print("证伪 JSON 已写：%s（verdict=%s）" % [OUT_JSON, "FALSIFIED" if p_falsified else "NOT_REPRODUCED"])


func _teardown() -> void:
	ModifierStack.AGG_TYPED = false       # shipped 默认还原
	DamagePipeline.settle_budget_override = -1
	var epool := _gl.pools[&"enemy"] as EnemyPool
	for e in _targets:
		if is_instance_valid(e):
			epool.release(e)
	_targets.clear()
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	PerfGovernor.set_process(true)
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame
		await tree.process_frame


func _median(p_arr: Array[float]) -> float:
	if p_arr.is_empty():
		return 0.0
	var s := p_arr.duplicate()
	s.sort()
	var mid := s.size() / 2
	if s.size() % 2 == 1:
		return s[mid]
	return (s[mid - 1] + s[mid]) / 2.0


func _median_of3(p_a: float, p_b: float, p_c: float) -> float:
	var arr: Array[float] = [p_a, p_b, p_c]
	return _median(arr)


func _fmt(p_arr: Array[float]) -> String:
	var parts: Array[String] = []
	for v in p_arr:
		parts.append("%.1f" % v)
	return "/".join(parts)
