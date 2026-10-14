# R267 ①出发链/选卡链分段微基准用例体（probe_r267_startchain 入口 load）
# 分段：A 位图冷烤（真机 mobile 门当量，override=1 强制）
#       B start_run 全链（R262e 同口径 5 次可比）
#       C 细分段：bgm 换流冷/热、change_state、set_character、load_table、
#         start_wave(1)、hud.refresh_stats、generate_candidates、
#         选卡 open 热/冷（清 _fit_desc_cache）、change_state(LEVEL_UP)
#       D 首波帧模拟：start_run 后逐帧 wave_director.tick 计时（出队+spawn+首遇卡）
# 只测不改；产物为 stdout 行（判读「验收汇总：PASS n / FAIL m」）
extends RefCounted

var _tree: SceneTree = null
var _fails: int = 0
var _passes: int = 0


func _check(p_name: String, p_ok: bool, p_detail: String = "") -> void:
	if p_ok:
		_passes += 1
		print("PASS | " + p_name)
	else:
		_fails += 1
		print("FAIL | " + p_name + ("" if p_detail.is_empty() else "  [got: " + p_detail + "]"))


func _bench_us(p_iters: int, p_fn: Callable, p_setup: Callable = Callable()) -> float:
	# µs/次均值（预热 1 次排首建抖动；setup 每次前复位态；无效 setup 直跳）
	var prep := func() -> void:
		if p_setup.is_valid():
			p_setup.call()
	prep.call()
	p_fn.call()
	var t0 := Time.get_ticks_usec()
	for i in range(p_iters):
		prep.call()
		p_fn.call()
	var dt := Time.get_ticks_usec() - t0
	return float(dt) / float(p_iters)


func run_all(p_tree: SceneTree) -> int:
	_tree = p_tree
	_probe_glyph_cold_bake()
	_bench_start_run_total()
	_bench_segments()
	_probe_first_wave_frames()
	print("R267 出发/选卡链探针汇总：PASS %d / FAIL %d（共 %d 项）" % [_passes, _fails, _passes + _fails])
	print("验收汇总：PASS %d / FAIL %d" % [_passes, _fails])
	return _fails


func _mk_gl(p_name: String):
	var gl = GameLoop.new()
	gl.name = p_name
	_tree.get_root().add_child(gl)
	gl.set_physics_process(false)
	return gl


# ── A：位图冷烤（真机 mobile 门当量——桌面/headless 本门恒关，override 强制测） ──
func _probe_glyph_cold_bake() -> void:
	print("── A 位图图集冷烤（PopupGlyphAtlas.ensure_runstart_bake，真机 mobile 门当量） ──")
	PopupGlyphAtlas.runstart_bake_override = 1
	var t0 := Time.get_ticks_usec()
	var did := PopupGlyphAtlas.ensure_runstart_bake()
	var us := Time.get_ticks_usec() - t0
	PopupGlyphAtlas.runstart_bake_override = -1
	print("    冷烤整图集 = %.1f ms（built=%d/12, 本口执行=%s）" % [
		float(us) / 1000.0, PopupGlyphAtlas.built_count(), str(did)])
	_check("A 冷烤落账（%.1f ms，真机出发帧内一次性补烤成本）" % (float(us) / 1000.0),
		did and PopupGlyphAtlas.built_count() == PopupGlyphAtlas.glyph_count())


# ── B：start_run 全链（R262e 同口径：state 直置 MENU，5 次均值） ──
func _bench_start_run_total() -> void:
	print("── B start_run 全链（点击「确认」→ 进战斗，R262e 可比口径） ──")
	var gl = _mk_gl("R267B")
	var ok_ref: Array = []
	var us := _bench_us(5, func() -> void:
			if gl.call("start_run"):
				ok_ref.append(1),
		func() -> void:
			gl.state = GameConst.GameStatus.MENU)
	print("    start_run/次 = %.0f µs（真跑 %d/5）" % [us, ok_ref.size()])
	_check("B start_run 全链落账（%.0f µs/次）" % us, ok_ref.size() >= 5 and us > 0.0)
	gl.queue_free()


