# tests/probe_r232_drift.gd
# 诊断探针（不入电池 glob——probe_ 前缀）：r232 腿2 末帧活弹数漂移界定。
# 结构 A：off/off/on 三臂（复现原始观察）；结构 B 在 LSPMODE 环境变量切换 off×4。
extends SceneTree

const CASES := "res://tests/runner/r232_resolve_equiv_cases.gd"

func _initialize() -> void:
	_run()

func _run() -> void:
	await process_frame
	await process_frame
	var cs: GDScript = load(CASES)
	var c = cs.new()
	c.tree = self
	var mode_b: bool = OS.get_environment("PROBE_MODE") == "alloff"
	var lives: Array = []
	var kills: Array = []
	var hits: Array = []
	var n: int = 4 if mode_b else 3
	for k in range(n):
		var on: bool = (not mode_b) and k == 2
		DamagePipeline.CTX_REUSE = on
		TraitStack.TRAIT_PRECACHE = on
		ModifierStack.AGG_TYPED = on
		await c._release_loop_and_reboot()
		seed(20261004)
		var r: Dictionary = await c._drive_arm(-2)
		lives.append(int(r["live_tail"]))
		kills.append(int(r["kills"]))
		hits.append(int(r["vals"].size()))
	c._cleanup()
	print("DRIFT | mode=%s lives=%s kills=%s hits=%s" % [OS.get_environment("PROBE_MODE"), str(lives), str(kills), str(hits)])
	quit(0)
