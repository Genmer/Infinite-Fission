# tests/qa_r225_mech.gd
# R225 把关注（测试甲·机制正确性镜头）探针入口（godot --headless --path <工程> -s 本文件）。
# 镜头五面 → 本套件锁的互补面（既有 R225 套件已锁面不重复）：
#   ① -4 全弃哨兵 × 反应通道共存：resolve_reaction 无 -4 闸——反应结算在 -4 下真付
#      （计数实证，把探针 TICK 臂 G3「零结算」的反应盲区从机制推断升级为计数证据；
#      本构成 W2 无元素卡→两臂结构性零反应，现行读数不受污染——口径披露非现行错账）；
#   ② -4 哨兵 × R223 预算切换边：override ≥0→-4 切换时残留 _pending_fifo 会被
#      begin_frame 全量真冲刷（-4 只拦 resolve 层新提交不拦既有积压）——探针 -2 冲刷
#      帧前置步为承重件（probe_r225_separation_cases.gd:230-232），缺它则 G3 假绿；
#   ③ 跳字位图门翻转双向行为：Label→bitmap（产品可达：boot 预热未完→图集就绪）
#      位图臂接管正确=硬门；bitmap→Label（当前仅 bitmap_override 测试覆写口可达）
#      非反应 Label 分支缺对称退位（Label 不复显 + 位图 sprite 残显旧值）=披露锚；
#   ④ 位图大数/零值字形序列 + R212 refresh_label_calls 观测口位图臂照走；
#   ⑤ 碎片单帽 _fullload_absorb_open 无复位点源级锚（:1410 兜底开帽死分支披露——
#      当前 ⑦ 全部调用点均有前置开帽，无行为影响）。
# 纪律：-s 入口零工程类名直引；用例体运行时 load（两文件铁律，test_r225_separation 同构）。
# 产品码只读——本套件只做行为/源级锚取证，不改任何产品文件。
extends SceneTree

const CASES_PATH := "res://tests/qa_r225_mech_cases.gd"


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ Infinite Fission · R225 把关注（机制正确性）探针 ══════════")
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
