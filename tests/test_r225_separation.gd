# tests/test_r225_separation.gd
# R225 回归入口（godot --headless --path <工程> -s 本文件）
# 契约：-4 全弃哨兵（R225 分离测量档——damage_pipeline settle_budget_override 新值）
# ① 全弃语义：通过三闸的提交全部丢弃计数 separate_drop、零真结算（settles 不增/
#    不落血/不入派发队/无积压）；
# ② separate_drop 计数正确（含幂等折返不计入的口径）；
# ③ -1/-2/-3/≥0 既有语义零回归的最小用例（headless 帽 0 真结算 / 强制关 / -3 tier
#    映射 / 强制帽顺延）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load
# （两文件铁律——入口+cases，test_r223_settlebudget 同构）。注意：本套件位于 tests/
# 非 tests/runner/——_batt_r215.py 只纳 tests/runner/test_*.gd，本套件手动直跑。
extends SceneTree

const CASES_PATH := "res://tests/test_r225_separation_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R225（-4 全弃哨兵契约） 回归 ══════════")
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
