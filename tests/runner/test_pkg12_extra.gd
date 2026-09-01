# tests/runner/test_pkg12_extra.gd
# v1.2.0 验收补漏 runner（tester 独立验收视角；pkg12 V41~V56 已覆盖项不重复）。
# 两段式同 pkg0~pkg12：
#   godot --headless --path <工程> -s tests/runner/test_pkg12_extra.gd
# 覆盖（tester 补漏 XE1~XE7；每恰 1 断言）：
#   XE1 WAT 衰减 λ 手算锚（50×(1−0.38×0.5)=40.5）+ λ 三处逐值镜像 / XE2 冻结全周期时序
#   XE3 盾克制端到端手算（FIR 100 打 ICE 盾 −200）+ SHIELD_COUNTER 全环 / XE4 敌侧重开残留
#   XE5 系统侧重开残留 + uid_conduct 复用行为 / XE6 ElementRing progress(WAT) 通路
#   XE7 既有 ICE 满槽冻结（1.2s 旧通道）同步升级全停
extends SceneTree

const CASES_PATH := "res://tests/runner/pkg12_extra_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · v1.2.0 验收补漏自测（pkg12_extra XE1~XE6） ══════════")
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
