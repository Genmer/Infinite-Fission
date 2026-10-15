# tests/qa_r285_qa_gridqa.gd
# R285 QA 独立探针套件入口（qa-r285 独立测试轮——不与实施员套件 qa_r285_gridhit 重面）：
# 覆盖实施员 51 断言未及的面（独立测试工程师职责面）：
# · qA 同帧多弹单敌：致死短路一次性（E-06）与非致死独立结算两态对拍（E-03 帧聚合面）；
# · qB 反弹弹命中：反弹预算不受命中侵蚀（R15）+ 元素附着同帧面两态对拍；
# · qJ sim30 swept 收集：30Hz 弦判定口径两态对拍（设计 §5.1 命中判定行 60Hz 之外的补面）；
# · qC 时序边界：关态帧头清残对缓冲（防跨帧幻影提交）/ 门翻转残队复合时序（含 R66
#   尸体看门狗交互）/ 帧级缓存翻帧生效 / grid·death 两门独立裁定；
# · qD 池交互：队中敌先归池（in-pool meta 守卫）/ 对缓冲节点 free（is_instance_valid 守卫）/
#   deaths_flushed 计数语义；
# · qE 燃烧 DOT 杀：⑤ 尾冲刷点同帧闭合（DOT/反应杀不跨帧）两态对拍；
# · qF 盘档卫生：套件全程 meta_save_test.cfg 字节逐位不变（红线 5「模式关不写盘档」独立复验）；
# · qH 注入口出厂态终检。
# 纪律：-s 入口编译期先于 autoload 注册——零工程类名直引；用例体运行时 load（qa_r285_gridhit
# 同构）。盘档纪律：Meta._settings 入口快照 + 收尾整字典还原 + Meta._save() 落盘；本套件
# 零落盘文件写点。池件勿 add_child/勿二次 release，判存活 is_instance_valid。
extends SceneTree

const CASES_PATH := "res://tests/qa_r285_qa_gridqa_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R285 QA 独立探针（同帧多弹/反弹/时序边界/池交互/DOT/盘档卫生） ══════════")
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
