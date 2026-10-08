# tests/runner/test_r202_g3_enemyhot.gd
# R202 G3「敌群热路径与渲染优化」自测入口（godot --headless --path <工程>
#   -s tests/runner/test_r202_g3_enemyhot.gd）。
# 命名避让说明：主控原派名 test_r202_perf.gd 已被 G4「帧率显示」套件占用
# （r202_perf_cases.gd 域K/域F/域S = show_fps 断言——非本组所有，不得覆写），
# 本组建 G3 专属名。
# 覆盖：①fx_quality 缓存 ②接触伤害圆距 ③闪白窗外摘材质 ④状态表现件档预算
# ⑤写点 30Hz 节拍（首帧写透）⑥Boss 附属弱引用 ⑦元素系统复用缓冲遍历
# ⑧reaction_cd 零分配 ⑨beam_impact 迸裂节流。
extends SceneTree

const CASES_PATH := "res://tests/runner/r202_g3_enemyhot_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R202 G3 敌群热路径优化自测 ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		print("FAIL | 用例体加载失败（cases=%s）" % str(cases_script))
		print("汇总：PASS 0 / FAIL 1（共 1 项）")
		quit(1)
		return
	var cases = cases_script.new()
	await cases.run(self)          # run 含 await（② 用真物理帧驱动）——协程等待
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)
