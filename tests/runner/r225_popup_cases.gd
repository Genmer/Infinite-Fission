# tests/runner/r225_popup_cases.gd
# R225 跳字位图化用例体（由 test_r225_popup.gd 入口在 autoload 就绪后运行时加载编译）。
# 覆盖（方案口径，落点 damage_popup.gd 位图门 / popup_glyph_atlas.gd 图集——桌面 Label
# 路径零扰动由 override=0 回归锁承担；manager 并入/帽契约锁位图门下不回归）：
#   · 门控：平台自动（headless 桌面=Label）/ override=0 强制 Label / override=1 图集
#     未就绪回退 Label（开局早预热未消化=表现不劣化于现状）/ 就绪后位图
#   · 图集契约：12 字形（0-9+免疫）全烤、meta 齐、幂等重烤零成本、纹理/材质单例
#   · 字形序列：12345 → 5 sprite 顺序/region 正确；merge 累计重排；位数收缩隐藏
#   · CRIT/元素 tint：元素色染填充（modulate）、CRIT/tier 字号乘区（sprite scale）、
#     IMMUNE 文案与灰蓝、DOT ceil、HEAL 样式色
#   · manager 契约（位图门）：层1 同目标并入 + CRIT 升格 + 低档数量帽 + REACTION 豁免臂
#     （Label 惰性补建 + 位图 sprite 退位）
#   · R212 deferred：位图门下首排版分流照走（defer 覆写→置脏→tick 首刷）
#   · 结构断言：位图路径数值臂全样式 Label 计数=0（_label==null）
extends RefCounted

const DT := 1.0 / 120.0
const POPUP_SCENE := "res://scenes/ui/damage_popup.tscn"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_test_gate_before_ready()
	_test_atlas_contract()
	_test_glyph_sequence()
	_test_tint_and_scale()
	_test_manager_contracts_bitmap()
	_test_deferred_first_layout_bitmap()
	_test_label_gate_regression()
	_test_zero_label_structure()
	_teardown()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])


func _teardown() -> void:
	# 覆写口用毕复位（套件纪律：bitmap_override / defer_first_layout 静态复位 -1）
	DamagePopup.bitmap_override = -1
	DamagePopup.defer_first_layout = -1


func _new_popup() -> DamagePopup:
	# 直建实例（池化实体直测先例 r221_fixreg ⑥：new + add_child，不经池不二次 release）
	var popup := DamagePopup.new()
	tree.root.add_child(popup)
	return popup


# ── 门控：图集未就绪回退（须最先跑——build 后 ready 恒真） ─────────────
func _test_gate_before_ready() -> void:
	print("── R225 门控·未就绪回退 ──")
	DamagePopup.bitmap_override = 1
	_check("未就绪门：override=1 但图集未烤 → gate=false（回退 Label，零战斗期烤图）",
		not DamagePopup.bitmap_gate()
			and not PopupGlyphAtlas.ready()
			and PopupGlyphAtlas.built_count() < PopupGlyphAtlas.glyph_count())
	# 逐 cell 烤（产品路径 op:6 同款）：中途未就绪、全量后就绪
	PopupGlyphAtlas.build_cell(0)
	_check("分帧烤①：首 cell 后仍未就绪（ready=全量完成判定）",
		not PopupGlyphAtlas.ready() and PopupGlyphAtlas.built_count() == 1)
	PopupGlyphAtlas.build_all()
	_check("分帧烤②：build_all 后就绪（12 字形全烤）",
		PopupGlyphAtlas.ready() and PopupGlyphAtlas.built_count() == PopupGlyphAtlas.glyph_count()
			and DamagePopup.bitmap_gate())


