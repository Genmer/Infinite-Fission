# tests/runner/r251_dodge_bomber_cases.gd（R251 需求①「躲爆授盾扩展」用例体——入口运行时加载）
# 口径：boot main.tscn 真实 GameLoop（MENU 态、不 start_run——零波次干扰，规避 r249 B2
# 式 flake）；E4/E24/E28 经 registry + EnemyPool 真件直出，e.tick(DT=1/120) 手动驱动
# 全生命周期；玩家为静态桩（只动 position/受击态，不 tick）。断言只读产品态。
# 验收锚：设计 §1.6 A1~A12（A11 BossMine 回归由 test_r249_mine_shield 复跑承担）。
extends RefCounted

const DT := 1.0 / 120.0
const MAIN_SCENE := "res://scenes/main.tscn"

var tree: SceneTree
var _gl: GameLoop = null
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _dodge_count: int = 0


func _on_dodge(_p_pos: Vector2) -> void:
	_dodge_count += 1


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> bool:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])
	return p_cond


func fail_count() -> int:
	return _fail


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	tree.paused = false                    # 电池串行防残留：前序套件异常退出可能遗留
	                                       # paused——A10 的 SceneTreeTimer(process_always=
	                                       # false) 会永不推进
	RunSave.clear()
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R251DodgeBomberUnderTest"
	tree.get_root().add_child(_gl)
	await tree.process_frame
	await tree.process_frame
	EventBus.mine_dodged.connect(_on_dodge)
	_test_a1_volatile_dodge()
	_test_a2_volatile_hit()
	_test_a3_volatile_knockback_cancel()
	_test_a4_volatile_killed_unarmed()
	_test_a5_blink_dodge()
	_test_a6_blink_hit()
	_test_a7_blink_interrupts()
	_test_a8_blink_killed()
	_test_a9_blink_pool_reuse()
	await _test_a10_spell_ring()
	_test_a12_shield_values()
	_teardown()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


# ── 环境 ──────────────────────────────────────────────────────────
func _reset_player() -> void:
	# 每用例净态：满血 / 无敌帧清 / 无橙盾 / 无蓝盾；玩家回固定锚位——直接落 E-15
	# 活动区（y∈[768,1264]）：本套件 MENU 态不 tick 玩家，位置恒定；落合法区防未来
	# 状态门变化引入 tick 钳制位移（r249 B 用例 pd 竞争红的同型预防）
	var p: Player = _gl.player
	p.position = Vector2(360.0, 900.0)
	p.hp = p.max_hp
	p.invuln_left = 0.0
	p.temp_shield_stacks = 0
	p.temp_shield_left = 0.0
	p.shield_interval = 0.0
	p.shield_ready = false
	p._dodge_frame_stamp = -1               # R253 同帧合并帧戳组间净态（headless 同步段不推真帧）


func _make_enemy(p_id: StringName) -> Enemy:
	var data: EnemyData = _gl.registry.get_enemy(p_id)
	if data == null:
		return null
	var e: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	e.spawn(data, 1, 0)
	return e


func _make_volatile() -> Enemy:
	return _make_enemy(&"E4_volatile")


func _make_blink() -> Enemy:
	return _make_enemy(&"E24_rift_demon")


func _drive_blink_to_fuse(e: Enemy, p_player: Player) -> bool:
	# cd 归零 + 距离 ≤ blink_range(340) → tick 进读条（快照玩家位）；读条 0.35s 走完
	# 落地进引信态（此时 _blink_threat 已置位）
	e.set("_blink_cd", 0.0)
	e.position = p_player.position + Vector2(-200.0, 0.0)
	var n := 0
	while int(e.blink_state()) != 2 and n < 300:
		e.tick(DT)
		n += 1
	return int(e.blink_state()) == 2 and not e.dead


