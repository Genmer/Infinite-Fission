# tests/qa_r228_qa_valvecheck.gd
# QA-R228/R229 独立复核探针（留档勿删）：三刀落地后 QA 侧独立验证——
#   A. 粒子满载门（刀1，isValve=true）：哨兵四档映射 / 三重门逐项 / 16 长窗采样相位
#      （非套件 8 窗口径）/ elif 独立计数器语义 / 强制开门不外溢非 CRIT /
#      桌面零扰动（无注入真 EventBus 派发 8/8/8/1）。
#   B. 弹池静载阀门（刀3，isValve=true）：trim_free_to 单元级 live-clamp 边界
#      （live>target 分支——新套件未覆盖面）+ _pool_valve_on 直读映射 +
#      新鲜 GameLoop 门序逐项 + 桌面零扰动 + 触发读数 820→448/裁372。
#   C. 特效层 alpha 量化（刀2，isValve=false，非阀门无门面）：_qa 契约直读 +
#      反应环族 6 件同相位四分档 ∧ distinct≤2（合批前提抽查）。
# 用法（会话根）：
#   ./tools/Godot_v4.3-stable_win64_console.exe --headless --path repo \
#     -s tests/qa_r228_qa_valvecheck.gd
# 纪律：-s 入口编译期零工程类名直引；用例体运行时 load（tests 双文件惯例）。
extends SceneTree

const CASES_PATH := "res://tests/qa_r228_qa_valvecheck_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ QA 探针：R228 三刀独立复核（阀门门序/哨兵/桌面零扰动 + 量化抽查） ══════════")
	await process_frame
	await process_frame
	var cases_script: GDScript = load(CASES_PATH)
	if cases_script == null or not cases_script.can_instantiate():
		print("FAIL | 用例体加载失败")
		quit(1)
		return
	var cases = cases_script.new()
	await cases.run(self)
	if cases.fail_count() > 0:
		quit(1)
	else:
		quit(0)
