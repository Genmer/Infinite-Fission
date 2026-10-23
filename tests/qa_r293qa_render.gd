# tests/qa_r293qa_render.gd
# R293 QA 独立探针入口：弹幕渲染 MultiMesh 合批（独立于开发套件 qa_r293_multimesh
# 的第二只眼——补池账本对账/多帧运动跟随/留桶空闲弹幽灵负向探针/FORCED 回收镜面
# 守恒/S1·S7 短路臂计数器归属/真实换键链 BODY_MM 回退/窗口态 transform·色 parity）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load
#（照 tests/qa_r292qa_probe.gd 结构）。
extends SceneTree


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ R293 QA 独立探针 · 弹本体 MultiMesh 合批 ══════════")
	await process_frame
	await process_frame
	var cs: GDScript = load("res://tests/qa_r293qa_render_cases.gd")
	if cs == null or not cs.can_instantiate():
		print("FAIL | 用例体加载失败")
		print("探针汇总：0/1 通过")
		quit(1)
		return
	var cases = cs.new()
	await cases.run(self)
	var fails: int = cases.fail_count()
	quit(1 if fails > 0 else 0)
