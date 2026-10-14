# tests/runner/rcu_faqi_cases.gd
# 二cu「灵剑/法器表现重构」用例体（由 test_rcu_faqi.gd 入口在 autoload 就绪后运行时 load
# 编译——-s 模式入口编译早于 autoload 全局名注册，cases 禁 test_ 前缀防电池 glob 误收）。
# 覆盖 G1~G7（分组见套件头注；真源 FEEDBACK_TRACKER 二cu #1~#6——剑光刺出+斜剑痕/图标
# 与化身重做/法器合一出击/DNF 巨剑直刃/旧阔剑轮廓转灵剑再细发光）：
#   G1 剑光弹体：flight_tex(false/true) 64px 非空互异 + SWORD_VIS_MULT/SWORD_TRAIL_LEN 常量锚
#   G2 命中剑痕发点：EventBus.sword_mark 直连计数——命中敌位 <20px + 角≈来速角；无命中零发点
#   G3 FX 剑痕池：ElementalFxLayer 裸实例手驱——16 槽 / 斜置 45° / 寿命后隐藏 / 低档关（还原档位；
#     发点经 EventBus.sword_mark 真信号驱动——_ready connect 接线在内，接线被删即红）
#   G4 化身出击：player 委托口 + W11/W12 开火 → 对应 _sorties 槽 active + 出段→回段→归位
#   G5 出膛口=化身：muzzle 距玩家 40~130px 化身环带（宽容断言，二cv 环分层改动不破）且 ≠ 本体位
#   G6 W13 直刃：greatsword poly[1]≈(118,14.4) + saber 原表回归锁 + 图标双版 56px 互异
#   G7 源码锚：flying_sword_weapon.gd 含「外辉光」「二cu」×1.9/streak；arc_slash.gd 含 DNF 直刃注释
# 结构仿 r245_diff_star_cases（_check + fail_count + EXPECTED_TOTAL 总项数断言防假绿——
# R231 教训）；夹具仿 r243_lingjian_cases（GameLoop 装配 + 桩敌 + crit=0 探针确定性）。
# 纪律：headless 测试档自动隔离（不动真实 user:// 存档）；化身槽位经 entries.find 动态定位
#（不假设本夹具槽位排布——初始武器在册不破读数）；G4/G5 段 tree.paused 短暂独占冻结化身
# _process（环位/态机手驱确定性，测完还原）；G3 fx_quality 改档测完还原（Meta 单一真源）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 120.0
const EXPECTED_TOTAL := 34   # 二cy +2（G1e 剑形截面 + G7d 缩放锚）
const FX_SRC := "res://scripts/combat/weapon/melee/flying_sword_weapon.gd"
const ARC_SRC := "res://scripts/combat/weapon/melee/arc_slash.gd"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _w11: FlyingSwordWeapon = null
var _w12: GroundAxeWeapon = null
var _oa: WeaponOrbitAvatars = null            # 化身层（G4/G5——player._ready 恒建）
var _fx: ElementalFxLayer = null              # G3 裸 FX 层（用完即 free）
var _marks_rx: Array[Dictionary] = []         # G2 sword_mark 直连记录（{pos, angle}）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261008)
	if not _boot_game_loop():
		_check("前置：GameLoop 装配", false, "start_run 失败")
		_report()
		return
	await tree.process_frame
	await tree.process_frame
	_test_g1_flight_tex()
	await _test_g2_sword_mark_event()
	await _test_g3_mark_pool()
	await _test_g4_avatar_sortie()
	_test_g5_muzzle_on_avatar()
	_test_g6_greatsword_blade()
	_test_g7_source_anchor()
	_teardown()
	_check("⑦ 套件总项数（EXPECTED=%d——R231 假绿教训）" % EXPECTED_TOTAL,
		_pass + _fail + 1 == EXPECTED_TOTAL, "实得 %d" % (_pass + _fail + 1))
	_report()


func _report() -> void:
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])


func fail_count() -> int:
	return _fail


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s（%s）" % [p_name, p_detail])
		print("  FAIL | %s（%s）" % [p_name, p_detail])


