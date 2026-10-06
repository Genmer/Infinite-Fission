# tests/probe_r234_quickwins.gd（R234 快项挖掘 只读探针入口）
# 跑法：cd E:/Code/Agent/Infinite-Fission && tools/Godot_v4.3-stable_win64_console.exe \
#         --headless --path E:/Code/Agent/Infinite-Fission/repo -s tests/probe_r234_quickwins.gd
# 目的（R234 探索：快项取证三臂）：
#   A/B/C 引擎驱动臂（await physics_frame——r224 同步循环不步物理服务器，Area2D 监测
#   成本在现有基准中不可见；本探针改引擎自然步进，用 Performance.TIME_PHYSICS_PROCESS
#   读每物理步引擎耗时（含物理服务器 step + 节点 _physics_process 回调））：
#   A  基线：现状（121 个 Area2D 全默认 layer=1/mask=1 互相监测——全仓零 collision 配置）
#   B  敌 mask 收窄：敌 _hit_area.collision_mask=2 + 玩家 collision_layer=3（敌间 pair 全消，
#      敌-玩家 pair 保留——最小刀等价性：_on_contact_area 只认 Player，mask 只动 pair 集不动信号过滤）
#   C  监测全关：敌 _hit_area.monitoring=false + 玩家 monitoring=false（成本上限锚）
#   A2 复验：恢复全默认再跑（漂移对照——A2≈A 则臂间差非场景漂移）
#   D  同步臂：手动 _gl._physics_process（r224 同口径——物理服务器不步进）=纯 GDScript
#      帧序基线；A−D≈引擎物理步+Area2D 监测每步成本。
#   采样（A/D 臂内每 12 帧）：弹-敌空域分布（query_circle_snap 半径 8/64/200 三档空占比
#   ——弹群批筛收益上限依据）+ 派发队列长度（pipeline._resolved_queue.size()——顺延
#   前移成本依据）。
#   微基准：GDScript 数组前移（dispatch_resolved_frame :326-328 顺延主语句）L=700/2000/4000。
# 纪律：-s 入口零工程类名直引；只读不改游戏代码；无 test_ 前缀不入电池；JSON 留档 docs/qa。
extends SceneTree

const CASES_PATH := "res://tests/probe_r234_quickwins_cases.gd"


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
	print("PROBE 汇总：探针完成（读数与 JSON 见 docs/qa/probe_r234_quickwins_2026-10-06.json）")
	quit(0)
