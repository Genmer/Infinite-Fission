# tests/probe_r234_overkill_cases.gd（R234 探索：overkill 封顶 需求侧构成实证——用例体）
# 复现口径：与 probe_r224_deepload_cases.gd 逐位同构（敌120 驻场 + W2_gatling L5 五词条
# 满叠 + 种子 20261003 + 风筝轨迹 + 300 帧预热 + 1800 帧测量 @60Hz 手动驱动）。
# 本探针不改场景构建/RNG 消费序/结算口径——只加两类只读观测：
#   A. EventBus.damage_resolved 事件流（派发保序=结算序；组分析按 result.frame_stamp
#      分组——dispatch 帽 48 的跨帧派发顺延不影响归组）
#   B. 每帧初 spawner.active 的 {uid: hp} 快照（shadow 账本帧基线）
# 统计三量（任务口径）：
#   ① 一击致死率：①a 命中时点账本 hp_before ≤ 本发 final_value（本发够杀）；
#      ①b 帧初 hp ≤ 本发 final_value（含上帧残血携带）
#   ② 同帧同目标重复命中分布：(frame_stamp, target_uid) 组 size =1 / 2-4 / 5+ 占比
#   ③ 白打占比：组内首杀发（累计 final_value ≥ 帧初 hp）之后仍结算的命中（单遍状态机
#      口径：账本推死后仍提交）合计 ÷ 总命中数 =「打在将死敌身上的白打」占提交需求比例
# 口径披露（如实）：
#   · 统计对象=走到 pipeline.resolve 的提交（提交需求构成）。弹侧更早拦截（E-03 单弹
#     帧去重 / R196 生命周期去重 / dead 短路 projectile_base:703）不产生提交、不计入
#     ——与需求侧砍刀的作用面一致。
#   · S0（override=-2 预算关）为唯一出数情景：无顺延/丢弃干扰，事件=全量提交。
#     S1（-3 帽96）/S2（48）仅收饱和度三轴账作参照——顺延占位不入派发队
#     （_synthetic_deferred 无 broadcast），per-hit 流不全，①②③不出数。
#   · shadow 账本偏差源=take_result 正面盾减伤（final_value 为盾修正前值）——方向：
#     低估 hp_before（保守低估白打）；enemy_killed 对账数披露。
#   · 桌面≠真机（R224 声明）：占比类读数（①②③）为结构量，桌面可信；绝对 ms 不采。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const GROVE_TABLE := "res://resources/maps/wave_table_grove.tres"
const DT60 := 1.0 / 60.0
const HOLD := 120
const WARMUP_FRAMES := 300
const MEASURE_FRAMES := 1800
const TOPUP_PER_FRAME := 8
const PLAYER_HOME := Vector2(360.0, 900.0)
const ENEMY_HP_SCALE := 0.3
const BASELINE_JSON := "res://docs/qa/probe_r234_overkill_baseline.json"
const EV_CAP := 300000                     # 事件护栏（1800 帧 × ~150/步 上界余量）

var tree: SceneTree
var _gl: GameLoop = null
var _fails: int = 0
var _comp: Array[Dictionary] = []
var _cursor: int = 0
var _spawned_total: int = 0
var _alive_at_reset: int = 0

# ── 只读观测状态 ──────────────────────────────────────────────────
var _ev_frame: PackedInt64Array = []
var _ev_target: PackedInt64Array = []
var _ev_value: PackedFloat64Array = []
var _ev_crit: PackedByteArray = []
var _ev_killed: PackedByteArray = []
var _ev_count: int = 0
var _ev_overflow: bool = false
var _measure_last_stamp: int = -1               # 测量末帧 stamp（排空期收数上限——
                                                # 末帧事件的派发顺延跨帧仍入账，排空帧
                                                # 新结算〔清场前在途弹〕不入账）
var _measure_first_stamp: int = -1              # 测量首帧 stamp（stamp 值锚定：
                                                # 事件 stamp − 本值 = archive 下标）
