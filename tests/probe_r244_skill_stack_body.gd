# tests/probe_r244_skill_stack_body.gd（R244 探针用例体）
# 判读口径：R246 已修（_skill_summon_orbs 入口先 _summon_restore 再重掷）——
# ①②④ 断言为「已修」期望值（效果期内再施放恒回收重掷=2，时长刷新语义）；修复前
# 原口径（append 不清旧 2→4→6 无帽叠）见 FEEDBACK_TRACKER R244 诊断；③⑤ 是
# 回收链与幂等对照组（任何实现下都必须成立）。
extends RefCounted

const DT := 1.0 / 120.0
const MAIN_SCENE := "res://scenes/main.tscn"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: Object = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	Meta.set_setting("fx_quality", 2)
	_boot_game_loop()
	_test_noah_recast_stacks_copies()
	_test_recast_refreshes_shared_lifetime()
	_test_expiry_still_reclaims_without_recast()
	_test_drones_accumulate_then_self_expire()
	_test_veles_recast_idempotent_contrast()
	_teardown_game_loop()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate()
	_gl.name = "GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	var p: Object = _gl.player
	p.set("max_hp", 1000000.0)
	p.set("hp", 1000000.0)
	p.set("character_id", &"noah")          # 直写角色（绕开 set_character 整局重置副作用）
	p.call(&"refresh_skill_cd")


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()


func _copies() -> int:
	return (_gl.player.get("_summon_copies") as Array).size()


func _drones() -> int:
	return (_gl.player.get("_summon_drones") as Array).size()


func _cast_bypass_cd() -> bool:
	# 等效「有效 CD 已被 CDR 堆到 <10s 后自动施放的逐帧再触发」：直写冷却归零再施放
	_gl.player.set("skill_cd_left", 0.0)
	return bool(_gl.player.call(&"activate_skill"))


func _tick_seconds(p_sec: float) -> void:
	var steps := int(p_sec / DT)
	for i in steps:
		_gl.player.call(&"tick", DT, Vector2.ZERO)


func _check(p_cond: bool, p_msg: String, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  PASS | %s" % p_msg)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_msg, p_detail])
		print("  FAIL | %s %s" % [p_msg, p_detail])


func _test_noah_recast_stacks_copies() -> void:
	print("── ① 诺亚效果期内再施放：先回收再重掷（R246 已修——恒 2 不叠） ──")
	var p: Object = _gl.player
	_check(int(p.call(&"skill_ready")) != 0, "开局技能就绪")
	_check(bool(p.call(&"activate_skill")), "第 1 次施放成功")
	_check(_copies() == 2, "施放 1 次后副本=2", "copies=%d" % _copies())
	_check(_drones() == 2, "施放 1 次后护航舰=2", "drones=%d" % _drones())
	_check(bool(_cast_bypass_cd()), "效果期内（冷却归零）再施放成功")
	_check(_copies() == 2, "施放 2 次后副本=2（入口先回收旧副本再重掷；>2 即叠层回归）",
		"copies=%d" % _copies())
	_check(bool(_cast_bypass_cd()), "第 3 次施放成功")
	_check(_copies() == 2, "施放 3 次后副本=2（无帽线性叠已根除）", "copies=%d" % _copies())
	_check(_drones() == 2, "施放 3 次后护航舰=2（同先回收再重掷）", "drones=%d" % _drones())


func _test_recast_refreshes_shared_lifetime() -> void:
	print("── ② 再施放=回收旧批+寿命刷新回满（不再续命旧副本） ──")
	var p: Object = _gl.player
	p.call(&"_summon_restore")             # 清场重测
	_cast_bypass_cd()
	_tick_seconds(8.0)                     # 8s < SUMMON_DURATION 10s：副本应仍在
	_check(_copies() == 2, "8s 后副本仍在（10s 期内）", "copies=%d" % _copies())
	var first_batch: Array = (p.get("_summon_copies") as Array).duplicate()
	_cast_bypass_cd()                      # 效果期内再放（旧批回收 + 寿命重置）
	var left: float = float(p.get("_summon_left"))
	_check(left > 9.0, "再施放把 _summon_left 刷新回满 10s（刷新时长语义保持）", "left=%.2f" % left)
	_check(_copies() == 2, "再施放后在场副本恒=2（旧批已回收非续命）", "copies=%d" % _copies())
	var first_alive := 0
	for c in first_batch:
		if c != null and is_instance_valid(c) and not (c as Node).is_queued_for_deletion():
			first_alive += 1
	_check(first_alive == 0, "首批副本实例已全部回收（queue_free 落账，无叠存残留）",
		"alive=%d" % first_alive)
	_tick_seconds(2.5)                     # 距首放 10.5s（旧口径下首批被续命会=4）
	_check(_copies() == 2, "首放后 10.5s 副本=2（第二批 2.5s 在册；=4 即续命叠存回归）",
		"copies=%d" % _copies())


func _test_expiry_still_reclaims_without_recast() -> void:
	print("── ③ 不再施放时到期回收链仍工作 ──")
	_tick_seconds(10.5)                    # 距上次施放 13s > 10s
	_check(_copies() == 0, "停手 10s 后副本全回收", "copies=%d" % _copies())


func _test_drones_accumulate_then_self_expire() -> void:
	print("── ④ 护航舰：连放不清旧口径已根除 + 到期回收链仍工作 ──")
	var p: Object = _gl.player
	p.call(&"_summon_restore")
	for i in 5:
		_cast_bypass_cd()
	_check(_drones() == 2, "连放 5 次护航舰瞬时=2（先回收再重掷；>2 即叠层回归）",
		"drones=%d" % _drones())
	_tick_seconds(10.5)
	var alive := 0
	for d in (p.get("_summon_drones") as Array):
		if d != null and is_instance_valid(d) and not (d as Node).is_queued_for_deletion():
			alive += 1
	_check(alive == 0, "10.5s 后护航舰到期回收清零（统一 _summon_restore 收口）", "alive=%d" % alive)


func _test_veles_recast_idempotent_contrast() -> void:
	print("── ⑤ 对照组：薇尔过载（增益型）效果期内再放不叠 ──")
	var p: Object = _gl.player
	p.call(&"_summon_restore")
	p.set("character_id", &"veles")
	p.set("rof_mult", 1.0)
	_cast_bypass_cd()
	p.set("skill_cd_left", 0.0)
	_check(bool(p.call(&"activate_skill")), "效果期内再施放成功")
	_check(is_equal_approx(float(p.get("rof_mult")), 2.0), "rof_mult 仍=2.0（幂等覆盖不叠乘）",
		"rof_mult=%.2f" % float(p.get("rof_mult")))
	_check(is_equal_approx(float(p.get("skill_active_left")), 4.0), "skill_active_left 刷新=4s（单计时器）",
		"left=%.2f" % float(p.get("skill_active_left")))
	p.set("skill_active_left", 0.0)
	p.set("rof_mult", 1.0)
	p.call(&"refresh_weapon_intervals")
