extends RefCounted
# R263 QA 独立缝隙探针 cases（配套口 qa_r263_gap_probe.gd）。
# 覆盖开发提示的 7 个缝隙面（不与 dev 套件 qa_r263_gift/_stardust 重复断言口径）：
# A 存量紫/金记忆×余额 20 首局「星尘不足」横幅（§5.4 预期行为）+ 白/蓝边界不误伤
# B 横幅双文案（扣费局 / 已购重挂局 / 未购局短横幅·修轮评审-5；重开横幅经 EventBus 捕获——
#   restart_run emit 后即清 _run_intro_lines，直读数组恒空是探针坑）
# C 每日真实路径（面板不弹 + 结算屏无星尘行 + 零扣费，change_state 驱动真接线）
# D 面板价签列几何（(488,22)/宽 80/右缘 568≤572；desc 与价签文字零重叠；名字实测宽）
# E 池三态边界补充（MEC_PARALLEL_CAL 在池 / AFF_RANGE/AFF_CDR 出局 / 分档子池 / 解析器空参）
# F 已购位与槽上武器持久（quit→continue 恢复不二次扣；回菜单再出发=新扣费）
# G 扣费原子性（不足拒：无新武器无词条余额与档均不动；恰好=30 边界成功）
# H 大厅星尘行 + stardust_icon
# 测试卫生：快照内存+档字节，收尾还原（r263 dev 套件同款）。
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


func _slot_wid(p_gl, p_i: int) -> StringName:
	if p_i >= p_gl.player.weapon_slots.size():
		return StringName("")
	var w: WeaponBase = p_gl.player.weapon_slots[p_i] if p_i < p_gl.player.weapon_slots.size() else null
	if w == null or not is_instance_valid(w) or w.data == null:
		return StringName("")
	return StringName(String(w.data.id))


func _count_weapon(p_gl, p_wid: StringName) -> int:
	var n := 0
	for w_v: Variant in p_gl.player.weapon_slots:
		var w := w_v as WeaponBase
		if w != null and is_instance_valid(w) and w.data != null \
				and StringName(String(w.data.id)) == p_wid:
			n += 1
	return n


func _blessing_lines(p_gl) -> Array:
	var out: Array = []
	for l in p_gl._run_intro_lines:
		if String(l).begins_with("【祝福】"):
			out.append(String(l))
	return out


func _capture_restart_banner(p_gl) -> Array:
	# restart_run 在 emit_mechanics_intro 之后即清 _run_intro_lines——须经总线捕获。
	var captured: Array = []
	var cb := func(t): captured.append(String(t))
	EventBus.mechanics_intro.connect(cb)
	p_gl.restart_run()
	EventBus.mechanics_intro.disconnect(cb)
	var out: Array = []
	for chunk in captured:
		for line in String(chunk).split("\n"):
			if line.begins_with("【祝福】"):
				out.append(line)
	return out


