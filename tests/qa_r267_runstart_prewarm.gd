# tests/qa_r267_runstart_prewarm.gd — R267 刀P1 runstart 预热总刀验收入口
# 验收面（设计 §1.1，含两处已声明偏差）：
#   a) 模态暖通道（祝福模态开帧 layout+全量 cell）→ start_run 全链 ≤8ms 且
#      bitmap_bake_us 零增量（ensure 恒短路）——对照改前冷直发 32.3ms（冷位图探针
#      本轮复测）/41.6ms（vc71 真机遗案）；
#      【偏差①】设计处方 6「4 入口分档改口径」未从——qa_r227_bake_a:83/
#      bake_b:121/probe_coldstart:49 锁死 override=1 冷图集入口同步全量补烤，
#      兜底档=原全量口径（由 bake_a ② + coldstart 探针既有套件盯守，本套件不重复）；
#   b) 模态暖幂等（ready 后零成本）+ 桌面自动门零扰动（缺省 override 下暖口直返）；
#   c) 队列波序重排：非 op:0 项槽位/内容恒等 + op:0 多重集不变 + 波键非降序 +
#      op:6 队首块不破（qa_r227_bake_b ① 口径）；
#   d) 快开局敌变体：wave1 廉价 kind PLAYING 泵首帧消化 + TextureFactory._cache
#      只读命中（首敌接敌前零首焙面）；
#   e) boss 错峰：波次门槛前跳过不 break（队首 boss 不停摆）+ 门槛放行恰 1 原子项/
#      帧 + 占空还账（_tex_prewarm_skip ≥1）+ tex_prewarm_atom_overruns 落账；
#   f) PLAYING 泵帧峰值：常规帧 ≤4ms 预算口径（冷廉价项起步越尾余量 +3ms）/
#      原子帧 ≤245ms / 300ms 硬帽。
# 纪律：-s 入口零工程类直引，逻辑全在 cases 体运行时加载；boot 零 await（bake_b
# 先例——队列满态/图集冷态保真）。
extends SceneTree

const CASES_PATH := "res://tests/qa_r267_runstart_prewarm_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	await process_frame
	var body: GDScript = load(CASES_PATH)
	if body == null or not body.can_instantiate():
		print("PROBE FAIL | 用例体加载失败：%s" % CASES_PATH)
		quit(1)
		return
	var cases: Object = body.new()
	await cases.run(self)
	var fails: int = int(cases.call("fail_count"))
	quit(1 if fails > 0 else 0)
