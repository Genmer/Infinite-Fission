# tests/qa_r255_perf_flow.gd
# R255 性能猎手·局中大流程探针（只测不改产品码）。
# 量三件事（headless，Time.get_ticks_usec 包裹直调 + 自然帧采样）：
# ① 波次切换：自然推进帧（敌 hp 压低加速清波）全帧 + wave 段耗时；
# ② 升级选卡开合：_open_card_flow（开） / card_select_ui.choose（选+合+恢复） /
#    _on_card_reroll（换一批）各 5 次中位数；
# ③ 结算：胜利结算帧（_on_wave_cleared_victory → 2.2s 窗 → show_victory）/
#    死亡结算（player_died emit）/ restart_run（重开）。
# 用法：Godot --headless --path <repo> -s tests/qa_r255_perf_flow.gd
extends SceneTree

const BODY_PATH := "res://tests/qa_r255_perf_flow_body.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("═══ R255 局中大流程探针（波次切换 / 选卡开合 / 结算） ═══")
	await process_frame
	await process_frame
	var watchdog: SceneTreeTimer = create_timer(600.0)
	watchdog.timeout.connect(_on_watchdog)
	var body_script: GDScript = load(BODY_PATH)
	if body_script == null or not body_script.can_instantiate():
		print("PROBE-FAIL | body 加载失败：%s" % str(body_script))
		quit(1)
		return
	var body = body_script.new()
	await body.run(self)
	quit(0 if body.fail_count() == 0 else 1)


func _on_watchdog() -> void:
	print("[watchdog] 探针超时——强制退出（3）")
	quit(3)