# ── 图集契约 ─────────────────────────────────────────────────────────
func _test_atlas_contract() -> void:
	print("── R225 图集契约 ──")
	_check("字形集：12 字形（0-9 + 免疫，审计口径——无负号/无万乙/无 CRIT 文字标记）",
		PopupGlyphAtlas.glyph_count() == 12
			and String.chr(PopupGlyphAtlas.glyph_code_at(0)) == "0"
			and String.chr(PopupGlyphAtlas.glyph_code_at(9)) == "9"
			and String.chr(PopupGlyphAtlas.glyph_code_at(10)) == "免"
			and String.chr(PopupGlyphAtlas.glyph_code_at(11)) == "疫")
	var tex := PopupGlyphAtlas.glyph_texture()
	_check("图集纹理：单张共享（ImageTexture 非空 / 双通道掩码画布）", tex != null)
	var all_meta := true
	for i in range(PopupGlyphAtlas.glyph_count()):
		var m: Dictionary = PopupGlyphAtlas.glyph_meta(PopupGlyphAtlas.glyph_code_at(i))
		if m.is_empty() or float(m["adv"]) <= 0.0 or (m["rect"] as Rect2).size.x <= 0.0:
			all_meta = false
	_check("字形 meta：全量齐备（adv>0 / bbox 非空 / code 反查一致）", all_meta)
	# 幂等：重烤零成本（_cell_done 短路——重复入队/重放安全）
	PopupGlyphAtlas.build_all()
	_check("幂等：build_all 重放同纹理（cell 短路，不重烤不换纹理）",
		PopupGlyphAtlas.glyph_texture() == tex)
	var mat0 := PopupGlyphAtlas.glyph_material()
	_check("共享材质：单例（同实例——全跳字合批前提）",
		mat0 != null and PopupGlyphAtlas.glyph_material() == mat0)


# ── 字形序列（12345 → 5 sprite 顺序正确；merge 重排；位数收缩） ────────
func _decode(p_popup: DamagePopup) -> String:
	var out := ""
	for sp in p_popup._glyph_sprites:
		if not sp.visible:
			continue
		var cx := int(floor(sp.region_rect.position.x / float(PopupGlyphAtlas.CELL)))
		var cy := int(floor(sp.region_rect.position.y / float(PopupGlyphAtlas.CELL)))
		out += String.chr(PopupGlyphAtlas.glyph_code_at(cy * PopupGlyphAtlas.COLS + cx))
	return out


func _test_glyph_sequence() -> void:
	print("── R225 字形序列 ──")
	DamagePopup.bitmap_override = 1
	var popup := _new_popup()
	popup.show_popup(Vector2(100.0, 200.0), 12345.0, GameConst.PopupStyle.NORMAL, 7, 0)
	_check("序列：12345 → 恰 5 个位图 sprite（_decode 顺序 1..5）",
		_decode(popup) == "12345" and popup._glyph_sprites.size() == 5,
		"decode=%s" % _decode(popup))
	_check("结构：位图门下零 Label 节点（数值臂 Label 计数=0 本体）", popup._label == null)
	# 同贴图同材质（同桶语义：全跳字共享图集 + 共享 ShaderMaterial → 合并 draw call）
	var same_batch := true
	for sp in popup._glyph_sprites:
		if sp.texture != PopupGlyphAtlas.glyph_texture() \
				or sp.material != PopupGlyphAtlas.glyph_material():
			same_batch = false
	_check("合批前提：全部 sprite 同图集纹理 + 同共享材质（同贴图同桶）", same_batch)
	# region 正确性：sprite region == 对应字形 meta rect
	var regions_ok := true
	var txt := "12345"
	for i in range(popup._glyph_sprites.size()):
		var expect: Dictionary = PopupGlyphAtlas.glyph_meta(txt.unicode_at(i))
		if (popup._glyph_sprites[i].region_rect as Rect2) != (expect["rect"] as Rect2):
			regions_ok = false
	_check("region：逐 sprite 指向对应字形格（rect 与 meta 全等）", regions_ok)
	# merge 累计重排：12345+100 → tick 首刷 12445
	popup.merge(100.0)
	popup.tick(DT)
	_check("merge：累计 12345+100=12445 → tick 重排序列正确（R189 置脏 tick 刷新）",
		absf(popup.merged_value - 12445.0) <= 0.001 and _decode(popup) == "12445",
		"decode=%s" % _decode(popup))
	# 位数收缩：池复用短值 → 多余 sprite 隐藏
	popup._reset_state()
	popup.show_popup(Vector2(50.0, 60.0), 42.0, GameConst.PopupStyle.NORMAL, 9, 0)
	var hidden_ok := _decode(popup) == "42"
	for k in range(2, popup._glyph_sprites.size()):
		if popup._glyph_sprites[k].visible:
			hidden_ok = false
	_check("位数收缩：池复用 42 → 2 显 + 余量隐藏（Sprite 只增不删纪律）", hidden_ok,
		"decode=%s" % _decode(popup))
	popup.free()


