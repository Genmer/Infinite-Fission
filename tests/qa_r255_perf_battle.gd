# tests/qa_r255_perf_battle.gd
# R255 性能猎手·战斗帧预算分布探针（只测不改产品码）。
# 改造自 tests/stress/perf_500p100e_cases.gd 框架，差异三点：
# ① 进局路径修正：R252 祝福面板拦截 start_requested 后，旧压力套件 emit 信号会停在
#   MENU 空转（2026-10-11 复跑实证：敌 0 / 帧均 0.007ms / 阶段均值空）——本探针直调
#   gl.start_run()；
# ② 负载加敌弹 300（Boss 弹幕口径 team=1，spawn 参数仿 enemy.gd:1845 _spawn_boss_bullet）
#   + 玩家弹 500 + 敌 100；
# ③ 输出 stage_probe_us 分阶段帧预算分布（全帧均值/峰值）+ 波次切换帧单独归因 + 最差
#   8 帧分解。
# 用法：Godot --headless --path <repo> -s tests/qa_r255_perf_battle.gd
extends SceneTree

const BODY_PATH := "res://tests/qa_r255_perf_battle_body.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("═══ R255 战斗帧预算分布探针（500 玩家弹 + 300 敌弹 + 100 敌，headless 逻辑帧） ═══")
	await process_frame
	await process_frame
	var watchdog: SceneTreeTimer = create_timer(900.0)
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