var _frame_hp_archive: Array[Dictionary] = []   # 每测量帧一份 {uid: hp}（帧初快照，测量帧序）
var _kill_events: int = 0
var _events_during_measure: bool = false
var _per_sec: Array[Dictionary] = []


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261003)
	print("══ R234 overkill 封顶实证：r224 深载夹具 × damage_resolved 事件流 × 帧初 hp 快照 ══")
	if not _boot():
		_teardown()
		return
	_scenario_s0(ENEMY_HP_SCALE, "S0")
	# 敏感性角点：压血×0.15（r224 实证角点 ×0.15 需求 3100 弹499 在带内）——敌更脆
	# → 一击致死率上升 → 白打占比弹性（方案降幅的敏感性输入，非主口径）
	_scenario_s0(0.15, "S0hp015")
	_scenario_budget_ref("S1 模拟真机 tier2（override=-3，帽96@60Hz——仅饱和度参照轴）", -3)
	_scenario_budget_ref("S2 饱和复现（override=48 强制帽——仅饱和度参照轴）", 48)
	_teardown()


func fail_count() -> int:
	return _fails


# ── 引导（与 r224 逐位同构） ──────────────────────────────────────

func _boot() -> bool:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "ProbeR234Overkill"
	tree.root.add_child(_gl)
	if not (_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU):
		push_error("[probe] Boot 失败：%s" % str(_gl.boot_fatal))
		_fails += 1
		return false
	PerfGovernor.set_process(false)
	PerfGovernor.mode_override = 0
	PerfGovernor.tier_override = 2
	_gl.current_map_id = &"world_grove"
	if not _gl.start_run():
		push_error("[probe] start_run 失败")
		_fails += 1
		return false
	_gl.player.set("xp_need", 1.0e12)
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
	var pierce: TraitData = _gl.registry.get_trait(&"AFF_PIERCE")
	for i in range(3):
		gatling.attach_trait(pierce)
	var multi: TraitData = _gl.registry.get_trait(&"AFF_MULTI")
	for i in range(2):
		gatling.attach_trait(multi)
	var bounce: TraitData = _gl.registry.get_trait(&"MEC_BOUNCE")
	for i in range(3):
		gatling.attach_trait(bounce)
	var nova: TraitData = _gl.registry.get_trait(&"MEC_KILL_BLAST")
	for i in range(2):
		gatling.attach_trait(nova)
	var fractal: TraitData = _gl.registry.get_trait(&"MEC_FRACTAL")
	for i in range(2):
		gatling.attach_trait(fractal)
	if _gl.player.mirror_count() != 0:
		push_error("[probe] 镜面数 %d ≠ 0（夹具异常）" % _gl.player.mirror_count())
		_fails += 1
		return false
	_gl.stage_probe_enabled = true
	EventBus.damage_resolved.connect(_on_damage_resolved)
	EventBus.enemy_killed.connect(_on_enemy_killed)
	if not _load_composition(ENEMY_HP_SCALE):
		return false
	print("boot：r224 同款深载夹具就绪（grove w16 %d 构成 压血×%.2f；W2 L5 五词条无棱镜）"
		% [_comp.size(), ENEMY_HP_SCALE])
	return true


func _load_composition(p_scale: float) -> bool:
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
	_comp.clear()
	for c in entry.get("composition"):
		var src: EnemyData = _gl.registry.get_enemy(StringName(c.get("enemy_id")))
		if src == null:
			push_error("[probe] 敌数据缺失：%s" % str(c.get("enemy_id")))
			_fails += 1
			return false
		var data: EnemyData = src.duplicate()
		data.hp_base = data.hp_base * p_scale
		var tags := int(c.get("tags", 0))
		for i in range(int(c.get("count", 1))):
			_comp.append({"data": data, "tags": tags})
	_comp.shuffle()
	return true


# ── 观测 handler（只读，零产品码改动） ────────────────────────────

func _on_damage_resolved(p_r: DamageResult) -> void:
	if not _events_during_measure:
		return
	if _measure_last_stamp >= 0 and p_r.frame_stamp > _measure_last_stamp:
		return                            # 排空帧新结算（清场前在途弹）——测量窗外
	if _ev_count >= EV_CAP:
		if not _ev_overflow:
			_ev_overflow = true
			push_error("[probe] 事件流超护栏 %d（截断——账本口径失真）" % EV_CAP)
			_fails += 1
		return
	_ev_frame.append(p_r.frame_stamp)
	_ev_target.append(p_r.target_uid)
	_ev_value.append(p_r.final_value)
	_ev_crit.append(1 if p_r.is_crit else 0)
	_ev_killed.append(1 if p_r.killed else 0)
	_ev_count += 1


func _on_enemy_killed(_p_e: Node2D) -> void:
	if _events_during_measure:
		_kill_events += 1


