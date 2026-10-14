# R262d 应急强化批验收入口（SceneTree 两段式——cases 运行时 load，autoload 编译时序）
# 覆盖：品级定标四档 · FALLBACK 卡直选走全局 · 满员转化横幅（品级+数值）· 全武器生效 ·
# 本命重写共存 · 存档往返+旧档武器栈词条迁移 · 黑市常青货无宿主恒真 · 衰减口径锁
extends SceneTree

const CASES := "res://tests/qa_r262d_fallback_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	await process_frame                     # 首帧驱动（boot 就绪——与 qa_r261/262c 同口径）
	var cases = load(CASES).new()
	var fails: int = int(cases.call("run_all", self))
	quit(1 if fails > 0 else 0)
