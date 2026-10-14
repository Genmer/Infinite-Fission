# tests/probe_r244_physattr_cases.gd（R244 churn 臂归因用例体——入口运行时加载）
# 复现口径（probe_r237_physattr_cases 同构，差异仅臂表——如实登记，判读须与本节对照）：
# · 构成/定标/调速器冻结/引擎自然驱动/60Hz 探针频率/物步µs 公式/CAL0：全部照抄 R237
#   run5 定标（敌血×1.0、敌 120 常驻、W2 L5 五词条、风筝补位）——本探针只换臂表，
#   保证与 R237 A0 基线可比。
# · 五臂：A0 基线深载（=R237 A0 同构复跑，当前代码基线）/ B popup 摘除（探针侧断连
#   EventBus.damage_resolved ↔ popup_manager.on_damage_resolved——跳字池零 spawn 零 tick
#   churn；HUD 侧 damage_resolved 消费不受扰）/ C 碎片链摘除（探针侧断连
#   EventBus.enemy_killed ↔ game_loop._on_enemy_killed_drop_xp——XP 碎片池零 spawn 零磁吸
#   零吸收；语义无损=探针局 xp_need 1e12 本就不开卡；spawner 池归还/遗物链不受扰）
#   / D 桶place 摘除（全池 bucket_host 置空——实体不做 reparent 落桶/归位，桶合批退化
#   为池根平铺）/ A0b 序效应复跑（B/C/D 注入复原后再跑 A0——漂移带披露）。
#   披露：DeathPop/PoisonSplash 无「零发射」产品旗（deathpop_cap_override -2=用户否决
#   【帽】→全放行，1=强开帽→仍 ≤10 并发+抢占）——死亡演出件churn无法归零隔离，
#   其残差份额计入全臂共同基底，属本探针盲区（后续批次若加产品旗可补臂）。
# · 判读（R237 规则照抄）：resid_alt 降幅 <30% = 未命中（噪声带，臂间窗漂移 ±15% 实证）；
#   ≥30% 塌缩 = 该 churn 源确证为残差主 contributor。桌面绝对值≠真机——只归因不外推。
# · 注入有效性门（每注入臂硬门）：B 臂 popups_p50==0（跳字活口零=断连生效）；
#   C 臂 active_shards 窗内恒空（碎片链断连生效）；D 臂首敌 parent==敌池根（place 零调用）。
# 纪律：只读不改游戏代码（三注入全探针侧，臂末复原——popup 重连/revert -1/桶 host 回填）；
#   禁 user:// 真档写（APPDATA 沙箱 + Meta.begin_persist_defer 双保险）；无 test_ 前缀不入电池。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const GROVE_TABLE := "res://resources/maps/wave_table_grove.tres"
const HOLD_DEFAULT := 120                  # 驻场敌数（R237 run5 同款）
const PROBE_PHYS_HZ := 60                  # 探针侧物理频率注入（R237 run1 120Hz 崩 8fps 实证）
const TOPUP_PER_FRAME := 8                 # SPAWN_PER_FRAME 同款补位节流
const WARMUP_STEPS := 1200                 # 20s@60Hz：spin_up 2s + BOUNCE 10s 寿命地板弹股稳态
const WARMUP_MAX_S := 30.0
const MEASURE_MIN_WALL_S := 40.0           # 任务下限①：≥40s
const MEASURE_MIN_STEPS := 1200            # 任务下限②：≥1200 物理步
const MEASURE_MAX_WALL_S := 75.0           # 防拖挂帽
const MEASURE_MAX_STEPS := 6000
# 运行时副本（smoke 档缩短窗——const 不可重赋，_run_arm 读 *_B 变量）
var WARMUP_STEPS_B := WARMUP_STEPS
var MEASURE_MIN_WALL_S_B := MEASURE_MIN_WALL_S
var MEASURE_MIN_STEPS_B := MEASURE_MIN_STEPS
const PLAYER_HOME := Vector2(360.0, 900.0)
const ENEMY_HP_SCALE := 1.0                # R237 run5 定标（敌 120 常驻硬前提）
const SANDBOX_MARKER := ".qa_sandbox_r244"
const OUT_JSON := "res://docs/qa/probe_r244_physattr.json"
const CAL0_BURN_US := 2000                 # CAL0 每物理步忙等 µs（目标 ~2ms）
const CAL0_FRAME_MS := 50.0                # CAL0 渲染帧忙等到 ~50ms → ~3 步/帧@60Hz（歧义分离带）
const CAL0_FRAMES := 90                    # CAL0 采样帧数（≈4.5s）

