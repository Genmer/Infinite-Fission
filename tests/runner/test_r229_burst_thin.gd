# tests/runner/test_r229_burst_thin.gd
# R229 粒子满载门收口自测入口（godot --headless --path <工程> -s tests/runner/test_r229_burst_thin.gd）
# 真源：R228 绘制谱——深载 CRIT/KILL/反应爆闪流把 64 发射器池打满 = 64 独立 dc 地板；
# 本刀三路接入三重门（mobile ∧ 帧率优先 ∧ tier≤2）减薄，CRIT 1/4 / 普通 KILL 1/4、
# 精英 KILL 1/2、Boss 全保留 / 反应 1/2；桌面/headless 零扰动（负向锚 8/8/8/1）。
extends SceneTree

const CASES_PATH := "res://tests/runner/r229_burst_thin_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R229 粒子满载门收口自测 ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		print("FAIL | 用例体加载失败（cases=%s）" % str(cases_script))
		print("验收汇总：0/1 通过")
		quit(1)
		return
	var cases = cases_script.new()
	await cases.run(self)                      # r223 入口同款：await 到用例收尾再读 fail_count
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)
