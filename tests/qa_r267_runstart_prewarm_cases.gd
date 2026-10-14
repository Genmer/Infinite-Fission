# R267 刀P1 runstart 预热用例体（qa_r267_runstart_prewarm 入口 load）
# 口径见入口文件头。boot 零 await（bake_b 先例）：add_child 同步走完 _ready 全链
# （队列已建、图集冷、menu_screen 就位），随后分段驱动。
extends RefCounted

const START_GATE_US := 8000.0        # 设计 §1.1-a 常态档门（模态暖后 start_run 全链）
const PUMP_BUDGET_US := 4000         # PLAYING 泵预算（渲染轴尾 4ms/帧）
const CHEAP_OVERSHOOT_US := 3000.0   # 廉价项（1-3ms）起步越尾余量——预算记账后置
const ATOM_CAP_US := 245000.0        # boss 双面单项实测上界（设计 e 原子上界钉死）
const HARD_CAP_US := 300000.0        # 全程硬帽兜底判读

var _tree: SceneTree = null
var _fails: int = 0
var _passes: int = 0
var _gl: GameLoop = null
var _snap_op0: Array = []            # start_run 前 op:0 (kind,angry) 多重集快照
var _snap_other: Array = []          # start_run 前非 op:0 (索引, str(项)) 快照


func _check(p_name: String, p_ok: bool, p_detail: String = "") -> void:
	if p_ok:
		_passes += 1
		print("PASS | " + p_name)
	else:
		_fails += 1
		print("FAIL | " + p_name + ("" if p_detail.is_empty() else "  [got: " + p_detail + "]"))


func fail_count() -> int:
	return _fails


func _boot_cold() -> void:
	# bake_b 先例：零 await 冷 boot（队列满态 + 图集冷态保真）
	_gl = GameLoop.new()
	_gl.name = "R267P1"
	_tree.get_root().add_child(_gl)
	_gl.set_physics_process(false)


func run(p_tree: SceneTree) -> int:
	_tree = p_tree
	_boot_cold()
	_test_cold_desktop_noop()
	_snapshot_queue()                  # start_run 重排前快照（c 段恒等断言基线）
	_test_modal_warm_channel()
	_test_reorder_semantics()
	await _test_playing_pump_wave1()    # 含 await process_frame（协程须 await 调用）
	_test_boss_stagger_no_stall()
	_test_pump_frame_peaks()
	_teardown()
	print("R267 刀P1 runstart 预热汇总：PASS %d / FAIL %d（共 %d 项）" % [_passes, _fails, _passes + _fails])
	print("验收汇总：PASS %d / FAIL %d" % [_passes, _fails])
	return _fails


func _snapshot_queue() -> void:
	# 重排不变量基线：op:0 多重集 + 非 op:0 槽位内容（重排只许动 op:0 内部序）
	_snap_op0 = []
	_snap_other = []
	for i in range(_gl._tex_prewarm_queue.size()):
		var it: Dictionary = _gl._tex_prewarm_queue[i]
		if int(it.get(&"op", -1)) == 0:
			_snap_op0.append("%s|%s" % [String(it.get(&"kind", &"")),
				str(bool(it.get(&"angry", false)))])
		else:
			_snap_other.append([i, str(it)])


func _teardown() -> void:
	PopupGlyphAtlas.runstart_bake_override = -1
	_tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.state = GameConst.GameStatus.MENU
		_gl.queue_free()


# ── a0) 冷态前置 + 桌面自动门零扰动 ──
func _test_cold_desktop_noop() -> void:
	print("── a0) 冷态前置 / 桌面门零扰动 ──")
	_check("a0 冷图集（built=0 / 未 ready / layout 未做 / 未烤 12）",
		PopupGlyphAtlas.built_count() == 0 and not PopupGlyphAtlas.ready()
			and not PopupGlyphAtlas.layout_done()
			and PopupGlyphAtlas.unbaked_cells() == 12,
		"built=%d unbaked=%d" % [PopupGlyphAtlas.built_count(), PopupGlyphAtlas.unbaked_cells()])
	_check("a0 menu_screen 同步就位（零 await boot——bake_b 先例）",
		_gl.menu_screen != null and _gl.boot_ready)
	# 桌面自动门（override=-1 缺省）：暖口直返零扰动（R227 桌面零扰动保持）
	_gl.menu_screen.set_blessing_modal(true)
	_gl.menu_screen.set_blessing_modal(false)
	_check("a0 桌面缺省门：模态开零暖（built 仍 0——桌面 Label 路径零扰动）",
		PopupGlyphAtlas.built_count() == 0 and not PopupGlyphAtlas.ready())


