# tests/runner/r191_rework_cases.gd
# R191 整案用例体（由 test_r191_rework.gd 入口在 autoload 就绪后运行时加载编译）。
# 真源：docs/design/R191_CODEX_REACTION.md §4 分项定案 + §7 验收总表——七项非 noop
# 定案的验收标准全部落为本套件断言（文案一律取 GameConst.weapon_note / reaction_note /
# balance 真源，禁止手抄；数据断言走 DataRegistry.load_all（内含 DataValidator 全量校验））：
#   A. tips｜theme() 全局 tooltip 条目 + 构筑详情卡 weapon_note 原句 + hud p_tip 死路径删除
#      + project.godot 无 [gui] + Tooltip 条目仅 theme.gd
#   B. codex_rxn｜GameConst.reaction_note 文案单源（R192 全键动态枚举：封闭字段 7/
#      坏 id/真条件/解锁节奏/样张单源；现役三名与优先级头部相对序逐字锁）
#   C. rxn｜registry 数据断言（required_forms/描述澄清）+ 挂载形态门四向 + 无难度门节奏
#   D. muzzle｜镜面弹出生点 == 外层化身枪口（≤2px；菱形/玩家中心 ≥52px 双负例）
#      + 镜面火花 ice_shard/TINT/0.09s + 本体零回归 + fx 低档门 + R183 副本零变化
#   E. mirror_laser｜tick_atk 补 meta 轴 + 镜面束 = 源面板×ratio + apply_state 缓存失效
#      + 直挂 SPLIT_PRISM 束段指纹==1 + 七束卡锁 W4（门与 .tres 双证）+ copy_tint bool
#      + r187 用例体 excl 显式类型化（源级）
#   F. achv｜阶梯展开 ~128（120~200）/ 手写 11 条逐字保留 / id 全局唯一 / 显式 reward
#      + 四族计数接线 + 分页与 toast 合批 + 批量单次落盘（源级）+ 存档结构零改动
#      + F17 run_reactions 成就族接线（R192：直调至 10/50 → 解锁 + 结晶仅终档 +30 + 结算复位）
#   G. boomerang｜BOOM_VIS_MULT ×5.0 表现层 + 命中盒解耦 + R77/R78 定距翻转/返航零冲突
#   H. rxn 端到端｜「火+电挂载 → 附着 → 过载触发」全链（通道单元 → ON_SPAWN 守卫 →
#      双元素实弹交替 → 真件 ElementalSystem 双槽成对 → RXN_FIR_LTG 落血/清槽/CD 2s）
# 确定性：固定种子 + 固定坐标（pkg3/w5/mirror_muzzle 范式）；夹具敌静止、玩家钉屏中心。
extends RefCounted

const DT := 1.0 / 120.0
const DT60 := 1.0 / 60.0
const MAIN_SCENE := "res://scenes/main.tscn"
const PROJ_SCENE := "res://scenes/combat/projectiles/ballistic_projectile.tscn"
const ENEMY_SCENE := "res://scenes/combat/enemies/enemy.tscn"
const ANCHOR_EPS := 2.0            # 锚点容差 px（修复后同帧重合级；修复前 ~82~112px）
const FALLBACK_MIN := 52.0         # 与菱形回退位/玩家中心最小距离（证明确实换锚）
const SAFE_THETA := 3.15           # 采样窗化身角 rad（安全弧——避开公转几何近点）
const ANCHOR_FRAMES := 150         # 锚点采样帧数（@60Hz 公转弧 ≈1.75 rad，全程安全弧内）
const PLAYER_HOME := Vector2(360.0, 900.0)   # E-15 活动区钳 y∈[768,1268] 合法位
const BEAM_CARDS: Array[StringName] = [&"MEC_SPLIT_PRISM", &"MEC_BEAM_TRACK",
	&"MEC_BEAM_FAN", &"MEC_BEAM_COFOCUS", &"MEC_BEAM_LAG", &"MEC_BEAM_SPECTRA",
	&"MEC_PHASE_SYNC"]

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _fx0: int = 2                  # fx_quality 出厂档备份（镜像/火花用例置档后还原）
var _char0: StringName = &"sentinel"  # 角色备份（R183 副本负例借诺亚后还原）
var _wave20_0: bool = false


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20260926)
	_ensure_autoloads()
	_test_tips_theme_sources()       # A（无 GameLoop：theme 条目 + 源级 grep 验收）
	_test_reaction_note_source()     # B（无 GameLoop：文案单源）
	_test_rxn_data_and_gates()       # C（无 GameLoop：registry + 形态门 + 节奏）
	_boot_game_loop()
	_test_tips_detail_card()         # A 行为级（详情卡真源逐字 + 布局契约）
	_test_mirror_laser_w4()          # E（W4 源镜面五缺陷修复）
	_test_muzzle_anchor_and_spark()  # D（锚点 + 火花 + R183 副本零变化）
	_test_boomerang_scale()          # G（×5.0 表现层 + 命中盒解耦）
	_test_achv_all()                 # F（阶梯/接线/分页/toast/单次落盘/存档结构）
	_test_codex_reaction_page()      # codex_rxn 行为级（页签/行级/倍率读表/零存档写入）
	_teardown_game_loop()
	_test_rxn_end_to_end()           # H（火+电挂载→附着→过载——独立池夹具真件全链）
	print("────────────────────────────────────────")
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


# ══ 支撑 ══════════════════════════════════════════════════════════
func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s（%s）" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])


func _approx(p_a: float, p_b: float, p_tol: float = 0.001) -> bool:
	return absf(p_a - p_b) <= p_tol


func _bump_frame() -> void:
	GameConfig.frame_stamp += 1                # E-03 帧闸推进（GameLoop 帧序的测试侧替身）


func _read_text(p_res_path: String) -> String:
	return FileAccess.get_file_as_string(p_res_path)


func _func_body(p_src: String, p_header: String) -> String:
	# 源级断言用：截取 p_header 起至下一个顶级 "\nfunc " 的函数体
	var start := p_src.find(p_header)
	if start < 0:
		return ""
	var next := p_src.find("\nfunc ", start + 1)
	return p_src.substr(start, (next if next >= 0 else p_src.length()) - start)


func _count_occurrences(p_src: String, p_needle: String) -> int:
	var n := 0
	var i := p_src.find(p_needle)
	while i >= 0:
		n += 1
		i = p_src.find(p_needle, i + p_needle.length())
	return n


func _scan_scripts_with(p_needles: Array) -> Array[String]:
	# 递归收集 scripts/ 下含任一 needle 的 .gd 文件（res:// 相对路径，headless 直读）
	var hits: Array[String] = []
	_scan_dir("res://scripts", p_needles, hits)
	return hits


