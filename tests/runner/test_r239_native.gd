# tests/runner/test_r239_native.gd
# R239 原生第一刀「SpaceGrid.query_circle_snap GDExtension 下沉」等价性自测入口
# （godot --headless --path <工程> -s tests/runner/test_r239_native.gd）。
# 真源：R239 任务书——off/on 两臂同快照查询结果逐位一致（候选 id 集合+顺序）×多组
# 几何（空结果/边界半径/密集重叠/出网格钳制）；开关门矩阵（默认关零扰动/开启走原生/
# 扩展缺失自动回落）；rebuild+波内补插生命周期；live 三查询口径回归不动。
# 用例体：r239_native_cases.gd（禁 test_ 前缀防电池 glob 误收——R230 教训）。
# 前置：repo/native/bin 双 dll 在位且 .gdextension 已被编辑器扫描（extension_list.cfg）；
# 扩展加载失败时本套件 FAIL（如实报红不跳过——原生路径是本轮交付物，缺载即不合格）。
extends SceneTree

const CASES_PATH := "res://tests/runner/r239_native_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R239 原生第一刀 SpaceGrid GDExtension 等价性自测 ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		print("FAIL | 用例体加载失败（cases=%s）" % str(cases_script))
		print("验收汇总：0/1 通过")
		quit(1)
		return
	var cases = cases_script.new()
	await cases.run(self)                      # r231 入口同款：await 到用例收尾再读 fail_count
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)