# ── A1：volatile 躲爆 ─────────────────────────────────────────────
func _test_a1_volatile_dodge() -> void:
	print("── A1 volatile 躲爆：arm 后拉远引爆 → 恰发 1 + 橙盾 +1 ──")
	_reset_player()
	var dodge0 := _dodge_count
	var pl: Player = _gl.player
	var e := _make_volatile()
	if not _check("A1-0 E4 真件直出", e != null):
		return
	e.position = pl.position + Vector2(20.0, 0.0)     # reach = 14+16+4 = 34px → 1 帧 arm
	e.tick(DT)
	if not _check("A1-1 贴身 1 帧 arm", e.fuse_armed()):
		return
	e.position = pl.position + Vector2(600.0, 0.0)    # 拉远：arm 冲刺 260px/s×1.2s = 312px
	var n := 0                                        # → 引爆时 ≈288px > blast 110 = 未伤人
	while is_instance_valid(e) and not e.dead and n < 300:
		e.tick(DT)
		n += 1
	_check("A1-2 引爆致死（引信走完）", is_instance_valid(e) and e.dead, "n=%d" % n)
	_check("A1-3 mine_dodged 恰发 1 次", _dodge_count == dodge0 + 1,
		"dodge %d→%d" % [dodge0, _dodge_count])
	_check("A1-4 橙盾 +1 层", _gl.player.temp_shield_stacks == 1,
		"stacks=%d" % _gl.player.temp_shield_stacks)
	_check("A1-5 玩家未掉血（躲爆免伤）",
		is_equal_approx(_gl.player.hp, _gl.player.max_hp))


# ── A2：volatile 命中 ─────────────────────────────────────────────
func _test_a2_volatile_hit() -> void:
	print("── A2 volatile 命中：arm 后贴身引爆 → 0 发 + 全额掉血 20 ──")
	_reset_player()
	var dodge0 := _dodge_count
	var pl: Player = _gl.player
	var e := _make_volatile()
	e.position = pl.position + Vector2(20.0, 0.0)
	e.tick(DT)
	var hp0 := pl.hp
	var n := 0
	while is_instance_valid(e) and not e.dead and n < 300:
		e.tick(DT)
		n += 1
	var dropped := hp0 - pl.hp
	_check("A2-1 引爆致死", is_instance_valid(e) and e.dead)
	_check("A2-2 全额掉血 20（wave1 dmg_base）", absf(dropped - 20.0) < 0.01,
		"dropped=%.2f" % dropped)
	_check("A2-3 不发 mine_dodged（hit 先置位语义）", _dodge_count == dodge0,
		"dodge %d→%d" % [dodge0, _dodge_count])


# ── A3：volatile 击退打断 ─────────────────────────────────────────
func _test_a3_volatile_knockback_cancel() -> void:
	print("── A3 volatile 击退打断：引信取消不爆 → 0 发、可再次引导 ──")
	_reset_player()
	var dodge0 := _dodge_count
	var pl: Player = _gl.player
	var e := _make_volatile()
	e.position = pl.position + Vector2(20.0, 0.0)
	e.tick(DT)
	if not _check("A3-0 已 arm", e.fuse_armed()):
		return
	e.knockback(Vector2(80.0, 0.0))                   # 击退打断（knockback → _cancel_fuse）
	_check("A3-1 引信已取消", not e.fuse_armed())
	e.position = pl.position + Vector2(400.0, 0.0)    # 拉远防再 arm/再爆
	var n := 0
	while n < 200:
		e.tick(DT)
		n += 1
	_check("A3-2 不引爆（打断后引信不恢复）", not e.dead)
	_check("A3-3 零 dodge", _dodge_count == dodge0,
		"dodge %d→%d" % [dodge0, _dodge_count])
	e.position = pl.position + Vector2(20.0, 0.0)
	e.tick(DT)
	_check("A3-4 敌存活可再次引导（pkg4 契约不破）", e.fuse_armed() and not e.dead)


# ── A4：volatile 未接触被杀 ───────────────────────────────────────
func _test_a4_volatile_killed_unarmed() -> void:
	print("── A4 volatile 未接触即被杀：0 发 ──")
	_reset_player()
	var dodge0 := _dodge_count
	var e := _make_volatile()
	e.position = _gl.player.position + Vector2(500.0, 0.0)   # > reach 34：不接触
	e.tick(DT)
	if _check("A4-0 未 arm", not e.fuse_armed()):
		e.apply_damage(99999.0)
	_check("A4-1 已击杀", e.dead)
	_check("A4-2 零 dodge", _dodge_count == dodge0,
		"dodge %d→%d" % [dodge0, _dodge_count])


