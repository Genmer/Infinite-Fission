# R262e ②点击卡顿微基准用例体（qa_r262e_menu_click 入口 load）
# 四段同步成本：①选关面板 _open_map_select ②祝福面板 open（首开=行缓存冷）
# ③start_run 出发链 ④card_select_ui open（分帧门 headless 关=全量同步当量）
# 判读：µs 均值行（阈值断言只锁「可优化大头已消失」的修后态——首版先出数据基线）
extends RefCounted

var _tree: SceneTree = null
var _fails: int = 0
var _passes: int = 0


func _check(p_name: String, p_ok: bool, p_detail: String = "") -> void:
	if p_ok:
		_passes += 1
		print("PASS | " + p_name)
	else:
		_fails += 1
		print("FAIL | " + p_name + ("" if p_detail.is_empty() else "  [got: " + p_detail + "]"))


func _bench_us(p_iters: int, p_fn: Callable, p_setup: Callable = Callable()) -> float:
	# µs/次均值（p_setup 每次前复位态——面板关/局清等；预热 1 次排首建抖动）
	p_setup.call()
	p_fn.call()
	var t0 := Time.get_ticks_usec()
	for i in range(p_iters):
		p_setup.call()
		p_fn.call()
	var dt := Time.get_ticks_usec() - t0
	return float(dt) / float(p_iters)


func run_all(p_tree: SceneTree) -> int:
	_tree = p_tree
	_test_map_select()
	_test_blessing_open()
	_test_start_run()
	_test_card_open()
	_test_anchors()
	print("R262e 微基准汇总：PASS %d / FAIL %d（共 %d 项）" % [_passes, _fails, _passes + _fails])
	return _fails


func _mk_gl(p_name: String):
	var gl = GameLoop.new()
	gl.name = p_name
	_tree.get_root().add_child(gl)
	gl.set_physics_process(false)
	return gl


func _test_map_select() -> void:
	print("── ① 选关面板 open（点击「选关」） ──")
	var gl = _mk_gl("R262eA")
	var ms = gl.menu_screen
	ms.call("_on_panel_close")
	var us := _bench_us(10, func() -> void: ms.call("_open_map_select"),
		func() -> void: ms.call("_on_panel_close"))
	print("    选关面板 open/次 = %.0f µs" % us)
	_check("① 选关面板 open 基线落账（%.0f µs/次）" % us, us > 0.0)
	ms.call("_on_panel_close")
	gl.queue_free()


func _test_blessing_open() -> void:
	print("── ② 祝福面板 open（点击「出发」首开） ──")
	var gl = _mk_gl("R262eB")
	var pool: Array[StringName] = gl.call("_blessing_pool")
	var bp = gl.blessing_pick_ui
	# 首开当量：每次 open 前换池签名（不同池序=行缓存全弃）模拟冷开
	var pools: Array[Array] = [pool.duplicate()]
	if pool.size() > 1:
		var rotated: Array[StringName] = []
		for i in range(pool.size()):
			rotated.append(pool[(i + 1) % pool.size()])
		pools.append(rotated)
	var pi := 0
	var us := _bench_us(8, func() -> void: bp.call("open", pools[pi % pools.size()], &"", 1),
		func() -> void:
			bp.call("close")
			pi += 1)
	print("    祝福面板 open（冷签名）= %.0f µs" % us)
	_check("② 祝福首开基线落账（%.0f µs/次，池 %d 项）" % [us, pool.size()], us > 0.0)
	bp.call("close")
	gl.queue_free()


func _test_start_run() -> void:
	print("── ③ start_run 出发链（点击「确认」） ──")
	var gl = _mk_gl("R262eC")
	var ok_ref: Array = []                       # lambda 捕贝坑：计数走引用容器
	var us := _bench_us(5, func() -> void:
			if gl.call("start_run"):
				ok_ref.append(1),
		func() -> void:
			gl.state = GameConst.GameStatus.MENU)
	print("    start_run/次 = %.0f µs（真跑 %d/5）" % [us, ok_ref.size()])
	_check("③ start_run 基线落账（%.0f µs/次，真跑 %d ≥5——state 门直置保真链）" % [us, ok_ref.size()],
		ok_ref.size() >= 5 and us > 0.0)
	gl.call("quit_to_menu")
	gl.queue_free()


