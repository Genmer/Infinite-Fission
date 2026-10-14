# tests/qa_r254_probe_map_cases.gd — R254-2 四象限用例体（入口运行时加载）
# 只读产品代码；Meta 直改内存字段（不走 mark 接口=不落盘），收尾清祝福记忆防污染电池批。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DEMON := &"world_demon"   # 第三关（MAPS 序 3——上一关 world_frost）
const FROST := &"world_frost"
const GRASS := &"world_grass"


func run(p_tree: SceneTree) -> void:
	print("══ QA probe R254-2: hard map3 depart → home? ══")
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
	var menu: MenuScreen = gl.menu_screen

	# ── Q1：困难档未通 frost（用户档形态：普通达线、困难分档键缺） ──
	Meta.map_records.clear()
	Meta.maps_cleared.clear()
	Meta.codex_traits.clear()
	Meta.map_records["world_grass"] = {"best_wave": 10, "best_kills": 0, "best_level": 1}
	Meta.maps_cleared["world_grass"] = true
	gl.state = GameConst.GameStatus.MENU
	print("[Q1] unlocked(demon,HARD)=%s  unlocked(frost,HARD)=%s"
		% [Meta.is_map_unlocked(DEMON, 1), Meta.is_map_unlocked(FROST, 1)])
	# UI 面：开选关面板切困难，数「出发」钮 + 找第三关行
	menu._open_map_select()
	menu._on_difficulty_pick(1)
	await p_tree.process_frame
	var go_total := 0
	var grove_btn := "无"
	for row in (menu.get("_panel_list") as Container).get_children():
		if row is Panel:
			var idx_l: Label = null
			for sub in row.get_children():
				if sub is Label and (sub as Label).position == Vector2(18.0, 32.0):
					idx_l = sub
				if sub is Button and (sub as Button).text == "出发":
					go_total += 1
					if idx_l != null and (idx_l as Label).text == "3":
						grove_btn = "有"
	print("[Q1] UI: 困难档面板出发钮总数=%d（期望 1：仅第一关恒解锁）  第三关(demon)行出发钮=%s"
		% [go_total, grove_btn])
	# 出发链：直调（用户按钮信号最终落点）
	gl._on_menu_start(DEMON, 1)
	await p_tree.process_frame
	print("[Q1] _on_menu_start(demon,1) 后: state=%d(PLAYING=%d) blessing_pending=%s panel_open=%s"
		% [gl.state, GameConst.GameStatus.PLAYING, gl.get("_blessing_pending"),
			gl.blessing_pick_ui.is_open()])

	# ── Q2：困难 frost 达线 + 祝福池空 → 应直达 PLAYING ──
	Meta.map_records["world_frost#1"] = {"best_wave": 15, "best_kills": 0, "best_level": 1}
	print("[Q2-diag] keys=%s cleared_at(frost,1)=%s meta=%s"
		% [Meta.map_records.keys(), Meta.is_map_cleared_at(FROST, 1), Meta])
	print("[Q2] unlocked(demon,HARD)=%s  codex_traits=%d" % [Meta.is_map_unlocked(DEMON, 1), Meta.codex_traits.size()])
	gl._on_menu_start(DEMON, 1)
	await p_tree.process_frame
	await p_tree.process_frame
	print("[Q2] _on_menu_start(demon,1) 后: state=%d(PLAYING=%d) blessing_pending=%s panel_open=%s"
		% [gl.state, GameConst.GameStatus.PLAYING, gl.get("_blessing_pending"),
			gl.blessing_pick_ui.is_open()])

	# ── Q3：图鉴解锁紫词条（AFF_MULTI rarity=2）→ 面板弹 → confirm ──
	if gl.state == GameConst.GameStatus.PLAYING:
		gl.state = GameConst.GameStatus.MENU
	Meta.codex_traits["AFF_MULTI"] = true
	gl._on_menu_start(DEMON, 1)
	await p_tree.process_frame
	print("[Q3-diag] unlocked(demon)=%s pool(tier2)=%s aff_unlocked=%s"
		% [Meta.is_map_unlocked(DEMON, 1), str(gl._blessing_pool(2)),
			Meta.is_trait_unlocked(&"AFF_MULTI")])
	print("[Q3] 面板态: blessing_pending=%s panel_open=%s state=%d"
		% [gl.get("_blessing_pending"), gl.blessing_pick_ui.is_open(), gl.state])
	gl.blessing_pick_ui.confirm()
	await p_tree.process_frame
	await p_tree.process_frame
	print("[Q3] confirm() 后: state=%d(PLAYING=%d)" % [gl.state, GameConst.GameStatus.PLAYING])

	# ── Q4：dismiss（不选祝福）→ PLAYING ──
	if gl.state == GameConst.GameStatus.PLAYING:
		gl.state = GameConst.GameStatus.MENU
	gl._on_menu_start(DEMON, 1)
	await p_tree.process_frame
	gl.blessing_pick_ui.dismiss()
	await p_tree.process_frame
	await p_tree.process_frame
	print("[Q4] dismiss() 后: state=%d(PLAYING=%d)" % [gl.state, GameConst.GameStatus.PLAYING])

	# 收尾：清祝福记忆（confirm 可能写了记忆键——防污染电池批 p1_polish 等）
	Meta.clear_blessing_trait()
	print("══ probe done ══")
