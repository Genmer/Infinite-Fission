# tests/probe_fps_band.gd
# G4 探针入口（R202 帧率显示落位依据）。-s 模式入口编译早于 autoload 全局名注册
#（同 test_r198/test_r195 口径）——入口只做引导，实测体在 probe_fps_band_body.gd。
# 非 test_ 前缀（不入电池 glob）。
extends SceneTree

const BODY_PATH := "res://tests/probe_fps_band_body.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("═══ G4 探针：HUD 空带实测（FPS Label 落位依据） ═══")
	await process_frame
	await process_frame
	var body_script: GDScript = load(BODY_PATH)
	if body_script == null or not body_script.can_instantiate():
		print("PROBE-FAIL | 探针体加载失败")
		quit(1)
		return
	var body = body_script.new()
	await body.run(self)
	quit(0)
