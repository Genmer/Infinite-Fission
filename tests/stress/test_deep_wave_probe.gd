# tests/stress/test_deep_wave_probe.gd
# R188 新增锚：深层无尽探针入口（两段式——入口只做引导，用例体运行时 load 编译）。
# 覆盖（验收口径）：
#   A. w233 建波探针：start_wave 单帧 ≤5ms（O(count) 建波结构性消除）+ spawn_queue ≤600；
#   B. 高水位拒收：队列 600 满后投放拒收 + 计数 + 一次告警；
#   C. gain_xp(1e12) 连升探针：选卡排队 ≤3（连升合并帽）+ 探针全程无单帧 >50ms。
extends SceneTree

const CASES_PATH := "res://tests/stress/deep_wave_probe_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R188 深层无尽探针（w233 建波/连升合并） ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	var cases = cases_script.new()
	await cases.run(self)
	quit(1 if cases.fail_count() > 0 else 0)