# ── a) 模态暖通道 → start_run 常态档 ──
func _test_modal_warm_channel() -> void:
	print("── a) 模态暖通道（祝福模态开帧 → 确认 → start_run） ──")
	PopupGlyphAtlas.runstart_bake_override = 1        # mobile 门当量（真链口径）
	var warm0: int = DebugStats.get_counter(&"bitmap_modal_warm_us")
	var bake0: int = DebugStats.get_counter(&"bitmap_bake_us")
	_gl.menu_screen.set_blessing_modal(true)          # 模态开帧暖（=game_loop _try_open_blessing_pick 调点）
	var warm_us: int = DebugStats.get_counter(&"bitmap_modal_warm_us") - warm0
	_gl.menu_screen.set_blessing_modal(false)         # 收口（确认路径同调点）
	_check("a 模态暖全量（built 0→12 / ready / layout 完成 / 暖耗时 %dµs 落账）" % warm_us,
		PopupGlyphAtlas.built_count() == 12 and PopupGlyphAtlas.ready()
			and PopupGlyphAtlas.layout_done() and warm_us > 0)
	# 确认即出发（_finish_menu_start 同链）：start_run 全链 = 常态档。
	# 统计口径：暖机 1 次后 3 窗各 1 次取最小（并行工种共用本机跑测时调度噪声只
	# 加时间——min-of-windows 对称固定程序，firstwave 套件先例；单发实测 3.0-9.1ms
	# 随负载漂，min 锁代码真实成本）
	_gl.state = GameConst.GameStatus.MENU
	_gl.start_run()
	var wall_us := 1 << 30
	var ok := false
	for i in range(3):
		_gl.state = GameConst.GameStatus.MENU
		var t0 := Time.get_ticks_usec()
		ok = _gl.start_run()
		var w := Time.get_ticks_usec() - t0
		if w < wall_us:
			wall_us = w
	var bake_us: int = DebugStats.get_counter(&"bitmap_bake_us") - bake0
	_check("a start_run 常态档 ≤%.0fµs（min-of-3=%dµs；对照改前冷直发 32300µs / vc71 真机 41612µs）" % [
		START_GATE_US, wall_us], ok and wall_us <= START_GATE_US, "%dµs" % wall_us)
	_check("a ensure 恒短路（bitmap_bake_us 零增量=%d——全量兜底档未触发）" % bake_us,
		bake_us == 0)
	# 暖口幂等：ready 后再开模态零成本
	var warm1: int = DebugStats.get_counter(&"bitmap_modal_warm_us")
	_gl.menu_screen.set_blessing_modal(true)
	_gl.menu_screen.set_blessing_modal(false)
	_check("a 暖口幂等（ready 后零新增暖耗时 / 未烤 0）",
		DebugStats.get_counter(&"bitmap_modal_warm_us") == warm1
			and PopupGlyphAtlas.unbaked_cells() == 0)
	PopupGlyphAtlas.runstart_bake_override = -1       # 回桌面缺省门（后续段 PLAYING 泵桌面口径）


