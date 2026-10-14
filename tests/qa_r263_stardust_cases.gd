extends RefCounted
# R263 祝福收费（星尘·局外货币）cases（配套口 qa_r263_stardust.gd；设计 §6 S1-S11）。
# S1 定价表  S2 扣费写即落盘  S3 余额不足拒挂  S4 已购位套利防线
# S5 产出公式六场景+结算入账==预览  S6 三终局口径  S7 旧档迁移
# S8 charge/grant 边界  S9 面板 UI（价签/余额/置灰/附赠行）  S10 结算屏产出行
# S11 每日面板不弹
# 测试卫生：开套件快照内存+档字节（含 records/map_records/daily/achievements——S5/S6
# 结算路径写面广），收尾原样还原；套件恒置电池末位。
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


func _disk_stardust() -> int:
	var cfg := ConfigFile.new()
	cfg.load(Meta.save_path())
	return int(cfg.get_value("meta", "stardust", -2147483648))


func _goto_row(p_ui, p_tid: String) -> Button:
	# 跨页找行（翻页钮驱动——页容量 7；找到停在所在页，找不到停在末页返 null）
	for _hop in range(12):
		var row: Button = p_ui._row_by_id(p_tid)
		if row != null:
			return row
		if p_ui._page_next_btn == null or not p_ui._page_next_btn.visible or p_ui._page_next_btn.disabled:
			break
		p_ui._on_page_next()
	return null


func _settle_direct(p_wave: int, p_kills: int, p_difficulty: int, p_victory: bool) -> int:
	# 结算入账直调（duck 写局计数 + 私有结算口——verify_feedback _on_state_changed 同款面）
	Meta.set("_run_max_wave", p_wave)
	Meta.set("_run_kills", p_kills)
	Meta.set("_run_difficulty", p_difficulty)
	Meta.set("_run_difficulty_armed", true)
	Meta.set("_run_daily", false)
	Meta.set("_run_victory", p_victory)
	var before: int = Meta.stardust
	Meta._settle_run_result()
	return Meta.stardust - before


