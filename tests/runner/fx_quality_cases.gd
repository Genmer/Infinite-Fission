# tests/runner/fx_quality_cases.gd
# 特效质量档位用例体（由 test_fx_quality.gd 入口加载）。
extends RefCounted

const DT := 1.0 / 120.0
const MAIN_SCENE := "res://scenes/main.tscn"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	_test_setting_roundtrip()
	_test_popup_scaling()
	_test_reaction_popup()
	_test_codex_preview_scale()
	_test_particle_scaling()
	_test_rocket_blast_fx()
	_teardown_game_loop()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "GameLoopUnderTest"
	tree.get_root().add_child(_gl)


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	Meta.set_setting("fx_quality", 2)             # 复位出厂档（防污染其他套件）
	if _gl != null:
		_gl.free()
		_gl = null


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])


func _test_setting_roundtrip() -> void:
	print("── 设置读写 ──")
	_check("出厂默认：fx_quality = 2（高）", int(Meta.settings("fx_quality")) == 2)
	Meta.set_setting("fx_quality", 0)
	_check("写口：低档落盘读回", int(Meta.settings("fx_quality")) == 0)
	Meta.set_setting("fx_quality", 7)
	_check("写口：越界钳上界（7→2）", int(Meta.settings("fx_quality")) == 2)
	Meta.set_setting("fx_quality", -3)
	_check("写口：越界钳下界（-3→0）", int(Meta.settings("fx_quality")) == 0)
	Meta.set_setting("fx_quality", 2)
	_check("复位：高档", int(Meta.settings("fx_quality")) == 2)


func _test_popup_scaling() -> void:
	print("── 跳字档位 ──")
	_check("档位表：跳字上限 20/40/80",
		PopupManager.max_active_for(0) == 20 and PopupManager.max_active_for(1) == 40
		and PopupManager.max_active_for(2) == 80)
	_check("档位表：合并窗 0.3/0.2/0.12s",
		absf(PopupManager.merge_window_for(0) - 0.3) < 0.001
		and absf(PopupManager.merge_window_for(1) - 0.2) < 0.001
		and absf(PopupManager.merge_window_for(2) - 0.12) < 0.001)
	# 行为：低档下超过 20 个不同目标跳字 → 活跃数封顶 20
	Meta.set_setting("fx_quality", 0)
	var pos := Vector2(360.0, 400.0)
	for i in range(30):
		var r := DamageResult.new()
		r.final_value = 5.0 + float(i)          # 每个不同 uid 一条（无合并）
		r.target_uid = 100000 + i
		r.pos = pos + Vector2(0.0, float(i % 7) * 8.0)
		r.popup_style = GameConst.PopupStyle.NORMAL
		_gl.popup_manager.on_damage_resolved(r)
	_check("低档：跳字同屏封顶 20（30 个目标只出 20 条）",
		int(_gl.popup_manager.active_popups) == 20,
		"实得 %d" % int(_gl.popup_manager.active_popups))
	# 高档恢复：同屏上限放宽（活跃列表此刻 20 → 再来 10 条可增长）
	Meta.set_setting("fx_quality", 2)
	for i in range(30, 45):
		var r := DamageResult.new()
		r.final_value = 5.0
		r.target_uid = 200000 + i
		r.pos = pos
		r.popup_style = GameConst.PopupStyle.NORMAL
		_gl.popup_manager.on_damage_resolved(r)
	_check("高档：上限放宽到 80（35 条全部在册）",
		int(_gl.popup_manager.active_popups) == 35,
		"实得 %d" % int(_gl.popup_manager.active_popups))
	_gl.popup_manager.clear_all()


