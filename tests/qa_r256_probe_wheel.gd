# tests/qa_r256_probe_wheel.gd（R256 QA 序2 分片轮长帧锁步复现探针入口）
# 跑法："E:/Code/Agent/Infinite-Fission/android_export/Godot_v4.3-stable_win64.exe" \
#         --headless --path E:/Code/Agent/Infinite-Fission/repo -s tests/qa_r256_probe_wheel.gd
# 目的：语义审查发现的疑点实证——_tick_separation 长帧追赶把同帧到期的多片重排到
#   同一到期时刻（_sep_due[i] = _sep_clock + INTERVAL，game_loop.gd:3922），单次
#   ≥SEPARATION_INTERVAL(0.1s) 的游戏增量（GAME_DELTA_CLAMP_S=0.25 钳制内可达，
#   真机后台恢复/长卡顿即触发）会让六片永久锁步＝退化回 10Hz 全量单帧尖峰，
#   直至下次 _reset_separation_wheel。本探针只演示与取证，exit 0，DEFECT 行为证据。
extends SceneTree

const CASES_PATH := "res://tests/qa_r256_probe_wheel_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	await process_frame
	var body: GDScript = load(CASES_PATH)
	if body == null or not body.can_instantiate():
		print("PROBE FAIL | 用例体加载失败：%s" % CASES_PATH)
		quit(1)
		return
	var cases: Object = body.new()
	cases.run(self)
	quit(0)
