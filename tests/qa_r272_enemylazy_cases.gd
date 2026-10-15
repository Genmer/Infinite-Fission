# tests/qa_r272_enemylazy_cases.gd
# R272 V-C2 用例体：敌/xp 池 lazy_bucket_release 接线（game_loop _boot_build_pools 尾）。
# 病根（vc82 真机定谳）：敌死亡归池 unplace 整子树 reparent 回池根+波补 acquire place 再
# reparent，深载敌周转 ~1300 组/s×2 次整树摘挂（子树含 Area2D=物理空间重注册），步µs
# 27-33ms/步顶死 30Hz 档步预算。本套锁三面：
#   ① 装配面：敌/xp lazy 旗开（boot 接线）+ homing 无桶不在刀面 + projectile 不回退
#   ② 行为面：boost 开 release 留桶（不 reparent）/ 同贴图 acquire 复用零树进出
#（node_added/removed 计数=0——本刀核心验收）/ 换贴图自然换桶（低频 reparent 路径不破）
#   ③ 回退面：boost 关 release 归位池根（现状逐位——r214「release 归位池根」旧断言口径）
# 夹具纪律：perf_boost 盘档副作用（R270 泄漏事故）——cleanup 显式 erase + RunSave.clear；
# 敌件测试直连注入 bucket_host（产品路径=spawner spawn 前注入，r214 先例）；勿对归池件
# 二次 release（rejected_release_count 防御口）。
extends RefCounted


const MAIN_SCENE := "res://scenes/main.tscn"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _added: int = 0
var _removed: int = 0
var _saved_settings: Dictionary = {}         # R270 盘档毒口径：入口快照，cleanup 整字典还原+_save


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_saved_settings = Meta._settings.duplicate(true)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	tree.node_added.connect(_on_node_added)
	tree.node_removed.connect(_on_node_removed)
	Meta.set_setting("perf_boost", 1)
	_test_1_wiring()
	_test_2_boost_on_release_stay_bucket()
	_test_3_boost_on_reuse_zero_tree_ops()
	_test_4_boost_on_tex_change_rebucket()
	_test_5_boost_off_release_return_home()
	_test_6_xp_pool_lazy()
	_test_7_fullload_release_gate()
	await _cleanup()
	tree.node_added.disconnect(_on_node_added)
	tree.node_removed.disconnect(_on_node_removed)
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


func _on_node_added(_n: Node) -> void:
	_added += 1


func _on_node_removed(_n: Node) -> void:
	_removed += 1


func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R272GameLoopUnderTest"
	tree.get_root().add_child(_gl)


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


# ── ① 装配面：lazy 旗接线 ──────────────────────────────────────
func _test_1_wiring() -> void:
	print("── ① lazy 旗装配 ──")
	_check("敌池 lazy_bucket_release=true（R272 V-C2 主刀接线）",
		(_gl.pools[&"enemy"] as ObjectPool).lazy_bucket_release == true, "")
	_check("xp 池 lazy_bucket_release=true（R272 顺手收口）",
		(_gl.pools[&"xp"] as ObjectPool).lazy_bucket_release == true, "")
	_check("弹池 lazy 不回退（R271 V-C1 保持）",
		(_gl.pools[&"projectile"] as ObjectPool).lazy_bucket_release == true, "")
	_check("homing 池未挂桶（无 reparent 链不在刀面——lazy 旗恒 false）",
		(_gl.pools[&"homing"] as ObjectPool).bucket_host == null
			and (_gl.pools[&"homing"] as ObjectPool).lazy_bucket_release == false, "")


# ── ② boost 开：敌 release 留桶（不 reparent 回池根） ──────────────
func _test_2_boost_on_release_stay_bucket() -> void:
	print("── ② boost 开 release 留桶 ──")
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var host: Node = pool.bucket_host
	var e := pool.acquire() as Enemy
	e.bucket_host = host                       # 测试直连注入（产品路径=spawner spawn 前）
	e.spawn(_fixture_enemy(&"E_R272_A", 100.0), 1, 0)
	var in_bucket: bool = host.is_ancestor_of(e) and e.get_parent() != pool
	_check("前置：spawn 后敌落桶", in_bucket, "parent=%s" % str(e.get_parent()))
	pool.release(e)
	_check("boost 开 release 留桶（parent 仍桶下非池根——unplace_lazy 零 reparent）",
		e.get_parent() != pool and host.is_ancestor_of(e), "parent=%s" % str(e.get_parent()))
	_check("留桶件池机械清理到位（visible=false——桶下不渲染不断批）",
		(e as CanvasItem).visible == false, "visible=%s" % str((e as CanvasItem).visible))
	var st: Dictionary = pool.stats()
	_check("留桶件池计数守恒（free+live==capacity）",
		int(st["free"]) + int(st["live"]) == int(st["capacity"]),
		"free=%d live=%d cap=%d" % [int(st["free"]), int(st["live"]), int(st["capacity"])])
	_check("留桶件无池污染告警（_assert_clean 双向不炸）",
		int(st["pollution"]) == 0 and int(st["rejected_releases"]) == 0,
		"pollution=%d rej=%d" % [int(st["pollution"]), int(st["rejected_releases"])])
	# 件留在桶栈内——本用例不归还第二次（防 double-release），直接弃置给 teardown 整池释放