func _snapshot_frame_hp() -> void:
	# 帧初快照（测量帧序 append）：本帧结算事件的 hp 基线
	var snap: Dictionary = {}
	for e in _gl.spawner.active:
		var en := e as Enemy
		if en != null and not en.dead:
			snap[en.uid] = en.hp
	_frame_hp_archive.append(snap)


# ── 驻场补位（r224 同款） ────────────────────────────────────────

func _kite(p_frame: int) -> void:
	var ang := float(p_frame) * 0.35 / 60.0
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
	_spawned_total += 1


func _topup() -> void:
	var alive: int = _gl.spawner.active.size()
	var want: int = mini(TOPUP_PER_FRAME, HOLD - alive)
	for i in range(want):
		_spawn_one()


func _kill_count() -> int:
	return _spawned_total + _alive_at_reset - _gl.spawner.active.size()


# ── S0 出数情景（预算关=提交全量可见） ────────────────────────────

var _stale_drop_base: int = 0                 # dispatch_stale_drop 对账基线（测量窗差分）

func _scenario_s0(p_scale: float, p_key: String) -> void:
	print("── %s 预算关（override=-2，压血×%.2f）：①②③ 出数情景 ──" % [p_key, p_scale])
	if p_scale != ENEMY_HP_SCALE:
		if not _load_composition(p_scale):
			return
	DamagePipeline.settle_budget_override = -2
	_reset_collectors()
	_stale_drop_base = DebugStats.get_counter(&"dispatch_stale_drop")
	for i in range(HOLD):
		_spawn_one()
	for i in range(WARMUP_FRAMES):
		_kite(i - WARMUP_FRAMES)
		_gl._physics_process(DT60)
		_topup()
	_alive_at_reset = _gl.spawner.active.size()
	_spawned_total = 0
	_kill_events = 0
	_measure_last_stamp = -1
	# 首帧锚：本帧驱动后 stamp 推进至 F0+1，帧 j 事件 stamp = F0+1+j ↔ archive[j]
	_measure_first_stamp = GameConfig.frame_stamp + 1
	_events_during_measure = true
	var frame_i := 0
	while frame_i < MEASURE_FRAMES:
		_kite(frame_i)
		_snapshot_frame_hp()
		_gl._physics_process(DT60)
		_topup()
		frame_i += 1
		if frame_i % 60 == 0:
			var d := _gl.diag_counts()
			d[&"submissions"] = int(d[&"settles"]) + int(d[&"settles_deferred"]) \
				+ int(d[&"settles_dropped"])
			_per_sec.append(d)
	_events_during_measure = false
	_measure_last_stamp = GameConfig.frame_stamp
	# 排空尾帧派发顺延（dispatch 帽 48 跨帧余量——drive 空帧直至队列清或 60 帧兜底；
	# 排空期继续收末帧 stamp 事件，排空帧新结算被 stamp 上限过滤）
	_events_during_measure = true
	for tail in range(60):
		var q: Variant = _gl.pipeline.get(&"_resolved_queue") if _gl.pipeline != null else null
		if q == null or (q as Array).is_empty():
			break
		_gl._physics_process(DT60)
	_events_during_measure = false
	var stale_dropped: int = DebugStats.get_counter(&"dispatch_stale_drop") - _stale_drop_base
	_analyze_s0(p_key, stale_dropped, p_scale)
	_clear_field()


func _reset_collectors() -> void:
	_ev_frame.clear()
	_ev_target.clear()
	_ev_value.clear()
	_ev_crit.clear()
	_ev_killed.clear()
	_ev_count = 0
	_ev_overflow = false
	_frame_hp_archive.clear()
	_per_sec.clear()
	_kill_events = 0


# ── S0 统计（①②③） ─────────────────────────────────────────────

