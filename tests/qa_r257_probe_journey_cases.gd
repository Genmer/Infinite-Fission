# tests/qa_r257_probe_journey_cases.gd — R257 全程时间线用例体（入口运行时加载）
# 只读产品代码；Meta 直改内存字段不落盘；收尾不清用户真档（本探针全程内存态，
# map_records 写入内存 Dictionary——quit 即弃）。池非空走面板路径（Q3 同款夹具）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DEMON := &"world_demon"
const FROST := &"world_frost"
const GRASS := &"world_grass"
const MAX_FRAMES := 60 * 150           # 150s 上限（60fps 实帧）


func run(p_tree: SceneTree) -> void:
	print("══ QA probe R257: demon@hard full journey timeline ══")
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

	# ── 用户档形态：普通全通 + 困难 grass/frost 已通（demon@困难解锁）+ 图鉴有紫词条（池非空弹面板）──
	Meta.map_records.clear()
	Meta.maps_cleared.clear()
	Meta.codex_traits.clear()
	Meta.map_records["world_grass"] = {"best_wave": 10, "best_kills": 0, "best_level": 1}
	Meta.map_records["world_grass#1"] = {"best_wave": 10, "best_kills": 0, "best_level": 1}
	Meta.map_records["world_frost"] = {"best_wave": 15, "best_kills": 0, "best_level": 1}
	Meta.map_records["world_frost#1"] = {"best_wave": 15, "best_kills": 0, "best_level": 1}
	Meta.maps_cleared["world_grass"] = true
	Meta.codex_traits["AFF_MULTI"] = true          # rarity=2 紫词条（R254 Q3 同款）
	gl.state = GameConst.GameStatus.MENU
	print("[pre] unlocked(demon,1)=%s pool(tier)=%s auto_restart_mode=%s"
		% [Meta.is_map_unlocked(DEMON, 1), str(gl._blessing_pool(2)),
			str(Meta.settings("auto_restart_mode"))])

	# ── 真按钮路径：选关面板 → 切困难 → demon 行出发钮 pressed ──
	menu._open_map_select()
	menu._on_difficulty_pick(1)
	await p_tree.process_frame
	var demon_go: Button = null
	for row in (menu.get("_panel_list") as Container).get_children():
		if row is Panel:
			var idx_l: Label = null
			for sub in row.get_children():
				if sub is Label and (sub as Label).position == Vector2(18.0, 32.0):
					idx_l = sub
				if sub is Button and (sub as Button).text == "出发" and idx_l != null \
						and (idx_l as Label).text == "3":
					demon_go = sub
	if demon_go == null:
		print("[J0] FAIL：困难档 demon 行无出发钮（与 R254 Q1/Q2 矛盾——解锁链断言先查）")
		return
	var t0 := Time.get_ticks_msec()
	demon_go.pressed.emit()

	# ── 逐帧时间线：面板→确认→PLAYING→首敌→首伤→死亡→结算屏 ──
	var last_state := -1
	var panel_seen := false
	var confirmed := false
	var first_enemy_ms := -1
	var first_hurt_ms := -1
	var death_ms := -1
	var go_screen_ms := -1
	var hp0 := 0.0
	var frames := 0
	var auto_restart_seen := false
	var go_edge_logged := 0
	while frames < MAX_FRAMES:
		await p_tree.process_frame
		frames += 1
		var ms := Time.get_ticks_msec() - t0
		# GAME_OVER 边沿：连 6 帧打印结算屏可见性（边沿直证——show_summary 是否真跑真显）
		if gl.state == GameConst.GameStatus.GAME_OVER and go_edge_logged < 6:
			var root_c: Control = gl.game_over_screen.get("_root")
			print("[GO 边沿 %d] T+%dms _root=%s visible=%s hud=%s"
				% [go_edge_logged, ms, str(root_c != null), str(root_c.visible if root_c != null else "n/a"),
					str(gl.game_over_screen.get("stats_source"))])
			go_edge_logged += 1
		# 面板出现：自动确认（模拟玩家点「出发」——面板确认键）
		if not panel_seen and gl.blessing_pick_ui.is_open():
			panel_seen = true
			print("[T+%dms] 祝福面板出现（pending=%s）" % [ms, gl.get("_blessing_pending")])
			gl.blessing_pick_ui.confirm()
			confirmed = true
			continue
		if confirmed and gl.state == GameConst.GameStatus.PLAYING and hp0 == 0.0:
			hp0 = gl.player.hp
			print("[T+%dms] PLAYING 开局：hp=%.0f 首帧敌=%d"
				% [ms, hp0, gl.spawner.active_count()])
		if gl.state != last_state:
			print("[T+%dms] state %d→%d" % [ms, last_state, gl.state])
			last_state = gl.state
		if first_enemy_ms < 0 and gl.spawner.active_count() > 0:
			first_enemy_ms = ms
			print("[T+%dms] 首敌入场（%d 只）" % [ms, gl.spawner.active_count()])
		if first_hurt_ms < 0 and hp0 > 0.0 and gl.player.hp < hp0:
			first_hurt_ms = ms
			print("[T+%dms] 首次掉血 hp %.0f→%.0f" % [ms, hp0, gl.player.hp])
		if death_ms < 0 and gl.player.hp <= 0.0 and gl.state == GameConst.GameStatus.GAME_OVER:
			death_ms = ms
			print("[T+%dms] 死亡→GAME_OVER" % ms)
		if go_screen_ms < 0 and death_ms >= 0 and gl.game_over_screen != null \
				and gl.game_over_screen.get_node_or_null("Root") != null:
			go_screen_ms = ms
			print("[T+%dms] 结算屏可见" % ms)
		if death_ms >= 0 and ms - death_ms > 5000:
			break                                # 死后观察 5s 足够（边沿直证已打）
		if death_ms < 0 and gl.state == GameConst.GameStatus.MENU and confirmed and frames > 60:
			print("[T+%dms] !!! 异常：确认后回 MENU（未经过 GAME_OVER？）" % ms)
			break
	# 死后 20s 行为摘要：结算屏在？倒计时在？回菜单了？
	var gos_visible: bool = gl.game_over_screen != null \
		and bool(gl.game_over_screen.get("_root") != null
			and (gl.game_over_screen.get("_root") as CanvasItem).visible)
	var countdown: float = float(gl.game_over_screen.get("_auto_countdown_left")) \
		if gl.game_over_screen != null else -1.0
	print("[post] 死后 5s：state=%d 结算屏可见=%s 倒计时=%.1f 回菜单=%s"
		% [gl.state, gos_visible, countdown,
			gl.state == GameConst.GameStatus.MENU])
	print("[post] 时间线摘要：首敌=%dms 首伤=%dms 死亡=%dms（首伤→死亡 %dms）"
		% [first_enemy_ms, first_hurt_ms, death_ms,
			(death_ms - first_hurt_ms) if (death_ms >= 0 and first_hurt_ms >= 0) else -1])
	# R257 事件行实形态 dump：事件独立环（M3 后导出前置段的真源——真机复发时
	# 「导出诊断日志」用户会看到的形态）
	var ev_lines: Array[String] = []
	for s in DebugStats._diag_ev_lines:
		if s.begins_with("[ev "):
			ev_lines.append(s)
	print("[diag] 事件行 ×%d（独立环——真机导出同形态）：" % ev_lines.size())
	for s in ev_lines:
		print("  %s" % s)
	print("══ probe done ══")
