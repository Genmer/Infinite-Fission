# tests/qa_r235_gap_probe.gd
# R235 QA 缺口探针入口（godot --headless --path <工程> -s 本文件）。
# 独立复核主控套件（test_r235_quickwins / test_r231_pfast）之外的边界缺口：
#   ① 4a 预检带与 _check_edge_bounce 判定带口径一致性（采样证明 + 半径生命周期不变式）；
#   ② 角落同帧双轴（x∧y 同时贴边）快/慢孪生逐位等价 + 水平 x 分支补位；
#   ③ 贴边但离面方向帧（velocity.dot(normal)>0）：回落本体零动作=慢路径；
#   ④ 4b 与 30Hz swept 膨胀交互：-3 开/-2 注入/生产关 三态预检半径口径（擦边弹判别）；
#   ⑤ _candidates 成员缓冲跨弹状态：同帧多快弹先后驱动无脏候选串弹；
#   ⑥ bounces 弹池化复用：归还清零/重 spawn 重判（无上代残留——_tmp_qa_r231_boundary e) 先例
#      的跳弹臂扩展）；
#   ⑦ bounces>0 弹 range 豁免语义（traveled≫range 不回收）；
#   ⑧ TH_BANK_SHOT 金染升格走快路径（≥12 反弹 GOLD 变体——反射补 _sync_visual 钩）；
#   ⑨ TH_BOUNCE_ETERNAL 永存走快路径（ON_BOUNCE 派发期写者被快路径消费）；
#   ⑩ 4c 真值臂第三态（-1+ENABLED=true 桌面 OS 门）直返冻结 + 注入翻转保鲜语义。
# 纪律：本文件无 test_ 前缀不入电池（glob 只收 tests/runner/test_*.gd）；-s 入口编译期
# 先于 autoload 注册——零工程类名直引；用例体运行时 load。
extends SceneTree

const CASES_PATH := "res://tests/qa_r235_gap_probe_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R235 QA 缺口探针（带口径/角落孪生/离面帧/双态合并/多弹缓冲/池化复用/金染/永存/关态三态） ══════════")
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