# ── A5：blink 躲爆 ────────────────────────────────────────────────
func _test_a5_blink_dodge() -> void:
	print("── A5 blink 躲爆：落地引信期拉远引爆 → 恰发 1 + 橙盾 +1 ──")
	_reset_player()
	var dodge0 := _dodge_count
	var stacks0: int = _gl.player.temp_shield_stacks
	var pl: Player = _gl.player
	var e := _make_blink()
	if not _check("A5-0 落地进引信态", _drive_blink_to_fuse(e, pl)):
		return
	_check("A5-1 落地即威胁置位（_blink_threat）", bool(e.get("_blink_threat")))
	pl.position = e.global_position + Vector2(400.0, 0.0)    # 走位出圈（> blast 110）
	var n := 0
	while is_instance_valid(e) and not e.dead and n < 200:
		e.tick(DT)
		n += 1
	_check("A5-2 引爆致死（本体仍死——blink_cases:160 语义不破）",
		is_instance_valid(e) and e.dead)
	_check("A5-3 mine_dodged 恰发 1 次", _dodge_count == dodge0 + 1,
		"dodge %d→%d" % [dodge0, _dodge_count])
	_check("A5-4 橙盾 +1 层", _gl.player.temp_shield_stacks == stacks0 + 1,
		"stacks=%d" % _gl.player.temp_shield_stacks)
	_check("A5-5 玩家免伤", is_equal_approx(_gl.player.hp, _gl.player.max_hp))


# ── A6：blink 命中 ────────────────────────────────────────────────
func _test_a6_blink_hit() -> void:
	print("── A6 blink 命中：圈内吃全额 18 → 0 发 ──")
	_reset_player()
	var dodge0 := _dodge_count
	var pl: Player = _gl.player
	var e := _make_blink()
	if not _check("A6-0 落地进引信态", _drive_blink_to_fuse(e, pl)):
		return
	var hp0 := pl.hp
	var n := 0
	while is_instance_valid(e) and not e.dead and n < 200:
		e.tick(DT)
		n += 1
	var dropped := hp0 - pl.hp
	_check("A6-1 引爆致死", is_instance_valid(e) and e.dead)
	_check("A6-2 圈内吃 18（30% 档 wave1 dmg_base）", absf(dropped - 18.0) < 0.01,
		"dropped=%.2f" % dropped)
	_check("A6-3 不发 mine_dodged", _dodge_count == dodge0,
		"dodge %d→%d" % [dodge0, _dodge_count])


# ── A7：blink 打断双路 ────────────────────────────────────────────
func _test_a7_blink_interrupts() -> void:
	print("── A7 blink 打断双路：读条期冻结 / 引信期击退 → 0 发且威胁旗清零 ──")
	_reset_player()
	var dodge0 := _dodge_count
	var pl: Player = _gl.player
	# 路 1：读条期冻结（CHARGING + sf=0 → _cancel_blink）
	var e := _make_blink()
	e.set("_blink_cd", 0.0)
	e.position = pl.position + Vector2(-200.0, 0.0)
	var n := 0
	while int(e.blink_state()) != 1 and n < 100:
		e.tick(DT)
		n += 1
	if not _check("A7-0 已进读条", int(e.blink_state()) == 1):
		return
	e.elemental = ElementalState.new()
	e.elemental.freeze_timer = 1.0
	e.tick(DT)
	_check("A7-1 冻结断读条（回巡航）", int(e.blink_state()) == 0)
	_check("A7-2 威胁旗清零", not bool(e.get("_blink_threat")))
	e.elemental.freeze_timer = 0.0
	# 路 2：引信期击退（FUSED 态 knockback → _cancel_blink）
	var e2 := _make_blink()
	if not _check("A7-3 落地进引信态", _drive_blink_to_fuse(e2, pl)):
		return
	if not _check("A7-4 落地威胁已置位（对照）", bool(e2.get("_blink_threat"))):
		return
	e2.knockback(Vector2(80.0, 0.0))
	_check("A7-5 击退断引信（回巡航）", int(e2.blink_state()) == 0)
	_check("A7-6 威胁旗清零", not bool(e2.get("_blink_threat")))
	e2.set("_blink_cd", 3.0)                          # 打断后置冷却（隔离待测行为）
	n = 0
	while n < 200:
		e2.tick(DT)
		n += 1
	_check("A7-7 不引爆", not e2.dead)
	_check("A7-8 零 dodge", _dodge_count == dodge0,
		"dodge %d→%d" % [dodge0, _dodge_count])