var tree: SceneTree
var _gl: GameLoop = null
var _fails: int = 0
var _comp: Array[Dictionary] = []          # 平铺构成池 {data: EnemyData, tags: int}
var _cursor: int = 0
var _is_headless: bool = false
var _smoke: bool = false                   # -- --smoke：管线烟测（缩短窗，不落 JSON）
var _phys_hz_project := 120                # 工程默认物理频率（注入前快照——teardown 还原）
var _phys_hz := 120
var _cal0: Dictionary = {}                 # CAL0 语义标定读数
var _arm_results: Dictionary = {}          # key -> 结果（入 JSON）
var _gate_results: Dictionary = {}         # 门读数（入 JSON）
# 注入态（B/C/D）——臂末复原
var _popup_off: bool = false               # B：damage_resolved ↔ popup_manager 断连闩
var _shards_off: bool = false              # C：enemy_killed ↔ drop_xp 断连闩
var _bucket_hosts_saved: Dictionary = {}   # D：pool_id -> 原 bucket_host（回填用）
var _inject_effect: Dictionary = {}        # 注入有效性采样（臂内首末各一次）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	_is_headless = DisplayServer.get_name() == "headless"
	_smoke = OS.get_cmdline_user_args().has("--smoke")
	_phys_hz_project = Engine.physics_ticks_per_second
	Engine.physics_ticks_per_second = PROBE_PHYS_HZ      # 探针侧 60Hz（R237 头注实证）
	_phys_hz = PROBE_PHYS_HZ
	seed(20261006)
	if _smoke:
		# 烟测档：窗长缩短（暖 100 步 / 测 ≥3s 且 ≥200 步）——只验管线不采数
		WARMUP_STEPS_B = 100
		MEASURE_MIN_WALL_S_B = 3.0
		MEASURE_MIN_STEPS_B = 200
	print("══ R244 churn 臂归因：A0 / B popup / C shards / D bucket / A0b（%s 档%s）══"
		% ["headless 降级" if _is_headless else "窗口 gl_compatibility",
			" · smoke" if _smoke else ""])
	if not _is_headless and not _sandbox_check():
		_teardown_static()
		return
	_cal0 = await _arm_cal0()
	if not _boot():
		_teardown()
		return
	# 五臂顺序：A0 → B → D → A0b → C（C=末位终臂）；臂间清场+复原+复热
	#（_run_arm 含 await=协程——必须逐臂 await，否则五臂并发交错共毁夹具态）
	# ★C 臂（碎片链断连）不复原：enemy_killed 订阅序契约（drop_xp 必须先于 spawner
	#   归还清零——_boot_build_actors ★ 注释）决定断连后重连只能排队尾=读已清零 data
	#   报错（smoke 实证）；故 C 排末位且保持断连到 teardown（GL 直接拆，零后续战斗帧）。
	await _run_arm("A0", "基线深载（=R237 A0 同构复跑，当前代码基线）", HOLD_DEFAULT, &"")
	await _run_arm("B", "popup 摘除（damage_resolved↔popup_manager 断连——跳字零 spawn 零 tick）", HOLD_DEFAULT, &"popup")
	await _run_arm("D", "桶place 摘除（全池 bucket_host 置空——零 reparent churn）", HOLD_DEFAULT, &"bucket")
	await _run_arm("A0b", "序效应复跑（B/D 注入复原后再跑 A0——漂移带披露）", HOLD_DEFAULT, &"")
	await _run_arm("C", "碎片链摘除（enemy_killed↔drop_xp 断连——XP 池零 spawn 零磁吸；末位终臂不复原）", HOLD_DEFAULT, &"shards")
	_derive()
	if not _smoke:
		_store_json()
	await _teardown()


func fail_count() -> int:
	return _fails


# ── CAL0：TIME_PHYSICS_PROCESS 语义标定（R237 同款逐式复刻）────────

func _arm_cal0() -> Dictionary:
	print("── CAL0 监视器语义标定（无 GameLoop 净环境：步忙等 %dµs × 帧压 %dms）──"
		% [CAL0_BURN_US, int(CAL0_FRAME_MS)])
	var box: Dictionary = {"last_us": 0}
	var burn := func() -> void:
		# physics_frame 信号在 SceneTree::physics_process 首行发出——必在引擎物理块
		#（monitor 量程）内；忙等 CAL0_BURN_US 每物理步一次
		var t0 := Time.get_ticks_usec()
		while Time.get_ticks_usec() - t0 < CAL0_BURN_US:
			pass
		box["last_us"] = Time.get_ticks_usec() - t0
	tree.physics_frame.connect(burn)
	var steps_arr: Array[int] = []
	var mon_arr: Array[int] = []
	var last_us_arr: Array[int] = []
	var last_pf := -1
	for i in range(CAL0_FRAMES):
		var ft0 := Time.get_ticks_usec()
		while Time.get_ticks_usec() - ft0 < int(CAL0_FRAME_MS * 1000.0):
			pass                                 # 渲染帧压到 ~20fps → ~3 步/帧@60Hz
		await tree.process_frame
		var pf := Engine.get_physics_frames()
		var steps := 1 if last_pf < 0 else maxi(pf - last_pf, 0)
		last_pf = pf
		steps_arr.append(steps)
		mon_arr.append(int(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000000.0))
		last_us_arr.append(int(box["last_us"]))
	tree.physics_frame.disconnect(burn)
	var steps_mean := _mean_i(steps_arr)
	var mon_mean := _mean_i(mon_arr)
	var stepus_mean := _mean_i(last_us_arr)
	var ratio := mon_mean / float(maxi(stepus_mean, 1))
	var verdict := "frame-sum" if ratio > steps_mean * 0.6 else ("last-step" if ratio < 1.6 else "ambiguous")
	var out := {
		"frames": CAL0_FRAMES, "steps_per_frame_mean": steps_mean,
		"monitor_us_mean": mon_mean, "burn_us_measured_mean": stepus_mean,
		"monitor_div_burn": ratio, "verdict": verdict,
	}
	print("CAL0：步/帧=%.2f monitor=%dµs 步耗时=%dµs monitor/步耗时=%.2f → 语义=%s"
		% [steps_mean, mon_mean, stepus_mean, ratio, verdict])
	_gate("CAL0 监视器语义可判（frame-sum / last-step 二选一）",
		verdict == "frame-sum" or verdict == "last-step",
		"ratio=%.2f（歧义窗 1.6~%.1f）" % [ratio, steps_mean * 0.6])
	return out


