# tests/qa_r255_play_b.gd — R255 试玩局 B：困难·紫晶魔域（第三关）出发链验证 + 短局体验
# 背景：R254-2 用户撞「困难-第三关-出发，回到主页」。本局用真实 UI 信号验证出发链：
#   主菜单出发钮 → 选关面板 → 困难档钮 → 第三关「出发」钮 → （祝福面板）→ 应进 PLAYING。
# 解锁前提用 Meta 内存直改（map_records["world_frost#1"] 达线，不落盘，收尾还原）——
# 真档无困难分档键，纯内存构造「上一关困难已通」形态（R254 探针同款口径）。
# 战斗照走真实输入链走位；不碰 hp/伤害；死亡自然死。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const SHOT_DIR := "E:/Code/Agent/Infinite-Fission/repo/docs/qa/r255-play/"
const TIMEOUT_S := 300.0             # 困难局硬上限（到点真实 UI 暂停退出）

var _tree: SceneTree
var _gl: GameLoop = null
var _menu: MenuScreen = null
var _shot_n := 10               # 接局 A（combat-01~10）之后编号
var _t0_msec := 0
var _el_prev := 0.0

var _card_opens := 0
var _card_was_open := false
var _over := false
var _wave_shot := {}
var _records_bk: Dictionary = {}
var _blessing_bk := &""


func run(p_tree: SceneTree) -> void:
	_tree = p_tree
	_t0_msec = Time.get_ticks_msec()
	print("══ QA-play R255 局B：困难·紫晶魔域（第三关）出发链 ══")
	var main: Node = load(MAIN_SCENE).instantiate()
	p_tree.root.add_child(main)

	var boot_deadline := _el() + 60.0
	while _el() < boot_deadline:
		await p_tree.process_frame
		_gl = _find_loop()
		if _gl != null and _gl.state == GameConst.GameStatus.MENU:
			break
	if _gl == null or _gl.state != GameConst.GameStatus.MENU:
		print("PROBE-FAIL 未进 MENU")
		return
	_menu = _gl.menu_screen
	_records_bk = Meta.map_records.duplicate(true)
	_blessing_bk = Meta.blessing_trait()

	# ── 构造「上一关（寒霜冰原）困难已通」内存形态（不落盘）──
	var had_key := Meta.map_records.has("world_frost#1")
	Meta.map_records["world_frost#1"] = {"best_wave": 15, "best_kills": 300, "best_level": 20, "endless_depth": 0}
	print("[B] 解锁判据：unlocked(demon,HARD)=%s（构造前=%s）· unlocked(frost,HARD)=%s"
		% [Meta.is_map_unlocked(&"world_demon", 1), Meta.is_map_unlocked(&"world_demon", 1) if had_key else false,
			Meta.is_map_unlocked(&"world_frost", 1)])

	# ── 步骤1：主菜单「出发！」→ 选关面板 ──
	var start_btn: Button = _menu.get("_start_btn")
	start_btn.pressed.emit()
	await p_tree.process_frame
	await p_tree.process_frame

	# ── 步骤2：难度行「困难」按钮（真实 pressed 信号 → _on_difficulty_pick(1) 重建行） ──
	var diff_btns: Array = _menu.get("_diff_btns")
	if diff_btns.size() < 2 or (diff_btns[1] as Button).disabled:
		print("PROBE-FAIL 困难档按钮不可用（normal_cleared=%s）" % Meta.normal_cleared())
		_restore_meta(had_key)
		return
	(diff_btns[1] as Button).pressed.emit()
	await p_tree.process_frame
	await p_tree.process_frame
	print("[B] 已切困难档（selected=%d）" % int(_menu.get("_sel_difficulty")))
	await _shot("选关面板·困难档（第三关应有出发钮）")

	# ── 步骤3：第三行（紫晶魔域）「出发」按钮 ──
	var go_btn := _find_row_go_button("3")
	if go_btn == null:
		print("PROBE-FAIL 第三关出发按钮缺失（解锁链失败）")
		_restore_meta(had_key)
		return
	print("[B] 点第三关出发钮 → 观察终态（R254-2：曾回主页）")
	go_btn.pressed.emit()

	# ── 步骤4：祝福面板（R262 全档池，默认签=困难档紫）→ 截图 → 不选祝福直接出发（真实按钮） ──
	var blessed := false
	for i in range(15):
		await p_tree.process_frame
		if _gl.blessing_pick_ui != null and _gl.blessing_pick_ui.is_open():
			blessed = true
			break
	if blessed:
		await _shot("祝福面板·R262 全档池默认紫签（第三关出发后）")
		var confirm_btn := _find_btn(_gl.blessing_pick_ui, "BlessingGoButton")
		if confirm_btn != null:
			confirm_btn.pressed.emit()
			print("[B] 祝福面板 → 出发（未选词条=空选合法）")
	else:
		print("[B] 祝福池空直通")

	# ── 出发链终态判定 ──
	for i in range(120):
		await p_tree.process_frame
		if _gl.state == GameConst.GameStatus.PLAYING:
			break
		if _gl.state == GameConst.GameStatus.MENU:
			break
	var verdict := "PLAYING（出发链正常）" if _gl.state == GameConst.GameStatus.PLAYING \
		else "state=%d（非 PLAYING——出发链异常！）" % _gl.state
	print("[B] ★出发链终态：%s · map=%s" % [verdict, str(_gl.current_map_id)])
	if _gl.state != GameConst.GameStatus.PLAYING:
		await _shot("出发后异常态（%s）" % verdict)
		_restore_meta(had_key)
		return

	# ── 步骤5：真实打 1-2 波 + 死亡/超时结算 ──
	var wave_prev := 0
	while not _over:
		await p_tree.process_frame
		var st: int = _gl.state
		var el := _el()
		if st == GameConst.GameStatus.PLAYING or st == GameConst.GameStatus.LEVEL_UP:
			_drive_move()
		var w: int = _gl.wave_director.current_wave
		if w != wave_prev:
			var hp_txt := "?"
			if _gl.player != null and is_instance_valid(_gl.player):
				hp_txt = "%d/%d" % [int(_gl.player.hp), int(_gl.player.max_hp)]
			print("[B] wave %d → %d（t=%.1fs hp=%s lv%d）"
				% [wave_prev, w, el, hp_txt, _gl.player.level if _gl.player != null else -1])
			wave_prev = w
		if st == GameConst.GameStatus.PLAYING and w >= 2 and not _wave_shot.has(2):
			_wave_shot[2] = true
			await _shot("困难魔域·战斗中 wave%d" % w)
		if st == GameConst.GameStatus.LEVEL_UP:
			var card_open: bool = _gl.card_select_ui.is_open
			if card_open and not _card_was_open:
				_card_was_open = true
				_card_opens += 1
				await _shot("困难局选卡#%d" % _card_opens)   # 之后交给 auto_select_on
			elif not card_open:
				_card_was_open = false
		if st == GameConst.GameStatus.GAME_OVER:
			_over = true
			await _on_game_over()
		if el > TIMEOUT_S and not _over:
			_over = true
			await _timeout_exit()

	await _back_to_menu()
	_restore_meta(had_key)
	print("[B] 结束：选卡 %d 次" % _card_opens)
	print("══ 局B done（%.1fs）══" % _el())


