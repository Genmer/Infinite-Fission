# tests/runner/test_r232_resolve_equiv.gd
# R232 回归入口（godot --headless --path <工程> -s 本文件）
# 契约：开关双跑同种子整局对拍（R231 T9 模式复用）——CTX_REUSE/TRAIT_PRECACHE
# off/on 两臂，伤害值谱 distinct 硬等价 + 值桶/计数桶 ≤max(2,5%) 漂移容差；饱和
# （override=4）+迸裂/弹片嵌套复合场景（分析 R4）与无预算双腿。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load。
extends SceneTree

const CASES_PATH := "res://tests/runner/r232_resolve_equiv_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R232（刀1b/1c 开关双跑整局等价） 回归 ══════════")
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
