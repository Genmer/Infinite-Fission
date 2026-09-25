# tests/runner/test_w8_charge.gd
# W8 蓄能引爆改版自测入口（godot --headless --path <工程> -s tests/runner/test_w8_charge.gd）。
# 真源：五方向定案 orbit 组——R186 附着位拆除（attach 三件套退役）→ 蓄能状态机 +
# 引力脉冲 + 引爆三道闸 + 塑场击退改版 + 阈值换装（TH_DETONATION_ECHO/TH_RING_PRESSURE）。
extends SceneTree

const CASES_PATH := "res://tests/runner/w8_charge_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · W8 蓄能引爆自测 ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	var cases = cases_script.new()
	cases.run(self)
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)
