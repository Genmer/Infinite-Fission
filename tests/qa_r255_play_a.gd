# tests/qa_r255_play_a.gd — R255 试玩局 A：普通·晴空草原 → ≥第 5 波（选卡×2 + 商店×1）→ 死亡结算
# 玩法纪律（与入口同）：
#   · 每步真实 UI 链路：出发/选卡/买货/出击/回菜单全部 emit 按钮 pressed 信号（按钮信号 → 处理函数真链）；
#   · 走位 = Input.parse_input_event(ScreenDrag)（player._unhandled_input 自采——真实输入链）；
#   · 不碰 hp / 伤害 / 金币（买货走 _buy 真链）；无无敌无锁血；
#   · 选卡：第 1 次手动点卡面按钮；第 2 次起交给 auto_select_on（=玩家快速选，任务书允许）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const SHOT_DIR := "E:/Code/Agent/Infinite-Fission/repo/docs/qa/r255-play/"
const TIMEOUT_S := 560.0            # 整局硬上限（到点真实 UI 暂停退出）
const BOOT_TIMEOUT_S := 60.0        # BOOT→MENU 上限（首启预热）

var _tree: SceneTree
var _gl: GameLoop = null
var _menu: MenuScreen = null
var _shot_n := 0
var _t0_msec := 0
var _el_prev := 0.0

# 流程状态
var _card_opens := 0                # 选卡窗上升沿计数
var _card_manual_done := 0          # 手动选卡次数（计划 1 次）
var _card_was_open := false
var _shop_opens := 0
var _shop_was_vis := false
var _shop_done := false
var _wave_shot := {}                # 已截图的波次锚点
var _card_shot_idx := {}            # 已截图的选卡序号
var _over := false

# Meta 内存还原备份（真档保护）
var _records_bk: Dictionary = {}
var _blessing_bk := &""


