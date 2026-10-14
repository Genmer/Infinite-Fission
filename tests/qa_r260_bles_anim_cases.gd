extends RefCounted
# R260 Q 弹动画掉帧批 cases（配套口 qa_r260_bles_anim.gd）。
# ①泵挂起链（弹层/大厅面板模态期 CardDesc+图鉴泵分泵挂起/恢复/图鉴豁免）
# ②祝福行缓存（池|档签名零重建/池变重建/选中态重置）
# ③档位色 open 刷新（band/title 随档——原 build 烘焙存量缺陷）。

var _pass := 0
var _fail := 0
var _failures: Array[String] = []


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  ok | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("  FAIL | %s %s" % [p_name, p_detail])


func run(p_tree: SceneTree) -> void:
	var gl_script: GDScript = load("res://scripts/loop/game_loop.gd")
	var gl = gl_script.new()
	gl.name = "GameLoopForR260BlesAnim"
	p_tree.get_root().add_child(gl)
	gl.set_physics_process(false)
	var waited := 0
	while not gl.boot_ready and waited < 600:
		await p_tree.process_frame
		waited += 1
	var menu = gl.menu_screen
	_check("boot：菜单就绪", menu != null and gl.boot_ready)
	_check("泵基线：大厅无面板双泵运行", not menu.card_desc_pump_paused() and not menu.codex_pump_paused())
	# R263 修轮（QA-2）：星尘 fixture——③段 open(pool2, pool2[0], 0) 预选记忆走新契约
	#「余额<价签 → 不预选」，对 user:// 残留档（stardust<20）敏感（1/23 假红）；快照+
	# 预置+两还原点回写（本套件零扣费——仅防预选被拒；r252 _snap_stardust 同款口径）。
	var sd_snap: int = Meta.stardust
	Meta.stardust = 100

	# ── ① 泵挂起链：大厅面板 ──
	menu._on_lobby_pressed("ach")
	_check("泵链：成就面板开=CardDesc 挂起+图鉴泵挂起",
		menu.card_desc_pump_paused() and menu.codex_pump_paused())
	menu._on_panel_close()
	_check("泵链：回大厅=双泵恢复", not menu.card_desc_pump_paused() and not menu.codex_pump_paused())
	menu._on_lobby_pressed("codex")
	_check("泵链：图鉴面板开=图鉴泵豁免续跑（CardDesc 仍挂起）",
		menu.card_desc_pump_paused() and not menu.codex_pump_paused())
	menu._on_panel_close()
	menu._open_map_select()
	_check("泵链：选关面板独立开口=CardDesc 挂起（不经 _on_lobby_pressed 的漏口）",
		menu.card_desc_pump_paused())
	menu._on_panel_close()
	_check("泵链：选关关=恢复", not menu.card_desc_pump_paused())

	# ── ② 祝福链：模态挂起+收口恢复（真池夹具——解锁两词条，走 game_loop 接线口） ──
	Meta.codex_traits["AFF_CRIT_DMG"] = true
	Meta.codex_traits["AFF_CRIT_RATE"] = true
	var opened: bool = gl._try_open_blessing_pick()
	_check("祝福链：面板开（真池接线口）", opened and gl.blessing_pick_ui.is_open(),
		"opened=%s" % str(opened))
	_check("祝福链：面板开=双泵挂起（game_loop 接线）",
		menu.card_desc_pump_paused() and menu.codex_pump_paused(),
		"cd=%s cx=%s" % [str(menu.card_desc_pump_paused()), str(menu.codex_pump_paused())])
	var pool: Array[StringName] = gl.blessing_pick_ui._pool
	gl.blessing_pick_ui.dismiss()
	_check("祝福链：dismiss 收口=双泵恢复",
		not menu.card_desc_pump_paused() and not menu.codex_pump_paused())

	# ── ③ 行缓存：同池同档零重建/选中态重置/池变重建 ──
	gl.blessing_pick_ui.open(pool, "", 0)
	var row0_a: Node = gl.blessing_pick_ui._list_box.get_child(0)
	gl.blessing_pick_ui.confirm()                   # 关面板（行留树）
	gl.blessing_pick_ui.open(pool, "", 0)
	var row0_b: Node = gl.blessing_pick_ui._list_box.get_child(0)
	_check("行缓存：同池同档重开=同行实例零重建", row0_b == row0_a,
		"same=%s" % str(row0_b == row0_a))
	# 池变夹具：确定性双元素池（本档池可能仅单元素——取首元素+池外一个词条，
	# UI 对池内容零过滤（池合法性由 GameLoop 侧保证），直传必建行）。
	# R262 P1 修：第二项用 AFF_GOLD（rarity=1 实查）——同蓝档直传不经 GameLoop
	# 过滤无需解锁（pool[0] 恒=AFF_CRIT_DMG）；原 AFF_CRIT_RATE 实为 r0 白档，
	# R262 默认签=蓝（difficulty0）下混档池 _filtered=1≠2 行数断言必红。
	var pool2: Array[StringName] = [StringName(String(pool[0])), &"AFF_GOLD"]
	gl.blessing_pick_ui.confirm()
	gl.blessing_pick_ui.open(pool2, "", 0)
	var row0_c: Node = gl.blessing_pick_ui._list_box.get_child(0)
	# 悬垂引用（free 后）与活实例的 != 比较不可靠（R259 坑：freed==null 判 true 的近族）——
	# 释放判据=is_instance_valid；重建判据=行数随池（下行）
	_check("行缓存：池变=重建+旧行释放",
		row0_c != null and not is_instance_valid(row0_a),
		"new_null=%s old_valid=%s" % [str(row0_c == null), str(is_instance_valid(row0_a))])
	_check("行缓存：池变后行数随池",
		gl.blessing_pick_ui._list_box.get_child_count() == pool2.size(),
		"rows=%d pool=%d" % [gl.blessing_pick_ui._list_box.get_child_count(), pool2.size()])
	# 选中态重置：预选记忆→关→无记忆重开→无选中（复用路径全清+预选重置）
	gl.blessing_pick_ui.confirm()
	gl.blessing_pick_ui.open(pool2, String(pool2[0]), 0)
	_check("行缓存：预选记忆=选中态生效", gl.blessing_pick_ui.selected_id() == String(pool2[0]),
		"sel=%s" % gl.blessing_pick_ui.selected_id())
	gl.blessing_pick_ui.confirm()
	gl.blessing_pick_ui.open(pool2, "", 0)
	_check("行缓存：复用路径重开=选中态全清", gl.blessing_pick_ui.selected_id() == "",
		"sel=%s" % gl.blessing_pick_ui.selected_id())
	gl.blessing_pick_ui.confirm()

	# ── ④ 档位色 open 刷新（存量缺陷顺修） ──
	gl.blessing_pick_ui.open(pool2, "", 2)          # 难度 2（地狱）——tier 真源经 blessing_rarity_tier
	var tier2 := GameConst.blessing_rarity_tier(2)
	var band_c: Color = gl.blessing_pick_ui._band.color
	var expect_c := PopPalette.rarity_color(tier2)
	_check("档位色：顶带色随档刷新（非 build 烘焙）",
		band_c.is_equal_approx(expect_c),
		"got=%s expect=%s" % [str(band_c), str(expect_c)])
	var title_c: Color = gl.blessing_pick_ui._title.get_theme_color("font_color")
	_check("档位色：标题字色随档刷新（评审补）",
		title_c.is_equal_approx(expect_c),
		"got=%s expect=%s" % [str(title_c), str(expect_c)])
	gl.blessing_pick_ui.confirm()

	# 夹具还原
	Meta.codex_traits.erase("AFF_CRIT_DMG")
	Meta.codex_traits.erase("AFF_CRIT_RATE")
	Meta._save()

	# ── ⑤ 评审修轮复核：HIGH-1 出发两口清位 / settings 门 / 条件合并组合 ──
	# R262 适配：全池口径下「出发直达战斗=泵恢复」前提需 codex 空——本地档跨档解锁
	# 项（白/紫档）会使命中出发弹祝福面板挂泵（R261 分档蓝池时不在池故绿）；
	# 快照→清空→还原（组合臂 :136 临时解锁一项真弹面板）。
	var codex_snap5: Dictionary = Meta.codex_traits.duplicate()
	Meta.codex_traits.clear()
	Meta._save()
	menu._open_map_select()
	menu._on_map_pick(&"world_grass")
	_check("评审H1：选关出发钮直关=泵恢复（不留挂起残留）",
		not menu.card_desc_pump_paused() and not menu.codex_pump_paused())
	menu._on_lobby_pressed("daily")
	menu._on_daily_start()
	_check("评审H1：每日出发钮直关=泵恢复",
		not menu.card_desc_pump_paused() and not menu.codex_pump_paused())
	menu.set_settings_modal(true)
	_check("评审M1：设置弹层=双泵挂起",
		menu.card_desc_pump_paused() and menu.codex_pump_paused())
	menu.set_settings_modal(false)
	_check("评审M1：设置关闭=双泵恢复", not menu.card_desc_pump_paused())
	menu._on_lobby_pressed("ach")                 # 条件合并组合：大厅面板开+祝福模态→祝福收口仍挂起
	Meta.codex_traits["AFF_CRIT_DMG"] = true      # R262：组合臂需池非空（真弹面板测条件合并）
	gl._try_open_blessing_pick()
	gl.blessing_pick_ui.dismiss()
	_check("评审组合：祝福收口后面板仍开=泵仍挂起（条件合并语义）",
		menu.card_desc_pump_paused() and menu.codex_pump_paused(),
		"cd=%s cx=%s" % [str(menu.card_desc_pump_paused()), str(menu.codex_pump_paused())])
	menu._on_panel_close()
	_check("评审组合：面板终关=双泵恢复",
		not menu.card_desc_pump_paused() and not menu.codex_pump_paused())
	# ⑤段夹具还原（快照重放）+ R263 修轮（QA-2）：星尘还原随最后一次 _save 落档
	Meta.codex_traits.clear()
	for k5_v: Variant in codex_snap5.keys():
		Meta.codex_traits[String(k5_v)] = true
	Meta.stardust = sd_snap
	Meta._save()

	gl.free()
	print("验收汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	for f in _failures:
		print("  FAIL | %s" % f)


func fail_count() -> int:
	return _fail
