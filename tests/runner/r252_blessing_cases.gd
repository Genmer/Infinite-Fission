# tests/runner/r252_blessing_cases.gd
# R252 需求②「祝福（开局自选词条）」用例体（入口 test_r252_blessing.gd 运行时 load——
# -s 编译期禁引工程类名纪律；cases 文件命名禁带 test_ 前缀）。验收锚（R252 设计 §2.5）：
#  B1 池容量（R263 送武迁移）：全解锁全池==62 且分档探针 {6,24,26,6}+逐项过
#     「fits 或 blessing_gift_weapon 送得出」三态自洽；MEC_RICOCHET_HALL/SYN_BOUNCE_SPEC∉全池、
#     7×TH_*∉全池（过滤键断言非 id 黑名单）；金档探针 6 项（BEAM_SPECTRA/CRITICAL_MASS 送武上池）。
#  B2 解锁门：codex_traits 空 → 池空、_on_menu_start 不弹面板直达战斗。
#  B3 记忆写口：已解锁写成功+ConfigFile 读回 characters/blessing_trait；未解锁拒写。
#  B4 跨档生效（R262 反向迁移）：金档记忆×普通局 / 蓝档记忆×困难局 → 挂载恰 1 层
#     +【祝福】横幅（R252 §2.1-8「跨档回落=不挂载」定案随池全档开放作废）。
#     R263 挂载用例统一星尘 fixture（余额 1000——收费面：余额不足挂载被拒断言必红）。
#  B5 挂载与横幅：蓝档记忆×普通局 → 恰 1 份 + 【祝福】行在 R250 三档横幅行之后。
#  B6 适配拒挂（R263 载靶迁移）：纯形态失配词条（AFF_CDR required_forms [1,2,3] 对手枪
#     form 0 恒失配、无 required_weapon 不进送通道）× 弹道首发 → 零挂载 + 拒挂披露
#    （原靶 MEC_BEAM_LAG 走送武通道会送 W4 挂载成功——语义反转，R263 起改哨兵靶）。
#  B7 重开重挂：restart_run 后恰 1 份（无双叠）+ 横幅再现 + 不重复扣费（R263）。
#  B8 每日隔离四场景：a 菜单每日路径无面板无挂载；b 直调 start_run(种子) 无挂载；
#     c 每日局死亡 restart_run 仍无挂载；d 对照常规局 restart 正常重挂。
#  B9 RNG 纪律：同种子带/不带祝福 start_run → card_generator/spawner rng.state 逐位相同。
#  B10 续局不虚增：带祝福存档 → continue_run 后 codex_traits 不增、词条层数不重复。
#  B11 UI 契约：面板记忆项预选；「不选祝福」/未选直出发均不改写记忆键。
#  B12 旧档零迁移：无 blessing_trait 键存档 _load 后读口==""。
# 测试卫生：headless 走 meta_save_test.cfg 独立档；开套件快照内存+档字节，收尾原样还原。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const GL_SRC := "res://scripts/loop/game_loop.gd"
# R262：GOLD_POOL 六件列常量退役（R252-design:95 拆门前池口径）——金档探针改 B1
# 内联 4 项断言（BEAM_SPECTRA W4/CRITICAL_MASS W8 绑定被首发适配门滤）。
const TH_KEYS := ["TH_BANK_SHOT", "TH_DETONATION_ECHO", "TH_MIRROR_CHOIR", "TH_PRISM_CHOIR", "TH_RING_PRESSURE", "TH_SWARM_NOVA", "TH_VOLLEY_STATE"]

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _captured_intro: Array[String] = []        # mechanics_intro 横幅捕获（restart 消费后断言用）
# Meta 快照（套件隔离）
var _snap_crystals: int = 0
var _snap_upgrades: Dictionary = {}
var _snap_codex_traits: Dictionary = {}
var _snap_custom_weapon: String = ""
var _snap_blessing: String = ""
var _snap_character: StringName = &""
var _snap_stardust: int = 0                    # R263：星尘入快照（挂载用例 fixture 还原）
var _snap_stardust_total: int = 0
var _had_save: bool = false
var _save_text: String = ""


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	EventBus.mechanics_intro.connect(_on_intro_captured)
	_snap_meta()
	_test_b1_pool_capacity()
	_test_b2_unlock_gate()
	_test_b3_memory_store()
	_test_b4_cross_tier_fallback()
	_test_b5_mount_and_banner()
	_test_b6_gate_adapter_fallback()
	_test_b7_restart_remount()
	_test_b8_daily_isolation()
	_test_b9_rng_discipline()
	_test_b10_continue_no_inflate()
	_test_b11_ui_contract()
	_test_b12_old_save_zero_migration()
	_test_b13_unlock_note()                     # R252-QA第1轮 B2：词条首获→祝福解锁局内播报
	_test_b14_clear_memory()                    # R252-QA第1轮 B3：清除记忆=永久退出携带
	_test_b15_dangling_memory_defense()         # QA甲-4 防御路径：悬空记忆 id 零挂载不崩
	_test_b16_pending_reopen_selfheal()         # R254-2：模态面板丢失→二次出发自愈重开
	_test_b19_pending_map_adopt()               # R254 QA-D4：pending 期换图二次出发——实跑图同步
	_test_b17_pending_debounce_and_reopen_params()  # R254-QA1：防抖臂+重开参数同池同档
	_test_b20_reject_visible()                   # R257：出发拒绝可见化（事件入环+菜单横幅）
	_test_b21_depart_events()                    # R257：出发链事件入环（复发定罪取证）
	_test_b22_panel_draw_order()                 # R258：面板绘制序置顶（修前被菜单整层盖）
	_restore_meta()
	# R252-QA第1轮 B4（测试卫生）：显式 free GameLoop + 断开本套件信号——修退出
	# 「ObjectDB instances leaked / resources still in use」警告（对照 cultivate 无泄漏）。
	EventBus.mechanics_intro.disconnect(_on_intro_captured)
	_gl.free()
	print("验收汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL | %s" % f)


func fail_count() -> int:
	return _fail


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  ok | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("  FAIL | %s %s" % [p_name, p_detail])


func _on_intro_captured(p_text: String) -> void:
	_captured_intro.append(p_text)


func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R252BlessingGameLoop"
	tree.get_root().add_child(_gl)              # _ready → boot（含 BlessingPickUI 组装）


