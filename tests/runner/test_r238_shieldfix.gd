# tests/runner/test_r238_shieldfix.gd
# R238 护盾五面修复回归入口（godot --headless --path <工程> -s 本文件）
# 契约：H4 首挂即就绪（原首充 8s 空窗=「选了没生效」主因）；H1 层数几何逐层增益
# （原两档封顶第 3+ 层零可感）；H3 跨武器全槽聚合（原宿主单栈低卡覆写高档）；
# H2 栈满降级横幅明示；H5 出生位重叠预判 arm（信号缓存缺口）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load。
extends SceneTree

const CASES_PATH := "res://tests/runner/r238_shieldfix_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R238（格挡力场五面修复） 回归 ══════════")
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
