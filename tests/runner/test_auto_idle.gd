# tests/runner/test_auto_idle.gd
# R188-3 挂机全链路验收入口（godot --headless --path <工程> -s tests/runner/test_auto_idle.gd）
# 真源：R188 idle 定案六组（A 设置 / B 开关 / C 选卡 / D 商店 / E 结算 / F soak）。
# 两段式入口：入口零 autoload 编译期引用——autoload 就绪后运行时 load() 用例体
#（fx_quality / r187 runner 同模式）；全 PASS exit 0，否则 exit 1。
extends SceneTree

const CASES_PATH := "res://tests/runner/auto_idle_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R188-3 挂机全链路验收 ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	var cases = cases_script.new()
	cases.run(self)
	var failed: int = cases.fail_count()
	print("══════════════════════════════════════════════════")
	print("验收汇总：FAIL %d" % failed)
	quit(0 if failed == 0 else 1)