func _scan_dir(p_dir_path: String, p_needles: Array, p_hits: Array[String]) -> void:
	var dir := DirAccess.open(p_dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var full := p_dir_path + "/" + name
		if dir.current_is_dir() and not name.begins_with("."):
			_scan_dir(full, p_needles, p_hits)
		elif name.ends_with(".gd"):
			var src := _read_text(full)
			for needle: String in p_needles:
				if src.contains(needle):
					p_hits.append(full)
					break
		name = dir.get_next()
	dir.list_dir_end()


func _ensure_autoloads() -> void:
	# -s 模式兜底（工程 autoload 正常在场时零操作——rxn_channel 同款防御）
	var pairs := {
		"EventBus": "res://autoload/event_bus.gd",
		"GameConfig": "res://autoload/game_config.gd",
		"DebugStats": "res://autoload/debug_stats.gd",
		"Meta": "res://scripts/meta/meta_manager.gd",
	}
	for node_name: String in pairs:
		if tree.get_root().get_node_or_null(node_name) == null:
			var node: Node = (load(pairs[node_name]) as GDScript).new()
			node.name = node_name
			tree.get_root().add_child(node)


func _ele(p_id: StringName) -> TraitData:
	return load("res://resources/traits/%s.tres" % String(p_id)) as TraitData


# ══ GameLoop 引导（main.tscn 实例 + start_run + MENU 冻结——w5/mirror_muzzle 范式） ══
func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_gl.player.set("max_hp", 1000000.0)
	_gl.player.set("hp", 1000000.0)
	_gl.player.set("unlocked_slots", 6)
	_gl.state = GameConst.GameStatus.MENU      # 冻结波次刷怪（用例自管夹具敌）
	_fx0 = clampi(int(Meta.settings("fx_quality")), 0, 2)
	_char0 = Meta.character_id
	_wave20_0 = bool(Meta.achievements_done.get("wave_20", false))
	_check("Boot：start_run 就绪（玩家 + 默认武器 ≥1 + menu/hud 注入）",
		_gl.player != null and (_gl.player.get("weapon_slots") as Array).size() >= 1
		and _gl.registry != null and _gl.menu_screen != null)


func _teardown_game_loop() -> void:
	tree.paused = false
	Meta.set_setting("fx_quality", _fx0)
	RunSave.clear()                            # 局内存档清档（防测试残留污染继续入口）
	if _gl != null:
		_gl.free()
		_gl = null


func _wipe_weapons() -> void:
	# 用例隔离：镜面全清 + 武器槽清空（保留槽位解锁）+ 指向锁/反应注册表复位
	_gl.player.clear_mirrors()
	_gl.player.call(&"set_mirror_locked", false)
	_gl.elemental.clear_reaction_mults()
	var slots: Array = _gl.player.get("weapon_slots")
	for i in range(slots.size()):
		var w: Variant = slots[i]
		if w != null and is_instance_valid(w):
			slots[i] = null
			(w as Node).queue_free()
	_gl.player.unlocked_slots = 6


func _add(p_id: StringName) -> WeaponBase:
	return _gl.player.add_weapon(_gl.registry.get_weapon(p_id))


func _make_prism() -> MirrorWeapon:
	# 棱镜装配（真件 MirrorWeapon——生产形态；注入包透传 player._deps）
	var prism := MirrorWeapon.new()
	prism.setup(_gl.registry.get_weapon(&"W5_prism"), _gl.player, _gl.player.get("_deps"))
	prism.meta_atk_pct = 0.0
	if not _gl.player.equip_weapon(prism):
		prism.free()
		return null
	prism.sync_mirrors(true)
	return prism


func _drive(p_frames: int, p_dt: float = DT60) -> void:
	for i in range(p_frames):
		GameConfig.advance_frame()
		_gl.player.call(&"tick", p_dt, Vector2.ZERO)


func _layer() -> Node:
	for c in _gl.player.get_children():
		if c is WeaponOrbitAvatars:
			return c
	return null


func _layer_process(p_frames: int, p_dt: float = DT60) -> void:
	# 化身惰性创建 + 公转/朝向同步（无头需手动驱动——weapon_orbit_cases 先例）
	var layer := _layer()
	if layer != null:
		for i in range(p_frames):
			layer.call("_process", p_dt)


func _entries() -> Array:
	var layer := _layer()
	if layer == null:
		return []
	return layer.call("_entries_of", _gl.player)


func _fixture_enemy(p_id: StringName, p_hp: float) -> EnemyData:
	var d := EnemyData.new()
	d.id = p_id
	d.display_name = String(p_id)
	d.hp_base = p_hp
	d.spd_base = 0.0
	d.dmg_base = 0.0
	d.exp_base = 1.0
	d.hitbox_r = 14.0
	d.resist = [0.0, 0.0, 0.0, 0.0]
	return d


func _spawn_fixtures(p_positions: Array[Vector2]) -> Array[Node2D]:
	var out: Array[Node2D] = []
	for pos in p_positions:
		var enemy := (_gl.pools[&"enemy"] as EnemyPool).acquire()
		enemy.spawn(_fixture_enemy(&"E_R191_FIXTURE", 100000.0), 1, 0)
		enemy.position = pos
		out.append(enemy)
	_gl.enemy_grid.rebuild(out)
	return out


func _release_fixtures(p_enemies: Array[Node2D]) -> void:
	for e in p_enemies:
		if e != null and is_instance_valid(e):
			(_gl.pools[&"enemy"] as EnemyPool).release(e)
	_gl.enemy_grid.rebuild([] as Array[Node2D])


func _live_children(p_node: Node) -> int:
	var n := 0
	for c in p_node.get_children():
		if not c.is_queued_for_deletion():
			n += 1
	return n


func _purge_ach_toasts() -> void:
	# 立即摘除现存 AchToast（queue_free 帧末才删，按名收集会撞旧件——测试隔离用）
	for c in _gl.hud.get_children():
		if c is Label and String(c.name) == "AchToast":
			_gl.hud.remove_child(c)
			c.free()


# ══ A. tips｜theme 全局 tooltip + 源级验收（R191#1） ═════════════════
func _test_tips_theme_sources() -> void:
	print("── A. tips：StickerTheme tooltip 条目 + 源级验收 ──")
	var t := StickerTheme.theme()
	_check("A1 theme() 注册 TooltipPanel panel 条目", t.has_stylebox("panel", "TooltipPanel"))
	if t.has_stylebox("panel", "TooltipPanel"):
		var sb := t.get_stylebox("panel", "TooltipPanel") as StyleBoxFlat
		_check("A2 TooltipPanel 白实底（PANEL + a≥1）+ 内容边距 12/12/6/8",
			sb != null and sb.bg_color == PopPalette.PANEL and sb.bg_color.a >= 1.0
			and sb.content_margin_left == 12.0 and sb.content_margin_right == 12.0
			and sb.content_margin_top == 6.0 and sb.content_margin_bottom == 8.0,
			str(sb.bg_color if sb != null else Color()))
	_check("A3 TooltipLabel：色=INK + 字号≥20 + 描边 0（对齐 Label 口径）",
		t.has_color("font_color", "TooltipLabel")
		and t.get_color("font_color", "TooltipLabel") == PopPalette.INK
		and t.has_font("font", "TooltipLabel")
		and t.get_font_size("font_size", "TooltipLabel") >= 20
		and t.get_constant("outline_size", "TooltipLabel") == 0)
	_check("A4 project.godot 无 [gui] 工程主题（全代码构建主题路线不变）",
		not _read_text("res://project.godot").contains("[gui]"))
	_check("A5 hud.gd p_tip 死路径全删（grep==0；签名收缩 + R10 过时注释同删）",
		_read_text("res://scripts/ui/hud.gd").contains("p_tip") == false)
	_check("A6 pause_overlay.gd 接入 weapon_note 真源（grep≥1）",
		_read_text("res://scripts/ui/pause_overlay.gd").contains("weapon_note"))
	var hits := _scan_scripts_with(["TooltipPanel", "TooltipLabel"] as Array)
	var only_theme := hits.size() == 1 and hits[0].ends_with("scripts/ui/theme.gd")
	_check("A7 TooltipPanel/TooltipLabel 全 scripts 仅 theme.gd 命中（一处生效全 UI 继承）",
		only_theme, str(hits))


# ══ B. codex_rxn｜reaction_note 文案单源（R191#5 数据侧） ════════════
func _rxn_keys() -> Array:
	# ReactionType 声明序键名（图鉴行建同源；禁硬编码键清单——R192 动态口径）
	var out: Array = []
	for k in GameConst.ReactionType:
		out.append(String(k))
	return out


func _test_reaction_note_source() -> void:
	print("── B. GameConst.reaction_note 全键文案单源（R192 动态枚举） ──")
	var keys := _rxn_keys()
	var all_ok := true
	var detail := ""
	for k in keys:
		var n: Dictionary = GameConst.reaction_note(k)
		if not (String(n.get("name", "")) != "" and String(n.get("recipe", "")) != ""
				and String(n.get("effect", "")) != "" and String(n.get("unlock", "")) != ""
				and String(n.get("mult_fmt", "")) != "" and String(n.get("sample", "")) != ""
				and (n.get("elements", []) as Array).size() == 2):
			all_ok = false
			detail = k
	_check("B1 全键 name/recipe/effect/unlock/mult_fmt/sample 非空 + elements 配对", all_ok, detail)
	var n0: Dictionary = GameConst.reaction_note("RXN_FIR_ICE")
	_check("B2 [R192 扩容] 字段封闭集（name/recipe/elements/effect/unlock/mult_fmt/sample 恰 7——无存档键来源）",
		n0.size() == 7 and n0.has_all(
			["name", "recipe", "elements", "effect", "unlock", "mult_fmt", "sample"]))
	_check("B3 坏 id 空字典（不崩）", GameConst.reaction_note("RXN_BAD").is_empty())
	_check("B4 现役三名/配方口径（碎裂/过载/超导 · 火+冰/火+雷/冰+雷）",
		String(n0["name"]) == "碎裂" and String(n0["recipe"]) == "火 + 冰"
		and String(GameConst.reaction_note("RXN_FIR_LTG")["name"]) == "过载"
		and String(GameConst.reaction_note("RXN_FIR_LTG")["recipe"]) == "火 + 雷"
		and String(GameConst.reaction_note("RXN_ICE_LTG")["name"]) == "超导"
		and String(GameConst.reaction_note("RXN_ICE_LTG")["recipe"]) == "冰 + 雷")
	# B5 真条件全键覆盖；优先级句按 R192 新序=头部相对位（碎裂<过载<超导）——
	# 相对序动态断言：句式随矩阵扩序演化（碎裂>蒸发>…>过载>…>超导）仍恒真
	var cond_ok := true
	for k2 in keys:
		var eff := String(GameConst.reaction_note(k2)["effect"])
		if not (eff.contains("双槽附着") and eff.contains("2s 冷却")
				and eff.contains("免疫怪拒附着") and not eff.contains("难度")):
			cond_ok = false
	_check("B5 效果句含真条件（双槽/2s CD/免疫拒附）且无难度门文案（rxn 审计口径·全键）", cond_ok)
	var eff0 := String(n0["effect"])
	_check("B5b 优先级句新序头部相对位（碎裂<过载<超导——扩序不翻头部）",
		eff0.find("碎裂") >= 0 and eff0.find("碎裂") < eff0.find("过载")
			and eff0.find("过载") < eff0.find("超导"))
	_check("B6 解锁句节奏 = MechanicGate.MAP_INTROS（火冰第 2 关 / 感电第 3 关）",
		String(GameConst.reaction_note("RXN_FIR_ICE")["unlock"]).contains("第 2 关")
		and String(GameConst.reaction_note("RXN_FIR_LTG")["unlock"]).contains("第 3 关")
		and String(GameConst.reaction_note("RXN_ICE_LTG")["unlock"]).contains("第 3 关"))
	# B7 [R192] 旧三键样张单源逐字锁（wire T1：1284 / 976 / 超导二字）；新键由 B1 全键非空覆盖
	_check("B7 旧三键样张单源（碎裂1284 / 过载976 / 超导）",
		String(n0["sample"]) == "1284"
		and String(GameConst.reaction_note("RXN_FIR_LTG")["sample"]) == "976"
		and String(GameConst.reaction_note("RXN_ICE_LTG")["sample"]) == "超导")


# ══ C. rxn｜registry 数据 + 挂载形态门 + 无难度门节奏（R191#4 数据/门侧） ══
func _form_weapon(p_form: int) -> WeaponBase:
	# p_form 锁 WeaponBase——真件武器仅 setup 不开火（四形态 setup 均无池依赖；pkg3 同构）
	var d := WeaponData.new()
	d.id = StringName("W_RXN_FORM_%d" % p_form)
	d.form = p_form
	var w: WeaponBase
	match p_form:
		GameConst.WeaponForm.BALLISTIC:
			w = BallisticWeapon.new()
		GameConst.WeaponForm.HOMING:
			w = HomingWeapon.new()
		GameConst.WeaponForm.LASER:
			w = LaserWeapon.new()
		_:
			w = OrbitWeapon.new()
	tree.get_root().add_child(w)
	w.setup(d, null, {})
	return w


func _test_rxn_data_and_gates() -> void:
	print("── C. rxn：registry 数据 + 挂载形态门四向 + 无难度门节奏 ──")
	var registry := DataRegistry.new()
	registry.load_all("res://data/manifest.cfg")   # 生产同路径（含 DataValidator 全量校验）
	for id in [&"ELE_IGNITE", &"ELE_SHOCK", &"ELE_FREEZE"]:
		var td := registry.get_trait(id)
		var forms: Variant = td.params.get("required_forms", null) if td != null else null
		_check("C1 registry：%s 在册且 required_forms == [0, 1, 2]（近战死卡下架）" % id,
			td != null and forms is Array and (forms as Array) == [0, 1, 2], str(forms))
	for id2 in [&"ELE_REACTION_VOID", &"ELE_ARC_SURGE"]:
		var td2 := registry.get_trait(id2)
		_check("C2 registry：%s 无 required_forms 键（全形态保留，不设门）" % id2,
			td2 != null and not (td2 as TraitData).params.has("required_forms"))
	var arc := registry.get_trait(&"ELE_ARC_SURGE")
	_check("C3 ELE_ARC_SURGE 描述含「（不附着雷元素）」（防误当电元素卡——文案留 .tres 真源）",
		arc != null and String(arc.description).contains("（不附着雷元素）"),
		arc.description if arc != null else "<null>")
	var ignite := registry.get_trait(&"ELE_IGNITE")
	var freeze := registry.get_trait(&"ELE_FREEZE")
	var shock := registry.get_trait(&"ELE_SHOCK")
	_check("C4 元素键位锚（IGNITE=FIR / FREEZE=ICE / SHOCK=LTG）",
		ignite != null and freeze != null and shock != null
		and int(ignite.params.get("element", -1)) == GameConst.Element.FIR
		and int(freeze.params.get("element", -1)) == GameConst.Element.ICE
		and int(shock.params.get("element", -1)) == GameConst.Element.LTG)
	for id3 in [&"ELE_IGNITE", &"ELE_SHOCK", &"ELE_FREEZE"]:
		var t3 := _ele(id3)
		var gate_ok := true
		for form: int in [GameConst.WeaponForm.BALLISTIC, GameConst.WeaponForm.LASER,
				GameConst.WeaponForm.HOMING]:
			var w := _form_weapon(form)
			gate_ok = gate_ok and CardGenerator.mount_gate_allows(t3, w)
			w.free()
		_check("C5 形态门：%s 投射物三形态（弹道/激光/自导）全放行" % id3, gate_ok)
		var melee := _form_weapon(GameConst.WeaponForm.MELEE)
		_check("C6 形态门：%s 近战拒绝上架（W8 附着 R186 有意拆除）" % id3,
			not CardGenerator.mount_gate_allows(t3, melee))
		melee.free()
	# 无难度门（rxn 仲裁口径：反应无难度/等级门，唯一门=卡架来源侧——结算核每帧无条件运行）
	Meta.set_run_map(&"")                      # 无局口径注入（_run_map 默认 FIRST_MAP_ID）
	_check("C7 无难度门：无局口径全开（map_index = -1，结算核零难度分支）",
		MechanicGate.map_index() == -1 and MechanicGate.elements_basic_unlocked()
		and MechanicGate.shock_unlocked())
	Meta.set_run_map(MapTable.MAPS[1].id)      # 第 2 关寒霜冰原
	_check("C8 第 2 关：火/冰开放；感电未解锁（雷第 3 关起——卡池节奏非难度锁）",
		MechanicGate.elements_basic_unlocked() and not MechanicGate.shock_unlocked())
	Meta.set_run_map(MapTable.MAPS[2].id)      # 第 3 关紫晶魔域
	_check("C9 第 3 关：感电开放（过载/超导随之可发生）", MechanicGate.shock_unlocked())
	Meta.set_run_map(&"")                      # 还原无局口径（防跨套件污染）


# ══ A（行为级）. tips｜构筑详情卡 weapon_note 原句 + 布局契约 ═════════
func _test_tips_detail_card() -> void:
	print("── A10~A13 tips：详情卡机制句（GameConst.weapon_note 真源） ──")
	_gl.state = GameConst.GameStatus.PLAYING
	_gl.hud.build_details_requested.emit()     # 生产路径：点击左下角 → 暂停 + 详情卡
	_check("A10 点击构筑 → PAUSED + 详情卡可见",
		_gl.state == GameConst.GameStatus.PAUSED and _gl.pause_overlay.is_details_visible())
	var list: Control = _gl.pause_overlay._details_list
	var sections: Array = []
	if list != null:
		for c in list.get_children():
			if c is VBoxContainer:
				sections.append(c)             # 武器区块（属性/遗物/通用段为 Panel 直挂不混入）
	var slots: Array = _gl.player.get("weapon_slots")
	var held: Array = []
	for w in slots:
		if w is WeaponBase and is_instance_valid(w) and (w as WeaponBase).get("data") != null:
			held.append(w)
	_check("A11 武器区块数 == 已持武器数", sections.size() == held.size(),
		"sections=%d held=%d" % [sections.size(), held.size()])
	var idx := 0
	for w in held:
		var wid := String((w as WeaponBase).get("data").get("id"))
		var note := GameConst.weapon_note(wid)
		if note.is_empty() or idx >= sections.size():
			idx += 1
			continue                           # 未知 id 空句护栏（不加行）不逐字断言
		var section: VBoxContainer = sections[idx]
		var note_label := _find_label_equal(section, note)
		_check("A12 武器 %s 区块含 weapon_note 原句（逐字相等——UI 零手抄）" % wid,
			note_label != null)
		if idx == 0 and note_label != null:
			# 布局契约（autowrap 行高引擎按行数强制最小——高断言取不小于请求行高）
			var head := section.get_child(0) as Panel
			_check("A13 机制句行 (58,62) 宽 508 + WORD_SMART + 12pt INK_SOFT + IGNORE + head 100",
				note_label.position == Vector2(58.0, 62.0)
				and note_label.size.x == 508.0 and note_label.size.y >= 34.0
				and note_label.autowrap_mode == TextServer.AUTOWRAP_WORD_SMART
				and int(note_label.get_theme_font_size("font_size")) == 12
				and note_label.get_theme_color("font_color") == PopPalette.INK_SOFT
				and note_label.mouse_filter == Control.MOUSE_FILTER_IGNORE
				and head != null and head.custom_minimum_size == Vector2(576.0, 100.0),
				"%s/%s" % [str(note_label.position), str(note_label.size)])
		idx += 1
	_gl.pause_overlay.resume_requested.emit()
	_check("A14 继续恢复 PLAYING（不滞留暂停）",
		_gl.state == GameConst.GameStatus.PLAYING)
	_gl.state = GameConst.GameStatus.MENU      # 还原冻结（后续战斗用例自管节拍）


func _find_label_equal(p_node: Node, p_text: String) -> Label:
	for c in p_node.get_children():
		if c is Label and (c as Label).text == p_text:
			return c as Label
		var sub := _find_label_equal(c, p_text)
		if sub != null:
			return sub
	return null


# ══ E. mirror_laser｜W4 源镜面五缺陷修复（R191#3） ═══════════════════
func _test_mirror_laser_w4() -> void:
	print("── E. mirror_laser：tick_atk meta 轴 / 缓存失效 / 束卡锁 W4 / 束染 ──")
	_wipe_weapons()
	_gl.player.rof_mult = 1.0
	var w4 := _add(&"W4_pulse_beam")           # 源武器（L1 base_atk=6，meta=0 夹具）
	if w4 != null:
		w4.meta_atk_pct = 0.0
		w4.cooldown_left = 9999.0              # 源静默（池账 +1 断言隔离）
	var prism := _make_prism()
	if prism != null:
		prism.cooldown_left = 9999.0           # 棱镜锚束静默（同上）
	_check("E0 前置：W4 源 + 棱镜装配且 1 镜位指向 W4",
		w4 != null and prism != null and prism.mirrors.size() == 1
		and prism.mirrors[0].source_id() == &"W4_pulse_beam")
	if w4 == null or prism == null or prism.mirrors.is_empty():
		_wipe_weapons()
		return
	var img: MirrorImage = prism.mirrors[0]
	var inner := img.inner
	# 修① meta 轴（单元口）：_tick_atk = get_current_atk ×(1+meta_atk_pct)——此前裸表值零消费
	w4.meta_atk_pct = 0.5
	var cur: float = w4.get_current_atk()
	var ticked: float = w4.call("_tick_atk")
	_check("E1 修①：Laser._tick_atk == get_current_atk×(1+meta_atk_pct)（meta=0.5 → ×1.5）",
		cur > 0.0 and _approx(ticked, cur * 1.5, 0.000001),
		"%.6f vs %.6f" % [ticked, cur * 1.5])
	w4.meta_atk_pct = 0.0
	# 修④ 束染构造口：make_mirror_image 产物 copy_tint == true（bool——此前写 Color 被
	# 类型化 bool 字段静默丢弃，镜面 W4 束恒玩家蓝）
	_check("E2 修④：inner.copy_tint == true（bool 类型，非 Color no-op）",
		inner != null and typeof(inner.get("copy_tint")) == TYPE_BOOL
		and bool(inner.get("copy_tint")),
		str(typeof(inner.get("copy_tint")) if inner != null else -1))
	# 修② 引擎侧防御：MirrorWeapon.setup 尾 sub_beams_override = 0（束段指纹硬保证）
	_check("E3 修②：MirrorWeapon.setup 后 sub_beams_override == 0",
		int(prism.get("sub_beams_override")) == 0)
	if inner == null:
		_wipe_weapons()
		return
	# 镜面出束：夹具敌 + 玩家驱动 → inner 主束入共享 laser 池（源/棱镜静默隔离）
	var pool := _gl.pools[&"laser"] as LaserBeamPool
	var live0: int = int(pool.stats()["live"])
	_gl.player.position = Vector2(360.0, 900.0)
	var fixtures := _spawn_fixtures([Vector2(360.0, 700.0)] as Array[Vector2])
	_drive(60)                                 # 0.5s @120Hz：镜面首拍即开火
	var live1: int = int(pool.stats()["live"])
	_check("E4 修①（端到端口）：镜面开火后共享 laser 池活束数 +1（源/棱镜静默隔离）",
		live1 == live0 + 1, "%d→%d" % [live0, live1])
	var mbeam: LaserBeam = null
	for b in pool.get_children():
		if b is LaserBeam and (b as LaserBeam).is_live() and (b as LaserBeam).weapon == inner:
			mbeam = b
	var expect_atk := float(w4.get_stat(&"base_atk")) * 0.40
	_check("E5 修①：镜面束 tick_atk == 源 base_atk×0.40 ±1e-6（meta=0 夹具，6×0.40=2.4）",
		mbeam != null and absf(mbeam.tick_atk - expect_atk) <= 0.000001,
		"%.6f vs %.6f" % [mbeam.tick_atk if mbeam != null else -1.0, expect_atk])
	_check("E6 修④传导：镜面束 gray_tint == true（R183 灰染通道）",
		mbeam != null and mbeam.gray_tint)
	_release_fixtures(fixtures)
	# 修③ apply_state 面板缓存失效：挂 crit/atk 卡 + sync_mirrors(true) → 快照随新栈聚合
	var crit := _gl.registry.get_trait(&"AFF_CRIT_RATE")
	var atk := _gl.registry.get_trait(&"AFF_ATK_UP")
	_check("E7 前置：AFF_CRIT_RATE(add_crit)/AFF_ATK_UP(add_atk) 在册",
		crit != null and String(crit.pool_id) == "add_crit"
		and atk != null and String(atk.pool_id) == "add_atk")
	if crit == null or atk == null:
		_wipe_weapons()
		return
	var old_snap: Dictionary = inner.build_panel_snapshot()
	var old_outer: Dictionary = img.build_panel_snapshot()
	prism.attach_trait(crit)
	prism.attach_trait(atk)
	prism.sync_mirrors(true)                   # 复用镜位 apply_state 重铺（新栈 copy_full）
	var agg: Dictionary = inner.trait_stack.aggregate_panel()
	var crit_cap := 1.0
	if GameConfig.balance != null:
		crit_cap = GameConfig.balance.cap_crit_rate
	var expect_crit := clampf(float(w4.data.crit_rate) + float(agg.get("add_crit", 0.0)),
		0.0, crit_cap)
	var snap: Dictionary = inner.build_panel_snapshot()
	var entries: Array = snap.get("add_entries", []) as Array
	_check("E8 修③：apply_state 后 inner 面板随新栈（crit=新聚合值且非旧值 + add_entries 非空）",
		absf(float(snap.get("crit_rate", -1.0)) - expect_crit) <= 0.000001
		and absf(float(snap.get("crit_rate", -1.0))
			- float(old_snap.get("crit_rate", -2.0))) > 0.000001
		and entries.size() == (inner.trait_stack.aggregate_add_entries() as Array).size()
		and not entries.is_empty(),
		"new %.4f / old %.4f" % [float(snap.get("crit_rate", -1.0)),
			float(old_snap.get("crit_rate", -2.0))])
	var outer_snap: Dictionary = img.build_panel_snapshot()
	_check("E9 修③：外壳身份壳面板同步失效（crit_rate 同新栈）",
		absf(float(outer_snap.get("crit_rate", -1.0)) - expect_crit) <= 0.000001
		and absf(float(outer_snap.get("crit_rate", -1.0))
			- float(old_outer.get("crit_rate", -2.0))) > 0.000001)
	# 修② 兜底口：直挂 SPLIT_PRISM（attach_trait 不经门）→ 棱镜活束仍 ==1
	var split := _gl.registry.get_trait(&"MEC_SPLIT_PRISM")
	if split != null:
		prism.cooldown_left = 0.0
		prism.attach_trait(split)
		prism.try_fire()
		_check("E10 修②：直挂 SPLIT_PRISM 后棱镜活束 ==1（sub_beams_override==0 硬保证）",
			int(prism.get("sub_beams_override")) == 0
			and _live_beams(prism).size() == 1,
			"override=%d beams=%d" % [int(prism.get("sub_beams_override")),
				_live_beams(prism).size()])
	# 修② 数据侧：七张束卡 mount 门对 W5_prism 全 false / 对 W4 全 true + .tres 双证
	var gate_ok := true
	var gate_detail: Array[String] = []
	for cid in BEAM_CARDS:
		var td: TraitData = _gl.registry.get_trait(cid)
		if td == null:
			gate_ok = false
			gate_detail.append("%s:missing" % String(cid))
			continue
		var on_w5 := CardGenerator.mount_gate_allows(td, prism)
		var on_w4 := CardGenerator.mount_gate_allows(td, w4)
		var tres_ok := (td.params.get("required_weapon", []) as Array).has(&"W4_pulse_beam") \
			and (td.params.get("required_forms", []) as Array).has(1)
		if on_w5 or not on_w4 or not tres_ok:
			gate_ok = false
			gate_detail.append("%s:w5=%s/w4=%s/tres=%s" % [String(cid), str(on_w5),
				str(on_w4), str(tres_ok)])
	_check("E11 修②：七束卡 mount 门（W5 全 false / W4 全 true）+ params 均含 required_weapon=W4（原键保留）",
		gate_ok, str(gate_detail))
	# 修⑤ r187 用例体中断修复（源级）：excl 显式类型化 Array[int]
	var r187 := _read_text("res://tests/runner/r187_rework_cases.gd")
	_check("E12 修⑤：r187_rework_cases excl 显式类型化（SCRIPT ERROR 中断不再复发）",
		r187.contains("var excl: Array[int]"),
		"nearest_unhit=%d 处" % _count_occurrences(r187, "_nearest_unhit"))
	_wipe_weapons()


func _live_beams(p_w: WeaponBase) -> Array:
	var out: Array = []
	var beams_v: Variant = p_w.get("active_beams")
	if not (beams_v is Array):
		return out
	for b in (beams_v as Array):
		if b != null and is_instance_valid(b) and b.is_live():
			out.append(b)
	return out


# ══ D. muzzle｜镜面锚点 + 火花 + R183 副本零变化（R191#2） ═══════════
func _test_muzzle_anchor_and_spark() -> void:
	print("── D. muzzle：镜面弹出生点 = 外层化身枪口 + 镜面火花 ──")
	_wipe_weapons()
	_gl.player.global_position = PLAYER_HOME
	_gl.player.rof_mult = 1.0
	var gatling := _add(&"W2_gatling")
	var prism := _make_prism()
	_check("D0 前置：W2 源 + 棱镜装配且 1 镜位指向 W2",
		gatling != null and prism != null and prism.mirrors.size() == 1
		and prism.mirrors[0].source_id() == &"W2_gatling")
	if gatling == null or prism == null or prism.mirrors.is_empty():
		_wipe_weapons()
		return
	var img: MirrorImage = prism.mirrors[0]
	var inner := img.inner
	_layer_process(3)                          # 显式驱动建化身（无头先例口径）
	var layer := _layer()
	var avatars: Array = layer.get("_avatars") if layer != null else []
	var idx: int = _entries().find(img)
	_check("D0b 前置：包装体入册且化身已建可见（修复前 inner 恒查无此件）",
		idx >= 0 and idx < avatars.size() and (avatars[idx] as Sprite2D).visible)
	if layer == null or idx < 0:
		_wipe_weapons()
		return
	var fixtures := _spawn_fixtures([Vector2(360.0, 300.0)] as Array[Vector2])
	_gl.player.rof_mult = 10.0                 # 镜面节拍推到钳 30/s（采样量）
	_gl.player.refresh_weapon_intervals()
	_warm_avatar_angle(layer, SAFE_THETA)      # 标定进安全弧（全程避开几何近点）
	var res := {"n": 0, "max_anchor": 0.0, "min_diamond": INF, "min_player": INF, "bad": ""}
	for f in range(ANCHOR_FRAMES):
		layer.call("_process", DT60)
		var oracle_v: Variant = layer.call("avatar_global", img)
		if oracle_v == null:
			continue
		var oracle: Vector2 = oracle_v
		GameConfig.advance_frame()
		_gl.player.call(&"tick", DT60, Vector2.ZERO)
		for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
			var pb := p as ProjectileBase
			if pb == null or pb.team != 0 or pb.weapon_uid != inner.uid:
				continue
			var sp: Vector2 = pb.global_position
			res["n"] = int(res["n"]) + 1
			var d_anchor := sp.distance_to(oracle)
			res["max_anchor"] = maxf(float(res["max_anchor"]), d_anchor)
			res["min_diamond"] = minf(float(res["min_diamond"]), sp.distance_to(inner.global_position))
			res["min_player"] = minf(float(res["min_player"]), sp.distance_to(_gl.player.global_position))
			if d_anchor > ANCHOR_EPS and String(res["bad"]) == "":
				res["bad"] = "f=%d spawn=%s oracle=%s" % [f, str(sp), str(oracle)]
			pb.call("nullify")                  # 采样即消弹（活表恒净——下拍匹配者必为新弹）
	_check("D1 采样量 ≥30 发（30/s 钳 × 2.5s 窗）", int(res["n"]) >= 30, str(res["n"]))
	_check("D2 逐发 |出生点−avatar_global(外层包装体)| ≤ %.1fpx（修复前 ≈82~112px）" % ANCHOR_EPS,
		int(res["n"]) > 0 and float(res["max_anchor"]) <= ANCHOR_EPS,
		"max=%.4f %s" % [float(res["max_anchor"]), str(res["bad"])])
	_check("D3 负例：逐发距菱形回退位 ≥%.0fpx（确已换锚非回退）" % FALLBACK_MIN,
		int(res["n"]) > 0 and float(res["min_diamond"]) >= FALLBACK_MIN,
		"min=%.1f" % float(res["min_diamond"]))
	_check("D4 负例：逐发距玩家中心 ≥%.0fpx（非玩家中心回退）" % FALLBACK_MIN,
		int(res["n"]) > 0 and float(res["min_player"]) >= FALLBACK_MIN,
		"min=%.1f" % float(res["min_player"]))
	_gl.player.rof_mult = 1.0
	_gl.player.refresh_weapon_intervals()
	# 镜面火花：ice_shard + MirrorImage.TINT + 0.09s（本体 star/0.05s 零回归）
	Meta.set_setting("fx_quality", 2)
	img.cooldown_left = 0.0
	_drive(1)
	var flash: Sprite2D = inner.get("_muzzle_flash")
	_check("D5 镜面开火建常驻 MuzzleFlash 且显形", flash != null and bool(flash.visible))
	_check("D6 镜面火花 texture == TextureFactory.ice_shard() + modulate == MirrorImage.TINT",
		flash != null and flash.texture == TextureFactory.ice_shard()
		and flash.modulate == MirrorImage.TINT,
		str(flash.modulate) if flash != null else "-")
	_check("D7 镜面火花 _muzzle_timer > 0（0.09s 读出口径）",
		flash != null and float(inner.get("_muzzle_timer")) > 0.0,
		"%.4f" % float(inner.get("_muzzle_timer")) if flash != null else "-")
	_release_fixtures(fixtures)
	_drive(14)                                 # 0.233s > 0.09s → 自熄
	_check("D8 镜面火花自熄（visible == false）", flash != null and not bool(flash.visible))
	fixtures = _spawn_fixtures([Vector2(360.0, 300.0)] as Array[Vector2])
	gatling.cooldown_left = 0.0
	_drive(1)
	var gflash: Sprite2D = gatling.get("_muzzle_flash")
	_check("D9 本体零回归：star(40, XP) + 显形 + 0.05s 计时",
		gflash != null and gflash.texture == TextureFactory.star(40, PopPalette.XP)
		and bool(gflash.visible) and float(gatling.get("_muzzle_timer")) > 0.0)
	# fx 低档门：fx_quality=0 → 开火路径可达但火花恒隐（既有门不放宽）
	_release_fixtures(fixtures)
	_drive(14)
	Meta.set_setting("fx_quality", 0)
	fixtures = _spawn_fixtures([Vector2(360.0, 300.0)] as Array[Vector2])
	img.cooldown_left = 0.0
	var fired := false
	_drive(1)
	for p2 in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
		var pb2 := p2 as ProjectileBase
		if pb2 != null and pb2.team == 0 and pb2.weapon_uid == inner.uid:
			fired = true
			pb2.call("nullify")
	_check("D10 fx_quality=0 门：开火路径到达且火花恒隐（门不放宽）",
		fired and flash != null and not bool(flash.visible))
	Meta.set_setting("fx_quality", _fx0)
	# 零逐发实例化：连发后 MuzzleFlash 子节点恒 1
	img.cooldown_left = 0.0
	_drive(24)
	var flash_count := 0
	for c in inner.get_children():
		if c is Sprite2D and String(c.name) == "MuzzleFlash":
			flash_count += 1
	_check("D11 连发后 MuzzleFlash 子节点恒 1（零逐发实例化）", flash_count == 1, str(flash_count))
	_release_fixtures(fixtures)
	# R183 负例：帧内副本首次 find 即命中——别名分支零触达（行为前后不变）
	_wipe_weapons()
	_gl.player.global_position = PLAYER_HOME
	Meta.character_id = &"noah"
	Meta.achievements_done["wave_20"] = true   # 诺亚解锁门（w5 用例同口径直授）
	_gl.player.set_character(&"noah")
	_gl.player.set("hp", 1000000.0)
	_gl.player.set("skill_cd_left", 0.0)
	_add(&"W2_gatling")
	_layer_process(3)
	_check("D12 前置：诺亚技能施放（_summon_copies 通道）",
		bool(_gl.player.call(&"activate_skill")))
	_layer_process(3)
	var copies: Array = _gl.player.get("_summon_copies")
	var entries := _entries()
	var copy_ok: bool = not copies.is_empty()
	var copy_detail := "copies=%d" % copies.size()
	for cp in copies:
		var copy := cp as WeaponBase
		if copy == null or not is_instance_valid(copy):
			copy_ok = false
			continue
		var av_v: Variant = _layer().call("avatar_global", copy)
		var wm_v: Variant = _gl.player.call("weapon_muzzle_global", copy)
		if entries.find(copy) < 0 or copy.get_parent() != _gl.player \
				or av_v == null or wm_v == null \
				or (wm_v as Vector2).distance_to(av_v as Vector2) > 0.01:
			copy_ok = false
			copy_detail = "find=%d parent=%s" % [entries.find(copy), str(copy.get_parent())]
		copy.cooldown_left = 0.0
	_check("D13 R183 副本零变化：在册首查命中 + weapon_muzzle_global == 化身枪口",
		copy_ok, copy_detail)
	Meta.character_id = _char0                 # 还原角色与诺亚门（防跨套件污染）
	if _wave20_0:
		Meta.achievements_done["wave_20"] = true
	else:
		Meta.achievements_done.erase("wave_20")
	_gl.player.set_character(_char0)
	_wipe_weapons()


func _warm_avatar_angle(p_layer: Node, p_theta: float) -> void:
	# 推进公转相位至包装体化身角进入 [p_theta, p_theta+0.05)（确定性标定——mirror_muzzle 同式）
	var idx: int = _entries().find(_current_img())
	if idx < 0:
		return
	var n := maxi(_entries().size(), 1)
	var guard := 0
	while guard < 4000:
		var theta: float = fposmod(float(p_layer.get("_spin")) + TAU * float(idx) / float(n), TAU)
		if theta >= p_theta and theta < p_theta + 0.05:
			return
		p_layer.call("_process", DT60)
		guard += 1


func _current_img() -> MirrorImage:
	# 当前用例的包装体（_wipe 后由调用方保证首个镜位即目标）
	var prism: Variant = null
	for w in _gl.player.get("weapon_slots"):
		if w is MirrorWeapon:
			prism = w
			break
	if prism != null and not (prism as MirrorWeapon).mirrors.is_empty():
		return (prism as MirrorWeapon).mirrors[0]
	return null


# ══ G. boomerang｜×5.0 表现层 + 命中盒解耦（R191#7） ═════════════════
func _test_boomerang_scale() -> void:
	print("── G. boomerang：表现层 ×5.0（命中盒不变）+ R77/R78 零冲突 ──")
	_wipe_weapons()
	_gl.player.global_position = PLAYER_HOME
	var boom := _add(&"W10_boomerang")
	_check("G0 前置：W10 装配", boom != null)
	if boom == null:
		_wipe_weapons()
		return
	_drive(1)                                  # 出生位稳定（verify_feedback 同式）
	boom.call("try_fire")
	var proj: ProjectileBase = null
	for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
		var pb := p as ProjectileBase
		if pb != null and pb.team == 0 and pb.get("weapon_ref") == boom:
			proj = pb
	_check("G1 发射产出回旋弹体（_boomerang 标记）",
		proj != null and bool(proj.get("_boomerang")))
	var bsrc := _read_text("res://scripts/combat/projectile/projectile_base.gd")
	_check("G2 源级：BOOM_VIS_MULT := 5.0 且 ×3.4 旧杠杆零残留",
		bsrc.contains("const BOOM_VIS_MULT := 5.0")
		and not bsrc.contains("* 3.4") and not bsrc.contains("×3.4"))
	_check("G3 源级：TEX_SIZE := 64 分母不变（全弹体变体共享）",
		bsrc.contains("const TEX_SIZE := 64"))
	_check("G4 源级：W10_boomerang.tres hitbox_r = 7.0 不变",
		_read_text("res://resources/weapons/W10_boomerang.tres").contains("hitbox_r = 7.0"))
	if proj == null:
		_wipe_weapons()
		return
	var sprite := proj.get("_sprite") as Sprite2D
	_check("G5 弹体视觉 ×5.0：_sprite.scale == 7/32×5（scale_f=effective_radius/(TEX_SIZE×0.5)）",
		sprite != null and is_equal_approx(sprite.scale.x, 7.0 / 32.0 * 5.0),
		"scale.x=%s" % str(sprite.scale.x) if sprite != null else "no-sprite")
	_check("G6 命中盒与视觉解耦：hitbox_radius == 7.0 且 size_mult == 1（碰撞半径不动）",
		_approx(float(proj.hitbox_radius), 7.0, 0.0001) and _approx(float(proj.size_mult), 1.0, 0.0001),
		"hitbox=%s size_mult=%s" % [str(proj.hitbox_radius), str(proj.size_mult)])
	# R77/R78 零冲突：出程定距翻转 + 返航回收（全为位置距离判定，不读 sprite scale）
	var i := 0
	while is_instance_valid(proj) and bool(proj.get("_live")) and i < 160:
		proj.tick(0.016)
		i += 1
		if int(proj.get("_boom_phase")) == 1:
			break
	var phase1 := is_instance_valid(proj) and int(proj.get("_boom_phase")) == 1
	var flown := proj.global_position.distance_to(proj.get("_boom_origin")) \
		if phase1 else -1.0
	var boom_range := float(proj.get("_boom_range")) if phase1 else 0.0
	_check("G7 R78 出程定距甩满才翻转（phase 0→1，距离贴 _boom_range）",
		phase1 and flown >= boom_range - 12.0 and flown <= boom_range + 40.0,
		"i=%d flown=%.0f range=%.0f" % [i, flown, boom_range])
	var j := 0
	while is_instance_valid(proj) and bool(proj.get("_live")) and j < 500:
		proj.tick(0.016)
		j += 1
	_check("G8 R77 返航到手自回收", not is_instance_valid(proj) or not bool(proj.get("_live")),
		"j=%d" % j)
	_wipe_weapons()


# ══ F. achv｜阶梯扩展 + 三修（R191#6） ══════════════════════════════
func _test_achv_all() -> void:
	print("── F. achv：阶梯 ~128 / 手写保留 / 计数接线 / 分页 / toast / 单次落盘 ──")
	var menu := _gl.menu_screen
	_check("F0 前置：大厅 registry 注入", menu.registry != null)
	# —— 表结构不变量 ——
	var achs: Array[Dictionary] = Meta.ACHIEVEMENTS
	var n := achs.size()
	_check("F1 表规模落 120~200 硬区间（裁定 ~128，架构按 500 预留）", n >= 120 and n <= 200, str(n))
	var handwritten := {
		&"first_blood": 10, &"kill_500": 25, &"kill_2000": 60, &"wave_10": 20,
		&"wave_20": 40, &"wave_30": 80, &"level_15": 30, &"weapons_3": 25,
		&"traits_8": 25, &"boss_slay": 30, &"runs_10": 50,
	}
	var hand_ok := true
	var by_id := {}
	for a in achs:
		by_id[String(a.id)] = a
	for hid: StringName in handwritten:
		var a2: Variant = by_id.get(String(hid))
		if a2 == null or int((a2 as Dictionary).get("reward", -1)) != int(handwritten[hid]):
			hand_ok = false
	_check("F2 手写 11 条原 id/原 reward 逐字保留（存档兼容 + noah 门）", hand_ok)
	var uniq := {}
	var reward_ok := true
	for a3 in achs:
		uniq[String(a3.id)] = true
		if not (a3 as Dictionary).has("reward"):
			reward_ok = false                  # 显式 reward 键堵 get("reward",10) 通胀口
	_check("F3 新 id 全局唯一（生成撞档跳过不重复）", uniq.size() == n,
		"uniq=%d n=%d" % [uniq.size(), n])
	_check("F4 全表显式 reward 键（中间档 0 也写——隐性通胀口封死）", reward_ok)
	var enemy_tier_n := 0
	var families := {"enemy_kills": false, "codex_weapons": false,
		"codex_traits": false, "maps_cleared": false}
	for a4 in achs:
		var t := String(a4.type)
		if t == "enemy_kills":
			enemy_tier_n += 1
		if families.has(t):
			families[t] = true
	_check("F5 单敌阶梯 = 29×3 自洽展开 + 收集/地图四族全部在册",
		enemy_tier_n == Meta.ACH_ENEMY_TIERS.size() * Meta.ACH_ENEMY_TARGETS.size()
		and families["enemy_kills"] and families["codex_weapons"]
		and families["codex_traits"] and families["maps_cleared"],
		"enemy=%d" % enemy_tier_n)
	# —— 计数接线（enemy_kills / maps_cleared / 收集族四通道）——
	var bk_done: Dictionary = Meta.achievements_done.duplicate()
	var bk_kills: Dictionary = Meta.codex_kills.duplicate()
	var bk_weps: Dictionary = Meta.codex_weapons.duplicate()
	var bk_traits: Dictionary = Meta.codex_traits.duplicate()
	var bk_maps: Dictionary = Meta.maps_cleared.duplicate()
	var bk_records: Dictionary = Meta.records.duplicate()
	var bk_crystals: int = Meta.crystals
	Meta.achievements_done = {}
	Meta.codex_kills = {}
	Meta.codex_weapons = {}
	Meta.codex_traits = {}
	Meta.maps_cleared = {}
	Meta.records["total_kills"] = 0
	Meta.crystals = 0
	var grunt := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	grunt.spawn(_fixture_enemy(&"E1_grunt", 10.0), 1, 0)
	Meta._on_enemy_killed(grunt)
	_check("F6 接线：击杀 1 → first_blood 解锁（total_kills 桶查）",
		Meta.is_ach_done(&"first_blood"))
	for i in range(49):
		Meta._on_enemy_killed(grunt)
	(_gl.pools[&"enemy"] as EnemyPool).release(grunt)
	_check("F7 接线：单敌 E1_grunt ×50 → enemy_kills_E1_grunt_50 解锁（enemy_kills 桶并入）",
		Meta.is_ach_done(&"enemy_kills_E1_grunt_50"),
		str(Meta.codex_kill_count(&"E1_grunt")))
	Meta.mark_map_cleared(MapTable.MAPS[1].id)
	_check("F8 接线：mark_map_cleared → maps_cleared_1 解锁（地图族桶查）",
		Meta.is_ach_done(&"maps_cleared_1"))
	for wid in [&"W1_pistol", &"W2_gatling", &"W3_shotgun", &"W4_pulse_beam", &"W5_prism"]:
		Meta._on_card_chosen(wid, 4)
	_check("F9 接线：图鉴武器 ×5 → codex_weapons_5 解锁（收集族桶查）",
		Meta.is_ach_done(&"codex_weapons_5"))
	var trait_ids: Array = _gl.registry.traits.keys()
	for i2 in range(mini(10, trait_ids.size())):
		Meta._on_card_chosen(trait_ids[i2], 1)
	_check("F10 接线：图鉴词条 ×10 → codex_traits_10 解锁（收集族桶查）",
		Meta.is_ach_done(&"codex_traits_10"))
	# F11 奖励曲线对账（表驱动神谕）：按 _counter_value 同义语义活算全表——
	# 期望解锁集合 = 计数达档的全链（含选择武器/词条时合法推进的 run_weapons_drawn/
	# run_traits_drawn 族）；结晶增量 == Σ显式 reward（reward=0 中间档不得隐性 +10💎）。
	# 解锁集合与结晶双向对账——比常数增量断言更强，且不硬编码期望集合。
	var counters := {
		"total_kills": int(Meta.records.get("total_kills", 0)),
		"run_wave": int(Meta.get("_run_max_wave")),
		"run_level": int(Meta.get("_run_max_level")),
		"run_weapons_drawn": int(Meta.get("_run_weapons_drawn")),
		"run_traits_drawn": int(Meta.get("_run_traits_drawn")),
		"boss_slain": int(Meta.get("_run_boss_slain")),
		"total_runs": int(Meta.records.get("total_runs", 0)),
		"codex_weapons": Meta.codex_weapons.size(),
		"codex_traits": Meta.codex_traits.size(),
		"maps_cleared": Meta.maps_cleared.size(),
	}
	var expect_ids := {}
	var expect_crystals := 0
	# 仅对账本窗内触发过桶查事件的族（击杀/地图/选卡两收集族/两单局抽取族）——
	# run_wave/run_level/total_runs 的事件（开局波次/升级/结算）未发生，不入神谕
	var fired_families := {"total_kills": true, "enemy_kills": true, "boss_slain": true,
		"maps_cleared": true, "run_weapons_drawn": true, "codex_weapons": true,
		"run_traits_drawn": true, "codex_traits": true}
	for a in Meta.ACHIEVEMENTS:
		var at := String(a.type)
		if not fired_families.has(at):
			continue
		var val: int = int(counters.get(at, 0))
		if at == "enemy_kills":
			val = Meta.codex_kill_count(StringName(String(a.get("enemy", ""))))
		if val >= int(a.target):
			expect_ids[String(a.id)] = true
			expect_crystals += int(a.get("reward", 0))
	var actual_ids := {}
	for aid in Meta.achievements_done.keys():
		actual_ids[String(aid)] = true
	_check("F11 奖励曲线：解锁集合 == 按表活算期望集合（%d 条）且结晶增量 == Σ显式 reward %d💎（隐性通胀口封死）" \
			% [expect_ids.size(), expect_crystals],
		actual_ids == expect_ids and Meta.crystals == expect_crystals,
		"actual=%d expect=%d crystals=%d" % [actual_ids.size(), expect_ids.size(), Meta.crystals])
	# 还原（防污染后续 codex 页零写入断言）
	Meta.achievements_done = bk_done
	Meta.codex_kills = bk_kills
	Meta.codex_weapons = bk_weps
	Meta.codex_traits = bk_traits
	Meta.maps_cleared = bk_maps
	Meta.records = bk_records
	Meta.crystals = bk_crystals
	# —— 分页 + toast 合批 ——
	menu._on_lobby_pressed("ach")
	_check("F12 成就分页：默认页行数 == min(24, N)=%d 且 >0" % mini(24, n),
		_live_children(menu._panel_list) == mini(24, n) and n > 0,
		"live=%d" % _live_children(menu._panel_list))
	# R191 收口 low 回归：页码 Label 旧位 x=136 压进 ◀上一页（右缘 168）描边 30px——
	# 锁死「落在上一页与返回大厅(211 起)之间空当」几何契约，两侧各留 ≥2px
	var pl: Label = menu._ach_page_label
	var pb: Button = menu._ach_prev_btn
	_check("F12a 页码 Label 落空当：x ≥ 上一页右缘+2 且右缘 ≤ 209（返回大厅左缘-2）",
		pl != null and pb != null
			and pl.position.x >= pb.position.x + pb.size.x + 2.0
			and pl.position.x + pl.size.x <= 209.0,
		"label=(%s)" % str(pl.position if pl != null else Vector2.ZERO))
	var acc_all := 0
	var acc_cats := 0
	for tab_name: String in menu._ach_tabs:
		menu._on_ach_tab(tab_name)
		while true:
			if tab_name == "全部":
				acc_all += _live_children(menu._panel_list)
			else:
				acc_cats += _live_children(menu._panel_list)
			if menu._ach_page >= menu._ach_page_count() - 1:
				break
			menu._on_ach_page_next()
	_check("F13 分页遍历累加 == N（全部 %d + 三类别 %d = %d——覆盖语义不弱化）" % [acc_all, acc_cats, n],
		acc_all == n and acc_cats == n)
	menu._on_ach_tab("全部")
	_gl.hud._ach_toast_pending.clear()
	for i3 in range(10):
		Meta.achievements_changed.emit(&"first_blood")
	_gl.hud._flush_achievement_toast()
	var toasts: Array[Label] = []
	for c in _gl.hud.get_children():
		if c is Label and String(c.name) == "AchToast":
			toasts.append(c)
	var toast_txt := String(toasts[0].text) if not toasts.is_empty() else ""
	# R196 有意契约变更（原「合计 +100💎」）：成就 toast emoji 字面量移除（💎/🏆，
	# Android 系统字体链缺字形——apk_menu_no_icons 定案），金额段改「（+%d）」纯数字
	_check("F14 toast 同帧合批：10 连发 → 1 条（含 ×10 与合计 +100，无 💎）",
		toasts.size() == 1 and toast_txt.contains("×10") and toast_txt.contains("+100")
			and not toast_txt.contains("💎"),
		"n=%d txt=%s" % [toasts.size(), toast_txt])
	for t2 in toasts:
		(t2 as Label).queue_free()
	# R191 评审修复回归：①零奖励分支（reward=0 不显示金额——定案「toast 无金额文案」，
	# 此前恒拼「（+0💎）」）；②合批名称截断（旧档批量回填数十条全量拼接超屏不可读）。
	_purge_ach_toasts()
	_gl.hud._ach_toast_pending.clear()
	Meta.achievements_changed.emit(&"total_kills_100")   # 阶梯首档（模板表 rewards[0]=0）
	_gl.hud._flush_achievement_toast()
	var ztxt := ""
	for c4 in _gl.hud.get_children():
		if c4 is Label and String(c4.name) == "AchToast":
			ztxt = String((c4 as Label).text)
	_check("F14a toast 零奖励分支：reward=0 解锁无金额文案（×1 + 名在 + 无 💎）",
		ztxt.contains("×1") and ztxt.contains("小试牛刀") and not ztxt.contains("💎"),
		"txt=%s" % ztxt)
	_purge_ach_toasts()
	_gl.hud._ach_toast_pending.clear()
	Meta.achievements_changed.emit(&"first_blood")       # 初次裂变 +10
	Meta.achievements_changed.emit(&"kill_500")          # 弹幕清道夫 +25
	Meta.achievements_changed.emit(&"wave_10")           # 站稳脚跟 +20（前三名内）
	Meta.achievements_changed.emit(&"level_15")          # 成长曲线（第 4 名——应截）
	Meta.achievements_changed.emit(&"boss_slay")         # 屠戮聚合体（第 5 名——应截）
	_gl.hud._flush_achievement_toast()
	var ctxt := ""
	for c5 in _gl.hud.get_children():
		if c5 is Label and String(c5.name) == "AchToast":
			ctxt = String((c5 as Label).text)
	# R196 有意契约变更（原「+115💎」）：金额段 emoji 移除，其余合批/截断语义不变
	_check("F14b toast 名称截断：5 连发只列前 3 名 +「等 5 项」，金额段完整（+115，无 💎）",
		ctxt.contains("×5") and ctxt.contains("初次裂变") and ctxt.contains("站稳脚跟")
		and ctxt.contains("等 5 项") and not ctxt.contains("成长曲线")
		and not ctxt.contains("屠戮聚合体") and ctxt.contains("+115")
		and not ctxt.contains("💎"),
		"txt=%s" % ctxt)
	_purge_ach_toasts()
	menu._on_panel_close()
	# —— 批量单次落盘（源级：_check_achievements 循环内逐条 _save 移出为函数尾一次）——
	var msrc := _read_text("res://scripts/meta/meta_manager.gd")
	var body := _func_body(msrc, "func _check_achievements(")
	_check("F15 批量单次落盘：_check_achievements 体内 _save() 恰 1 次且在解锁循环后",
		body != "" and _count_occurrences(body, "_save()") == 1
		and body.contains("unlocked_any")
		and body.find("unlocked_any = true") < body.find("_save()"))
	# —— 存档层结构零改动（achievements 段仍只有 done 键）——
	Meta._save()
	var cfg := ConfigFile.new()
	var struct_ok := cfg.load(Meta.save_path()) == OK \
		and cfg.get_section_keys("achievements") != null \
		and (cfg.get_section_keys("achievements") as Array).size() == 1 \
		and (cfg.get_section_keys("achievements") as Array).has("done")
	_check("F16 存档结构零改动：achievements 段仍仅 done 键（id 数组口径）", struct_ok)
	# —— F17 [R192] run_reactions 成就族（run 作用域接线；直调 handler——F6-F10 模式）——
	# ACH_TIER_TABLE +1 条 type=run_reactions targets=[10,25,50] rewards=[0,0,30]：
	# 中间档 0💎（隐性通胀口封死）、仅终档 +30💎；全表条数仍在 F1 区间、总奖励 ≤1500💎；
	# 零存档键（计数不入 _save 九段；F16 结构断言上方已验）。注意 F11 已先行对账还原，
	# 本段在新窗内自备份/自还原——不回灌 F11 的 fired_families 神谕。
	var bk2_done: Dictionary = Meta.achievements_done.duplicate()
	var bk2_crystals: int = Meta.crystals
	var bk2_records: Dictionary = Meta.records.duplicate()
	Meta.achievements_done = {}
	Meta.crystals = 0
	var rr_tiers := 0
	for a7 in Meta.ACHIEVEMENTS:
		if String(a7.type) == "run_reactions":
			rr_tiers += 1
	_check("F17a run_reactions 三档在册（targets 10/25/50）+ F1 表规模续绿（≤200）",
		rr_tiers == 3 and Meta.ACHIEVEMENTS.size() <= 200,
		"tiers=%d n=%d" % [rr_tiers, Meta.ACHIEVEMENTS.size()])
	for i4 in range(10):
		Meta._on_reaction_triggered(GameConst.ReactionType.RXN_FIR_ICE, Vector2.ZERO, 0)
	_check("F17b 直调 reaction_triggered ×10 → run_reactions_10 解锁且结晶 0（中间档零通胀）",
		Meta.is_ach_done(&"run_reactions_10") and Meta.crystals == 0,
		"done=%s crystals=%d" % [str(Meta.is_ach_done(&"run_reactions_10")), Meta.crystals])
	for i5 in range(40):
		Meta._on_reaction_triggered(GameConst.ReactionType.RXN_FIR_LTG, Vector2.ZERO, 0)
	_check("F17c 达 50 → 25/50 档解锁 + 结晶仅终档 +30",
		Meta.is_ach_done(&"run_reactions_25") and Meta.is_ach_done(&"run_reactions_50")
		and Meta.crystals == 30, "crystals=%d" % Meta.crystals)
	var reward_sum := 0
	for a8 in Meta.ACHIEVEMENTS:
		reward_sum += int(a8.get("reward", 0))
	_check("F17d 全表总奖励 ≤1500💎（经济封顶随新族复核）", reward_sum <= 1500, "sum=%d" % reward_sum)
	Meta._settle_run_result()                     # 结算 → 单局计数复位（_reset_run_counters）
	var rr_val: Variant = Meta.get("_run_reactions")
	_check("F17e 结算复位：_run_reactions 字段在且归零（run 作用域零存档迁移）",
		rr_val != null and int(rr_val) == 0, "val=%s" % str(rr_val))
	Meta.achievements_done = bk2_done
	Meta.crystals = bk2_crystals
	Meta.records = bk2_records
	# —— F18 [R198 契约变更新增] boss_slain 档自洽契约锁（R191-low1 口径 11）——
	# 盘点复核证实 ACH_TIER_TABLE boss_slain targets [3,5,8]/rewards [0,0,60]/desc
	# 「单局击败 %d 个 Boss」与 _run_boss_slain 单局化链（声明/递增/每局重置/桶查）已自洽，
	# 本段固化为防回退契约断言（数值仅复核失洽才包络内改排——本轮无失洽，零改动）。
	var bs_tiers: Array[Dictionary] = []
	for a9 in Meta.ACHIEVEMENTS:
		if String(a9.type) == "boss_slain" and int(a9.target) > 1:
			bs_tiers.append(a9)                   # 阶梯档（手写 boss_slay target=1 另计）
	var bs_targets: Array = []
	var bs_desc_ok := true
	for t1 in bs_tiers:
		bs_targets.append(int(t1.target))
		if not String(t1.desc).contains("单局"):
			bs_desc_ok = false
	_check("F18a boss_slain 阶梯档 targets==[3,5,8] 且 desc 均含「单局」（单局口径契约锁）",
		bs_targets == [3, 5, 8] and bs_desc_ok and bs_tiers.size() == 3,
		"targets=%s desc_ok=%s n=%d" % [str(bs_targets), str(bs_desc_ok), bs_tiers.size()])
	var bk3_done: Dictionary = Meta.achievements_done.duplicate()
	var bk3_crystals: int = Meta.crystals
	var bk3_records: Dictionary = Meta.records.duplicate()
	Meta.achievements_done = {}
	Meta.crystals = 0
	Meta._run_boss_slain = 3
	Meta._check_achievements_of([&"boss_slain"])
	_check("F18b 单局击败 3 Boss → boss_slain_3 解锁（_run_boss_slain 桶查接线）",
		Meta.is_ach_done(&"boss_slain_3"))
	Meta._settle_run_result()                     # 结算 → 单局计数复位（含 _run_boss_slain）
	var bs_val: Variant = Meta.get("_run_boss_slain")
	_check("F18c 结算复位：_run_boss_slain 归零（跨局不累加——单局计数不迁存档）",
		bs_val != null and int(bs_val) == 0, "val=%s" % str(bs_val))
	Meta._run_boss_slain = 1
	Meta._check_achievements_of([&"boss_slain"])
	_check("F18d 次局再 1 杀仅按本局计（跨局不累加：余档 5/8 不误解锁）",
		not Meta.is_ach_done(&"boss_slain_5") and not Meta.is_ach_done(&"boss_slain_8"))
	Meta.achievements_done = bk3_done
	Meta.crystals = bk3_crystals
	Meta.records = bk3_records


# ══ codex_rxn（行为级）｜4 页签 + 反应页行级 + 倍率读表 + 零存档写入 ═══
func _test_codex_reaction_page() -> void:
	print("── codex_rxn：4 页签 / 反应页 3 行 / 预览五项 / 倍率运行时读表 ──")
	var menu := _gl.menu_screen
	menu._on_lobby_pressed("codex")
	var tabs: Array = menu._codex_tabs.keys()
	_check("X1 图鉴页签恰 4 枚 = 怪物/武器/词条/反应",
		tabs.size() == 4 and tabs.has("怪物") and tabs.has("武器")
		and tabs.has("词条") and tabs.has("反应"))
	_check("X2 页签几何：宽 126 ·「反应」末沿 486+126=612（右距 36 不变）",
		(menu._codex_tabs["反应"] as Button).size.x == 126.0
		and (menu._codex_tabs["反应"] as Button).position.x == 486.0)
	menu._on_codex_tab("反应")
	var rows: Array = []
	for c in menu._panel_list.get_children():
		if not c.is_queued_for_deletion():
			rows.append(c)
	var n_rxn: int = GameConst.ReactionType.size()
	# [R192 动态] 行数 == 枚举全键；冰草留白标注行（GameConst 新常量、循环后追加）至多 +1
	_check("X3 反应页重建出全枚举条目（ReactionType 序；冰草标注行至多 +1）",
		(rows.size() == n_rxn or rows.size() == n_rxn + 1), str(rows.size()))
	var keys := _rxn_keys()
	var fills := [PopPalette.RXN_FILL_SHATTER, PopPalette.RXN_FILL_OVERLOAD, PopPalette.RXN_FILL_SUPER]
	var lines := [PopPalette.RXN_LINE_SHATTER, PopPalette.RXN_LINE_OVERLOAD, PopPalette.RXN_LINE_SUPER]
	var row_ok := true
	var row_detail := ""
	for i in range(mini(rows.size(), n_rxn)):
		var row: Control = rows[i]
		var rid: String = keys[i]
		var note: Dictionary = GameConst.reaction_note(rid)
		var name_l: Label = row.get_node_or_null("RxnName") as Label
		var desc_l: Label = row.get_node_or_null("RxnDesc") as Label
		var unlock_l: Label = row.get_node_or_null("RxnUnlock") as Label
		var mult_l: Label = row.get_node_or_null("RxnMult") as Label
		var prev: Label = row.get_node_or_null("RxnPreview") as Label
		if name_l == null or desc_l == null or unlock_l == null or mult_l == null or prev == null:
			row_ok = false
			row_detail = rid + " 行内标签缺失"
			continue
		if name_l.text != String(note["name"]) or not desc_l.text.contains(String(note["effect"])) \
				or not unlock_l.text.contains(String(note["unlock"])) or mult_l.text.is_empty():
			row_ok = false
			row_detail = rid + " 文案不同源"
			continue
		var look: Dictionary = DamagePopup.REACTION_LOOKS[int(GameConst.ReactionType.get(rid))]
		# 预览五项 override（照抄 DamagePopup._apply_reaction_look；get_theme_* 命中 override 优先）
		if prev.get_theme_font_size("font_size") != DamagePopup.FONT_SIZE_REACTION \
				or prev.get_theme_constant("outline_size") != DamagePopup.OUTLINE_PX_REACTION \
				or prev.get_theme_color("font_color") != (look["fill"] as Color) \
				or prev.get_theme_color("font_outline_color") != (look["outline"] as Color) \
				or prev.get_theme_font("font") != StickerTheme.font_reaction(int(look["variant"])):
			row_ok = false
			row_detail = rid + " 预览五项参数不符"
			continue
		# 逐行双色/字型对位（旧三键=枚举序前三位 0/1/2 对位 RXN_* 常量）+ 样张==note.sample
		if i < 3 and (prev.get_theme_color("font_color") != fills[i] \
				or prev.get_theme_color("font_outline_color") != lines[i] \
				or prev.get_theme_font("font") != StickerTheme.font_reaction(i)):
			row_ok = false
			row_detail = rid + " 双色/字型错行"
			continue
		# 样张 == 实机同源组合（R192 收口2 用户口径「反应名+数字（包括图鉴）」，与 rxn_codex
		# 同口径：dmg 型名+sample 数值段 / pct·stat 型名+reaction_stat_text 读表段 / 空段只显名）
		var want_txt := String(look["name"]) + (String(note["sample"]) \
			if String(look["fmt"]) == "dmg" else DamagePopup.reaction_stat_text(int(GameConst.ReactionType.get(rid))))
		if prev.text != want_txt:
			row_ok = false
			row_detail = rid + " 样张 != 实机组合（want=%s got=%s）" % [want_txt, prev.text]
	_check("X4 行级：名称/效果/解锁单源 + 预览五项 override + 逐行对位 + 样张==实机组合（%d 行全过）" % n_rxn,
		row_ok and rows.size() >= n_rxn, row_detail)
	# 倍率运行时读表（数值不进文案不硬编码：置 3.5 → 行文含 3.5 → 还原）
	var rt: Dictionary = GameConfig.balance.reaction_table
	var coef0 := float(rt["RXN_FIR_ICE"]["coef"])
	rt["RXN_FIR_ICE"]["coef"] = 3.5
	menu._on_codex_tab("反应")
	var mult0 := _reaction_mult_label(menu)
	_check("X5 倍率跟随表值：coef=3.5 → 碎裂行倍率文本含 3.5",
		mult0 != null and (mult0 as Label).text.contains("3.5"),
		"txt=%s" % ((mult0 as Label).text if mult0 != null else "-"))
	rt["RXN_FIR_ICE"]["coef"] = coef0           # 还原（防进程内数值表污染）
	menu._on_codex_tab("反应")
	var mult1 := _reaction_mult_label(menu)
	_check("X6 还原 coef 后倍率复原（含 %.1f 不含 3.5）" % coef0,
		mult1 != null and (mult1 as Label).text.contains("%.1f" % coef0)
		and not (mult1 as Label).text.contains("3.5"))
	# 反应页开合零存档写入（不新增 Meta 键；「见过即解锁」通道明确不做）
	var snap0 := [Meta.codex_kills.size(), Meta.codex_first_met.size(),
		Meta.codex_weapons.size(), Meta.codex_traits.size(),
		Meta.achievements_done.size()]
	menu._on_codex_tab("怪物")
	menu._on_codex_tab("反应")
	var snap1 := [Meta.codex_kills.size(), Meta.codex_first_met.size(),
		Meta.codex_weapons.size(), Meta.codex_traits.size(),
		Meta.achievements_done.size()]
	_check("X7 反应页开合前后 Meta codex_*/achievements_done 集合零写入", snap0 == snap1)
	menu._on_panel_close()


func _reaction_mult_label(p_menu) -> Label:
	# duck 类型形参（MenuScreen._panel_list——runtime load 环境零静态依赖，rxn_codex 同式）
	var rows: Array = []
	for c in p_menu._panel_list.get_children():
		if not c.is_queued_for_deletion():
			rows.append(c)
	if rows.is_empty():
		return null
	return (rows[0] as Control).get_node_or_null("RxnMult") as Label   # 行序 0 = RXN_FIR_ICE


# ══ H. rxn 端到端｜火+电挂载 → 附着 → 过载触发（R191#4 核心） ════════
var _r_proj_pool: ProjectilePool
var _r_enemy_pool: EnemyPool
var _r_grid: SpaceGrid
var _r_pipeline: DamagePipelineStub
var _r_real: DamagePipeline
var _r_sys: ElementalSystem
var _r_enemies: Array[Node2D] = []


func _test_rxn_end_to_end() -> void:
	print("── H. rxn 端到端：火+电挂载 → 附着 → 过载触发（E-03 帧闸 + CD 2s） ──")
	seed(20260926)
	_setup_rxn_world()
	_test_channel_unit()
	_test_spawn_guard()
	_test_weapon_alternation()
	_test_overload_chain()
	_teardown_rxn_world()


func _setup_rxn_world() -> void:
	_r_proj_pool = ProjectilePool.new()
	_r_proj_pool.name = "R191RxnProjPool"
	tree.get_root().add_child(_r_proj_pool)
	_r_proj_pool.setup(&"r191_rxn", load(PROJ_SCENE), 64)
	var ep := EnemyPool.new()
	ep.name = "R191RxnEnemyPool"
	tree.get_root().add_child(ep)
	ep.setup(&"r191_rxn_enemy", load(ENEMY_SCENE), 16)
	_r_enemy_pool = ep
	_r_grid = SpaceGrid.new()
	_r_grid.configure(Vector2(720, 1280), 192.0)
	_r_pipeline = DamagePipelineStub.new()
	_r_real = DamagePipeline.new()             # 真件：反应结算内部落血
	_r_real.set_rng_seed(42)
	_r_sys = ElementalSystem.new()
	_r_sys.name = "R191RxnElementalSystem"
	tree.get_root().add_child(_r_sys)
	_r_sys.pipeline = _r_real
	_r_sys.enemy_grid = _r_grid
	_r_enemies.clear()


func _teardown_rxn_world() -> void:
	_r_enemies.clear()
	if _r_sys != null:
		_r_sys.free()
		_r_sys = null
	_r_real = null
	if _r_proj_pool != null:
		_r_proj_pool.free()
		_r_proj_pool = null
	if _r_enemy_pool != null:
		(_r_enemy_pool as Node).free()
		_r_enemy_pool = null
	_r_grid = null
	_r_pipeline = null


func _rxn_enemy_data(p_id: String, p_hp: float) -> EnemyData:
	var d := EnemyData.new()
	d.id = StringName(p_id)
	d.display_name = p_id
	d.hp_base = p_hp
	d.spd_base = 0.0                           # 静止敌（几何确定性）
	d.dmg_base = 8.0
	d.exp_base = 3.0
	d.tp_cost = 1.0
	d.hitbox_r = 14.0
	return d


func _rxn_spawn_enemy(p_data: EnemyData, p_pos: Vector2) -> Enemy:
	var e := _r_enemy_pool.acquire() as Enemy
	e.spawn(p_data, 1, 0)
	e.position = p_pos
	_r_enemies.append(e)
	_r_grid.rebuild(_r_enemies)
	return e


func _rxn_spawn_proj(p_params: Dictionary) -> ProjectileBase:
	var proj := _r_proj_pool.acquire() as ProjectileBase
	proj.damage_pipeline = _r_pipeline
	proj.enemy_grid = _r_grid
	proj.pool = _r_proj_pool
	proj.elemental = _r_sys
	proj.spawn(p_params.duplicate())
	return proj


func _rxn_make_weapon_data() -> WeaponData:
	var d := WeaponData.new()
	d.id = &"W_R191_RXN_PROBE"
	d.display_name = "R191 rxn 探针"
	d.form = GameConst.WeaponForm.BALLISTIC
	d.crit_rate = 0.0
	d.crit_dmg = 2.0
	d.hitbox_r = 6.0
	for i in range(5):
		var ls := WeaponLevelStats.new()
		ls.base_atk = 100.0                    # 面板 100 → 过载 100×1.2 = 120（整数好算）
		ls.rof = 5.0
		ls.cd = 0.5
		ls.pierce = 1
		ls.pellets = 1
		d.upgrade_table.append(ls)
	d.ballistic = {"proj_speed": 100.0, "range": 600.0, "spread_deg": 0.0}
	return d


func _rxn_make_weapon() -> BallisticWeapon:
	var w := BallisticWeapon.new()
	w.name = "R191RxnProbeWeapon"
	tree.get_root().add_child(w)
	w.position = Vector2(360, 1100)
	w.setup(_rxn_make_weapon_data(), null, {
		"pipeline": _r_pipeline,
		"projectile_pool": _r_proj_pool,
		"enemy_grid": _r_grid,
		"laser_pool": null,
		"elemental": _r_sys,
	})
	return w


func _dual_stack() -> TraitStack:
	# 双元素栈（挂载序 IGNITE(FIR)→SHOCK(LTG)——生产卡架挂载序即派发序）
	var stack := TraitStack.new()
	stack.attach(_ele(&"ELE_IGNITE"))
	stack.attach(_ele(&"ELE_SHOCK"))
	return stack


func _kill_live_projs() -> void:
	for node in _r_proj_pool.active_projectiles():
		(node as ProjectileBase).nullify()


# ── H1. 通道单元（挂载→派发级：attach_request 按当发宿主元素放行） ──
func _test_channel_unit() -> void:
	print("── H1 通道单元：ON_HIT 按当发宿主元素放行（末位覆写已修） ──")
	var stack := _dual_stack()
	var p_fir := _rxn_spawn_proj({"position": Vector2(150, 150), "velocity": Vector2.ZERO,
		"lifetime": 10.0, "pierce": 1, "hitbox_radius": 6.0,
		"element": GameConst.Element.FIR, "attach_value": 0.0, "team": 0})
	var ctx_fir := TraitContext.new()
	ctx_fir.event = GameConst.TraitEvent.ON_HIT
	ctx_fir.projectile = p_fir
	stack.dispatch(GameConst.TraitEvent.ON_HIT, ctx_fir)
	_check("H1a 火宿主 → attach_request.element == FIR（修复前被挂载序末位覆写为雷）",
		int(ctx_fir.attach_request.get("element", -1)) == GameConst.Element.FIR,
		str(ctx_fir.attach_request))
	_check("H1b 火宿主请求逐字节 == {FIR, 22.0, {}}",
		ctx_fir.attach_request == {"element": GameConst.Element.FIR,
			"value": 22.0, "overrides": {}}, str(ctx_fir.attach_request))
	var p_ltg := _rxn_spawn_proj({"position": Vector2(150, 150), "velocity": Vector2.ZERO,
		"lifetime": 10.0, "pierce": 1, "hitbox_radius": 6.0,
		"element": GameConst.Element.LTG, "attach_value": 0.0, "team": 0})
	_bump_frame()                              # E-03：同栈第二派发须推帧
	var ctx_ltg := TraitContext.new()
	ctx_ltg.event = GameConst.TraitEvent.ON_HIT
	ctx_ltg.projectile = p_ltg
	stack.dispatch(GameConst.TraitEvent.ON_HIT, ctx_ltg)
	_check("H1c 雷宿主 → attach_request.element == LTG（交替发各附当发元素）",
		int(ctx_ltg.attach_request.get("element", -1)) == GameConst.Element.LTG,
		str(ctx_ltg.attach_request))
	var ctx_e03 := TraitContext.new()
	ctx_e03.event = GameConst.TraitEvent.ON_HIT
	ctx_e03.projectile = p_fir
	stack.dispatch(GameConst.TraitEvent.ON_HIT, ctx_e03)
	_check("H1d E-03 帧闸：同帧同栈二次派发零输出", ctx_e03.attach_request.is_empty(),
		str(ctx_e03.attach_request))
	# 单元素栈回归：{element, value, overrides} 逐字节不变
	var single := TraitStack.new()
	single.attach(_ele(&"ELE_IGNITE"))
	var ctx_s := TraitContext.new()
	ctx_s.event = GameConst.TraitEvent.ON_HIT
	ctx_s.projectile = p_fir
	single.dispatch(GameConst.TraitEvent.ON_HIT, ctx_s)
	_check("H1e 单元素回归：请求逐字节 == {FIR, 22.0, {}}",
		ctx_s.attach_request == {"element": GameConst.Element.FIR,
			"value": 22.0, "overrides": {}}, str(ctx_s.attach_request))
	var p_kin := _rxn_spawn_proj({"position": Vector2(150, 150), "velocity": Vector2.ZERO,
		"lifetime": 10.0, "pierce": 1, "hitbox_radius": 6.0,
		"element": GameConst.Element.KIN, "attach_value": 0.0, "team": 0})
	var ctx_kin := TraitContext.new()
	ctx_kin.event = GameConst.TraitEvent.ON_HIT
	ctx_kin.projectile = p_kin
	_bump_frame()
	single.dispatch(GameConst.TraitEvent.ON_HIT, ctx_kin)
	_check("H1f KIN 宿主放行：无附魔弹直挂通道照旧输出",
		ctx_kin.attach_request == {"element": GameConst.Element.FIR,
			"value": 22.0, "overrides": {}}, str(ctx_kin.attach_request))
	_kill_live_projs()


# ── H2. ON_SPAWN 守卫（spawn 参数元素不被词条覆写） ─────────────────
func _test_spawn_guard() -> void:
	print("── H2 ON_SPAWN 守卫：spawn 随机元素保持（R26「每发随机取一」第三腿） ──")
	var stack := _dual_stack()
	var p1 := _rxn_spawn_proj({"position": Vector2(150, 150), "velocity": Vector2.ZERO,
		"lifetime": 10.0, "pierce": 1, "hitbox_radius": 6.0,
		"element": GameConst.Element.FIR, "attach_value": 0.0, "team": 0,
		"trait_stack": stack.copy_runtime()})
	_check("H2a spawn 参数 FIR 保持 FIR（修复后被末位 LTG 整写覆写）",
		int(p1.element) == GameConst.Element.FIR, "element=%d" % int(p1.element))
	var p2 := _rxn_spawn_proj({"position": Vector2(150, 150), "velocity": Vector2.ZERO,
		"lifetime": 10.0, "pierce": 1, "hitbox_radius": 6.0,
		"element": GameConst.Element.LTG, "attach_value": 0.0, "team": 0,
		"trait_stack": stack.copy_runtime()})
	_check("H2b spawn 参数 LTG 保持 LTG", int(p2.element) == GameConst.Element.LTG,
		"element=%d" % int(p2.element))
	var p3 := _rxn_spawn_proj({"position": Vector2(150, 150), "velocity": Vector2.ZERO,
		"lifetime": 10.0, "pierce": 1, "hitbox_radius": 6.0,
		"element": GameConst.Element.KIN, "attach_value": 0.0, "team": 0,
		"trait_stack": stack.copy_runtime()})
	_check("H2c KIN 中性弹保留附魔染色（放行分支→首挂词条元素）",
		int(p3.element) == GameConst.Element.FIR, "element=%d" % int(p3.element))
	_kill_live_projs()


# ── H3. 武器级实弹：双 ELE 卡交替（_shot_element 每发随机不被覆写） ──
func _test_weapon_alternation() -> void:
	print("── H3 武器级实弹：火+电双卡交替 ──")
	var w := _rxn_make_weapon()
	w.attach_trait(_ele(&"ELE_IGNITE"))
	w.attach_trait(_ele(&"ELE_SHOCK"))
	var seen := {}
	for i in range(16):
		_bump_frame()
		w.try_fire()
	for node in _r_proj_pool.active_projectiles():
		var proj := node as ProjectileBase
		seen[int(proj.element)] = true
	_check("H3a 双元素实弹：火/雷均出现（每发随机取一，不再恒为挂载序末位）",
		seen.has(GameConst.Element.FIR) and seen.has(GameConst.Element.LTG),
		str(seen.keys()))
	_check("H3b 16 发全部 ∈ 附魔集合（无 KIN 无杂色）", seen.size() == 2, str(seen.keys()))
	_kill_live_projs()
	w.free()


# ── H4. 端到端：真件 ElementalSystem 双槽成对 → RXN_FIR_LTG 过载 ────
func _test_overload_chain() -> void:
	print("── H4 端到端：火+电挂载 → 附着 → 过载触发（落血/清槽/CD 2s） ──")
	var enemy := _rxn_spawn_enemy(_rxn_enemy_data("E_R191_RXN", 1000.0), Vector2(365, 640))
	_r_sys.register_host(enemy)
	var stack := _dual_stack()                 # 火+电挂载（同武器双 ELE 卡）
	# 第 1 发：当发随机元素 = 火（模拟 _shot_element 抽中火）
	var p1 := _rxn_spawn_proj({"position": Vector2(360, 640), "velocity": Vector2(100, 0),
		"lifetime": 10.0, "pierce": 1, "hitbox_radius": 6.0,
		"element": GameConst.Element.FIR, "attach_value": 0.0, "team": 0,
		"panel_snapshot": {"base_atk": 100.0}, "trait_stack": stack.copy_runtime()})
	_check("H4a 第 1 发 ON_SPAWN 后 element == FIR", int(p1.element) == GameConst.Element.FIR)
	_bump_frame()                              # E-03：spawn 期已派发 ON_SPAWN，命中须推帧
	p1.tick(DT)
	var st := enemy.get("elemental") as ElementalState
	_check("H4b 命中 → 火槽 +22（当发元素附着上槽）",
		st != null and _approx(st.gauges[GameConst.Element.FIR], 22.0),
		"fir=%s" % str(st.gauges[GameConst.Element.FIR] if st != null else -1.0))
	_check("H4c 雷槽未被错元素串写（恒 0）",
		st == null or _approx(st.gauges[GameConst.Element.LTG], 0.0))
	# 第 2 发：当发随机元素 = 雷（交替）
	var p2 := _rxn_spawn_proj({"position": Vector2(360, 640), "velocity": Vector2(100, 0),
		"lifetime": 10.0, "pierce": 1, "hitbox_radius": 6.0,
		"element": GameConst.Element.LTG, "attach_value": 0.0, "team": 0,
		"panel_snapshot": {"base_atk": 100.0}, "trait_stack": stack.copy_runtime()})
	_bump_frame()
	p2.tick(DT)
	_check("H4d 双槽成对（火=22 且 雷=22 → has_both 达成）",
		st != null and _approx(st.gauges[GameConst.Element.FIR], 22.0)
			and _approx(st.gauges[GameConst.Element.LTG], 22.0),
		"fir=%s ltg=%s" % [str(st.gauges[GameConst.Element.FIR] if st != null else -1.0),
			str(st.gauges[GameConst.Element.LTG] if st != null else -1.0)])
	# 帧末统一检测（E-07）：过载 RXN_FIR_LTG = 120%ATK × 快照 100
	var rxn0: int = DebugStats.get_counter(&"reaction_triggered")
	_bump_frame()
	_r_sys.detect_reactions()
	_check("H4e 过载触发：reaction_triggered 计数 +1",
		DebugStats.get_counter(&"reaction_triggered") == rxn0 + 1,
		"%d → %d" % [rxn0, DebugStats.get_counter(&"reaction_triggered")])
	_check("H4f 过载消耗：双槽清空",
		_approx(st.gauges[GameConst.Element.FIR], 0.0)
		and _approx(st.gauges[GameConst.Element.LTG], 0.0))
	_check("H4g 过载 CD：reaction_cd[RXN_FIR_LTG] = 2s",
		_approx(float(st.reaction_cd.get(GameConst.ReactionType.RXN_FIR_LTG, 0.0)), 2.0, 0.01))
	_check("H4h 过载落血：120%ATK 落血（1000 − 100×2 弹体 − 120 = 680）",
		_approx(float(enemy.hp), 680.0, 0.01), "hp=%s" % str(enemy.hp))
	# CD 期内重附双槽 → 不触发；过期（sys.tick 推进）→ 再触发
	_r_sys.apply_attach(enemy, GameConst.Element.FIR, 22.0, {"snapshot": 100.0})
	_r_sys.apply_attach(enemy, GameConst.Element.LTG, 22.0)
	_bump_frame()
	_r_sys.detect_reactions()
	_check("H4i 反应 CD：2s 内重附双槽不触发（同反应每敌 2s 门）",
		DebugStats.get_counter(&"reaction_triggered") == rxn0 + 1)
	_r_sys.tick(2.0)
	_r_sys.apply_attach(enemy, GameConst.Element.FIR, 22.0, {"snapshot": 100.0})
	_r_sys.apply_attach(enemy, GameConst.Element.LTG, 22.0)
	_bump_frame()
	_r_sys.detect_reactions()
	_check("H4j CD 过期后可再次触发（+1——普通难度全额结算，无难度门）",
		DebugStats.get_counter(&"reaction_triggered") == rxn0 + 2)
	_r_sys.unregister_host(enemy)