# ── CRIT / 元素 tint / 字号乘区（sprite modulate + scale） ────────────
func _test_tint_and_scale() -> void:
	print("── R225 tint 与字号乘区 ──")
	DamagePopup.bitmap_override = 1
	# ① 元素色（弹级一色 modulate tint）：NORMAL+FIR → 填充染元素色
	var p1 := _new_popup()
	p1.show_popup(Vector2.ZERO, 10.0, GameConst.PopupStyle.NORMAL, 31, 0, GameConst.Element.FIR)
	_check("元素色：NORMAL+FIR → sprite modulate=元素表色（只染填充，描边藏青在图集）",
		p1._glyph_sprites[0].modulate == PopPalette.ELEMENT_COLORS[GameConst.Element.FIR])
	p1.free()
	# ② CRIT 字号：40px 基准 → scale=40/64（除法精确）；tier 3 金档 ×1.6 → 64/64
	var p2 := _new_popup()
	p2.show_popup(Vector2.ZERO, 7.0, GameConst.PopupStyle.CRIT, 32, 0)
	_check("CRIT 字号：scale=40/64（FONT_SIZE_CRIT 等比，无 tier）",
		p2._glyph_sprites[0].scale.is_equal_approx(Vector2(40.0 / 64.0, 40.0 / 64.0)))
	var p3 := _new_popup()
	p3.show_popup(Vector2.ZERO, 80.0, GameConst.PopupStyle.CRIT, 33, 3)
	_check("金档字号：scale=roundi(40×1.6)/64=1.0（量级档乘区同 Label 口径）",
		p3._glyph_sprites[0].scale.is_equal_approx(Vector2.ONE))
	p2.free()
	p3.free()
	# ③ IMMUNE：文案「免疫」+ 灰蓝样式色
	var p4 := _new_popup()
	p4.show_popup(Vector2.ZERO, 0.0, GameConst.PopupStyle.IMMUNE, 34)
	_check("免疫：位图 2 字形顺序「免疫」+ STYLE_COLORS 灰蓝 tint",
		_decode(p4) == "免疫"
			and p4._glyph_sprites[0].modulate
				== DamagePopup.STYLE_COLORS[GameConst.PopupStyle.IMMUNE],
		"decode=%s" % _decode(p4))
	p4.free()
	# ④ DOT ceil 口径：0.5 → 「1」（烧伤 0 观感修复同源）
	var p5 := _new_popup()
	p5.show_popup(Vector2.ZERO, 0.5, GameConst.PopupStyle.DOT, 35)
	_check("DOT ceil：0.5 → 「1」（文本口径与 Label 分支同源）", _decode(p5) == "1",
		"decode=%s" % _decode(p5))
	p5.free()
	# ⑤ HEAL 样式色（非直击不吃元素/档色）
	var p6 := _new_popup()
	p6.show_popup(Vector2.ZERO, 3.0, GameConst.PopupStyle.HEAL, 36)
	_check("HEAL：样式表色 tint（非直击臂）",
		p6._glyph_sprites[0].modulate == DamagePopup.STYLE_COLORS[GameConst.PopupStyle.HEAL])
	p6.free()


