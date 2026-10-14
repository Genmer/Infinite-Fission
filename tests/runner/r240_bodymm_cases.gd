# tests/runner/r240_bodymm_cases.gd
# R240 敌本体 MultiMesh 镜像用例体（入口运行时 load——cases 禁 test_ 前缀防电池 glob 误收）。
# 覆盖：
# ① BODY_MM=true 契约：常规敌注册镜像（_mm_on/sprite 恒隐/键=本体贴图）；mm 挂桶
#    首位（瞬态件恒在上口径）+规格；同贴图多敌同键追加
# ② 排除面：elite/bastion/boss 分型逐敌 Sprite 保留（不注册+复显）；FLASH_TEX=false
#    期不注册（联动约束）；排除期零残留
# ③ 生命周期：注册计数；release 注销；全释放后各 mm visible_instance_count=0
# ④ 换键：volatile 变脸→新脸键；镜像敌轻载起闪→白变体键+不挂 shader（贴图路径
#    常开契约）；闪毕回本体键
# ⑤ parity：实例 transform==owner.global×body.local；实例色==root.modulate×
#    body.modulate×self_modulate（含渐显 α）；实例序=place 序
# ⑥ 门关回退：BODY_MM=false 复显+注销；恢复再注册（单点双向无残留）
# ⑦ 池 churn：acquire/release 环无孤儿
# ⑧ 套件总项数断言（R231 假绿教训）
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const EXPECTED_TOTAL := 28

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261007)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	await tree.process_frame             # start_run 初始波敌出齐（MENU 后无新增——:1781 门）
	_sweep_foreign()                     # 开局波敌归还池——计数断言零基线（夹具纯化）
	_case1_gate_on_contract()
	_case2_exclusions()
	await _case3_lifecycle()
	_case4_rekey_flash()
	await _case5_parity()
	_case6_gate_off_rollback()
	_case7_churn()
	await _case7b_realloc()
	await _case7c_compact_hidden()
	await _cleanup()
	_check("⑧ 套件总项数（EXPECTED=%d——R231 假绿教训）" % EXPECTED_TOTAL,
		_pass + _fail + 1 == EXPECTED_TOTAL, "实得 %d" % (_pass + _fail + 1))
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
	_gl.name = "R240BodyMMGameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_gl.state = GameConst.GameStatus.MENU
	_gl.player.global_position = Vector2(360.0, 900.0)


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


func _acquire(p_id: StringName, p_tags: int = 0, p_hp: float = 100000.0) -> Enemy:
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var e := pool.acquire() as Enemy
	e.bucket_host = pool.bucket_host       # 敌 spawner 注入口径同款（enemy_spawner.gd:81
	                                       # 直连池绕过 spawner——本套自补注，spawn 前）
	e.spawn(_fixture_enemy(p_id, p_hp), 1, p_tags)
	e._fade_left = 0.0                    # 跳过入场渐显（根 α 噪声清零——⑤ 另测）
	e.modulate.a = 1.0
	return e


func _release(p_enemy: Enemy) -> void:
	(_gl.pools[&"enemy"] as EnemyPool).release(p_enemy)


func _host() -> TexBucketHost:
	return (_gl.pools[&"enemy"] as EnemyPool).bucket_host as TexBucketHost


func _sweep_foreign() -> void:
	# 开局波敌清扫（start_run 初始 spawn 的真实敌——非本套夹具）：全部归还池，
	# 镜像计数归零基线。MENU 态战斗循环停摆（game_loop:1781 门）无新增。
	var host := _host()
	var victims: Array = []
	for tex in host._mm_lists:
		for o in host._mm_lists[tex]:
			victims.append(o)
	for v in victims:
		if is_instance_valid(v):
			_release(v)

