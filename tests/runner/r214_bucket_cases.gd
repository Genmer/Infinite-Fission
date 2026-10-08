# tests/runner/r214_bucket_cases.gd
# R214 用例体：树序分桶合批（E'）+ 磁吸吸收分帧 + 双驱动修复。
# 背景（vc21 真机定案）：dc 与 fps 强负相关（dc≤400 → fps 95-120 / dc>550 → <50）；
# 满载 dc 700-1000 大头=敌本体×120+弹×百发，同贴图实体池化树序交错断批。
#   E'：敌/弹池挂 TexBucketHost——按贴图（Texture2D 引用键）reparent 进同贴图桶
#       （桶=host 子级原点 Node2D），同贴图相邻 → 2D 批处理合并。
#   磁吸帽：_tick_magnetized_shards 同帧吸收 ≤24 片（帽满冻结圈内原地）——vc21
#       选卡窗磁键 156ms 尖峰（吸收→gain_xp×N 链）根治。
#   双驱动修复：磁吸片原帧序②（全量）+⑦（磁吸）各 tick 一次=速度双倍——②跳过磁吸片
#       （⑦独占）+ MAGNET_SPEED 520→1040 补偿（单帧位移恒等观感零变化）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const PLAYER_HOME := Vector2(360.0, 900.0)
const DT := 1.0 / 60.0

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	_test_1_bucket_assembly()
	_enter_run_frozen()
	_test_2_enemy_bucket_place_release()
	_test_3_projectile_bucket_place()
	_test_4_magnet_absorb_cap()
	_test_5_dual_drive_fix()
	_test_6_null_host_compatible()
	_teardown_game_loop()
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


func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R214GameLoopUnderTest"
	tree.get_root().add_child(_gl)


func _enter_run_frozen() -> void:
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_gl.state = GameConst.GameStatus.MENU
	_gl.player.global_position = PLAYER_HOME


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


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


# ── ① boot 装配：敌/弹池 host 在位 ──────────────────────────────
func _test_1_bucket_assembly() -> void:
	print("── ① 桶装配 ──")
	var ehost: Node = (_gl.pools[&"enemy"] as ObjectPool).bucket_host
	var phost: Node = (_gl.pools[&"projectile"] as ObjectPool).bucket_host
	_check("敌池/弹池 bucket_host 装配（boot _attach_bucket_host）",
		ehost != null and phost != null, "e=%s p=%s" % [str(ehost), str(phost)])
	_check("host 挂池下且 home=池根（unplace 归位目标）",
		ehost != null and ehost.get_parent() == _gl.pools[&"enemy"]
			and ehost.get("_home") == _gl.pools[&"enemy"],
		"parent=%s home=%s" % [str(ehost.get_parent() if ehost != null else null),
			str(ehost.get("_home") if ehost != null else null)])
	_check("其余四池不挂（popup 同字体天然相邻；laser/particle 不在刀面）——R216 刀① xp 池已补挂（碎片 18 贴图变体树序交错断批）",
		(_gl.pools[&"popup"] as ObjectPool).bucket_host == null
			and (_gl.pools[&"xp"] as ObjectPool).bucket_host != null
			and (_gl.pools[&"xp"] as ObjectPool).bucket_host.get_parent() == _gl.pools[&"xp"],
		"popup=%s xp=%s" % [str((_gl.pools[&"popup"] as ObjectPool).bucket_host),
			str((_gl.pools[&"xp"] as ObjectPool).bucket_host)])
	var spawner_src := _read_src("res://scripts/entities/wave/enemy_spawner.gd")
	_check("spawner 注入序源级锚（bucket_host 在 spawn 前——_sync_visual 尾消费）",
		spawner_src.find("enemy.bucket_host = pool.bucket_host") < spawner_src.find("enemy.spawn(data,"),
		"注入序错位")


func _read_src(p_path: String) -> String:
	var f := FileAccess.open(p_path, FileAccess.READ)
	var s := f.get_as_text() if f != null else ""
	if f != null:
		f.close()
	return s