# ── C：细分段（单 gl 复用，逐段独立计时） ──
func _bench_segments() -> void:
	print("── C 出发/选卡链细分段 ──")
	var gl = _mk_gl("R267C")

	# C1 bgm 换流冷（首载 4 轨 .res——真机换套当量）与热（缓存命中）
	var sfx = gl.get("sfx")
	var v_cur: int = sfx.call("bgm_combat_variant_index")
	var v_a := (v_cur + 1) % 3
	var v_b := (v_cur + 2) % 3
	var t0 := Time.get_ticks_usec()
	sfx.call("bgm_apply_combat_variant", v_a)
	var cold_us := Time.get_ticks_usec() - t0
	var t1 := Time.get_ticks_usec()
	sfx.call("bgm_apply_combat_variant", v_b)
	var cold2_us := Time.get_ticks_usec() - t1
	var hot_us := _bench_us(20, func() -> void:
			sfx.call("bgm_apply_combat_variant", v_a), Callable())
	print("    C1 bgm 换流：冷 v%d=%.1f ms / 冷 v%d=%.1f ms / 热切换=%.0f µs" % [
		v_a, float(cold_us) / 1000.0, v_b, float(cold2_us) / 1000.0, hot_us])
	_check("C1 bgm 换流落账（冷 %.1f+%.1f ms / 热 %.0f µs）" % [
		float(cold_us) / 1000.0, float(cold2_us) / 1000.0, hot_us], cold_us > 0 and hot_us >= 0.0)

	# C2 change_state MENU→PLAYING（含 state_changed 广播 + bgm 运输）
	var us_cs := _bench_us(10, func() -> void:
			gl.call("change_state", GameConst.GameStatus.PLAYING),
		func() -> void:
			gl.state = GameConst.GameStatus.MENU)
	print("    C2 change_state(PLAYING)/次 = %.0f µs（state_changed 9 订阅者）" % us_cs)
	_check("C2 change_state(PLAYING) 落账（%.0f µs/次）" % us_cs, us_cs > 0.0)

	# C3 player.set_character（含养成加成应用）
	var us_sc := _bench_us(10, func() -> void:
			gl.player.call("set_character", Meta.character_id), Callable())
	print("    C3 set_character/次 = %.0f µs" % us_sc)
	_check("C3 set_character 落账（%.0f µs/次）" % us_sc, us_sc > 0.0)

	# C4 MapTable.load_table（每局重载波表）
	var us_lt := _bench_us(20, func() -> void:
			MapTable.load_table(gl.get("current_map_id"), gl.registry), Callable())
	print("    C4 MapTable.load_table/次 = %.0f µs" % us_lt)
	_check("C4 load_table 落账（%.0f µs/次）" % us_lt, us_lt > 0.0)

	# C5 wave_director.start_wave(1)（构成 roll + enqueue + wave_started 广播）
	var wd = gl.wave_director
	var us_sw := _bench_us(10, func() -> void:
			wd.call("start_wave", 1), Callable())
	print("    C5 start_wave(1)/次 = %.0f µs（enqueue 侧，生成在 tick）" % us_sw)
	_check("C5 start_wave(1) 落账（%.0f µs/次）" % us_sw, us_sw > 0.0)

	# C6 hud.refresh_stats（出发链尾段显式刷）
	var hud = gl.hud
	var us_hr := _bench_us(20, func() -> void:
			hud.call("refresh_stats"), Callable())
	print("    C6 hud.refresh_stats/次 = %.0f µs" % us_hr)
	_check("C6 refresh_stats 落账（%.0f µs/次）" % us_hr, us_hr > 0.0)

	# C7 generate_candidates（选卡链头段；wave5 deal3 = R262e 同参）
	var cg = gl.card_generator
	var ctx := {"player": gl.player, "wave": 5, "deal_count": 3}
	var us_gc := _bench_us(20, func() -> void:
			cg.call("generate_candidates", ctx), Callable())
	print("    C7 generate_candidates/次 = %.0f µs（3 张）" % us_gc)
	_check("C7 generate_candidates 落账（%.0f µs/次）" % us_gc, us_gc > 0.0)

	# C8/C9 选卡窗 open 热（缓存命中）/ 冷（清 _fit_desc_cache=真机首开当量）
	gl.call("start_run")
	var cands: Array = cg.call("generate_candidates", ctx)
	var cs = gl.card_select_ui
	var us_hot := _bench_us(8, func() -> void:
			cs.call("open", cands, false),
		func() -> void:
			cs.call("close"))
	var m0: int = CardSelectUI.fit_desc_measures
	var us_cold := _bench_us(5, func() -> void:
			cs.call("open", cands, false),
		func() -> void:
			CardSelectUI._fit_desc_cache.clear()
			cs.call("close"))
	var m1: int = CardSelectUI.fit_desc_measures
	print("    C8 选卡 open 热/次 = %.0f µs；C9 冷（清量测缓存）/次 = %.0f µs（量测 %d 次）" % [
		us_hot, us_cold, m1 - m0])
	# R267 判读注：冷热差在桌面不放大（雅黑单 RID 排版快）——真机 Android 回退链 miss
	# 才是冷开大头（R255 真机对照：排空后中位 16.52→2.60ms），断言只锁「冷开真走了
	# 量测路径 + 两值落账」
	_check("C8/C9 选卡 open 落账（热 %.0f µs / 冷 %.0f µs / 冷量测 %d 次）" % [
		us_hot, us_cold, m1 - m0], us_hot > 0.0 and us_cold > 0.0 and m1 - m0 > 0)

	# C10 change_state PLAYING→LEVEL_UP（选卡瞬间迁移：磁吸遍历+爆虫清引导+tree.paused）
	var us_lu := _bench_us(10, func() -> void:
			gl.call("change_state", GameConst.GameStatus.LEVEL_UP),
		func() -> void:
			gl.state = GameConst.GameStatus.PLAYING)
	print("    C10 change_state(LEVEL_UP)/次 = %.0f µs（空场当量——磁吸/清引导随场上实体线性）" % us_lu)
	_check("C10 change_state(LEVEL_UP) 落账（%.0f µs/次）" % us_lu, us_lu > 0.0)

	gl.state = GameConst.GameStatus.MENU
	gl.queue_free()