# ── 引导（probe_r237_physattr_cases._boot 同构）──────────────────────

func _boot() -> bool:
	Meta.begin_persist_defer()               # 全程挂起 Meta 落盘（_save 短路——零真档写）
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "ProbeR244Physattr"
	tree.root.add_child(_gl)
	if not (_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU):
		push_error("[probe] Boot 失败：%s" % str(_gl.boot_fatal))
		_fails += 1
		return false
	# ★引擎自然驱动物理：不 set_physics_process(false)、不手动 _physics_process
	PerfGovernor.set_process(false)
	PerfGovernor.mode_override = 0
	PerfGovernor.tier_override = 2
	DamagePipeline.settle_budget_override = -3
	_gl.current_map_id = &"world_grove"
	if not _gl.start_run():
		push_error("[probe] start_run 失败")
		_fails += 1
		return false
	_gl.player.set("xp_need", 1.0e12)       # 30s+ 窗不开选卡（成本归「开」键不在本口径）
	_gl.player.set("max_hp", 1.0e12)
	_gl.player.set("hp", 1.0e12)
	_gl.player.unlocked_slots = 6
	_gl.player.global_position = PLAYER_HOME
	var gatling: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W2_gatling"))
	if gatling == null:
		push_error("[probe] W2 加特林装配失败")
		_fails += 1
		return false
	gatling.level = 5
	var ok_counts := {"PIERCE": 0, "MULTI": 0, "BOUNCE": 0, "NOVA": 0, "FRACTAL": 0}
	for pair in [["PIERCE", &"AFF_PIERCE", 3], ["MULTI", &"AFF_MULTI", 2],
			["BOUNCE", &"MEC_BOUNCE", 3], ["NOVA", &"MEC_KILL_BLAST", 2],
			["FRACTAL", &"MEC_FRACTAL", 2]]:
		var td: TraitData = _gl.registry.get_trait(pair[1])
		for i in range(int(pair[2])):
			if gatling.attach_trait(td):
				ok_counts[pair[0]] = int(ok_counts[pair[0]]) + 1
	print("boot.词条：PIERCE×%d/3 MULTI×%d/2 BOUNCE×%d/3 NOVA×%d/2 FRACTAL×%d/2"
		% [ok_counts["PIERCE"], ok_counts["MULTI"], ok_counts["BOUNCE"],
			ok_counts["NOVA"], ok_counts["FRACTAL"]])
	if _gl.player.mirror_count() != 0:
		push_error("[probe] 镜面数 %d ≠ 0（夹具异常）" % _gl.player.mirror_count())
		_fails += 1
		return false
	_gl.stage_probe_enabled = true
	if not _load_composition():
		return false
	print("boot：grove w16 构成 %d 敌种池（%s）压血×%.2f；物理引擎自然驱动 %dHz；构筑=W2 L5 五词条（无棱镜）+ 风筝"
		% [_comp.size(), _comp_summary(), ENEMY_HP_SCALE, _phys_hz])
	return true


func _sandbox_check() -> bool:
	var udir := OS.get_user_data_dir()
	var ok: bool = udir.contains(SANDBOX_MARKER)
	_gate("G-沙箱 user:// 重定向生效（含 %s）" % SANDBOX_MARKER, ok,
		"user_dir=%s%s" % [udir, "" if ok else " ←未重定向！窗口跑必须 APPDATA 指向仓内沙箱，中止防真档污染"])
	return ok


