# tests/runner/r249_mine_shield_cases.gd（二db 地雷降频+躲雷橙盾 用例体——入口运行时加载）
# 复现口径：boot 真实 GameLoop（r245_sublime_gate 同款）→ start_run 后在真 PLAYING 态
# 驱动 BossMine 生命周期（真帧推进；缩短 telegraph/arm/life 加速，host=null 走全周期
# ——:3338 清理臂只在 host!=null 生效）；玩家拉远 700px+ 保证「引爆未伤人」。
# 断言只读产品态，不改游戏代码；无 test_ 前缀不入电池 glob 的误收范围。
extends RefCounted

const PLAYER_SOURCE := "res://scripts/entities/player/player.gd"
const ENEMY_SOURCE := "res://scripts/entities/enemy/enemy.gd"
const HUD_SOURCE := "res://scripts/ui/hud.gd"
const GL_SOURCE := "res://scripts/loop/game_loop.gd"
const PALETTE_SOURCE := "res://scripts/ui/palette.gd"
const BUS_SOURCE := "res://autoload/event_bus.gd"

var tree: SceneTree
var _gl: GameLoop = null
var _fails: int = 0
var _dodge_count: int = 0


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> bool:
	if p_cond:
		print("  PASS | %s" % p_name)
	else:
		_fails += 1
		print("  FAIL | %s %s" % [p_name, p_detail])
	return p_cond


func fail_count() -> int:
	return _fails


func _on_dodge(_p_pos: Vector2) -> void:
	_dodge_count += 1


func _read_source(p_path: String) -> String:
	var fs := FileAccess.open(p_path, FileAccess.READ)
	if fs == null:
		return ""
	var txt := fs.get_as_text()
	fs.close()
	return txt


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	print("── 0 环境 boot ──")
	RunSave.clear()
	_gl = GameLoop.new()
	_gl.name = "R249MineShieldUnderTest"
	tree.get_root().add_child(_gl)
	await tree.process_frame
	await tree.process_frame
	if not _check("前置：GameLoop Boot 完成（MENU）",
			_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU,
			"boot_ready=%s state=%d" % [str(_gl.boot_ready), _gl.state]):
		return
	_gl.start_run()
	_check("前置：start_run → PLAYING", _gl.state == GameConst.GameStatus.PLAYING,
		"state=%d" % _gl.state)
	EventBus.mine_dodged.connect(_on_dodge)
	# 玩家初始位直接落 E-15 活动区（y∈[768,1264]，下 40% 屏）——PLAYING 态 game_loop
	# 每物理帧 player.tick → _clamp_to_playfield（player.gd:615）无条件钳制；放 (620,620)
	# 会与「放雷读位 vs 首个 physics tick」竞争（读位落在 tick 前则雷贴 620、随后玩家被
	# 钳到 768，pd 141→267.4 破坏威胁圈 141px 设计——B0/B2/B3/B4 连锁红的根因）。合法区
	# 内 clamp 恒不动，pd 恒 141 确定化。
	_gl.player.position = Vector2(620.0, 900.0)

	_test_a_trapper_cd()
	await _test_b_dodge_grant()
	await _test_b2_far_mine_no_grant()
	_test_c_stack_cap()
	_test_d_expiry()
	_test_e_absorb_order()
	_test_f_blast_hit_no_grant()
	await _test_g_silent_clean()
	_test_h_source_anchors()
	await _test_i_hud_runtime()

	_gl.queue_free()
	await tree.process_frame


# ── A：trapper 降频锁 ─────────────────────────────────────────────
func _test_a_trapper_cd() -> void:
	print("── A trapper 词缀 cd 降频 ──")
	var cd_v: Variant = Enemy.AFFIX_DEFS.get(&"affix_trapper", {}).get("cd", -1)
	_check("A1 affix_trapper cd==13.0（二db 降频 9→13）", float(cd_v) == 13.0,
		"cd=%s" % str(cd_v))


