# R262b 修复批验收入口（SceneTree 两段式——cases 运行时 load，autoload 编译时序）
# 覆盖：H1/M6 量化收口源码锚 · M1 存档品级往返（+S2 质变）· M2 泵还账 · M3 世代缓存 ·
# M4/M5/L1/L13/L17 源码锚 · L11 validator 拦截 · L14 图鉴滤 TH_* · L16 文案
extends SceneTree

const CASES := "res://tests/qa_r262c_fixes_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	await process_frame                     # 首帧驱动（boot 就绪——与 qa_r261 同口径）
	var cases = load(CASES).new()
	var fails: int = int(cases.call("run_all", self))
	quit(1 if fails > 0 else 0)
