# tests/stress/test_perf_500p100e.gd
# AC-01.2 压力场景入口（架构 §附录：test_perf_500p100e.gd）。
# 口径：500 活跃投射物 + 100 活跃敌人 + ≥40 跳字 + ≥60 粒子发射器满载，
#   headless 手动驱动逻辑帧 60s 游戏时间（120Hz × 7200 帧），P95 < 8.3ms（frame_budget_ms）。
# 结构（同 pkg0~pkg5）：-s 脚本模式下入口脚本编译早于 autoload 全局名注册，
#   入口只做引导；用例体 perf_500p100e_cases.gd 经运行时 load 编译。
extends SceneTree

const CASES_PATH := "res://tests/stress/perf_500p100e_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · AC-01.2 压力场景（500弹+100敌） ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	var cases = cases_script.new()
	cases.run(self)
	quit(1 if cases.fail_count() > 0 else 0)
