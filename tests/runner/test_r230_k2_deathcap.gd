# tests/runner/test_r230_k2_deathcap.gd
# R230 K2c「DeathPop/演出件并发帽」自测入口（godot --headless --path <工程> -s tests/runner/test_r230_k2_deathcap.gd）
# 真源：R230 夹具谱——F1 敌桶本体 134dc（52.8%）被 DeathPop/PoisonSplash 自绘件穿插
# 打断合批（F1 单独可见仅 ~63dc，P2−P1=−52~−92）；本刀=并发活口帽（阀门刀）：
# 三重门（mobile ∧ 帧率优先 ∧ tier≤2）∧ 满载敌数滞回门，门内活口 ≤ DEATHPOP_FX_CAP、
# 超帽最老抢占；Boss 全保留 / 精英 1/2 / 普通按帽；帽N 秒差分诊断键（debug_stats）。
extends SceneTree

const CASES_PATH := "res://tests/runner/r230_k2_deathcap_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R230 K2c DeathPop 并发帽自测 ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		print("FAIL | 用例体加载失败（cases=%s）" % str(cases_script))
		print("验收汇总：0/1 通过")
		quit(1)
		return
	var cases = cases_script.new()
	await cases.run(self)                      # r229 入口同款：await 到用例收尾再读 fail_count
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)