# ── Meta 快照/还原（档 + 内存双面） ────────────────────────────────
func _snap_meta() -> void:
	_snap_crystals = Meta.crystals
	_snap_upgrades = Meta.upgrades.duplicate()
	_snap_codex_traits = Meta.codex_traits.duplicate()
	_snap_custom_weapon = Meta.custom_weapon_id
	_snap_blessing = Meta.blessing_trait_id
	_snap_character = Meta.character_id
	_snap_stardust = Meta.stardust
	_snap_stardust_total = Meta.stardust_total
	Meta.stardust = 1000                       # R263 星尘 fixture：挂载用例（B4/B5/B7/B8-d/
	                                          # B9/B10）按价扣费，余额不足即拒挂断言必红
	var sp := Meta.save_path()
	_had_save = FileAccess.file_exists(sp)
	if _had_save:
		_save_text = FileAccess.get_file_as_string(sp)


func _restore_meta() -> void:
	Meta.crystals = _snap_crystals
	Meta.upgrades = _snap_upgrades
	Meta.codex_traits = _snap_codex_traits
	Meta.custom_weapon_id = _snap_custom_weapon
	Meta.blessing_trait_id = _snap_blessing
	Meta.character_id = _snap_character
	Meta.stardust = _snap_stardust
	Meta.stardust_total = _snap_stardust_total
	var sp := Meta.save_path()
	if _had_save:
		var f := FileAccess.open(sp, FileAccess.WRITE)
		if f != null:
			f.store_string(_save_text)
			f.close()
		Meta._load()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(sp))
	RunSave.clear()                             # 局内存档不留痕（B10 写入）


# ── fixture 工具 ──────────────────────────────────────────────────
func _unlock_all_traits() -> void:
	for tid_v: Variant in _gl.registry.traits.keys():
		Meta.codex_traits[String(tid_v)] = true


func _goto_menu() -> void:
	# 清场回菜单（真路径）：start_run 本就不清武器槽（清场是 quit_to_menu/_reset_run_state
	# 职责）——直改 state 绕过清场会让上一局挂载的词条残留进下一局计数（B7/B8/B10
	# 假阳性根源）。玩家口径「回主菜单再出发」恒经此清场。
	if _gl.state == GameConst.GameStatus.MENU:
		return
	_gl.state = GameConst.GameStatus.PAUSED
	_gl.quit_to_menu()


func _normal_start() -> void:
	# 直调常规开局（绕过面板入口——祝福挂载由 start_run 内 _apply_start_blessing 承担）
	_goto_menu()
	_gl._difficulty = 0
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()


func _trait_layers_total(p_tid: StringName) -> int:
	# 全槽位词条层数合计（挂载恰一份断言）
	var n := 0
	for w_v: Variant in _gl.player.weapon_slots:
		var w := w_v as WeaponBase
		if w == null or not is_instance_valid(w) or w.trait_stack == null:
			continue
		for m in w.trait_stack.traits:
			if m.data != null and m.data.id == p_tid:
				n += m.layers
	return n


func _trait_layers_on_slot0(p_tid: StringName) -> int:
	# slot 0 主武器上的层数（B6 兜底落位断言）
	if _gl.player.weapon_slots.is_empty():
		return 0
	var w := _gl.player.weapon_slots[0] as WeaponBase
	if w == null or not is_instance_valid(w) or w.trait_stack == null:
		return 0
	var n := 0
	for m in w.trait_stack.traits:
		if m.data != null and m.data.id == p_tid:
			n += m.layers
	return n


func _captured_contains(p_text: String) -> bool:
	# 已消费横幅捕获检查（restart_run emit+clear 后的断言通道）
	for s in _captured_intro:
		if s.contains(p_text):
			return true
	return false


func _intro_contains(p_text: String) -> bool:
	# 横幅断言：先查未消费的 _run_intro_lines（start_run 直调路径），再查已消费捕获
	#（restart_run 消费口径——emit 后即清）
	if "".join(_gl._run_intro_lines).contains(p_text):
		return true
	return _captured_contains(p_text)


# ── B1 池容量 ─────────────────────────────────────────────────────
func _test_b1_pool_capacity() -> void:
	print("── B1 池容量：全解锁全池 62={白6,蓝24,紫26,金6}（R263 送武三态）+ 过滤键断言 ──")
	_unlock_all_traits()
	var p_all := _gl._blessing_pool()
	var p0 := _gl._blessing_pool(0)
	var p1 := _gl._blessing_pool(1)
	var p2 := _gl._blessing_pool(2)
	var p3 := _gl._blessing_pool(3)
	_check("B1 档位映射：blessing_rarity_tier == [1,2,3]",
		GameConst.blessing_rarity_tier(0) == 1 and GameConst.blessing_rarity_tier(1) == 2
			and GameConst.blessing_rarity_tier(2) == 3)
	# R263：W1 手枪首发三态滤——38 适配 + 24 武器绑定经送武通道上池（2 纯形态失配出局）
	_check("B1 池容量：全池==62 且分档 {6,24,26,6}",
		p_all.size() == 62 and p0.size() == 6 and p1.size() == 24 and p2.size() == 26 and p3.size() == 6,
		"all=%d %d/%d/%d/%d" % [p_all.size(), p0.size(), p1.size(), p2.size(), p3.size()])
	# R263 逐项三态自洽：全池每一项「过首发适配门」或「送得出」（blessing_gift_weapon
	# 非空——武器绑定附赠通道）
	var swid: StringName = _gl._starting_weapon_id(Meta.character_id)
	var swd: WeaponData = _gl.registry.get_weapon(swid)
	var sform := int(swd.form) if swd != null else -1
	var sclass := "melee"
	if swd != null and swd.melee is Dictionary:
		sclass = String((swd.melee as Dictionary).get("weapon_class", "melee"))
	var all_fit := true
	for tid in p_all:
		var td_f: TraitData = _gl.registry.get_trait(tid)
		var fits := td_f != null and _gl._blessing_fits_start_weapon(td_f, swd, sform, sclass)
		var gifts := td_f != null and MechanicGate.blessing_gift_weapon(td_f, _gl.registry.weapons) != StringName("")
		if not (fits or gifts):
			all_fit = false
	_check("B1 逐项三态自洽：全池每项 fits 或送得出（%s 首发）" % String(swid),
		all_fit, "swid=%s" % String(swid))
	# 过滤键断言（非 id 黑名单）：requires_trait 键在词条声明侧实存，且因此缺席全池
	var rh := _gl.registry.get_trait(&"MEC_RICOCHET_HALL")
	var bs := _gl.registry.get_trait(&"SYN_BOUNCE_SPEC")
	_check("B1 requires_trait 过滤键：MEC_RICOCHET_HALL/SYN_BOUNCE_SPEC 声明侧键实存且∉全池",
		rh != null and bs != null
			and String(rh.params.get("requires_trait", "")) != ""
			and String(bs.params.get("requires_trait", "")) != ""
			and not p_all.has(&"MEC_RICOCHET_HALL") and not p_all.has(&"SYN_BOUNCE_SPEC"))
	# 阈值型过滤键：7×TH_* 声明 threshold_only=true 且全部缺席全池
	var th_keyed := 0
	var th_absent := 0
	for key: String in TH_KEYS:
		var td := _gl.registry.get_trait(StringName(key))
		if td != null and bool(td.params.get("threshold_only", false)):
			th_keyed += 1
			if not p_all.has(StringName(key)):
				th_absent += 1
	_check("B1 threshold_only 过滤键：7×TH_* 声明侧键实存且∉全池", th_keyed == 7 and th_absent == 7,
		"keyed=%d absent=%d" % [th_keyed, th_absent])
	# 金档探针（R263 送武迁移）：6 项=4 通用+BEAM_SPECTRA(W4)/CRITICAL_MASS(W8)
	# 双绑定经附赠送武通道上池（原 R262 首发适配门滤除——送武通道开例回归）
	var gold_ok := true
	for key: String in ["ELE_REACTION_VOID", "MEC_CRIT_SHARD", "MEC_FRACTAL", "SYN_FIRST_STRIKE",
			"MEC_BEAM_SPECTRA", "MEC_CRITICAL_MASS"]:
		if not p3.has(StringName(key)):
			gold_ok = false
	_check("B1 金档探针 6 项：四通用+BEAM_SPECTRA(W4)/CRITICAL_MASS(W8) 送武上池",
		gold_ok and p3.size() == 6 and p3.has(&"MEC_CRITICAL_MASS"))
	_check("B1 池序纪律：池按 id 序（零 rng）", _sorted(p_all) and _sorted(p1) and _sorted(p2) and _sorted(p3))


