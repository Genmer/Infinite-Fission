extends RefCounted
# R263 修复轮 QA 复核 cases（配套口 qa_r263_fix_probe.gd）。
# X1 置灰可感知（评审-2）：modulate.a=0.45 + 余额回账后重建恢复 1.0
# X2 附赠标记新载体（评审-6）：名字行尾「附赠·X」+ desc 纯效果文本 + 全附赠行名字实测宽<420
#     （clip 截断风险实测——附缀信息不得被 clip 吃掉）
# X3 每日不误播评审-5 新横幅（每日守卫先于未购分支）
# X4 结算屏双口径（评审-3）：死亡精确 + 胜利「至少 +N（当前余额 M）」
# B4' 评审-5 未购重开新横幅——已由 gap_probe B4 覆盖（精确全文），此处不重复。
# 测试卫生：快照+档字节还原。
var _pass := 0
var _fail := 0
var _failures: Array[String] = []

var _snap: Dictionary = {}
var _had_save: bool = false
var _save_text: String = ""


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  ok | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("  FAIL | %s %s" % [p_name, p_detail])


func _goto_menu(p_gl) -> void:
	if p_gl.state == GameConst.GameStatus.MENU:
		return
	p_gl.state = GameConst.GameStatus.PAUSED
	p_gl.quit_to_menu()


func _start_normal(p_gl, p_difficulty: int = 0) -> void:
	_goto_menu(p_gl)
	p_gl._difficulty = p_difficulty
	p_gl.current_map_id = MapTable.FIRST_MAP_ID
	p_gl.start_run()


func _trait_layers_total(p_gl, p_tid: StringName) -> int:
	var n := 0
	for w_v: Variant in p_gl.player.weapon_slots:
		var w := w_v as WeaponBase
		if w == null or not is_instance_valid(w) or w.trait_stack == null:
			continue
		for m in w.trait_stack.traits:
			if m.data != null and m.data.id == p_tid:
				n += int(m.layers)
	return n


func _goto_row(p_ui, p_tid: String) -> Button:
	for _hop in range(12):
		var row: Button = p_ui._row_by_id(p_tid)
		if row != null:
			return row
		if p_ui._page_next_btn == null or not p_ui._page_next_btn.visible or p_ui._page_next_btn.disabled:
			break
		p_ui._on_page_next()
	return null


