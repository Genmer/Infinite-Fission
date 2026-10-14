# tests/runner/test_r244_flushbucket.gd
# R244「物理相冲刷桶批」自测入口（godot --headless --path <工程> -s tests/runner/test_r244_flushbucket.gd）
# 真源：vc53 真机菜单行 物步µs 45170→77486 两秒尖峰——归因=MENU 态贴图预热跑在
# _physics_process 物理窗内（gl_compatibility 贴图上传主线程同步；R215 自证 boss 双面
# 单项 88-245ms），MENU 段探针不记账 → 物步µs 残差独吞读数。修 A=预热消费迁渲染轴
# _process；修 B=帧入口 glue 下洞 entry 段键（advance_frame/trim/ip_restore/begin_frame/
# _game_delta 此前无段键全额落「他」），行格式零改动（键不进 DIAG_STAGE_ORDER）。
extends SceneTree

const CASES_PATH := "res://tests/runner/r244_flushbucket_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R244 物理相冲刷桶批自测 ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		print("FAIL | 用例体加载失败（cases=%s）" % str(cases_script))
		print("验收汇总：0/1 通过")
		quit(1)
		return
	var cases = cases_script.new()
	await cases.run(self)                      # r229 入口同款：await 到用例收尾再读 fail_count
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)