func _load_composition() -> bool:
	var tbl: Resource = load(GROVE_TABLE)
	if tbl == null or not ("entries" in tbl):
		push_error("[probe] 波表加载失败：%s" % GROVE_TABLE)
		_fails += 1
		return false
	var entry: Resource = null
	for e in tbl.get("entries"):
		if int(e.get("index")) == 16:
			entry = e
			break
	if entry == null:
		push_error("[probe] grove 波表无 index==16 条目")
		_fails += 1
		return false
	for c in entry.get("composition"):
		var src: EnemyData = _gl.registry.get_enemy(StringName(c.get("enemy_id")))
		if src == null:
			push_error("[probe] 敌数据缺失：%s" % str(c.get("enemy_id")))
			_fails += 1
			return false
		var data: EnemyData = src.duplicate()   # 压血复本（探针持有，注册表真件不动）
		data.hp_base = data.hp_base * ENEMY_HP_SCALE
		var tags := int(c.get("tags", 0))
		for i in range(int(c.get("count", 1))):
			_comp.append({"data": data, "tags": tags})
	_comp.shuffle()
	return true


func _comp_summary() -> String:
	var counts: Dictionary = {}
	for c in _comp:
		var id := String((c["data"] as EnemyData).id)
		counts[id] = int(counts.get(id, 0)) + 1
	var parts: Array[String] = []
	for id in counts:
		parts.append("%s×%d" % [id, int(counts[id])])
	return " ".join(parts)


# ── 驻场补位/风筝（R237 同款）──────────────────────────────────────

func _kite() -> void:
	var ang := float(_gl.frame_stamp) * 0.35 / float(_phys_hz)
	_gl.player.global_position = Vector2(360.0 + cos(ang) * 140.0,
		660.0 + sin(ang) * 200.0)


func _spawn_one() -> void:
	var c: Dictionary = _comp[_cursor % _comp.size()]
	_cursor += 1
	var e := (_gl.pools[&"enemy"] as EnemyPool).acquire() as Enemy
	if e == null:
		return
	e.bucket_host = (_gl.pools[&"enemy"] as EnemyPool).bucket_host
	e.spawn(c["data"], 16, int(c["tags"]))
	e.global_position = Vector2(randf() * 680.0 + 20.0, randf() * 1180.0 + 40.0)
	_gl.spawner.active.append(e)


func _topup(p_hold: int) -> void:
	var alive: int = _gl.spawner.active.size()
	var want: int = mini(TOPUP_PER_FRAME, p_hold - alive)
	for i in range(want):
		_spawn_one()


# ── 臂注入（B/C/D——探针侧，臂末复原）───────────────────────────────

func _inject_apply(p_inject: StringName) -> void:
	match p_inject:
		&"popup":
			# B：断连跳字 spawn（HUD 侧 damage_resolved 消费不受扰）；重连在复原
			EventBus.damage_resolved.disconnect(_gl.popup_manager.on_damage_resolved)
			_popup_off = true
		&"shards":
			# C：断连碎片掉落（spawner 池归还/遗物链不受扰——各自独立订阅）
			EventBus.enemy_killed.disconnect(_gl._on_enemy_killed_drop_xp)
			_shards_off = true
		&"bucket":
			# D：全池桶 host 置空（place/unplace 双侧守卫均 null 短路——零 reparent）；
			# 已在场敌的实体引用一并清（churn 期新敌经 _spawn_one 拿到的即 null）
			for pid in _gl.pools:
				var pool: Object = _gl.pools[pid]
				var host: Object = pool.get("bucket_host")
				if host != null:
					_bucket_hosts_saved[String(pid)] = host
					pool.set("bucket_host", null)
			for e in _gl.spawner.active:
				(e as Enemy).bucket_host = null
		_:
			pass


func _inject_restore(p_inject: StringName) -> void:
	match p_inject:
		&"popup":
			if _popup_off:
				EventBus.damage_resolved.connect(_gl.popup_manager.on_damage_resolved)
				_popup_off = false
		&"shards":
			# C=末位终臂：不重连（订阅序契约见 run() 头注——重连排队尾读已清零 data
			# 必报错；断连保持到 teardown 拆 GL）
			pass
		&"bucket":
			for pid in _bucket_hosts_saved:
				if _gl.pools.has(StringName(pid)):
					(_gl.pools[StringName(pid)] as Object).set("bucket_host", _bucket_hosts_saved[pid])
			_bucket_hosts_saved.clear()
			# 在场敌实体引用回填（池侧 host 已回；churn 新敌经 _spawn_one 自取）
			var ehost: Object = (_gl.pools[&"enemy"] as EnemyPool).get("bucket_host")
			for e in _gl.spawner.active:
				(e as Enemy).bucket_host = ehost
		_:
			pass


func _inject_effect_check(p_inject: StringName) -> Dictionary:
	# 注入有效性采样（臂内调用；硬门判据数据源）
	var out: Dictionary = {}
	match p_inject:
		&"popup":
			var d := _gl.diag_counts()
			out["popups"] = int(d.get(&"popups", 0))
		&"shards":
			out["active_shards"] = (_gl.get("active_shards") as Array).size()
		&"bucket":
			var pool: Object = _gl.pools[&"enemy"]
			var first_parent: Node = null
			if not _gl.spawner.active.is_empty():
				first_parent = (_gl.spawner.active[0] as Node).get_parent()
			out["pool_host_null"] = pool.get("bucket_host") == null
			out["first_enemy_parent_is_pool"] = first_parent == (pool as Node)
	return out


