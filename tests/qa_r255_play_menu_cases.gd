# tests/qa_r255_play_menu_cases.gd — R255 玩家大厅漫游用例体（入口运行时加载）
# 全程真实 UI 链路：Button.pressed.emit()（按钮信号）→ 面板开合；截图经
# RenderingServer.frame_post_draw 后 root.get_texture().get_image().save_png()。
# 不点任何写档/开局按钮；存档保护由外层快照还原负责。
# 节点路径真源：menu_screen.gd _build_ui/_build_lobby/_build_panel、
# settings_panel.gd _build_ui、game_loop.gd _wire 后段（menu_screen/settings_panel 接线）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const OUT_DIR := "E:/Code/Agent/Infinite-Fission/repo/docs/qa/r255-play"

var _tree: SceneTree = null
var _gl: Node = null                 # GameLoop（duck 型——不直引工程类）
var _menu: Node = null               # MenuScreen CanvasLayer
var _shot_seq := 0


func run(p_tree: SceneTree) -> void:
	_tree = p_tree
	print("══ R255 play: 大厅全漫游（真实 UI 链路）══")
	var main: Node = load(MAIN_SCENE).instantiate()
	p_tree.root.add_child(main)
	for i in range(90):                      # BOOT→MENU + 首帧绘制 + 图鉴预建泵跑几拍
		await p_tree.process_frame
	for c in p_tree.root.get_children():
		if String(String(c.name)) == "Main" and c.get_script() != null:
			_gl = c
			break
	if _gl == null:
		print("PROBE-FAIL no Main/GameLoop")
		return
	_menu = _gl.get("menu_screen")
	if _menu == null:
		print("PROBE-FAIL no menu_screen")
		return
	if not bool(_menu.call("is_menu_visible")):
		print("PROBE-FAIL boot 后菜单不可见（state=%s）" % str(_gl.get("state")))
		return

	# ── ① 主菜单（含「继续上次进度」/吉祥物/七个入口行文案取证） ──
	var start_b := _mbtn("MenuRoot/StartButton")
	var cont_b := _mbtn("MenuRoot/ContinueButton")
	print("START btn=%s text=%s" % [start_b != null, start_b.text if start_b else "?"])
	print("CONTINUE visible=%s text=%s" % [cont_b.visible if cont_b else "?",
		cont_b.text if cont_b else "?"])
	for kind in ["codex", "ach", "records", "char", "upgrade", "daily", "settings"]:
		var b := _mbtn("MenuRoot/Lobby_%s" % kind)
		if b != null:
			print("LOBBY[%s] text=%s disabled=%s" % [kind, b.text, b.disabled])
	await _settle(0.4)
	await _shot("menu-01")

	# ── ② 出发 → 选关面板：普通档（五图解锁/星标态） ──
	await _click(start_b, "出发！(StartButton)")
	await _settle(0.5)
	_dump_diff_row("普通档")
	_dump_map_rows("普通")
	await _shot("menu-02")

	# ── ③ 难度切到 困难：分档键空 → 地图 2-5 锁定态 ──
	var hard_b := _diff_btn("困难")
	if hard_b == null:
		print("PROBE-FAIL 找不到「困难」难度钮")
		return
	await _click(hard_b, "难度·困难")
	await _settle(0.4)
	_dump_diff_row("困难档")
	_dump_map_rows("困难")
	await _shot("menu-03")

	# ── ④ 难度切到 地狱 ──
	var hell_b := _diff_btn("地狱")
	if hell_b != null:
		await _click(hell_b, "难度·地狱")
		await _settle(0.4)
		_dump_diff_row("地狱档")
		_dump_map_rows("地狱")
		await _shot("menu-04")
	# 回普通（面板后续页面共用壳，_sel_difficulty 会影响选人页首发候选展示）
	var norm_b := _diff_btn("普通")
	if norm_b != null:
		await _click(norm_b, "难度·普通(复位)")
		await _settle(0.2)
	await _click(_mbtn("MenuRoot/LobbyPanelRoot/LobbyPanel/LobbyCloseButton"), "返回大厅")
	await _settle(0.3)

	# ── ⑤ 图鉴五页逐页看 ──
	await _click(_mbtn("MenuRoot/Lobby_codex"), "图鉴")
	await _settle(0.5)
	print("[CODEX 怪物] 行数=%s" % _codex_row_count())
	await _shot("menu-05")
	for tab in ["武器", "祝福", "反应", "遗物"]:
		await _click(_mbtn("MenuRoot/LobbyPanelRoot/LobbyPanel/Tab_%s" % tab), "图鉴页签·%s" % tab)
		await _settle(0.35)
		print("[CODEX %s] 行数=%s" % [tab, _codex_row_count()])
		await _shot("menu-0%d" % (6 + ["武器", "祝福", "反应", "遗物"].find(tab)))
	await _click(_mbtn("MenuRoot/LobbyPanelRoot/LobbyPanel/LobbyCloseButton"), "返回大厅")
	await _settle(0.3)

	# ── ⑥ 成就（类别页签 + 翻页） ──
	await _click(_mbtn("MenuRoot/Lobby_ach"), "成就")
	await _settle(0.5)
	print("[ACH 全部] %s" % _ach_pager_text())
	await _shot("menu-10")
	await _click(_mbtn("MenuRoot/LobbyPanelRoot/LobbyPanel/AchTab_猎杀"), "成就页签·猎杀")
	await _settle(0.3)
	print("[ACH 猎杀] %s" % _ach_pager_text())
	await _shot("menu-11")
	var next_b := _mbtn("MenuRoot/LobbyPanelRoot/LobbyPanel/AchNextButton")
	if next_b != null and not next_b.disabled:
		await _click(next_b, "成就·下一页")
		await _settle(0.25)
		print("[ACH 翻页] %s" % _ach_pager_text())
	await _click(_mbtn("MenuRoot/LobbyPanelRoot/LobbyPanel/LobbyCloseButton"), "返回大厅")
	await _settle(0.3)

	# ── ⑦ 历史记录 ──
	await _click(_mbtn("MenuRoot/Lobby_records"), "记录")
	await _settle(0.5)
	print("[RECORDS] 行数=%d" % _panel_rows().size())
	await _shot("menu-12")
	await _click(_mbtn("MenuRoot/LobbyPanelRoot/LobbyPanel/LobbyCloseButton"), "返回大厅")
	await _settle(0.3)

	# ── ⑧ 选人 ──
	await _click(_mbtn("MenuRoot/Lobby_char"), "角色")
	await _settle(0.5)
	_dump_char_rows()
	await _shot("menu-13")
	await _click(_mbtn("MenuRoot/LobbyPanelRoot/LobbyPanel/LobbyCloseButton"), "返回大厅")
	await _settle(0.3)

	# ── ⑨ 局外养成 ──
	await _click(_mbtn("MenuRoot/Lobby_upgrade"), "养成")
	await _settle(0.5)
	print("[UPGRADE] 行数=%d" % _panel_rows().size())
	await _shot("menu-14")
	await _click(_mbtn("MenuRoot/LobbyPanelRoot/LobbyPanel/LobbyCloseButton"), "返回大厅")
	await _settle(0.3)

	# ── ⑩ 每日挑战 ──
	await _click(_mbtn("MenuRoot/Lobby_daily"), "每日挑战")
	await _settle(0.5)
	print("[DAILY] 行数=%d" % _panel_rows().size())
	await _shot("menu-15")
	await _click(_mbtn("MenuRoot/LobbyPanelRoot/LobbyPanel/LobbyCloseButton"), "返回大厅")
	await _settle(0.3)

	# ── ⑪ 设置（settings_requested 信号 → GameLoop → SettingsPanel.open） ──
	await _click(_mbtn("MenuRoot/Lobby_settings"), "设置")
	await _settle(0.5)
	var sp: Node = _gl.get("settings_panel")
	print("[SETTINGS] is_open=%s" % str(sp.call("is_open") if sp != null else "null"))
	await _shot("menu-16")
	var sc := _mbtn("SettingsRoot/SettingsCard/SettingsCloseButton", sp)
	await _click(sc, "设置·返回")
	await _settle(0.3)
	print("[SETTINGS] 关闭后 is_open=%s 菜单可见=%s" % [
		str(sp.call("is_open") if sp != null else "?"),
		str(_menu.call("is_menu_visible"))])

	print("══ TOUR DONE shots=%d ══" % _shot_seq)


