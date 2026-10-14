# tests/runner/test_w4_prism.gd
# W4 激光组（主束常驻化 + 棱镜副束）自测入口（SceneTree 脚本：
# godot --headless --path <工程> -s tests/runner/test_w4_prism.gd）
# 覆盖（W4 五方向定案验收 1~5 + R183 折减）：
#   A  真实 .tres 数据锚：base_atk 6/7/7/9/11（A3 tick_atk 锚兑现）、跳频=L 表 rof、
#      pulse_duration/tick_rate 死键删除、sub_ratio_levels、阈值 TH_PRISM_CHOIR/CRIT_SHARD 0.35
#   1  默认单束：seed(42)+静止敌夹具，try_fire 后 laser 段计数==1、锁定最近敌、lifetime==0
#   2  叠束硬帽：3× MEC_SPLIT_PRISM→段数==4；副束 dmg_mult==主×0.6（L5 ×0.75）±1e-6；
#      目标两两互斥；第 4 张被拒且 DebugStats+1
#   3  聚焦归属：主束 6.7s focus_mult==2.0±0.05、副束恒 1.0；PHASE_SYNC 下 3.35s 满；
#      AFF_CDR×4 换目标保留 50%±2%（计帧断言）
#   4  灼焦单池：两束共照同目标 2s 层数曲线==单束对照（≤8）；重叠回退×0.5 且不叠灼焦
#   5  预算与数值：双激光满配全场段峰值≤12（池帽 12）、结算≤束数×30/s；L5 单体满配
#      324.8±5；R183 复制体并发束==1+灰染 flag（含 laser_subbeam_spawned 归属字段断言）
#   +  拓扑三选一（TRACK 缺省互斥 / FAN 固定角反挂机 / COFOCUS 全束钉单体）、
#      BEAM_LAG 跳频加成、TH_PRISM_CHOIR 副束跳频+2、SPECTRA 元素轮转（删 KIN 硬编码）、
#      遗物乘区接线（inject_relic_pools）、池满副束拒绝计数
# 结构同 pkg3：-s 模式下入口脚本编译早于 autoload 全局名注册，入口只做引导；
# 用例体 w4_prism_cases.gd 经运行时 load 编译——此时 autoload 已就绪。
extends SceneTree

const CASES_PATH := "res://tests/runner/w4_prism_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · W4 激光组（主束常驻化+棱镜副束）自测 ══════════")
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
