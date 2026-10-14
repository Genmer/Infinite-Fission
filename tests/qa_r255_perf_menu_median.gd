# tests/qa_r255_perf_menu_median.gd
# R255 性能猎手·菜单剩余大头中位复测（只测不改产品码）。
# R254 切页缓存已修图鉴二切——本探针只量「剩余大头」：图鉴首开（冷泵口径）/反应页
# 首建/成就页/选人页/遗物首建/选图开/难度重选，各 5 次中位数（r252_menu_perf M1
# D1 修订同口径——单发时序噪声大）。两次启动之间模拟「闲时泵排空」对照：
# run A = boot 即测（玩家秒开口径，泵未排空）；run B = 等泵排空后再测（玩家停留口径）。
# 用法：Godot --headless --path <repo> -s tests/qa_r255_perf_menu_median.gd
extends SceneTree

const N := 5


func _initialize() -> void:
	_run()


func _t(p_cb: Callable) -> int:
	var us0 := int(Time.get_ticks_usec())
	p_cb.call()
	return int(Time.get_ticks_usec()) - us0


func _median(p_arr: Array) -> float:
	var s := p_arr.duplicate()
	s.sort()
	return float(s[s.size() / 2]) / 1000.0


func _samples(p_arr: Array) -> String:
	var out := ""
	for v in p_arr:
		out += "%.1f," % (float(v) / 1000.0)
	return out


func _run() -> void:
	print("═══ R255 菜单剩余大头中位复测（headless 直调 handler，5 次中位） ═══")
	await process_frame
	await process_frame
	var gl_script: GDScript = load("res://scripts/loop/game_loop.gd")
	var gl = gl_script.new()
	gl.name = "GameLoopForProbeR255"
	get_root().add_child(gl)
	gl.set_physics_process(false)
	var waited := 0
	while not gl.boot_ready and waited < 600:
		await process_frame
		waited += 1
	var menu = gl.menu_screen
	gl.set("_menu_dwell_s", 99.0)
	var guard := 0
	while gl._tex_prewarm_queue.size() > 0 and guard < 400:
		gl._process_tex_prewarm(20000)
		guard += 1
	print("[A] boot 即测（图鉴闲时行级泵未排空——玩家秒开口径）")
	_measure_set(menu, gl, "_A")
	# 排空图鉴闲时行级泵（menu_screen _process 驱动——等待其把 5 页建完）
	var pump_guard := 0
	while pump_guard < 900:
		await process_frame
		pump_guard += 1
		if menu.get("_codex_prewarm_queue") != null and (menu.get("_codex_prewarm_queue") as Array).is_empty() \
				and not (menu.get("_codex_page_cache") as Dictionary).is_empty():
			break
	print("[B] 图鉴行级泵排空后测（玩家菜单停留 ≥~1s 口径；缓存页直挂）")
	_measure_set(menu, gl, "_B")
	gl.free()
	quit(0)


func _measure_set(p_menu, p_gl, p_tag: String) -> void:
	var res := {}
	for name_key in ["codex_open", "lobby_ach", "lobby_char", "map_select"]:
		var samples: Array = []
		for i in N:
			match name_key:
				"codex_open":
					samples.append(_t(func() -> void: p_menu._on_lobby_pressed("codex")))
				"lobby_ach":
					samples.append(_t(func() -> void: p_menu._on_lobby_pressed("ach")))
				"lobby_char":
					samples.append(_t(func() -> void: p_menu._on_lobby_pressed("char")))
				"map_select":
					samples.append(_t(func() -> void: p_menu._open_map_select()))
		res[name_key] = {"median_ms": _median(samples), "samples_ms": _samples(samples)}
	# 反应页首建：每轮先 invalidate（否则 R254 缓存命中=二切口径）
	var rxn: Array = []
	for i in N:
		p_menu._invalidate_codex_cache()
		rxn.append(_t(func() -> void: p_menu._on_codex_tab("反应")))
	res["codex_tab_reaction_first"] = {"median_ms": _median(rxn), "samples_ms": _samples(rxn)}
	for k in res:
		print("[%s] %-24s 中位 %7.2f ms｜样本 %s" % [p_tag.substr(1), k, res[k]["median_ms"], res[k]["samples_ms"]])
