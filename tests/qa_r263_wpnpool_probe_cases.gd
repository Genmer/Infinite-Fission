# tests/qa_r263_wpnpool_probe_cases.gd — R263 定谳探针用例体（入口 qa_r263_wpnpool_probe.gd）
# 用户反馈「开局祝福依旧没有武器」三臂核查：
#  A 普通角色（恒手枪 W1 form=0）全解锁全池：武器绑定词条数（预期 0=适配门全滤定谳）
#  B fission+W8 环绕首发×困难（难度门 1 过）：环绕族词条应过门（预期 >0）
#  C fission+W8 首发×普通（难度门拦→回落手枪）：同 A 预期 0
extends RefCounted


func _weapon_bound(p_td: TraitData) -> bool:
	# 武器绑定判定：required_weapon / required_class 直判；required_forms 含非 0 形态
	#（手枪 form=0——纯 [0] 视作手枪适配不判武器绑定）
	var rw: Variant = p_td.params.get("required_weapon", null)
	if rw != null:
		return true
	var rc: Variant = p_td.params.get("required_class", null)
	if rc != null:
		return true
	var forms: Variant = p_td.params.get("required_forms", null)
	if forms is Array and not (forms as Array).is_empty():
		for f_v in (forms as Array):
			if int(f_v) != 0:
				return true
	return false


func _bound_names(p_gl, p_pool: Array[StringName]) -> Array[String]:
	var out: Array[String] = []
	for tid in p_pool:
		var td: TraitData = p_gl.registry.get_trait(tid)
		if td != null and _weapon_bound(td):
			out.append(String(tid))
	return out


func run(p_tree: SceneTree) -> void:
	var gl_script: GDScript = load("res://scripts/loop/game_loop.gd")
	var gl = gl_script.new()
	gl.name = "GameLoopForR263Probe"
	p_tree.get_root().add_child(gl)
	gl.set_physics_process(false)
	var waited := 0
	while not gl.boot_ready and waited < 600:
		await p_tree.process_frame
		waited += 1
	print("PROBE | boot=%s" % str(gl.boot_ready))

	var char_saved: StringName = Meta.character_id
	var cw_saved: String = Meta.custom_weapon_id
	var diff_saved: int = gl._difficulty
	for tid_v: Variant in gl.registry.traits.keys():
		Meta.codex_traits[String(tid_v)] = true

	# ── A 普通角色×困难 ──
	Meta.character_id = &"vera"
	gl._difficulty = 1
	var pool_a: Array[StringName] = gl._blessing_pool()
	var bound_a := _bound_names(gl, pool_a)
	print("PROBE A | 普通角色(手枪)×困难 全池=%d 武器绑定词条=%d %s"
		% [pool_a.size(), bound_a.size(), str(bound_a)])

	# ── B fission+W8×困难 ──
	Meta.character_id = &"fission"
	Meta.custom_weapon_id = "W8_orbit_field"
	gl._difficulty = 1
	var pool_b: Array[StringName] = gl._blessing_pool()
	var bound_b := _bound_names(gl, pool_b)
	print("PROBE B | fission+W8环绕×困难 全池=%d 武器绑定词条=%d %s"
		% [pool_b.size(), bound_b.size(), str(bound_b)])

	# ── C fission+W8×普通（难度门拦回落手枪）──
	gl._difficulty = 0
	var pool_c: Array[StringName] = gl._blessing_pool()
	var bound_c := _bound_names(gl, pool_c)
	print("PROBE C | fission+W8环绕×普通 全池=%d 武器绑定词条=%d %s"
		% [pool_c.size(), bound_c.size(), str(bound_c)])

	Meta.character_id = char_saved
	Meta.custom_weapon_id = cw_saved
	gl._difficulty = diff_saved