func run(p_tree: SceneTree) -> void:
	var gl_script: GDScript = load("res://scripts/loop/game_loop.gd")
	var gl = gl_script.new()
	gl.name = "GameLoopForR263Fix"
	p_tree.get_root().add_child(gl)
	gl.set_physics_process(false)
	var waited := 0
	while not gl.boot_ready and waited < 600:
		await p_tree.process_frame
		waited += 1
	_check("boot：菜单就绪", gl.boot_ready)
	if not gl.boot_ready:
		_summary()
		return
	_take_snap()
	for tid_v: Variant in gl.registry.traits.keys():
		Meta.codex_traits[String(tid_v)] = true
	Meta.character_id = &"sentinel"
	Meta.custom_weapon_id = ""

	# ══ X1 置灰可感知（评审-2）══
	Meta.stardust = 25
	var ui = gl.blessing_pick_ui
	var pool_p: Array[StringName] = gl._blessing_pool(2)      # 紫档（ORBIT_SWORD 30>25 置灰）
	ui.close()
	ui.open(pool_p, "", 0, &"W1_pistol")
	await p_tree.process_frame
	var row_p: Button = _goto_row(ui, "MEC_ORBIT_SWORD")
	var grey_ok := false
	if row_p != null:
		grey_ok = row_p.disabled and is_equal_approx(row_p.modulate.a, 0.45)
	_check("X1 置灰行：disabled + 整行 modulate.a=0.45（可感知变淡）",
		grey_ok, "disabled=%s a=%.3f" % [str(row_p.disabled if row_p != null else null),
			row_p.modulate.a if row_p != null else -1.0])
	var pool_b1: Array[StringName] = gl._blessing_pool(1)
	ui.close()
	ui.open(pool_b1, "", 0, &"W1_pistol")
	await p_tree.process_frame
	var row_b: Button = ui._row_by_id("AFF_CRIT_DMG")
	_check("X1 可负担对照：蓝档行 modulate.a=1.0（不误伤）",
		row_b != null and not row_b.disabled and is_equal_approx(row_b.modulate.a, 1.0),
		"a=%.3f" % (row_b.modulate.a if row_b != null else -1.0))
	# 余额回账后重开：签名含 stardust → 行重建恢复可点
	Meta.stardust = 200
	ui.close()
	ui.open(pool_p, "", 0, &"W1_pistol")
	await p_tree.process_frame
	var row_p2: Button = _goto_row(ui, "MEC_ORBIT_SWORD")
	_check("X1 回账重建：余额 200 后紫行恢复可点（modulate 1.0·缓存签名生效）",
		row_p2 != null and not row_p2.disabled and is_equal_approx(row_p2.modulate.a, 1.0),
		"disabled=%s a=%.3f" % [str(row_p2.disabled if row_p2 != null else null),
			row_p2.modulate.a if row_p2 != null else -1.0])
	ui.close()

	# ══ X2 附赠标记新载体（评审-6）══
	Meta.stardust = 77
	var pool_all: Array[StringName] = gl._blessing_pool()
	ui.open(pool_all, "", 0, &"W1_pistol")
	ui._filter_rarity = -1
	ui._apply_filter()
	ui._rebuild_rows()
	await p_tree.process_frame
	var name_max_w: float = 0.0
	var name_max_id := ""
	var gift_rows := 0
	var carrier_ok := true
	var carrier_detail := ""
	var seen: Dictionary = {}
	for _hop in range(16):
		for c in ui._list_box.get_children():
			var btn := c as Button
			if btn == null:
				continue
			var tid := String(btn.get_meta(&"trait_id"))
			if tid.is_empty() or seen.has(tid):
				continue
			seen[tid] = true
			var name_l: Label = null
			var desc_l: Label = null
			for sub in btn.get_children():
				var l := sub as Label
				if l == null:
					continue
				if l.position.y > 30.0:
					desc_l = l
				elif not l.text.begins_with("-"):
					name_l = l
			if name_l == null or desc_l == null:
				continue
			var is_gift: bool = name_l.text.contains("附赠·")
			if is_gift:
				gift_rows += 1
				if not name_l.text.contains("　附赠·") or desc_l.text.contains("附赠"):
					carrier_ok = false
					carrier_detail = "%s 载体异常 name='%s' desc='%s'" % [tid,
						name_l.text.substr(0, 20), desc_l.text.substr(0, 12)]
			var font := name_l.get_theme_font("font")
			var fsize: int = name_l.get_theme_font_size("font")
			var nw: float = font.get_string_size(name_l.text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, fsize).x if font != null else 0.0
			if nw > name_max_w:
				name_max_w = nw
				name_max_id = tid
		if ui._page_next_btn == null or not ui._page_next_btn.visible or ui._page_next_btn.disabled:
			break
		ui._on_page_next()
	_check("X2 附赠载体：附缀在名字行尾（全角空格分隔）+ desc 纯效果文本（24 附赠行）",
		carrier_ok and gift_rows == 24, "%s gift=%d" % [carrier_detail, gift_rows])
	_check("X2 截断风险实测：名字（含附缀）实测最大宽 %.0fpx < 框宽 420（附缀不被 clip 吃掉）"
		% name_max_w, name_max_w < 420.0, "max=%s %s" % [name_max_id, str(name_max_w)])
	print("  .. | X2 最长名字行 %s=%.0fpx / 420px" % [name_max_id, name_max_w])
	ui.close()

	# ══ X3 每日不误播评审-5 新横幅 ══
	Meta.stardust = 100
	Meta.set_blessing_trait(&"MEC_ORBIT_SWORD")               # 有记忆（评审-5 横幅的前置）
	_goto_menu(gl)
	gl._difficulty = 0
	gl._on_menu_start_daily()
	gl.state = GameConst.GameStatus.GAME_OVER
	var captured: Array = []
	var cb := func(t): captured.append(String(t))
	EventBus.mechanics_intro.connect(cb)
	gl.restart_run()
	EventBus.mechanics_intro.disconnect(cb)
	var daily_bless_lines: Array = []
	for chunk in captured:
		for line in String(chunk).split("\n"):
			if line.begins_with("【祝福】"):
				daily_bless_lines.append(line)
	_check("X3 每日重开：零祝福横幅（评审-5 新横幅不越过每日守卫）",
		daily_bless_lines.is_empty() and _trait_layers_total(gl, &"MEC_ORBIT_SWORD") == 0
			and Meta.stardust == 100,
		"lines=%s sd=%d" % [str(daily_bless_lines), Meta.stardust])

	# ══ X4 结算屏双口径（评审-3）══
	Meta.set_run_daily(false)
	Meta.set_run_difficulty(0)
	Meta.stardust = 40
	gl.hud.kills = 60
	gl.hud.wave = 12
	gl.game_over_screen.show_summary()
	var death_line: String = gl.game_over_screen.stardust_text()
	_check("X4 死亡屏精确口径：「◆ 星尘 +14（余额 40）」",
		death_line == "◆ 星尘 +14（余额 40）", "[%s]" % death_line)
	gl.game_over_screen.show_victory(true)
	var vict_line: String = gl.game_over_screen.stardust_text()
	_check("X4 胜利屏下限口径：「◆ 星尘 至少 +22（当前余额 40）」",
		vict_line == "◆ 星尘 至少 +22（当前余额 40）", "[%s]" % vict_line)
	Meta.set_run_daily(true)
	gl.game_over_screen.show_victory(false)
	_check("X4 每日屏无星尘行（口径不变）",
		gl.game_over_screen.stardust_text() == "", "[%s]" % gl.game_over_screen.stardust_text())
	Meta.set_run_daily(false)
	gl.game_over_screen.hide_screen()

	_restore_snap()
	RunSave.clear()
	gl.free()
	_summary()


