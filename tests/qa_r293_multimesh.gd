# tests/qa_r293_multimesh.gd
# R293 刀A 独立验收：弹幕渲染 MultiMesh 合批（弹本体绘制改按贴图桶 MultiMeshInstance2D
# 每帧同步 transform+modulate；模拟行为零改动/特效保留）。入口。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load
#（照 tests/qa_r292_export_progress.gd 结构）。
extends SceneTree


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ R293 独立验收 · 弹本体 MultiMesh 合批 ══════════")
	await process_frame
	await process_frame
	var cs: GDScript = load("res://tests/qa_r293_multimesh_cases.gd")
	if cs == null or not cs.can_instantiate():
		print("FAIL | 用例体加载失败")
		print("验收汇总：0/1 通过")
		quit(1)
		return
	var cases = cs.new()
	await cases.run(self)
	var fails: int = cases.fail_count()
	quit(1 if fails > 0 else 0)