# ── 夹具（r243_lingjian_cases 同式） ──────────────────────────────
func _boot_game_loop() -> bool:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "RcuFaqiGameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	var ok: bool = _gl.start_run()
	_gl.state = GameConst.GameStatus.MENU        # 冻结帧序——全部手动驱动（r241 同式）
	_gl.player.set("max_hp", 1000000.0)
	_gl.player.set("hp", 1000000.0)
	_gl.player.global_position = Vector2(360.0, 640.0)   # 居中（几何确定性）
	_gl.player.set("unlocked_slots", 5)
	_w11 = _add_w11()
	_oa = _gl.player.orbit_avatars as WeaponOrbitAvatars
	return ok and _w11 != null


func _teardown() -> void:
	tree.paused = false                          # G4/G5 段暂停占用的兜底还原
	RunSave.clear()
	_release_all_proj()
	_clear_enemies()
	if _fx != null:
		_fx.free()
		_fx = null
	if _gl != null:
		_gl.free()
		_gl = null


func _add_w11() -> FlyingSwordWeapon:
	# 装备 W11 + 探针确定性（crit=0 副本数据 + meta 修正归零——r243 同式）
	var w := _gl.player.add_weapon(_gl.registry.get_weapon(&"W11_spirit_sword")) as FlyingSwordWeapon
	if w != null:
		w.data = w.data.duplicate(true)
		w.data.crit_rate = 0.0
		w.meta_atk_pct = 0.0
		w.call(&"_invalidate_panel")
	return w


func _add_w12() -> GroundAxeWeapon:
	# 装备 W12（掷斧化身出击面）——探针同式（伤害确定性对本套件非关键，口径对齐防渗）
	var w := _gl.player.add_weapon(_gl.registry.get_weapon(&"W12_ground_axe")) as GroundAxeWeapon
	if w != null:
		w.data = w.data.duplicate(true)
		w.data.crit_rate = 0.0
		w.meta_atk_pct = 0.0
		w.call(&"_invalidate_panel")
	return w


func _strip_traits() -> void:
	if _w11 != null and _w11.trait_stack != null:
		_w11.trait_stack.traits.clear()
		_w11.call(&"_invalidate_panel")
	if _w12 != null and _w12.trait_stack != null:
		_w12.trait_stack.traits.clear()
		_w12.call(&"_invalidate_panel")


func _spawn_e(p_pos: Vector2, p_hp: float = 100000.0) -> Enemy:
	var enemy := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	enemy.spawn(_gl.registry.get_enemy(&"E1_grunt"), 1, 0)
	enemy.set("speed", 0.0)                      # 静止敌（几何确定性）
	enemy.set("max_hp", p_hp)
	enemy.set("hp", p_hp)
	enemy.global_position = p_pos
	_gl.spawner.active.append(enemy)
	_gl.enemy_grid.rebuild(_gl.spawner.active)
	return enemy


func _clear_enemies() -> void:
	if _gl == null:
		return
	for e in _gl.spawner.active.duplicate():
		_gl.spawner.active.erase(e)
		(_gl.pools[&"enemy"] as EnemyPool).release(e)
	_gl.enemy_grid.rebuild(_gl.spawner.active)


func _my_swords(p_gen: int = 0) -> Array[ProjectileBase]:
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var out: Array[ProjectileBase] = []
	for p in pool.active_projectiles():
		var pb := p as ProjectileBase
		if pb != null and not pb.is_clean and int(pb.weapon_uid) == _w11.uid \
				and int(pb.generation) == p_gen:
			out.append(pb)
	return out


func _release_my_swords() -> void:
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var victims: Array = []
	for p in pool.active_projectiles():
		var pb := p as ProjectileBase
		if pb != null and not pb.is_clean and int(pb.weapon_uid) == _w11.uid:
			victims.append(pb)
	for v in victims:
		pool.release(v)


func _release_all_proj() -> void:
	if _gl == null:
		return
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var victims: Array = []
	for p in pool.active_projectiles():
		victims.append(p)
	for v in victims:
		var pb := v as ProjectileBase
		if pb != null and not pb.is_clean:
			pool.release(pb)


func _fly_until_recycled(p_sword: ProjectileBase, p_max_ticks: int = 240) -> int:
	# 逐 tick 推进至回收（命中/寿命任一路径）；返回实推 tick 数
	var n := 0
	while n < p_max_ticks and not p_sword.is_clean:
		GameConfig.frame_stamp += 1              # E-03 帧闸门推进（r243 夹具同式）
		p_sword.tick(DT)
		n += 1
	return n


