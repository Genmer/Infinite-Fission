# tests/qa_r254_rev2_probe_cases.gd — R254 修轮复核用例体（入口运行时加载）
# 只读产品代码；Meta 直改内存字段（不走 mark 接口=不落盘），存档文本快照还原收尾。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const GRASS := &"world_grass"
const FROST := &"world_frost"


func run(p_tree: SceneTree) -> void:
	print("══ QA probe R254 修轮复核 ══")
	var sp := Meta.save_path()
	var had_save := FileAccess.file_exists(sp)
	var save_text := ""
	if had_save:
		save_text = FileAccess.get_file_as_string(sp)
	var snap_traits: Dictionary = Meta.codex_traits.duplicate()
	var snap_records: Dictionary = Meta.map_records.duplicate()
	var snap_cleared: Dictionary = Meta.maps_cleared.duplicate()
	var snap_blessing: String = Meta.blessing_trait_id

	var main: Node = load(MAIN_SCENE).instantiate()
	p_tree.root.add_child(main)
	await p_tree.process_frame
	await p_tree.process_frame
	var gl: GameLoop = null
	for c in p_tree.root.get_children():
		if c is GameLoop:
			gl = c
			break
	if gl == null:
		print("PROBE-FAIL no GameLoop")
		return

	_p1_adoption_map(gl)
	_p2_pump_race_prebuilt(gl, p_tree)
	_p3_invalidate_midpage(p_tree)
	_p4_keep_reaction(p_tree)
	_p5_daily_pending_gate(gl)

	# 收尾还原（防污染后续电池批）
	Meta.codex_traits = snap_traits
	Meta.map_records = snap_records
	Meta.maps_cleared = snap_cleared
	Meta.blessing_trait_id = snap_blessing
	Meta.clear_blessing_trait()
	if had_save:
		var f := FileAccess.open(sp, FileAccess.WRITE)
		if f != null:
			f.store_string(save_text)
			f.close()
		Meta._load()
	print("══ probe done ══")


func _unlock_traits(gl: GameLoop) -> void:
	for tid_v: Variant in gl.registry.traits.keys():
		Meta.codex_traits[String(tid_v)] = true


func _mk_gl(p_tree: SceneTree, p_name: String) -> GameLoop:
	var g := GameLoop.new()
	g.name = p_name
	p_tree.root.add_child(g)
	g.set_physics_process(false)
	return g


# ── P1：pending 二次出发换图——confirm 后实跑地图真源一致性 ──
func _p1_adoption_map(p_gl: GameLoop) -> void:
	print("── P1 换图采用链：start(grass) → 面板丢失 → start(frost) → confirm → 实跑图？ ──")
	p_gl.state = GameConst.GameStatus.MENU
	_unlock_traits(p_gl)
	Meta.blessing_trait_id = ""
	Meta.maps_cleared.clear()
	Meta.map_records.clear()
	Meta.map_records["world_grass"] = {"best_wave": 10, "best_kills": 0, "best_level": 1}
	Meta.maps_cleared["world_grass"] = true          # 普通档 frost 解锁
	p_gl._on_menu_start(GRASS, 0)                    # 首次出发：grass（tier1 池非空应弹）
	var pre_ok := bool(p_gl.get("_blessing_pending")) and p_gl.blessing_pick_ui.is_open()
	p_gl.blessing_pick_ui.close()                    # 面板丢失（不发信号）
	p_gl._on_menu_start(FROST, 0)                    # 二次出发换图：frost（已解锁）
	var adopted_pool := p_gl.blessing_pick_ui.is_open()
	p_gl.blessing_pick_ui.dismiss()                  # 收口 → _finish_menu_start(frost)
	print("[P1] pre_ok=%s reopened=%s pick_map=%s current_map_id=%s state=%d(PLAYING=%d)"
		% [str(pre_ok), str(adopted_pool), String(p_gl.get("_blessing_pick_map")),
			String(p_gl.current_map_id), p_gl.state, GameConst.GameStatus.PLAYING])
	print("[P1] 判读：pick_map==frost 且 current_map_id==frost → 采用链完整；"
		+ "pick_map==frost 而 current_map_id==grass → 半采用（start_run 真源=旧图=缺陷）")


# ── P2：泵在建页被同步抢建——页毕弃置半成品、缓存不被覆盖 ──
func _p2_pump_race_prebuilt(p_gl: GameLoop, p_tree: SceneTree) -> void:
	print("── P2 抢建竞态：泵半页 → 玩家同步建同页 → 泵页毕 → 缓存=同步页实例 ──")
	var gl := _mk_gl(p_tree, "QAP2GameLoop")
	var menu = gl.menu_screen
	menu._root.visible = true
	var guard := 0
	while menu._codex_pump_tab == "" and not menu._codex_prewarm_queue.is_empty() and guard < 50:
		menu._process(0.016)                          # 推到「某页在建」态
		guard += 1
	var tab: String = menu._codex_pump_tab
	var partial: int = menu._codex_pump_rows.size()
	if tab == "":
		print("[P2] SKIP：单帧内页已毕未捕获在建态（headless 快行）partial=%d" % partial)
		gl.free()
		return
	menu._on_lobby_pressed("codex")                  # 同步路径抢建同页（面板当前 tab=怪物）
	if tab != "怪物":
		menu._on_codex_tab(tab)
	var sync_ids: Array[int] = []
	for r in menu._codex_page_cache[tab]:
		sync_ids.append(r.get_instance_id())
	guard = 0
	while (menu._codex_pump_tab != "" or not menu._codex_prewarm_queue.is_empty()) and guard < 400:
		menu._process(0.016)
		guard += 1
	var after_ids: Array[int] = []
	for r in menu._codex_page_cache[tab]:
		after_ids.append(r.get_instance_id())
	var mounted_still := true
	for r in menu._panel_list.get_children():
		if not r.is_queued_for_deletion() and not (r.get_instance_id() in after_ids):
			mounted_still = false
	print("[P2] tab=%s partial_rows=%d sync_page=%d cache_after=%d unchanged=%s mounted_clean=%s"
		% [tab, partial, sync_ids.size(), after_ids.size(),
			str(sync_ids == after_ids), str(mounted_still)])
	menu._on_panel_close()
	gl.free()