func run(p_tree: SceneTree) -> void:
	var gl_script: GDScript = load("res://scripts/loop/game_loop.gd")
	var gl = gl_script.new()
	gl.name = "GameLoopForR263Stardust"
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

	# ══ S1 定价表（用户拍板·唯一真源） ══
	_check("S1 定价表：BLESSING_COST==[10,20,30,50]",
		Meta.BLESSING_COST.size() == 4 and Meta.BLESSING_COST[0] == 10
			and Meta.BLESSING_COST[1] == 20 and Meta.BLESSING_COST[2] == 30
			and Meta.BLESSING_COST[3] == 50)
	_check("S1 blessing_cost 逐项：0..3 → 10/20/30/50",
		Meta.blessing_cost(0) == 10 and Meta.blessing_cost(1) == 20
			and Meta.blessing_cost(2) == 30 and Meta.blessing_cost(3) == 50)

	# ══ S8 边界：charge 不足/0/负 + grant 累加无上限 ══
	Meta.stardust = 7
	var c1 := Meta.charge_stardust(10)
	var c2 := Meta.charge_stardust(0)
	var c3 := Meta.charge_stardust(-5)
	_check("S8 charge 边界：超余额/0/负均返 false 且余额不动",
		not c1 and not c2 and not c3 and Meta.stardust == 7,
		"%s/%s/%s sd=%d" % [str(c1), str(c2), str(c3), Meta.stardust])
	var c4 := Meta.charge_stardust(7)
	_check("S8 charge 恰等余额：成功归零（无负余额路径）", c4 and Meta.stardust == 0)
	Meta.grant_stardust(1000000)
	var total_after_big: int = Meta.stardust_total
	Meta.grant_stardust(5)
	_check("S8 grant 累加无上限：1000000 入账不溢出拒绝 + total 累计",
		Meta.stardust == 1000005 and Meta.stardust_total == total_after_big + 5)

	# ══ S5 产出公式：六场景精确值（设计 §5.3 校准表） ══
	var formula_rows: Array = [
		[6, 40, 0, false, 7], [12, 60, 0, true, 22], [8, 60, 1, false, 14],
		[12, 80, 1, true, 33], [13, 100, 2, true, 46], [30, 400, 0, true, 46],
	]
	var formula_ok := true
	var formula_detail := ""
	for row in formula_rows:
		var got := Meta.stardust_for(row[0], row[1], row[2], row[3])
		if got != row[4]:
			formula_ok = false
			formula_detail = "(%d,%d,%d,%s)→%d（期望 %d）" % [row[0], row[1], row[2], str(row[3]), got, row[4]]
			break
	_check("S5 产出公式：stardust_for 六场景 == 7/22/14/33/46/46", formula_ok, formula_detail)
	# 结算入账==预览（同参对照；含胜利位 V）
	Meta.stardust = 500
	Meta.stardust_total = 0
	var preview := Meta.stardust_for(12, 80, 1, true)
	var granted := _settle_direct(12, 80, 1, true)
	_check("S5 结算入账==预览值：settle(12,80,困难,胜利)==%d" % preview,
		granted == preview and granted == 33, "granted=%d preview=%d" % [granted, preview])
	_check("S5 granted 累计入 stardust_total", Meta.stardust_total == 33,
		"total=%d" % Meta.stardust_total)

	# ══ S6 三终局：通关 settle_now 兑现 / 中途退出 0 / 每日 0（死亡=S5 已证） ══
	Meta.stardust = 500
	Meta.set("_run_max_wave", 13)
	Meta.set("_run_kills", 100)
	Meta.set("_run_difficulty", 2)
	Meta.set("_run_difficulty_armed", true)
	Meta.set("_run_daily", false)
	Meta.set("_run_victory", true)
	var sd_defer: int = Meta.stardust
	Meta.defer_settle_once()
	Meta._on_state_changed(GameConst.GameStatus.GAME_OVER)   # 延迟结算位——不落账
	var sd_after_gameover: int = Meta.stardust
	Meta.settle_now()                                        # 玩家选重开/回菜单——兑现
	_check("S6 通关延迟结算：GAME_OVER 不落账 → settle_now 兑现 +46（地狱 V=16）",
		sd_after_gameover == sd_defer and Meta.stardust == sd_defer + 46,
		"%d → %d → %d" % [sd_defer, sd_after_gameover, Meta.stardust])
	# 中途退出（暂停回菜单）：无结算即无产出（清记忆防扣费干扰——本臂只测产出侧）
	Meta.blessing_trait_id = ""
	Meta.stardust = 500
	_start_normal(gl, 0)
	gl.state = GameConst.GameStatus.PAUSED
	gl.quit_to_menu()
	_check("S6 中途退出：暂停回菜单零结算零产出",
		Meta.stardust == 500, "sd=%d" % Meta.stardust)
	# 每日局：结算分流零星尘
	Meta.set("_run_daily", true)
	Meta.set("_run_max_wave", 30)
	Meta.set("_run_kills", 400)
	Meta.set("_run_difficulty", 0)
	Meta.set("_run_victory", true)
	var sd_daily: int = Meta.stardust
	Meta._settle_run_result()
	_check("S6 每日局：结算分流提前返零星尘（W/K/V 均不计）",
		Meta.stardust == sd_daily, "%d→%d" % [sd_daily, Meta.stardust])
	Meta.set("_run_daily", false)

	# ══ S7 旧档迁移：无键默认 20/0 + 往返持久化 ══
	var cfg := ConfigFile.new()
	cfg.set_value("meta", "crystals", 5)
	cfg.set_value("meta", "upgrades", {})
	cfg.set_value("meta", "character", "sentinel")
	cfg.save(Meta.save_path())                              # 故意不含 stardust 键（旧档形态）
	Meta._load()
	_check("S7 旧档缺键：_load 后 stardust==20（启动资金）+ stardust_total==0",
		Meta.stardust == 20 and Meta.stardust_total == 0,
		"sd=%d total=%d" % [Meta.stardust, Meta.stardust_total])
	Meta.stardust = 77
	Meta.stardust_total = 123
	Meta.charge_stardust(7)                                 # 写即落盘（往返面）
	Meta._load()
	_check("S7 存档往返：charge 落盘后 _load 读回 70/123",
		Meta.stardust == 70 and Meta.stardust_total == 123,
		"sd=%d total=%d" % [Meta.stardust, Meta.stardust_total])

	# ══ S2 扣费：挂载成功即扣+写即落盘 ══
	Meta.stardust = 100
	Meta.set_blessing_trait(&"AFF_CRIT_DMG")                # 蓝档 20·W1 可挂
	_start_normal(gl, 0)
	_check("S2 扣费：蓝档挂载成功 → 余额 100-20=80",
		_trait_layers_total(gl, &"AFF_CRIT_DMG") == 1 and Meta.stardust == 80,
		"layers=%d sd=%d" % [_trait_layers_total(gl, &"AFF_CRIT_DMG"), Meta.stardust])
	_check("S2 写即落盘：ConfigFile 立即可读回 meta/stardust==80", _disk_stardust() == 80,
		"disk=%d" % _disk_stardust())

	# ══ S3 余额不足：不挂不扣+横幅+正常进局 ══
	Meta.stardust = 15
	Meta.set_blessing_trait(&"MEC_ORBIT_SWORD")             # 紫 30·绑 W8（附赠送武型）
	_start_normal(gl, 0)
	_check("S3 余额不足：不挂载+余额不动+横幅披露+正常进局",
		_trait_layers_total(gl, &"MEC_ORBIT_SWORD") == 0 and Meta.stardust == 15
			and "".join(gl._run_intro_lines).contains("星尘不足")
			and gl.state == GameConst.GameStatus.PLAYING,
		"layers=%d sd=%d lines=%s" % [_trait_layers_total(gl, &"MEC_ORBIT_SWORD"),
			Meta.stardust, str(gl._run_intro_lines)])

	# ══ S4 已购位：未购局死亡补星尘重开不白捡；已购局重开不重复扣 ══
	gl.state = GameConst.GameStatus.GAME_OVER
	gl.restart_run()                                        # 未购位（S3 被拒）重开
	var s4_layers := _trait_layers_total(gl, &"MEC_ORBIT_SWORD")
	Meta.stardust += 100                                    # 模拟死亡结算入账（变够买）
	gl.state = GameConst.GameStatus.GAME_OVER
	gl.restart_run()                                        # 已购位仍 false——拦截（重开横幅
	                                                        # 随消费清空——挂载缺席即拦截证据）
	_check("S4 套利防线：未购局重开仍不挂载（结算补星尘不改变已购位）",
		s4_layers == 0 and _trait_layers_total(gl, &"MEC_ORBIT_SWORD") == 0,
		"layers=%d" % [_trait_layers_total(gl, &"MEC_ORBIT_SWORD")])
	# 修轮（评审-5）：未购局重开重播一句未携带短横幅（直调口径——生产消费链由 gap
	# B4 经 EventBus 捕获覆盖）；不挂载不扣费语义不变。
	Meta.stardust += 50
	gl._apply_start_blessing(false)
	_check("S4 评审-5：未购局重开重播「未携带」短横幅 + 仍不挂载不扣费",
		"".join(gl._run_intro_lines).contains("未携带·未购不随重开生效")
			and _trait_layers_total(gl, &"MEC_ORBIT_SWORD") == 0,
		"lines=%s" % str(gl._run_intro_lines))
	gl._run_intro_lines.clear()
	Meta.stardust = 100
	Meta.set_blessing_trait(&"AFF_CRIT_DMG")
	_start_normal(gl, 0)                                    # 新局（复位已购位）→ 扣 20
	var sd_paid: int = Meta.stardust
	gl.state = GameConst.GameStatus.GAME_OVER
	gl.restart_run()                                        # 已购局重开
	_check("S4 对照：已购局 restart 不重复扣费（余额维持 80）",
		Meta.stardust == sd_paid and sd_paid == 80
			and _trait_layers_total(gl, &"AFF_CRIT_DMG") == 1,
		"sd=%d" % Meta.stardust)

	# ══ S9 面板 UI：价签/余额行/置灰/附赠行 ══
	Meta.stardust = 25
	var ui = gl.blessing_pick_ui
	var pool: Array[StringName] = gl._blessing_pool(2)      # 紫档子池（含 ORBIT_SWORD·26 项 4 页）
	ui.open(pool, "", 0, &"W1_pistol")                      # 显式首发上下文（附赠标记判定）
	await p_tree.process_frame
	var afford_row: Button = _goto_row(ui, "MEC_ORBIT_SWORD")
	var price_ok := false
	if afford_row != null:
		for sub in afford_row.get_children():
			var pl := sub as Label
			if pl != null and pl.text == "-30":
				price_ok = pl.get_theme_color("font_color").is_equal_approx(PopPalette.rarity_color(2))
	_check("S9 价签：紫档行右缘「-30」+ rarity 色（与行品级同源）",
		price_ok, "rows=%d" % ui._list_box.get_child_count())
	# 修轮（评审-6）：附赠标记上移名字行行尾（desc 全留效果文本）——断言随迁
	var gift_name := ""
	if afford_row != null:
		for sub2 in afford_row.get_children():
			var nl2 := sub2 as Label
			if nl2 != null and nl2.position.y < 30.0 and nl2.position.x < 450.0:
				gift_name = nl2.text
	_check("S9 附赠行：名字行尾「附赠·近战·天狼刀」（MechanicGate 单源解析·评审-6 空间分配）",
		gift_name.contains("附赠·") and gift_name.contains("近战·天狼刀"), gift_name)
	_check("S9 余额不足置灰：余额 25 < 紫 30 → 该行 disabled 不可选 + 整行降透明可感知（评审-2）",
		afford_row != null and afford_row.disabled and afford_row.modulate.a < 1.0)
	_check("S9 余额行：footer 上方「◆ 星尘余额 25｜…收费…」",
		ui._stardust_label != null and ui._stardust_label.text.contains("星尘余额 25")
			and ui._stardust_label.text.contains("白10/蓝20/紫30/金50"),
		ui._stardust_label.text if ui._stardust_label != null else "<null>")
	# 记忆项不可负担：不预选 + 副标题披露
	Meta.set_blessing_trait(&"MEC_ORBIT_SWORD")
	ui.close()
	ui.open(pool, Meta.blessing_trait(), 0, &"W1_pistol")
	await p_tree.process_frame
	_check("S9 记忆不可负担：不预选 + 副标题追加披露",
		ui.selected_id() == "" and ui._subtitle.text.contains("记忆祝福余额不足"),
		"sel=%s sub=%s" % [ui.selected_id(), ui._subtitle.text])
	# 可负担对照：蓝档余额 25 ≥ 20 → 可选
	Meta.stardust = 25
	var pool_b: Array[StringName] = gl._blessing_pool(1)
	ui.close()
	ui.open(pool_b, "AFF_CRIT_DMG", 0, &"W1_pistol")
	await p_tree.process_frame
	var blue_row: Button = ui._row_by_id("AFF_CRIT_DMG")
	_check("S9 可负担对照：蓝档行可选（disabled==false·不降透明）+ 预选生效",
		blue_row != null and not blue_row.disabled and blue_row.modulate.a == 1.0
			and ui.selected_id() == "AFF_CRIT_DMG",
		"sel=%s" % ui.selected_id())
	ui.close()

	# ══ S10 结算屏：死亡行/胜利预览/每日无行 ══
	Meta.set_run_daily(false)
	Meta.set_run_difficulty(0)
	Meta.stardust = 40
	gl.hud.kills = 60
	gl.hud.wave = 12
	gl.game_over_screen.show_summary()
	var death_line: String = gl.game_over_screen.stardust_text()
	_check("S10 死亡屏：统计行下「◆ 星尘 +14（余额 40）」（w12/60 杀普通无 V）",
		death_line.contains("星尘 +14") and death_line.contains("余额 40"), death_line)
	gl.game_over_screen.show_victory(true)
	var vict_line: String = gl.game_over_screen.stardust_text()
	_check("S10 胜利屏预览：至少 +22（评审-3 下限口径·settle 前可读==公式值 w12/60 普通通关）",
		vict_line.contains("至少 +22")
			and vict_line == "◆ 星尘 至少 +22（当前余额 %d）" % Meta.stardust,
		vict_line)
	Meta.set_run_daily(true)
	gl.game_over_screen.show_victory(false)
	_check("S10 每日屏：无星尘行（零产出不披露）",
		gl.game_over_screen.stardust_text() == "",
		"[%s]" % gl.game_over_screen.stardust_text())
	Meta.set_run_daily(false)
	gl.game_over_screen.hide_screen()

	# ══ S11 每日面板：每日路径不弹（B8 回归） ══
	Meta.set_blessing_trait(&"AFF_CRIT_DMG")
	_goto_menu(gl)
	gl._difficulty = 0
	gl._on_menu_start_daily()
	_check("S11 每日面板：每日路径不弹面板 + 零挂载",
		not gl.blessing_pick_ui.is_open() and _trait_layers_total(gl, &"AFF_CRIT_DMG") == 0,
		"open=%s" % str(gl.blessing_pick_ui.is_open()))

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
