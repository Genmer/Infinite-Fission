# tests/runner/test_rxn_channel.gd
# 元素通道自测入口（SceneTree 脚本：godot --headless --path <工程> -s tests/runner/test_rxn_channel.gd）
# 覆盖（2026-09 R191 用户反馈「选了火和电没反应 / 只有超导生效 / 普通难度没开？」）：
#   同武器双 ELE 卡通道守卫（ON_SPAWN 不覆写每发随机元素 / ON_HIT 按当发宿主元素放行）、
#   真件 ElementalSystem 双槽成对 → RXN_FIR_LTG 过载触发（E-03 帧闸 + reaction CD 2s）、
#   单元素通道逐字节回归、双元素实弹交替采样、近战死卡上架门（required_forms 四向）、
#   registry 数据断言与解锁节奏口径（火冰第 2 关 / 感电第 3 关；反应无难度门）。
# 结构说明（同 pkg0~pkg5）：-s 脚本模式下入口脚本编译早于 autoload 全局名注册，
# 入口只做引导；用例体经运行时 load 编译——此时 autoload 已就绪。
extends SceneTree

const CASES_PATH := "res://tests/runner/rxn_channel_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · 元素通道自测 ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null:
		# 防挂死守卫：用例体编译失败必须确定性退出（headless 套件纪律）
		print("FAIL | 用例体编译失败：%s（见上方 SCRIPT ERROR）" % CASES_PATH)
		quit(1)
		return
	var cases = cases_script.new()
	cases.run(self)
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)
