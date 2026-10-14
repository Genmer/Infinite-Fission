# tests/qa_r253_probe_p7death_cases.gd — P7 消化死亡根因用例体（入口运行时加载）
# 复刻 r188_idle §P/P7：常规局开局 → hp/max_hp=1e6 + invuln=9999 → gain_xp(1e12)
# → auto_select 分帧消化 → 逐 300 帧快照，_dead 即停。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0

var _snaps: Array[String] = []


func run(p_tree: SceneTree) -> void:
	print("══ QA probe: P7 digestion death root cause ══")
	var main: Node = load(MAIN_SCENE).instantiate()
	p_tree.root.add_child(main)
	await p_tree.process_frame
	await p_tree.process_frame
	var gl: GameLoop = null
	for c in p_tree.root.get_children():
		if c is GameLoop:
			gl = c
			break
	if gl == null:
		print("PROBE-FAIL no GameLoop")
		return
	gl.state = GameConst.GameStatus.MENU
	if not gl.start_run():
		print("PROBE-FAIL start_run")
		return
	var p := gl.player
	p.set("max_hp", 1000000.0)
	p.set("hp", 1000000.0)
	p.set("invuln_left", 9999.0)
	for i in range(50):
		gl._physics_process(DT)
		if not gl.card_select_ui.is_open:
			break
	gl.pending_level_ups = 0
	gl.merged_overflow_level_ups = 0
	p.gain_xp(1e12)
	gl.call(&"_consume_deferred_level_open")
	print("[probe] burst=%d pending=%d merged=%d" % [int(p.get("level_burst_last")),
		gl.pending_level_ups, gl.merged_overflow_level_ups])
	p.set("max_hp", 1000000.0)
	p.set("hp", 1000000.0)
	p.set("invuln_left", 9999.0)
	Meta.set_setting("auto_select_on", true)
	var frames := 0
	var died_at := -1
	while (gl.merged_overflow_level_ups > 0 or gl.card_select_ui.is_open) and frames < 9000:
		gl._physics_process(DT)
		frames += 1
		if frames % 300 == 0:
			_snap(gl, frames)
		if bool(p.get("_dead")):
			died_at = frames
			break
	Meta.set_setting("auto_select_on", false)
	_snap(gl, frames)
	print("══ probe done: frames=%d died_at=%d state=%d ══" % [frames, died_at, gl.state])
	for s in _snaps:
		print(s)


func _snap(gl: GameLoop, p_frame: int) -> void:
	var p := gl.player
	var enemies := -1
	var sp_v: Variant = gl.get("spawner")
	if sp_v != null and sp_v is Object and (sp_v as Object).get("active") is Array:
		enemies = (sp_v.get("active") as Array).size()
	var wave_v: Variant = gl.get("wave")
	var wave_i := int(wave_v) if wave_v != null else -1
	_snaps.append("f%-5d st=%d hp=%.1f mhp=%.1f inv=%.2f lvl=%d wave=%d enem=%d merged=%d pend=%d"
		% [p_frame, gl.state, float(p.get("hp")), float(p.get("max_hp")),
			float(p.get("invuln_left")), int(p.get("level")), wave_i,
			enemies, gl.merged_overflow_level_ups, gl.pending_level_ups])