# ── 采样累计器（debug_stats.gd _diag_accumulate_window 逐式复刻——R237 同款）──

class Acc:
	# Σmon：物理活跃渲染帧上 TIME_PHYSICS_PROCESS 读数 µs 累计（帧间不复位判重——
	#   debug_stats 同口径）；Σseg：同帧段和（十六段去三子集键+派µs，含「他」键）×步数；
	#   resid_alt：未乘步数不钳负逐帧序列（多步帧 ×steps 近似的对侧读数）
	# 注：R244 起 probe 字典另含 &"entry" 键（帧入口 glue）——本类段和口径维持 R237
	#   十六段键表不变（entry 不入 Σseg ⇒ 留在 resid 内，与 R237 历史读数可比）
	const DIAG_KEYS: Array[StringName] = [
		&"player", &"player_mv", &"player_wp", &"shard", &"grid_rebuild", &"grid_projectile",
		&"enemy", &"wave", &"feel_shard", &"feel", &"fx", &"popup", &"ui",
		&"card_open", &"card_drain", &"other",
	]
	const DIAG_SUBSET_KEYS: Array[StringName] = [&"player_mv", &"player_wp", &"popup"]

	var mon_us: int = 0
	var seg_us: int = 0
	var samples: int = 0
	var steps: int = 0
	var resid_alt: Array[float] = []
	var resid_raw: Array[float] = []      # mon − seg×steps（钳负前逐帧——钳负占比判读键）
	var _last_pf: int = -1

	func sample_frame(p_gl: Node) -> void:
		var pf := Engine.get_physics_frames()
		if pf == _last_pf:
			return
		var n_steps := 1 if _last_pf < 0 else int(pf - _last_pf)
		_last_pf = pf
		var probe_raw: Variant = p_gl.get("stage_probe_us")
		if not (probe_raw is Dictionary):
			return                         # 无段帧不采样（debug_stats 同口径）
		var probe: Dictionary = probe_raw
		var m := int(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000000.0)
		var g := int(probe.get(&"dispatch", 0))
		for key in DIAG_KEYS:
			if not DIAG_SUBSET_KEYS.has(key):
				g += int(probe.get(key, 0))
		mon_us += m
		seg_us += g * n_steps
		samples += 1
		steps += n_steps
		resid_alt.append(float(m - g))
		resid_raw.append(float(m - g * n_steps))


# ── 五臂驱动（R237 _run_arm 同构——注入参数化）───────────────────────