# ── helpers ─────────────────────────────────────────────
func _mbtn(p_path: String, p_from: Node = null) -> Button:
	var host: Node = p_from if p_from != null else _menu
	var b := host.get_node_or_null(p_path) as Button
	if b == null:
		print("PROBE-WARN 找不到按钮：%s" % p_path)
	return b


func _click(p_btn: Button, p_label: String) -> void:
	if p_btn == null:
		print("CLICK-FAIL | %s（节点缺失）" % p_label)
		return
	var t0 := Time.get_ticks_usec()
	p_btn.pressed.emit()                     # 真实按钮信号（面板开合由信号链驱动）
	await _tree.process_frame
	await _tree.process_frame
	print("CLICK %-14s → %5.1f ms（含 2 帧重建）" % [p_label, (Time.get_ticks_usec() - t0) / 1000.0])


func _settle(p_sec: float) -> void:
	await _tree.create_timer(p_sec).timeout


func _shot(p_name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := _tree.root.get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, p_name]
	var err := img.save_png(path)
	_shot_seq += 1
	print("SHOT %-9s → %s (%dx%d err=%d)" % [p_name, path, img.get_width(), img.get_height(), err])


func _panel_rows() -> Array:
	var list := _menu.get_node_or_null(
		"MenuRoot/LobbyPanelRoot/LobbyPanel/LobbyScroll/LobbyList")
	if list == null:
		return []
	return list.get_children()


