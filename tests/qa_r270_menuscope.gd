# tests/qa_r270_menuscope.gd
# R270 修复①入口：分辨率降档仅活战态（vc79 真机「主页分辨率乱/按钮显示不全」回归——
# boot 全局应用 612×1088 画布使 720×1280 布点菜单 UI 溢出被裁）+ 修复②真路径敌弹计数验证。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load
#（qa_r269_boostmode.gd 同款结构；套件落 tests/ 根）。
extends SceneTree

const CASES_PATH := "res://tests/qa_r270_menuscope_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R270 菜单域分辨率回归+真路径敌弹计数 回归 ══════════")
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