func _on_game_over() -> void:
	var dead_wave: int = _gl.wave_director.current_wave
	print("[B] 玩家死亡（wave=%d）→ 困难局结算屏" % dead_wave)
	for i in range(30):
		await _tree.process_frame
	await _shot("困难局死亡结算（wave=%d）" % dead_wave)


func _timeout_exit() -> void:
	print("[B] 超时 %.0fs——主动暂停退出" % TIMEOUT_S)
	var pause_btn: Button = _gl.hud.get("_pause_btn")
	if pause_btn != null:
		pause_btn.pressed.emit()
		for i in range(20):
			await _tree.process_frame
		await _shot("困难局·暂停面板（超时退出）")


func _back_to_menu() -> void:
	for i in range(60):
		await _tree.process_frame
	for host in [_gl.game_over_screen, _gl.pause_overlay]:
		if host == null:
			continue
		var mb := _find_btn(host, "MenuButton")
		if mb != null and mb.visible:
			print("[B] 点结算/暂停「回主菜单」按钮")
			mb.pressed.emit()
			break
	for i in range(120):
		await _tree.process_frame
		if _gl.state == GameConst.GameStatus.MENU:
			break
	print("[B] 回主菜单 state=%d（1=MENU——GameStatus 枚举序 BOOT=0/MENU=1）" % _gl.state)


var _nav_t := Vector2(360.0, 940.0)
var _nav_left := 0.0

func _drive_move() -> void:
	var pl: Node2D = _gl.player
	if pl == null or not is_instance_valid(pl):
		return
	var el := _el()
	_nav_left -= (el - _el_prev)
	_el_prev = el
	if _nav_left <= 0.0 or _nav_t.distance_to(pl.global_position) < 48.0:
		_nav_t = Vector2(randf_range(150.0, 570.0), randf_range(790.0, 1140.0))
		_nav_left = randf_range(0.45, 1.0)
	var to := _nav_t - pl.global_position
	if to.length() < 2.0:
		return
	var ev := InputEventScreenDrag.new()
	ev.index = 0
	ev.relative = to.normalized() * minf(5.5, to.length())
	Input.parse_input_event(ev)


func _el() -> float:
	return (Time.get_ticks_msec() - _t0_msec) / 1000.0


func _find_loop() -> GameLoop:
	for c in _tree.root.get_children():
		if c is GameLoop:
			return c
	return null


func _find_row_go_button(p_idx: String) -> Button:
	var panel_list: Container = _menu.get("_panel_list")
	for row in panel_list.get_children():
		if not (row is Panel):
			continue
		var idx_l: Label = null
		var go: Button = null
		for sub in (row as Panel).get_children():
			if sub is Label and (sub as Label).position == Vector2(18.0, 32.0):
				idx_l = sub
			if sub is Button and (sub as Button).text == "出发":
				go = sub
		if idx_l != null and go != null and idx_l.text == p_idx:
			return go
	return null


func _find_btn(p_node: Node, p_name: String) -> Button:
	if p_node is Button and p_node.name == p_name:
		return p_node
	for c in p_node.get_children():
		var r := _find_btn(c, p_name)
		if r != null:
			return r
	return null


func _shot(p_tag: String) -> void:
	_shot_n += 1
	await _tree.process_frame
	var img := _tree.root.get_texture().get_image()
	var path := "%scombat-%02d.png" % [SHOT_DIR, _shot_n]
	img.save_png(path)
	print("  SHOT#%02d [%s] -> %s (%dx%d)" % [_shot_n, p_tag, path, img.get_width(), img.get_height()])


func _restore_meta(p_had_key: bool) -> void:
	# 真档保护：records 还原（构造键按备份回滚）+ 祝福记忆还原
	Meta.map_records.clear()
	for k in _records_bk:
		Meta.map_records[k] = _records_bk[k]
	if _blessing_bk == &"":
		Meta.clear_blessing_trait()
	else:
		Meta.set_blessing_trait(_blessing_bk)
	print("[B] Meta 内存已还原（构造键存在=%s→%s）"
		% [p_had_key, Meta.map_records.has("world_frost#1")])
