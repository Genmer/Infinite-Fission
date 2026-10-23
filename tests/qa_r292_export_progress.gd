# tests/qa_r292_export_progress.gd
# R292 独立验收：主菜单「导出日志」分段进度反馈（用户反馈：真机一键导出「跟卡了
# 一样」零反馈——组装/写盘、剪贴板、弹预览框原全挤一帧）。入口。
extends SceneTree


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ R292 独立验收 · 导出日志分段进度反馈 ══════════")
	await process_frame
	await process_frame
	var cs: GDScript = load("res://tests/qa_r292_export_progress_cases.gd")
	if cs == null or not cs.can_instantiate():
		print("FAIL | 用例体加载失败")
		print("验收汇总：0/1 通过")
		quit(1)
		return
	var cases = cs.new()
	await cases.run(self)
	var fails: int = cases.fail_count()
	quit(1 if fails > 0 else 0)