func _sorted(p_pool: Array[StringName]) -> bool:
	var prev := ""
	for tid in p_pool:
		if String(tid) < prev:
			return false
		prev = String(tid)
	return true


# ── B2 解锁门 ─────────────────────────────────────────────────────
func _test_b2_unlock_gate() -> void:
	print("── B2 解锁门：codex_traits 空 → 池空、不弹面板直达战斗 ──")
	Meta.codex_traits.clear()
	Meta.blessing_trait_id = ""
	_check("B2 空图鉴：全池空（R262 全池口径）", _gl._blessing_pool().is_empty())
	_goto_menu()
	_gl._difficulty = 0
	_gl._on_menu_start(MapTable.FIRST_MAP_ID)
	_check("B2 直达战斗：不弹面板（is_open==false）且 state==PLAYING",
		not _gl.blessing_pick_ui.is_open() and _gl.state == GameConst.GameStatus.PLAYING,
		"open=%s state=%d" % [str(_gl.blessing_pick_ui.is_open()), _gl.state])


# ── B3 记忆写口 ───────────────────────────────────────────────────
func _test_b3_memory_store() -> void:
	print("── B3 记忆写口：解锁写+落盘可读回；未解锁拒写 ──")
	Meta.codex_traits["AFF_CRIT_DMG"] = true
	Meta.blessing_trait_id = ""
	var ok := Meta.set_blessing_trait(&"AFF_CRIT_DMG")
	_check("B3 已解锁写入：返 true + 内存读口生效", ok and Meta.blessing_trait_id == "AFF_CRIT_DMG",
		"ok=%s mem=%s" % [str(ok), Meta.blessing_trait_id])
	var cfg := ConfigFile.new()
	var loaded := cfg.load(Meta.save_path()) == OK
	var stored := String(cfg.get_value("characters", "blessing_trait", "<missing>"))
	_check("B3 写即落盘：ConfigFile 立即可读回 characters/blessing_trait",
		loaded and stored == "AFF_CRIT_DMG", "loaded=%s stored=%s" % [str(loaded), stored])
	# 未解锁拒写：返 false、内存与档均不变
	Meta.codex_traits.erase("AFF_XP_GAIN")
	var ok2 := Meta.set_blessing_trait(&"AFF_XP_GAIN")
	var cfg2 := ConfigFile.new()
	cfg2.load(Meta.save_path())
	var stored2 := String(cfg2.get_value("characters", "blessing_trait", "<missing>"))
	_check("B3 未解锁拒写：返 false + 内存与档均不变（仿 set_custom_weapon 断言式）",
		not ok2 and Meta.blessing_trait_id == "AFF_CRIT_DMG" and stored2 == "AFF_CRIT_DMG",
		"ok=%s mem=%s stored=%s" % [str(ok2), Meta.blessing_trait_id, stored2])


# ── B4 跨档生效（R262 拆门反向迁移）────────────────────────────────
func _test_b4_cross_tier_fallback() -> void:
	print("── B4 跨档生效：金档记忆×普通局 / 蓝档记忆×困难局 → 合法挂载（R252 §2.1-8 回落定案作废） ──")
	_unlock_all_traits()
	Meta.set_blessing_trait(&"SYN_FIRST_STRIKE")        # 金档（rarity 3）
	_goto_menu()
	_gl._difficulty = 0
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_check("B4 金×普：挂载恰 1 层（R262 跨档合法生效）", _trait_layers_total(&"SYN_FIRST_STRIKE") == 1,
		"layers=%d" % _trait_layers_total(&"SYN_FIRST_STRIKE"))
	_check("B4 金×普：横幅含【祝福】生效行", _intro_contains("【祝福】"),
		str(_gl._run_intro_lines))
	Meta.set_blessing_trait(&"AFF_CRIT_DMG")            # 蓝档（rarity 1）
	_goto_menu()
	_gl._difficulty = 1
	_gl.start_run()
	_check("B4 蓝×困：挂载恰 1 层", _trait_layers_total(&"AFF_CRIT_DMG") == 1,
		"layers=%d" % _trait_layers_total(&"AFF_CRIT_DMG"))
	_check("B4 蓝×困：横幅含【祝福】生效行", _intro_contains("【祝福】"))


