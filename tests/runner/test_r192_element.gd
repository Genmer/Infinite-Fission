# tests/runner/test_r192_element.gd
# R192 七元素反应大矩阵验收入口（SceneTree 脚本：godot --headless --path <工程> -s tests/runner/test_r192_element.gd）
# 真源：docs/design/R192_ELEMENT_MATRIX.md §3 idContract（唯一真源）+ §15 验收命令。
# 覆盖（六项验收标准，用例体 r192_element_cases.gd）：
#   ① reaction_table 键集合 == idContract §3.3 全表（C(7,2)=21 配对逐键对：20 键逐行 +
#      冰草留白无键；id 低枚举序在前；扩散族转移语义；RXN_ORDER == 优先级 1..20）
#   ② 七元素枚举在位（序数 0..7 追加不重排）+ element_decay_lambda 恰 7 项（三源同值）+
#      PopPalette.ELEMENT_COLORS 每元素色表键在位 + 四张新元素卡 §3.2 字段 + 解锁关
#   ③ 端到端：同武器挂两种新元素卡 → 实弹附着 → 触发对应反应（绽放=非族新反应 +
#      扩散·水=族模板反应 + 扩散·草转移元素行为探针）
#   ④ 图鉴反应行数 == reaction_table 行数（动态断言，禁硬编码）+ 留白标注行恰 1
#   ⑤ 反应跳字文本含中文反应名与数字（蒸发150/蒸发184/超导-30%/结晶·火-15%/冻结1.2s）
#   ⑥ 旧 3 反应行为回归（碎裂 2.0×DOT 池引爆 / 过载 1.2×快照+AoE / 超导 −0.3 全抗 6s）
# 结尾打印「验收汇总：X/Y 通过」；全过 exit 0，否则 exit 1。
# 结构说明（同 pkg0~pkg5 / test_rxn_channel）：-s 脚本模式下入口脚本编译早于 autoload
# 全局名注册，入口只做引导；用例体经运行时 load 编译——此时 autoload 已就绪。
extends SceneTree

const CASES_PATH := "res://tests/runner/r192_element_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R192 七元素反应大矩阵验收 ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null:
		# 防挂死守卫：用例体编译失败必须确定性退出（headless 套件纪律）
		print("FAIL | 用例体编译失败：%s（见上方 SCRIPT ERROR）" % CASES_PATH)
		print("验收汇总：0/1 通过")
		quit(1)
		return
	var cases = cases_script.new()
	cases.run(self)
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)
