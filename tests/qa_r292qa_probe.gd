# tests/qa_r292qa_probe.gd
# R292 QA 独立探针入口：主菜单「导出日志」分段进度反馈（独立于开发套件
# qa_r292_export_progress 的第二只眼——补真输入注入点击/点击拦截/菜单态外/
# 节点释放悬挂/同秒连导文件覆盖/diag_export 直调契约等边界探针）。
extends SceneTree


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ R292 QA 独立探针 · 导出日志分段进度反馈 ══════════")
	await process_frame
	await process_frame
	var cs: GDScript = load("res://tests/qa_r292qa_probe_cases.gd")
	if cs == null or not cs.can_instantiate():
		print("FAIL | 用例体加载失败")
		print("探针汇总：0/1 通过")
		quit(1)
		return
	var cases = cs.new()
	await cases.run(self)
	var fails: int = cases.fail_count()
	quit(1 if fails > 0 else 0)