# ── ② 敌分桶：place 同桶相邻 / 换贴图换桶 / release 归位 / local 语义 ──
func _test_2_enemy_bucket_place_release() -> void:
	print("── ② 敌分桶 ──")
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var host: Node = pool.bucket_host
	var e1 := pool.acquire() as Enemy
	e1.bucket_host = host                       # 测试直连注入（产品路径=spawner spawn 前）
	e1.spawn(_fixture_enemy(&"E_R214_A", 100.0), 1, 0)
	e1.position = Vector2(100.0, 200.0)
	var g_before: Vector2 = e1.global_position
	_check("spawn 后落桶（parent=host 子桶而非池根）",
		e1.get_parent() != pool and host.is_ancestor_of(e1),
		"parent=%s" % str(e1.get_parent()))
	_check("落桶后 global_position 恒等（桶原点无变换）",
		e1.global_position == g_before, "before=%s after=%s" % [str(g_before), str(e1.global_position)])
	var e2 := pool.acquire() as Enemy
	e2.bucket_host = host
	e2.spawn(_fixture_enemy(&"E_R214_A", 100.0), 1, 0)
	_check("同贴图敌同桶（桶内相邻=合批前提）",
		e1.get_parent() == e2.get_parent(), "p1=%s p2=%s" % [str(e1.get_parent()), str(e2.get_parent())])
	var e3 := pool.acquire() as Enemy
	e3.bucket_host = host
	e3.spawn(_fixture_enemy(&"E_R214_B", 100.0), 1, 0)
	e3.get_parent()  # 贴图取决于 kind 解析——不同 id 可能同 kind 兜底；不锁异桶，只锁桶数 ≥1
	var buckets: int = host.get_child_count()
	_check("桶惰性建（host 子桶 ≥1）", buckets >= 1, "buckets=%d" % buckets)
	# 换贴图换桶（boss 变脸路径：_place_in_bucket 再入）
	var old_parent: Node = e1.get_parent()
	var sprite: Sprite2D = e1.get("_sprite")
	var tex_bak: Texture2D = sprite.texture
	sprite.texture = TextureFactory.enemy_tex(&"volatile", false)
	e1.call(&"_place_in_bucket")
	_check("换贴图 → 换桶（变脸保合批）", e1.get_parent() != old_parent,
		"parent=%s" % str(e1.get_parent()))
	sprite.texture = tex_bak
	e1.call(&"_place_in_bucket")
	_check("换回贴图 → 回原桶", e1.get_parent() == old_parent, "parent=%s" % str(e1.get_parent()))
	# 评审修复回归锁：E4 挥发性敌三段变脸真实路径换桶（曾漏 _place_in_bucket——
	# 异贴图滞留旧桶=桶内断批；volatile_scared/volatile 为独立缓存贴图 → 独立桶）
	e1.set("_face_state", 2)
	e1.call(&"_set_volatile_face", 1)
	var p_scared: Node = e1.get_parent()
	_check("E4 变脸真实路径换桶（_set_volatile_face 自报）",
		p_scared != old_parent and host.is_ancestor_of(e1), "parent=%s" % str(p_scared))
	e1.call(&"_set_volatile_face", 0)
	_check("E4 变脸逐段换桶（scared 桶 ≠ calm 桶）",
		e1.get_parent() != p_scared and host.is_ancestor_of(e1), "parent=%s" % str(e1.get_parent()))
	# 归还归位
	pool.release(e1)
	pool.release(e2)
	pool.release(e3)
	_check("release 归位池根（unplace 统一口）",
		e1.get_parent() == pool and e2.get_parent() == pool and e3.get_parent() == pool,
		"p1=%s" % str(e1.get_parent()))
	var st: Dictionary = pool.stats()
	_check("池计数不受分桶影响（free 回满）",
		int(st["free"]) == int(st["capacity"]), "free=%d cap=%d" % [int(st["free"]), int(st["capacity"])])


# ── ③ 弹分桶：变体落桶 / 归还归位 ────────────────────────────────
func _test_3_projectile_bucket_place() -> void:
	print("── ③ 弹分桶 ──")
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var host: Node = pool.bucket_host
	var mine := pool.acquire() as ProjectileBase
	mine.pool = pool                            # 依赖注入（武器侧同款；弹 place 消费）
	mine.spawn({"velocity": Vector2.ZERO, "lifetime": 2.0, "team": 0})
	_check("我方弹落桶（spawn 置 is_clean=false → _sync_visual 落桶）",
		host.is_ancestor_of(mine), "parent=%s" % str(mine.get_parent()))
	var foe := pool.acquire() as ProjectileBase
	foe.pool = pool
	foe.spawn({"velocity": Vector2.ZERO, "lifetime": 2.0, "team": 1})
	_check("敌弹独立桶（阵营贴图不同——混排断批根治）",
		foe.get_parent() != mine.get_parent() and host.is_ancestor_of(foe),
		"p_mine=%s p_foe=%s" % [str(mine.get_parent()), str(foe.get_parent())])
	pool.release(mine)
	pool.release(foe)
	_check("弹 release 归位池根",
		mine.get_parent() == pool and foe.get_parent() == pool, "p=%s" % str(mine.get_parent()))


