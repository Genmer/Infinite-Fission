# tests/probe_r246_ranger_blink.gd（R246 游侠瞬步·越界回弹 修复回归探针入口）
# 跑法：APPDATA=E:/Code/Agent/Infinite-Fission/.qa_sandbox_r243 Godot --headless \
#         --path E:/Code/Agent/Infinite-Fission/repo -s tests/probe_r246_ranger_blink.gd
# 假设检验：R246 前 activate_skill 瞬步落点用 _clamp_to_playfield_pos 全屏界（y≥24）
#   放行越活动区落点，下一帧 tick 的 _clamp_to_playfield（活动区 y≥size.y*0.6=768）
#   再拉回——向上瞬步从 y=800 实测 800→540→768（承诺 260px 实兑 32px + 一帧回弹）。
#   R246 后落点与移动同口径活动区钳制：向上瞬步停活动区上界、施放后与下一帧
#   y 差 <1px（零回弹）；向下/横向不受影响。
# 纪律：-s 入口零工程类名直引（全鸭子），用例体运行时加载；无 test_ 前缀不入电池。
extends SceneTree

const CASES_PATH := "res://tests/probe_r246_ranger_blink_body.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	await process_frame
	var body: GDScript = load(CASES_PATH)
	if body == null or not body.can_instantiate():
		print("PROBE FAIL | 用例体加载失败：%s" % CASES_PATH)
		quit(1)
		return
	var cases: Object = body.new()
	await cases.run(self)
	var fails: int = int(cases.call(&"fail_count"))
	if fails > 0:
		print("PROBE 汇总：%d 项硬门未过" % fails)
		quit(1)
	else:
		print("PROBE 汇总：硬门全过")
		quit(0)