func _analyze_s0(p_key: String, p_stale_dropped: int, p_scale: float) -> void:
	var n := _ev_count
	if n == 0:
		push_error("[probe] %s 测量窗零事件（夹具异常）" % p_key)
		_fails += 1
		return
	var diag_settles := 0
	for d in _per_sec:
		diag_settles += int(d[&"settles"])
	print("账本对账：事件数=%d｜diag 结N 和=%d｜dispatch_stale_drop=%d｜enemy_killed=%d｜补位击杀口径=%d"
		% [n, diag_settles, p_stale_dropped, _kill_events, _kill_count()])

	# 诊断：distinct stamp 数 vs archive 数 + 单调性 + untracked 归因
	# （stamp 值锚定：archive 下标 = stamp − _measure_first_stamp——distinct 序锚定
	#   曾被预热尾派发顺延跨窗错位 8 帧，run1 实锤 30% 无档，run2 起值锚定）
	var distinct := 0
	var last_s := -1
	var mono_violations := 0
	for k0 in range(n):
		var s0 := int(_ev_frame[k0])
		if s0 != last_s:
			distinct += 1
			last_s = s0
		elif s0 < last_s:
			mono_violations += 1
	print("diag.归组：distinct stamps=%d｜archive=%d｜stamp 逆序数=%d｜首 stamp=%d（锚 %d）末 stamp=%d"
		% [distinct, _frame_hp_archive.size(), mono_violations,
			int(_ev_frame[0]), _measure_first_stamp, int(_ev_frame[n - 1])])
	var untracked_before_window := 0  # stamp < 首锚（预热尾派发顺延跨窗——口径外披露）
	var untracked_after_window := 0   # stamp > 末锚（排空期边界——口径外披露）
	var untracked_missing_uid := 0    # 窗内但快照缺 uid（帧内召唤/边界更替——口径外披露）
	var k1 := 0
	while k1 < n:
		var st := int(_ev_frame[k1])
		var fe := k1
		while fe < n and int(_ev_frame[fe]) == st:
			fe += 1
		var ordn := st - _measure_first_stamp
		if ordn < 0:
			untracked_before_window += fe - k1
		elif ordn >= _frame_hp_archive.size():
			untracked_after_window += fe - k1
		else:
			var sn: Dictionary = _frame_hp_archive[ordn]
			for k2 in range(k1, fe):
				if not sn.has(int(_ev_target[k2])):
					untracked_missing_uid += 1
		k1 = fe
	print("diag.untracked 溯源：窗前=%d｜窗后=%d｜窗内缺 uid=%d"
		% [untracked_before_window, untracked_after_window, untracked_missing_uid])

	var hits_lethal_a := 0
	var hits_lethal_b := 0
	var wasted_hits := 0                     # ③：账本推死后仍提交（=组内首杀后多发）
	var wasted_final := 0.0
	var wasted_crit := 0                     # 白打命中中的暴击数（方案A 暴击合并语义输入）
	var valid_crit := 0
	var total_final := 0.0
	var total_crit := 0
	var untracked_hits := 0                  # 帧初快照无此 uid（口径外，披露）
	var group_size_hist := {"1": 0, "2_4": 0, "5plus": 0}
	var group_max := 0
	var group_count := 0
	var group_hits_total := 0
	var dead_groups := 0
	var groups_2plus := 0                    # 多发组（size≥2）组数
	var groups_per_frame := 0.0

	var i := 0
	while i < n:
		var stamp := int(_ev_frame[i])
		var frame_ord := stamp - _measure_first_stamp
		var snap: Dictionary = _frame_hp_archive[frame_ord] \
			if frame_ord >= 0 and frame_ord < _frame_hp_archive.size() else {}
		# 本帧组状态（单遍）
		var acc: Dictionary = {}              # uid -> 累计伤害
		var slain: Dictionary = {}            # uid -> true（账本已死）
		var gcount: Dictionary = {}           # uid -> 本帧命中数
		var frame_end := i
		while frame_end < n and int(_ev_frame[frame_end]) == stamp:
			frame_end += 1
		for k in range(i, frame_end):
			var uid := int(_ev_target[k])
			var val := float(_ev_value[k])
			var crit := int(_ev_crit[k]) == 1
			gcount[uid] = int(gcount.get(uid, 0)) + 1
			group_hits_total += 1
			total_final += val
			if crit:
				total_crit += 1
			if not snap.has(uid):
				untracked_hits += 1
				continue
			var hp0 := float(snap[uid])
			var a := float(acc.get(uid, 0.0))
			var hp_before := hp0 - a
			if hp_before <= val:
				hits_lethal_a += 1
			if hp0 <= val:
				hits_lethal_b += 1
			if bool(slain.get(uid, false)) or hp_before <= 0.0:
				wasted_hits += 1
				wasted_final += val
				if crit:
					wasted_crit += 1
			a += val
			acc[uid] = a
			if hp0 - a <= 0.0:
				slain[uid] = true
		for uid in gcount:
			var sz := int(gcount[uid])
			group_count += 1
			if sz == 1:
				group_size_hist["1"] = int(group_size_hist["1"]) + 1
			elif sz <= 4:
				group_size_hist["2_4"] = int(group_size_hist["2_4"]) + 1
			else:
				group_size_hist["5plus"] = int(group_size_hist["5plus"]) + 1
			if sz > group_max:
				group_max = sz
			if sz >= 2:
				groups_2plus += 1
			if bool(slain.get(uid, false)):
				dead_groups += 1
		groups_per_frame += float(gcount.size())
		i = frame_end
	valid_crit = total_crit - wasted_crit

	var frames := _frame_hp_archive.size()
	var secs := MEASURE_FRAMES / 60.0
	var pct_a := float(hits_lethal_a) / float(n) * 100.0
	var pct_b := float(hits_lethal_b) / float(n) * 100.0
	var pct_wasted := float(wasted_hits) / float(n) * 100.0
	print("① 一击致死率：①a 命中时点 hp_before≤final %.1f%%（%d/%d）｜①b 帧初 hp≤final %.1f%%（%d/%d）"
		% [pct_a, hits_lethal_a, n, pct_b, hits_lethal_b, n])
	print("② 同帧同目标组：组数=%d（%.1f/帧）｜size=1 %.1f%%｜2-4 %.1f%%｜5+ %.1f%%｜组均 %.2f 发｜max=%d｜多发组 %d"
		% [group_count, groups_per_frame / float(frames),
			float(group_size_hist["1"]) / float(group_count) * 100.0,
			float(group_size_hist["2_4"]) / float(group_count) * 100.0,
			float(group_size_hist["5plus"]) / float(group_count) * 100.0,
			float(group_hits_total) / float(maxi(group_count, 1)), group_max, groups_2plus])
	print("③ 白打占比：账本推死后仍提交 %.1f%%（%d/%d）｜白打伤害占比 %.1f%%（%.0f/%.0f）"
		% [pct_wasted, wasted_hits, n,
			wasted_final / maxf(total_final, 1.0) * 100.0, wasted_final, total_final])
	print("③e 暴击账：全事件暴击 %.1f%%｜白打中暴击 %.1f%%（合并掷骰的期望损失输入）"
		% [float(total_crit) / float(n) * 100.0,
			float(wasted_crit) / float(maxi(wasted_hits, 1)) * 100.0])
	print("需求轴：提交=%.0f/s（%.1f/步）｜击杀=%d（%.1f/s）｜发/击杀=%.1f｜口径外命中（帧初无档）=%d"
		% [float(n) / secs, float(n) / float(frames),
			_kill_events, float(_kill_events) / secs,
			float(n) / maxf(float(_kill_events), 1.0), untracked_hits])
	var proj_p50 := 0.0
	var enemy_p50 := 0.0
	if not _per_sec.is_empty():
		var pj: Array[float] = []
		var en: Array[float] = []
		for d in _per_sec:
			pj.append(float(int(d[&"projectiles"])))
			en.append(float(int(d[&"enemies"])))
		pj.sort()
		en.sort()
		proj_p50 = pj[pj.size() / 2]
		enemy_p50 = en[en.size() / 2]
	print("驻场对齐：敌 p50=%.0f｜弹 p50=%.0f（r224 基线带 敌118+/弹60-350）" % [enemy_p50, proj_p50])
	# C1 披露式：dispatch 稳态积压触发 stale 前缀丢弃（事件流少 stale 份）+ 秒拉取边界
	# ——|事件+stale−diag|≤1% 即口径内一致；超差=真丢数需回报
	var c1_diff := absi(n + p_stale_dropped - diag_settles)
	_gate_disclosed("C1 事件流对账：|事件+stale_drop−diag结N|≤1%+60",
		c1_diff <= int(float(diag_settles) * 0.01) + 60,
		"事件 %d + stale %d vs diag %d（差 %d）" % [n, p_stale_dropped, diag_settles, c1_diff])
	_gate("C2 敌驻场 p50≥118", enemy_p50 >= 118.0, "%.0f" % enemy_p50)
	_gate_disclosed("C3 弹带 p50∈[60,350]", proj_p50 >= 60.0 and proj_p50 <= 350.0,
		"%.0f（超上沿 %.0f%%——r224 满配实测弹 370-391 同带）"
		% [proj_p50, maxf(0.0, proj_p50 - 350.0) / 350.0 * 100.0])
	_store_baseline(p_key, p_scale, n, diag_settles, p_stale_dropped, hits_lethal_a,
		hits_lethal_b, wasted_hits, wasted_final, total_final, wasted_crit, total_crit,
		group_count, group_size_hist, groups_per_frame / float(frames), group_hits_total,
		dead_groups, group_max, groups_2plus, enemy_p50, proj_p50, untracked_hits,
		untracked_before_window, untracked_after_window, untracked_missing_uid)


