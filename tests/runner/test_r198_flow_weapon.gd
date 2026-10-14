# tests/runner/test_r198_flow_weapon.gd
# R198 组2 战斗流程·新套件入口（SceneTree 脚本：godot --headless --path <工程>
#   -s tests/runner/test_r198_flow_weapon.gd）
# 覆盖（骨架照 test_r197_build_panel.gd 既有模式；用例体经运行时 load 编译——
#   -s 模式下入口脚本编译早于 autoload 全局名注册，此时用例体编译 autoload 已就绪）：
#   F1  二aw-1 遗物随继续局恢复（serialize 补 relics 键 / continue 恢复 owned+常驻位 /
#       旧档无键兼容）
#   F2  二aw-2 每击谐振慢速武器间隔折算补偿（0.5s→0.1s / 0.1s→0.02s / 5s 触顶 ×10 /
#       快速下限 1.0 / 守卫链不变 / 每秒收益解耦）
#   F3  R192-low4 r_rxn/R_alarm 告警闸每局复位（reset 前仅首局广播 → reset → 再广播；
#       R_rxn 双闸同口径）
#   F4  r194-1 空波计数单源化（回退分支 wave_composition_registry_empty 独立计数 /
#       wave_empty_composition 守卫侧恰 +1）
#   F5  P2-escort 护航舰改吃副本 game_delta（player.tick 驱动寿命/开火节拍/浮动相位 /
#       引擎自驱退出 / 到期回收）
#   F6  r195-1 激光副束/折射束序数加成归零（副束首目标 ctx.pierce_index==1 /
#       SYN_PIERCE_EVO 副束贡献==0 / 主束序数原样）
extends SceneTree

const CASES_PATH := "res://tests/runner/r198_flow_weapon_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R198 战斗流程验证 ══════════")
	# 等引擎注册的 autoload 完成 add_child + _ready（EventBus→GameConfig→DebugStats→Meta）
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		# 用例体编译失败（load 已打印解析错误）——立即失败退出（防 -s 套件悬挂电池；
		# 解析错 load 返回非 null 但不可实例化的 GDScript，须 can_instantiate 复查）
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
