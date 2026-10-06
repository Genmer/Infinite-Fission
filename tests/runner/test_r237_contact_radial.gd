# tests/runner/test_r237_contact_radial.gd
# R237 清退刀（接触伤害去物理化 CONTACT_RADIAL 双模）回归入口。
# 契约：off（默认）=敌 HitArea 信号通道原语义（R202 ②，blink 白名单不动）；
# on=敌不建 HitArea、tick 内双半径直判（与物理圆重叠同口径=hitbox_r+hitbox_radius，
# 结算闸 take_contact_damage 内 _dead/无敌帧/格挡不变）。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load。
extends SceneTree

const CASES_PATH := "res://tests/runner/r237_contact_radial_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R237（接触伤害去物理化清退刀） 回归 ══════════")
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
