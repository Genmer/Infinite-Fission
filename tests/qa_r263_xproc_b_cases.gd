extends RefCounted
# R263 双进程 G9b 进程 B cases：读 A 快照 → boot（全新 Meta：_load 档面 170）→
# continue_run（blessing_paid 随档恢复 true）→ 断言槽/词条 → GAME_OVER → restart_run →
# 断言重送 W8+词条 1+余额 170 不变（修前：新实例 paid=false → 未购分支不重挂）。
# 收尾：RunSave.clear + 档字节还原 + 删快照。
var _pass := 0
var _fail := 0
var _failures: Array[String] = []

const SNAP_PATH := "user://qa_r263_xproc_snap.txt"


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  ok | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("  FAIL | %s %s" % [p_name, p_detail])


func _slot_wid(p_gl, p_i: int) -> StringName:
	if p_i >= p_gl.player.weapon_slots.size():
		return StringName("")
	var w: WeaponBase = p_gl.player.weapon_slots[p_i] if p_i < p_gl.player.weapon_slots.size() else null
	if w == null or not is_instance_valid(w) or w.data == null:
		return StringName("")
	return StringName(String(w.data.id))


func _layers(p_gl, p_tid: StringName) -> int:
	var n := 0
	for w_v: Variant in p_gl.player.weapon_slots:
		var w := w_v as WeaponBase
		if w == null or not is_instance_valid(w) or w.trait_stack == null:
			continue
		for m in w.trait_stack.traits:
			if m.data != null and m.data.id == p_tid:
				n += int(m.layers)
	return n


func run(p_tree: SceneTree) -> void:
	_check("B 前置：A 快照与 RunSave 均在位",
		FileAccess.file_exists(SNAP_PATH) and RunSave.exists(),
		"snap=%s run=%s" % [str(FileAccess.file_exists(SNAP_PATH)), str(RunSave.exists())])
	if not FileAccess.file_exists(SNAP_PATH):
		_summary()
		return
	var snap_raw := FileAccess.get_file_as_string(SNAP_PATH)
	var nl := snap_raw.find("\n")
	var had_save: bool = snap_raw.substr(0, nl) == "1"
	var save_text := snap_raw.substr(nl + 1)

	var gl_script: GDScript = load("res://scripts/loop/game_loop.gd")
	var gl = gl_script.new()
	gl.name = "GameLoopForXprocB"
	p_tree.get_root().add_child(gl)
	gl.set_physics_process(false)
	var waited := 0
	while not gl.boot_ready and waited < 600:
		await p_tree.process_frame
		waited += 1
	_check("B boot：菜单就绪（新进程 Meta 档面 170）", gl.boot_ready and Meta.stardust == 170,
		"boot=%s sd=%d" % [str(gl.boot_ready), Meta.stardust])
	if not gl.boot_ready:
		_finish(gl, had_save, save_text)
		return

	var resumed: bool = gl.continue_run()
	_check("B continue：已购局恢复 slot1=W8 + 词条恰 1 份",
		resumed and _slot_wid(gl, 1) == &"W8_orbit_field" and _layers(gl, &"MEC_ORBIT_SWORD") == 1,
		"resumed=%s s1=%s layers=%d" % [str(resumed), String(_slot_wid(gl, 1)),
			_layers(gl, &"MEC_ORBIT_SWORD")])

	gl.state = GameConst.GameStatus.GAME_OVER
	var sd_pre: int = Meta.stardust
	var banner: Array = []
	var cb := func(t): banner.append(String(t))
	EventBus.mechanics_intro.connect(cb)
	var restarted: bool = gl.restart_run()
	EventBus.mechanics_intro.disconnect(cb)
	_check("B 重开（跨进程已购位）：重送 W8 + 词条恰 1 + 余额 170 不变 + 无未购短横幅",
		restarted and _slot_wid(gl, 1) == &"W8_orbit_field"
			and _layers(gl, &"MEC_ORBIT_SWORD") == 1 and Meta.stardust == sd_pre
			and not "".join(banner).contains("未购不随重开生效"),
		"restart=%s s1=%s layers=%d sd=%d→%d banner=%s" % [str(restarted),
			String(_slot_wid(gl, 1)), _layers(gl, &"MEC_ORBIT_SWORD"), sd_pre, Meta.stardust,
			str(banner).substr(0, 80)])

	_finish(gl, had_save, save_text)
	_summary()


func _finish(p_gl, p_had_save: bool, p_save_text: String) -> void:
	RunSave.clear()
	var sp := Meta.save_path()
	if p_had_save:
		var f := FileAccess.open(sp, FileAccess.WRITE)
		if f != null:
			f.store_string(p_save_text)
			f.close()
		Meta._load()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(sp))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SNAP_PATH))
	p_gl.free()


func _summary() -> void:
	print("验收汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	for f in _failures:
		print("  FAIL | %s" % f)


func fail_count() -> int:
	return _fail