func _rec_sword_mark(p_pos: Vector2, p_angle: float) -> void:
	# EventBus.sword_mark 直连记录器（G2——信号即证据，不经 FX 层）
	_marks_rx.append({"pos": p_pos, "angle": p_angle})


func _avatar_idx_of(p_w: WeaponBase) -> int:
	# 化身槽位动态定位（entries 序 = 真实武器槽序 + 副本/镜面环尾——不假设本夹具
	# 初始武器排布，防「假设 W11 恒槽 0」的脆断言）
	if _oa == null:
		return -1
	var entries: Array = _oa._entries_of(_gl.player)
	return entries.find(p_w)


func _sortie_of(p_idx: int) -> Dictionary:
	# 出击态槽安全读（idx 越界 = 空表——调用侧 .get 判 false 不崩）
	if _oa == null or p_idx < 0 or p_idx >= _oa._sorties.size():
		return {}
	return _oa._sorties[p_idx]


# ══ G1：剑光弹体（flight_tex 双版 + 放大/拖尾常量锚） ══
func _test_g1_flight_tex() -> void:
	print("── G1：剑光弹体（flight_tex 64px 双版互异 + 常量锚） ──")
	var tex_a: ImageTexture = FlyingSwordWeapon.flight_tex(false)
	var tex_b: ImageTexture = FlyingSwordWeapon.flight_tex(true)
	var size_ok := false
	var data_diff := false
	if tex_a != null and tex_b != null:
		size_ok = tex_a.get_size() == Vector2(64.0, 64.0) \
			and tex_b.get_size() == Vector2(64.0, 64.0)
		var ia: Image = tex_a.get_image()
		var ib: Image = tex_b.get_image()
		if ia != null and ib != null:
			data_diff = ia.get_data() != ib.get_data()
	_check("G1a flight_tex(false/true) 非空且 64×64（光刃画布）",
		tex_a != null and tex_b != null and size_ok,
		"a=%s b=%s size_ok=%s" % [str(tex_a != null), str(tex_b != null), str(size_ok)])
	_check("G1b 基础银蓝/质变鎏金光刃图像互异（逐像素数据比对）", data_diff)
	_check("G1c 常量锚 SWORD_VIS_MULT==3.2（剑光放大——火箭读感退役面）",
		is_equal_approx(float(ProjectileBase.SWORD_VIS_MULT), 3.2),
		"mult=%s" % str(ProjectileBase.SWORD_VIS_MULT))
	_check("G1d 常量锚 SWORD_TRAIL_LEN==42.0（刺击残影 30→42 加长）",
		is_equal_approx(float(ProjectileBase.SWORD_TRAIL_LEN), 42.0),
		"trail=%s" % str(ProjectileBase.SWORD_TRAIL_LEN))
	# 二cy 剑形横截面像素锁（真剑形=护手行宽于剑刃行——光条版无此结构；画布中心
	# (32,32)，剑体 y -30..+15 → 行 2..47：刃半宽 2.6@y20、护手半宽 5.5@y35.5、柄@y41）
	var shape_ok := false
	var shape_dbg := "no-tex"
	if tex_a != null:
		var img_s: Image = tex_a.get_image()
		if img_s != null:
			var blade_a := img_s.get_pixel(32, 20).a
			var guard_a := img_s.get_pixel(27, 35).a
			var guard_row_blade_col_a := img_s.get_pixel(27, 20).a
			var grip_a := img_s.get_pixel(32, 41).a
			shape_dbg = "b=%.2f g=%.2f gb=%.2f grip=%.2f" % [blade_a, guard_a,
				guard_row_blade_col_a, grip_a]
			# 刃行中轴实心；护手行 x-4.5 处实心（≥0.7）且同列刃行仅外辉光（≤0.5——
			# 护手横向显著宽于刃=十字结构）；柄行中轴实心
			shape_ok = blade_a > 0.7 and guard_a > 0.7 and guard_row_blade_col_a < 0.5 \
				and grip_a > 0.7
	_check("G1e 剑形横截面（护手行宽于刃行=十字结构 + 柄在——二cy 真剑形，子弹/光条版无此截面）",
		shape_ok, shape_dbg)