# ── B5 挂载与横幅 ─────────────────────────────────────────────────
func _test_b5_mount_and_banner() -> void:
	print("── B5 挂载与横幅：蓝档记忆×普通局（sentinel 弹道首发） ──")
	_unlock_all_traits()
	Meta.set_blessing_trait(&"AFF_CRIT_DMG")            # 蓝档通用词条（W1 可挂）
	_normal_start()
	var total := _trait_layers_total(&"AFF_CRIT_DMG")
	_check("B5 挂载：TraitStack 含 AFF_CRIT_DMG 恰 1 份", total == 1, "layers=%d" % total)
	var bidx := -1
	var didx := -1
	var lines := _gl._run_intro_lines
	for i in range(lines.size()):
		if String(lines[i]).begins_with("【祝福】"):
			bidx = i
		if String(lines[i]).contains("【普通】"):
			didx = i
	_check("B5 横幅：含【祝福】行且位于 R250 三档横幅行之后（行序断言）",
		bidx >= 0 and didx >= 0 and bidx > didx,
		"banner@%d r250@%d lines=%s" % [bidx, didx, str(lines)])
	_check("B5 记忆不变：直调 start_run 不改写记忆键", Meta.blessing_trait_id == "AFF_CRIT_DMG")


# ── B6 适配拒挂（R263 载靶迁移：纯形态失配哨兵）──────────────────
func _test_b6_gate_adapter_fallback() -> void:
	print("── B6 适配拒挂：纯形态失配词条（AFF_CDR）× 弹道首发 → 零挂载 + 拒挂横幅 ──")
	_unlock_all_traits()
	# R263：原靶 MEC_BEAM_LAG（required_forms[1]+required_weapon W4）走送武通道会送 W4
	# 并挂载成功——拒挂语义反转；改靶 AFF_CDR（required_forms [1,2,3] 对手枪 form 0 恒
	# 失配、无 required_weapon/required_class 不进送通道）= 三态滤第三态哨兵。
	Meta.set_blessing_trait(&"AFF_CDR")
	_normal_start()
	_check("B6 拒挂：零挂载（不占 12 格构筑帽真伤）",
		_trait_layers_on_slot0(&"AFF_CDR") == 0 and _trait_layers_total(&"AFF_CDR") == 0,
		"slot0=%d total=%d" % [_trait_layers_on_slot0(&"AFF_CDR"), _trait_layers_total(&"AFF_CDR")])
	_check("B6 拒挂披露：横幅含「与当前首发武器不适配」", _intro_contains("与当前首发武器不适配"),
		str(_gl._run_intro_lines))


# ── B7 重开重挂 ───────────────────────────────────────────────────
func _test_b7_restart_remount() -> void:
	print("── B7 重开重挂：start_run → restart_run 恰 1 份 + 横幅再现 + 不重复扣费（R263） ──")
	_unlock_all_traits()
	Meta.set_blessing_trait(&"AFF_CRIT_DMG")
	_normal_start()
	_check("B7 首局：挂载恰 1 份", _trait_layers_total(&"AFF_CRIT_DMG") == 1)
	var sd_before_restart: int = Meta.stardust          # R263：已购位——重开不重复扣费
	_captured_intro.clear()
	_gl.state = GameConst.GameStatus.GAME_OVER          # 死亡/结算态（restart_run 状态门）
	var reopened: bool = _gl.restart_run()
	_check("B7 重开：restart_run 成功 + 词条恰 1 份（无双叠）",
		reopened and _trait_layers_total(&"AFF_CRIT_DMG") == 1,
		"reopened=%s layers=%d" % [str(reopened), _trait_layers_total(&"AFF_CRIT_DMG")])
	_check("B7 横幅再现：mechanics_intro 消费含【祝福】行", _captured_contains("【祝福】"),
		str(_captured_intro))
	_check("B7 不重复扣费：重开星尘余额不变（已购位拦截）", Meta.stardust == sd_before_restart,
		"%d → %d" % [sd_before_restart, Meta.stardust])


# ── B8 每日隔离（四场景） ─────────────────────────────────────────
func _test_b8_daily_isolation() -> void:
	print("── B8 每日隔离：a 菜单路径 / b 直调种子 / c 每日死亡重开 / d 常规对照 ──")
	_unlock_all_traits()
	Meta.set_blessing_trait(&"AFF_CRIT_DMG")
	# a) _on_menu_start_daily 路径：无面板无挂载（面板层）
	_goto_menu()
	_gl._difficulty = 0
	_gl._on_menu_start_daily()
	_check("B8-a 菜单每日路径：无面板 + 零挂载 + 已进局",
		not _gl.blessing_pick_ui.is_open() and _trait_layers_total(&"AFF_CRIT_DMG") == 0
			and _gl.state == GameConst.GameStatus.PLAYING,
		"open=%s layers=%d" % [str(_gl.blessing_pick_ui.is_open()), _trait_layers_total(&"AFF_CRIT_DMG")])
	# b) 直调 start_run(正种子)：绕过面板入口 → 挂载层守卫拦截
	_goto_menu()
	_gl._difficulty = 0
	_gl.start_run(20261010)
	_check("B8-b 直调每日种子：零挂载（_active_daily_seed>=0 守卫）",
		_trait_layers_total(&"AFF_CRIT_DMG") == 0)
	# c) 每日局死亡 → R188 自动重开路径 restart_run：仍零挂载
	_gl.state = GameConst.GameStatus.GAME_OVER
	_gl.restart_run()
	_check("B8-c 每日局自动重开：restart_run 后仍零挂载（种子跨重开留存）",
		_trait_layers_total(&"AFF_CRIT_DMG") == 0)
	# d) 对照：常规局（seed=-1）restart_run 正常重挂
	_goto_menu()
	_gl._difficulty = 0
	_gl.start_run()
	_gl.state = GameConst.GameStatus.GAME_OVER
	_gl.restart_run()
	_check("B8-d 常规局对照：restart_run 后正常重挂恰 1 份",
		_trait_layers_total(&"AFF_CRIT_DMG") == 1, "layers=%d" % _trait_layers_total(&"AFF_CRIT_DMG"))


# ── B9 RNG 纪律 ───────────────────────────────────────────────────
func _test_b9_rng_discipline() -> void:
	print("── B9 RNG 纪律：同种子带/不带祝福 → 卡池流零位移 ──")
	_unlock_all_traits()
	Meta.set_blessing_trait(&"AFF_CRIT_DMG")
	_goto_menu()
	_gl._difficulty = 0
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run(424242)
	var card_state: int = _gl.card_generator.rng.state
	var spawn_state: int = _gl.spawner.rng.state
	Meta.blessing_trait_id = ""                         # 清记忆（测试探针直写——不落盘）
	_goto_menu()
	_gl._difficulty = 0
	_gl.start_run(424242)
	_check("B9 零 rng 消费：card_generator.rng.state 逐位相同",
		card_state == _gl.card_generator.rng.state,
		"%d vs %d" % [card_state, _gl.card_generator.rng.state])
	_check("B9 零 rng 消费：spawner.rng.state 逐位相同",
		spawn_state == _gl.spawner.rng.state)