# ── manager 契约（位图门：并入 / CRIT 升格 / 帽 / REACTION 豁免臂） ────
func _test_manager_contracts_bitmap() -> void:
	print("── R225 manager 契约（位图门） ──")
	# 自建池+管理器：override=1 后预热 → 池内实例即位图构成（真 GameLoop 池在 boot 期
	# 已按桌面门建成 Label，不能复用——门随 _ready 定格）
	var quality_prev: int = int(Meta.settings("fx_quality"))
	var numbers_prev: bool = bool(Meta.settings("damage_numbers_on"))
	Meta.set_setting("damage_numbers_on", true)
	DamagePopup.bitmap_override = 1
	var pool := PopupPool.new()
	pool.setup(&"r225_popup_t", load(POPUP_SCENE) as PackedScene, 96)
	tree.root.add_child(pool)
	pool.prewarm(96)
	var pm := PopupManager.new()
	pm.setup(pool)
	pm.baseline_provider = Callable()             # 量级档关闭（本段锁合并/帽语义）
	pm.tick(10.0)
	pm.clear_all()
	# 层1 同目标存活即并入：同 uid 两跳 active=1 值累计（位图宿主文本重排正确）
	var r := DamageResult.new()
	r.final_value = 6.0
	r.target_uid = 7101
	r.pos = Vector2(100.0, 200.0)
	r.popup_style = GameConst.PopupStyle.NORMAL
	pm.on_damage_resolved(r)
	pm.tick(0.2)
	var r2 := DamageResult.new()
	r2.final_value = 4.0
	r2.target_uid = 7101
	r2.pos = Vector2(100.0, 200.0)
	r2.popup_style = GameConst.PopupStyle.NORMAL
	pm.on_damage_resolved(r2)
	pm.tick(DT)
	var host := pm._active_list[0] as DamagePopup
	_check("层1 并入（位图）：同 uid 两跳 active=1 / 值累计 10 / 位图序列=10",
		pm.active_popups == 1 and absf(host.merged_value - 10.0) <= 0.001
			and _decode(host) == "10",
		"decode=%s" % _decode(host))
	# CRIT 升格：incoming CRIT 并入 NORMAL 宿主 → 原地升样式（位图下字号乘区跟升）
	var rc := DamageResult.new()
	rc.final_value = 5.0
	rc.target_uid = 7101
	rc.pos = Vector2(100.0, 200.0)
	rc.popup_style = GameConst.PopupStyle.CRIT
	pm.on_damage_resolved(rc)
	pm.tick(DT)
	_check("CRIT 升格（位图）：宿主原地升 CRIT / sprite scale 跟 40px 基准",
		host.style == GameConst.PopupStyle.CRIT
			and host._glyph_sprites[0].scale.is_equal_approx(Vector2(40.0 / 64.0, 40.0 / 64.0)))
	pm.tick(10.0)
	pm.clear_all()
	# 低档数量帽：fx_quality=0 → cap 20，30 uid 直击（位图门不改变节流语义）
	Meta.set_setting("fx_quality", 0)
	for i in range(30):
		var rr := DamageResult.new()
		rr.final_value = 5.0
		rr.target_uid = 7200 + i
		rr.pos = Vector2(40.0 + float(i % 10) * 40.0, 80.0 + float(i / 10) * 40.0)
		rr.popup_style = GameConst.PopupStyle.NORMAL
		pm.on_damage_resolved(rr)
	_check("数量帽（位图）：低档 30 目标封顶 20（R220/R19 档位帽不回归）",
		pm.active_popups == 20, "active=%d" % pm.active_popups)
	pm.tick(10.0)
	pm.clear_all()
	# REACTION 豁免臂：Label 惰性补建 + 位图 sprite 退位（刀面豁免口径的结构锁）
	pm._rxn_frame_stamp = -1
	var rx := DamageResult.new()
	rx.final_value = 9.0
	rx.target_uid = 7300
	rx.pos = Vector2(300.0, 400.0)
	rx.popup_style = GameConst.PopupStyle.REACTION
	rx.element = GameConst.ReactionType.RXN_FIR_ICE
	pm.on_damage_resolved(rx)
	pm.tick(DT)
	var rhost := pm._active_list[-1] as DamagePopup
	_check("REACTION 豁免臂：Label 惰性补建（text=名+值）/ 位图 sprite 全隐藏",
		rhost._label != null and rhost._label.text.contains("碎裂")
			and rhost._label.text.contains("9"),
		"text=%s" % (rhost._label.text if rhost._label != null else "<null>"))
	var any_glyph := false
	for sp in rhost._glyph_sprites:
		if sp.visible:
			any_glyph = true
	_check("REACTION 豁免臂：位图字形零显示（防双渲染）", not any_glyph)
	pm.tick(10.0)
	pm.clear_all()
	# 清场后位图门池复用：数值臂再起字 → Label 退位（visible=false）+ 位图恢复
	var r3 := DamageResult.new()
	r3.final_value = 8.0
	r3.target_uid = 7400
	r3.pos = Vector2(100.0, 100.0)
	r3.popup_style = GameConst.PopupStyle.NORMAL
	pm.on_damage_resolved(r3)
	pm.tick(DT)
	var back := pm._active_list[0] as DamagePopup
	_check("池复用：REACTION 槽位转数值臂 → Label 退位 / 位图序列=8",
		back._label == null or not back._label.visible and _decode(back) == "8",
		"decode=%s" % _decode(back))
	pm.tick(10.0)
	Meta.set_setting("fx_quality", quality_prev)
	Meta.set_setting("damage_numbers_on", numbers_prev)
	pm.free()
	pool.free()


