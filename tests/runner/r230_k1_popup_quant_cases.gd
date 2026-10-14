# tests/runner/test_r230_k1_popup_quant_cases.gd
# R230 K1「跳字根 alpha 渐隐 4 档量化」验收用例体（由 test_r230_k1_popup_quant.gd 入口
# 运行时加载；骨架照 r229_fx_quantize_cases 既有 -cases 结构）。
# 覆盖（刀面 acceptance 逐条）：
#   ① 量化档位契约：Q_ALPHA_STEPS==4 + _qa 逐界值/越界钳制（roundi(clamp(a,0,1)*4)/4，
#      R229 _qa 同式同界值表）。
#   ② 两写点全覆盖（grep 钉）：damage_popup.gd 源内 modulate.a 写点恰 2 处
#      （tick 淡出① / _reset_state 复位②）且逐处均含 _qa(——旧直写零残留；
#      写点①②逐字面钉 + 旧直写字面「modulate.a = fx_opacity」缺席断言。
#   ③ Label 兜底路径回归（bitmap_override=0）：show_popup → 分相位 tick → 根 modulate.a
#      精确落 {1.0, 0.75, 0.5, 0.25, 0.0} 五档（0.96→1.0 / 0.84→0.75 / 0.6156→0.5 /
#      0.36→0.25 / 0→0）；Label 节点在位、文本口径不变。
#   ④ 位图路径回归（PopupGlyphAtlas.build_all + bitmap_override=1）：同拍表逐位同值
#      （根 modulate 双路径同源——量化不分路径）；字形 sprite 在位、数值臂零 Label。
#   ⑤ fx_opacity 折乘量化：fx_opacity=0.3 → tick t=0.25 → 0.3×0.9375=0.28125→0.25；
#      _reset_state → _qa(0.3)=0.25（复位值恒等首拍值=「防池复用闪帧」契约保持）。
#   ⑥ 多层渐隐不串档：6 跳字微相位差并发 → 全部 modulate.a∈四分档且 distinct 坍缩
#      （连续 6 值→量化 ≤3 档）；单件 tick 其余逐位不动（逐实例独立，无串写）。
#   ⑦ 池复用链：show→tick→_reset_state→复位档 → 再 show 首拍=复位档（同档无闪帧）。
# 环境钉：DamagePopup.bitmap_override / defer_first_layout 用毕复位 -1（套件纪律）；
#   DamagePopup.fx_opacity 静态乘区快照还原；图集 build_all 进程内持久（r225 先例，无副作用）。
extends RefCounted

const POPUP_SRC := "res://scripts/ui/damage_popup.gd"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _fxo_prev: float = 1.0


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(2301004)
	_fxo_prev = DamagePopup.fx_opacity
	PopupGlyphAtlas.build_all()                   # 位图臂就绪（r225 先例：产品路径 build_all）
	_test_qa_contract()
	_test_write_points_grep()
	_test_label_path_fade_grid()
	_test_bitmap_path_fade_grid()
	_test_fx_opacity_fold()
	_test_multi_popup_no_cross()
	_test_pool_reuse_chain()
	_teardown()
	_summary()


func fail_count() -> int:
	return _fail


# ── 支撑 ──────────────────────────────────────────────────────────
func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])


func _summary() -> void:
	print("────────────────────────────────────────")
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])


func _teardown() -> void:
	DamagePopup.bitmap_override = -1              # 覆写口用毕复位（套件纪律，r225 同款）
	DamagePopup.defer_first_layout = -1
	DamagePopup.fx_opacity = _fxo_prev            # 乘区快照还原（防跨套件污染）


func _new_popup() -> DamagePopup:
	# 直建实例（池化实体直测先例 r221_fixreg ⑥ / r225 同款：new + add_child，不经池）
	var popup := DamagePopup.new()
	tree.root.add_child(popup)
	return popup


func _on_grid(p_a: float) -> bool:
	# 四分档判定：a∈[0,1] 且 a×4 为整数（量化值均为 2 的幂次分母——精确二进制表示）
	if p_a < -0.0001 or p_a > 1.0001:
		return false
	var q := p_a * 4.0
	return absf(q - roundf(q)) < 0.01