func _test_card_open() -> void:
	print("── ④ 选卡窗 open（升级弹窗） ──")
	var gl = _mk_gl("R262eD")
	gl.call("start_run")
	var cands: Array = gl.card_generator.call("generate_candidates",
		{"player": gl.player, "wave": 5})
	var cs = gl.card_select_ui
	var us := _bench_us(8, func() -> void: cs.call("open", cands, false),
		func() -> void: cs.call("close"))
	print("    选卡窗 open/次 = %.0f µs（货架 %d 张）" % [us, cands.size()])
	_check("④ 选卡窗 open 基线落账（%.0f µs/次）" % us, us > 0.0)
	# R262e ①满层徽标冒烟：maxed flag 与 UI 显隐链路
	var has_flag := false
	for c_v: Variant in cands:
		var c: Dictionary = c_v
		if c.has("maxed"):
			has_flag = true
	_check("①生成侧候选带 maxed 键（满层徽标数据面）", has_flag)
	# 直调组装口（候选随机货架不含护盾卡是常态——指定 target 断言判定面本体）：
	# ①层（未满）→ false；2 层（=stack_max 满）→ true
	var w0 = gl.player.weapon_slots[0]
	var shield: TraitData = (gl.registry.get_trait(&"MEC_SHIELD") as TraitData).duplicate()
	var shield_cap := int(shield.stack_max)
	w0.call("attach_trait", shield)
	var card_partial: Dictionary = gl.card_generator.call("_make_trait_card",
		&"MEC_SHIELD", 0, w0)
	_check("①未满层（1/%d）maxed=false（未满不亮徽标）" % shield_cap,
		not bool(card_partial.get("maxed", true)))
	for i in range(shield_cap - 1):
		w0.call("attach_trait", shield)
	var card_full: Dictionary = gl.card_generator.call("_make_trait_card",
		&"MEC_SHIELD", 0, w0)
	_check("①已满层（%d/%d）maxed=true（徽标触发面）" % [shield_cap, shield_cap],
		bool(card_full.get("maxed", false)),
		"maxed=%s" % str(card_full.get("maxed")))
	cs.call("close")
	gl.call("quit_to_menu")
	# U1 徽标 UI 显隐链：满层卡 open 后角标 visible（_setup_button 消费 "maxed"）
	var maxed_cands: Array[Dictionary] = []
	var mk: CardGenerator = gl.card_generator
	var w0b = gl.player.weapon_slots[0]
	var sh2: TraitData = (gl.registry.get_trait(&"MEC_SHIELD") as TraitData).duplicate()
	for i in range(int(sh2.stack_max)):
		w0b.call("attach_trait", sh2)
	maxed_cands.append(mk.call("_make_trait_card", &"MEC_SHIELD", 0, w0b))
	maxed_cands.append(mk.call("_fallback_stat_card", 0))
	cs.call("open", maxed_cands, false)       # open 无 state 前置（纯 UI 面——零迁移直测）
	var btn0: Button = (cs.get("_buttons") as Array)[0]
	var badge: Label = ((cs.get("_card_faces") as Array)[0] as Dictionary).get("maxed")
	var badge2: Label = ((cs.get("_card_faces") as Array)[1] as Dictionary).get("maxed")
	_check("U1 满层卡角标可见+未满卡隐藏（UI 链）",
		badge != null and badge.visible and badge2 != null and not badge2.visible,
		"b0=%s b1=%s" % [str(badge.visible if badge != null else null),
			str(badge2.visible if badge2 != null else null)])
	cs.call("close")
	gl.call("quit_to_menu")
	gl.queue_free()


func _test_anchors() -> void:
	print("── U2-U4 源码锚与快路径 ──")
	var gl = _mk_gl("R262eE")
	var ms = gl.menu_screen
	ms.call("_on_panel_close")
	ms.call("_open_map_select")
	var row0_first: Node = ms.get("_panel_list").get_node_or_null("MapRow_0")
	ms.call("_on_panel_close")
	ms.call("_open_map_select")
	var row0_second: Node = ms.get("_panel_list").get_node_or_null("MapRow_0")
	_check("U2 同档重开快路径（行实例同一=零重建）", row0_first != null and row0_first == row0_second)
	ms.call("_on_panel_close")
	var gl_src := FileAccess.get_file_as_string("res://scripts/loop/game_loop.gd")
	_check("U3 菜单帧率帽锚（mobile 门 Engine.max_fps = 60 单点）",
		gl_src.count("Engine.max_fps = 60") == 1)
	var ds_src := FileAccess.get_file_as_string("res://autoload/debug_stats.gd")
	_check("U4 诊断环 MENU 降频锚（DIAG_MENU_SAMPLE_MS 消费单点）",
		ds_src.count("DIAG_MENU_SAMPLE_MS") == 2)   # 常量定义+消费各一
	gl.queue_free()
