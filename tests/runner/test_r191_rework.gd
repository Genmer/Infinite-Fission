# tests/runner/test_r191_rework.gd
# R191 整案（七项定案）验收自测入口（godot --headless --path <工程> -s tests/runner/test_r191_rework.gd）
# 真源：docs/design/R191_CODEX_REACTION.md（§4 分项定案 + §7 回归与验收总表）。
# 覆盖全部非 noop 七项：tips 构筑可读性 / muzzle 镜面枪口锚点 / mirror_laser 棱镜束五缺陷 /
# rxn 元素反应通道（含「火+电挂载→附着→过载触发」端到端）/ codex_rxn 图鉴反应页 /
# achv 成就扩展与三修 / boomerang 回旋刃尺寸。用例体在 r191_rework_cases.gd。
# 结构说明（同 test_rxn_channel 等套件）：-s 脚本模式下入口脚本编译早于 autoload
# 全局名注册，入口只做引导；用例体经运行时 load 编译——此时 autoload 已就绪。
extends SceneTree

const CASES_PATH := "res://tests/runner/r191_rework_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R191 整案验收 ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		# 防挂死守卫：用例体编译失败必须确定性退出（headless 套件纪律）
		print("FAIL | 用例体编译失败：%s（见上方 SCRIPT ERROR）" % CASES_PATH)
		print("验收汇总：0/1 通过")
		quit(1)
		return
	var cases = cases_script.new()
	cases.run(self)
	if cases.fail_count() > 0:
		quit(1)
	else:
		quit(0)