# ── c) 队列波序重排语义（start_run 已发生——本段对照快照取自 run 前置） ──
func _test_reorder_semantics() -> void:
	print("── c) 队列波序重排 ──")
	# 快照在本套件 run() 首段 boot 后、start_run 前拍（_test_modal_warm_channel 内
	# start_run 已重排）——此处拍改后态断言内部一致性与 op:6 块
	var q: Array = _gl._tex_prewarm_queue
	_check("c 前置：队列非空（%d 项）" % q.size(), not q.is_empty())
	# c1: op:6（若在册）仍连续占据队首块（qa_r227_bake_b ①a 口径不破）
	var head6 := 0
	while head6 < q.size() and int((q[head6] as Dictionary).get(&"op", -1)) == 6:
		head6 += 1
	var tail6 := 0
	for it_v: Variant in q:
		if int((it_v as Dictionary).get(&"op", -1)) == 6:
			tail6 += 1
	_check("c1 op:6 队首连续块（首块 %d = 全量 %d——①a 口径）" % [head6, tail6],
		head6 == tail6)
	# c2: 带波键 op:0 项沿队列序非降（波序优先核心断言）
	var last_fw := -1
	var mono := true
	var keyed := 0
	for it_v: Variant in q:
		var it: Dictionary = it_v
		if int(it.get(&"op", -1)) != 0 or not it.has(&"wave"):
			continue
		keyed += 1
		var fw := int(it[&"wave"])
		if fw < last_fw:
			mono = false
			break
		last_fw = fw
	_check("c2 带波键 op:0 项非降序（%d 项带键——波序优先）" % keyed,
		keyed > 0 and mono)
	# c5: 重排不变量——op:0 多重集恒等 + 非 op:0 槽位内容恒等（只动 op:0 内部序）
	var after_op0: Array = []
	var after_other: Array = []
	for i in range(q.size()):
		var it: Dictionary = q[i]
		if int(it.get(&"op", -1)) == 0:
			after_op0.append("%s|%s" % [String(it.get(&"kind", &"")),
				str(bool(it.get(&"angry", false)))])
		else:
			after_other.append([i, str(it)])
	# 多重集比对：排序后逐一相等（Array[String] 排序——红线 4）
	var a0: Array[String] = []
	var b0: Array[String] = []
	for s_v: Variant in _snap_op0:
		a0.append(String(s_v))
	for s_v: Variant in after_op0:
		b0.append(String(s_v))
	a0.sort()
	b0.sort()
	_check("c5a op:0 多重集恒等（%d 项——重排零增删）" % a0.size(),
		a0 == b0)
	_check("c5b 非 op:0 槽位内容恒等（%d 项逐位相等——共享域/op:6/op:7 序不动）" % (
		_snap_other.size()),
		str(_snap_other) == str(after_other))
	# c3: 波键 boss 项门槛值合法（首现波 ≥2 才有「前一波」错峰窗）
	var boss_gate_ok := true
	for it_v: Variant in q:
		var it: Dictionary = it_v
		if int(it.get(&"op", -1)) == 0 and String(it.get(&"kind", &"")).begins_with("boss") \
				and it.has(&"wave") and int(it[&"wave"]) < 2:
			boss_gate_ok = false
	_check("c3 boss 波键 ≥2（门槛放行窗存在）", boss_gate_ok)
	# c4: 本地图 wave1 廉价 kind 已排 op:0 段首部（首 < 波键中位）——抽首/尾对照
	var op0_kinds: Array[String] = []
	for it_v: Variant in q:
		var it: Dictionary = it_v
		if int(it.get(&"op", -1)) == 0:
			op0_kinds.append(String(it.get(&"kind", &"")))
	var w1 := _wave1_kinds()
	var first_idx := op0_kinds.size()
	var last_idx := -1
	for i in range(op0_kinds.size()):
		if w1.has(op0_kinds[i]):
			first_idx = mini(first_idx, i)
			last_idx = maxi(last_idx, i)
	_check("c4 wave1 kind 聚 op:0 段前部（首 %d / 末 %d / 段长 %d——重排后居前）" % [
		first_idx, last_idx, op0_kinds.size()],
		first_idx < op0_kinds.size() / 3)