# ── B10 续局不虚增 ────────────────────────────────────────────────
func _test_b10_continue_no_inflate() -> void:
	print("── B10 续局：存档恢复后 codex_traits 不增、层数不重复 ──")
	_unlock_all_traits()
	Meta.set_blessing_trait(&"AFF_CRIT_DMG")
	_normal_start()
	var codex_n0: int = Meta.codex_traits.size()
	RunSave.save_run(_gl.serialize_run())
	_goto_menu()
	var resumed: bool = _gl.continue_run()
	_check("B10 恢复：continue_run 成功",
		resumed and _gl.state == GameConst.GameStatus.PLAYING, "resumed=%s" % str(resumed))
	_check("B10 图鉴不虚增：恢复后 codex_traits 计数不变",
		Meta.codex_traits.size() == codex_n0,
		"%d → %d" % [codex_n0, Meta.codex_traits.size()])
	_check("B10 层数不重复：恢复后词条恰 1 份（快照恢复口径）",
		_trait_layers_total(&"AFF_CRIT_DMG") == 1, "layers=%d" % _trait_layers_total(&"AFF_CRIT_DMG"))


# ── B11 UI 契约 ───────────────────────────────────────────────────
func _test_b11_ui_contract() -> void:
	print("── B11 UI 契约：记忆项预选 + 「不选祝福」不改写记忆键 ──")
	_unlock_all_traits()
	Meta.set_blessing_trait(&"AFF_CRIT_DMG")
	var pool := _gl._blessing_pool(1)
	_goto_menu()
	_gl._difficulty = 0
	_gl.blessing_pick_ui.open(pool, Meta.blessing_trait(), 0)
	_check("B11 预选态：面板打开 + 记忆项处于选中",
		_gl.blessing_pick_ui.is_open() and _gl.blessing_pick_ui.selected_id() == "AFF_CRIT_DMG",
		"open=%s sel=%s" % [str(_gl.blessing_pick_ui.is_open()), _gl.blessing_pick_ui.selected_id()])
	var mem_before := Meta.blessing_trait_id
	_gl.blessing_pick_ui.dismiss()                      # 触发真实 dismissed 链（GameLoop 收口不写记忆）
	_check("B11 不选祝福：记忆键不被覆盖",
		Meta.blessing_trait_id == mem_before and not _gl.blessing_pick_ui.is_open(),
		"mem=%s→%s" % [mem_before, Meta.blessing_trait_id])
	# 未选直出发（confirmed 空串）：同样不改写记忆键（GameLoop 空串守卫）
	_goto_menu()
	_gl.blessing_pick_ui.open(pool, "", 0)
	_gl.blessing_pick_ui.confirm()
	_check("B11 未选直出发：confirmed 空串不改写记忆键",
		Meta.blessing_trait_id == mem_before,
		"mem=%s→%s" % [mem_before, Meta.blessing_trait_id])


# ── B12 旧档零迁移 ────────────────────────────────────────────────
func _test_b12_old_save_zero_migration() -> void:
	print("── B12 旧档零迁移：无 blessing_trait 键 → 读口空 ──")
	Meta.blessing_trait_id = "AFF_CRIT_DMG"             # 先污染内存（证明确实由 _load 覆写）
	var cfg := ConfigFile.new()
	cfg.set_value("meta", "crystals", 5)
	cfg.set_value("meta", "upgrades", {})
	cfg.set_value("meta", "character", "sentinel")
	cfg.save(Meta.save_path())                          # 故意不含 characters/blessing_trait 键
	Meta._load()
	_check("B12 旧档缺键：_load 后读口==\"\"（零迁移）", Meta.blessing_trait_id == "",
		"mem=%s" % Meta.blessing_trait_id)
	_check("B12 读口同构：blessing_trait()==StringName(\"\")",
		Meta.blessing_trait() == StringName(""))


# ── B13 解锁播报（R252-QA第1轮 B2） ───────────────────────────────
func _test_b13_unlock_note() -> void:
	print("── B13 解锁播报：词条首获→「新祝福已解锁」局内 toast；重复获得静默 ──")
	_captured_intro.clear()
	Meta.codex_traits.erase("AFF_GOLD")
	var tname := ""
	var td := _gl.registry.get_trait(&"AFF_GOLD")
	if td != null:
		tname = String(td.display_name)
	Meta._on_card_chosen(&"AFF_GOLD", 1)                # 直调事件口（kind=1 首获分支）
	_check("B13 首获播报：mechanics_intro 含「新祝福已解锁」+ 词条名（GameLoop 接线组装）",
		_captured_contains("新祝福已解锁") and (not tname.is_empty()) and _captured_contains(tname),
		"captured=%s tname=%s" % [str(_captured_intro), tname])
	var n0: int = _captured_intro.size()
	Meta._on_card_chosen(&"AFF_GOLD", 1)                # 已解锁：重复获得
	_check("B13 重复获得静默：零新播报（首获分支幂等）", _captured_intro.size() == n0,
		"%d → %d" % [n0, _captured_intro.size()])
	_check("B13 图鉴写入：首获即入 codex_traits（解锁口径不回归）",
		Meta.is_trait_unlocked(&"AFF_GOLD"))


