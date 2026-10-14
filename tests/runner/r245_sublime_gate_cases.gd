# tests/runner/r245_sublime_gate_cases.gd
# R245「红卡大屏确认门」用例体（入口 test_r245_sublime_gate.gd 运行时 load——
# -s 编译期禁引工程类名纪律）。夹具：GameLoop 完整 Boot（r246_sublime S 组同式）
# + start_run 后全程同步直驱（无 await——挂机窗/物理帧不与用例交错）。
# 红卡夹具：card_generator._make_sublime_card(player) 直构卡 dict（勿靠 0.001% 真掷，
# r246_sublime 定种流纪律同源）；SUBLIME 故意放批内第二位——锁「判据=本批应用列表，
# 勿按槽位/首张判」（设计 §6.4-1）。
extends RefCounted

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _bk: Dictionary = {}


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(245)
	_snapshot_meta()
	var booted: bool = await _boot()
	if not booted:
		_teardown()
		_summary()
		return
	_test_gate_open()          # A + D + 内容
	_test_confirm_close()      # B
	_test_pending_reopen()     # C
	_test_idle_auto_confirm()  # E
	_test_keyboard_confirm()  # E6（评审 low 落地：键盘/手柄确认通道）
	_test_no_gate_passthrough()  # F + 同局不去重
	_test_quit_menu_settle()   # §1.6 quit_to_menu 补结清
	_teardown()
	_summary()


func fail_count() -> int:
	return _fail


