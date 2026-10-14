# tests/qa_r255_perf_cardwarm.gd
# R255 性能猎手·开卡 carddesc 预热排空对照探针（只测不改产品码）。
# 对照口径：boot 后先用大预算把 card_desc_prewarm 队列排空（≈玩家菜单停留 ≥1s 的
# 真实口径），再 start_run → 直调 _open_card_flow / choose 5 次中位——与 qa_r255_
# perf_flow「boot 即进局（泵未排空）」的 16.52ms 中位对照，量化 _fit_desc miss 份额。
# 用法：Godot --headless --path <repo> -s tests/qa_r255_perf_cardwarm.gd
extends SceneTree


func _initialize() -> void:
	_run()


func _t(p_cb: Callable) -> int:
	var us0 := int(Time.get_ticks_usec())
	p_cb.call()
	return int(Time.get_ticks_usec()) - us0


func _median(p_arr: Array) -> float:
	var s := p_arr.duplicate()
	s.sort()
	return float(s[s.size() / 2]) / 1000.0


func _run() -> void:
	print("═══ R255 开卡预热排空对照（carddesc 队列排空后 _open_card_flow 5 次中位） ═══")
	await process_frame
	await process_frame
	var gl_script: GDScript = load("res://scripts/loop/game_loop.gd")
	var cd_script: GDScript = load("res://scripts/cards/card_desc_prewarm.gd")
	var gl = gl_script.new()
	gl.name = "GameLoopForProbeR255CW"
	get_root().add_child(gl)
	gl.set_physics_process(false)
	var waited := 0
	while not gl.boot_ready and waited < 600:
		await process_frame
		waited += 1
	var menu = gl.menu_screen
	gl.set("_menu_dwell_s", 99.0)
	var guard := 0
	while gl._tex_prewarm_queue.size() > 0 and guard < 400:
		gl._process_tex_prewarm(20000)
		guard += 1
	# carddesc 队列排空（大预算泵——单项原子粒度口径同产品泵）
	cd_script.reset_for_tests()
	cd_script.ensure_built(menu.registry)
	var pumped := 0
	while cd_script.remaining() > 0 and pumped < 2000:
		cd_script.pump(2000000)
		pumped += 1
	print("[warm] carddesc 排空：remaining=%d total_built=%d pump 轮 %d" % [
		int(cd_script.remaining()), int(cd_script.total_built()), pumped])
	gl.start_run()
	gl.stage_probe_enabled = true
	for i in range(240):
		gl._physics_process(1.0 / 120.0)
	var opens: Array = []
	var chooses: Array = []
	for i in range(5):
		if gl.state != 2:
			print("[warm] 状态 %d 中止第 %d 轮" % [gl.state, i])
			break
		gl.player.level += 1
		opens.append(_t(func() -> void: gl._open_card_flow(gl.player.level)))
		if gl.card_select_ui.is_open:
			chooses.append(_t(func() -> void: gl.card_select_ui.choose(0)))
		for f in range(24):
			if gl.state == 2:
				break
			if gl.state == 4 and gl.card_select_ui.is_open:
				gl.card_select_ui.choose(0)
			if gl.state == 4 and gl.shop_ui != null and gl.shop_ui.is_shop_visible():
				gl.shop_ui.close()
			gl._physics_process(1.0 / 120.0)
	print("[warm] 开卡 _open_card_flow：%d 次中位 %.2f ms（对照未排空口径 16.52ms）" % [
		opens.size(), _median(opens)])
	print("[warm] 合卡 choose(0)：%d 次中位 %.2f ms（对照 5.38ms）" % [
		chooses.size(), _median(chooses)])
	gl.free()
	quit(0)