# ── ③ boost 开：同贴图 acquire 复用零树进出（本刀核心验收） ────────
func _test_3_boost_on_reuse_zero_tree_ops() -> void:
	print("── ③ 复用零树进出 ──")
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var host: Node = pool.bucket_host
	# 预置：acquire→spawn 落桶→release 留桶（同 ② 路径）
	var e := pool.acquire() as Enemy
	e.bucket_host = host
	e.spawn(_fixture_enemy(&"E_R272_A", 100.0), 1, 0)
	pool.release(e)
	# 核心臂：包裹 acquire+spawn（同贴图复用）计 node_added/removed——期望双零
	_added = 0
	_removed = 0
	var e2 := pool.acquire() as Enemy
	e2.bucket_host = host
	e2.spawn(_fixture_enemy(&"E_R272_A", 100.0), 1, 0)
	var reused_same: bool = e2 == e
	_check("同贴图复用取回同一件（LIFO 栈顶=刚留桶件）", reused_same,
		"e2==e：%s" % str(reused_same))
	_check("复用全程零 reparent（node_added==0——敌子树整树摘挂归零）",
		_added == 0, "added=%d" % _added)
	_check("复用全程零摘树（node_removed==0）", _removed == 0, "removed=%d" % _removed)
	_check("复用后敌仍在桶下且激活（visible=true）",
		host.is_ancestor_of(e2) and (e2 as CanvasItem).visible, "")
	pool.release(e2)


# ── ④ boost 开：换贴图自然换桶（低频 reparent 路径不破） ───────────
func _test_4_boost_on_tex_change_rebucket() -> void:
	print("── ④ 换贴图换桶 ──")
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var host: Node = pool.bucket_host
	var e := pool.acquire() as Enemy
	e.bucket_host = host
	e.spawn(_fixture_enemy(&"E_R272_A", 100.0), 1, 0)
	pool.release(e)                           # 留桶（贴图 A 桶）
	# 复用为不同 kind（贴图 B）——place 换桶 reparent 正常路径
	var e2 := pool.acquire() as Enemy
	e2.bucket_host = host
	e2.spawn(_fixture_enemy(&"E_R272_B", 100.0), 1, 0)
	var parent_a: Node = null
	var parent_b: Node = e2.get_parent()
	_check("换贴图复用落桶（host 子桶下）", host.is_ancestor_of(e2),
		"parent=%s" % str(parent_b))
	# 对照臂：同贴图再复用回 A——place 免搬判或换桶均为桶下合法态，不锁同桶
	#（贴图取决于 kind 解析，同 id 才保同桶——③ 已锁零 reparent 主路径）
	pool.release(e2)
	var e3 := pool.acquire() as Enemy
	e3.bucket_host = host
	e3.spawn(_fixture_enemy(&"E_R272_A", 100.0), 1, 0)
	parent_a = e3.get_parent()
	_check("复用任意 kind 恒桶下（留桶/换桶两形态统一）",
		host.is_ancestor_of(e3) and parent_a != pool, "parent=%s" % str(parent_a))
	pool.release(e3)


# ── ⑤ boost 关：release 归位池根（现状逐位回退——r214 旧断言口径） ──
func _test_5_boost_off_release_return_home() -> void:
	print("── ⑤ boost 关逐位回退 ──")
	Meta.set_setting("perf_boost", 0)
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var host: Node = pool.bucket_host
	var e := pool.acquire() as Enemy
	e.bucket_host = host
	e.spawn(_fixture_enemy(&"E_R272_C", 100.0), 1, 0)
	pool.release(e)
	_check("boost 关 release 归位池根（unplace 现状逐位）",
		e.get_parent() == pool, "parent=%s" % str(e.get_parent()))
	var st: Dictionary = pool.stats()
	_check("关态池计数守恒", int(st["free"]) + int(st["live"]) == int(st["capacity"]),
		"free=%d live=%d" % [int(st["free"]), int(st["live"])])
	Meta.set_setting("perf_boost", 1)         # 还原 boost 开态（⑥ 续用）


