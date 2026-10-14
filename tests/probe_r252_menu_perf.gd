# tests/probe_r252_menu_perf.gd
# R252-M0 菜单性能探针（设计 §4.5-M0 指定路径；§5 分区表归 D）：headless 直调点击链路
# handler 计时，Time.get_ticks_usec 包裹（与设计 §4.1 侦察同口径、成品行数建行）。输出
# JSON 至 res://tests/runner/_probe_r252_menu_perf.json：每 handler 耗时 µs / rebuild 后
# 同帧 _panel_list.get_child_count()（含 queue_free 待释放旧行 = 同帧双布局证据）/
# 委托臂图标直调口冷热耗时 / 双预热泵实测。修前基线已留档 _probe_r252_menu_perf_pre.json、
# 修后对照 _probe_r252_menu_perf_post.json（r252_menu_perf_cases.gd M0 组读取对比）——
# 本脚本保留为同口径再生复核生成器：跑后把输出 JSON 改名 _pre/_post 归档。
# autoload 全局名在 -s 编译期不可见 → GameLoop/TextureFactory/CardDescPrewarm 一律
# load() 取脚本（同 cases 运行时编译规避）。
extends SceneTree

const OUT_PATH := "res://tests/runner/_probe_r252_menu_perf.json"


func _initialize() -> void:
	_run()


func _t(p_cb: Callable) -> int:
	var us0 := int(Time.get_ticks_usec())
	p_cb.call()
	return int(Time.get_ticks_usec()) - us0


func _run() -> void:
	print("════ R252-M0 菜单性能探针（headless 直调 handler 计时） ════")
	await process_frame
	await process_frame
	var gl_script: GDScript = load("res://scripts/loop/game_loop.gd")
	var tf_script: GDScript = load("res://scripts/ui/texture_factory.gd")
	var cd_script: GDScript = load("res://scripts/cards/card_desc_prewarm.gd")
	var gl = gl_script.new()
	gl.name = "GameLoopForProbeR252"
	get_root().add_child(gl)
	gl.set_physics_process(false)
	var waited := 0
	while not gl.boot_ready and waited < 600:
		await process_frame
		waited += 1
	var menu = gl.menu_screen
	var res := {}
	res["probe"] = "r252_menu_perf"
	res["boot_ready"] = bool(gl.boot_ready)
	res["registry"] = {
		"enemies": menu.registry.enemies.size(),
		"weapons": menu.registry.weapons.size(),
		"traits": menu.registry.traits.size(),
		"relics": menu.registry.relics.size(),
	}
	# R252D P3 后口径：手动排空贴图预热队列（M1 量「贴图预热完成后」的首建——
	# boss 挂机门以 dwell 拉满绕过；guard 防死循环）
	gl.set("_menu_dwell_s", 99.0)
	var guard := 0
	while gl._tex_prewarm_queue.size() > 0 and guard < 400:
		gl._process_tex_prewarm(20000)
		guard += 1
	res["prewarm_drained"] = gl._tex_prewarm_queue.size() == 0
	var us := {}
	var kids := {}

	# ── 图鉴打开（怪物页首建/二建） ──
	us["codex_open_first"] = _t(func() -> void: menu._on_lobby_pressed("codex"))
	kids["codex_open_first"] = menu._panel_list.get_child_count()
	us["codex_open_second"] = _t(func() -> void: menu._on_lobby_pressed("codex"))
	kids["codex_open_second"] = menu._panel_list.get_child_count()

	# ── 图鉴各页签 首建/二建（同帧双布局证据 = 二建后 child_count ≈ 2×行数） ──
	for tab in ["武器", "祝福", "反应", "遗物", "怪物"]:
		us["codex_tab_%s_first" % tab] = _t(func() -> void: menu._on_codex_tab(tab))
		kids["codex_tab_%s_first" % tab] = menu._panel_list.get_child_count()
		us["codex_tab_%s_second" % tab] = _t(func() -> void: menu._on_codex_tab(tab))
		kids["codex_tab_%s_second" % tab] = menu._panel_list.get_child_count()

	# ── 其余大厅页 ──
	for kind in ["ach", "records", "char", "upgrade", "daily"]:
		us["lobby_%s" % kind] = _t(func() -> void: menu._on_lobby_pressed(kind))
		kids["lobby_%s" % kind] = menu._panel_list.get_child_count()
	us["lobby_ach_page2"] = _t(func() -> void: menu._on_ach_page_next())
	kids["lobby_ach_page2"] = menu._panel_list.get_child_count()

	# ── 选关与切难度 ──
	us["map_select_open"] = _t(func() -> void: menu._open_map_select())
	kids["map_select_open"] = menu._panel_list.get_child_count()
	us["map_difficulty_repick"] = _t(func() -> void: menu._on_difficulty_pick(1))
	kids["map_difficulty_repick"] = menu._panel_list.get_child_count()

	# ── 委托臂图标直调口（M3 口径：同 id 第二次直调；P4-② 成品缓存后热调 ≤1ms） ──
	var wid := StringName("W11_spirit_sword")
	us["delegate_icon_cold"] = _t(func() -> void:
		tf_script._delegate_weapon_icon(wid, false))
	us["delegate_icon_warm"] = _t(func() -> void:
		tf_script._delegate_weapon_icon(wid, false))

	# ── 双预热泵实测（预算现状 4000；carddesc 量 12000 与 4000 对照） ──
	res["tex_prewarm_queue_left"] = gl._tex_prewarm_queue.size()
	us["tex_prewarm_12000"] = _t(func() -> void: gl._process_tex_prewarm(12000))
	cd_script.reset_for_tests()
	cd_script.ensure_built(menu.registry)
	res["carddesc_total_built"] = int(cd_script.total_built())
	us["carddesc_pump_12000"] = _t(func() -> void: cd_script.pump(12000))
	res["carddesc_remaining_after_12000"] = int(cd_script.remaining())
	cd_script.reset_for_tests()
	cd_script.ensure_built(menu.registry)
	us["carddesc_pump_4000"] = _t(func() -> void: cd_script.pump(4000))
	res["carddesc_remaining_after_4000"] = int(cd_script.remaining())
	cd_script.reset_for_tests()

	res["handlers_us"] = us
	res["children_same_frame"] = kids
	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(res, "  "))
	f.close()
	print(JSON.stringify(res, "  "))
	print("JSON 已写：%s" % OUT_PATH)
	gl.free()
	quit(0)