# ═══ ① BODY_MM=true 契约 ═════════════════════════════════════════════
func _case1_gate_on_contract() -> void:
	print("── ① BODY_MM=true 契约（常规敌镜像注册） ──")
	Enemy.BODY_MM = true
	Enemy.FLASH_TEX = true
	Enemy.fullload_override = -1          # 真值门（非满载态——本套主测轻载形态）
	var e := _acquire(&"E_R240_G1")
	var host := _host()
	var base_tex: Texture2D = e._sprite.texture
	_check("①a 常规敌注册：_mm_on 且 sprite 恒隐 且 键=本体贴图",
		e._mm_on and not e._sprite.visible
			and host.mirror_tex_of(e) == base_tex,
		"mm_on=%s vis=%s" % [str(e._mm_on), str(e._sprite.visible)])
	var bucket: Node2D = null
	for k in host._buckets:
		if (host._buckets[k] as Node) == e.get_parent():
			bucket = host._buckets[k]
	_check("①b mm 挂敌所在桶首位（本体层在瞬态件之下口径）",
		bucket != null and bucket.get_child(0) is MultiMeshInstance2D
			and bucket.get_child(0).name == &"BodyMM",
		"bucket=%s" % str(bucket))
	var mmi: MultiMeshInstance2D = (bucket.get_child(0) as MultiMeshInstance2D)
	_check("①c mm 规格：texture==本体贴图 且 use_colors 且 TRANSFORM_2D",
		mmi.texture == base_tex and mmi.multimesh.use_colors
			and mmi.multimesh.transform_format == MultiMesh.TRANSFORM_2D,
		"tex_ok=%s colors=%s" % [str(mmi.texture == base_tex),
			str(mmi.multimesh.use_colors)])
	var e2 := _acquire(&"E_R240_G2")
	var e3 := _acquire(&"E_R240_G3")
	_check("①d 同贴图多敌同键追加（count=3）",
		host.mirror_count() == 3 and host.mirror_tex_of(e2) == base_tex
			and host.mirror_tex_of(e3) == base_tex,
		"count=%d" % host.mirror_count())
	_release(e3)
	_release(e2)
	_release(e)

# ═══ ② 排除面 ═════════════════════════════════════════════════════════
func _case2_exclusions() -> void:
	print("── ② 排除面（boss/elite/bastion/FLASH_TEX=false） ──")
	var host := _host()
	var el := _acquire(&"E_R240_EL", GameConst.TAG_ELITE)
	_check("②a elite 排除：不注册 且 sprite 复显（皇冠/底影叠层语义保留）",
		not el._mm_on and el._sprite.visible and host.mirror_tex_of(el) == null,
		"mm_on=%s" % str(el._mm_on))
	_release(el)
	var ba := _acquire(&"E3_R240_BA")
	_check("②b bastion 排除：不注册（外甲板叠层语义）",
		not ba._mm_on and ba._sprite.visible, "mm_on=%s" % str(ba._mm_on))
	_release(ba)
	var bo := _acquire(&"E6_boss2_R240", GameConst.TAG_BOSS)
	_check("②c boss 排除：不注册（卫星/底影/变脸语义）",
		not bo._mm_on and bo._sprite.visible, "mm_on=%s" % str(bo._mm_on))
	_release(bo)
	Enemy.FLASH_TEX = false
	var fx := _acquire(&"E_R240_FT")
	_check("②d FLASH_TEX=false 联动排除：不注册（实例色承不住 >1 白乘）",
		not fx._mm_on and fx._sprite.visible, "mm_on=%s" % str(fx._mm_on))
	_release(fx)
	Enemy.FLASH_TEX = true
	_check("②e 排除期零残留：host.mirror_count()==0",
		host.mirror_count() == 0, "count=%d" % host.mirror_count())

# ═══ ③ 生命周期 ═══════════════════════════════════════════════════════
func _case3_lifecycle() -> void:
	print("── ③ 生命周期（release 注销/全释放清零） ──")
	var host := _host()
	var e := _acquire(&"E_R240_LC")
	_check("③a 注册计数：count==1",
		host.mirror_count() == 1, "count=%d" % host.mirror_count())
	_release(e)
	_check("③b release 注销：tex_of==null 且 count==0",
		host.mirror_tex_of(e) == null and host.mirror_count() == 0,
		"count=%d" % host.mirror_count())
	var e2 := _acquire(&"E_R240_LC2")     # 复取（同池实例或新实例——再注册链）
	var e3 := _acquire(&"E_R240_LC3")
	_release(e2)
	_release(e3)
	await tree.process_frame             # 让镜像同步跑一帧（visible_instance_count 清零）
	_check("③c 全释放后 mm 实例活口=0（visible_instance_count 清零）",
		host.mirror_count() == 0 and _all_mm_visible_zero(host),
		"count=%d" % host.mirror_count())

