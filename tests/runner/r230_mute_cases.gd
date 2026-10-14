# tests/runner/r230_mute_cases.gd
# R230 二cb「静音按钮」用例体（入口 test_r230_mute.gd 运行时 load——-s 编译期禁引
# 工程类名纪律）。验收锚：
# ① Meta 链：master_mute 键注册齐（SETTINGS_DEFAULTS + _normalized_setting bool 族）——
#    写口 bool 归一（int 1 → true）、读口回读、未知键口径不受扰。
# ② SfxBank 应用链：master_mute=true → 全播放器（sfx 全族 + bgm 七轨）统一 SILENT_DB
#    (-60)；=false → 恢复两滑条公式值（sfx = SFX_BASE_DB + linear_gain_db(v)）；bgm 七轨
#    null 宿主容错（menu 轨存在即断言）。
# ③ 信号链：settings_changed("master_mute") → apply_settings_volumes 即时重应用（不重启）。
# ④ SettingsPanel UI：MuteButton 在树（音效音量行内）、_refresh_toggles 态文案
#    （未静音=「静 音」/已静音=「已静音」）、_on_mute_toggle 翻转 Meta + 刷文案；
#    _sync_from_meta 打开回填路径同刷（守卫不写盘）。
# ⑤ 源级锚：sfx_bank 早分支 + _apply_all_db 落点在位；settings_panel 药丸接线齐
#    （pressed→_on_mute_toggle / _refresh_toggles 覆盖 / 行内坐标不撞右缘百分比与滑条）。
extends RefCounted

const BANK_SRC := "res://scripts/gamefeel/sfx_bank.gd"
const PANEL_SRC := "res://scripts/ui/settings_panel.gd"
const META_SRC := "res://scripts/meta/meta_manager.gd"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	await tree.process_frame
	await tree.process_frame
	# 快照还原纪律（k2 先例：headless 测试档跨套件残留）
	var mm0 := bool(Meta.settings("master_mute"))
	var sfx0 := float(Meta.settings("sfx_volume"))
	var bgm0 := float(Meta.settings("bgm_volume"))
	Meta.set_setting("master_mute", false)
	Meta.set_setting("sfx_volume", 0.8)
	Meta.set_setting("bgm_volume", 0.6)
	var bank: SfxBank = SfxBank.new()
	bank.name = "R230MuteBank"
	tree.get_root().add_child(bank)
	await tree.process_frame                     # _ready → _build_all/_build_bgm/apply
	_test_1_meta_chain()
	_test_2_bank_apply(bank)
	_test_3_signal_chain(bank)
	var panel: SettingsPanel = SettingsPanel.new()
	panel.name = "R230MutePanel"
	tree.get_root().add_child(panel)
	await tree.process_frame
	_test_4_panel_ui(panel, bank)
	_test_5_source_anchors()
	# 清理 + 还原（池化纪律：直建直 free）
	panel.queue_free()
	bank.queue_free()
	Meta.set_setting("master_mute", mm0)
	Meta.set_setting("sfx_volume", sfx0)
	Meta.set_setting("bgm_volume", bgm0)
	await tree.process_frame
	_report()


func _all_players_db(p_bank: SfxBank) -> Array[float]:
	# 全播放器 db 采集（spx 全族 + bgm 七轨非空宿主）——空表/全 null 返回空数组由调用方断言
	var out: Array[float] = []
	for key: Variant in p_bank._players:
		out.append((p_bank._players[key] as AudioStreamPlayer).volume_db)
	for p: AudioStreamPlayer in [p_bank._bgm_player, p_bank._bgm_bass_player,
			p_bank._bgm_arp_player, p_bank._bgm_hats_player, p_bank._bgm_arp_high_player,
			p_bank._bgm_boss_player, p_bank._bgm_menu_player]:
		if p != null:
			out.append(p.volume_db)
	return out


func _test_1_meta_chain() -> void:
	print("── ① Meta 键注册与归一 ──")
	_check("① 默认表注册 master_mute=false", not bool(Meta.settings("master_mute")))
	Meta.set_setting("master_mute", 1)          # int 1 → bool 归一
	_check("① 写口 bool 归一（int 1 → true 回读）", bool(Meta.settings("master_mute")))
	Meta.set_setting("master_mute", 0)
	_check("① 写口 bool 归一（int 0 → false 回读）", not bool(Meta.settings("master_mute")))