func _run_arm(p_key: String, p_label: String, p_hold: int, p_inject: StringName) -> void:
	print("── %s %s ──" % [p_key, p_label])
	_clear_field()
	_cursor = 0
	_inject_apply(p_inject)
	for i in range(p_hold):
		_spawn_one()
	# 预热：≥WARMUP_STEPS_B 物理步（20s@60Hz——BOUNCE 10s 寿命地板弹股稳态；帽 WARMUP_MAX_S 墙钟）
	var pf0 := Engine.get_physics_frames()
	var wt0 := Time.get_ticks_msec()
	while Engine.get_physics_frames() - pf0 < WARMUP_STEPS_B \
			and Time.get_ticks_msec() - wt0 < int(WARMUP_MAX_S * 1000.0):
		_kite()
		_topup(p_hold)
		await tree.process_frame
	# 测量：≥40s 且 ≥1200 步（双下限；帽 75s/6000 步）——smoke 档窗长见 *_B 副本
	var acc := Acc.new()
	var fps_arr: Array[float] = []
	var enemies_arr: Array[int] = []
	var proj_arr: Array[int] = []
	var popup_arr: Array[int] = []
	var m_pf0 := Engine.get_physics_frames()
	var m_wt0 := Time.get_ticks_msec()
	var sec_last_ms := m_wt0
	_take_load_sample(fps_arr, enemies_arr, proj_arr, popup_arr)   # 窗口首样必采
	var effect_mid: Dictionary = _inject_effect_check(p_inject)
	while true:
		_kite()
		_topup(p_hold)
		acc.sample_frame(_gl)
		await tree.process_frame
		var now_ms := Time.get_ticks_msec()
		if now_ms - sec_last_ms >= 1000:                    # 墙钟 ~1s 节流（fps 无关）
			sec_last_ms = now_ms
			_take_load_sample(fps_arr, enemies_arr, proj_arr, popup_arr)
		var wall_s := (Time.get_ticks_msec() - m_wt0) / 1000.0
		var steps_done := Engine.get_physics_frames() - m_pf0
		if (wall_s >= MEASURE_MIN_WALL_S_B and steps_done >= MEASURE_MIN_STEPS_B) \
				or wall_s >= MEASURE_MAX_WALL_S or steps_done >= MEASURE_MAX_STEPS:
			break
	_take_load_sample(fps_arr, enemies_arr, proj_arr, popup_arr)   # 窗口末样必采
	var effect_end: Dictionary = _inject_effect_check(p_inject)
	var wall_s := (Time.get_ticks_msec() - m_wt0) / 1000.0
	var steps_done := Engine.get_physics_frames() - m_pf0
	# 段末帧快照（µs 逐键——JSON 键 seg_last_frame_us 如名：末帧直读非均值，
	# 臂间段漂移对账用；均值口径见 mon/seg_us_per_step）
	var seg_means: Dictionary = {}
	if acc.samples > 0:
		var probe: Dictionary = _gl.get("stage_probe_us")
		for key in Acc.DIAG_KEYS:
			seg_means[String(key)] = float(int(probe.get(key, 0)))
	var res := {
		"label": p_label, "hold": p_hold, "inject": String(p_inject),
		"wall_s": wall_s, "steps": steps_done, "samples": acc.samples,
		"steps_per_active_frame": float(acc.steps) / float(maxi(acc.samples, 1)),
		"mon_us_per_step": float(acc.mon_us) / float(maxi(acc.steps, 1)),
		"seg_us_per_step": float(acc.seg_us) / float(maxi(acc.steps, 1)),
		"phys_step_us_per_active_frame": float(maxi(acc.mon_us - acc.seg_us, 0))
			/ float(maxi(acc.samples, 1)),          # ← 物步µs（debug_stats 同式：×steps 减项、钳负）
		"resid_alt_us_per_active_frame": _mean_f(acc.resid_alt),
		"resid_alt_p50": _pct_f(_sorted_f(acc.resid_alt), 0.50),
		"resid_alt_p95": _pct_f(_sorted_f(acc.resid_alt), 0.95),
		"resid_raw_clamped_frac": _clamped_frac(acc.resid_raw),
		"seg_last_frame_us": seg_means,
		"fps_mean": _mean_f(fps_arr),
		"enemies_p50": _pct_i(_sorted_i(enemies_arr), 0.50),
		"projectiles_p50": _pct_i(_sorted_i(proj_arr), 0.50),
		"popups_p50": _pct_i(_sorted_i(popup_arr), 0.50),
		"effect_mid": effect_mid, "effect_end": effect_end,
	}
	_arm_results[p_key] = res
	print("读数：物步µs/活跃帧=%.1f｜resid_alt=%.1f（p95=%.1f，钳负帧占%.0f%%）｜mon=%.1fµs/步 段和=%.1fµs/步｜步/帧=%.2f 样本=%d 步=%d 墙=%.1fs"
		% [res["phys_step_us_per_active_frame"], res["resid_alt_us_per_active_frame"],
			res["resid_alt_p95"], float(res["resid_raw_clamped_frac"]) * 100.0,
			res["mon_us_per_step"], res["seg_us_per_step"], res["steps_per_active_frame"],
			acc.samples, steps_done, wall_s])
	print("负载：敌 p50=%d 弹 p50=%d 跳 p50=%d fps=%.0f"
		% [res["enemies_p50"], res["projectiles_p50"], res["popups_p50"], res["fps_mean"]])
	_gate("G-%s 采样成立（活跃帧>0 且 步≥%d 且 墙≥%.0fs×0.9）" % [p_key, MEASURE_MIN_STEPS_B, MEASURE_MIN_WALL_S_B],
		acc.samples > 0 and steps_done >= MEASURE_MIN_STEPS_B
			and wall_s >= MEASURE_MIN_WALL_S_B * 0.9,
		"样本=%d 步=%d 墙=%.1fs（帽 %.0fs/%d 步内收口）"
			% [acc.samples, steps_done, wall_s, MEASURE_MAX_WALL_S, MEASURE_MAX_STEPS])
	_gate_disclosed("G-%s 负载带披露（敌 p50≥hold-8 且 弹 p50≥60——R224 带 [60,350]）" % p_key,
		res["enemies_p50"] >= p_hold - 8 and res["projectiles_p50"] >= 60,
		"敌=%d/%d 弹=%d 跳=%d" % [res["enemies_p50"], p_hold, res["projectiles_p50"], res["popups_p50"]])
	# 注入有效性门（硬门——防「注入未生效假阴性归因」）
	if p_inject == &"popup":
		_gate("G-%s popup 注入生效（测量窗 跳 p50==0）" % p_key,
			res["popups_p50"] == 0, "跳=%d" % res["popups_p50"])
	elif p_inject == &"shards":
		_gate("G-%s shards 注入生效（测量窗 碎片活口恒 0）" % p_key,
			int(effect_mid.get("active_shards", -1)) == 0
				and int(effect_end.get("active_shards", -1)) == 0,
			"mid=%s end=%s" % [str(effect_mid.get("active_shards")), str(effect_end.get("active_shards"))])
	elif p_inject == &"bucket":
		_gate("G-%s bucket 注入生效（池 host null + 首敌挂池根）" % p_key,
			bool(effect_end.get("pool_host_null", false))
				and bool(effect_end.get("first_enemy_parent_is_pool", false)),
			"host_null=%s parent_is_pool=%s" % [str(effect_end.get("pool_host_null")),
				str(effect_end.get("first_enemy_parent_is_pool"))])
	_inject_restore(p_inject)
	await tree.process_frame                 # 注入复原落地（popup 重连/哨兵还原）后进下一臂