# ── ⑥ xp 池同款（pickup 碎片留桶） ──────────────────────────────
func _test_6_xp_pool_lazy() -> void:
	print("── ⑥ xp 池留桶 ──")
	var pool := _gl.pools[&"xp"] as ObjectPool
	var host: Node = pool.bucket_host
	var shard := pool.acquire()
	_check("xp 件可取得（夹具前置）", shard != null, "")
	if shard == null:
		return
	# 注入 host 后激活自报 place（pickup._place_in_bucket 同敌侧协议）
	shard.set("bucket_host", host)
	if shard.has_method(&"_place_in_bucket"):
		shard.call(&"_place_in_bucket")
	_check("xp 件落桶", host.is_ancestor_of(shard), "parent=%s" % str(shard.get_parent()))
	pool.release(shard)
	_check("xp boost 开 release 留桶",
		shard.get_parent() != pool and host.is_ancestor_of(shard),
		"parent=%s" % str(shard.get_parent()))
	var st: Dictionary = pool.stats()
	_check("xp 池计数守恒", int(st["free"]) + int(st["live"]) == int(st["capacity"]),
		"free=%d live=%d" % [int(st["free"]), int(st["live"])])


# ── ⑦ 满载档释放门（R272 评审#1 暗门回归锁） ─────────────────────
# 病根：fullload_dim() 档 _reset_state 的 _apply_flash(0.0) 无条件走 _restore_flash_tex，
# 其守卫 is_ancestor_of 在 V-C2 留桶态恒真 → 释放期重新落桶（非 grunt 换桶 reparent）
# + _apply_body_mirror 重注册（违反 :2217 「镜像在册标志清零」不变量）。
# 修=守卫加 dead 门（enemy.gd _restore_flash_tex）——本臂锁修复后三态。
func _test_7_fullload_release_gate() -> void:
	print("── ⑦ 满载档释放门 ──")
	Enemy.fullload_override = 1                # headless 强制满载分支（评审探针同款）
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var host: Node = pool.bucket_host
	# 臂A grunt（贴图复位=同桶，免搬路径）：释放期零树进出+镜像不回册
	var ea := pool.acquire() as Enemy
	ea.bucket_host = host
	ea.spawn(_fixture_enemy(&"E_R272_FL_A", 100.0), 1, 0)
	_added = 0
	_removed = 0
	pool.release(ea)
	_check("满载 grunt 释放零树进出（dead 门挡回桶）", _added == 0 and _removed == 0,
		"added=%d removed=%d" % [_added, _removed])
	_check("满载 grunt 释放镜像不回册（_mm_on=false ∧ mirror_tex_of==null）",
		ea.get(&"_mm_on") == false and host.mirror_tex_of(ea) == null,
		"mm_on=%s mirror=%s" % [str(ea.get(&"_mm_on")), str(host.mirror_tex_of(ea))])
	_check("满载 grunt 释放仍留桶", host.is_ancestor_of(ea) and ea.get_parent() != pool,
		"parent=%s" % str(ea.get_parent()))
	# 臂B 非 grunt（E2 前缀→非 grunt kind，贴图复位=跨桶）：修复前换桶 reparent 1 次/周转
	var eb := pool.acquire() as Enemy
	eb.bucket_host = host
	eb.spawn(_fixture_enemy(&"E2_R272_FL_B", 100.0), 1, 0)
	var kind_b: StringName = eb.get(&"_kind")
	_added = 0
	_removed = 0
	pool.release(eb)
	_check("满载非 grunt（kind=%s）释放零树进出（修复前=复位贴图换桶 reparent）" % str(kind_b),
		_added == 0 and _removed == 0, "added=%d removed=%d" % [_added, _removed])
	_check("满载非 grunt 释放镜像不回册", eb.get(&"_mm_on") == false,
		"mm_on=%s" % str(eb.get(&"_mm_on")))
	# 臂C 满载+boost 关：现状逐位归池根（dead 门冗余臂——关态本就不在桶下）
	Meta.set_setting("perf_boost", 0)
	var ec := pool.acquire() as Enemy
	ec.bucket_host = host
	ec.spawn(_fixture_enemy(&"E_R272_FL_A", 100.0), 1, 0)
	pool.release(ec)
	_check("满载 boost 关释放归池根（现状逐位）", ec.get_parent() == pool,
		"parent=%s" % str(ec.get_parent()))
	Meta.set_setting("perf_boost", 1)         # 还原 boost 开态
	Enemy.fullload_override = -1              # 复位（qa_r269 cleanup 先例口径）
	var st: Dictionary = pool.stats()
	_check("满载臂后池计数守恒+零污染",
		int(st["free"]) + int(st["live"]) == int(st["capacity"])
			and int(st["pollution"]) == 0 and int(st["rejected_releases"]) == 0,
		"free=%d live=%d" % [int(st["free"]), int(st["live"])])


func _cleanup() -> void:
	# R270 盘档毒口径（本套首轮实锤复发：内存 erase 不清盘，set_setting 写即存盘——
	# 毒倒同批后跑套件）：入口快照整字典还原 + _save() 落盘冲销（qa_r269 同款）。
	# 垫值勿混判：Meta._ready 的 _boost_pad_defaults 会往内存 _settings 垫
	# perf_boost=0（headless——设计口径不落盘），「键存在」≠毒，真毒签名=盘档值==1
	Meta._settings = _saved_settings
	Meta._save()
	RunSave.clear()
	tree.paused = false
	if _gl != null:
		_gl.free()
		_gl = null