# ── ① _qa 契约 ────────────────────────────────────────────────────
func _test_qa_contract() -> void:
	print("── ① _qa 四分档契约 ──")
	_check("① Q_ALPHA_STEPS==4（四分档 {0, 0.25, 0.5, 0.75, 1.0}，R229 同值）",
		DamagePopup.Q_ALPHA_STEPS == 4)
	# roundi(clamp(a,0,1)*4)/4 逐界值（避 0.125/0.375 等半界点，R229 界值表同款）
	var q_cases := {
		-0.3: 0.0, 0.0: 0.0, 0.124: 0.0, 0.126: 0.25, 0.3: 0.25, 0.37: 0.25,
		0.38: 0.5, 0.5: 0.5, 0.62: 0.5, 0.63: 0.75, 0.7: 0.75, 0.87: 0.75,
		0.88: 1.0, 1.0: 1.0, 1.7: 1.0,
	}
	var ok := true
	var bad := ""
	for k in q_cases:
		var got := DamagePopup._qa(float(k))
		if absf(got - float(q_cases[k])) > 0.0001:
			ok = false
			bad = "%s→%s（期望 %s）" % [str(k), str(got), str(q_cases[k])]
			break
	_check("① _qa 契约：roundi(clamp(a,0,1)*4)/4 逐界值（含越界钳制到 [0,1]）", ok, bad)


# ── ② 两写点全覆盖（grep 钉） ─────────────────────────────────────
func _test_write_points_grep() -> void:
	print("── ② 两写点全覆盖（源级 grep） ──")
	var fa := FileAccess.open(POPUP_SRC, FileAccess.READ)
	_check("② 前置：damage_popup.gd 源可读", fa != null)
	if fa == null:
		return
	var src := fa.get_as_text()
	fa.close()
	# 写点扫描：行内出现 modulate.a 且其后（去空白）以「=」起（非 ==/!=/:=）= 写点
	var lines := src.split("\n")
	var writes: Array[String] = []
	for ln: String in lines:
		var idx := ln.find("modulate.a")
		while idx != -1:
			var rest := ln.substr(idx + 10).strip_edges()
			if rest.begins_with("=") and not rest.begins_with("=="):
				writes.append(ln.strip_edges())
			idx = ln.find("modulate.a", idx + 1)
	_check("② 写点总数==2（tick 淡出① + _reset_state 复位②，无第三写点）",
		writes.size() == 2, "writes=%d %s" % [writes.size(), str(writes)])
	# 逐写点过 _qa 判定：行内直含 _qa( = 直包；RHS 为单标识符（等值跳过写形态
	# 「modulate.a = a」）时认源内「var <id> := _qa(」声明——量化值经局部变量中转。
	var all_qa := true
	for w in writes:
		if w.contains("_qa("):
			continue
		var rhs := w.substr(w.find("=") + 1).strip_edges()
		if rhs.is_valid_identifier() and src.contains("var %s := _qa(" % rhs):
			continue
		all_qa = false
	_check("② 全部写点过 _qa()（直包或经 _qa 声明的局部量——旧直写零残留）",
		all_qa and writes.size() == 2, str(writes))
	_check("② 写点①字面钉：tick 内 var a := _qa(fx_opacity * clampf(1.0 - t * t, 0.0, 1.0))",
		src.contains("var a := _qa(fx_opacity * clampf(1.0 - t * t, 0.0, 1.0))"))
	_check("② 写点②字面钉：_reset_state 内 modulate.a = _qa(fx_opacity)",
		src.contains("modulate.a = _qa(fx_opacity)"))
	_check("② 旧直写退役：字面「modulate.a = fx_opacity」零残留",
		not src.contains("modulate.a = fx_opacity"))
	_check("② 机制块在位：Q_ALPHA_STEPS := 4 契约常量",
		src.contains("const Q_ALPHA_STEPS := 4"))