func _consume_intro(p_gl) -> void:
	# 生产消费口径复刻（_finish_menu_start:1916-1918）：start 后即 emit+清——
	# 直调 start_run() 不消费，restart 会整队重播（探针坑）。
	if not p_gl._run_intro_lines.is_empty():
		EventBus.emit_mechanics_intro("
".join(p_gl._run_intro_lines))
		p_gl._run_intro_lines.clear()


func _disk_stardust() -> int:
	var cfg := ConfigFile.new()
	cfg.load(Meta.save_path())
	return int(cfg.get_value("meta", "stardust", -2147483648))


func run(p_tree: SceneTree) -> void:
	var gl_script: GDScript = load("res://scripts/loop/game_loop.gd")
	var gl = gl_script.new()
	gl.name = "GameLoopForR263Gap"
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

	# ══ A 存量记忆×余额 20 首局（§5.4 预期行为非 bug——验证发生且不误伤） ══
	Meta.stardust = 20
	Meta.stardust_total = 0
	Meta.set_blessing_trait(&"MEC_ORBIT_SWORD")             # 紫 30·「环绕·裂空剑」
	_start_normal(gl, 0)
	var a1_lines := _blessing_lines(gl)
	_check("A1 存量紫记忆：余额 20 首局横幅精确文（现有 20/30）",
		a1_lines.size() == 1 and a1_lines[0] == "【祝福】星尘不足，「环绕·裂空剑」本局未携带（现有 20/30）",
		str(a1_lines))
	_check("A1 不误伤：正常进局 + 零挂载零送武 + 余额 20 不动",
		gl.state == GameConst.GameStatus.PLAYING
			and _trait_layers_total(gl, &"MEC_ORBIT_SWORD") == 0
			and _count_weapon(gl, &"W8_orbit_field") == 0 and Meta.stardust == 20,
		"state=%d layers=%d w8=%d sd=%d" % [gl.state, _trait_layers_total(gl, &"MEC_ORBIT_SWORD"),
			_count_weapon(gl, &"W8_orbit_field"), Meta.stardust])
	_check("A1 档面原子：拒挂不落任何部分写（disk==20）", _disk_stardust() == 20,
		"disk=%d" % _disk_stardust())

	Meta.stardust = 20
	Meta.set_blessing_trait(&"MEC_CRITICAL_MASS")           # 金 50·「临界质量」
	_start_normal(gl, 0)
	var a2_lines := _blessing_lines(gl)
	_check("A2 存量金记忆：余额 20 横幅（现有 20/50）+ 零送零扣",
		a2_lines.size() == 1 and String(a2_lines[0]).contains("（现有 20/50）")
			and _count_weapon(gl, &"W8_orbit_field") == 0 and Meta.stardust == 20,
		str(a2_lines))

	Meta.stardust = 20
	Meta.set_blessing_trait(&"AFF_CRIT_RATE")               # 白 10·「瞄准校准」
	_start_normal(gl, 0)
	_check("A3 白档边界不误伤：余额 20 ≥ 10 → 挂载成功余 10",
		_trait_layers_total(gl, &"AFF_CRIT_RATE") == 1 and Meta.stardust == 10,
		"layers=%d sd=%d" % [_trait_layers_total(gl, &"AFF_CRIT_RATE"), Meta.stardust])

	Meta.stardust = 20
	Meta.set_blessing_trait(&"AFF_CRIT_DMG")                # 蓝 20·「致命一击」
	_start_normal(gl, 0)
	_check("A4 蓝档恰好边界：余额 20 == 20 → 成功归零（不误伤）",
		_trait_layers_total(gl, &"AFF_CRIT_DMG") == 1 and Meta.stardust == 0,
		"layers=%d sd=%d" % [_trait_layers_total(gl, &"AFF_CRIT_DMG"), Meta.stardust])

	# ══ B 横幅双文案（扣费局 / 已购重挂局 / 未购局静默） ══
	Meta.stardust = 200
	Meta.set_blessing_trait(&"MEC_ORBIT_SWORD")
	_start_normal(gl, 0)
	var b1_lines := _blessing_lines(gl)
	_check("B1 扣费局送武横幅精确文（附赠·W8 display_name 真源 + 价签）",
		b1_lines.size() == 1
			and b1_lines[0] == "【祝福】环绕·裂空剑（开局生效·附赠 近战·天狼刀·-30 星尘）",
		str(b1_lines))
	_consume_intro(gl)                                    # 生产口径：开局横幅已消费
	gl.state = GameConst.GameStatus.GAME_OVER
	var sd_b2: int = Meta.stardust
	var b2_lines := _capture_restart_banner(gl)
	_check("B2 已购重挂局横幅：复现附赠段但无价签（不重复扣费披露）",
		b2_lines.size() == 1
			and b2_lines[0] == "【祝福】环绕·裂空剑（开局生效·附赠 近战·天狼刀）"
			and Meta.stardust == sd_b2,
		"%s sd=%d→%d" % [str(b2_lines), sd_b2, Meta.stardust])

	Meta.stardust = 100
	Meta.set_blessing_trait(&"AFF_CRIT_DMG")
	_start_normal(gl, 0)
	_consume_intro(gl)
	gl.state = GameConst.GameStatus.GAME_OVER
	var b3_lines := _capture_restart_banner(gl)
	_check("B3 挂载路径已购重挂：横幅无价签（开局生效）",
		b3_lines.size() == 1 and b3_lines[0] == "【祝福】致命一击（开局生效）",
		str(b3_lines))

	Meta.stardust = 15
	Meta.set_blessing_trait(&"MEC_ORBIT_SWORD")             # 同 B1 靶
	_start_normal(gl, 0)                                    # 首局拒（横幅披露一次）
	_consume_intro(gl)
	gl.state = GameConst.GameStatus.GAME_OVER
	Meta.stardust += 100                                    # 结算补星尘（变够买）
	var sd_b4: int = Meta.stardust
	var b4_lines := _capture_restart_banner(gl)
	_check("B4 未购局重开：重播一句「未携带」短横幅（修轮评审-5）+ 不挂载 + 不扣费",
		b4_lines.size() == 1
			and b4_lines[0] == "【祝福】环绕·裂空剑（未携带·未购不随重开生效）"
			and _trait_layers_total(gl, &"MEC_ORBIT_SWORD") == 0
			and Meta.stardust == sd_b4,
		"lines=%s sd=%d" % [str(b4_lines), Meta.stardust])

	# ══ C 每日真实路径（change_state 驱动真接线） ══
	Meta.stardust = 100
	Meta.set_blessing_trait(&"AFF_CRIT_DMG")
	_goto_menu(gl)
	gl._difficulty = 0
	gl._on_menu_start_daily()
	_check("C1 每日出发：面板不弹 + 零挂载 + 零扣费 + 进局",
		not gl.blessing_pick_ui.is_open()
			and _trait_layers_total(gl, &"AFF_CRIT_DMG") == 0 and Meta.stardust == 100
			and gl.state == GameConst.GameStatus.PLAYING,
		"open=%s sd=%d" % [str(gl.blessing_pick_ui.is_open()), Meta.stardust])
	gl.hud.kills = 400
	gl.hud.wave = 30
	var c2_sd: int = Meta.stardust
	gl.change_state(GameConst.GameStatus.GAME_OVER)         # 真接线：EventBus → Meta 结算 + 结算屏
	_check("C2 每日结算屏：无星尘行 + 零产出（W30/K400/V 全不计）",
		gl.game_over_screen.stardust_text() == "" and Meta.stardust == c2_sd,
		"[%s] sd=%d→%d" % [gl.game_over_screen.stardust_text(), c2_sd, Meta.stardust])
	gl.game_over_screen.hide_screen()

	# ══ D 面板价签列几何（(488,22) 新布局·「全部」签 62 行全扫） ══
	Meta.stardust = 77
	var ui = gl.blessing_pick_ui
	var pool_all: Array[StringName] = gl._blessing_pool()
	ui.close()
	ui.open(pool_all, "", 0, &"W1_pistol")
	ui._filter_rarity = -1                                  # 「全部」签（默认签=难度档蓝 24 项）
	ui._apply_filter()
	ui._rebuild_rows()
	await p_tree.process_frame
	var geom_bad: Array[String] = []
	var name_max_w: float = 0.0
	var name_max_id := ""
	var desc_max_right: float = 0.0
	var desc_max_id := ""
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
			var price_l: Label = null
			var desc_l: Label = null
			var name_l: Label = null
			for sub in btn.get_children():
				var l := sub as Label
				if l == null:
					continue
				if l.text.begins_with("-") and l.text.length() <= 3:
					price_l = l
				elif l.position.y > 30.0:
					desc_l = l
				else:
					name_l = l
			if price_l == null:
				geom_bad.append("%s:无价签" % tid)
				continue
			if price_l.position.x != 488.0 or absf(price_l.size.x - 80.0) > 0.5:
				geom_bad.append("%s:价签几何%s%s" % [tid, str(price_l.position), str(price_l.size)])
			if price_l.position.x + price_l.size.x > 572.0:
				geom_bad.append("%s:价签右缘出卡宽 572" % tid)
			if price_l.horizontal_alignment != HORIZONTAL_ALIGNMENT_RIGHT:
				geom_bad.append("%s:价签非右对齐" % tid)
			if desc_l == null or name_l == null:
				geom_bad.append("%s:行缺名字/描述标签" % tid)
				continue
			# 视觉重叠判据：desc 框右缘 vs 价签文字实测左缘（右对齐——左缘=568-文字宽）
			var pfont := price_l.get_theme_font("font")
			var pfsize: int = price_l.get_theme_font_size("font")
			var price_tw: float = pfont.get_string_size(price_l.text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, pfsize).x if pfont != null else 0.0
			var price_text_left := price_l.position.x + price_l.size.x - price_tw
			var desc_right := desc_l.position.x + desc_l.size.x
			if desc_right > desc_max_right:
				desc_max_right = desc_right
				desc_max_id = tid
			if desc_right > price_text_left - 2.0:
				geom_bad.append("%s:desc 与价签文字重叠（%0.f vs %.0f）" % [tid, desc_right, price_text_left])
			if desc_l.text_overrun_behavior != TextServer.OVERRUN_TRIM_ELLIPSIS:
				geom_bad.append("%s:desc 无截断保护" % tid)
			var font := name_l.get_theme_font("font")
			var fsize: int = name_l.get_theme_font_size("font")
			var nw: float = font.get_string_size(name_l.text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, fsize).x if font != null else 0.0
			if nw > name_max_w:
				name_max_w = nw
				name_max_id = tid
			if name_l.position.x + nw > 488.0:
				geom_bad.append("%s:名字实测宽 %.0f 溢入价签区" % [tid, nw])
		if ui._page_next_btn == null or not ui._page_next_btn.visible or ui._page_next_btn.disabled:
			break
		ui._on_page_next()
	_check("D1 价签几何：62 行（全部签）全有价签@x488 宽80·右缘 568≤572·desc 与价签文字零重叠",
		geom_bad.is_empty() and seen.size() == 62,
		"rows=%d affected=%d bad=%s" % [seen.size(), geom_bad.size(), str(geom_bad.slice(0, 8))])
	print("  .. | D1 名字实测最大宽 %.0fpx（%s）；desc 框最大右缘 %.0fpx（%s，价签文字左缘≈537）"
		% [name_max_w, name_max_id, desc_max_right, desc_max_id])
	_check("D2 余额行随开刷新：◆ 星尘余额 77｜收费表全文",
		ui._stardust_label != null
			and ui._stardust_label.text == "◆ 星尘余额 77｜祝福按品级收费：白10/蓝20/紫30/金50",
		ui._stardust_label.text if ui._stardust_label != null else "<null>")
	Meta.stardust = 78
	ui.close()
	ui.open(pool_all, "", 0, &"W1_pistol")
	await p_tree.process_frame
	_check("D3 余额变动后重开：余额行新值 78（无缓存旧值）",
		ui._stardust_label.text.contains("星尘余额 78"), ui._stardust_label.text)
	ui.close()

	# ══ E 池三态边界补充 ══
	var pool_e: Array[StringName] = gl._blessing_pool()
	_check("E1 MEC_PARALLEL_CAL 在池（W1 含 lateral_gap_levels → fits 通过）",
		pool_e.has(&"MEC_PARALLEL_CAL"))
	_check("E2 纯形态类出局：AFF_RANGE/AFF_CDR 不在池",
		not pool_e.has(&"AFF_RANGE") and not pool_e.has(&"AFF_CDR"))
	var bound_n := 0
	var bound_all_gift := true
	for tid_v: Variant in gl.registry.traits.keys():
		var td_b: TraitData = gl.registry.get_trait(StringName(String(tid_v)))
		if td_b == null:
			continue
		if td_b.params.has("required_weapon") or td_b.params.has("required_class"):
			bound_n += 1
			if MechanicGate.blessing_gift_weapon(td_b, gl.registry.weapons) == StringName(""):
				bound_all_gift = false
	_check("E3 24 条武器绑定词条解析全非空", bound_n == 24 and bound_all_gift,
		"bound=%d" % bound_n)
	_check("E4 解析器空参防御：null td / 空 registry → 空串",
		MechanicGate.blessing_gift_weapon(null, gl.registry.weapons) == StringName("")
			and MechanicGate.blessing_gift_weapon(
				gl.registry.get_trait(&"MEC_GIANT_BLADE"), {}) == StringName(""))
	var tier_sizes := [gl._blessing_pool(0).size(), gl._blessing_pool(1).size(),
		gl._blessing_pool(2).size(), gl._blessing_pool(3).size()]
	_check("E5 分档子池：{白6,蓝24,紫26,金6} 逐档探针口",
		tier_sizes == [6, 24, 26, 6], str(tier_sizes))

	# ══ F 已购位与槽上武器持久（quit→continue / 回菜单再出发） ══
	Meta.stardust = 200
	Meta.set_blessing_trait(&"MEC_ORBIT_SWORD")
	_start_normal(gl, 0)                                    # 扣费 30 → 170
	var sd_f1: int = Meta.stardust
	gl.state = GameConst.GameStatus.PAUSED
	gl.quit_to_menu()                                       # PAUSED 主动退出 → 落档
	var resumed: bool = gl.continue_run()
	_check("F1 quit→continue：已购局恢复（slot1=W8+词条 1 份）+ 余额无二次扣",
		resumed and _slot_wid(gl, 1) == &"W8_orbit_field"
			and _trait_layers_total(gl, &"MEC_ORBIT_SWORD") == 1 and Meta.stardust == sd_f1,
		"resumed=%s s1=%s sd=%d→%d" % [str(resumed), String(_slot_wid(gl, 1)), sd_f1, Meta.stardust])
	gl.state = GameConst.GameStatus.PAUSED
	gl.quit_to_menu()
	var sd_f2: int = Meta.stardust
	_start_normal(gl, 0)                                    # 回菜单再出发 = 新局新扣费
	var f2_lines := _blessing_lines(gl)
	_check("F2 回菜单再出发：新局重扣（横幅复现价签 -30）",
		Meta.stardust == sd_f2 - 30 and f2_lines.size() == 1
			and String(f2_lines[0]).contains("-30 星尘"),
		"sd=%d→%d lines=%s" % [sd_f2, Meta.stardust, str(f2_lines)])

	# ══ G 扣费原子性 ══
	Meta.stardust = 25
	Meta.set_blessing_trait(&"MEC_ORBIT_SWORD")             # 同 F 靶
	_start_normal(gl, 0)
	_check("G1 余额 25<30 拒：槽上无新武器/无词条/内存与档余额均不动",
		_count_weapon(gl, &"W8_orbit_field") == 0
			and _trait_layers_total(gl, &"MEC_ORBIT_SWORD") == 0
			and Meta.stardust == 25 and _disk_stardust() == 25,
		"w8=%d sd=%d disk=%d" % [_count_weapon(gl, &"W8_orbit_field"), Meta.stardust, _disk_stardust()])
	Meta.stardust = 30
	_start_normal(gl, 0)
	_check("G2 余额恰 30 边界：成功送挂扣至 0",
		_count_weapon(gl, &"W8_orbit_field") == 1
			and _trait_layers_total(gl, &"MEC_ORBIT_SWORD") == 1 and Meta.stardust == 0,
		"w8=%d sd=%d" % [_count_weapon(gl, &"W8_orbit_field"), Meta.stardust])

	# ══ H 大厅星尘行 + 图标 ══
	var icon := TextureFactory.stardust_icon()
	_check("H1 stardust_icon：非空程序化贴图（尺寸>0）",
		icon != null and icon.get_width() > 0 and icon.get_height() > 0,
		"%dx%d" % [icon.get_width() if icon != null else -1,
			icon.get_height() if icon != null else -1])
	Meta.stardust = 123
	var menu = gl.menu_screen
	var found_sd_row := ""
	if menu != null:
		menu._rebuild_upgrades()
		var stack: Array = [menu._panel_list]
		while not stack.is_empty():
			var node = stack.pop_back()
			if node == null or not is_instance_valid(node):
				continue
			for ch in node.get_children():
				stack.append(ch)
			var lbl := node as Label
			if lbl != null and lbl.text.begins_with("星尘："):
				found_sd_row = lbl.text
	_check("H2 大厅养成面板星尘行：「星尘：123（每局结算产出 · 祝福携带消耗）」",
		found_sd_row == "星尘：123（每局结算产出 · 祝福携带消耗）", "[%s]" % found_sd_row)

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
