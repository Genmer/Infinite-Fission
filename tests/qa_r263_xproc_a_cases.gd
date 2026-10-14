extends RefCounted
# R263 双进程 G9b 进程 A cases：快照档字节（存全局暂存位）→ stardust=200 → 付费局
# （ORBIT_SWORD -30 → 170）→ PAUSED 退出落 RunSave（含 blessing_paid 键）→ 退出。
# 档字节快照写到 user://qa_r263_xproc_snap.txt 供进程 B 收尾还原。
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


func run(p_tree: SceneTree) -> void:
	var gl_script: GDScript = load("res://scripts/loop/game_loop.gd")
	var gl = gl_script.new()
	gl.name = "GameLoopForXprocA"
	p_tree.get_root().add_child(gl)
	gl.set_physics_process(false)
	var waited := 0
	while not gl.boot_ready and waited < 600:
		await p_tree.process_frame
		waited += 1
	_check("boot：菜单就绪", gl.boot_ready)
	if not gl.boot_ready:
		_failures.append("boot 失败")
		_summary()
		return

	var sp := Meta.save_path()
	var had_save := FileAccess.file_exists(sp)
	var save_text := FileAccess.get_file_as_string(sp) if had_save else ""
	var f := FileAccess.open(SNAP_PATH, FileAccess.WRITE)
	f.store_string(("1" if had_save else "0") + "\n" + save_text)
	f.close()

	RunSave.clear()
	for tid_v: Variant in gl.registry.traits.keys():
		Meta.codex_traits[String(tid_v)] = true
	Meta.character_id = &"sentinel"
	Meta.custom_weapon_id = ""
	Meta.stardust = 200
	Meta.set_blessing_trait(&"MEC_ORBIT_SWORD")

	gl._difficulty = 0
	gl.current_map_id = MapTable.FIRST_MAP_ID
	gl.start_run()                                            # 付费：200-30=170（写即落盘）

	var layers := 0
	for w_v: Variant in gl.player.weapon_slots:
		var w := w_v as WeaponBase
		if w != null and is_instance_valid(w) and w.trait_stack != null:
			for m in w.trait_stack.traits:
				if m.data != null and m.data.id == &"MEC_ORBIT_SWORD":
					layers += int(m.layers)
	var slot1: StringName = StringName("")
	if gl.player.weapon_slots.size() > 1:
		var w1: WeaponBase = gl.player.weapon_slots[1]
		if w1 != null and is_instance_valid(w1) and w1.data != null:
			slot1 = StringName(String(w1.data.id))
	_check("A 付费局：slot1=W8 + 词条 1 份 + 余额 170",
		slot1 == &"W8_orbit_field" and layers == 1 and Meta.stardust == 170,
		"s1=%s layers=%d sd=%d" % [String(slot1), layers, Meta.stardust])

	gl.state = GameConst.GameStatus.PAUSED
	var quit_ok: bool = gl.quit_to_menu()                     # PAUSED 主动退出 → RunSave 落档
	var data: Dictionary = RunSave.load_run()
	_check("A 落档：RunSave 存在 + blessing_paid 键为 true（serialize 含已购位）",
		quit_ok and RunSave.exists() and bool(data.get("blessing_paid", false)),
		"quit=%s keys=%s" % [str(quit_ok), str(data.keys().slice(0, 8))])
	# A 故意不还原（跨进程被测面交 B 检验）；不 RunSave.clear()
	gl.free()
	_summary()
	print("（A 收尾保持档/RunSave 原样——由 B 收尾还原）")


func _summary() -> void:
	print("验收汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	for f in _failures:
		print("  FAIL | %s" % f)


func fail_count() -> int:
	return _fail