# ── A8：blink 读条期/引信期被杀 ───────────────────────────────────
func _test_a8_blink_killed() -> void:
	print("── A8 blink 读条期被杀 / 引信期被杀 → 0 发 ──")
	_reset_player()
	var dodge0 := _dodge_count
	var pl: Player = _gl.player
	# 读条期被杀（apply_damage → _on_died，不进 _blink_explode）
	var e := _make_blink()
	e.set("_blink_cd", 0.0)
	e.position = pl.position + Vector2(-200.0, 0.0)
	var n := 0
	while int(e.blink_state()) != 1 and n < 100:
		e.tick(DT)
		n += 1
	e.apply_damage(99999.0)
	_check("A8-1 读条期被杀", e.dead)
	# 引信期被杀
	var e2 := _make_blink()
	if _drive_blink_to_fuse(e2, pl):
		e2.apply_damage(99999.0)
	_check("A8-2 引信期被杀", e2.dead)
	n = 0
	while n < 120:
		e2.tick(DT)                                   # 死敌 tick 短路（dead → return）
		n += 1
	_check("A8-3 零 dodge（两路均不进引爆结算）", _dodge_count == dodge0,
		"dodge %d→%d" % [dodge0, _dodge_count])


# ── A9：blink 池复用 ──────────────────────────────────────────────
func _test_a9_blink_pool_reuse() -> void:
	print("── A9 blink 池复用：引爆发 1 次 → release 重 spawn → 锁存不残留 ──")
	_reset_player()
	var dodge0 := _dodge_count
	var pl: Player = _gl.player
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var e := _make_blink()
	if not _check("A9-0 第一轮落地", _drive_blink_to_fuse(e, pl)):
		return
	pl.position = e.global_position + Vector2(400.0, 0.0)
	var n := 0
	while is_instance_valid(e) and not e.dead and n < 200:
		e.tick(DT)
		n += 1
	if not _check("A9-1 第一轮引爆发 1 次", e.dead and _dodge_count == dodge0 + 1,
			"dodge %d→%d" % [dodge0, _dodge_count]):
		return
	# 引爆死亡已走真实管线自动归还（_on_died → enemy_killed → spawner 回收 →
	# _reset_state）；显式 release 会触发「重复归还」防线——直接 acquire 复用
	var e2 := pool.acquire()
	e2.spawn(_gl.registry.get_enemy(&"E24_rift_demon"), 1, 0)
	_check("A9-2a 复用同一实例（死亡自动归还即取回）", e2 == e)
	_check("A9-2b 复用实例锁存不残留（_blink_threat==false）",
		not bool(e2.get("_blink_threat")))
	e2.position = pl.position + Vector2(600.0, 0.0)   # > blink_range 340：全程不闪现
	e2.set("_blink_cd", 0.0)
	n = 0
	while n < 200:
		e2.tick(DT)
		n += 1
	_check("A9-3 复用后距离外不闪现不引爆", not e2.dead)
	_check("A9-4 复用后零误发", _dodge_count == dodge0 + 1,
		"dodge=%d" % _dodge_count)
	if not _check("A9-5 复用后再走全流程落地", _drive_blink_to_fuse(e2, pl)):
		return
	pl.position = e2.global_position + Vector2(400.0, 0.0)
	n = 0
	while is_instance_valid(e2) and not e2.dead and n < 200:
		e2.tick(DT)
		n += 1
	_check("A9-6 复用后引爆恰再发 1 次", e2.dead and _dodge_count == dodge0 + 2,
		"dead=%s dodge=%d" % [str(e2.dead), _dodge_count])


