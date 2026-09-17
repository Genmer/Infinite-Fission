# tests/runner/fx_quality_cases.gd
# 特效质量档位用例体（由 test_fx_quality.gd 入口加载）。
extends RefCounted

const DT := 1.0 / 120.0
const MAIN_SCENE := "res://scenes/main.tscn"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	_test_setting_roundtrip()
	_test_popup_scaling()
	_test_particle_scaling()
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
	_gl = scene.instantiate() as GameLoop
	_gl.name = "GameLoopUnderTest"
	tree.get_root().add_child(_gl)


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	Meta.set_setting("fx_quality", 2)             # 复位出厂档（防污染其他套件）
	if _gl != null:
		_gl.free()
		_gl = null


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])


func _test_setting_roundtrip() -> void:
	print("── 设置读写 ──")
	_check("出厂默认：fx_quality = 2（高）", int(Meta.settings("fx_quality")) == 2)
	Meta.set_setting("fx_quality", 0)
	_check("写口：低档落盘读回", int(Meta.settings("fx_quality")) == 0)
	Meta.set_setting("fx_quality", 7)
	_check("写口：越界钳上界（7→2）", int(Meta.settings("fx_quality")) == 2)
	Meta.set_setting("fx_quality", -3)
	_check("写口：越界钳下界（-3→0）", int(Meta.settings("fx_quality")) == 0)
	Meta.set_setting("fx_quality", 2)
	_check("复位：高档", int(Meta.settings("fx_quality")) == 2)


func _test_popup_scaling() -> void:
	print("── 跳字档位 ──")
	_check("档位表：跳字上限 20/40/80",
		PopupManager.max_active_for(0) == 20 and PopupManager.max_active_for(1) == 40
		and PopupManager.max_active_for(2) == 80)
	_check("档位表：合并窗 0.3/0.2/0.12s",
		absf(PopupManager.merge_window_for(0) - 0.3) < 0.001
		and absf(PopupManager.merge_window_for(1) - 0.2) < 0.001
		and absf(PopupManager.merge_window_for(2) - 0.12) < 0.001)
	# 行为：低档下超过 20 个不同目标跳字 → 活跃数封顶 20
	Meta.set_setting("fx_quality", 0)
	var pos := Vector2(360.0, 400.0)
	for i in range(30):
		var r := DamageResult.new()
		r.final_value = 5.0 + float(i)          # 每个不同 uid 一条（无合并）
		r.target_uid = 100000 + i
		r.pos = pos + Vector2(0.0, float(i % 7) * 8.0)
		r.popup_style = GameConst.PopupStyle.NORMAL
		_gl.popup_manager.on_damage_resolved(r)
	_check("低档：跳字同屏封顶 20（30 个目标只出 20 条）",
		int(_gl.popup_manager.active_popups) == 20,
		"实得 %d" % int(_gl.popup_manager.active_popups))
	# 高档恢复：同屏上限放宽（活跃列表此刻 20 → 再来 10 条可增长）
	Meta.set_setting("fx_quality", 2)
	for i in range(30, 45):
		var r := DamageResult.new()
		r.final_value = 5.0
		r.target_uid = 200000 + i
		r.pos = pos
		r.popup_style = GameConst.PopupStyle.NORMAL
		_gl.popup_manager.on_damage_resolved(r)
	_check("高档：上限放宽到 80（35 条全部在册）",
		int(_gl.popup_manager.active_popups) == 35,
		"实得 %d" % int(_gl.popup_manager.active_popups))
	_gl.popup_manager.clear_all()


func _test_particle_scaling() -> void:
	print("── 粒子档位 ──")
	var gf := _gl.game_feel
	if gf == null or gf.particles == null:
		_check("粒子档位：GameFeel/粒子注入就绪", false)
		return
	var r := DamageResult.new()
	r.final_value = 5.0
	r.target_uid = 999999
	r.pos = Vector2(300.0, 600.0)
	r.popup_style = GameConst.PopupStyle.NORMAL
	# 低档：普命中不出粒子
	Meta.set_setting("fx_quality", 0)
	var b0 := gf.particles.burst_requests
	r.is_crit = false
	gf.on_damage_resolved(r)
	_check("低档：普命中 0 粒子爆发", int(gf.particles.burst_requests) == b0)
	r.is_crit = true
	gf.on_damage_resolved(r)
	_check("低档：暴击保留粒子（打击感底线）", int(gf.particles.burst_requests) == b0 + 1)
	# 高档：普命中恢复
	Meta.set_setting("fx_quality", 2)
	r.is_crit = false
	gf.on_damage_resolved(r)
	_check("高档：普命中恢复粒子", int(gf.particles.burst_requests) == b0 + 2)