# ── ③ Label 兜底路径回归（bitmap_override=0） ─────────────────────
func _test_label_path_fade_grid() -> void:
	print("── ③ Label 路径分相位档位（bitmap_override=0） ──")
	DamagePopup.bitmap_override = 0
	var popup := _new_popup()
	popup.show_popup(Vector2(100.0, 200.0), 10.0, GameConst.PopupStyle.NORMAL)
	# 拍表：t=0.2→raw0.96→1.0 / t=0.4→0.84→0.75 / t=0.62→0.6156→0.5 / t=0.8→0.36→0.25 / t=1.0→0.0
	var beats := [[0.12, 1.0], [0.12, 0.75], [0.132, 0.5], [0.108, 0.25], [0.12, 0.0]]
	var ok := true
	var bad := ""
	var cum_t := 0.0
	for beat: Array in beats:
		popup.tick(float(beat[0]))
		cum_t += float(beat[0]) / DamagePopup.LIFE_TIME
		if absf(popup.modulate.a - float(beat[1])) > 0.0001:
			ok = false
			bad = "t=%.3f a=%.4f（期望 %s）" % [cum_t, popup.modulate.a, str(beat[1])]
			break
	_check("③ Label 路径：五拍根 modulate.a 精确落 {1.0,0.75,0.5,0.25,0.0}（0.96→1.0 首拍归档）",
		ok, bad)
	_check("③ Label 路径回归：_label 在位且文本口径不变（「10」）",
		popup._label != null and popup._label.text == "10",
		"text=%s" % (popup._label.text if popup._label != null else "<null>"))
	_check("③ Label 路径回归：self_modulate/theme 零触碰（tint 通道仍为样式表值）",
		popup._label.self_modulate == Color.WHITE,
		str(popup._label.self_modulate))
	popup.free()


# ── ④ 位图路径回归（bitmap_override=1） ───────────────────────────
func _test_bitmap_path_fade_grid() -> void:
	print("── ④ 位图路径分相位档位（bitmap_override=1） ──")
	_check("④ 前置：图集就绪（run 早期 build_all，进程内持久）", PopupGlyphAtlas.ready())
	DamagePopup.bitmap_override = 1
	_check("④ 前置：override=1 → bitmap_gate 真（强制位图臂）", DamagePopup.bitmap_gate())
	var popup := _new_popup()
	popup.show_popup(Vector2(100.0, 200.0), 12345.0, GameConst.PopupStyle.NORMAL)
	_check("④ 位图臂结构：字形 sprite 在位且数值臂零 Label（R225 结构锁不回归）",
		popup._glyph_sprites.size() == 5 and popup._label == null)
	var beats := [[0.12, 1.0], [0.12, 0.75], [0.132, 0.5], [0.108, 0.25], [0.12, 0.0]]
	var ok := true
	var bad := ""
	for beat: Array in beats:
		popup.tick(float(beat[0]))
		if absf(popup.modulate.a - float(beat[1])) > 0.0001:
			ok = false
			bad = "a=%.4f（期望 %s）" % [popup.modulate.a, str(beat[1])]
			break
	_check("④ 位图路径：同拍表逐位同档（根 modulate 双路径同源，量化不分路径）", ok, bad)
	popup.free()


# ── ⑤ fx_opacity 折乘量化 ─────────────────────────────────────────
func _test_fx_opacity_fold() -> void:
	print("── ⑤ fx_opacity 折乘量化（R194 写点契约） ──")
	DamagePopup.bitmap_override = 0
	DamagePopup.fx_opacity = 0.3
	var popup := _new_popup()
	popup.show_popup(Vector2(100.0, 100.0), 10.0, GameConst.PopupStyle.NORMAL)
	popup.tick(DamagePopup.LIFE_TIME * 0.25)      # t=0.25 → raw 0.3×0.9375=0.28125 → 0.25
	_check("⑤ 写点①：fx_opacity=0.3 → tick 后 a==_qa(0.28125)==0.25（折乘后整体量化）",
		absf(popup.modulate.a - 0.25) <= 0.0001, str(popup.modulate.a))
	popup._reset_state()
	_check("⑤ 写点②：_reset_state 后 a==_qa(0.3)==0.25（复位带乘区同档）",
		absf(popup.modulate.a - 0.25) <= 0.0001, str(popup.modulate.a))
	DamagePopup.fx_opacity = 1.0
	popup.show_popup(Vector2(100.0, 100.0), 10.0, GameConst.PopupStyle.NORMAL)
	popup.tick(0.001)
	_check("⑤ 乘区恢复：fx_opacity=1.0 → 首拍 a==1.0（满档）",
		absf(popup.modulate.a - 1.0) <= 0.0001, str(popup.modulate.a))
	popup.free()