# ── B：躲雷授盾（真周期驱动） ─────────────────────────────────────
func _test_b_dodge_grant() -> void:
	print("── B 地雷到期未伤人 → 橙盾 +1（10s） ──")
	var mine := Enemy.BossMine.new()
	mine.name = "R249MineFar"
	mine.position = Vector2(100.0, 100.0)          # 玩家 (620,620) 距离 ~735 > blast
	mine.telegraph_s = 0.05
	mine.arm_s = 0.05
	mine.life_s = 0.15
	mine.blast_r = 90.0
	mine.trigger_r = 42.0
	mine.dmg = 30.0
	mine.host = null                               # 清理臂不生效——走全生命周期
	tree.get_root().add_child(mine)
	await tree.process_frame
	# M2 威胁门口径：「躲过」= armed 后玩家曾入 blast×2 圈（180px）。玩家被战场钳制
	# 覆写（设 (200,200) 实夹 (200,768)——站桩不可靠），改由雷贴玩家实际位：
	# 141px 落在 (trigger 42, blast 90]×2 威胁圈内——armed 记威胁、到期爆不伤人=躲过。
	var pl := tree.get_first_node_in_group(&"player") as Node2D
	mine.position = pl.global_position + Vector2(100.0, -100.0)
	# 帧上限 4000（非 40）：BossMine._process 按渲染 delta 推进 _t，高 fps（如
	# --fixed-fps 1000 调度）下 40 帧仅 0.04s 够不到 arm 线 0.1s——break 条件不变
	#（到线即出，60fps 下仍 ≈6 帧），上限只兜极端 fps 的等待余量
	var armed_wait := 0
	while is_instance_valid(mine) and armed_wait < 4000:
		await tree.process_frame
		armed_wait += 1
		if mine._t >= mine.telegraph_s + mine.arm_s:
			break
	_check("B0 威胁圈已记忆（armed 期玩家曾入 blast×2）", mine._threat_near,
		"armed_wait=%d threat=%s pd=%.1f" % [armed_wait, str(mine._threat_near),
			mine.global_position.distance_to(pl.global_position)])
	var waited := 0
	while is_instance_valid(mine) and waited < 600:
		await tree.process_frame
		waited += 1
	_check("B1 雷已自毁（到期引爆）", not is_instance_valid(mine), "waited=%d" % waited)
	_check("B2 mine_dodged 恰发一次（引爆未伤人）", _dodge_count == 1,
		"dodge=%d" % _dodge_count)
	var stacks: int = _gl.player.temp_shield_stacks
	var left: float = _gl.player.temp_shield_left
	_check("B3 橙盾 +1 层（stacks==1）", stacks == 1, "stacks=%d" % stacks)
	_check("B4 剩余 ≈10s（TEMP_SHIELD_TIME；真帧推进容差 ≥9.0）", left >= 9.0,
		"left=%.2f" % left)


# ── B2：远雷不授（M2 威胁门——玩家从未入威胁圈的雷到期不算「躲过」） ──
func _test_b2_far_mine_no_grant() -> void:
	print("── B2 远雷（玩家全程 ~735px）到期 → 不授盾 ──")
	var dodge0 := _dodge_count
	var stacks0: int = _gl.player.temp_shield_stacks
	var mine := Enemy.BossMine.new()
	mine.name = "R249MineNeverNear"
	mine.position = Vector2(100.0, 100.0)
	mine.telegraph_s = 0.05
	mine.arm_s = 0.05
	mine.life_s = 0.15
	mine.blast_r = 90.0
	mine.trigger_r = 42.0
	mine.dmg = 30.0
	mine.host = null
	tree.get_root().add_child(mine)
	var waited := 0
	while is_instance_valid(mine) and waited < 600:
		await tree.process_frame
		waited += 1
	_check("B2-1 远雷已自毁（到期引爆）", not is_instance_valid(mine), "waited=%d" % waited)
	_check("B2-2 无威胁不授盾（威胁门）",
		_dodge_count == dodge0 and _gl.player.temp_shield_stacks == stacks0,
		"dodge %d→%d stacks %d→%d" % [dodge0, _dodge_count, stacks0,
			_gl.player.temp_shield_stacks])


