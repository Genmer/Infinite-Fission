# tests/probe_r238_barrier_repro.gd
# R238「格挡力场（MEC_SHIELD）选了没生效」五假设（H1-H5）headless 诊断探针——入口。
# 契约：
# · 诊断模式：断言结果不影响退出码——恒 exit 0（探针失败/假设被驳倒都是有效诊断信息）。
# · stdout 末行 = VERDICT JSON（输出契约，见 cases 尾部拼装）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load
#（参照 tests/runner/test_r237_contact_radial.gd 同款结构）。
extends SceneTree

const CASES_PATH := "res://tests/probe_r238_barrier_repro_cases.gd"
const PROBE_FILE := "repo/tests/probe_r238_barrier_repro.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R238（MEC_SHIELD「选了没生效」五假设 H1-H5） 诊断探针 ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		print("FAIL | 用例体加载失败（cases=%s）——诊断模式恒 exit 0" % str(cases_script))
		_print_verdict(_all_inconclusive("用例体加载失败，五假设均无法判定"))
		quit(0)
		return
	var cases = cases_script.new()
	await cases.run(self)
	quit(0)                                       # 诊断模式：无论断言成败恒 0


func _all_inconclusive(p_reason: String) -> Dictionary:
	var verdicts: Array = []
	for h in ["H1", "H2", "H3", "H4", "H5"]:
		verdicts.append({"id": h, "result": "inconclusive", "evidence": p_reason})
	return {
		"verdicts": verdicts,
		"summary": p_reason,
		"probeFile": PROBE_FILE,
	}


func _print_verdict(p_out: Dictionary) -> void:
	print("VERDICT: " + JSON.stringify(p_out))