# ── R186 反应字体（碎裂/过载/超导双色大字 + 分桶合并/升格 + 密度护栏） ──
func _test_reaction_popup() -> void:
	print("── R186 反应字体 ──")
	var pm: PopupManager = _gl.popup_manager
	var pool: PopupPool = _gl.pools[&"popup"]
	pool.prewarm(GameConfig.get_pool_capacity(&"popup"))
	var numbers_prev: bool = bool(Meta.settings("damage_numbers_on"))
	var provider_prev: Callable = pm.baseline_provider
	Meta.set_setting("damage_numbers_on", true)
	pm.baseline_provider = Callable()             # 分级关闭（量级档噪声隔离）
	pm.tick(10.0)
	pm.clear_all()
	# ① REACTION 规格表分流：54px + 12px 描边 + 双色真分通道（碎裂）
	pm._rxn_frame_stamp = -1                      # 帧计数器隔离（同帧护栏判据重置）
	var r := DamageResult.new()
	r.final_value = 12.0
	r.target_uid = 610001
	r.pos = Vector2(300.0, 400.0)
	r.popup_style = GameConst.PopupStyle.REACTION
	r.element = GameConst.ReactionType.RXN_FIR_ICE
	pm.on_damage_resolved(r)
	var p0: DamagePopup = pm._active_list[0]
	_check("R186 碎裂大字：54px 字号 + 12px 描边 + 「中文名+数字」（R192 名+值纯函数）",
		pm.active_popups == 1
		and p0._label.get_theme_font_size("font_size") == DamagePopup.FONT_SIZE_REACTION
		and p0._label.get_theme_constant("outline_size") == DamagePopup.OUTLINE_PX_REACTION
		and p0._label.text == "碎裂12")
	_check("R186 碎裂大字：双色通道（暖雪白填充/绯红描边）+ 乘色退位 + 专属字型",
		p0._label.get_theme_color("font_color") == PopPalette.RXN_FILL_SHATTER
		and p0._label.get_theme_color("font_outline_color") == PopPalette.RXN_LINE_SHATTER
		and p0._label.self_modulate == Color.WHITE
		and p0._label.get_theme_font("font") == StickerTheme.font_reaction(0))
	# ② 升格（R2b）：同 uid 直击小字在窗吃到大额反应结算 → 原地换反应样式重弹
	var rd := DamageResult.new()
	rd.final_value = 12.0
	rd.target_uid = 610002
	rd.pos = Vector2(300.0, 400.0)
	rd.popup_style = GameConst.PopupStyle.NORMAL
	pm.on_damage_resolved(rd)
	var rr := DamageResult.new()
	rr.final_value = 8.0
	rr.target_uid = 610002
	rr.pos = Vector2(300.0, 400.0)
	rr.popup_style = GameConst.PopupStyle.REACTION
	rr.element = GameConst.ReactionType.RXN_FIR_LTG
	pm.on_damage_resolved(rr)
	var p1: DamagePopup = pm._active_list[1]
	_check("R186 升格：直击小字原地换过载大字（active 不涨 / 数值并入 12+8）",
		pm.active_popups == 2 and p1.style == GameConst.PopupStyle.REACTION
		and absf(p1.merged_value - 20.0) <= 0.001)
	_check("R186 升格：过载双色（爆裂橙填充/暗电紫描边）+ 斜体 900 字型 + merge 后文本==名+新值",
		p1._label.get_theme_color("font_color") == PopPalette.RXN_FILL_OVERLOAD
		and p1._label.get_theme_color("font_outline_color") == PopPalette.RXN_LINE_OVERLOAD
		and p1._label.get_theme_font("font") == StickerTheme.font_reaction(1)
		and p1._label.text == "过载20")
	# ③ 直击遇反应大字在窗（R2c）：不吞大字，新起小字下移 +20px
	var rr2 := DamageResult.new()
	rr2.final_value = 9.0
	rr2.target_uid = 610003
	rr2.pos = Vector2(300.0, 400.0)
	rr2.popup_style = GameConst.PopupStyle.REACTION
	rr2.element = GameConst.ReactionType.RXN_FIR_ICE
	pm.on_damage_resolved(rr2)
	var rd2 := DamageResult.new()
	rd2.final_value = 5.0
	rd2.target_uid = 610003
	rd2.pos = Vector2(300.0, 400.0)
	rd2.popup_style = GameConst.PopupStyle.NORMAL
	pm.on_damage_resolved(rd2)
	var small: DamagePopup = pm._active_list[-1]
	_check("R186 直击让行：反应大字不被吞，新起小字下移 +20px（30px 常规字号）",
		pm.active_popups == 4
		and small.style == GameConst.PopupStyle.NORMAL
		and small.position == Vector2(300.0, 420.0)
		and small._label.get_theme_font_size("font_size") == DamagePopup.FONT_SIZE)
	# ④ 超导文字标签（R3）：RXN_ICE_LTG 无 DamageResult 通道 → 纯文字「超导-30%」
	# （R192：起字时读表一次性格式化 rxn_stat；merged_value 恒 0.0——bucket3 拒值契约）
	pm.on_reaction_triggered(GameConst.ReactionType.RXN_ICE_LTG, Vector2(320.0, 420.0), 610004)
	var p4: DamagePopup = pm._active_list[-1]
	_check("R186 超导标签：纯文字「超导-30%」+ 冰晶白/靛紫双色 + 斜体 700 字型 + merged_value 恒 0",
		pm.active_popups == 5 and p4._label.text == "超导-30%"
		and absf(p4.merged_value) <= 0.001
		and p4._label.get_theme_color("font_color") == PopPalette.RXN_FILL_SUPER
		and p4._label.get_theme_color("font_outline_color") == PopPalette.RXN_LINE_SUPER
		and p4._label.get_theme_font("font") == StickerTheme.font_reaction(2))
	# ④c [R192] bucket3 拒值（§4.d 文字桶无 merge 入口）：同 uid 反应数值并入禁入文字标签
	var before_b3 := int(pm.active_popups)
	var rv3 := DamageResult.new()
	rv3.final_value = 100.0
	rv3.target_uid = 610004
	rv3.pos = Vector2(320.0, 420.0)
	rv3.popup_style = GameConst.PopupStyle.REACTION
	rv3.element = GameConst.ReactionType.RXN_FIR_ICE
	pm._rxn_frame_stamp = -1                  # 放行帧闸（聚焦桶位判据本身）
	pm.on_damage_resolved(rv3)
	_check("R192 bucket3 拒值：文字标签不吞值（text/merged_value 不变）+ 数值走独立 bucket1 起字",
		int(pm.active_popups) == before_b3 + 1
		and p4._label.text == "超导-30%" and absf(p4.merged_value) <= 0.001,
		"active=%d" % int(pm.active_popups))
	# ④d [R192] R2c 补缺口：直击遇存活 bucket3 文字标签 → 新起小字下移 +20px（防叠扩到文字桶）
	var rd4 := DamageResult.new()
	rd4.final_value = 5.0
	rd4.target_uid = 610004
	rd4.pos = Vector2(320.0, 420.0)
	rd4.popup_style = GameConst.PopupStyle.NORMAL
	pm.on_damage_resolved(rd4)
	var small4: DamagePopup = pm._active_list[-1]
	_check("R192 直击让行（bucket3）：文字标签不被吞，小字下移 offset==(0,20)",
		small4 != null and small4.style == GameConst.PopupStyle.NORMAL
		and small4.position == Vector2(320.0, 440.0),
		"pos=%s" % (str(small4.position) if small4 != null else "-"))
	# ④b 碎裂/过载禁走 reaction_triggered 起字（管线 settle 已派生，二次会翻倍）
	var before := int(pm.active_popups)
	pm.on_reaction_triggered(GameConst.ReactionType.RXN_FIR_ICE, Vector2(320.0, 420.0), 610005)
	_check("R186 超导专属：碎裂 reaction_triggered 不在此起字（防翻倍刷屏）",
		int(pm.active_popups) == before)
	# ⑤ 零值短路（R4c）：反应结算值 ≤0.5 不起大字（防 54px 大「0」）
	var rz := DamageResult.new()
	rz.final_value = 0.3
	rz.target_uid = 610006
	rz.pos = Vector2(300.0, 400.0)
	rz.popup_style = GameConst.PopupStyle.REACTION
	rz.element = GameConst.ReactionType.RXN_FIR_ICE
	pm.on_damage_resolved(rz)
	_check("R186 零值短路：≤0.5 反应结算不起大字", int(pm.active_popups) == before)
	# ⑥ 同帧起字上限（R4a，低档 = 1）：超限就近并入本帧已起同反应大字（位置不动）
	Meta.set_setting("fx_quality", 0)
	pm._rxn_frame_stamp = -1
	var ra := DamageResult.new()
	ra.final_value = 5.0
	ra.target_uid = 610007
	ra.pos = Vector2(300.0, 400.0)
	ra.popup_style = GameConst.PopupStyle.REACTION
	ra.element = GameConst.ReactionType.RXN_FIR_ICE
	pm.on_damage_resolved(ra)
	var rb := DamageResult.new()
	rb.final_value = 7.0
	rb.target_uid = 610008
	rb.pos = Vector2(310.0, 410.0)
	rb.popup_style = GameConst.PopupStyle.REACTION
	rb.element = GameConst.ReactionType.RXN_FIR_ICE
	pm.on_damage_resolved(rb)
	var host: DamagePopup = pm._active_list[-1]
	_check("R186 帧上限（低档=1）：同帧第二条就近并入宿主（数值累加/位置不动/active 不涨）",
		int(pm.active_popups) == before + 1
		and absf(host.merged_value - 12.0) <= 0.001
		and host.position == Vector2(300.0, 400.0))
	pm._rxn_frame_stamp = -1                      # 模拟跨帧（frame 号推进）
	var rc := DamageResult.new()
	rc.final_value = 3.0
	rc.target_uid = 610009
	rc.pos = Vector2(300.0, 400.0)
	rc.popup_style = GameConst.PopupStyle.REACTION
	rc.element = GameConst.ReactionType.RXN_FIR_ICE
	pm.on_damage_resolved(rc)
	_check("R186 帧上限：跨帧计数重置后可再起", int(pm.active_popups) == before + 2)
	# ⑦ 满池回收（R4b）：REACTION 满池时回收最老非反应槽再起字
	pm.tick(10.0)
	pm.clear_all()
	pm._rxn_frame_stamp = -1
	for i in range(20):
		var rf := DamageResult.new()
		rf.final_value = 1.0
		rf.target_uid = 620000 + i
		rf.pos = Vector2(100.0 + float(i), 100.0)
		rf.popup_style = GameConst.PopupStyle.NORMAL
		pm.on_damage_resolved(rf)
	var dropped0: int = pm.dropped_count()
	var rrx := DamageResult.new()
	rrx.final_value = 9.0
	rrx.target_uid = 620100
	rrx.pos = Vector2(300.0, 400.0)
	rrx.popup_style = GameConst.PopupStyle.REACTION
	rrx.element = GameConst.ReactionType.RXN_FIR_ICE
	pm.on_damage_resolved(rrx)
	var rxn_slots := 0
	for p: DamagePopup in pm._active_list:
		if p.style == GameConst.PopupStyle.REACTION:
			rxn_slots += 1
	_check("R186 满池回收：最老直击槽让位反应大字（active 守恒 20 / 不涨丢弃计数）",
		int(pm.active_popups) == 20 and pm.dropped_count() == dropped0 and rxn_slots == 1
		and (pm._active_list[0] as DamagePopup).target_uid == 620001)
	# ⑧ 池复用串色防线（§4.1）：同一槽先起反应大字 → 归还 → LIFO 必取同槽再起直击
	# 小字 = 贴纸出厂态（无 54px/双色/大字字型残留）
	pm.tick(10.0)
	pm.clear_all()
	pm._rxn_frame_stamp = -1
	var rs := DamageResult.new()
	rs.final_value = 6.0
	rs.target_uid = 630000
	rs.pos = Vector2(300.0, 400.0)
	rs.popup_style = GameConst.PopupStyle.REACTION
	rs.element = GameConst.ReactionType.RXN_FIR_ICE
	pm.on_damage_resolved(rs)
	pm.tick(10.0)                                 # 归还（release → _reset_state 清覆盖）
	var rn := DamageResult.new()
	rn.final_value = 1.0
	rn.target_uid = 630001
	rn.pos = Vector2(300.0, 400.0)
	rn.popup_style = GameConst.PopupStyle.NORMAL
	pm.on_damage_resolved(rn)
	var p8: DamagePopup = pm._active_list[0]
	_check("R186 串色防线：复用反应槽起直击小字 = 白填充/藏青描边/8px/30px/常规字型",
		p8._label.get_theme_color("font_color") == Color.WHITE
		and p8._label.get_theme_color("font_outline_color") == PopPalette.OUTLINE
		and p8._label.get_theme_constant("outline_size") == DamagePopup.OUTLINE_PX
		and p8._label.get_theme_font_size("font_size") == DamagePopup.FONT_SIZE
		and p8._label.get_theme_font("font") == StickerTheme.font()
		and p8._label.text == "1")
	# 复位（防污染其他用例）
	pm.tick(10.0)
	pm.clear_all()
	pm.baseline_provider = provider_prev
	Meta.set_setting("damage_numbers_on", numbers_prev)
	Meta.set_setting("fx_quality", 2)


