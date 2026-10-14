# tests/qa_r259_perf_diag.gd — R259 QA 诊断探针：三面板连开 hit/miss 分类计时
# （区分「命中路径变慢」vs「每开必 miss」；产品码 2026-10-11 22:14 冻结态）
extends SceneTree


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	await process_frame
	var gl_script: GDScript = load("res://scripts/loop/game_loop.gd")
	var gl = gl_script.new()
	gl.name = "GameLoopForR259PerfDiag"
	get_root().add_child(gl)
	gl.set_physics_process(false)
	var waited := 0
	while not gl.boot_ready and waited < 600:
		await process_frame
		waited += 1
	var menu = gl.menu_screen
	print("═══ R259 性能诊断：连开 hit/miss 分类（ach/char/map 各 8 开）═══")
	# 排空图鉴泵（同 r255 B 轮口径）
	var guard := 0
	while not ((menu._codex_prewarm_queue as Array).is_empty()
			and String(menu._codex_pump_tab) == "") and guard < 900:
		await process_frame
		guard += 1

	var panels := {
		"codex": func() -> void: menu._on_lobby_pressed("codex"),
		"ach": func() -> void: menu._on_lobby_pressed("ach"),
		"char": func() -> void: menu._on_lobby_pressed("char"),
		"map": func() -> void: menu._open_map_select(),
	}
	# r255 同序复现：codex 先开 ×5（A 轮口径=泵未排空），随后 ach/char/map
	print("  [r255 序列复现：codex×5 → ach×5 → char×5 → map×5]")
	for pname in ["codex", "ach", "char", "map"]:
		var prefix: String = {"codex": "CodexRow_", "ach": "AchRow_", "char": "CharRow_", "map": "MapRow_"}[pname]
		var prev_ids: Array[int] = []
		var line := ""
		for i in 8:
			var t0 := int(Time.get_ticks_usec())
			(panels[pname] as Callable).call()
			var us := int(Time.get_ticks_usec()) - t0
			# 分类：取首行实例 id 与上次开比较
			var first_id := 0
			for c in (menu._panel_list as Node).get_children():
				if String(c.name).begins_with(prefix):
					first_id = (c as Object).get_instance_id()
					break
			var kind := "MISS"
			if i > 0 and first_id != 0 and prev_ids.has(first_id):
				kind = "hit "
			prev_ids.append(first_id)
			line += "%s=%.1fms(%s)" % [str(i + 1), float(us) / 1000.0, kind]
			if i < 7:
				line += " "
			await process_frame
		print("  %-5s %s" % [pname, line])
	gl.free()
	quit(0)
