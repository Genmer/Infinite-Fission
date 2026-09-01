# tests/runner/test_pkg13.gd
# v1.3.0 自测入口（元素收尾与打磨：共鸣/水晶/跳过补偿/类型守卫；
# 两段式同 pkg0~pkg12：godot --headless --path <工程> -s tests/runner/test_pkg13.gd）
# 覆盖冻结方案 pkg13 用例组 V57~V78（A12_v1.3.0_design.md §7；每恰 1 断言）：
#   V57 扫描器 / V58 后缀 / V59 附着共鸣 / V60 阈值分立 / V61 反应臂 / V62 破碎共鸣
#   V63 增幅共鸣 / V64 rebuild 收口 / V65 恒等锚 / V66 HUD / V67 roll 序列
#   V68 生成顶替 / V69 消散三出口 / V70 弹-晶碰撞 / V71~V74 五分支 FIR·ICE·WAT·LTG·KIN
#   V75 跳过补偿 / V76 跳过面 / V77 生产重算 / V78 收尾+管线 veto
extends SceneTree

const CASES_PATH := "res://tests/runner/pkg13_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · v1.3.0 元素收尾自测（pkg13 V57~V78） ══════════")
	# 等引擎注册的 autoload 完成 add_child + _ready（EventBus→GameConfig→DebugStats）
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	var cases = cases_script.new()
	cases.run(self)
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)