# ── 参照情景（预算态饱和度账，不出①②③） ──────────────────────────

func _scenario_budget_ref(p_label: String, p_override: int) -> void:
	print("── %s ──" % p_label)
	DamagePipeline.settle_budget_override = p_override
	_reset_collectors()
	_events_during_measure = false
	for i in range(HOLD):
		_spawn_one()
	for i in range(WARMUP_FRAMES):
		_kite(i - WARMUP_FRAMES)
		_gl._physics_process(DT60)
		_topup()
	_alive_at_reset = _gl.spawner.active.size()
	_spawned_total = 0
	_per_sec.clear()
	var frame_i := 0
	while frame_i < MEASURE_FRAMES:
		_kite(frame_i)
		_gl._physics_process(DT60)
		_topup()
		frame_i += 1
		if frame_i % 60 == 0:
			var d := _gl.diag_counts()
			d[&"submissions"] = int(d[&"settles"]) + int(d[&"settles_deferred"]) \
				+ int(d[&"settles_dropped"])
			_per_sec.append(d)
	var subs := _pct50(_sec_series(_per_sec, "submissions", true))
	var settles := _pct50(_sec_series(_per_sec, "settles", true))
	var defer := _pct50(_sec_series(_per_sec, "settles_deferred", true))
	var drop := _pct50(_sec_series(_per_sec, "settles_dropped", true))
	print("饱和度参照：提交/步 p50=%.1f（%.0f/s）｜结=%.1f｜顺=%.1f｜弃=%.1f（r224 对照用）"
		% [subs, subs * 60.0, settles, defer, drop])
	_store_ref(p_label, subs, settles, defer, drop)
	_clear_field()