# ── R192 图鉴预览缩放（visual 批1：CODEX_PREVIEW_SCALE 单源 + pivot 居中适配 140×78 格） ──
func _test_codex_preview_scale() -> void:
	print("── R192 图鉴预览 scale == CODEX_PREVIEW_SCALE ──")
	var menu = _gl.menu_screen
	if menu == null:
		_check("前置：MenuScreen 就绪（GameLoop 子树）", false)
		return
	menu._on_lobby_pressed("codex")
	menu._on_codex_tab("反应")
	var prev: Label = null
	for c in menu._panel_list.get_children():
		if not c.is_queued_for_deletion():
			prev = (c as Control).get_node_or_null("RxnPreview") as Label
			break
	_check("R192 预览缩放：prev.scale == CODEX_PREVIEW_SCALE(0.5) 且 pivot_offset==size×0.5（居中适配格）",
		prev != null and is_equal_approx(prev.scale.x, DamagePopup.CODEX_PREVIEW_SCALE)
		and is_equal_approx(prev.scale.y, DamagePopup.CODEX_PREVIEW_SCALE)
		and is_equal_approx(prev.pivot_offset.x, prev.size.x * 0.5)
		and is_equal_approx(prev.pivot_offset.y, prev.size.y * 0.5),
		"scale=%s" % (str(prev.scale) if prev != null else "-"))
	menu._on_panel_close()


