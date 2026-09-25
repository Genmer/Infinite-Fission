# tests/runner/test_w67_rocket.gd
# W6/W7 双火箭 30% 规格专项自测入口（SceneTree 脚本：godot --headless --path <工程> -s tests/runner/test_w67_rocket.gd）
# 真源：R187 五方向定案「rockets」——30% 规格裁定 = 溅射口径（爆径≈30% + 爆炸伤害≈30%，
# 直击不砍）+ W6 齐射轴（volley_count_levels + MEC_HIVE_RACK 硬顶 5）+ 引信连携
# （MEC_FUSE_COAT 铺设 / MEC_FUSE_DETONATE 引爆）+ TH_SWARM_NOVA 身份线 + R183 复制体折减。
# 验收映射（acceptance 1~5 / 6 项）：
#   ① 比例断言（数据级：blast_r 比 / 溅射比 / W7 现网字段 / 阈值分叉）
#   ② 齐射行为（第 i 近索敌 / ×0.6^j 递减 / HIVE_RACK×2→5 弹 / 池空 false 不崩）
#   ③ 引信（挂引信幂等 / 引信敌爆炸 ×1.4 / DETONATE×2 追加恰一次 + 0.5s 护栏）
#   ④ validator 负例（volley_count / blast_r_levels / blast_atk_ratio / _levels 长度）
#   ⑤ R183 折减 + 预算（volley_eff==1 / sub_eff==min(sub,3) / 满配双火箭+双副本 10s 峰值≤64）
#   ⑥ 爆径<50 震屏 == HIT 档（真实 GameLoop 订阅者探针）
extends SceneTree

const CASES_PATH := "res://tests/runner/w67_rocket_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · W6/W7 双火箭 30% 规格专项自测 ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	var cases = cases_script.new()
	await cases.run(self)
	var fail_count: int = cases.fail_count()
	if fail_count > 0:
		quit(1)
	else:
		quit(0)
