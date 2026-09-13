# tests/runner/test_mech_gate.gd
# 机制解锁节奏自测入口（SceneTree 脚本：godot --headless --path <工程> -s tests/runner/test_mech_gate.gd）
# 覆盖（2026-09-13 用户反馈「机制太多……大关卡大关卡地解锁，每关都有新体验」）：
#   MechanicGate 无局全开口径、五大关逐项门控位、元素/遗物细粒度过滤、
#   CardGenerator 卡池联动（ELEM 池按元素 / RELIC 类目 / 赌徒诅咒终关）、质变挂载门。
# 结构说明（同 pkg0~pkg5）：-s 脚本模式下入口脚本编译早于 autoload 全局名注册，
# 入口只做引导；用例体经运行时 load 编译——此时 autoload 已就绪。
extends SceneTree

const CASES_PATH := "res://tests/runner/mech_gate_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · 机制解锁节奏自测 ══════════")
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