# ── D：首波帧模拟（出发后首物理帧：spawner 出队 + enemy.spawn + 首遇卡） ──
func _probe_first_wave_frames() -> void:
	print("── D 首波帧模拟（start_run 后逐帧 wave_director.tick 计时） ──")
	var gl = _mk_gl("R267D")
	gl.call("start_run")
	var wd = gl.wave_director
	var sp = gl.get("spawner")
	var step := 1.0 / 60.0
	var max_us := 0
	var max_frame := -1
	var first_enemy_frame := -1
	var total_us := 0
	for f in range(120):
		var t0 := Time.get_ticks_usec()
		wd.call("tick", step)
		var dt := Time.get_ticks_usec() - t0
		total_us += dt
		if dt > max_us:
			max_us = dt
			max_frame = f
		if first_enemy_frame < 0 and int(sp.get("active").size()) > 0:
			first_enemy_frame = f
	print("    120 帧驱动：峰值帧 %d = %.0f µs；均值 %.0f µs/帧；首敌落场帧 = %d；场上 %d 只" % [
		max_frame, float(max_us), float(total_us) / 120.0, first_enemy_frame,
		int(sp.get("active").size())])
	_check("D 首波帧落账（峰值 %.0f µs @帧%d，首敌帧 %d）" % [
		float(max_us), max_frame, first_enemy_frame], max_us > 0 and first_enemy_frame >= 0)
	gl.queue_free()
