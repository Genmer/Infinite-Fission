# tests/qa_r226_ele_register_probe.gd
# R226 QA 探针入口（非电池口；手工跑法：
#   ./tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s tests/qa_r226_ele_register_probe.gd
# 猎杀面：拆帽后「低品质 ELE 反应卡后挂 → reaction_mult 注册表被覆写降级」疑点
#（weapon_base.attach_trait ELEM 臂按 p_trait.value 注册 + ElementalSystem.register_reaction_mult
#  覆写语义；帽时代 ELE stack_max=1 二挂被拒不可达，R226 起新可达）。
# 纪律：-s 入口零工程类名直引；用例体运行时 load。
extends SceneTree

const CASES_PATH := "res://tests/qa_r226_ele_register_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R226 ELE 反应乘区注册降级探针 ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		print("FAIL | 用例体加载失败（cases=%s）" % str(cases_script))
		print("验收汇总：0/1 通过")
		quit(1)
		return
	var cases = cases_script.new()
	await cases.run(self)
	if cases.fail_count() > 0:
		quit(1)
	else:
		quit(0)