# ── 留档 JSON ────────────────────────────────────────────────────

func _store_baseline(p_key: String, p_scale: float, p_n: int, p_diag_settles: int,
		p_stale_dropped: int, p_lethal_a: int, p_lethal_b: int,
		p_wasted: int, p_wasted_final: float, p_total_final: float,
		p_wasted_crit: int, p_total_crit: int, p_group_count: int, p_group_hist: Dictionary,
		p_groups_per_frame: float, p_group_hits: int, p_dead_groups: int, p_group_max: int,
		p_groups_2plus: int, p_enemy_p50: float, p_proj_p50: float, p_untracked: int,
		p_pre_window: int, p_post_window: int, p_missing_uid: int) -> void:
	var root: Dictionary
	var existing_text := FileAccess.get_file_as_string(BASELINE_JSON)
	if existing_text.is_empty() or p_key == "S0":
		root = {
			"meta": {
				"date": "2026-10-06", "probe": "probe_r234_overkill",
				"package": "desktop-headless-probe（只读观测：damage_resolved 事件流 + 帧初 hp 快照）",
				"fixture": "r224 同构：grove w16 敌120 驻场 压血×0.3 主口径 + ×0.15 敏感性角点，W2_gatling L5 + PIERCE×3/MULTI×2/BOUNCE×3/KILL_BLAST×2/FRACTAL×2（无棱镜）",
				"seed": 20261003, "dt": DT60, "warmup": WARMUP_FRAMES,
				"measure_frames": MEASURE_FRAMES,
				"governor": "frozen, mode=frame_priority, tier_override=2",
				"budget": "S0* override=-2（出数情景：事件=全量提交）；S1/-3 与 S2/48 仅饱和度参照",
				"note": "占比类读数为结构量（桌面可信）；绝对 ms 不采；统计对象=走到 resolve 的提交，弹侧更早拦截（E-03/R196/dead 短路）不计需求；事件流缺口=dispatch stale 前缀丢弃（对账键 stale_drop）",
			},
		}
	else:
		var parsed = JSON.parse_string(existing_text)
		root = parsed if parsed is Dictionary else {}
	root[p_key] = {
		"hp_scale": p_scale,
		"events": p_n, "diag_settles_sum": p_diag_settles,
		"dispatch_stale_drop": p_stale_dropped,
		"kills": _kill_events,
		"hits_per_kill": float(p_n) / maxf(float(_kill_events), 1.0),
		"lethal_a": {"hits": p_lethal_a, "pct": p_lethal_a * 100.0 / float(p_n)},
		"lethal_b": {"hits": p_lethal_b, "pct": p_lethal_b * 100.0 / float(p_n)},
		"wasted": {"hits": p_wasted, "pct": p_wasted * 100.0 / float(p_n),
			"final_value": p_wasted_final,
			"damage_pct": p_wasted_final / maxf(p_total_final, 1.0) * 100.0,
			"crit_hits": p_wasted_crit},
		"total": {"final_value": p_total_final, "crit_hits": p_total_crit},
		"groups": {"count": p_group_count, "per_frame": p_groups_per_frame,
			"hist": p_group_hist.duplicate(),
			"mean_hits": float(p_group_hits) / float(maxi(p_group_count, 1)),
			"max": p_group_max, "dead_groups": p_dead_groups, "size_2plus": p_groups_2plus},
		"untracked": {"total": p_untracked, "pre_window": p_pre_window,
			"post_window": p_post_window, "missing_uid": p_missing_uid},
		"field": {"enemy_p50": p_enemy_p50, "proj_p50": p_proj_p50},
		"per_sec_tail": _per_sec.slice(maxi(0, _per_sec.size() - 10)),
	}
	var f := FileAccess.open(BASELINE_JSON, FileAccess.WRITE)
	if f == null:
		push_warning("[probe] 留档 JSON 写入失败：%s" % BASELINE_JSON)
		return
	f.store_string(JSON.stringify(root, "\t"))
	f.close()
	print("留档：%s（%s）" % [BASELINE_JSON, p_key])