func _all_mm_visible_zero(p_host: TexBucketHost) -> bool:
	for k in p_host._mm_meshes:
		var mmi: MultiMeshInstance2D = p_host._mm_meshes[k]
		if mmi.multimesh.visible_instance_count != 0:
			return false
	return true

# ═══ ④ 换键（变脸/闪白） ══════════════════════════════════════════════
func _case4_rekey_flash() -> void:
	print("── ④ 换键：volatile 变脸 + 镜像敌轻载起闪贴图路径常开 ──")
	var host := _host()
	var v := _acquire(&"E4_R240_V")
	var calm_tex: Texture2D = v._sprite.texture
	v._set_volatile_face(1)
	var scared_tex: Texture2D = TextureFactory.enemy_tex(&"volatile_scared")
	_check("④a 变脸换键：mirror_tex_of==新脸贴图（place 复用自动换 mm 键）",
		host.mirror_tex_of(v) == scared_tex and scared_tex != calm_tex,
		"ok=%s" % str(host.mirror_tex_of(v) == scared_tex))
	v._apply_flash(1.0)                   # 非满载（fullload_override=-1 真值门·轻载）
	var strong_tex: Texture2D = TextureFactory.enemy_tex_flash(&"volatile_scared", false, true)
	_check("④b 轻载起闪=贴图路径常开：键==强白变体 且 不挂 shader（mm 实例色承载约束）",
		host.mirror_tex_of(v) == strong_tex and v._sprite.material == null
			and v._sprite.modulate == Color.WHITE,
		"ok=%s mat=%s" % [str(host.mirror_tex_of(v) == strong_tex),
			str(v._sprite.material)])
	v._apply_flash(0.0)
	_check("④c 闪毕回本体键：tex_of==当前脸本体（scared）且 _flash_tex_on 清零",
		host.mirror_tex_of(v) == scared_tex and not v._flash_tex_on,
		"ok=%s" % str(host.mirror_tex_of(v) == scared_tex))
	_release(v)