# ── ⑥ 多层渐隐不串档 ──────────────────────────────────────────────
func _test_multi_popup_no_cross() -> void:
	print("── ⑥ 6 跳字并发（微相位差）不串档 ──")
	DamagePopup.bitmap_override = 0
	var pops: Array[DamagePopup] = []
	for i in range(6):
		var p := _new_popup()
		p.show_popup(Vector2(100.0 + 30.0 * i, 300.0), 7.0, GameConst.PopupStyle.NORMAL)
		p.tick(DamagePopup.LIFE_TIME * (0.30 + 0.08 * i))   # t=0.30..0.70 六相位
		pops.append(p)
	var alphas: Array = []
	for p in pops:
		alphas.append(p.modulate.a)
	var all_grid := true
	for a: float in alphas:
		if not _on_grid(a):
			all_grid = false
	# 连续对照：同六相位的未量化 raw 值逐件唯一（断批定律面），量化后坍缩 ≤3 档
	var cont: Array = []
	for i in range(6):
		var t := 0.30 + 0.08 * i
		cont.append(1.0 - t * t)
	var cont_distinct := _distinct(cont)
	var quant_distinct := _distinct(alphas)
	_check("⑥ 全部 live 跳字 modulate.a∈四分档（6 相位并发）", all_grid, str(alphas))
	_check("⑥ 合批前置验：distinct 坍缩（连续 %d 档 → 量化 %d 档 ≤3）" % [cont_distinct, quant_distinct],
		cont_distinct >= 6 and quant_distinct <= 3,
		"cont=%d quant=%d vals=%s" % [cont_distinct, quant_distinct, str(alphas)])
	# 串档反证：单件 tick 其余逐位不动（逐实例独立 modulate，无共享态串写）
	var before: Array = []
	for p in pops:
		before.append(p.modulate.a)
	pops[2].tick(0.006)                           # 微步：raw 仍在同档 → 等值跳过写
	var no_cross := true
	for i in range(6):
		if pops[i].modulate.a != before[i]:
			no_cross = false
	_check("⑥ 不串档：单件 tick 后 6 件 modulate.a 逐位不动（档内等值跳过 + 零跨实例串写）",
		no_cross, "before=%s after=%s" % [str(before), str(alphas)])
	for p in pops:
		p.free()


# ── ⑦ 池复用链 ────────────────────────────────────────────────────
func _test_pool_reuse_chain() -> void:
	print("── ⑦ 池复用链（复位档=首拍档，无闪帧） ──")
	DamagePopup.bitmap_override = 0
	var popup := _new_popup()
	popup.show_popup(Vector2(50.0, 60.0), 5.0, GameConst.PopupStyle.NORMAL)
	popup.tick(0.2)
	popup._reset_state()
	_check("⑦ 归还复位：a==_qa(1.0)==1.0（满档复位）",
		absf(popup.modulate.a - 1.0) <= 0.0001, str(popup.modulate.a))
	popup.show_popup(Vector2(50.0, 60.0), 8.0, GameConst.PopupStyle.NORMAL)
	popup.tick(0.001)
	_check("⑦ 复用首拍：a==复位档（同档无闪帧——写点②契约量化口径保持）",
		absf(popup.modulate.a - 1.0) <= 0.0001, str(popup.modulate.a))
	_check("⑦ is_active 链：show 置活 / 复位清活（池化契约不回归）",
		popup.is_active and popup.visible)
	popup._reset_state()
	_check("⑦ 复位清活：is_active=false（归还契约）", not popup.is_active)
	popup.free()


func _distinct(p_vals: Array) -> int:
	var seen: Array = []
	for v in p_vals:
		var dup := false
		for s in seen:
			if absf(float(v) - float(s)) < 0.0001:
				dup = true
				break
		if not dup:
			seen.append(float(v))
	return seen.size()