# ══ G2：命中剑痕发点（EventBus.sword_mark 直连） ══
func _test_g2_sword_mark_event() -> void:
	print("── G2：命中剑痕发点（命中敌位 + 来速角；无命中零发点） ──")
	_strip_traits()
	EventBus.sword_mark.connect(_rec_sword_mark)
	var e := _spawn_e(Vector2(360.0, 430.0))     # 正上方 210px 桩敌（r243 case1 同位）
	var fired: bool = _w11.try_fire()
	var swords := _my_swords()
	if not fired or swords.is_empty():
		_check("G2 前置：W11 try_fire 出剑", false,
			"fired=%s n=%d" % [str(fired), str(swords.size())])
		EventBus.sword_mark.disconnect(_rec_sword_mark)
		_clear_enemies()
		return
	var ang0: float = (swords[0] as ProjectileBase).velocity.angle()   # 来速角（直线飞行恒定）
	var ticks := _fly_until_recycled(swords[0], 240)
	var hit_ok := _marks_rx.size() >= 1
	_check("G2a 命中即发剑痕事件（计数 ≥1）", hit_ok,
		"rx=%d ticks=%d" % [_marks_rx.size(), ticks])
	if hit_ok:
		var m: Dictionary = _marks_rx[0]
		var mpos: Vector2 = m["pos"]
		var mang: float = m["angle"]
		_check("G2b 剑痕 pos 距敌位 <20px（目标身上落痕）",
			mpos.distance_to(e.global_position) < 20.0,
			"d=%s e=%s mark=%s" % [str(mpos.distance_to(e.global_position)),
			str(e.global_position), str(mpos)])
		_check("G2c 剑痕 angle≈来速角（|Δ|<0.05rad——刺击方向一致）",
			absf(wrapf(mang - ang0, -PI, PI)) < 0.05,
			"mark=%s vel=%s" % [str(mang), str(ang0)])
	# 无命中零发点（清场后自然飞完寿命——表现层不发噪音事件）
	_clear_enemies()
	var quiet0 := _marks_rx.size()
	_w11.try_fire()
	swords = _my_swords()
	var n_tick := 0
	if not swords.is_empty():
		n_tick = _fly_until_recycled(swords[0], 240)
	_check("G2d 无命中零发点（剑自然回收，计数不变）",
		_marks_rx.size() == quiet0 and n_tick > 0,
		"quiet=%d→%d n_tick=%d" % [quiet0, _marks_rx.size(), n_tick])
	_release_my_swords()
	EventBus.sword_mark.disconnect(_rec_sword_mark)
	_clear_enemies()


# ══ G3：FX 剑痕池（裸实例手驱 tick；发点走 EventBus.sword_mark 真信号） ══
func _test_g3_mark_pool() -> void:
	print("── G3：FX 剑痕池（16 槽 / 斜置 45° / 寿命隐藏 / 低档关） ──")
	_fx = ElementalFxLayer.new()
	_fx.name = "RcuFaqiFxLayerUnderTest"
	tree.get_root().add_child(_fx)
	await tree.process_frame                     # _ready：建池 + 订阅
	_check("G3a 剑痕池 16 槽（MARK_COUNT——齐射 7+子剑 8 峰值预算）",
		_fx._marks.size() == 16, "n=%d" % _fx._marks.size())
	# 档位钳制：先钉高档（预算 2=主+副痕全量），原档快照尾后还原——防测试档脏位假阴
	var q_orig: int = int(Meta.settings("fx_quality"))
	Meta.set_setting("fx_quality", 2)
	var idx: int = int(_fx._mark_idx) % 16       # 本次落位槽（handler 取旧值再自增）
	# 二cv 评审追补：经 EventBus.sword_mark 真信号驱动（原直调 _on_sword_mark——
	# _ready 里 sword_mark→FX 层的 connect 接线被删时套件仍全绿的覆盖缺口）。GameLoop
	# 内置 FX 层同订此信号只多落一枚屏上痕，无断言依赖，headless 零扰。
	EventBus.sword_mark.emit(Vector2(200.0, 300.0), 0.0)
	var root: Node2D = _fx._marks[idx]["root"]
	_check("G3b 落位点亮且斜置 45°（angle 0 + PI/4，槽序抖动 ±0.10 容差内）",
		root.visible and absf(root.rotation - PI * 0.25) < 0.15,
		"vis=%s rot=%s" % [str(root.visible), str(root.rotation)])
	for i in range(6):
		_fx.tick(0.05)                           # 手驱 0.30s > MARK_LIFE 0.22s
	_check("G3c 寿命耗尽自动隐藏（visible==false）", not root.visible,
		"vis=%s" % str(root.visible))
	# 低档关：SWORD_MARK_BUDGET[0]==0 短路——不点亮（测完还原原档；同走真信号）
	Meta.set_setting("fx_quality", 0)
	idx = int(_fx._mark_idx) % 16
	EventBus.sword_mark.emit(Vector2(200.0, 300.0), 0.0)
	var root2: Node2D = _fx._marks[idx]["root"]
	_check("G3d fx_quality=0 低档不点亮（SWORD_MARK_BUDGET 分档口）",
		int(Meta.settings("fx_quality")) == 0 and not root2.visible,
		"q=%s vis=%s" % [str(Meta.settings("fx_quality")), str(root2.visible)])
	Meta.set_setting("fx_quality", q_orig)       # 档位还原（Meta 单一真源不跨套件渗）
	_fx.free()
	_fx = null