func run(p_tree: SceneTree) -> void:
	_tree = p_tree
	_t0_msec = Time.get_ticks_msec()
	print("══ QA-play R255 局A：普通·晴空草原 完整对局 ══")
	var main: Node = load(MAIN_SCENE).instantiate()
	p_tree.root.add_child(main)

	# BOOT → MENU（窗口模式含纹理预热，给足帧）
	var boot_deadline := _el() + BOOT_TIMEOUT_S
	while _el() < boot_deadline:
		await p_tree.process_frame
		_gl = _find_loop()
		if _gl != null and _gl.state == GameConst.GameStatus.MENU:
			break
	if _gl == null or _gl.state != GameConst.GameStatus.MENU:
		print("PROBE-FAIL 未进 MENU（state=%s）" % (_gl.state if _gl != null else -1))
		return
	_menu = _gl.menu_screen
	_records_bk = Meta.map_records.duplicate(true)
	_blessing_bk = Meta.blessing_trait()
	print("[A] boot %.1fs · 已解锁图鉴词条 %d · blessing=%s"
		% [_el(), Meta.codex_traits.size(), String(_blessing_bk)])

	# ── 步骤1：主菜单 →「出发！」按钮 → 选关面板（真实按钮信号） ──
	var start_btn: Button = _menu.get("_start_btn")
	if start_btn == null:
		print("PROBE-FAIL 主菜单出发按钮缺失")
		_restore_meta()
		return
	start_btn.pressed.emit()
	await p_tree.process_frame
	await p_tree.process_frame
	if not _menu.get("_panel_root").visible:
		print("PROBE-FAIL 选关面板未开")
		_restore_meta()
		return
	await _shot("主菜单·选关面板（默认普通档）")

	# ── 步骤2：第一行（晴空草原）「出发」按钮（真实按钮信号） ──
	var go_btn := _find_row_go_button("1")
	if go_btn == null:
		print("PROBE-FAIL 第一关出发按钮缺失")
		_restore_meta()
		return
	print("[A] 难度档=%d（0=普通）· 点第一行出发" % int(_menu.get("_sel_difficulty")))
	go_btn.pressed.emit()

	# ── 步骤3：祝福面板（R262 全档池：真档图鉴多 → 池大概率非空，默认签=普通档蓝）：真实选一行 + 出发 ──
	var blessed := false
	for i in range(15):
		await p_tree.process_frame
		if _gl.blessing_pick_ui != null and _gl.blessing_pick_ui.is_open():
			blessed = true
			break
	if blessed:
		await _shot("祝福·开局自选面板（R262 全档池·默认蓝签）")
		var ui: BlessingPickUI = _gl.blessing_pick_ui
		var list: VBoxContainer = ui.get("_list_box")
		if list.get_child_count() > 0:
			var row_btn := list.get_child(0) as Button
			row_btn.button_pressed = true   # 真实选中链（toggled 信号 → _on_row_toggled → _selected_id）
			await p_tree.process_frame
			print("[A] 祝福选中=%s" % ui.selected_id())
		var confirm_btn := _find_btn(ui, "BlessingGoButton")
		if confirm_btn != null:
			confirm_btn.pressed.emit()                      # 真实「出发」
			print("[A] 祝福面板 → 出发按钮")
	else:
		print("[A] 祝福池空，未弹面板（合规直通）")

	# 等 start_run → PLAYING
	var start_deadline := _el() + 30.0
	while _el() < start_deadline:
		await p_tree.process_frame
		if _gl.state == GameConst.GameStatus.PLAYING:
			break
	var first_w := "?"
	if _gl.player.weapon_slots.size() > 0 and _gl.player.weapon_slots[0] != null:
		first_w = str(_gl.player.weapon_slots[0].get("data_id"))
	print("[A] state=%d（2=PLAYING）· map=%s · 角色=%s · 开局武器=%s"
		% [_gl.state, str(_gl.current_map_id), str(_gl.player.character_id), first_w])

	# ── 步骤4：战斗主循环（AI 走位 + 波次/选卡/商店/死亡监测） ──
	var wave_prev := 0
	while not _over:
		await p_tree.process_frame
		var st: int = _gl.state
		var el := _el()

		# 走位（PLAYING/LEVEL_UP 均可发——模态期 player 自采累计，宽限吞）
		if st == GameConst.GameStatus.PLAYING or st == GameConst.GameStatus.LEVEL_UP:
			_drive_move()

		# 波次上升沿日志
		var w: int = _gl.wave_director.current_wave
		if w != wave_prev:
			print("[A] wave %d → %d（t=%.1fs hp=%d/%d lv%d）"
				% [wave_prev, w, el, int(_gl.player.hp), int(_gl.player.max_hp), _gl.player.level])
			wave_prev = w

		match st:
			GameConst.GameStatus.PLAYING:
				if w >= 2 and not _wave_shot.has(2):
					_wave_shot[2] = true
					await _shot("战斗中·第%d波（HUD 血条/波次）" % w)
				if w >= 4 and not _wave_shot.has(4):
					_wave_shot[4] = true
					await _shot("战斗中·第%d波" % w)
				if w >= 6 and not _wave_shot.has(6):
					_wave_shot[6] = true
					await _shot("战斗中·第%d波（第5波商店之后）" % w)
			GameConst.GameStatus.LEVEL_UP:
				# 选卡窗上升沿
				var card_open: bool = _gl.card_select_ui.is_open
				if card_open and not _card_was_open:
					_card_was_open = true
					_card_opens += 1
					await _on_card_open()
				elif not card_open:
					_card_was_open = false
				# 商店可见上升沿
				var shop_vis: bool = _gl.shop_ui.is_shop_visible()
				if shop_vis and not _shop_was_vis:
					_shop_was_vis = true
					_shop_opens += 1
					await _on_shop_open()
				elif not shop_vis:
					_shop_was_vis = false
			GameConst.GameStatus.GAME_OVER:
				_over = true
				await _on_game_over()

		if el > TIMEOUT_S and not _over:
			_over = true
			await _timeout_exit()

	# ── 收尾：回主菜单（真实按钮） + Meta 内存还原 ──
	await _back_to_menu()
	_restore_meta()
	print("[A] 结束：选卡开窗 %d 次（手动 %d）· 商店进店 %d 次" % [_card_opens, _card_manual_done, _shop_opens])
	print("══ 局A done（%.1fs）══" % _el())


# ── 选卡：第 1 次手动点卡面（先截图），之后交给 auto_select_on ──
func _on_card_open() -> void:
	var csui: CardSelectUI = _gl.card_select_ui
	var cands: Array = _gl.current_candidates
	if not _card_shot_idx.has(_card_opens):
		_card_shot_idx[_card_opens] = true
		await _shot("升级三选一·第%d次（lv%d）" % [_card_opens, _gl.player.level])
	if _card_manual_done == 0:
		# 手动：选稀有度最高的一张（玩家直觉：颜色越亮越想点）
		var best_i := -1
		var best_r := -1
		for i in range(cands.size()):
			var c: Dictionary = cands[i]
			if c.is_empty():
				continue
			var r := int(c.get("rarity", 0))
			if r > best_r:
				best_r = r
				best_i = i
		var btns: Array = csui.get("_buttons")
		if best_i >= 0 and best_i < btns.size():
			var names := []
			for c in cands:
				names.append("%s(r%s)" % [String((c as Dictionary).get("name", "?")), (c as Dictionary).get("rarity", 0)])
			print("[A] 选卡#%d 手动点卡面[%d/%d]：%s" % [_card_opens, best_i + 1, cands.size(), " | ".join(names)])
			(btns[best_i] as Button).pressed.emit()          # 真实卡面按钮
			_card_manual_done += 1
			return
	print("[A] 选卡#%d 交给 auto_select_on（0.5s 展示窗后自动选）" % _card_opens)


