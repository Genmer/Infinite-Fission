# tests/runner/test_pkg10_extra.gd
# v1.0.0 验收补充入口（tester 独立复核 + 补漏；两段式同 pkg0~pkg10：
#   godot --headless --path <工程> -s tests/runner/test_pkg10_extra.gd）
# 补漏定位（pkg10 M1~M24 未覆盖的验收项；A9_v1.0.0_design.md）：
#   E1 set_save_path 复位语义 + 不自动加载（M1 验收；M10 仅消费未断言）
#   E2 再次出击再死再结转：二局累积 + 本局增量回写（M2 验收；M11 只死一次）
#   E3 gold=0 正常路径结转 →「结晶 +0」+ runs 计入（M2 验收；M24 仅 meta_store 降级路径）
#   E4 greed 负增量不缩放（M4 验收；M16 只测正增量 ×1.1）
#   E5 MetaPanel 满级/余额不足 disabled + 已满级文案（M5 验收）
#   E6 结算屏结晶行与双按钮无交集（M5 验收；M22 只测 MetaPanel 侧）
#   E7 存档键布局契约逐节 diff（补漏职责④：[meta] 恰2/[levels] 恰5/[stats] 恰3）
#   E8 定价独立复算：逐级迭代重算对照 + pow 一次算 655≠656 钉死 + seed_gold Lv0=100
#   E9 max_hp 公式真源手算：(100+0+10+10)×(1-0)=120（static compute_max_hp 直接对照）
extends SceneTree

const CASES_PATH := "res://tests/runner/pkg10_extra_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · v1.0.0 验收补充（tester 独立复核+补漏） ══════════")
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
