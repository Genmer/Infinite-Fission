# tests/qa_r253_probe_kill.gd — QA 探针（只读，不改产品代码）
# 目的：复现 r188_idle §B「GAME_OVER 隐藏」概率红的根因——
# 复刻 §B 序列（start_run → 升2级选卡 choose(0) → _kill_player 同款必死一击），
# 逐次记录被选卡 id/kind 与击后玩家盾态（_shield_units / temp_shield_stacks / hp / 状态）。
# 注：autoload 名（EventBus/PerfGovernor）经 get_node 取——-s 入口脚本编译期不可见。
extends SceneTree

const MAIN_SCENE := "res://scenes/main.tscn"

var _chosen: Array = []


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══ QA probe: r188 §B kill-block root cause ══")
	var main: Node = load(MAIN_SCENE).instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	var gl: GameLoop = null
	for c in root.get_children():
		if c is GameLoop:
			gl = c
			break
	if gl == null:
		print("PROBE-FAIL no GameLoop")
		quit(1)
		return
	gl.state = GameConst.GameStatus.MENU
	var perf: Node = root.get_node_or_null("/root/PerfGovernor")
	if perf != null:
		perf.call(&"set_process", false)
	GameLoop.SIM_30HZ_ENABLED = false
	GameLoop.sim30_override = -1
	var bus: Node = root.get_node("/root/EventBus")
	var spy := func(p_id: StringName, p_kind: int) -> void:
		_chosen.append([String(p_id), p_kind])
	bus.connect(&"card_chosen", spy)
	var blocked := 0
	for i in range(60):
		_chosen.clear()
		gl.state = GameConst.GameStatus.MENU
		gl.relic_handler.reset_run()
		gl.card_generator.owned_relics.clear()
		gl.player._dead = false
		gl.player.hp = gl.player.max_hp
		var ok_start: bool = gl.start_run(-1)
		await process_frame
		gl._on_level_up(2)
		gl.call(&"_consume_deferred_level_open")
		gl.card_select_ui.choose(0)
		await process_frame
		var p := gl.player
		p.set("revives_left", 0)
		p.set("shield_ready", false)          # §B 夹具原样（R253 后为派生视图——写入无效）
		p.set("invuln_left", 0.0)
		p.set("max_hp", 1000000.0)
		p.set("hp", 1000000.0)
		p.take_contact_damage(1000001.0)
		var survived: bool = float(p.get("hp")) > 0.0
		if survived or gl.state != GameConst.GameStatus.GAME_OVER:
			blocked += 1
		print("iter %02d | start=%s card=%s | hp=%.1f state=%d units=%d orange=%d dead=%s"
			% [i, str(ok_start), str(_chosen), float(p.get("hp")), int(gl.state),
			(p.get("_shield_units") as Dictionary).size(),
			int(p.get("temp_shield_stacks")), str(bool(p.get("_dead")))])
		# 复位回 MENU 供下一轮
		gl.state = GameConst.GameStatus.MENU
		p.set("_dead", false)
		p.set("hp", float(p.get("max_hp")))
	bus.disconnect(&"card_chosen", spy)
	print("══ probe done: blocked/total = %d/60 ══" % blocked)
	quit(0)