# ══ G4：法器合一·化身出击（委托口 + 出段→回段→归位） ══
func _test_g4_avatar_sortie() -> void:
	print("── G4：化身出击（player 委托 + W11/W12 开火自动触发 + 态机） ──")
	_check("G4a player.weapon_avatar_sortie 委托口存在（has_method）",
		_gl.player.has_method(&"weapon_avatar_sortie"))
	_w12 = _add_w12()
	await tree.process_frame                     # 化身层 _process：_ensure_avatars + visible 置位
	await tree.process_frame
	_check("G4b W12 装备为 GroundAxeWeapon + 化身层槽位就绪（≥2 槽）",
		_w12 is GroundAxeWeapon and _oa != null and _oa._avatars.size() >= 2,
		"w12=%s oa=%s n=%s" % [str(_w12 is GroundAxeWeapon), str(_oa != null),
		str(_oa._avatars.size() if _oa != null else -1)])
	# 无口环境零副作用（纯表现通道纪律——player 无委托口时静默跳过，裸桩调用即冒烟）
	# ＋有口委托可观察锁（二cv 评审追补：原 G4c 断言字面恒真只能证「执行到此处未崩」
	# ——补 spy 桩断委托链真发生且武器参正确，_notify 逻辑退化（误早退/漏委托/参数
	# 错位）在此即红，不再依赖「没抛错」的间接推断）
	var player_bak: Node2D = _w11.player
	var stub := Node2D.new()                     # 裸桩无 weapon_avatar_sortie 口
	_w11.player = stub
	_w11._notify_avatar_sortie(Vector2.UP, 100.0)   # 必须静默返回不崩
	_w11.player = player_bak
	stub.free()
	_check("G4c W11._notify_avatar_sortie 无口环境零副作用（裸桩静默跳过不崩）", true)
	var spy_src := GDScript.new()
	spy_src.source_code = "extends Node2D\n" \
		+ "var calls: Array = []\n" \
		+ "func weapon_avatar_sortie(p_w, p_to) -> void:\n" \
		+ "\tcalls.append([p_w, p_to])\n"
	spy_src.reload()
	var spy := Node2D.new()
	spy.name = "RcuSortieSpy"
	spy.set_script(spy_src)
	_w11.player = spy
	_w11._notify_avatar_sortie(Vector2.UP, 100.0)
	_w11.player = player_bak
	var calls_v: Variant = spy.get("calls")
	var calls: Array = calls_v if calls_v is Array else []
	var delegated := false
	if calls.size() == 1 and calls[0] is Array:
		var entry: Array = calls[0]
		delegated = entry.size() == 2 and entry[0] == _w11
	spy.free()
	_check("G4c-2 W11._notify_avatar_sortie 委托链可观察（有口桩被调恰 1 次且武器参=self）",
		delegated, "calls=%s" % str(calls_v))
	if _oa == null or _oa._avatars.size() < 2:
		_check("G4d W11 开火→化身出击 active", false, "化身层不可用（G4b 失败连带）")
		_check("G4e 出段到位", false, "skip")
		_check("G4f 回段归位", false, "skip")
		_check("G4g W12 开火→化身出击 active", false, "skip")
		return
	_clear_enemies()
	var i11 := _avatar_idx_of(_w11)
	var fired11: bool = _w11.try_fire()          # 开火即出击（同步委托链 try_fire→_notify→begin_sortie）
	var s11 := _sortie_of(i11)
	_check("G4d W11 开火→对应化身 _sorties 槽 active==true",
		fired11 and i11 >= 0 and bool(s11.get("active", false)),
		"fired=%s idx=%d active=%s" % [str(fired11), i11, str(s11.get("active", "n/a"))])
	if not (fired11 and i11 >= 0):
		_check("G4e 出段到位", false, "skip")
		_check("G4f 回段归位", false, "skip")
	else:
		# 态机手驱（暂停冻结 _process——两次驱动即出段→回段全流程，确定性不竞速）。
		# p_home_r 按二cv#3 环分层口径现算（RING_R + 层号×RING_STEP，_process 同式）——
		# 分层改动只改半径来源不改本断言
		var av11: Sprite2D = _oa._avatars[i11]
		var layers: Array[int] = _oa._ring_layers(_oa._entries_of(_gl.player))
		var home_r: float = WeaponOrbitAvatars.RING_R \
			+ float(layers[i11] if i11 < layers.size() else 0) * WeaponOrbitAvatars.RING_STEP
		tree.paused = true
		s11["t"] = 0.0
		_oa._tick_sortie(i11, av11, WeaponOrbitAvatars.SORTIE_OUT_S, 2, home_r)
		var out_ok := int(s11.get("phase", 0)) == 1 \
			and av11.scale.x > WeaponOrbitAvatars.AVATAR_SCALE
		_check("G4e 出段到位（phase 0→1 + 出击放大 %s×）" % str(WeaponOrbitAvatars.SORTIE_SCALE),
			out_ok, "phase=%s scale=%s" % [str(s11.get("phase")), str(av11.scale)])
		s11["t"] = 0.0
		_oa._tick_sortie(i11, av11, WeaponOrbitAvatars.SORTIE_BACK_S, 2, home_r)
		_check("G4f 回段归位（active 复位 + scale 复常态）",
			not bool(s11.get("active", true))
			and is_equal_approx(av11.scale.x, WeaponOrbitAvatars.AVATAR_SCALE),
			"active=%s scale=%s" % [str(s11.get("active")), str(av11.scale)])
		tree.paused = false
	# W12 同标准（用户「另外俩都按这个标准做」——开火即化身扑向首斧落点）
	var e := _spawn_e(Vector2(360.0, 430.0))
	var i12 := _avatar_idx_of(_w12)
	var fired12: bool = _w12.try_fire()
	var s12 := _sortie_of(i12)
	_check("G4g W12 开火→对应化身 _sorties 槽 active==true",
		fired12 and i12 >= 0 and bool(s12.get("active", false)),
		"fired=%s idx=%d active=%s" % [str(fired12), i12, str(s12.get("active", "n/a"))])
	_clear_enemies()


