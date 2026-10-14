# tests/runner/test_r250_difficulty_weapon_gate.gd
# 二dc「难度武器门」自测入口（godot --headless --path <工程> -s 本文件）
# 验收锚：A) 矩阵五键源码锚 B) 无局态全开（基线不动）C) Meta 武装哨兵语义
# D) 门矩阵（大关 AND 难度双门全组合）E) 卡池集成（boot 进局真抽候选）
# F) 图鉴锁行难度句 G) 开局横幅三档文案源码锚。
extends SceneTree

const CASES_PATH := "res://tests/runner/r250_difficulty_weapon_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R250 难度武器门自测 ══════════")
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
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)