# ── A10：法术圈（E28 咒术师） ─────────────────────────────────────
func _test_a10_spell_ring() -> void:
	print("── A10 法术圈：施圈后移出 r95 → 0 伤 + 恰发 1；站圈内 → 掉血 + 0 发 ──")
	_reset_player()
	var pl: Player = _gl.player
	var e := _make_enemy(&"E28_hexcaster")
	if not _check("A10-0 E28 registry 直出", e != null):
		return
	e.position = pl.position + Vector2(-300.0, 0.0)   # ≤ fire_range 400 → 驻停施法
	e.set("fire_cd_left", 0.0)
	e.tick(DT)                                        # 施圈（圈心 = 施法帧玩家位快照）
	var dodge0 := _dodge_count
	var hp0 := pl.hp
	pl.position += Vector2(300.0, 0.0)                # 真实走位移出 r95
	var n := 0
	while _dodge_count == dodge0 and n < 20000:
		await tree.process_frame                      # SceneTreeTimer 0.9s 真帧推进
		n += 1
	_check("A10-1 圈外引爆恰发 1 次（真躲开 = 授盾）", _dodge_count == dodge0 + 1,
		"waited=%d" % n)
	_check("A10-2 圈外零伤害", is_equal_approx(pl.hp, hp0),
		"hp %.1f→%.1f" % [hp0, pl.hp])
	# 圈内：净态第二次施圈，玩家站桩
	_reset_player()
	pl.position = Vector2(360.0, 900.0)
	var dodge1 := _dodge_count
	var hp1 := pl.hp
	e.set("fire_cd_left", 0.0)
	e.tick(DT)
	n = 0
	while is_equal_approx(pl.hp, hp1) and n < 20000:
		await tree.process_frame
		n += 1
	var dropped := hp1 - pl.hp
	_check("A10-3 圈内掉血 22（dmg_base 22 × atk_ratio 1.0）",
		absf(dropped - 22.0) < 0.01, "dropped=%.2f" % dropped)
	_check("A10-4 圈内零 dodge（命中不发）", _dodge_count == dodge1,
		"dodge %d→%d" % [dodge1, _dodge_count])


# ── A12：授盾数值（帽 5 / 刷新 10s / 橙先于蓝） ───────────────────
func _test_a12_shield_values() -> void:
	print("── A12 授盾数值：帽 5、刷新 10s、橙分支先于蓝盾 ──")
	var p: Player = _gl.player
	p.temp_shield_stacks = 0
	p.temp_shield_left = 0.0
	p._dodge_frame_stamp = -1
	for i in range(6):
		p._dodge_frame_stamp = -1                 # R253 同帧合并语义——手动归零模拟跨帧逐躲
		p._on_mine_dodged(Vector2.ZERO)
	_check("A12-1 跨帧连躲 6 次钳 5（TEMP_SHIELD_MAX）", p.temp_shield_stacks == 5,
		"stacks=%d" % p.temp_shield_stacks)
	_check("A12-2 叠层整体刷新 ≈10s（TEMP_SHIELD_TIME）", p.temp_shield_left >= 9.99,
		"left=%.2f" % p.temp_shield_left)
	# 橙盾吸收先于蓝盾（整击吞下）
	p.invuln_left = 0.0
	p.temp_shield_stacks = 1
	p.temp_shield_left = 5.0
	p.shield_interval = 5.0
	p.shield_ready = true
	var hp0 := p.hp
	p.take_contact_damage(30.0)
	_check("A12-3 橙先于蓝：橙耗尽、蓝盾就绪保住、hp 不动",
		p.temp_shield_stacks == 0 and p.shield_ready and is_equal_approx(p.hp, hp0),
		"stacks=%d hp %.1f→%.1f" % [p.temp_shield_stacks, hp0, p.hp])


# ── A11：BossMine 回归（设计 §1.6 A11 原文=r249 套件复跑承担） ─────
# 本套件不重复实现 BossMine 用例；运行序上先跑本套件、再跑 test_r249_mine_shield
# 确认 B1/B2/F1/F2/G1/G2 原语义绿。

# ── 收尾 ──────────────────────────────────────────────────────────
func _teardown() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null
