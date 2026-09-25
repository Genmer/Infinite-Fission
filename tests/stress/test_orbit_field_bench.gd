# tests/stress/test_orbit_field_bench.gd
# R188 档0 新增锚：OrbitField 微基准入口（两段式——入口只做引导，用例体运行时 load 编译）。
# 覆盖（验收口径）：真 OrbitWeapon+真管线+100 敌满载驱动 1200 帧——
#   ① _gain_cd 键数有界（≤活跃目标数×2——零值即擦治理后不随敌流累积）；
#   ② tick 均耗上限（打印实测，供同机 A/B 对账）；
#   ③ 蓄能/引爆真链可达（w8_detonations ≥1）；
#   ④ DeathPop 表现件池有界复用（news ≤ 池上限）。
extends SceneTree

const CASES_PATH := "res://tests/stress/orbit_field_bench_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R188 OrbitField 微基准（W8+100敌×1200帧） ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	var cases = cases_script.new()
	await cases.run(self)
	quit(1 if cases.fail_count() > 0 else 0)
