# tests/qa_r263_fix_probe.gd — R263 修复轮 QA 独立复核探针（评审-2/3/5/6 落地验证）
# 电池编排：写 user:// 有副作用——单独跑。
extends SceneTree

const CASES_PATH := "res://tests/qa_r263_fix_probe_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R263 修复轮复核探针 ══════════")
	await process_frame
	await process_frame
	var body: GDScript = load(CASES_PATH)
	if body == null or not body.can_instantiate():
		print("PROBE FAIL | 用例体加载失败：%s" % CASES_PATH)
		quit(1)
		return
	var cases: Object = body.new()
	await cases.run(self)
	var fails: int = int(cases.call("fail_count"))
	quit(1 if fails > 0 else 0)