func _test_particle_scaling() -> void:
	print("── 粒子档位 ──")
	var gf := _gl.game_feel
	if gf == null or gf.particles == null:
		_check("粒子档位：GameFeel/粒子注入就绪", false)
		return
	var r := DamageResult.new()
	r.final_value = 5.0
	r.target_uid = 999999
	r.pos = Vector2(300.0, 600.0)
	r.popup_style = GameConst.PopupStyle.NORMAL
	# 低档：普命中不出粒子
	Meta.set_setting("fx_quality", 0)
	var b0 := gf.particles.burst_requests
	r.is_crit = false
	gf.on_damage_resolved(r)
	_check("低档：普命中 0 粒子爆发", int(gf.particles.burst_requests) == b0)
	r.is_crit = true
	gf.on_damage_resolved(r)
	_check("低档：暴击保留粒子（打击感底线）", int(gf.particles.burst_requests) == b0 + 1)
	# 高档：普命中恢复
	Meta.set_setting("fx_quality", 2)
	r.is_crit = false
	gf.on_damage_resolved(r)
	_check("高档：普命中恢复粒子", int(gf.particles.burst_requests) == b0 + 2)

# ── R35/R36 火箭筒四层命中爆 ──────────────────────────────────────
func _test_rocket_blast_fx() -> void:
	print("── 火箭命中四层爆（R36 范围爆炸显示护栏） ──")
	# 找 FX 层（elemental_fx_layer 挂 GameLoop 子树；事件订阅已在 boot 完成）
	var fx: Node = null
	var stack: Array[Node] = [_gl]
	while not stack.is_empty() and fx == null:
		var cur: Node = stack.pop_front()
		if cur.has_method("_on_kill_blast") and cur.get("_blasts") != null:
			fx = cur
			break
		for c in cur.get_children():
			stack.append(c)
	_check("前置：FX 层在册（_blasts 池持有者）", fx != null)
	if fx == null:
		return
	var blasts: Array = fx.get("_blasts")
	# 清场：把所有槽计时归零（防其他用例残留）
	for slot: Dictionary in blasts:
		slot["left"] = 0.0
	EventBus.emit_kill_blast(Vector2(360.0, 640.0), 110.0)
	_check("四层爆：emit 后计时槽就位", blasts.size() > 0 and float(blasts[0]["left"]) > 0.0)
	var slot0: Dictionary = blasts[0]
	var vis := 0
	for key: String in ["flash", "fire", "ring", "smoke"]:
		if slot0.has(key) and (slot0[key] as Sprite2D).visible:
			vis += 1
	_check("四层爆：白闪/火球/冲击环/烟尘 四层全可见", vis == 4, "visible=%d" % vis)
	_check("四层爆：特效半径联动结算半径（r1 = 110×1.25）",
		is_equal_approx(float(slot0["r1"]), 137.5), "r1=%.1f" % float(slot0["r1"]))
	# 推进 0.6s → 全层自熄（寿命兜底）
	for i in range(40):
		fx.call("_tick_blasts", 0.016)
	var all_off := true
	for slot: Dictionary in blasts:
		if float(slot["left"]) > 0.0:
			all_off = false
	_check("四层爆：0.64s 后全层自熄", all_off)
