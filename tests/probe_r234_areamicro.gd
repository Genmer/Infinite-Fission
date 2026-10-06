# tests/probe_r234_areamicro.gd（R234 Area2D 监测纯物理微基准——无帧序噪声隔离臂）
# 跑法：cd E:/Code/Agent/Infinite-Fission && tools/Godot_v4.3-stable_win64_console.exe \
#         --headless --path E:/Code/Agent/Infinite-Fission/repo -s tests/probe_r234_areamicro.gd
# 目的：R234 主探针 A/B/C 臂被 30ms 级帧序漂移淹没（34-44ms 无序差）——本微基准剥离
#   GameLoop，只放 121 个 Area2D（敌口径：圆形 r=14 挤成团 + 1 玩家 r=16），三态各驱
#   400 物理步（await physics_frame），读 TIME_PHYSICS_PROCESS（含 PhysicsServer2D step
#   + 空回调——无 GDScript 帧序）。敌每步微移（模拟追击态 transform 同步负载）。
#   态：def=全默认 layer1/mask1 互监 / mask=敌mask2+玩家layer3 / off=monitoring 全 false。
# 纪律：无 test_ 前缀；只读探针（自建节点树跑完即毁）；JSON 留档。
extends SceneTree

const N_ENEMY := 120
const STEPS := 400
const OUT_JSON := "res://docs/qa/probe_r234_areamicro_2026-10-06.json"


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	await process_frame
	var root := Node2D.new()
	root.name = "AreaMicro"
	self.root.add_child(root)
	var player := Area2D.new()
	var pshape := CollisionShape2D.new()
	var pc := CircleShape2D.new()
	pc.radius = 16.0
	pshape.shape = pc
	player.add_child(pshape)
	player.position = Vector2(360.0, 640.0)
	root.add_child(player)
	var enemies: Array[Area2D] = []
	for i in range(N_ENEMY):
		var a := Area2D.new()
		var s := CollisionShape2D.new()
		var c := CircleShape2D.new()
		c.radius = 14.0
		s.shape = c
		a.add_child(s)
		# 挤成团（深载敌群形态：分离力 10Hz 只推开 4px——密集重叠）
		var ang := float(i) * TAU / float(N_ENEMY)
		var rad := 40.0 + 110.0 * (float(i % 7) / 7.0)
		a.position = player.position + Vector2.from_angle(ang) * rad
		root.add_child(a)
		enemies.append(a)
	var out: Dictionary = {"meta": {
		"date": "2026-10-06", "n_enemy": N_ENEMY, "steps": STEPS,
		"note": "121 Area2D 挤团（敌圆 r14 密集群 + 玩家 r16）；每步敌向玩家微移 1.2px；"
			+ "TIME_PHYSICS_PROCESS=PhysicsServer2D step+空回调（无帧序）；桌面口径真机≈×0.5-2"}}
	for mode in ["def", "mask", "off"]:
		if mode == "mask":
			for a in enemies:
				a.collision_mask = 2
			player.collision_layer = 3
		elif mode == "off":
			for a in enemies:
				a.monitoring = false
			player.monitoring = false
		else:
			for a in enemies:
				a.collision_mask = 1
				a.monitoring = true
			player.collision_layer = 1
			player.monitoring = true
		await physics_frame                  # 换态后弃一步（pair 重建帧）
		var ms: Array[float] = []
		for i in range(STEPS):
			await physics_frame
			var dir := (player.position - enemies[0].position).normalized()
			for j in range(N_ENEMY):
				enemies[j].position += dir * 1.2    # 微移：transform 同步负载
			ms.append(float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0)
		var s2 := ms.duplicate()
		s2.sort()
		out[mode] = {"p50": _pct(s2, 0.50), "p95": _pct(s2, 0.95), "mean": _mean(ms)}
		print("%s：TIME_PHYSICS_PROCESS ms p50=%.4f p95=%.4f mean=%.4f（n=%d）" % [
			mode, _pct(s2, 0.50), _pct(s2, 0.95), _mean(ms), STEPS])
	var f := FileAccess.open(OUT_JSON, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(out, "\t"))
		f.close()
		print("JSON 留档：%s" % OUT_JSON)
	root.queue_free()
	await process_frame
	quit(0)


func _pct(p_sorted: Array[float], p_pct: float) -> float:
	if p_sorted.is_empty():
		return 0.0
	return p_sorted[clampi(int(float(p_sorted.size()) * p_pct), 0, p_sorted.size() - 1)]


func _mean(p_arr: Array[float]) -> float:
	if p_arr.is_empty():
		return 0.0
	var s := 0.0
	for v in p_arr:
		s += v
	return s / float(p_arr.size())