func _take_snap() -> void:
	_snap = {
		"crystals": Meta.crystals,
		"stardust": Meta.stardust,
		"stardust_total": Meta.stardust_total,
		"records": Meta.records.duplicate(),
		"map_records": Meta.map_records.duplicate(),
		"daily_records": Meta.daily_records.duplicate(),
		"achievements": Meta.achievements_done.duplicate(),
		"codex_traits": Meta.codex_traits.duplicate(),
		"codex_weapons": Meta.codex_weapons.duplicate(),
		"blessing": Meta.blessing_trait_id,
		"character": Meta.character_id,
		"custom_weapon": Meta.custom_weapon_id,
	}
	var sp := Meta.save_path()
	_had_save = FileAccess.file_exists(sp)
	if _had_save:
		_save_text = FileAccess.get_file_as_string(sp)


func _restore_snap() -> void:
	Meta.crystals = _snap["crystals"]
	Meta.stardust = _snap["stardust"]
	Meta.stardust_total = _snap["stardust_total"]
	Meta.records = _snap["records"]
	Meta.map_records = _snap["map_records"]
	Meta.daily_records = _snap["daily_records"]
	Meta.achievements_done = _snap["achievements"]
	Meta.codex_traits = _snap["codex_traits"]
	Meta.codex_weapons = _snap["codex_weapons"]
	Meta.blessing_trait_id = _snap["blessing"]
	Meta.character_id = _snap["character"]
	Meta.custom_weapon_id = _snap["custom_weapon"]
	var sp := Meta.save_path()
	if _had_save:
		var f := FileAccess.open(sp, FileAccess.WRITE)
		if f != null:
			f.store_string(_save_text)
			f.close()
		Meta._load()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(sp))


func _summary() -> void:
	print("验收汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	for f in _failures:
		print("  FAIL | %s" % f)


func fail_count() -> int:
	return _fail