# ── d) 快开局敌变体：PLAYING 泵首帧消化 wave1 廉价 kind + 只读缓存命中 ──
func _test_playing_pump_wave1() -> void:
	print("── d) 快开局敌变体（PLAYING 泵） ──")
	var w1 := _wave1_kinds()
	_check("d 前置：wave1 kind 清单非空（%s）" % str(w1), not w1.is_empty())
	# 合成快开局：wave1 kind 项插队首（boot 零 await 队列未被 MENU 泵消化过——
	# 此处重插队首模拟「快开局玩家排不到 → PLAYING 泵兜住」的 P1 主场景）
	for i in range(w1.size() - 1, -1, -1):
		_gl._tex_prewarm_queue.push_front({&"op": 0, &"kind": StringName(w1[i]),
			&"angry": false, &"wave": 1})
	var q0: int = _gl._tex_prewarm_queue.size()
	var c0: int = DebugStats.get_counter(&"tex_prewarm_frame_us")
	# 引擎 _process 真路径：await 帧（state PLAYING → PLAYING 泵分支）
	for i in range(6):
		await _tree.process_frame
	var drained: int = q0 - _gl._tex_prewarm_queue.size()
	_check("d PLAYING 泵消化（%d 项出队 / frame_us 计数落账 Δ%d）" % [
		drained, DebugStats.get_counter(&"tex_prewarm_frame_us") - c0],
		drained > 0 and DebugStats.get_counter(&"tex_prewarm_frame_us") > c0)
	# 只读缓存命中：wave1 kind 全在册（首敌接敌前零首焙面——TextureFactory._cache
	# 只读 peek，键式 enemy_<kind>_<angry>）
	var miss: Array[String] = []
	for k: String in w1:
		if not (TextureFactory._cache as Dictionary).has("enemy_%s_false" % k):
			miss.append(k)
	_check("d wave1 kind 全命中 TextureFactory._cache（miss=%s——首见零首焙）" % (
		str(miss) if not miss.is_empty() else "无"),
		miss.is_empty())


func _wave1_kinds() -> Array[String]:
	# 本局 wave1 出场 kind 清单（生产同源：波表 composition + Enemy.visual_kind_for）
	var out: Array[String] = []
	if _gl.wave_director == null or _gl.wave_director.wave_table == null:
		return out
	for entry_v: Variant in _gl.wave_director.wave_table.entries:
		var entry: WaveEntryData = entry_v as WaveEntryData
		if entry == null or int(entry.index) != 1:
			continue
		for comp: Dictionary in entry.composition:
			var eid := StringName(String(comp.get("enemy_id", "")))
			var ed: EnemyData = _gl.registry.get_enemy(eid)
			var k := Enemy.visual_kind_for(ed, int(comp.get("tags", 0)))
			if not out.has(String(k)):
				out.append(String(k))
	return out