func _take_load_sample(p_fps: Array[float], p_en: Array[int], p_proj: Array[int],
		p_pop: Array[int]) -> void:
	# 负载快照（墙钟 ~1s 节流 + 窗口首末必采——帧计数节流在低 fps 窗会零采样）
	var d := _gl.diag_counts()
	p_fps.append(float(Engine.get_frames_per_second()))
	p_en.append(int(d.get(&"enemies", 0)))
	p_proj.append(int(d.get(&"projectiles", 0)))
	p_pop.append(int(d.get(&"popups", 0)))


# ── 判读派生（R237 规则：<30% 未命中 / ≥30% 塌缩确证）────────────────

func _derive() -> void:
	if not (_arm_results.has("A0") and _arm_results.has("B")
			and _arm_results.has("C") and _arm_results.has("D")):
		return
	var a0: Dictionary = _arm_results["A0"]
	var d := {}
	for arm_key in ["B", "C", "D"]:
		var arm: Dictionary = _arm_results[arm_key]
		d["alt_drop_%s_pct" % arm_key] = _drop_pct(a0, arm, "resid_alt_us_per_active_frame")
		d["wu_drop_%s_pct" % arm_key] = _drop_pct(a0, arm, "phys_step_us_per_active_frame")
		d["mon_drop_%s_pct" % arm_key] = _drop_pct(a0, arm, "mon_us_per_step")
		d["gain_alt_%s" % arm_key] = float(a0["resid_alt_us_per_active_frame"]) \
			- float(arm["resid_alt_us_per_active_frame"])
	if _arm_results.has("A0b"):
		d["a0b_drift_alt_pct"] = _drop_pct(a0, _arm_results["A0b"], "resid_alt_us_per_active_frame")
	_arm_results["derive"] = d
	var drift_line := ""
	if d.has("a0b_drift_alt_pct"):
		drift_line = "｜A0b 序漂移=%.0f%%" % float(d["a0b_drift_alt_pct"])
	print("── 派生（R237 规则：降幅<30%% 未命中 / ≥30%% 塌缩确证）：resid_alt 降幅 B(popup)=%.0f%% C(shards)=%.0f%% D(bucket)=%.0f%%｜mon 降幅 B=%.0f%% C=%.0f%% D=%.0f%%%s"
		% [d["alt_drop_B_pct"], d["alt_drop_C_pct"], d["alt_drop_D_pct"],
			d["mon_drop_B_pct"], d["mon_drop_C_pct"], d["mon_drop_D_pct"], drift_line])


func _drop_pct(p_base: Dictionary, p_arm: Dictionary, p_key: String) -> float:
	var b := float(p_base[p_key])
	if b <= 0.0:
		return 0.0
	return clampf((b - float(p_arm[p_key])) / b * 100.0, -100.0, 100.0)


# ── JSON 留档（性能结论唯一依据）─────────────────────────────────────

func _store_json() -> void:
	var rmethod := str(ProjectSettings.get_setting_with_override(
		&"rendering/renderer/rendering_method"))
	var args := OS.get_cmdline_args()
	for i in range(args.size() - 1):
		if String(args[i]) == "--rendering-method":
			rmethod = String(args[i + 1])
	var root: Dictionary = {
		"meta": {
			"date": "2026-10-08", "package": "desktop-window-probe（归因对象=vc53 真机深载 物步µs 22-45ms 纯引擎侧残差——R237 修账后读数）",
			"rendering_project_setting": rmethod,
			"adapter_api": RenderingServer.get_video_adapter_api_version(),
			"headless": _is_headless,
			"physics_hz_project": _phys_hz_project,
			"physics_hz_probe": PROBE_PHYS_HZ,
			"user_dir": OS.get_user_data_dir(), "physics_hz": _phys_hz,
			"hold": HOLD_DEFAULT, "hp_scale": ENEMY_HP_SCALE,
			"build": "W2_gatling L5 + AFF_PIERCE×3/AFF_MULTI×2/MEC_BOUNCE×3/MEC_KILL_BLAST×2/MEC_FRACTAL×2（R224/R237 同款，无棱镜/无敌弹注入）",
			"governor": "frozen, mode=frame_priority, tier_override=2, settle_budget=-3",
			"drive": "引擎自然驱动物理（60Hz 探针注入）+ 夹具每渲染帧 风筝/补位/臂注入",
			"measure": {"min_wall_s": MEASURE_MIN_WALL_S, "min_steps": MEASURE_MIN_STEPS,
				"max_wall_s": MEASURE_MAX_WALL_S, "max_steps": MEASURE_MAX_STEPS,
				"warmup_steps": WARMUP_STEPS},
			"formula": "物步µs = max(ΣTIME_PHYSICS_PROCESS − Σ(段和×步数),0)/活跃帧（R237 同式；Acc 段和口径=十六段不含 entry——与 R237 历史可比，entry 留在 resid 内）；resid_alt=未乘步数不钳负对侧口径",
			"cal0": _cal0,
			"note": "桌面绝对值≠真机——只做归因（churn 源确证），不做收益外推；判读规则 <30%=未命中（噪声带 ±15%）/≥30%=塌缩确证",
		},
		"arms": _arm_results.duplicate(true),
		"gates": _gate_results.duplicate(true),
	}
	var f := FileAccess.open(OUT_JSON, FileAccess.WRITE)
	if f == null:
		push_error("[probe] JSON 写入失败：%s" % OUT_JSON)
		_fails += 1
		return
	f.store_string(JSON.stringify(root, "\t"))
	f.close()
	print("留档：%s" % OUT_JSON)


