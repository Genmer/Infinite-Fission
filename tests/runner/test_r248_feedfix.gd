# tests/runner/test_r248_feedfix.gd
# R248 反馈吞没与卡面品质收口专项套件入口（簇1：c4①②③④ + c8①②③④）：
# · c4① graze 掠过反馈：无敌窗直调 take_contact_damage → graze_hits 恰 +1、
#   0.25s 节流内第二发不计、节流衰减后恢复计数（表现侧 graze_fx 同步计数）；
# · c4② 敌弹保留配额：默认路径逐位（饱和 acquire() → null+misses）/ acquire(1)
#   挤掉最老玩家弹成功 / 无玩家弹可挤仍 null+misses+enemy_bullet_dropped；
# · c4③ 非 CHASE 精英词缀复活：RANGED 精英 tick 推进 affix_ring 释放；
# · c4④ BossMine 宿主失效：已 arm 原地引爆（HazardPool 落地+_done 防重入）、
#   未 arm 静默清；
# · c8① 五死数字卡特例臂：五卡蓝/金两档卡面数字=运行值；
# · c8②+③ 二元卡尾注抑制 + PHASE_SYNC 卡面去「×2」；c8④ ELE lv2 白名单泛化。
# 契约：headless、退出码判据（0 过 / 1 挂）；「共 N 项」总数断言与用例数一致
#（R231 假绿教训）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load。
extends SceneTree

const CASES_PATH := "res://tests/runner/r248_feedfix_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R248（反馈吞没与卡面品质收口） 专项套件 ══════════")
	# 等引擎注册的 autoload 完成 add_child + _ready（EventBus→GameConfig→DebugStats）
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