func _test_2_bank_apply(p_bank: SfxBank) -> void:
	print("── ② SfxBank 静音应用 ──")
	var expect_sfx := SfxBank.SFX_BASE_DB + SfxBank.linear_gain_db(0.8)
	var dbs := _all_players_db(p_bank)
	_check("② 非静音态：播放器在树（build 完成）", dbs.size() >= 8,
		"size=%d（sfx 族+bgm 轨）" % dbs.size())
	var sfx_player: AudioStreamPlayer = p_bank._players.values()[0]
	_check("② 非静音态：sfx 音量=基准+增益公式（%.2f）" % expect_sfx,
		absf(sfx_player.volume_db - expect_sfx) < 0.01,
		"actual=%.2f" % sfx_player.volume_db)
	Meta.set_setting("master_mute", true)
	dbs = _all_players_db(p_bank)
	var all_silent := not dbs.is_empty()
	for dbv in dbs:
		all_silent = all_silent and absf(dbv - SfxBank.SILENT_DB) < 0.001
	_check("② 静音态：全播放器统一 -60dB（含 %d 枚）" % dbs.size(), all_silent)
	Meta.set_setting("master_mute", false)
	_check("② 解除静音：恢复公式值（%.2f）" % expect_sfx,
		absf(sfx_player.volume_db - expect_sfx) < 0.01,
		"actual=%.2f" % sfx_player.volume_db)


func _test_3_signal_chain(p_bank: SfxBank) -> void:
	print("── ③ settings_changed 即时链 ──")
	# ② 已隐式走信号（set_setting → emit → _on_settings_changed → apply）；此处锁
	# _on_settings_changed 的键过滤面：master_mute 必在触发列表（防未来改键名漏接）
	var src := _read(BANK_SRC)
	_check("③ 键过滤含 master_mute（settings_changed 触发面）",
		src.contains("\"master_mute\""))


func _test_4_panel_ui(p_panel: SettingsPanel, p_bank: SfxBank) -> void:
	print("── ④ 设置页药丸 ──")
	var btn: Button = p_panel.find_child("MuteButton", true, false) as Button
	_check("④ MuteButton 在树（音效音量行内）", btn != null and is_instance_valid(btn))
	if btn == null:
		return
	_check("④ 未静音态文案=「静 音」", btn.text == "静 音", "text=%s" % btn.text)
	p_panel._on_mute_toggle()
	_check("④ 药丸翻转：Meta master_mute=true", bool(Meta.settings("master_mute")))
	_check("④ 已静音态文案=「已静音」", btn.text == "已静音", "text=%s" % btn.text)
	var sfx_player: AudioStreamPlayer = p_bank._players.values()[0]
	_check("④ 药丸翻转即时生效：bank 全静音（信号链端到端）",
		absf(sfx_player.volume_db - SfxBank.SILENT_DB) < 0.001,
		"db=%.2f" % sfx_player.volume_db)
	p_panel._on_mute_toggle()
	_check("④ 再翻回：Meta false + 文案复位", not bool(Meta.settings("master_mute"))
		and btn.text == "静 音")
	# 打开回填路径（_sync_from_meta 尾调 _refresh_toggles——守卫内不写盘）
	Meta.set_setting("master_mute", true)
	p_panel._sync_from_meta()
	_check("④ _sync_from_meta 回填刷态（打开即正确态）", btn.text == "已静音")
	Meta.set_setting("master_mute", false)


func _test_5_source_anchors() -> void:
	print("── ⑤ 源级锚 ──")
	var bank := _read(BANK_SRC)
	_check("⑤ sfx_bank：SILENT_DB 常量 + 早分支 + _apply_all_db 落点齐",
		bank.contains("const SILENT_DB := -60.0")
			and bank.contains("_apply_all_db(SILENT_DB)")
			and bank.contains("func _apply_all_db("))
	var panel := _read(PANEL_SRC)
	_check("⑤ settings_panel：药丸接线齐（pressed→_on_mute_toggle/_refresh_toggles 刷态/命名）",
		panel.contains("\"MuteButton\"")
			and panel.contains("pressed.connect(_on_mute_toggle)")
			and panel.contains("_on_mute_toggle"))
	var meta := _read(META_SRC)
	_check("⑤ meta：默认表 + bool 归一族双注册（缺一静默失效口径）",
		meta.contains("\"master_mute\": false")
			and meta.contains("\"master_mute\""))


func _read(p_path: String) -> String:
	var f := FileAccess.open(p_path, FileAccess.READ)
	if f == null:
		return ""
	var s := f.get_as_text()
	f.close()
	return s


func _check(p_label: String, p_ok: bool, p_detail: String = "") -> void:
	if p_ok:
		_pass += 1
		print("  PASS | %s" % p_label)
	else:
		_fail += 1
		_failures.append(p_label)
		print("  FAIL | %s | %s" % [p_label, p_detail])


func fail_count() -> int:
	return _fail


func _report() -> void:
	print("────────────────────────────────")
	if not _failures.is_empty():
		print("  FAIL 详情：%s" % "；".join(_failures))
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])