# ═══ ⑤ parity（transform/色/实例序） ══════════════════════════════════
func _case5_parity() -> void:
	print("── ⑤ parity：实例 transform/色 与 sprite 状态逐位一致 ──")
	# QA-R240-002：Dummy 渲染器（headless）不落地 MultiMesh 实例 transform/color 缓冲
	# （写入读回恒 (0,0)/(0,0,0,1)，QA 最小引擎探针实证；窗口渲染器逐位正确）——
	# headless 下本组降级为结构性断言（instance_count/visible_instance_count 场景侧
	# 属性 headless 正常），读回等价只在窗口态断言。
	var headless: bool = DisplayServer.get_name() == "headless"
	var host := _host()
	var e := _acquire(&"E_R240_P1")
	e.global_position = Vector2(123.0, 45.0)
	e._sprite.position = Vector2(2.0, 3.0)
	e._sprite.rotation = 0.6
	e._sprite.self_modulate = Color(1.0, 0.5, 0.5, 1.0)
	e.modulate.a = 0.5                    # 渐显 α 半程（实例色 a 通道承载）
	await tree.process_frame
	await tree.process_frame
	var tex: Texture2D = host.mirror_tex_of(e)
	var mmi: MultiMeshInstance2D = host._mm_meshes[tex]
	if headless:
		_check("⑤a 实例同步结构等价（headless 降级：容量>0 且活口=注册数）",
			mmi.multimesh.instance_count > 0 and mmi.multimesh.visible_instance_count == 1,
			"inst=%d vis=%d" % [mmi.multimesh.instance_count,
				mmi.multimesh.visible_instance_count])
		_check("⑤b 实例色通道（headless 降级：写路径不可读回，见 QA-R240-002 探针留档）",
			mmi.multimesh.use_colors, "use_colors=false 则窗口态色也会丢")
	else:
		var it: Transform2D = mmi.multimesh.get_instance_transform_2d(0)
		var want_t: Transform2D = e.global_transform * e._sprite.transform
		_check("⑤a 实例 transform==owner.global×body.local",
			it.origin.distance_to(want_t.origin) < 0.001
				and absf(it.get_rotation() - want_t.get_rotation()) < 0.001,
			"got=%s want=%s" % [str(it.origin), str(want_t.origin)])
		var ic: Color = mmi.multimesh.get_instance_color(0)
		var want_c: Color = e.modulate * e._sprite.modulate * e._sprite.self_modulate
		_check("⑤b 实例色==root.modulate×modulate×self_modulate（含渐显 α）",
			absf(ic.r - want_c.r) < 0.002 and absf(ic.g - want_c.g) < 0.002
				and absf(ic.b - want_c.b) < 0.002 and absf(ic.a - want_c.a) < 0.002,
			"got=%s want=%s" % [str(ic), str(want_c)])
	var e2 := _acquire(&"E_R240_P2")
	e2.global_position = Vector2(300.0, 100.0)
	await tree.process_frame
	var i0: int = _instance_index_of(host, e)
	var i1: int = _instance_index_of(host, e2)
	_check("⑤c 实例序=place 序（先注册=低索引——绘制序与现状桶序同构）",
		i0 >= 0 and i1 >= 0 and i0 < i1,
		"i0=%d i1=%d" % [i0, i1])
	_release(e2)
	_release(e)
	# ⑤d R240-B1 翻转修复机制断言（恒跑——headless 可测，评审 BLOCKER 回归门）：
	# _quad_mesh_uv_up 的 UV 取向必须 UV-up（v=0 顶行=贴图顶部=Sprite2D 等价）——
	# QuadMesh 的 v=0 在底（GL 惯例），2D canvas 渲染即垂直镜像（敌人全部倒置）。
	var utex: Texture2D = TextureFactory.enemy_tex(&"grunt")   # 非对称脸贴图
	var umesh: ArrayMesh = TexBucketHost._quad_mesh_uv_up(utex)
	var uv_arr: PackedVector2Array = umesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV]
	var v_arr: PackedVector3Array = umesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var half_w := float(utex.get_width()) * 0.5
	var half_h := float(utex.get_height()) * 0.5
	var uv_ok: bool = uv_arr.size() == 4 and v_arr.size() == 4
	if uv_ok:
		uv_ok = v_arr[0].distance_to(Vector3(-half_w, -half_h, 0)) < 0.001 and uv_arr[0] == Vector2(0, 0) \
			and v_arr[1].distance_to(Vector3(half_w, -half_h, 0)) < 0.001 and uv_arr[1] == Vector2(1, 0) \
			and v_arr[2].distance_to(Vector3(half_w, half_h, 0)) < 0.001 and uv_arr[2] == Vector2(1, 1) \
			and v_arr[3].distance_to(Vector3(-half_w, half_h, 0)) < 0.001 and uv_arr[3] == Vector2(0, 1)
	_check("⑤d mesh UV 取向=Sprite2D 等价（左上(-hw,-hh)↔UV(0,0)；R240-B1 翻转回归门）",
		uv_ok, "uv=%s verts=%s" % [str(uv_arr), str(v_arr)])
	# ⑤e 窗口态像素对拍（headless 降级——Dummy 渲染器无像素，机制门=⑤d+探针留档
	# docs/qa/probe_r240_uvfix.json：grunt/volatile_scared direct=0.0000 双证）
	if headless:
		_check("⑤e 像素对拍（headless 降级：见 probe_r240_uvfix.json direct=0.0000 留档）",
			true, "窗口态跑本套件时为真像素断言")
	else:
		var pd: float = await _pixel_compare(utex)
		_check("⑤e Sprite2D vs mm 渲染区像素 direct diff≤0.012（翻转/取向回归）",
			pd <= 0.012, "direct=%.4f" % pd)

