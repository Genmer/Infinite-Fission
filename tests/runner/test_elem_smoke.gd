# tests/runner/test_elem_smoke.gd
# R192 元素扩容冒烟入口（SceneTree 脚本：godot --headless --path <工程> -s tests/runner/test_elem_smoke.gd）
# 覆盖（docs/design/R192_ELEMENT_MATRIX.md §13.1「新增」行）：
#   Element 枚举 size==8 / 序数 0..7（KIN=0 槽恒 0 弃用 · 追加不重排）/ 免疫位 16/32/64/128；
#   ReactionType 演进口径（现役 0/1/2 字面序锁 + size==reaction_table 行数）；
#   λ 四源（.tres 与 .gd 默认逐位一致 + size==7 + validator 3 项 λ 输入告警回退）；
#   附着段（HYD 累积 / 满槽钳制不清零 / FIR 满槽旧语义不变 / HYD+LTG has_both /
#   elem_immune=16 拒附着 / λ 新槽衰减）；「仅带旧 3 键 reaction_table 的 .tres 加载→
#   仅告警不拒启」；validator 键集探针（进程内删表键→报告含缺口项）；
#   card_generator reaction_mult 泛化探针（2.2 假卡金品质→×5.7 且 VOID 仍 ×4.7）。
# 结构说明（同 pkg0~pkg5 / test_rxn_codex）：-s 脚本模式下入口脚本编译早于 autoload
# 全局名注册，入口只做引导；用例体经运行时 load 编译——此时 autoload 已就绪。
extends SceneTree

const CASES_PATH := "res://tests/runner/elem_smoke_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R192 元素扩容冒烟 ══════════")
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
