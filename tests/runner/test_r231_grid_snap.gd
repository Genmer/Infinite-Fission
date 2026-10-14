# tests/runner/test_r231_grid_snap.gd
# R231 刀A「SpaceGrid 读路径快照化」自测入口（godot --headless --path <工程> -s tests/runner/test_r231_grid_snap.gd）
# 真源：R231 设计 ③ 测试计划 T1-T7 + 分析 AC-1/AC-2/AC-5 销账口径——
# 快照语义等价（④ 头 rebuild 定型、死亡-回池不改位+dead 短路、击退速度型）、
# _radii 删除后常量保守半径口径（候选超集、窄相 live 裁定）、三 live 查询口径逐位不动。
# 用例体：r231_grid_snap_cases.gd（禁 test_ 前缀防电池 glob 误收——R230 教训）。
extends SceneTree

const CASES_PATH := "res://tests/runner/r231_grid_snap_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R231 刀A SpaceGrid 读路径快照化自测 ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		print("FAIL | 用例体加载失败（cases=%s）" % str(cases_script))
		print("验收汇总：0/1 通过")
		quit(1)
		return
	var cases = cases_script.new()
	await cases.run(self)                      # r230 入口同款：await 到用例收尾再读 fail_count
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)
