# tests/qa_r256_probe_wheel_cases.gd（R256 QA 序2 分片轮长帧锁步复现用例体）
# 夹具同 pkg5 B.5b _test_separation_shard_wheel：12 只静止敌同点叠放（位移唯一来源
# =分离力），直调 _tick_separation。对照两段：
# · 段A（正常帧 1/60×7）：分片轮摊平——单帧位移敌 < 12，全轮全员恰服务一次；
# · 段B（先一次 0.25s 长帧——真机后台恢复/长卡顿经 GAME_DELTA_CLAMP_S 钳制后的
#   游戏增量形态，再 1/60×13 正常帧）：若追赶把多片重排到同一到期时刻，段B 将
#   出现单帧全量位移（==12）且 _sep_due 六值全等（spread=0）——锁步坐实。
# 注意：run() 保持全同步（pkg5 用例体同构——boot 在 add_child 内同步完成），
# 否则入口未 await 协程即 quit。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT60 := 1.0 / 60.0
const LONG_DT := 0.25                    # GAME_DELTA_CLAMP_S 同值（R194 单帧钳制上限）

var tree: SceneTree
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	tree.get_root().add_child(_gl)
	var data := EnemyData.new()
	data.id = &"E_QA256"
	data.hp_base = 1.0
	data.spd_base = 0.0
	data.dmg_base = 5.0
	data.exp_base = 7.0
	data.hitbox_r = 14.0
	var foes: Array[Enemy] = []
	for i in 12:
		var e: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
		e.spawn(data, 1, 0)
		e.position = Vector2(360, 640)
		_gl.spawner.active.append(e)
		foes.append(e)
	_gl.enemy_grid.rebuild(_gl.spawner.active)

	# ── 段A：正常帧基线（应摊平） ──────────────────────────────────
	_gl._reset_separation_wheel()
	var max_a := 0
	var total_a := 0
	for f in 7:
		var moved := _tick_and_count(foes, DT60)
		max_a = maxi(max_a, moved)
		total_a += moved
	print("[probe] 段A 正常帧：单帧最大位移敌 %d（<12=摊平）| 一轮全员服务累计 %d（==12）" % [
		max_a, total_a])
	var spread_a := _due_spread()
	print("[probe] 段A 到期相位散布（max-min）= %.4f s（>0=六片错峰在位）" % spread_a)

	# ── 段B：单次长帧（0.25s 钳制值）后恢复正常帧 ──────────────────
	var moved_long := _tick_and_count(foes, LONG_DT)
	var spread_b := _due_spread()
	print("[probe] 段B 长帧(0.25s)本帧位移敌 %d | 长帧后到期相位散布 = %.4f s" % [
		moved_long, spread_b])
	var max_b := 0
	var total_b := 0
	var full_frames := 0
	for f in 13:                          # 13×1/60 ≈ 0.217s：锁步下应再现 ≥2 个全量帧
		var moved := _tick_and_count(foes, DT60)
		max_b = maxi(max_b, moved)
		total_b += moved
		if moved >= 12:
			full_frames += 1
	print("[probe] 段B 后续 13 正常帧：单帧最大位移敌 %d | 全量帧（≥12 同帧）%d 个 | 累计 %d" % [
		max_b, full_frames, total_b])

	if spread_b == 0.0 and max_b >= 12 and full_frames >= 2:
		print("[probe] DEFECT 坐实：长帧追赶后六片锁步（相位散布 0，正常帧周期性单帧全量）"
			+ "——退化回 10Hz 全量分离形态，持续至下次 _reset_separation_wheel")
	elif max_b < 12 and spread_b > 0.0:
		print("[probe] 未复现锁步：相位散布 %.4f、最大单帧 %d（本缺陷不成立）" % [spread_b, max_b])
	else:
		print("[probe] 部分复现：散布 %.4f、最大单帧 %d、全量帧 %d——需人工判读" % [
			spread_b, max_b, full_frames])

	# 清场
	for e in foes:
		_gl.spawner.active.erase(e)
		(_gl.pools[&"enemy"] as EnemyPool).release(e)
	tree.paused = false
	_gl.free()
	_gl = null


func _tick_and_count(p_foes: Array[Enemy], p_dt: float) -> int:
	var before := PackedVector2Array()
	for e in p_foes:
		before.append(e.global_position)
	_gl._tick_separation(p_dt)
	var moved := 0
	for i in p_foes.size():
		if p_foes[i].global_position != before[i]:
			moved += 1
	return moved


func _due_spread() -> float:
	if _gl._sep_due.is_empty():
		return -1.0
	var lo := _gl._sep_due[0]
	var hi := _gl._sep_due[0]
	for v in _gl._sep_due:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	return hi - lo
