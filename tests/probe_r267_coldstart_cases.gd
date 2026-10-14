# R267 ②冷位图出发组合用例体：mobile 门开（runstart_bake_override=1）+ 图集未烤
# → start_run 整链计时 = 「真机快速出发（菜单停留不足预热）」桌面当量。
# 对照组：图集已烤后同口径 start_run（≈R262e 3909µs 桌面基线）。只测不改。
extends RefCounted

var _tree: SceneTree = null
var _fails: int = 0
var _passes: int = 0


func _check(p_name: String, p_ok: bool, p_detail: String = "") -> void:
	if p_ok:
		_passes += 1
		print("PASS | " + p_name)
	else:
		_fails += 1
		print("FAIL | " + p_name + ("" if p_detail.is_empty() else "  [got: " + p_detail + "]"))


func run_all(p_tree: SceneTree) -> int:
	_tree = p_tree
	var gl = GameLoop.new()
	gl.name = "R267Cold"
	_tree.get_root().add_child(gl)
	gl.set_physics_process(false)

	# 冷组：mobile 门开 + 图集未烤 → start_run（首跑含 ensure_runstart_bake 全量补烤）
	PopupGlyphAtlas.runstart_bake_override = 1
	var t0 := Time.get_ticks_usec()
	var ok1: bool = gl.call("start_run")
	var cold_us := Time.get_ticks_usec() - t0
	PopupGlyphAtlas.runstart_bake_override = -1
	print("    start_run 冷位图（门开+未烤）= %.1f ms（ok=%s, built=%d/12）" % [
		float(cold_us) / 1000.0, str(ok1), PopupGlyphAtlas.built_count()])

	# 热组：图集已烤（ready()=true 直返）→ 同口径 start_run
	gl.state = GameConst.GameStatus.PAUSED
	gl.call("quit_to_menu")
	var t1 := Time.get_ticks_usec()
	var ok2: bool = gl.call("start_run")
	var warm_us := Time.get_ticks_usec() - t1
	print("    start_run 热位图（已烤）= %.2f ms（ok=%s）" % [
		float(warm_us) / 1000.0, str(ok2)])
	print("    差值（=ensure_runstart_bake 同帧补烤净贡献）= %.1f ms" % [
		float(cold_us - warm_us) / 1000.0])
	_check("R267 冷位图出发组合落账（冷 %.1f ms / 热 %.2f ms / 差 %.1f ms）" % [
		float(cold_us) / 1000.0, float(warm_us) / 1000.0,
		float(cold_us - warm_us) / 1000.0],
		ok1 and ok2 and cold_us > warm_us and PopupGlyphAtlas.built_count() == 12)
	gl.state = GameConst.GameStatus.PAUSED
	gl.queue_free()
	print("R267 冷位图探针汇总：PASS %d / FAIL %d（共 %d 项）" % [_passes, _fails, _passes + _fails])
	print("验收汇总：PASS %d / FAIL %d" % [_passes, _fails])
	return _fails
