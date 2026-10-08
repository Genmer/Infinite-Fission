# tests/qa_r226_ele_register_cases.gd
# R226 ELE 反应乘区注册降级探针用例体（入口 tests/qa_r226_ele_register_probe.gd）。
# 场景复现（金后挂白降级）：
#   ① 金卡元素裂变（value=1.8×2.6=4.68，仿 card_generator._apply_rarity_values 金档
#      缩放——R192 wire T5 臂 value×scale，卡面「×4.7」）attach → 注册 ×4.68；
#   ② 白卡元素裂变（value=1.8）后挂——R226 拆帽后 attach 成功（ELE 取优：data 仍金），
#      但 weapon_base.attach_trait ELEM 臂按 p_trait.value 注册 → 覆写 ×1.8；
#   ③ 断言注册值 < 挂载定义值 = 降级（帽时代 stack_max=1 二挂被拒不可达）。
extends RefCounted

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
	await tree.process_frame
	await tree.process_frame
	_test_ele_register_downgrade()
	_teardown_game_loop()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])


func fail_count() -> int:
	return _fail


func _check(p_cond: bool, p_name: String, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s | %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])


func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "QA226EleGameLoop"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_gl.state = GameConst.GameStatus.MENU
	Meta.set_run_map(&"")


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	Meta.set_run_map(&"")
	if _gl != null:
		_gl.free()
		_gl = null


func _test_ele_register_downgrade() -> void:
	print("── ELE 反应乘区注册：金后挂白降级疑点 ──")
	var sys := ElementalSystem.new()
	var w: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W1_pistol"))
	w.elemental = sys                            # 注入元素系统（生产由 deps 注入）
	var base: TraitData = _gl.registry.get_trait(&"ELE_REACTION_VOID")
	var gold: TraitData = base.duplicate() as TraitData
	gold.value = 1.8 * 2.6                       # 金档缩放（card_generator R192 臂同式）
	gold.params = {"reaction_mult": gold.value}
	gold.rarity = 3
	var ok_gold: bool = w.attach_trait(gold)
	var mult_gold: float = sys.reaction_mult()
	_check(ok_gold and absf(mult_gold - 4.68) < 0.001,
		"① 金卡挂载 → 注册 ×4.68", "ok=%s mult=%f" % [str(ok_gold), mult_gold])
	var ok_white: bool = w.attach_trait(base)    # R226：同 ID 无限叠 → 成功
	var mounted: TraitBase = w.trait_stack.traits[0]
	var mult_after: float = sys.reaction_mult()
	print("     （二挂 ok=%s；挂载侧取优 data.value=%.2f layers=%d；注册值=%.3f）"
		% [str(ok_white), float(mounted.data.value), mounted.layers, mult_after])
	_check(ok_white and absf(float(mounted.data.value) - 4.68) < 0.001,
		"② 白卡后挂成功且挂载定义保持金 4.68（ELE 取优语义不变）",
		"data=%.2f" % float(mounted.data.value))
	_check(absf(mult_after - 4.68) < 0.001,
		"③ 注册乘区不降级（期望 ×4.68，实测 %.3f——降级=探针红）" % mult_after,
		"mult=%.3f" % mult_after)
	w.queue_free()
	sys.free()