# ── P3：invalidate 中途（泵半页态）状态复位 ──
func _p3_invalidate_midpage(p_tree: SceneTree) -> void:
	print("── P3 失效中途：泵半页态 invalidate → 状态复位 + 后续重建可用 ──")
	var gl := _mk_gl(p_tree, "QAP3GameLoop")
	var menu = gl.menu_screen
	menu._root.visible = true
	var guard := 0
	while menu._codex_pump_tab == "" and not menu._codex_prewarm_queue.is_empty() and guard < 50:
		menu._process(0.016)
		guard += 1
	var mid_tab: String = menu._codex_pump_tab
	var mid_rows: int = menu._codex_pump_rows.size()
	menu._invalidate_codex_cache()                   # 默认口（codex_changed 语义）
	var reset_ok: bool = menu._codex_pump_tab == "" and menu._codex_pump_rows.is_empty() \
		and menu._codex_page_cache.is_empty() and menu._codex_prewarm_queue.size() == 5
	menu._on_lobby_pressed("codex")
	var live_n: int = 0
	for c in menu._panel_list.get_children():
		if not c.is_queued_for_deletion():
			live_n += 1
	print("[P3] mid_tab=%s mid_rows=%d reset=%s rebuild_live=%d（>0=重建可用）"
		% [mid_tab, mid_rows, str(reset_ok), live_n])
	menu._on_panel_close()
	gl.free()


# ── P4：回菜单失效口 keep_reaction——反应页同实例保留 ──
func _p4_keep_reaction(p_tree: SceneTree) -> void:
	print("── P4 keep_reaction：五页备齐 → 回菜单 → 反应页同实例、其余失效、队列 4 项 ──")
	var gl := _mk_gl(p_tree, "QAP4GameLoop")
	var menu = gl.menu_screen
	menu._root.visible = true
	var guard := 0
	while (menu._codex_pump_tab != "" or not menu._codex_prewarm_queue.is_empty()) and guard < 400:
		menu._process(0.016)
		guard += 1
	var rxn_ids: Array[int] = []
	for r in menu._codex_page_cache["反应"]:
		rxn_ids.append(r.get_instance_id())
	var mon_ids: Array[int] = []
	for r in menu._codex_page_cache["怪物"]:
		mon_ids.append(r.get_instance_id())
	menu._on_state_changed(GameConst.GameStatus.MENU)   # 回菜单口（invalidate(true)）
	var rxn_after: Array[int] = []
	for r in menu._codex_page_cache["反应"]:
		rxn_after.append(r.get_instance_id())
	var mon_dead := true
	for id_v in mon_ids:
		var n: Node = instance_from_id(int(id_v))
		if n != null and not n.is_queued_for_deletion():
			mon_dead = false
	var q_n: int = menu._codex_prewarm_queue.size()
	var q_no_rxn: bool = not menu._codex_prewarm_queue.has("反应")
	menu._on_lobby_pressed("codex")
	menu._on_codex_tab("反应")
	var mount_ids: Array[int] = []
	for r in menu._panel_list.get_children():
		if not r.is_queued_for_deletion():
			mount_ids.append(r.get_instance_id())
	print("[P4] rxn_same=%s mon_freed=%s cache_n=%d q=%d q_no_rxn=%s remount_same=%s"
		% [str(rxn_ids == rxn_after), str(mon_dead), menu._codex_page_cache.size(),
			q_n, str(q_no_rxn), str(mount_ids == rxn_after)])
	menu._on_panel_close()
	gl.free()


# ── P5：每日出发 pending 闸（评审#4）──
func _p5_daily_pending_gate(p_gl: GameLoop) -> void:
	print("── P5 每日 pending 闸：pending 挂起 → _on_menu_start_daily → 不启动+面板开 ──")
	if p_gl.state == GameConst.GameStatus.PLAYING:
		p_gl.state = GameConst.GameStatus.PAUSED
		p_gl.quit_to_menu()
	p_gl._on_menu_start(GRASS, 0)                    # grass 恒解锁：弹面板挂起
	var pre := bool(p_gl.get("_blessing_pending")) and p_gl.blessing_pick_ui.is_open()
	p_gl.blessing_pick_ui.close()                    # 面板丢失态（最严路径）
	p_gl._on_menu_start_daily()
	var gate_ok: bool = p_gl.state == GameConst.GameStatus.MENU \
		and bool(p_gl.get("_blessing_pending")) and p_gl.blessing_pick_ui.is_open()
	p_gl.blessing_pick_ui.dismiss()                  # 收口 → 按 pending 上下文进局
	print("[P5] pre=%s gate_still_menu_panel_reopen=%s after_dismiss_state=%d(PLAYING=%d)"
		% [str(pre), str(gate_ok), p_gl.state, GameConst.GameStatus.PLAYING])