# ── C：叠层与上限 ─────────────────────────────────────────────────
func _test_c_stack_cap() -> void:
	print("── C 叠层至上限 5（R253 起同帧多源合并 1 层——跨帧断言） ──")
	_gl.player.temp_shield_left = 3.0              # 模拟已消耗 7s
	_gl.player.temp_shield_stacks = 0
	_gl.player._dodge_frame_stamp = -1             # 帧戳净态
	for i in range(6):
		_gl.player._on_mine_dodged(Vector2.ZERO)
	_check("C1 同帧 6 源齐爆只授 1 层（R253 合并——防雷海+自爆海一次走位滚雪球）",
		_gl.player.temp_shield_stacks == 1,
		"stacks=%d" % _gl.player.temp_shield_stacks)
	_check("C2 授层刷新寿命回 ≈10", _gl.player.temp_shield_left >= 9.99,
		"left=%.2f" % _gl.player.temp_shield_left)
	for i in range(6):
		_gl.player._dodge_frame_stamp = -1         # 直调无真帧推进——手动归零模拟跨帧
		_gl.player._on_mine_dodged(Vector2.ZERO)
	_check("C3 跨帧连躲逐层叠至 5 帽（TEMP_SHIELD_MAX）",
		_gl.player.temp_shield_stacks == 5,
		"stacks=%d" % _gl.player.temp_shield_stacks)
	_gl.player._dodge_frame_stamp = -1             # 组尾净态（组间残留防线）


# ── D：寿命归零层清 ───────────────────────────────────────────────
func _test_d_expiry() -> void:
	print("── D 寿命归零层清 ──")
	_gl.player.temp_shield_left = 0.02
	_gl.player.tick(0.05, Vector2.ZERO)
	_check("D1 tick 越过归零 → stacks 清 0",
		_gl.player.temp_shield_stacks == 0 and _gl.player.temp_shield_left <= 0.0,
		"stacks=%d left=%.3f" % [_gl.player.temp_shield_stacks,
			_gl.player.temp_shield_left])


# ── E：吸收顺序（橙先于蓝；整击吞下） ─────────────────────────────
func _test_e_absorb_order() -> void:
	print("── E 橙盾吸收：先于蓝盾、整击吞下 ──")
	var p: Player = _gl.player
	p.invuln_left = 0.0
	p.temp_shield_stacks = 2
	p.temp_shield_left = 5.0
	p.shield_interval = 0.0                        # 无蓝盾词条基线
	var hp0: float = p.hp
	p.take_contact_damage(30.0)
	_check("E1 橙盾整击吞下（hp 不动）+ 层数 −1",
		is_equal_approx(p.hp, hp0) and p.temp_shield_stacks == 1,
		"hp %.1f→%.1f stacks=%d" % [hp0, p.hp, p.temp_shield_stacks])
	_check("E2 吸收后进 contact_tick 无敌帧（防同帧连击透层）", p.invuln_left > 0.0,
		"invuln=%.2f" % p.invuln_left)
	# 蓝盾就绪共存时：橙先用（临时过期资源先用先消）
	p.invuln_left = 0.0
	p.shield_interval = 5.0
	p.shield_ready = true
	p.temp_shield_stacks = 1
	p.temp_shield_left = 5.0
	var hp1: float = p.hp
	p.take_contact_damage(30.0)
	_check("E3 橙先于蓝（橙耗尽、蓝盾就绪保住）",
		p.temp_shield_stacks == 0 and p.shield_ready and is_equal_approx(p.hp, hp1),
		"stacks=%d ready=%s hp %.1f→%.1f" % [p.temp_shield_stacks,
			str(p.shield_ready), hp1, p.hp])