# ── B14 清除记忆（R252-QA第1轮 B3） ───────────────────────────────
func _test_b14_clear_memory() -> void:
	print("── B14 清除记忆：永久退出携带（清键+落盘）；无记忆禁用 ──")
	_unlock_all_traits()
	Meta.set_blessing_trait(&"AFF_CRIT_DMG")
	var pool := _gl._blessing_pool(1)
	_goto_menu()
	_gl._difficulty = 0
	_gl.blessing_pick_ui.open(pool, Meta.blessing_trait_id, 0)
	var clear_btn := _gl.blessing_pick_ui.get_node_or_null(
		"BlessingPickRoot/BlessingPickCard/BlessingClearButton") as Button
	_check("B14 清除钮在册：记忆存在时可用", clear_btn != null and not clear_btn.disabled,
		"node=%s disabled=%s" % [str(clear_btn != null), str(clear_btn.disabled if clear_btn != null else true)])
	Meta.clear_blessing_trait()
	_check("B14 直调清键：读口空", Meta.blessing_trait_id == "")
	# 面板全链：带记忆开面板 → clear_memory() → GameLoop 清键收口
	Meta.set_blessing_trait(&"AFF_CRIT_DMG")
	_goto_menu()
	_gl.blessing_pick_ui.open(pool, Meta.blessing_trait_id, 0)
	_gl.blessing_pick_ui.clear_memory()
	var cfg := ConfigFile.new()
	var loaded: bool = cfg.load(Meta.save_path()) == OK
	var stored := String(cfg.get_value("characters", "blessing_trait", "<missing>"))
	_check("B14 全链清除：记忆键空 + ConfigFile 读回空（写即落盘）",
		Meta.blessing_trait_id == "" and loaded and stored == "",
		"mem=%s stored=%s" % [Meta.blessing_trait_id, stored])
	# 无记忆禁用态
	_goto_menu()
	_gl.blessing_pick_ui.open(pool, "", 0)
	_check("B14 清除钮禁用：无记忆时 disabled（无可清）",
		clear_btn != null and clear_btn.disabled)
	_gl.blessing_pick_ui.dismiss()


# ── B15 悬空记忆防御（QA甲-4 顺手防御断言） ───────────────────────
func _test_b15_dangling_memory_defense() -> void:
	print("── B15 悬空记忆：记忆 id 不存在（词条被删）→ 零挂载不崩零横幅 ──")
	_unlock_all_traits()
	Meta.blessing_trait_id = "NO_SUCH_TRAIT"            # var 直写绕过写口守卫（模拟悬空档）
	_normal_start()
	_check("B15 悬空记忆：开局正常（state==PLAYING）零挂载",
		_gl.state == GameConst.GameStatus.PLAYING
			and _gl.registry.get_trait(&"NO_SUCH_TRAIT") == null)
	_check("B15 悬空记忆：零祝福/回落横幅（视作空记忆静默）",
		not _intro_contains("【祝福】") and not _intro_contains("与本难度档位不符"),
		str(_gl._run_intro_lines))
	Meta.blessing_trait_id = ""


func _test_b19_pending_map_adopt() -> void:
	print("── B19 换图半采用修复（QA-D4：current_map_id 随二次出发同步） ──")
	# 复现链：grass 出发弹面板挂起 → 面板丢失 → 换已解锁 frost 再出发 → dismiss 进局。
	# 修前采用块漏写 current_map_id → start_run 波表/Meta.set_run_map 读旧图 grass
	#（横幅新图/实跑旧图/难度新档三者错位）。修后实跑==二次所选。
	_goto_menu()
	_unlock_all_traits()
	Meta.blessing_trait_id = ""
	Meta.map_records.clear()
	Meta.map_records["world_grass"] = {"best_wave": 10, "best_kills": 0, "best_level": 1}
	_check("B19 前置：frost 普通档已解锁（grass 达线）",
		Meta.is_map_unlocked(&"world_frost", 0))
	_gl._on_menu_start(&"world_grass", 0)     # 首启 grass：tier1 池非空弹面板挂起
	_check("B19 前置：grass 面板挂起", bool(_gl.get("_blessing_pending"))
		and _gl.blessing_pick_ui.is_open())
	_gl.blessing_pick_ui.close()              # 模拟面板丢失（不发收口信号）
	_gl._on_menu_start(&"world_frost", 0)     # 换图二次出发（frost 已解锁→采用）
	_gl.blessing_pick_ui.dismiss()            # 收口进局
	_check("B19 换图半采用修复：实跑地图==二次所选 frost（start_run 真源同步）",
		_gl.current_map_id == &"world_frost"
			and _gl.state == GameConst.GameStatus.PLAYING,
		"current=%s state=%d" % [String(_gl.current_map_id), _gl.state])
	_goto_menu()


func _test_b16_pending_reopen_selfheal() -> void:
	print("── B16 模态面板丢失自愈（R254-2：二次出发重开面板） ──")
	# 复现链：真机「出发→回主页」= 面板模态期面板因故不可见且三收口信号未发 →
	# _blessing_pending 挂起 → 旧实现二次出发被静默吞（玩家永远无响应）。
	# R254-2 修：pending 期二次出发时面板未开则同池同档重开（open 幂等）。
	_goto_menu()
	_unlock_all_traits()
	Meta.blessing_trait_id = ""
	_gl._on_menu_start(MapTable.FIRST_MAP_ID, 1)   # 困难首关（恒解锁）：tier2 池非空应弹面板
	_check("B16 前置：面板弹起挂起（困难档池非空，MENU 模态）",
		bool(_gl.get("_blessing_pending")) and _gl.blessing_pick_ui.is_open()
			and _gl.state == GameConst.GameStatus.MENU,
		"pending=%s open=%s state=%d" % [_gl.get("_blessing_pending"),
			_gl.blessing_pick_ui.is_open(), _gl.state])
	_gl.blessing_pick_ui.close()                    # 模拟面板丢失（close 不发信号——三收口全旁路）
	_check("B16 丢失态：面板不可见但 pending 挂起（复现用户卡点）",
		not _gl.blessing_pick_ui.is_open() and bool(_gl.get("_blessing_pending")),
		"open=%s pending=%s" % [_gl.blessing_pick_ui.is_open(), _gl.get("_blessing_pending")])
	_gl._on_menu_start(MapTable.FIRST_MAP_ID, 1)    # 玩家丢视野后的自然动作：再点出发
	_check("B16 自愈：二次出发重开面板（仍 MENU 不误启动）",
		_gl.blessing_pick_ui.is_open() and bool(_gl.get("_blessing_pending"))
			and _gl.state == GameConst.GameStatus.MENU,
		"open=%s pending=%s state=%d" % [_gl.blessing_pick_ui.is_open(),
			_gl.get("_blessing_pending"), _gl.state])
	_gl.blessing_pick_ui.dismiss()                  # 收口归位：按「不选祝福」继续
	_check("B16 收口：dismiss 后链恢复进局",
		_gl.state == GameConst.GameStatus.PLAYING and not bool(_gl.get("_blessing_pending")),
		"state=%d pending=%s" % [_gl.state, _gl.get("_blessing_pending")])
	_goto_menu()