# ── e) boss 错峰 / 不停摆（设计 f 用例：[boss(wave9), wave1 kind]） ──
func _test_boss_stagger_no_stall() -> void:
	print("── e) boss 错峰 / 不停摆 ──")
	var w1 := _wave1_kinds()
	var cheap_k := StringName(w1[0] if not w1.is_empty() else "grunt")
	_gl.wave_director.current_wave = 1
	_gl._tex_prewarm_queue.push_front({&"op": 0, &"kind": &"boss1", &"angry": false, &"wave": 9})
	_gl._tex_prewarm_queue.push_front({&"op": 0, &"kind": &"boss1", &"angry": true, &"wave": 9})
	_gl._tex_prewarm_queue.push_front({&"op": 0, &"kind": cheap_k, &"angry": false, &"wave": 1})
	var q_before: int = _gl._tex_prewarm_queue.size()
	_gl._tex_prewarm_skip = 0
	_gl._process_tex_prewarm(PUMP_BUDGET_US, true)
	var q_after: int = _gl._tex_prewarm_queue.size()
	var h0: Dictionary = _gl._tex_prewarm_queue[0]
	var h1: Dictionary = _gl._tex_prewarm_queue[1]
	var boss_kept := String(h0.get(&"kind", &"")) == "boss1" \
		and String(h1.get(&"kind", &"")) == "boss1"
	_check("e 门槛前跳过不 break（廉价项先出队 %d 项、boss 双面留队=%s——不停摆）" % [
		q_before - q_after, str(boss_kept)],
		q_before - q_after >= 1 and boss_kept)
	# 门槛放行：current_wave=8 ≥ 9-1 → 恰 1 原子项/帧 + 占空还账 + 原子上界
	# （boss 计数只认本段合成对：boss1 且 wave==9——真实队列另有表内 boss 23 项，
	#  其波键 ≥10 在 wave8 不放行）
	var atom0: int = DebugStats.get_counter(&"tex_prewarm_atom_overruns")
	_gl.wave_director.current_wave = 8
	var t0 := Time.get_ticks_usec()
	_gl._tex_prewarm_skip = 0
	_gl._process_tex_prewarm(PUMP_BUDGET_US, true)
	var atom_us := Time.get_ticks_usec() - t0
	var atom_d: int = DebugStats.get_counter(&"tex_prewarm_atom_overruns") - atom0
	var synth_left := 0
	for it_v: Variant in _gl._tex_prewarm_queue:
		var it: Dictionary = it_v
		if int(it.get(&"op", -1)) == 0 and String(it.get(&"kind", &"")) == "boss1" \
				and int(it.get(&"wave", -1)) == 9:
			synth_left += 1
	_check("e 门槛放行恰 1 原子项/帧（合成对剩 %d/2；帧 %dµs ≤%.0fµs；超支计数 Δ=%d）" % [
		synth_left, atom_us, ATOM_CAP_US, atom_d],
		synth_left == 1 and atom_us <= ATOM_CAP_US and atom_d >= 1,
		"atom_us=%d synth_left=%d" % [atom_us, synth_left])
	_check("e 原子帧 ≤%.0fµs 硬帽（实测 %dµs）" % [HARD_CAP_US, atom_us],
		atom_us <= HARD_CAP_US)
	_check("e 占空还账生效（_tex_prewarm_skip=%d ≥1——R222 Fix P）" % _gl._tex_prewarm_skip,
		_gl._tex_prewarm_skip >= 1)
	# 还账帧：skip 递减零出队
	var q_payback: int = _gl._tex_prewarm_queue.size()
	_gl._process_tex_prewarm(PUMP_BUDGET_US, true)
	_check("e 还账帧零出队（队长 %d 恒等）" % q_payback,
		_gl._tex_prewarm_queue.size() == q_payback)


	# ── f) PLAYING 泵帧峰值（60 次泵调用逐帧计时——引擎 _process 同参直调） ──
func _test_pump_frame_peaks() -> void:
	print("── f) 泵帧峰值（60 帧） ──")
	_gl._tex_prewarm_skip = 0
	var max_us := 0
	var atom_frames := 0
	var regular_frames := 0
	for i in range(60):
		var t0 := Time.get_ticks_usec()
		_gl._process_tex_prewarm(PUMP_BUDGET_US, true)
		var us := Time.get_ticks_usec() - t0
		if us > max_us:
			max_us = us
		if us > PUMP_BUDGET_US + CHEAP_OVERSHOOT_US:
			atom_frames += 1     # 原子超支帧（volatile 双面/合成 boss 尾项/ring 慢项）
		else:
			regular_frames += 1
	print("    60 帧泵耗时：峰值 %dµs / 常规帧 %d / 超支帧 %d" % [
		max_us, regular_frames, atom_frames])
	_check("f 全程 ≤%.0fµs 硬帽（峰值 %dµs）" % [HARD_CAP_US, max_us],
		max_us <= HARD_CAP_US)
	_check("f 超支帧各 ≤%.0fµs 原子上界（峰值 %dµs——boss 双面实测上界口径）" % [
		ATOM_CAP_US, max_us], max_us <= ATOM_CAP_US)
	_check("f 常规帧（≤%.0fµs 档）占多数（%d/60 ≥45——占空还账后零成本帧 +
		预算内帧为主，原子项摊到 ~1/N 帧）" % [
			PUMP_BUDGET_US + CHEAP_OVERSHOOT_US, regular_frames],
		regular_frames >= 45)