func _gate(p_label: String, p_ok: bool, p_detail: String) -> void:
	if p_ok:
		print("  PASS | %s（%s）" % [p_label, p_detail])
	else:
		print("  FAIL | %s（%s）" % [p_label, p_detail])
		_fails += 1
	_gate_results[p_label] = {"ok": p_ok, "detail": p_detail}


func _gate_disclosed(p_label: String, p_ok: bool, p_detail: String) -> void:
	# 披露类门：如实记 FAIL* 但不阻塞退出码（负载带漂移已声明，归因用途不受影响）
	if p_ok:
		print("  PASS | %s（%s）" % [p_label, p_detail])
	else:
		print("  FAIL* | %s（%s）——披露类失配：不阻塞（口径见用例体头注）" % [p_label, p_detail])
	_gate_results[p_label] = {"ok": p_ok, "detail": p_detail, "disclosed": true}


# ── 清场/收尾（R237 同款）──────────────────────────────────────────

func _clear_field() -> void:
	for e in _gl.spawner.active.duplicate():
		_gl.elemental.unregister_host(e)
		(_gl.pools[&"enemy"] as EnemyPool).release(e)
	_gl.spawner.active.clear()
	_gl.spawner.spawn_queue.clear()
	for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles().duplicate():
		(_gl.pools[&"projectile"] as ObjectPool).release(p)
	for s in (_gl.active_shards as Array).duplicate():
		(_gl.pools[&"xp"] as XPPool).release(s)
	_gl.active_shards.clear()


func _teardown() -> void:
	DamagePipeline.settle_budget_override = -1
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	PerfGovernor.set_process(true)
	Engine.physics_ticks_per_second = _phys_hz_project   # 还原工程默认频率
	if _popup_off:
		# 防御：异常路径漏复原（正常臂末已断连闩 false）
		EventBus.damage_resolved.connect(_gl.popup_manager.on_damage_resolved)
		_popup_off = false
	# shards 断连不复原（末位终臂——订阅序契约，见 run() 头注；GL 随即拆除）
	if not _bucket_hosts_saved.is_empty():
		_inject_restore(&"bucket")
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame
		await tree.process_frame


func _teardown_static() -> void:
	# 沙箱自检失败路径（boot 未跑）：无可还原 static 口（boot 前失败）——空实现占位
	pass


# ── 统计工具（R237 同款）────────────────────────────────────────────

func _mean_i(p_arr: Array[int]) -> int:
	if p_arr.is_empty():
		return 0
	var s := 0
	for v in p_arr:
		s += v
	return s / p_arr.size()


func _mean_f(p_arr: Array[float]) -> float:
	if p_arr.is_empty():
		return 0.0
	var s := 0.0
	for v in p_arr:
		s += v
	return s / float(p_arr.size())


func _sorted_i(p_arr: Array[int]) -> Array[int]:
	var s := p_arr.duplicate()
	s.sort()
	return s


func _sorted_f(p_arr: Array[float]) -> Array[float]:
	var s := p_arr.duplicate()
	s.sort()
	return s


func _pct_i(p_sorted: Array[int], p_pct: float) -> int:
	if p_sorted.is_empty():
		return 0
	return p_sorted[clampi(int(float(p_sorted.size()) * p_pct), 0, p_sorted.size() - 1)]


func _pct_f(p_sorted: Array[float], p_pct: float) -> float:
	if p_sorted.is_empty():
		return 0.0
	return p_sorted[clampi(int(float(p_sorted.size()) * p_pct), 0, p_sorted.size() - 1)]


func _clamped_frac(p_resid_raw: Array[float]) -> float:
	if p_resid_raw.is_empty():
		return 0.0
	var neg := 0
	for v in p_resid_raw:
		if v < 0.0:
			neg += 1
	return float(neg) / float(p_resid_raw.size())