func _test_b17_pending_debounce_and_reopen_params() -> void:
	print("── B17 pending 防抖（面板开着不重开）+ 自愈重开=同池同档（不随二次参数漂移） ──")
	# R254-QA 第 1 轮补缺口：B16 只钉「未开则重开」臂——本用例补两缺口：
	# ① is_open 真臂（面板本就开着）不重开不误启（open() 重调会清选中态——选中态
	#   保持即防抖证据）；② 重开参数=原出发上下文（_difficulty 未被二次参数覆写）。
	_goto_menu()
	_unlock_all_traits()
	Meta.blessing_trait_id = ""
	_gl._on_menu_start(MapTable.FIRST_MAP_ID, 2)     # 地狱首关（恒解锁）：tier3 池非空应弹面板
	var pool3 := _gl._blessing_pool(3)
	_check("B17 前置：地狱档出发弹面板（tier3 池非空，MENU 模态挂起）",
		pool3.size() > 0 and bool(_gl.get("_blessing_pending")) and _gl.blessing_pick_ui.is_open()
			and _gl.state == GameConst.GameStatus.MENU,
		"pool=%d pending=%s open=%s state=%d" % [pool3.size(), _gl.get("_blessing_pending"),
			_gl.blessing_pick_ui.is_open(), _gl.state])
	var sel_tid := ""
	if pool3.size() > 0:
		sel_tid = String(pool3[0])
		_gl.blessing_pick_ui._on_row_toggled(true, sel_tid)   # 玩家选中（未确认）
	_gl._on_menu_start(MapTable.FIRST_MAP_ID, 2)     # 模态期二次出发（面板仍开）
	# R254 修轮终版语义（评审#6）：无条件 open（幂等只刷内容）——兼「开着但渲染
	# 异常不可见」的引擎级兜底。内容刷新即 open 重入证据：选中态重置为记忆项
	#（记忆空=空选），模态三不变量（开/pending/MENU）保持
	_check("B17 幂等重入：面板开着二次出发=内容刷新（选中态重置）+模态保持",
		_gl.blessing_pick_ui.is_open() and _gl.blessing_pick_ui.selected_id() == ""
			and _gl.state == GameConst.GameStatus.MENU
			and bool(_gl.get("_blessing_pending")),
		"open=%s sel=%s state=%d" % [_gl.blessing_pick_ui.is_open(),
			_gl.blessing_pick_ui.selected_id(), _gl.state])
	_gl.blessing_pick_ui.dismiss()                  # 收口归位：按「不选祝福」继续
	_check("B17 收口：dismiss 后链恢复进局",
		_gl.state == GameConst.GameStatus.PLAYING and not bool(_gl.get("_blessing_pending")),
		"state=%d pending=%s" % [_gl.state, _gl.get("_blessing_pending")])
	# —— B18 自愈重开参数：面板丢失后二次出发（换难度参数）采用新档重开 ——
	# R254 修轮终版语义（评审#5）：丢视野窗口玩家可能改选难度——重开采用本次
	# 出发上下文（首关恒解锁必过校验），confirm 启动的正是玩家当前所见的出发
	_goto_menu()
	_gl._on_menu_start(MapTable.FIRST_MAP_ID, 2)     # 地狱：tier3 面板
	_gl.blessing_pick_ui.close()                     # 模拟面板丢失（close 不发信号）
	_gl._on_menu_start(MapTable.FIRST_MAP_ID, 0)     # 玩家改点普通出发（二次参数=0）
	var pool1 := _gl._blessing_pool(1)
	var rows_n: int = _gl.blessing_pick_ui._list_box.get_child_count()
	var sub: String = _gl.blessing_pick_ui._subtitle.text
	# R261 口径迁移：分页后树内行=当页页容量（min(7,池)）非全池——池观感走页码/筛选签
	_check("B18 自愈重开=采用二次参数档（当页行数==页容量；副标题=普通档无地狱残留）",
		_gl.blessing_pick_ui.is_open() and rows_n == mini(7, pool1.size())
			and sub.contains(GameConst.difficulty_name(0))
			and not sub.contains(GameConst.difficulty_name(2)),
		"open=%s rows=%d/%d sub=%s" % [_gl.blessing_pick_ui.is_open(), rows_n, pool1.size(), sub])
	_gl.blessing_pick_ui.dismiss()                   # 收口归位
	_goto_menu()


# ── B20/B21（R257 出发链可观测性） ─────────────────────────────────
func _diag_count(p_text: String) -> int:
	# 事件独立环行计数（QA-257-2 后事件单写 _diag_ev_lines——断言用前后差分=本用例
	# 新发事件；环不清空，免疫套件先前用例残留，也免破坏 _diag_cursor 环不变量）
	var n := 0
	for s in DebugStats._diag_ev_lines:
		if s.contains(p_text):
			n += 1
	return n


func _test_b20_reject_visible() -> void:
	print("── B20 出发拒绝可见化（R257：事件入环 + 菜单横幅——「点了没反应」终结） ──")
	# 复刻用户场景：困难-第三关（world_demon）未解锁（frost 困难档未通关）点出发。
	# 修前=push_warning+静默 return（选图面板已关=玩家感知「点了没反应/回主页」）；
	# 修后=① diag 事件行（含上一关名+难度——复发导出一锤定罪）② 菜单顶横幅
	# flash_hint（当场告知解锁缺口）。
	_goto_menu()
	Meta.blessing_trait_id = ""
	Meta.map_records.clear()                       # demon@困难锁定（frost 困难档无通关记录）
	_check("B20 前置：demon 困难档未解锁（frost·困难未通关）",
		not Meta.is_map_unlocked(&"world_demon", 1))
	var n_reject := _diag_count("出发拒绝")
	_gl._on_menu_start(&"world_demon", 1)          # 用户场景直调：出发→拒绝
	_check("B20 拒绝：state 仍 MENU（不误启动、不弹面板、无 pending 挂起）",
		_gl.state == GameConst.GameStatus.MENU
			and not bool(_gl.get("_blessing_pending"))
			and not _gl.blessing_pick_ui.is_open(),
		"state=%d pending=%s" % [_gl.state, _gl.get("_blessing_pending")])
	_check("B20 事件入环：出发拒绝行（map+难度+上一关名——复发定罪键）",
		_diag_count("出发拒绝") > n_reject
			and _diag_count("出发拒绝：map=world_demon 难度=1 未解锁（需先通关 寒霜冰原·困难）") > 0,
		"环内拒绝行数=%d" % _diag_count("出发拒绝"))
	_check("B20 可见化：菜单顶横幅在显且指向解锁缺口（尚未解锁·寒霜冰原）",
		_gl.menu_screen != null and _gl.menu_screen._hint_label != null
			and _gl.menu_screen._hint_label.visible
			and _gl.menu_screen._hint_label.text.contains("尚未解锁")
			and _gl.menu_screen._hint_label.text.contains("寒霜冰原"),
		"hint=%s" % (_gl.menu_screen._hint_label.text
			if _gl.menu_screen != null and _gl.menu_screen._hint_label != null else "<null>"))
	_check("B20 绘制序置顶：横幅居 _root 兄弟末位且在 MenuBg 之上（评审H1 回归守卫）",
		_gl.menu_screen._hint_label.get_index()
			== _gl.menu_screen._hint_label.get_parent().get_child_count() - 1
			and (_gl.menu_screen._root.get_node("MenuBg") as CanvasItem).get_index()
				< _gl.menu_screen._hint_label.get_index(),
		"hint_idx=%d/%d bg_idx=%d" % [_gl.menu_screen._hint_label.get_index(),
			_gl.menu_screen._hint_label.get_parent().get_child_count() - 1,
			(_gl.menu_screen._root.get_node("MenuBg") as CanvasItem).get_index()])


