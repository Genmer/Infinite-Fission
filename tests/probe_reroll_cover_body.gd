# tests/probe_reroll_cover_body.gd
# 侦查探针用例体（由 probe_reroll_cover.gd 入口在 autoload 就绪后运行时加载编译）。
# 「换一批」按钮被挡住——v3 聚焦三件事：
#   A. 设计窗（套件归一化 = 真机等价配置）下 4 卡 desc80 的槽显隐/尺寸异常复现；
#   B. 原生 -s 窗（不归一化——字体度量另一档）下按钮最小尺寸增长 → 与卡0 相交深度；
#   C. 免费态文本宽度增长后的按钮右沿。
extends RefCounted


func run(p_tree: SceneTree) -> void:
	RunSave.clear()
	var win: Window = p_tree.root
	print("═══ B. 原生 -s 窗（未归一化）——先跑，免得归一化后还原不净 ═══")
	var gl: GameLoop = GameLoop.new()
	gl.name = "ProbeGameLoop"
	p_tree.get_root().add_child(gl)
	await p_tree.process_frame
	await p_tree.process_frame
	gl.call(&"start_run")
	await p_tree.process_frame
	await p_tree.process_frame
	await _report(gl, "原生窗静息")
	var ui: CardSelectUI = gl.card_select_ui
	for n in [1, 3, 4]:
		for ln in [1, 80, 160]:
			ui.open(_make_cards(int(n), int(ln), 1.9), false)
			ui.update_reroll(0, true)
			await p_tree.process_frame
			await p_tree.process_frame
			await p_tree.create_timer(0.6).timeout
			await p_tree.process_frame
			await _combo_report(ui, "原生窗 普通%d卡 desc%d" % [int(n), int(ln)])
			ui.close()
			await p_tree.process_frame

	# 归一化 → 设计窗（r195_layout 同款）
	print("═══ A. 设计 720×1280（归一化）═══")
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
	await _report(gl, "设计窗(归一化)")

	# 4卡 desc80 异常复现：连开三遍 + 逐槽体检
	for round_i in range(3):
		ui.open(_make_cards(4, 80, 1.9), false)
		await p_tree.process_frame
		await p_tree.process_frame
		await p_tree.create_timer(1.0).timeout
		await p_tree.process_frame
		await _combo_report(ui, "设计窗 普通4卡 desc80 第%d轮" % (round_i + 1))
		ui.close()
		await p_tree.process_frame
		await p_tree.process_frame

	# close→open 快速循环（reroll 重发牌同款节奏）后再测
	for i in range(3):
		ui.open(_make_cards(4, 80, 1.9), false)
		await p_tree.process_frame
		ui.close()
		await p_tree.process_frame
	ui.open(_make_cards(4, 80, 1.9), false)
	await p_tree.create_timer(1.0).timeout
	await _combo_report(ui, "设计窗 普通4卡 desc80 快速循环后")
	ui.close()
	await p_tree.process_frame

	print("═══ C. 免费态按钮宽度（设计窗）═══")
	ui.open(_make_cards(3, 1, 1.0), false)
	ui.update_reroll(0, true)
	await p_tree.process_frame
	await p_tree.process_frame
	var btn: Button = ui._reroll_btn
	print("免费态 text=\"%s\" rect=%s min=%s 屏宽 720 / 卡右沿 660" % [btn.text,
		str(btn.get_global_rect()), str(btn.get_combined_minimum_size())])
	ui.close()
	await p_tree.process_frame

	print("PROBE DONE")
	gl.queue_free()
	await p_tree.process_frame
	await p_tree.process_frame


func _report(p_gl: GameLoop, p_tag: String) -> void:
	var ui: CardSelectUI = p_gl.card_select_ui
	var btn: Button = ui._reroll_btn
	print("[%s] vis=%s title rect=%s min=%s" % [p_tag,
		str(p_gl.get_tree().root.get_visible_rect().size),
		str(ui._title.get_global_rect()), str(ui._title.get_combined_minimum_size())])
	print("[%s] reroll rect=%s min=%s（设计 offset 198..254 高 56；卡0 顶 264）" % [p_tag,
		str(btn.get_global_rect()), str(btn.get_combined_minimum_size())])


func _combo_report(p_ui: CardSelectUI, p_tag: String) -> void:
	var rr: Rect2 = p_ui._reroll_btn.get_global_rect()
	var lines: Array = []
	for s in range(4):
		var b: Button = p_ui._buttons[s]
		var dl: Label = b.get_node_or_null("CardDesc") as Label
		lines.append("slot%d vis=%s h%.0f@y%.0f desc=%s" % [s, str(b.visible),
			b.size.y, b.global_position.y,
			str(dl.get_line_count()) if dl != null else "?"])
	var inter := ""
	for s in range(4):
		var b: Button = p_ui._buttons[s]
		if b.visible and rr.intersects(b.get_global_rect()):
			var r2: Rect2 = rr.intersection(b.get_global_rect())
			inter += " slot%d∩深%.0fpx(y %.0f..%.0f)" % [s, r2.size.y,
				r2.position.y, r2.end.y]
	print("[%s] 按钮 y %.0f..%.0f | %s%s" % [p_tag, rr.position.y, rr.end.y,
		" / ".join(lines), " → 相交:" + inter if inter != "" else " → 无相交"])


func _make_cards(p_n: int, p_len: int, p_vs: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i in range(p_n):
		out.append({"kind": CardGenerator.CardKind.TRAIT,
			"id": StringName("PB%d" % i), "rarity": 2, "value_scale": p_vs,
			"display_name": "卡%d" % i, "description": "测".repeat(p_len)})
	return out
