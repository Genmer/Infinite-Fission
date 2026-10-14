# tests/probe_rv202_dualcover_body.gd
# 复审探针用例体（由 probe_rv202_dualcover.gd 入口在 autoload 就绪后运行时加载编译）。
# ③四种卡组组合可点性——成对（dual）模式（槽 4~9）下 reroll 按钮 × 6 卡几何 +
# 树序 + 每槽可点性（native -s 窗最坏字体档；正常模式已由 probe_reroll_zorder 证）。
extends RefCounted


func run(p_tree: SceneTree) -> void:
	RunSave.clear()
	var gl: GameLoop = GameLoop.new()
	gl.name = "ProbeDualCoverGameLoop"
	p_tree.get_root().add_child(gl)
	await p_tree.process_frame
	await p_tree.process_frame
	gl.call(&"start_run")
	await p_tree.process_frame
	await p_tree.process_frame
	var ui: CardSelectUI = gl.card_select_ui
	var cards: Array[Dictionary] = []
	for i in range(6):
		cards.append({"kind": CardGenerator.CardKind.TRAIT, "id": StringName("DC%d" % i),
			"rarity": 2, "value_scale": 1.0, "display_name": "双卡%d" % i,
			"description": "测".repeat(40)})
	ui.open(cards, true)                       # 成对模式（槽 4~9）
	ui.update_reroll(1, true)                  # 免费态最长文案（按钮最坏内容态）
	await p_tree.process_frame
	await p_tree.create_timer(0.6).timeout
	await p_tree.process_frame
	var btn: Button = ui._reroll_btn
	var rr: Rect2 = btn.get_global_rect()
	var max_idx := -1
	var blocked: Array[String] = []
	var visible_cnt := 0
	for b in ui._buttons:
		max_idx = maxi(max_idx, b.get_index())
		if not b.visible:
			continue
		visible_cnt += 1
		var cr: Rect2 = b.get_global_rect()
		var inter: String = "分离"
		if rr.intersects(cr):
			var d := rr.intersection(cr)
			inter = "相交深%.0fpx" % d.size.y
			# 树序判谁在上：index 大者绘制/拾取在上
			var who := "按钮盖卡" if btn.get_index() > b.get_index() else "卡盖按钮(挡!)"
			if who != "按钮盖卡":
				blocked.append("%s(%s)" % [String(b.name), who])
			inter += " → " + who
		print("槽%s vis=%s rect=%s reroll缝=%.0fpx(正=分离) %s"
			% [String(b.name), str(b.visible), str(cr), cr.position.y - rr.end.y, inter])
	print("可见卡数=%d / reroll idx=%d / 最大卡 idx=%d / 树序=%s"
		% [visible_cnt, btn.get_index(), max_idx,
			"reroll最后(盖上)" if btn.get_index() > max_idx else "异常"])
	print("被卡挡住的按钮数=%d %s" % [blocked.size(), " ".join(blocked)])
	print("PROBE DONE")
	gl.queue_free()
	await p_tree.process_frame
	await p_tree.process_frame
