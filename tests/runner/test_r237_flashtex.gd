# tests/runner/test_r237_flashtex.gd
# R237 闪白换桶刀（满载档受击闪白改白变体贴图换桶 FLASH_TEX）回归入口。
# 契约：FLASH_TEX=true（默认）=满载闪白走 TextureFactory.enemy_tex_flash 白变体
# （强闪全白剪影/弱闪半白混合——R217 两档强度语义保留）+ modulate 复位 WHITE +
# 材质摘除 + _place_in_bucket() 换桶（R214 E' 变脸换桶同款，至多 2 闪白桶=至多 2 批
# bounded）；闪毕/门回落/池归还三路复位本体贴图回原桶（零状态残留）。
# FLASH_TEX=false=满载白乘现状单点回退（R216 碎片烤色先例）；轻载（非满载）
# ShaderMaterial 路径零改动。
# 视觉口径披露：满载档受击闪白 = modulate 过曝白乘 → 白剪影/半白贴图（经典
# hit-flash 观感，亮度读感略变）；轻载观感零变化。用户可否决：FLASH_TEX=false 回退。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load。
extends SceneTree

const CASES_PATH := "res://tests/runner/r237_flashtex_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R237（满载闪白贴图换桶刀 FLASH_TEX） 回归 ══════════")
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
