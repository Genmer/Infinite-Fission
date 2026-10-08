# tests/qa_r228_costcurve.gd
# QA-R228 独立探针入口（QA 侧留档，勿删）：每 canvas item 引擎每帧成本曲线。
# 纯引擎夹具（Sprite2D/Node2D/ImageTexture），零工程类直引、零产品码改动、零 user:// 写入。
# 跑法（会话根执行）：
#   ./tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s tests/qa_r228_costcurve.gd
#   sanity 变体：上式尾加 --fixed-fps 60（每帧恰 1 物理tick 的确定性对照）。
# 输出契约：COST/COSTFIT/DERIVED/EXTRA 行 + 末行 QA_R228_RESULT {json}；FAIL>0 退出码 1。
extends SceneTree

const CASES_PATH := "res://tests/qa_r228_costcurve_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ QA-R228 成本曲线：每 canvas item 引擎每帧成本（headless 探针） ══════════")
	await process_frame
	await process_frame
	# 看门狗：用例体脚本错误中止协程时强制退出（probe_r202_bench.gd:21 先例）
	var watchdog: SceneTreeTimer = create_timer(600.0)
	watchdog.timeout.connect(_on_watchdog)
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		print("FAIL | 用例体加载失败")
		quit(2)
		return
	var cases = cases_script.new()
	await cases.run(self)
	var fail_count: int = cases.fail_count()
	print("入口汇总：FAIL=%d" % fail_count)
	if fail_count > 0:
		quit(1)
	else:
		quit(0)


func _on_watchdog() -> void:
	print("[watchdog] 探针超时/协程中止——强制退出（3）")
	quit(3)
