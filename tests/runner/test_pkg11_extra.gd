# tests/runner/test_pkg11_extra.gd
# v1.1.0 验收补漏 runner（tester 独立验收视角；pkg11 V25~V40 已覆盖项不重复）。
# 两段式同 pkg0~pkg11：
#   godot --headless --path <工程> -s tests/runner/test_pkg11_extra.gd
# 覆盖（tester 补漏 XE1~XE7；每恰 1 断言）：
#   XE1 ★重开残留（E-AMP-1 跨局面）/ XE2 免疫目标增幅照常 / XE3 精通 1 层 φ=1.25
#   XE4 融化×精通 L3 端到端手算（1.5×1.75）/ XE5 碎裂 2s 触发节奏 / XE6 过载 3s 触发节奏
#   XE7 CD 三方同值（schema 默认 vs .tres vs runtime 文件级对照）
extends SceneTree

const CASES_PATH := "res://tests/runner/pkg11_extra_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · v1.1.0 验收补漏自测（pkg11_extra XE1~XE7） ══════════")
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