var _ref_results: Dictionary = {}


func _store_ref(p_label: String, p_subs: float, p_settles: float, p_defer: float, p_drop: float) -> void:
	_ref_results[p_label.substr(0, 2) + "_ref"] = {
		"submissions_per_step_p50": p_subs, "settles_p50": p_settles,
		"deferred_p50": p_defer, "dropped_p50": p_drop,
	}
	var existing_text := FileAccess.get_file_as_string(BASELINE_JSON)
	if existing_text.is_empty():
		return
	var parsed = JSON.parse_string(existing_text)
	if parsed is Dictionary:
		(parsed as Dictionary).merge(_ref_results, true)
		var f := FileAccess.open(BASELINE_JSON, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify(parsed, "\t"))
			f.close()


# ── 清场/收尾 ────────────────────────────────────────────────────

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
	EventBus.damage_resolved.disconnect(_on_damage_resolved)
	EventBus.enemy_killed.disconnect(_on_enemy_killed)
	DamagePipeline.settle_budget_override = -1
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	PerfGovernor.set_process(true)
	if _gl != null:
		_gl.queue_free()
	await tree.process_frame
	await tree.process_frame


# ── 统计工具 ─────────────────────────────────────────────────────

func _gate(p_label: String, p_ok: bool, p_detail: String) -> void:
	if p_ok:
		print("  PASS | %s（%s）" % [p_label, p_detail])
	else:
		print("  FAIL | %s（%s）" % [p_label, p_detail])
		_fails += 1


func _gate_disclosed(p_label: String, p_ok: bool, p_detail: String) -> void:
	# 披露类门（r224 先例）：如实记 FAIL* 不阻塞退出码——口径失配已声明、不冒充通过
	if p_ok:
		print("  PASS | %s（%s）" % [p_label, p_detail])
	else:
		print("  FAIL* | %s（%s）——披露类失配：不阻塞（口径见用例体头注）" % [p_label, p_detail])


func _sec_series(p_per_sec: Array[Dictionary], p_key: String, p_per_step: bool) -> Array[float]:
	var out: Array[float] = []
	for d in p_per_sec:
		var v := float(int(d[StringName(p_key)]))
		out.append(v / 60.0 if p_per_step else v)
	out.sort()
	return out


func _pct50(p_sorted: Array[float]) -> float:
	if p_sorted.is_empty():
		return 0.0
	return p_sorted[clampi(p_sorted.size() / 2, 0, p_sorted.size() - 1)]