# ══ G5：出膛口=化身（环带宽容断言——二cv 环分层改动不破） ══
func _test_g5_muzzle_on_avatar() -> void:
	print("── G5：出膛口=化身（muzzle 在化身环带 40~130px 且 ≠ 本体位） ──")
	if _oa == null or _oa._avatars.size() < 2:
		_check("G5 W11 muzzle 在化身环带", false, "化身层不可用（G4b 失败连带）")
		_check("G5 W12 muzzle 在化身环带", false, "skip")
		return
	tree.paused = true                           # 冻结化身 _process——环位手设确定性
	for i in range(_oa._avatars.size()):
		_oa._avatars[i].position = Vector2(58.0, 0.0)   # RING_R 口径环位（右方）
		_oa._avatars[i].rotation = 0.0                  # 朝向归零（刃类 facing=−90°=UP）
	var ppos: Vector2 = _gl.player.global_position
	var m11: Vector2 = _w11.muzzle_position()
	var m12: Vector2 = _w12.muzzle_position()
	var d11 := ppos.distance_to(m11)
	var d12 := ppos.distance_to(m12)
	tree.paused = false
	_check("G5a W11 muzzle_position 在化身环带（40~130px，实得 %s）" % str(d11),
		d11 >= 40.0 and d11 <= 130.0, "d=%s" % str(d11))
	_check("G5b W11 muzzle ≠ 玩家本体位", d11 > 1.0, "d=%s" % str(d11))
	_check("G5c W12 muzzle_position 在化身环带（40~130px，实得 %s）" % str(d12),
		d12 >= 40.0 and d12 <= 130.0, "d=%s" % str(d12))
	_check("G5d W12 muzzle ≠ 玩家本体位", d12 > 1.0, "d=%s" % str(d12))


