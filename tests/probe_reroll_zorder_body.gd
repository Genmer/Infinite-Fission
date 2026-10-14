# tests/probe_reroll_zorder_body.gd
# R202（换一批按钮遮挡修复）落码验证探针（由 probe_reroll_zorder.gd 入口加载）：
#   1. 树序兜底：reroll get_index() > 全部卡（③ 卡后 add 生效）；
#   2. 新设计位：归一化设计窗下 reroll rect y≈196..252（① 上提 2px）；
#   3. 静息无重叠：归一化档（min 高 56）真货架 + 免费态文本下 reroll∩首卡 不相交；
#   4. 原生 -s 窗（字体度量另一档，min 高可回涨）：重叠深度从 13 → 11px 上限，
#      树序使按钮绘制/拾取仍在卡上（重叠=按钮盖卡顶边，非卡挡按钮）。
extends RefCounted


func run(p_tree: SceneTree) -> void:
	RunSave.clear()
	var gl: GameLoop = GameLoop.new()
	gl.name = "ProbeZOrderGameLoop"
	p_tree.get_root().add_child(gl)
	await p_tree.process_frame
	await p_tree.process_frame
	gl.call(&"start_run")
	await p_tree.process_frame
	await p_tree.process_frame
	var ui: CardSelectUI = gl.card_select_ui

	# ── 1+4：原生 -s 窗（未归一化——字体档 min 高可回涨的暴露环境）──
	print("═══ 原生 -s 窗（字体另一档）═══")
	ui.open(_make_cards(4), false)
	ui.update_reroll(1, true)                      # 免费态文本（最长文案）
	await p_tree.process_frame
	await p_tree.create_timer(0.6).timeout
	await p_tree.process_frame
	_report(ui, "原生窗 真货架+免费态")
	ui.close()
	await p_tree.process_frame

	# ── 2+3：归一化设计窗（r195_layout 同款 = 真机等价配置）──
	print("═══ 归一化设计 720×1280 ═══")
	var win: Window = p_tree.root
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	match String(ProjectSettings.get_setting("display/window/stretch/aspect", "keep")):
		"expand":
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
		"keep":
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	win.size = Vector2i(720, 1280)
	await p_tree.process_frame
	await p_tree.process_frame
	await p_tree.create_timer(0.5).timeout
	ui.open(_make_cards(4), false)
	ui.update_reroll(1, true)
	await p_tree.process_frame
	await p_tree.create_timer(0.6).timeout
	await p_tree.process_frame
	_report(ui, "设计窗(归一化) 真货架+免费态")
	ui.close()
	await p_tree.process_frame

	# ── 5：高视口 720×1680（21:9 高档——reroll y 锚对齐视觉组的回归面）──
	print("═══ 归一化高视口 720×1680 ═══")
	win.size = Vector2i(720, 1680)
	await p_tree.process_frame
	await p_tree.process_frame
	await p_tree.create_timer(0.5).timeout
	ui.open(_make_cards(4), false)
	ui.update_reroll(1, true)
	await p_tree.process_frame
	await p_tree.create_timer(0.6).timeout
	await p_tree.process_frame
	_report(ui, "高视窗(归一化) 真货架+免费态")
	ui.close()
	await p_tree.process_frame

	print("PROBE DONE")
	gl.queue_free()
	await p_tree.process_frame
	await p_tree.process_frame


func _report(p_ui: CardSelectUI, p_tag: String) -> void:
	var btn: Button = p_ui._reroll_btn
	var root: Control = p_ui._root
	# 树序兜底：reroll 在 _root 全部卡之后（get_index 越大绘制/拾取越靠上）
	var max_card_idx := -1
	for b in p_ui._buttons:
		max_card_idx = maxi(max_card_idx, b.get_index())
	print("[%s] 树序：reroll idx=%d / 最大卡 idx=%d → 兜底%s（reroll 后 add=盖上）" % [p_tag,
		btn.get_index(), max_card_idx,
		"成立" if btn.get_index() > max_card_idx else "不成立"])
	print("[%s] reroll text=\"%s\" rect=%s min=%s" % [p_tag, btn.text,
		str(btn.get_global_rect()), str(btn.get_combined_minimum_size())])
	var first: Button = null
	for b in p_ui._buttons:
		if b.visible:
			first = b
			break
	if first == null:
		print("[%s] 无可见卡（货架空）" % p_tag)
		return
	var rr: Rect2 = btn.get_global_rect()
	var cr: Rect2 = first.get_global_rect()
	var inter: String = "无相交"
	if rr.intersects(cr):
		var d := rr.intersection(cr)
		inter = "相交 深%.0fpx(y %.0f..%.0f)——按钮盖卡顶边（树序兜底）" % [d.size.y,
			d.position.y, d.end.y]
	print("[%s] 首卡 rect=%s → reroll×首卡：%s；缝=%.0fpx（正=分离）" % [p_tag, str(cr),
		inter, cr.position.y - rr.end.y])


func _make_cards(p_n: int) -> Array[Dictionary]:
	# 真货架同构卡（probe_reroll_cover_body 先例）：短描述 = 静息卡高（不触发 R199 扩高）
	var out: Array[Dictionary] = []
	for i in range(p_n):
		out.append({"kind": CardGenerator.CardKind.TRAIT,
			"id": StringName("RZ%d" % i), "rarity": 2, "value_scale": 1.0,
			"display_name": "卡%d" % i, "description": "测"})
	return out