# ── ④ 磁吸吸收分帧帽：单帧 ≤24，多帧全收，总面值守恒 ─────────────
func _test_4_magnet_absorb_cap() -> void:
	print("── ④ 磁吸吸收帽 ──")
	_gl.state = GameConst.GameStatus.LEVEL_UP
	var pool := _gl.pools[&"xp"] as XPPool
	var shards: Array = _gl.get("active_shards")
	shards.clear()
	var player_pos: Vector2 = _gl.player.global_position
	var total := 0.0
	for i in range(160):
		var s := pool.acquire() as XpShard
		if s == null:
			break
		s.position = player_pos + Vector2(10.0, 0.0).rotated(TAU * float(i) / 160.0)
		s.activate(1.0, 1.0)
		s.force_magnet()
		shards.append(s)
		total += 1.0
	_check("ready_to_absorb 判据（圈内磁吸片）",
		(shards[0] as XpShard).ready_to_absorb(), "first not ready")
	# 守恒口径：xp_gained 信号累计（player.xp 是级内进度——入账途中升级会归零重计，
	# 直读 delta 会漏升掉的经验）。lambda 按值捕获 → 数组容器累加。
	var gained := [0.0]
	var on_xp := func(p_amount: float) -> void: gained[0] += p_amount
	EventBus.xp_gained.connect(on_xp)
	var xp0: float = _gl.player.xp
	_gl.call(&"_tick_magnetized_shards", DT)    # 单帧
	var after_first: int = shards.size()
	_check("单帧吸收帽 24（160 片只收 %d）" % (160 - after_first),
		160 - after_first == 24, "remaining=%d absorbed=%d" % [after_first, 160 - after_first])
	_check("帽满片冻结在场（active 且仍磁吸）",
		after_first > 0 and (shards[0] as XpShard).is_magnet(), "left=%d" % after_first)
	for f in range(40):                        # 多帧全收（160/24 ≈ 7 帧；余量防边界）
		_gl.call(&"_tick_magnetized_shards", DT)
	_check("多帧全部吸收（active_shards 清空）", shards.is_empty(), "left=%d" % shards.size())
	EventBus.xp_gained.disconnect(on_xp)
	_check("总面值守恒（xp_gained 信号累计 == 160 × 1.0）",
		is_equal_approx(gained[0], total), "gained=%f total=%f" % [gained[0], total])
	_gl.state = GameConst.GameStatus.MENU


# ── ⑤ 双驱动修复：磁吸片②不动 / ⑦单驱动 / 速度补偿恒等 ────────────
func _test_5_dual_drive_fix() -> void:
	print("── ⑤ 双驱动修复 ──")
	var pool := _gl.pools[&"xp"] as XPPool
	var shards: Array = _gl.get("active_shards")
	shards.clear()
	var player_pos: Vector2 = _gl.player.global_position
	var s := pool.acquire() as XpShard
	s.position = player_pos + Vector2(200.0, 0.0)   # 圈外磁吸飞行态
	s.activate(1.0, 1.0)
	s.force_magnet()
	shards.append(s)
	var pos0: Vector2 = s.global_position
	_gl.call(&"_tick_xp_shards", DT)            # 帧序②（修复后跳过磁吸片）
	_check("②段不再 tick 磁吸片（双驱动修复——位置不动）",
		s.global_position == pos0, "moved=%s" % str(s.global_position - pos0))
	_gl.call(&"_tick_magnetized_shards", DT)    # 帧序⑦（独占驱动）
	var moved: float = pos0.distance_to(s.global_position)
	_check("⑦段单 tick 位移 = 1040×DT（补偿后恒等旧双 tick）",
		is_equal_approx(moved, 1040.0 * DT), "moved=%f expect=%f" % [moved, 1040.0 * DT])
	pool.release(s)
	shards.clear()


# ── ⑥ 兼容：host=null 老路径零行为变化 ──────────────────────────
func _test_6_null_host_compatible() -> void:
	print("── ⑥ host=null 兼容 ──")
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var bak: Node = pool.bucket_host
	pool.bucket_host = null                     # 模拟未装配池
	var e := pool.acquire() as Enemy
	e.bucket_host = null                        # 直连池（老测试同款）
	e.spawn(_fixture_enemy(&"E_R214_C", 100.0), 1, 0)
	_check("host=null：spawn 后仍挂池根（零行为变化）",
		e.get_parent() == pool, "parent=%s" % str(e.get_parent()))
	pool.release(e)
	pool.bucket_host = bak
	# QA DEF-4 修复：原为恒真占位——补真断言（还原装配后新 spawn 确实回桶）
	var e2 := pool.acquire() as Enemy
	e2.bucket_host = bak
	e2.spawn(_fixture_enemy(&"E_R214_C", 100.0), 1, 0)
	_check("host 恢复后新 spawn 落桶",
		e2.get_parent() != pool and bak.is_ancestor_of(e2), "parent=%s" % str(e2.get_parent()))
	pool.release(e2)
