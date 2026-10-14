extends RefCounted
# R261 QA 前置侦察 cases：全解锁后各档祝福池的 pool 类别分布（探针设计输入）


func run(p_tree: SceneTree) -> void:
	var gl_script: GDScript = load("res://scripts/loop/game_loop.gd")
	var gl = gl_script.new()
	gl.name = "GameLoopForR261Dump"
	p_tree.get_root().add_child(gl)
	gl.set_physics_process(false)
	var waited := 0
	while not gl.boot_ready and waited < 600:
		await p_tree.process_frame
		waited += 1
	for tid_v: Variant in gl.registry.traits.keys():
		var td_d: TraitData = gl.registry.get_trait(StringName(String(tid_v)))
		if td_d != null and int(td_d.rarity) >= 1 and int(td_d.rarity) <= 3:
			Meta.codex_traits[String(tid_v)] = true
	var names := ["ADD0", "MULT1", "LOCAL2", "MECH3", "ELEM4"]
	for tier in range(1, 4):
		var pool: Array[StringName] = gl._blessing_pool(tier)
		var counts := [0, 0, 0, 0, 0]
		for tid in pool:
			var td: TraitData = gl.registry.get_trait(tid)
			if td != null:
				counts[int(td.pool)] += 1
		var parts: String = ""
		for i in range(5):
			parts += "%s=%d " % [names[i], counts[i]]
		print("TIER%d total=%d | %s" % [tier, pool.size(), parts])
	for tid_v: Variant in gl.registry.traits.keys():
		Meta.codex_traits.erase(String(tid_v))
	Meta._save()
	gl.free()
