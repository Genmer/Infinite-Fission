# tests/runner/test_r240_bodymm.gd
# R240 敌本体 MultiMesh 镜像刀（渲染轴 F1 敌域第二刀）回归入口。
# 契约：BODY_MM=true（默认）=符合条件敌（非 boss/elite/bastion 且 FLASH_TEX 可用）
# 本体绘制改 TexBucketHost 按贴图 MultiMesh 镜像（每贴图恒 1 draw；实例色承载
# 染色/渐显——组色差异不再断批）；_sprite 恒隐作 transform/色读源；镜像敌闪白
# 无论满载与否恒走白变体贴图路径（实例色 8-bit 钳位承不住 >1 白乘——轻载 shader
# 混合仅保留给排除分型）。BODY_MM=false 单点回退=逐敌 Sprite 现状零扰动。
# 视觉口径披露：桶内本体层恒在瞬态指示件（施法扇/爆环）之下；轻载闪白改白变体
# 贴图（=现满载观感）。用户否决口：BODY_MM=false 回退。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load。
extends SceneTree

const CASES_PATH := "res://tests/runner/r240_bodymm_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R240（敌本体 MultiMesh 镜像 BODY_MM） 回归 ══════════")
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