func _diff_btn(p_text: String) -> Button:
	var row := _menu.get_node_or_null(
		"MenuRoot/LobbyPanelRoot/LobbyPanel/LobbyScroll/LobbyList/DifficultyRow")
	if row == null:
		return null
	for sub in row.get_children():
		if sub is Button and (sub as Button).text == p_text:
			return sub
	return null


func _dump_diff_row(p_tag: String) -> void:
	var row := _menu.get_node_or_null(
		"MenuRoot/LobbyPanelRoot/LobbyPanel/LobbyScroll/LobbyList/DifficultyRow")
	if row == null:
		print("[DIFF:%s] DifficultyRow 缺失" % p_tag)
		return
	var states := PackedStringArray()
	var desc := ""
	for sub in row.get_children():
		if sub is Button:
			var b := sub as Button
			states.append("%s(dis=%s,亮=%s)" % [b.text, str(b.disabled),
				"白" if b.modulate == Color.WHITE else "灰"])
		if sub is Label and (sub as Label).name == "DiffDesc":
			desc = String((sub as Label).text)
	print("[DIFF:%s] %s | %s" % [p_tag, " ".join(states), desc])


func _dump_map_rows(p_tag: String) -> void:
	var out := []
	var go_total := 0
	for row in _panel_rows():
		if not (row is Panel) or String(row.name) == "DifficultyRow":
			continue
		var has_go := false
		var name_txt := ""
		for sub in row.get_children():
			if sub is Button and (sub as Button).text == "出发":
				has_go = true
			if sub is Label and (sub as Label).position == Vector2(64.0, 14.0):
				name_txt = String((sub as Label).text)
		if name_txt != "":
			if has_go:
				go_total += 1
			out.append("%s[%s]" % [name_txt, "出发" if has_go else "锁"])
	print("[MAP:%s] 出发钮总数=%d" % [p_tag, go_total])
	for line in out:
		print("        %s" % line)


func _codex_row_count() -> int:
	var n := 0
	for c in _panel_rows():
		var nm := String(c.name)
		if nm.begins_with("CodexRow_") or nm.begins_with("RxnRow_"):
			n += 1
	return n


func _ach_pager_text() -> String:
	var l := _menu.get_node_or_null(
		"MenuRoot/LobbyPanelRoot/LobbyPanel/AchPageLabel") as Label
	return String(l.text) if l != null else "?"


func _dump_char_rows() -> void:
	var n := 0
	var picked := ""
	for row in _panel_rows():
		if not (row is Panel):
			continue
		n += 1
		for sub in row.get_children():
			if sub is Label and (sub as Label).position == Vector2(74.0, 12.0):
				var t := String((sub as Label).text)
				if n <= 3 or t.contains("当前"):
					print("        CHAR%d %s" % [n, t])
				if t.contains("当前"):
					picked = t
	print("[CHAR] 行数=%d 当前=%s" % [n, picked])
