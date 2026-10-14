# tests/runner/test_r246_skills.gd
# R246「技能升华」skills 泳道验收自测入口（SceneTree 脚本：godot --headless --path <工程>
#   -s tests/runner/test_r246_skills.gd）
# 覆盖（真源 docs/design/sublime/*.md 十角色 + 总监三新角色 medic/vortex/reaper）：
#   G0  公共：enable_sublime 幂等 / set_character 清位 / _reset_skill_temp_state 收口 /
#       普通版逐位回归（10 角色两态断言之「关」态）
#   G1  sentinel 绝对屏障：5s 力场 / 相位反冲 / 吸收回充（节流·帽·归零·强限定）
#   G2  veles 临界过载：5s 爬坡 2.0→3.2 / 余热软着陆 / 渐冷
#   G3  bulwark 余震壁垒：主震参化 / 余震时序 / 磐岩护壁（转化·吸收·净伤）
#   G4  ranger 百影穿袭：340/460 位移钳制 / 路径结算 uid 去重 / 残影爆拂弹 / 潜影
#   G5  zero 时滞奇点：3.5s 直写绕免疫 / 持续力场覆盖新敌 / 击杀延展帽 / 唯我演算
#   G6  mank 万毒噬界：210% 基线 / 喂层分档帽 / 腐沼爆裂（去重·深度 1·合成 UID）
#   G7  vera 毒理学终章：7s 窗 / 半径滋生 / 毒蚀层乘区 / 催化错帧
#   G8  noah 万械共鸣：3 副本 3 舰 16s / 舰体寿命绑定 / 共鸣层即时乘区 / 恋战延时
#   G9  echo 无尽回响：双生和弦分流 / 回声层 / 渐弱余韵
#   G10 fission 本命同调：契约不破 / 原始计数回填 / 层数注入 / Ω 五档 extern / CDR 参数化
#   G11 medic 医疗矩阵：回复 + 减伤窗 ×0.5
#   G12 vortex 奇点：向心牵引 + 末爆
#   G13 reaper 收割窗：extern atk 乘区启停
# 结构说明（同 test_r245 套件）：-s 脚本模式下入口脚本编译早于 autoload 全局名注册，
# 入口只做引导；用例体经运行时 load 编译——此时 autoload 已就绪。
# 夹具：真 GameLoop（main.tscn）+ 敌池夹具敌（mirror_muzzle 同式；勿 add_child 池化节点）。
extends SceneTree

const CASES_PATH := "res://tests/runner/r246_skills_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R246 技能升华（skills 泳道）验收 ══════════")
	# 等引擎注册的 autoload 完成 add_child + _ready（EventBus→GameConfig→DebugStats→Meta）
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		# 用例体编译失败（load 已打印解析错误）——立即失败退出（防 -s 套件悬挂电池）
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