func _instance_index_of(p_host: TexBucketHost, p_enemy: Enemy) -> int:
	var tex: Texture2D = p_host.mirror_tex_of(p_enemy)
	if tex == null:
		return -1
	var lst: Array = p_host._mm_lists[tex]
	return lst.find(p_enemy)

# ═══ ⑥ 门关回退 ═══════════════════════════════════════════════════════
func _case6_gate_off_rollback() -> void:
	print("── ⑥ BODY_MM=false 单点回退（逐敌 Sprite 现状零扰动） ──")
	var host := _host()
	var e := _acquire(&"E_R240_RB")
	Enemy.BODY_MM = false
	e._place_in_bucket()                  # 门翻后重落桶（分档/换贴图点会自然触发）
	_check("⑥a 门关复显：sprite.visible==true 且 注销 且 count==0",
		e._sprite.visible and not e._mm_on and host.mirror_count() == 0,
		"vis=%s mm_on=%s count=%d" % [str(e._sprite.visible), str(e._mm_on),
			host.mirror_count()])
	Enemy.BODY_MM = true
	e._place_in_bucket()
	_check("⑥b 门恢复：再落桶复注册（单点双向无残留）",
		e._mm_on and host.mirror_count() == 1,
		"mm_on=%s count=%d" % [str(e._mm_on), host.mirror_count()])
	_release(e)

# ═══ ⑦ 池 churn ═══════════════════════════════════════════════════════
func _case7_churn() -> void:
	print("── ⑦ acquire/release 环无孤儿 ──")
	var host := _host()
	for i in range(10):
		var a := _acquire(StringName("E_R240_CH%d" % i))
		var b := _acquire(&"E4_R240_CHV")
		_release(a)
		_release(b)
	_check("⑦ 10 轮双敌环后 count==0（注销链无泄漏）",
		host.mirror_count() == 0, "count=%d" % host.mirror_count())


# ═══ ⑦b 阶梯 realloc 写穿（评审缺口：>16 实例跨容量级——realloc 须保留已写数据） ═══
func _case7b_realloc() -> void:
	print("── ⑦b 阶梯 realloc：40 实例单帧写穿 16→32→48 三级 ──")
	var host := _host()
	var headless: bool = DisplayServer.get_name() == "headless"
	var enemies: Array = []
	for i in range(40):
		var e := _acquire(&"E_R240_P1")     # 同种同桶（一个 mm 上跨容量级）
		e.global_position = Vector2(40.0 + i * 8.0, 220.0)
		enemies.append(e)
	await tree.process_frame
	await tree.process_frame
	var tex: Texture2D = host.mirror_tex_of(enemies[0])
	var mm: MultiMesh = (host._mm_meshes[tex] as MultiMeshInstance2D).multimesh
	var capacity_ok: bool = mm.instance_count >= 40 and mm.visible_instance_count == 40
	if headless:
		_check("⑦b realloc（headless 降级：容量≥40 且活口=40）", capacity_ok,
			"inst=%d vis=%d" % [mm.instance_count, mm.visible_instance_count])
	else:
		var sample_ok := capacity_ok
		for idx in [0, 19, 39]:             # 头/中/尾三点（跨全部三级容量）
			var it: Transform2D = mm.get_instance_transform_2d(idx)
			var want: Transform2D = (enemies[idx] as Node2D).global_transform \
				* (enemies[idx] as Enemy)._sprite.transform
			sample_ok = sample_ok and it.origin.distance_to(want.origin) < 0.001
		_check("⑦b realloc 写穿（40 实例三级增长，采样 0/19/39 读回正确）", sample_ok,
			"inst=%d vis=%d" % [mm.instance_count, mm.visible_instance_count])
	for e in enemies:
		_release(e)


