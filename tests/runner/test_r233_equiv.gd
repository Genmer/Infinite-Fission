# tests/runner/test_r233_equiv.gd
# R233 T7 等价性总套件入口（godot --headless --path <工程> -s 本文件）。
# 契约（分析 §五 1-6 项 + AC-3 电池门的产品侧部分）：R233 全部改动（T2 谓词/T3 档位/
# T4 半频短路/T5 swept/T6 插值层）就位下的整机面等价——
# · 整机双跑全等（承重）：-2 强制关 vs -1 默认态（headless 真值门本就=关），同种子
#   同构筑真链驱动，AC-E4 指纹（命中 uid 序/伤害值谱/回收原因计数/结算轴/RNG 消费序）
#   容差 0 + 关态零执行抽查（源级+运行时）；
# · 30Hz 注入态（-3）整机冒烟：真链 _physics_process(1/30) 全链跑通、档位取 30Hz 值、
#   半频相位每 tick 直驱、swept 真链生效、插值恢复/快照执行、_process headless 直返
#   分支 + 直调内部函数口径写插值位；
# · 切换态横跳：同一局中途 -3↔-2（模拟用户回退场景）——选择器即时生效、无撕裂/
#   无重复结算/无回收错因、prev/curr 缓冲不脏；
# · RNG 消费序：idle 同 dt 双态消费序逐位一致（等价刀不碰掷骰）+ 战斗场景命中集超集
#   口径（swept 增命中→掷骰连锁可增=设计内，如实注明）。
# AC-3 电池门本身由 `python _batt_r215.py` 终跑承担（本套件为电池 glob 成员之一）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load。
extends SceneTree

const CASES_PATH := "res://tests/runner/r233_equiv_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R233 T7（等价性总套件：双跑全等/30Hz 冒烟/切换横跳/RNG 序） ══════════")
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