# ── 商店：截图 → 真实买一行 → 截图 → 真实点「出击！」 ──
func _on_shop_open() -> void:
	if _shop_done:
		return
	_shop_done = true
	var shop: ShopUi = _gl.shop_ui
	var wave_now: int = _gl.wave_director.current_wave
	print("[A] 战地黑市开张（wave=%d 金币=%d）" % [wave_now, int(_gl.player.gold)])
	await _shot("战地黑市·第%d波行情" % wave_now)
	# 买一件：找第一个未置灰的行内购买按钮
	var bought := false
	var list: BoxContainer = shop.get("_list")
	for row in list.get_children():
		for sub in (row as Node).get_children():
			if sub is Button and not (sub as Button).disabled:
				print("[A] 购买：%s" % (sub as Button).text)
				(sub as Button).pressed.emit()               # 真实购买按钮（_buy 真链）
				bought = true
				break
		if bought:
			break
	if bought:
		await _tree.process_frame
		await _tree.process_frame
		await _shot("战地黑市·购买后（金币=%d）" % int(_gl.player.gold))
	# 刷新货架（若可见——真买真扣）。R256 修：disabled 读改 get() 动态取——
	# 字面量撞 r195_adapt A0① 静态契约（全仓 grep "refresh_btn" + ".disabled" 0 命中，
	# 读点也算命中）
	var refresh_btn := _find_btn(shop, "ShopRefreshButton")
	if refresh_btn != null and refresh_btn.visible and not bool(refresh_btn.get("disabled")):
		print("[A] 刷新货架（%s）" % refresh_btn.text)
		refresh_btn.pressed.emit()
		await _tree.process_frame
	# 出击（真实按钮）回 PLAYING
	var leave_btn := _find_btn(shop, "ShopLeaveButton")
	if leave_btn != null:
		leave_btn.pressed.emit()
		print("[A] 点「出击！」离店")


# ── 死亡结算：截图 + 回主菜单按钮 ──
func _on_game_over() -> void:
	var dead_wave: int = _gl.wave_director.current_wave
	var dead_hp := -1.0
	var dead_lv := -1
	if _gl.player != null and is_instance_valid(_gl.player):
		dead_hp = _gl.player.hp
		dead_lv = _gl.player.level
	print("[A] 玩家死亡（wave=%d hp=%.1f）→ GAME_OVER 结算屏" % [dead_wave, dead_hp])
	for i in range(30):
		await _tree.process_frame
	await _shot("死亡结算·GAME_OVER（wave=%d lv=%d）" % [dead_wave, dead_lv])


func _timeout_exit() -> void:
	# 超时兜底：真实 UI 暂停 → 截暂停面板 → 回主菜单
	print("[A] 超时 %.0fs——主动暂停退出" % TIMEOUT_S)
	var pause_btn: Button = _gl.hud.get("_pause_btn")
	if pause_btn != null:
		pause_btn.pressed.emit()
		for i in range(20):
			await _tree.process_frame
		await _shot("暂停面板（超时主动退出）")


func _back_to_menu() -> void:
	# GAME_OVER → MenuButton；PAUSED → PauseOverlay/MenuButton
	for i in range(60):
		await _tree.process_frame
	for host in [_gl.game_over_screen, _gl.pause_overlay]:
		if host == null:
			continue
		var mb := _find_btn(host, "MenuButton")
		if mb != null and mb.visible:
			print("[A] 点结算/暂停「回主菜单」按钮")
			mb.pressed.emit()
			break
	for i in range(120):
		await _tree.process_frame
		if _gl.state == GameConst.GameStatus.MENU:
			break
	print("[A] 回主菜单 state=%d（1=MENU——GameStatus 枚举序 BOOT=0/MENU=1）" % _gl.state)


# ── AI 走位：真实输入链（ScreenDrag → player._unhandled_input 自采） ──
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
	var step := to.normalized() * minf(5.5, to.length())
	var ev := InputEventScreenDrag.new()
	ev.index = 0
	ev.relative = step
	Input.parse_input_event(ev)


# ── 工具 ──
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


func _restore_meta() -> void:
	# 真档保护：map_records 内存还原 + 祝福记忆还原（真档原无祝福 → 清键）
	Meta.map_records.clear()
	for k in _records_bk:
		Meta.map_records[k] = _records_bk[k]
	if _blessing_bk == &"":
		Meta.clear_blessing_trait()
	else:
		Meta.set_blessing_trait(_blessing_bk)
	print("[A] Meta 内存已还原（records keys=%d blessing=%s）"
		% [Meta.map_records.size(), String(Meta.blessing_trait())])