func _test_b21_depart_events() -> void:
	print("── B21 出发链事件入环（R257 修轮：真按钮路径全链五事件——取证五件套） ──")
	# 修轮升级（评审M2）：驱动改真按钮链（开选关面板→切困难→点出发钮→emit→
	# _on_menu_start），比直调 _on_menu_start 多覆盖 UI 层 tap 直证事件——若病灶是
	# 上层吞点击，玩家导出呈「无选关出发钮行」，假说 f 从反推变直证。
	_goto_menu()
	_unlock_all_traits()
	Meta.blessing_trait_id = ""
	# QA-257-1：恢复普通通关记录（B20 清了 map_records）——normal_cleared()==true
	# 才能切困难档：_on_difficulty_pick 后 _build_map_select_rows → _refresh_difficulty_row
	# 对未解锁档回落 _sel_difficulty=0（menu_screen.gd:706-707），事件将诚实发「难度=0」
	Meta.map_records["world_grass"] = {"best_wave": 10, "best_kills": 0, "best_level": 1}
	var n_pick := _diag_count("选关出发钮")
	var n_panel := _diag_count("祝福面板弹")
	var n_confirm := _diag_count("祝福确认")
	var n_start := _diag_count("start_run map=")
	var n_m12 := _diag_count("状态 1→2")
	_gl.menu_screen._open_map_select()
	_gl.menu_screen._on_difficulty_pick(1)        # 真路径：切困难档
	_gl.menu_screen._on_map_pick(MapTable.FIRST_MAP_ID)   # 真路径：出发钮（UI tap 直证）
	_check("B21 选关出发钮事件入环（UI 层 tap 直证——评审 M2）",
		_diag_count("选关出发钮") > n_pick
			and _diag_count("选关出发钮：map=world_grass 难度=1") > 0,
		"pick 行=%d" % _diag_count("选关出发钮"))
	_check("B21 面板弹事件入环（池数+档+map 三元组）",
		_diag_count("祝福面板弹") > n_panel
			and _diag_count("祝福面板弹：池 ") > 0
			and _diag_count("map=world_grass") >= 1,
		"面板弹行=%d" % _diag_count("祝福面板弹"))
	var pool2 := _gl._blessing_pool(2)
	var sel_tid := ""
	if pool2.size() > 0:
		sel_tid = String(pool2[0])
		_gl.blessing_pick_ui._on_row_toggled(true, sel_tid)   # 玩家选中（未确认）
	_gl.blessing_pick_ui.confirm()                 # 「出发」收口
	_check("B21 确认事件入环（含所选词条 id——非空选择真路径）",
		_diag_count("祝福确认") > n_confirm and _diag_count("祝福确认：%s" % sel_tid) > 0,
		"sel=%s" % sel_tid)
	_check("B21 start_run+状态迁移入环（进局两件套，state==PLAYING）",
		_diag_count("start_run map=") > n_start
			and _diag_count("状态 1→2") > n_m12
			and _gl.state == GameConst.GameStatus.PLAYING,
		"start=%d m12=%d state=%d" % [_diag_count("start_run map="),
			_diag_count("状态 1→2"), _gl.state])
	_goto_menu()


func _test_b22_panel_draw_order() -> void:
	print("── B22 面板绘制序置顶（R258：修前面板被菜单整层盖——vc65 真机日志定罪） ──")
	# 修前：blessing_pick_ui 先挂（:3034）< menu_screen 后挂（:3051）=菜单画在面板上，
	# 面板 root 不透明 bg 整层盖死（不可见+tap 穿透到菜单层=玩家「点出发没反应」）。
	# is_open() 标志位测试假绿（与 R257-H1 横幅同构盲区）——本用例断绘制序真源。
	_goto_menu()
	_unlock_all_traits()
	Meta.blessing_trait_id = ""
	var n_vis := _diag_count("祝福面板可见化")
	_gl._on_menu_start(MapTable.FIRST_MAP_ID, 1)   # 困难首关恒解锁：弹面板
	_check("B22 绘制序：面板挂载序位在菜单之后（画在菜单上——R258 根修）",
		_gl.blessing_pick_ui.get_index() > _gl.menu_screen.get_index(),
		"panel=%d menu=%d" % [_gl.blessing_pick_ui.get_index(),
			_gl.menu_screen.get_index()])
	_check("B22 可见化事件入环（卡片矩形+层序读数——复发日志直读归因）",
		_diag_count("祝福面板可见化") > n_vis
			and _diag_count("祝福面板可见化：卡片=") > 0
			and _diag_count("层=") > 0
			and _gl.blessing_pick_ui.layer == 40,
		"vis 行=%d layer=%d" % [_diag_count("祝福面板可见化"),
			_gl.blessing_pick_ui.layer])
	_gl._on_menu_start(MapTable.FIRST_MAP_ID, 1)   # 二次出发（模态期）→ open 幂等重开
	_check("B22 layer 重申：二次 open 后面板层=40 盖过全部默认 0 层屏（挂载序免疫）",
		_gl.blessing_pick_ui.layer == 40
			and _gl.blessing_pick_ui.get_index() > _gl.menu_screen.get_index()
			and _gl.blessing_pick_ui.is_open(),
		"layer=%d panel=%d menu=%d" % [_gl.blessing_pick_ui.layer,
			_gl.blessing_pick_ui.get_index(), _gl.menu_screen.get_index()])
	_gl.blessing_pick_ui.dismiss()                 # 收口归位
	_goto_menu()