# ── R212 deferred 首排版（位图门照走） ───────────────────────────────
func _test_deferred_first_layout_bitmap() -> void:
	print("── R225 deferred 首排版（位图门） ──")
	DamagePopup.bitmap_override = 1
	DamagePopup.defer_first_layout = 1            # 强制延迟（mobile 通道同构）
	var popup := _new_popup()
	popup.show_popup(Vector2(100.0, 200.0), 456.0, GameConst.PopupStyle.NORMAL, 8, 1)
	_check("deferred：show_popup 后置脏 + 位图字形零显示（首刷让渡 tick）",
		popup._label_dirty and _decode(popup) == "")
	popup.tick(0.016)
	_check("deferred：tick 首刷 → 位图序列=456（R212 驱动序位图同构）",
		not popup._label_dirty and _decode(popup) == "456",
		"decode=%s" % _decode(popup))
	popup.free()
	DamagePopup.defer_first_layout = -1


# ── mobile 门关闭 = 旧路径回归锁（override=0 强制 Label） ─────────────
func _test_label_gate_regression() -> void:
	print("── R225 门关闭回归锁 ──")
	DamagePopup.bitmap_override = 0
	_check("门关闭：override=0 → gate=false（桌面既有路径口径）",
		not DamagePopup.bitmap_gate())
	var popup := _new_popup()
	popup.show_popup(Vector2(100.0, 200.0), 12345.0, GameConst.PopupStyle.NORMAL, 7, 0)
	_check("回归锁：Label 路径原样（_label 就位 / text=12345 / 位图 sprite 零）",
		popup._label != null and popup._label.text == "12345"
			and popup._glyph_sprites.is_empty()
			and popup._label.get_theme_font_size("font_size") == DamagePopup.FONT_SIZE,
		"text=%s" % popup._label.text)
	popup.free()
	# 平台自动门：headless 桌面 = Label（-1 口径零扰动）
	DamagePopup.bitmap_override = -1
	_check("平台自动：headless 桌面 gate=false（桌面零扰动口径）",
		not DamagePopup.bitmap_gate())


# ── 结构断言：位图路径数值臂全样式 Label 计数=0 ───────────────────────
func _test_zero_label_structure() -> void:
	print("── R225 位图路径 Label 计数=0 结构断言 ──")
	DamagePopup.bitmap_override = 1
	var styles: Array = [
		GameConst.PopupStyle.NORMAL, GameConst.PopupStyle.CRIT,
		GameConst.PopupStyle.DOT, GameConst.PopupStyle.HEAL,
		GameConst.PopupStyle.XP, GameConst.PopupStyle.IMMUNE,
		GameConst.PopupStyle.CHARGE_BURST,
	]
	var zero_label := true
	var any_glyph := true
	var uid := 7500
	for st: int in styles:
		var popup := _new_popup()
		var val := 12.0 if st != GameConst.PopupStyle.IMMUNE else 0.0
		popup.show_popup(Vector2(10.0, 10.0), val, st, uid, 0, GameConst.Element.KIN)
		if popup._label != null:
			zero_label = false
		if _decode(popup).is_empty():
			any_glyph = false
		popup.free()
		uid += 1
	_check("结构断言：数值臂全样式（NORMAL/CRIT/DOT/HEAL/XP/IMMUNE/CHARGE_BURST）"
		+ "位图门下 Label 计数=0 且位图字形在位", zero_label and any_glyph)
