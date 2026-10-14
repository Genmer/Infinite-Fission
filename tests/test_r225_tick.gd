# tests/test_r225_tick.gd
# R225 弹tick侧刀回归入口（godot --headless --path <工程> -s 本文件）
# 契约：ON_TICK 派发 armed 快照闸（R225——tick 期 payload 字典死分配掐除）
# ① armed 路径：栈声明 ON_TICK 挂钩 → tick 逐帧派发照常（game_delta 透传）；
# ② unarmed 路径：无 ON_TICK 挂钩栈 → ON_TICK 零派发（R210 has_event_hook 闸契约）；
# ③ 非 ON_TICK 事件零扰动：ON_SPAWN/ON_HIT/ON_EXPIRE 派发计数精确不受刀影响；
# ④ 池复用 armed 快照重算（spawn 期重算——池复用不串弹）；
# ⑤ 回旋刃接触内冷清扫语义等价（0.4s 内冷节拍不变）；
# ⑥ 回收原因计数键同名等价（recycle_reason_N 键 DebugStats 口径不变）；
# ⑦ 无词条弹运动/回收基线（armed=false 零扰动）；
# ⑧ 直挂数组通道 live 判定（spawn 后注入照常触发——simchain ③a 契约保旧路径）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load
# （两文件铁律——入口+cases，test_r225_separation 同构）。注意：本套件位于 tests/
# 非 tests/runner/——_batt_r215.py 只纳 tests/runner/test_*.gd，本套件手动直跑。
extends SceneTree

const CASES_PATH := "res://tests/test_r225_tick_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R225（弹tick侧刀 ON_TICK armed 闸） 回归 ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		print("FAIL | 用例体加载失败（cases=%s）" % str(cases_script))
		print("验收汇总：0/1 通过")
		quit(1)
		return
	var cases = cases_script.new()
	await cases.run(self)
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)
