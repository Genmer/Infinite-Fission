# tests/qa_r271_deeprepro.gd
# R271 P 轨 headless 深载复现台架入口（设计 §3.2——qa_r271_deeprepro_cases.gd 用例体）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load
#（照 tests/qa_r269_boostmode.gd 结构；套件落 tests/ 根）。
# 修轮 M1（评审/QA DEF-1）落盘参化——用法（照 qa_r228_diagfreeze「-- compare=」先例）：
#   缺省            → 复跑态档 docs/qa/2026-10-14-R271-deeprepro-postcut.md（可覆写）
#   -- archive=1    → 归档档 docs/qa/2026-10-14-R271-deeprepro-verdict.md
#                     （已存在则拒写并继续跑——防复跑破坏归档 md5 基线）
extends SceneTree

const CASES_PATH := "res://tests/qa_r271_deeprepro_cases.gd"


func _initialize() -> void:
	_run()


func _archive_from_args() -> bool:
	# 用户参数（-- 之后）：archive=1 = 归档态；其余/缺省 = 复跑态
	for a in OS.get_cmdline_user_args():
		if String(a).strip_edges() == "archive=1":
			return true
	return false


func _run() -> void:
	print("══════════ Infinite Fission · R271 headless 深载复现台架（复现臂+S1-S7 短路二分+M4 有效性门+verdict 表） ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		print("FAIL | 用例体加载失败（cases=%s）" % str(cases_script))
		print("验收汇总：0/1 通过")
		quit(1)
		return
	var cases = cases_script.new()
	await cases.run(self, _archive_from_args())
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)
