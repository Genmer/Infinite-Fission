# tests/runner/test_pkg13_extra.gd
# v1.3.0 tester 补漏入口（独立复算 + 验收缺口补测；两段式同 pkg13：
# godot --headless --path <工程> -s tests/runner/test_pkg13_extra.gd）
# 用例组 X1~X12（pkg13 V57~V78 未覆盖面的独立复算与补漏）：
#   X1 共鸣 attach 端到端 / X2 水晶 FIR 端到端 / X3 strip VOID 收口幂等 / X4 水晶跨局残留+GAME_OVER 不清
#   X5 最高层胜+VOID/MASTERY 不参与 / X6 4 把=3 把档 / X7 汽爆双元素 1.15² / X8 K_gold=0.5 跳过 +23
#   X9 类型守卫 _int_or 四键 / X10 敌弹穿过无副作用 / X11 seed1001 重播种同 pos / X12 水晶触发面 veto
extends SceneTree

const CASES_PATH := "res://tests/runner/pkg13_extra_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · v1.3.0 tester 补漏自测（pkg13_extra X1~X12） ══════════")
	# 等引擎注册的 autoload 完成 add_child + _ready（EventBus→GameConfig→DebugStats）
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