func _summary() -> void:
	print("────────────────────────────────────────")
	print("验收汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL | %s" % f)


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> bool:
	if p_cond:
		_pass += 1
		print("  ok | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("  FAIL | %s %s" % [p_name, p_detail])
	return p_cond


# ── 环境 ─────────────────────────────────────────────────────────
func _snapshot_meta() -> void:
	_bk = {
		"character_id": Meta.character_id,
		"crystals": Meta.crystals,
	}
	Meta.character_id = &"sentinel"
	Meta.set_setting("auto_select_on", false)     # 挂机关基线（E 组内显式开）


func _restore_meta() -> void:
	Meta.character_id = StringName(String(_bk["character_id"]))
	Meta.crystals = int(_bk["crystals"])
	Meta.set_setting("auto_select_on", false)     # 收尾还原（磁盘测试档不留挂机态）
	Meta._save()


func _boot() -> bool:
	RunSave.clear()
	_gl = GameLoop.new()
	_gl.name = "R245SublimeGateUnderTest"
	tree.get_root().add_child(_gl)
	await tree.process_frame
	await tree.process_frame
	if not (_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU):
		_check("前置：GameLoop Boot 完成（MENU）", false,
			"boot_ready=%s state=%d" % [str(_gl.boot_ready), _gl.state])
		return false
	if not _check("前置：sublime_confirm_ui 随 boot 组装（confirmed 接 _finish_card_choice）",
			_gl.sublime_confirm_ui != null):
		return false
	_gl.start_run()
	_check("前置：start_run → PLAYING", _gl.state == GameConst.GameStatus.PLAYING,
		"state=%d" % _gl.state)
	return _gl.state == GameConst.GameStatus.PLAYING


func _teardown() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null
	_restore_meta()


# ── 夹具 ─────────────────────────────────────────────────────────
func _open_flow() -> void:
	# 开一轮选卡（PLAYING → LEVEL_UP + 卡窗）——本套所有 _on_card_choice 的前置
	_gl._open_card_flow(_gl.player.level)


func _sublime_card() -> Dictionary:
	return _gl.card_generator._make_sublime_card(_gl.player)


func _choose_sublime_pair() -> void:
	# SUBLIME 放批内第二位（首位空 dict 不应用）——锁「勿按槽位/首张判」
	_gl._on_card_choice([{}, _sublime_card()])


# ── A 组：门弹出（state 保持 LEVEL_UP + 大屏 is_open + 结清提前） ──
func _test_gate_open() -> void:
	print("── A 组：红卡门弹出（设计 §7-1 A/D）──")
	var src := FileAccess.get_file_as_string("res://scripts/loop/game_loop.gd")
	_check("A0a 源码锚：尾段提取为 _finish_card_choice 且 confirmed 信号接其上",
		src.contains("func _finish_card_choice()")
			and src.contains("sublime_confirm_ui.confirmed.connect(_finish_card_choice)"))
	_check("A0b 源码锚：AUTO_SUBLIME_WINDOW_S := 1.5（挂机自动确认窗=选卡窗 3 倍）",
		_gl.AUTO_SUBLIME_WINDOW_S == 1.5
			and src.contains("const AUTO_SUBLIME_WINDOW_S := 1.5"))
	_open_flow()
	_check("A1 前置：_open_card_flow → LEVEL_UP 且选卡窗开",
		_gl.state == GameConst.GameStatus.LEVEL_UP and _gl.card_select_ui.is_open)
	_choose_sublime_pair()
	_check("A2a 批含 SUBLIME（第二位）：state 保持 LEVEL_UP（不直通 PLAYING）",
		_gl.state == GameConst.GameStatus.LEVEL_UP, "state=%d" % _gl.state)
	_check("A2b 大屏 is_open（鸭子口）+ 选卡窗已收",
		_gl.sublime_confirm_ui.is_open() and not _gl.card_select_ui.is_open)
	_check("A2c apply 即生效（红卡本局语义——大屏是告知非选择）",
		bool(_gl.player.get("skill_sublime")))
	_check("A3 D) 进大屏时 _persist_defer_depth==0（摊薄窗结清提前）",
		int(Meta.get("_persist_defer_depth")) == 0,
		"depth=%d" % int(Meta.get("_persist_defer_depth")))
	# 内容生成（设计 §1.3：零新文案，全读 CharacterTable 同表）
	var entry: Dictionary = CharacterTable.get_character(_gl.player.character_id)
	var ui_title: Label = _gl.sublime_confirm_ui.get("_title")
	var ui_cur_name: Label = _gl.sublime_confirm_ui.get("_cur_name")
	var ui_cur_desc: Label = _gl.sublime_confirm_ui.get("_cur_desc")
	var ui_sub_name: Label = _gl.sublime_confirm_ui.get("_sub_name")
	var ui_sub_desc: Label = _gl.sublime_confirm_ui.get("_sub_desc")
	var btn: Button = _gl.sublime_confirm_ui.find_child("SublimeConfirmButton", true, false)
	_check("A4a 标题带「技能升华 · 传说」（红档档名）",
		ui_title != null and ui_title.text == "技能升华 · 传说", "text=%s" % str(ui_title.text if ui_title else "?"))
	_check("A4b 左右栏同表同源（当前/升华 名+描述 == CharacterTable 键值）",
		ui_cur_name.text == String(entry.get("skill_name"))
			and ui_cur_desc.text == String(entry.get("skill_desc"))
			and ui_sub_name.text == String(entry.get("sublime_name"))
			and ui_sub_desc.text == String(entry.get("sublime_desc")))
	_check("A4c 尾行「本局有效 · 爆率 0.001% · 确认后继续战斗」逐字在卡", _footer_text_ok())
	_check("A4d 单「确认」钮 + FOCUS_NONE（真机异形屏/手柄焦点不抢）",
		btn != null and btn.text == "确认" and btn.focus_mode == Control.FOCUS_NONE)


func _footer_text_ok() -> bool:
	var footer: Label = null
	for c in _gl.sublime_confirm_ui.get("_card").get_children():
		if c is Label and String((c as Label).text).contains("本局有效"):
			footer = c
			break
	return footer != null and footer.text == "本局有效 · 爆率 0.001% · 确认后继续战斗"


# ── B 组：确认收口（PLAYING + 宽限） ──────────────────────────────
func _test_confirm_close() -> void:
	print("── B 组：confirmed → PLAYING + 宽限（设计 §7-1 B）──")
	_gl.sublime_confirm_ui.confirm()
	_check("B1 confirmed 后 state==PLAYING", _gl.state == GameConst.GameStatus.PLAYING,
		"state=%d" % _gl.state)
	_check("B2 resume_grace 计时 >0（_arm_resume_grace 只在最终恢复 PLAYING 置位一次）",
		_gl.resume_grace_left > 0.0, "grace=%.3f" % _gl.resume_grace_left)
	_check("B3 大屏已收（is_open false）", not _gl.sublime_confirm_ui.is_open())
	_gl.sublime_confirm_ui.confirm()            # 幂等：已收态直返（不再发信号）
	_check("B4 confirm 幂等（重复调用不再发信号/state 不动）",
		not _gl.sublime_confirm_ui.is_open() and _gl.state == GameConst.GameStatus.PLAYING)


# ── C 组：连升排队不丢 ────────────────────────────────────────────
func _test_pending_reopen() -> void:
	print("── C 组：pending_level_ups>0 确认后选卡窗重开（设计 §7-1 C）──")
	_open_flow()
	_gl.pending_level_ups = 1                     # 模拟连升排队一张
	_choose_sublime_pair()
	_check("C1 前置：大屏开且排队在（pending==1）",
		_gl.sublime_confirm_ui.is_open() and _gl.pending_level_ups == 1)
	_gl.sublime_confirm_ui.confirm()
	_check("C2 确认后选卡窗重开（回 LEVEL_UP——排队续开走同一收口不丢）",
		_gl.state == GameConst.GameStatus.LEVEL_UP and _gl.card_select_ui.is_open
			and _gl.pending_level_ups == 0,
		"state=%d open=%s pending=%d" % [_gl.state, str(_gl.card_select_ui.is_open),
			_gl.pending_level_ups])
	_check("C3 宽限保留待最终收口（回 LEVEL_UP 期不清零）",
		_gl.resume_grace_left > 0.0, "grace=%.3f" % _gl.resume_grace_left)
	_gl._on_card_choice([{}])                    # 排队卡选完（无 SUBLIME 批）→ PLAYING
	_check("C4 排队卡收口 → PLAYING（门只在批含 SUBLIME 时弹）",
		_gl.state == GameConst.GameStatus.PLAYING, "state=%d" % _gl.state)


# ── E 组：挂机自动确认（无手动输入路径） ──────────────────────────
func _test_idle_auto_confirm() -> void:
	print("── E 组：挂机模式大屏 1.5s 自动确认（设计 §7-1 E / §6.4-2 P0）──")
	Meta.set_setting("auto_select_on", true)
	_open_flow()
	_choose_sublime_pair()
	_check("E1 大屏开 + 挂机臂挂起（_auto_sublime_left == 1.5）",
		_gl.sublime_confirm_ui.is_open()
			and is_equal_approx(_gl._auto_sublime_left, 1.5),
		"left=%.3f" % _gl._auto_sublime_left)
	_gl._tick_auto_idle(1.0)
	_check("E2 1.0s 未满窗：大屏仍开（不提前确认）",
		_gl.sublime_confirm_ui.is_open()
			and _gl.state == GameConst.GameStatus.LEVEL_UP)
	_gl._tick_auto_idle(0.6)                     # 累计 1.6s ≥ 1.5s → 自动 confirm
	_check("E3 1.5s 到点自动确认（无手动输入路径）：PLAYING + 大屏收",
		_gl.state == GameConst.GameStatus.PLAYING and not _gl.sublime_confirm_ui.is_open(),
		"state=%d" % _gl.state)
	_check("E4 自动确认后挂机臂复位（left == -1）", _gl._auto_sublime_left == -1.0)
	# 挂机关：臂即时撤销不误 confirm（auto_select_on 关 = 零成本直返）
	Meta.set_setting("auto_select_on", false)
	_open_flow()
	_choose_sublime_pair()
	_check("E5a 挂机关：大屏照常弹出（手动确认路径不受挂机开关影响）",
		_gl.sublime_confirm_ui.is_open())
	_gl._tick_auto_idle(5.0)                     # 关态直返分支：窗撤销且不 confirm
	_check("E5b 挂机关：5s 驱动不自动确认 + 挂机臂撤销（left == -1）",
		_gl.sublime_confirm_ui.is_open() and _gl._auto_sublime_left == -1.0)
	_gl.sublime_confirm_ui.confirm()
	_check("E5c 手动确认照常收口 → PLAYING", _gl.state == GameConst.GameStatus.PLAYING)


# ── E6 组：键盘/手柄确认通道（R245 评审 low 落地） ──────────────────
func _test_keyboard_confirm() -> void:
	print("── E6 组：ui_accept/ui_select 即确认（FOCUS_NONE 不吃键，走 _unhandled_input）──")
	_open_flow()
	_choose_sublime_pair()
	var ev_cancel := InputEventAction.new()
	ev_cancel.action = &"ui_cancel"
	ev_cancel.pressed = true
	_gl.sublime_confirm_ui._unhandled_input(ev_cancel)
	_check("E6a 非 accept 动作不确认（ui_cancel：大屏仍开、态不动）",
		_gl.sublime_confirm_ui.is_open()
			and _gl.state == GameConst.GameStatus.LEVEL_UP)
	var ev := InputEventAction.new()
	ev.action = &"ui_accept"
	ev.pressed = true
	_gl.sublime_confirm_ui._unhandled_input(ev)
	_check("E6b ui_accept 即确认：PLAYING + 大屏收（与按钮/挂机臂同一 confirm 收口）",
		_gl.state == GameConst.GameStatus.PLAYING and not _gl.sublime_confirm_ui.is_open(),
		"state=%d" % _gl.state)
	_gl.sublime_confirm_ui._unhandled_input(ev)      # 已收态再发
	_check("E6c 已收态重复 accept 零扰动（confirm 幂等）",
		_gl.state == GameConst.GameStatus.PLAYING and not _gl.sublime_confirm_ui.is_open())


# ── F 组：无门直通 + 同局不去重 ───────────────────────────────────
func _test_no_gate_passthrough() -> void:
	print("── F 组：批不含 SUBLIME 时无门直通（设计 §7-1 F + §1.5 同局不去重）──")
	_open_flow()
	_gl._on_card_choice([{}])                    # 空批（applied=0，无 SUBLIME）
	_check("F1 无 SUBLIME 批：直通 PLAYING + 大屏不弹 + 宽限照置",
		_gl.state == GameConst.GameStatus.PLAYING
			and not _gl.sublime_confirm_ui.is_open()
			and _gl.resume_grace_left > 0.0,
		"state=%d grace=%.3f" % [_gl.state, _gl.resume_grace_left])
	_check("F2 persist 收口结清（depth==0——旧版链路逐位一致）",
		int(Meta.get("_persist_defer_depth")) == 0)
	# 同局不去重：第二次红卡批照弹（enable_sublime 幂等——去重反而零反馈）
	_open_flow()
	_choose_sublime_pair()
	_check("F3 同局第二批红卡照弹（每批必弹·同局不去重）",
		_gl.sublime_confirm_ui.is_open()
			and _gl.state == GameConst.GameStatus.LEVEL_UP)
	_gl.sublime_confirm_ui.confirm()
	_check("F4 第二次确认照常收口 → PLAYING", _gl.state == GameConst.GameStatus.PLAYING)


# ── Q 组：quit_to_menu 补结清（设计 §1.6） ────────────────────────
func _test_quit_menu_settle() -> void:
	print("── Q 组：quit_to_menu 补 cancel_persist_defer 强制结清 ──")
	_gl.request_pause()                          # PLAYING → PAUSED（quit_to_menu 合法前置）
	_check("Q1 前置：PAUSED", _gl.state == GameConst.GameStatus.PAUSED)
	Meta.begin_persist_defer()                   # 模拟批作用域残余抑制态（depth==1）
	_check("Q2 前置：抑制态在（depth==1）", int(Meta.get("_persist_defer_depth")) == 1)
	var ok := _gl.quit_to_menu()
	_check("Q3 quit_to_menu 强制结清（depth 1→0——丢图鉴/total_kills 增量的口径修复）",
		ok and int(Meta.get("_persist_defer_depth")) == 0,
		"ok=%s depth=%d" % [str(ok), int(Meta.get("_persist_defer_depth"))])
	var src := FileAccess.get_file_as_string("res://scripts/loop/game_loop.gd")
	_check("Q4 源码锚：quit_to_menu 内含 Meta.cancel_persist_defer()",
		src.contains("func quit_to_menu") and src.count("Meta.cancel_persist_defer()") >= 2)