# ═══ ⑦c 释亡压缩 + 隐藏 owner 跳绘（评审缺口：_compact_lists 与 visible 门） ═══
func _case7c_compact_hidden() -> void:
	print("── ⑦c 释亡帧尾压缩 / 隐藏 owner 跳绘 ──")
	var host := _host()
	var e_free := _acquire(&"E_R240_P1")    # 释亡臂：直接 free（绕开 unregister 路径）
	var e_hide := _acquire(&"E_R240_P1")    # 隐藏臂
	var e_live := _acquire(&"E_R240_P1")    # 活口对照
	e_free.global_position = Vector2(100.0, 320.0)
	e_hide.global_position = Vector2(180.0, 320.0)
	e_live.global_position = Vector2(260.0, 320.0)
	e_hide.visible = false
	e_free.free()                           # 表内留 freed 引用——_process 标记+帧尾压缩
	await tree.process_frame               # 本帧 _process（标记 has_dead）+帧尾 _compact_lists
	await tree.process_frame
	_check("⑦c 释亡压缩：free 后注册表恰清（count==2 只余 hide+live）",
		host.mirror_count() == 2, "count=%d" % host.mirror_count())
	var tex2: Texture2D = host.mirror_tex_of(e_live)
	var mm2: MultiMesh = (host._mm_meshes[tex2] as MultiMeshInstance2D).multimesh
	_check("⑦c 隐藏 owner 跳绘（visible_instance_count 只计活口 1）",
		mm2.visible_instance_count == 1, "vis=%d" % mm2.visible_instance_count)
	e_hide.visible = true
	await tree.process_frame
	_check("⑦c 复显回绘（visible_instance_count==2）",
		mm2.visible_instance_count == 2, "vis=%d" % mm2.visible_instance_count)
	_release(e_hide)
	_release(e_live)


# ═══ ⑤e 助手：窗口态像素对拍（同位置先后渲染消背景——菜单动画暂停冻结） ═══
func _pixel_compare(p_tex: Texture2D) -> float:
	var headless: bool = DisplayServer.get_name() == "headless"
	if headless:
		return 0.0                          # 调用方 headless 分支不会走到（降级口径）
	tree.paused = true                      # 冻结菜单动画：两臂截图帧间背景逐位静止
	var probe_root := Node2D.new()
	tree.root.add_child(probe_root)
	var p := Vector2(360.0, 700.0)
	var spr := Sprite2D.new()
	spr.texture = p_tex
	spr.position = p
	probe_root.add_child(spr)
	await tree.process_frame
	await tree.process_frame
	var img_a := tree.root.get_texture().get_image()
	spr.queue_free()
	var mmi := MultiMeshInstance2D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.mesh = TexBucketHost._quad_mesh_uv_up(p_tex)
	mm.custom_aabb = AABB(Vector3(-1e7, -1e7, -1.0), Vector3(2e7, 2e7, 2.0))
	mm.instance_count = 1
	mm.set_instance_transform_2d(0, Transform2D(0.0, Vector2(1, 1), 0.0, p))
	mm.set_instance_color(0, Color.WHITE)
	mmi.multimesh = mm
	mmi.texture = p_tex
	probe_root.add_child(mmi)
	await tree.process_frame
	await tree.process_frame
	var img_b := tree.root.get_texture().get_image()
	mmi.queue_free()
	probe_root.queue_free()
	tree.paused = false
	var sz := p_tex.get_size().round()
	var r := Rect2i((p - p_tex.get_size() * 0.5).round(), sz)
	var n := 0
	var acc := 0.0
	for y in range(r.size.y):
		for x in range(r.size.x):
			var ca := img_a.get_pixel(r.position.x + x, r.position.y + y)
			var cb := img_b.get_pixel(r.position.x + x, r.position.y + y)
			acc += absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)
			n += 1
	return acc / float(n * 3) if n > 0 else 1.0


func _cleanup() -> void:
	Enemy.fullload_override = -1
	Enemy.BODY_MM = true                  # 源默认 on 态复位（防跨套件泄漏）
	Enemy.FLASH_TEX = true
	Enemy._fullload_latched = false
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null
