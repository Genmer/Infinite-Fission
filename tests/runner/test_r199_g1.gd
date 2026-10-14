# tests/runner/test_r199_g1.gd
# R199-G1 局内循环组自测入口（godot --headless --path <工程> -s tests/runner/test_r199_g1.gd）
# 结构同 pkg0~pkg5 / history：-s 模式下入口脚本编译早于 autoload 全局名注册 → 入口只做引导；
# 用例体经运行时 load 编译（此时 autoload 已就绪）。
# 覆盖（R199 规划 G1 组四项，全部断言注明 R199）：
#   · P01（high）restart_run 补授 GameConst.difficulty_revives（重开局难度复活不缩水）
#   · P18（medium）选卡收口 / continue_endless 直迁 PLAYING 接 0.5s 输入宽限（防拖动残留瞬移）
#   · C10（medium）boot 空表闸 weapons 同判（weapons 类目缺失 → 拒绝入 MENU）
#   · N13（medium）换一批复传首 roll 留存保底（超频核心保底不洗掉；WORDS_TIDE 口径不回归）
extends SceneTree

const CASES_PATH := "res://tests/runner/r199_g1_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R199-G1 局内循环组自测 ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null:
		# 用例体编译失败（load 已打印解析错误）——立即失败退出（防 -s 套件悬挂电池）
		print("FAIL | 用例体加载失败")
		print("验收汇总：0/1 通过")
		quit(1)
		return
	var cases = cases_script.new()
	cases.run(self)
	var total_fail: int = cases.fail_count()
	print("验收汇总：%d/%d 通过" % [int(cases.get("_pass")),
		int(cases.get("_pass")) + total_fail])
	if total_fail > 0:
		quit(1)
	else:
		quit(0)