# ── F：炸到玩家不发 dodge ─────────────────────────────────────────
func _test_f_blast_hit_no_grant() -> void:
	print("── F 引爆炸到玩家：伤害照走、不发 dodge ──")
	var p: Player = _gl.player
	p.invuln_left = 0.0
	p.temp_shield_stacks = 0
	p.temp_shield_left = 0.0
	p.shield_interval = 0.0
	p.shield_ready = false              # E3 共存验证残留（蓝就绪会吞伤——必须净态）
	var dodge0 := _dodge_count
	var hp0: float = p.hp
	var mine := Enemy.BossMine.new()
	mine.position = p.position                     # 距离 0 ≤ blast——必命中
	mine.dmg = 30.0
	mine.blast_r = 90.0
	tree.get_root().add_child(mine)
	mine._explode(p)
	_check("F1 命中扣血 30（hp−30）", is_equal_approx(hp0 - p.hp, 30.0),
		"hp %.1f→%.1f" % [hp0, p.hp])
	_check("F2 不发 mine_dodged、不授橙盾",
		_dodge_count == dodge0 and p.temp_shield_stacks == 0,
		"dodge %d→%d stacks=%d" % [dodge0, _dodge_count, p.temp_shield_stacks])


# ── G：未 arm 静默清不授盾 ────────────────────────────────────────
func _test_g_silent_clean() -> void:
	print("── G 宿主失效未 arm 静默清（无威胁不授盾） ──")
	var dodge0 := _dodge_count
	var fake_host := Node2D.new()                  # instance 有效但 data==null → 清理臂
	var mine := Enemy.BossMine.new()
	mine.telegraph_s = 5.0                         # 永远到不了 arm——静默清路径
	mine.arm_s = 5.0
	mine.host = fake_host
	tree.get_root().add_child(mine)
	await tree.process_frame
	await tree.process_frame
	_check("G1 未 arm 雷被静默清（自毁）", not is_instance_valid(mine))
	_check("G2 无 dodge 无授盾", _dodge_count == dodge0
		and _gl.player.temp_shield_stacks == 0,
		"dodge=%d stacks=%d" % [_dodge_count, _gl.player.temp_shield_stacks])
	fake_host.free()