# ══ G6：W13 DNF 巨剑直刃（顶点表 + 图标双版） ══
func _test_g6_greatsword_blade() -> void:
	print("── G6：W13 直刃（greatsword poly[1]≈(118,14.4) + saber 回归锁 + 图标双版） ──")
	var gs := ArcSlash.new()
	gs.blade_style = ArcSlash.STYLE_GREATSWORD
	var gp := gs._blade_polygon()
	var gp1: Vector2 = gp[1] if gp.size() > 1 else Vector2.INF
	_check("G6a greatsword 直刃表 8 顶点且 poly[1]≈(118,14.4)（9×1.6 平行等宽直刃）",
		gp.size() == 8 and absf(gp1.x - 118.0) < 1e-3 and absf(gp1.y - 14.4) < 1e-3,
		"n=%d p1=%s" % [gp.size(), str(gp1)])
	gs.free()
	var sb := ArcSlash.new()                     # 缺省 saber（W9 原表回归锁）
	var sp := sb._blade_polygon()
	var sp1: Vector2 = sp[1] if sp.size() > 1 else Vector2.INF
	var sp3: Vector2 = sp[3] if sp.size() > 3 else Vector2.INF
	_check("G6b saber 原表不变（8 顶点 + p1=(95,14) + p3=(150,-10) 回归锁）",
		sp.size() == 8 and absf(sp1.x - 95.0) < 1e-3 and absf(sp1.y - 14.0) < 1e-3
		and absf(sp3.x - 150.0) < 1e-3 and absf(sp3.y - (-10.0)) < 1e-3,
		"n=%d p1=%s p3=%s" % [sp.size(), str(sp1), str(sp3)])
	sb.free()
	var tex_a: ImageTexture = OrbitWeapon.weapon_icon_tex(false)
	var tex_b: ImageTexture = OrbitWeapon.weapon_icon_tex(true)
	var size_ok := false
	var data_diff := false
	if tex_a != null and tex_b != null:
		size_ok = tex_a.get_size() == Vector2(56.0, 56.0) \
			and tex_b.get_size() == Vector2(56.0, 56.0)
		var ia: Image = tex_a.get_image()
		var ib: Image = tex_b.get_image()
		if ia != null and ib != null:
			data_diff = ia.get_data() != ib.get_data()
	_check("G6c W13 图标双版非空 56×56（DNF 巨剑重画面）",
		tex_a != null and tex_b != null and size_ok,
		"a=%s b=%s size_ok=%s" % [str(tex_a != null), str(tex_b != null), str(size_ok)])
	_check("G6d W13 默认黑金/质变裂纹图标互异（逐像素数据比对）", data_diff)


# ══ G7：源码锚（灵剑剑形弹体 + 发光的证据链） ══
func _test_g7_source_anchor() -> void:
	print("── G7：源码锚（外辉光 / 二cy 剑形 / ×1.9 / 十字护手 / DNF 直刃注释） ──")
	var src: String = FileAccess.get_file_as_string(FX_SRC)
	_check("G7a flying_sword_weapon.gd 含「外辉光」+「二cy」锚（剑形弹体+发光证据）",
		not src.is_empty() and src.contains("外辉光") and src.contains("二cy"),
		"len=%d" % src.length())
	_check("G7b 源码含图标外辉光 ×1.9 层 + 剑形弹体证据（sword_blade 刃形 + 十字护手——二cy 真剑形，光条 streak 已退役）",
		src.contains("pt.x * 1.9") and src.contains("sword_blade") and src.contains("十字护手"))
	var arc_src: String = FileAccess.get_file_as_string(ARC_SRC)
	_check("G7c arc_slash.gd 含 DNF 直刃注释（W13 巨剑直刃重画证据）",
		arc_src.contains("DNF"))
	_check("G7d arc_slash.gd 含二cy#1 剑体随判定半径缩放锚（blade_visual_scale——剑尖贴虚线圈）",
		arc_src.contains("blade_visual_scale") and arc_src.contains("BLADE_TABLE_R"))