# ── H：源码锚 ─────────────────────────────────────────────────────
func _test_h_source_anchors() -> void:
	print("── H 源码锚（信号/参数/橙条/吸收序） ──")
	var bus_src := _read_source(BUS_SOURCE)
	_check("H1 EventBus 信号+emit 在位",
		bus_src.contains("signal mine_dodged") and bus_src.contains("func emit_mine_dodged"))
	var pal_src := _read_source(PALETTE_SOURCE)
	_check("H2 调色板 ORANGE 常量在位（ff8c1a）", pal_src.contains("ORANGE := Color(\"ff8c1a\")"))
	var pl_src := _read_source(PLAYER_SOURCE)
	_check("H3 橙盾参数锚（10s/上限 5）",
		pl_src.contains("TEMP_SHIELD_TIME := 10.0") and pl_src.contains("TEMP_SHIELD_MAX := 5"))
	# 吸收顺序：橙分支在 take_contact_damage 函数体内先于蓝盾（R253 蓝臂=独立单元循环）
	var fn_at := pl_src.find("func take_contact_damage(")
	var fn_end := pl_src.find("\nfunc ", fn_at + 10)
	var fn_body := pl_src.substr(fn_at, fn_end - fn_at)
	var orange_at := fn_body.find("if temp_shield_stacks > 0 and temp_shield_left > 0.0:")
	var blue_at := fn_body.find("var block_key := -1")
	_check("H4 吸收顺序：橙分支先于蓝盾（函数体区间裁剪判；R253 独立计时蓝臂锚）",
		orange_at > 0 and blue_at > orange_at,
		"orange@%d blue@%d" % [orange_at, blue_at])
	var hud_src := _read_source(HUD_SOURCE)
	_check("H5 HUD 橙条锚（OrangeShieldBar @ (306,132)=蓝条正下方 + ORANGE 填充 + N·Xs 读数）",
		hud_src.contains("OrangeShieldBar") and hud_src.contains("Vector2(306.0, 132.0)")
			and hud_src.contains("PopPalette.ORANGE") and hud_src.contains("\"%d·%ds\""))
	var en_src := _read_source(ENEMY_SOURCE)
	_check("H6 威胁门锚（_threat_near 记忆 + 授盾门 + boss 死亡臂传真实玩家——M2/M3）",
		en_src.contains("var _threat_near: bool")
			and en_src.contains("if not hit and _threat_near:")
			and en_src.contains("_explode(_get_player())"))
	_check("H7 爆环 dedent 出池分支（thorn 雷无池也有爆感——M1）",
		en_src.contains("\t\tEventBus.emit_kill_blast")
			and not en_src.contains("\t\t\tEventBus.emit_kill_blast"))
	_check("H8 respawn 随局清零锚（M4/QA BUG-1）",
		pl_src.contains("temp_shield_stacks = 0")
			and pl_src.contains("temp_shield_left = 0.0"))
	var gl_src := _read_source(GL_SOURCE)
	_check("H9 表现层锚（授盾音效 + 首获 toast + 挡下即刷条——M1/L1）",
		gl_src.contains("mine_dodged.connect")
			and pl_src.contains("emit_mechanics_intro(\"⚡ 闪避护盾")
			and hud_src.contains("EventBus.shield_blocked.connect(_on_shield_blocked_hud)"))


# ── I：HUD 运行时（随层显隐 + 读数） ──────────────────────────────
func _test_i_hud_runtime() -> void:
	print("── I HUD 橙条运行时 ──")
	var bar := _find_node(tree.get_root(), "OrangeShieldBar") as Control
	if not _check("I1 橙条节点存在（HUD 构建挂树）", bar != null):
		return
	_gl.player.temp_shield_stacks = 0             # 从净态起
	_gl.player.temp_shield_left = 0.0
	_gl.player.invuln_left = 0.0                   # grant 守卫只看 _dead——顺手清无敌帧不干扰
	_gl.player._dodge_frame_stamp = -1             # R253 同帧合并帧戳净态
	EventBus.emit_mine_dodged(Vector2.ZERO)        # 走真信号：player grant + HUD 脏标记帧末 flush
	EventBus.emit_mine_dodged(Vector2.ZERO)
	EventBus.emit_mine_dodged(Vector2.ZERO)        # 同帧三源齐爆 → R253 合并只授 1 层
	await tree.process_frame
	await tree.process_frame
	var label: Label = null
	for c in bar.get_children():
		if c is Label and String((c as Label).text).contains("·"):
			label = c
	_check("I2 同帧三爆合并 1 层 → 橙条帧末即时可见 + 读数「1·Xs」式（R253 合并语义）",
		bar.visible and label != null and (label as Label).text.begins_with("1·"),
		"visible=%s text=%s" % [str(bar.visible), str(label.text if label != null else "")])
	_gl.player.temp_shield_stacks = 0
	_gl.player.temp_shield_left = 0.0
	var hud: Node = bar
	while hud != null and not hud.has_method(&"refresh_stats"):
		hud = hud.get_parent()
	if hud != null:
		hud.call(&"refresh_stats")                  # 直调兜底（清层无事件——1Hz 兜底口径）
	_check("I3 层清 → 橙条隐藏", not bar.visible)


func _find_node(p_from: Node, p_name: String) -> Node:
	if p_from.name == p_name:
		return p_from
	for c in p_from.get_children():
		var found := _find_node(c, p_name)
		if found != null:
			return found
	return null
