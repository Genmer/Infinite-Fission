# tests/runner/r237_flashtex_cases.gd
# R237 闪白换桶刀用例体（入口运行时 load——cases 禁 test_ 前缀防电池 glob 误收）。
# 视觉口径披露（R237）：满载档受击闪白 = modulate 过曝白乘 → 白剪影/半白贴图
# （经典 hit-flash 观感，亮度读感略变）；轻载观感零变化；FLASH_TEX=false 单点回退。
# 覆盖：
# ① 满载+FLASH_TEX=true 契约：起闪强/弱 → texture==白变体 且 modulate==WHITE 且
#    material==null；闪毕 → texture 复位本体贴图；两次起闪（强→弱）变体切换正确；
#    染色通道（self_modulate）分立不互踩
# ② 换桶事实：起闪后敌所在桶==白变体贴图桶（TexBucketHost._buckets 落桶结果直读）；
#    闪毕回原桶；同档两敌同桶（合批前提）
# ③ 池复用零残留：闪白窗内归还（pool release）→ 归还链守卫（敌归位池根不回桶）+
#    _flash_tex_on 清零 + texture 复位；复取 spawn → texture==本体贴图（非白变体）
#    且 modulate WHITE 且 material null
# ④ fullload 回落边界：起闪后 fullload_override 关（回落）+ 窗口衰减 → 非满载 shader
#    路径正确接管（modulate WHITE+材质挂回+贴图复位）→ 闪毕路径一致，零状态残留
# ⑤ FLASH_TEX=false 回退：满载起闪 → modulate==WHITE×2.4/1.5 且 texture 不变（现状锁）
#    + true→false 切换边界（白变体先复位再走白乘）
# ⑥ TextureFactory 白变体烘焙口径 + 邻接锚：强=全白剪影 alpha 保留 / 弱=0.5 混白 /
#    缓存同实例；非满载路径零改动（R202 ③ 现状锁）；满载闪白敌 is_batch_broken 反向
#    （闪白期不再断批——本刀目的）；源级锚
# ⑦ 套件总项数断言（R231 假绿教训）
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const ENEMY_SOURCE := "res://scripts/entities/enemy/enemy.gd"
const TF_SOURCE := "res://scripts/ui/texture_factory.gd"
const DT := 1.0 / 60.0
const EPS := 0.0001
const PIX_TOL := 0.005                    # 8-bit 量化半级容差（1/255≈0.004）
const EXPECTED_TOTAL := 35

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
	_case1_flashtex_contract()
	_case2_bucket_facts()
	_case3_pool_reuse_no_residue()
	_case4_fullload_fallback_edge()
	_case5_flashtex_false_rollback()
	_case6_bake_and_adjacency_anchors()
	await _cleanup()
	_check("⑦ 套件总项数（EXPECTED=%d——R231 假绿教训）" % EXPECTED_TOTAL,
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
	_gl.name = "R237FlashTexGameLoopUnderTest"
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


func _acquire(p_id: StringName, p_hp: float = 100000.0) -> Enemy:
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var e := pool.acquire() as Enemy
	e.bucket_host = pool.bucket_host       # 敌 spawner 注入口径同款（enemy_spawner.gd:81
	                                       # 直连池绕过 spawner——本套自补注，spawn 前）
	e.spawn(_fixture_enemy(p_id, p_hp), 1, 0)
	e._fade_left = 0.0                    # 跳过入场渐显（根 α 噪声清零）
	e.modulate.a = 1.0
	return e


func _release(p_enemy: Enemy) -> void:
	(_gl.pools[&"enemy"] as EnemyPool).release(p_enemy)


# ═══ ① 满载+FLASH_TEX=true 契约 ═══════════════════════════════════
func _case1_flashtex_contract() -> void:
	print("── ① 满载 FLASH_TEX=true 契约（贴图化闪白） ──")
	Enemy.fullload_override = 1
	Enemy.FLASH_TEX = true
	var e := _acquire(&"E_R237_FT1")
	var sprite: Sprite2D = e._sprite
	var base_tex: Texture2D = TextureFactory.enemy_tex(&"grunt")   # 未知 id 前缀 → grunt 分型
	var strong_tex: Texture2D = TextureFactory.enemy_tex_flash(&"grunt", false, true)
	var weak_tex: Texture2D = TextureFactory.enemy_tex_flash(&"grunt", false, false)
	_check("①a 前置：spawn 后本体贴图==grunt 基图（夹具口径）",
		sprite.texture == base_tex, "tex=%s" % str(sprite.texture))
	e._apply_flash(1.0)
	_check("①b 起闪强档：texture==强白变体 且 ≠本体（贴图通道接管）",
		sprite.texture == strong_tex and sprite.texture != base_tex,
		"tex=%s" % str(sprite.texture))
	_check("①c 起闪强档：modulate==WHITE 且 material==null 且 _flash_tex_on",
		sprite.modulate == Color.WHITE and sprite.material == null
			and bool(e.get("_flash_tex_on")),
		"mod=%s mat=%s flag=%s" % [str(sprite.modulate), str(sprite.material),
			str(e.get("_flash_tex_on"))])
	var tex_after_repeat: Texture2D = sprite.texture
	e._apply_flash(1.0)
	_check("①d 续闪同值幂等：同档续闪 texture 不变（place 幂等零 reparent）",
		sprite.texture == tex_after_repeat, "tex=%s" % str(sprite.texture))
	e._apply_flash(0.3)
	_check("①e 弱档切换：flash(0.3) → texture==弱白变体 且 ≠强变体（两档强度保留）",
		sprite.texture == weak_tex and sprite.texture != strong_tex,
		"tex=%s" % str(sprite.texture))
	e._apply_flash(0.5)
	_check("①f 档界 0.5：界点归强档（R217 量化口径保留）",
		sprite.texture == strong_tex, "tex=%s" % str(sprite.texture))
	# 染色通道分立：burn 敌闪白期 self_modulate 保持染色（两通道不互踩）
	e.elemental = ElementalState.new()
	e.elemental.burn_timer = 2.0
	e._anim_t = 0.3
	e._apply_body_tint(DT)
	var tint_before: Color = sprite.self_modulate
	e._apply_flash(1.0)
	_check("①g 染色通道分立：闪白期 self_modulate 保持染色值（R217 刀A 通道不互踩）",
		sprite.self_modulate.is_equal_approx(tint_before)
			and not sprite.self_modulate.is_equal_approx(Color.WHITE),
		"tint=%s（前=%s）" % [str(sprite.self_modulate), str(tint_before)])
	e.elemental = null
	e._apply_flash(0.0)
	_check("①h 闪毕：texture 复位本体贴图 + modulate WHITE + material null + flag 清零",
		sprite.texture == base_tex and sprite.modulate == Color.WHITE
			and sprite.material == null and not bool(e.get("_flash_tex_on")),
		"tex=%s mod=%s flag=%s" % [str(sprite.texture), str(sprite.modulate),
			str(e.get("_flash_tex_on"))])
	Enemy.fullload_override = -1
	_release(e)


# ═══ ② 换桶事实（TexBucketHost 落桶结果直读） ═════════════════════
func _case2_bucket_facts() -> void:
	print("── ② 换桶事实（白变体桶/回原桶/同桶聚集） ──")
	Enemy.fullload_override = 1
	Enemy.FLASH_TEX = true
	var e1 := _acquire(&"E_R237_B1")
	var e2 := _acquire(&"E_R237_B2")
	var host: TexBucketHost = e1.bucket_host as TexBucketHost
	var base_tex: Texture2D = TextureFactory.enemy_tex(&"grunt")
	var strong_tex: Texture2D = TextureFactory.enemy_tex_flash(&"grunt", false, true)
	var buckets: Dictionary = host._buckets
	_check("②a 前置：敌池桶 host 在位 + 本体贴图桶已建（spawn 落桶口径）",
		host != null and buckets.has(base_tex), "host=%s" % str(host))
	var base_bucket: Node2D = buckets[base_tex]
	_check("②b 起闪前：两敌均在本体贴图桶（同贴图同桶——合批前提）",
		e1.get_parent() == base_bucket and e2.get_parent() == base_bucket,
		"p1=%s p2=%s" % [str(e1.get_parent() == base_bucket), str(e2.get_parent() == base_bucket)])
	e1._apply_flash(1.0)
	var flash_bucket: Node2D = buckets.get(strong_tex)
	_check("②c 起闪后：白变体贴图桶已建（_buckets 键=强白变体）且敌落其中（换桶事实）",
		flash_bucket != null and e1.get_parent() == flash_bucket,
		"bucket=%s parent_ok=%s" % [str(flash_bucket != null),
			str(e1.get_parent() == flash_bucket)])
	e2._apply_flash(1.0)
	_check("②d 同档聚集：两强闪敌同桶（同贴图同桶=同批——断批根治读数）",
		e2.get_parent() == flash_bucket and e1.get_parent() == e2.get_parent()
			and e1.get_parent() != base_bucket,
		"同桶=%s" % str(e1.get_parent() == e2.get_parent()))
	e1._apply_flash(0.0)
	_check("②e 闪毕回原桶：闪白敌回本体贴图桶（原桶零滞留）",
		e1.get_parent() == base_bucket and e2.get_parent() == flash_bucket,
		"p1=%s p2=%s" % [str(e1.get_parent() == base_bucket),
			str(e2.get_parent() == flash_bucket)])
	e2._apply_flash(0.0)
	_check("②f 全员闪毕：两敌均回本体桶（桶内恢复合批形态）",
		e1.get_parent() == base_bucket and e2.get_parent() == base_bucket, "")
	Enemy.fullload_override = -1
	_release(e1)
	_release(e2)


# ═══ ③ 池复用零残留（归还链守卫） ═════════════════════════════════
func _case3_pool_reuse_no_residue() -> void:
	print("── ③ 池复用零残留 ──")
	Enemy.fullload_override = 1
	Enemy.FLASH_TEX = true
	var base_tex: Texture2D = TextureFactory.enemy_tex(&"grunt")
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var host: TexBucketHost = null
	var e := _acquire(&"E_R237_P1")
	host = e.bucket_host as TexBucketHost
	e._apply_flash(1.0)                   # 闪白窗内（白变体在身）
	var was_flash_tex: bool = e._sprite.texture != base_tex and bool(e.get("_flash_tex_on"))
	_release(e)                           # 闪白窗内归还（_reset_state → _apply_flash(0.0)）
	_check("③a 前置+归还复位：起闪白变体在身 → 归还后 _flash_tex_on 清零 + texture 复位本体",
		was_flash_tex and not bool(e.get("_flash_tex_on")) and e._sprite.texture == base_tex,
		"was=%s flag=%s tex_ok=%s" % [str(was_flash_tex), str(e.get("_flash_tex_on")),
			str(e._sprite.texture == base_tex)])
	_check("③b 归还链守卫：归还后敌不在桶下（unplace 归位池根——释放中不被重新挂桶）",
		e.get_parent() == pool or not host.is_ancestor_of(e),
		"parent=%s" % str(e.get_parent().name))
	var e2 := pool.acquire() as Enemy
	_check("③c 复取同实例（池栈序——复用前提成立）", e2 == e, "same=%s" % str(e2 == e))
	e2.spawn(_fixture_enemy(&"E_R237_P2", 100000.0), 1, 0)
	_check("③d 复取 spawn 后：texture==本体贴图（非白变体）+ modulate WHITE + material null",
		e2._sprite.texture == TextureFactory.enemy_tex(&"grunt")
			and e2._sprite.modulate == Color.WHITE and e2._sprite.material == null
			and not bool(e2.get("_flash_tex_on")),
		"tex=%s mod=%s flag=%s" % [str(e2._sprite.texture), str(e2._sprite.modulate),
			str(e2.get("_flash_tex_on"))])
	Enemy.fullload_override = -1
	_release(e2)


# ═══ ④ fullload 回落边界（shader 接管/闪毕一致） ══════════════════
func _case4_fullload_fallback_edge() -> void:
	print("── ④ fullload 回落边界 ──")
	Enemy.FLASH_TEX = true
	var base_tex: Texture2D = TextureFactory.enemy_tex(&"grunt")
	# 回落+续窗：满载起闪 → 门关 → 窗口衰减（非满载 shader 路径接管）
	var e := _acquire(&"E_R237_E1")
	Enemy.fullload_override = 1
	e._apply_flash(1.0)
	Enemy.fullload_override = 0
	e._apply_flash(0.5)                   # 窗口衰减值（非满载分支）
	_check("④a 回落续窗：shader 接管（材质挂回+flash_amount==0.5）+ 贴图复位本体 + modulate WHITE",
		e._sprite.material == e._material
			and absf(float(e._material.get_shader_parameter(&"flash_amount")) - 0.5) < EPS
			and e._sprite.texture == base_tex and e._sprite.modulate == Color.WHITE
			and not bool(e.get("_flash_tex_on")),
		"mat=%s amt=%s tex=%s flag=%s" % [str(e._sprite.material == e._material),
			str(e._material.get_shader_parameter(&"flash_amount")),
			str(e._sprite.texture == base_tex), str(e.get("_flash_tex_on"))])
	e._apply_flash(0.0)
	_check("④b 回落闪毕：材质摘除 + 贴图本体 + 零状态残留（与满载闪毕路径一致）",
		e._sprite.material == null and e._sprite.texture == base_tex
			and e._sprite.modulate == Color.WHITE and not bool(e.get("_flash_tex_on")),
		"mat=%s tex=%s" % [str(e._sprite.material), str(e._sprite.texture == base_tex)])
	_release(e)
	# 回落即闪毕（zero 路径直接）：满载起闪 → 门关 → 归零口
	var e0 := _acquire(&"E_R237_E2")
	Enemy.fullload_override = 1
	e0._apply_flash(1.0)
	Enemy.fullload_override = 0
	e0._apply_flash(0.0)
	_check("④c 回落即闪毕：归零口直接复位（QA-R213-001 口径扩展——贴图通道零残留）",
		e0._sprite.texture == base_tex and e0._sprite.modulate == Color.WHITE
			and e0._sprite.material == null and not bool(e0.get("_flash_tex_on")),
		"tex=%s flag=%s" % [str(e0._sprite.texture == base_tex),
			str(e0.get("_flash_tex_on"))])
	_release(e0)
	# 反向边界：非满载挂材质 → 门再开归零 → 材质摘除（互复位）
	var e3 := _acquire(&"E_R237_E3")
	Enemy.fullload_override = 0
	e3._apply_flash(1.0)                  # 非满载：挂材质
	var mat_attached: bool = e3._sprite.material == e3._material
	Enemy.fullload_override = 1
	e3._apply_flash(0.0)                  # 满载归零路径
	_check("④d 门再开：shader 材质摘除 + 贴图本体（双通道互复位不回归）",
		mat_attached and e3._sprite.material == null
			and e3._sprite.texture == base_tex and e3._sprite.modulate == Color.WHITE,
		"attached=%s mat=%s" % [str(mat_attached), str(e3._sprite.material)])
	Enemy.fullload_override = -1
	_release(e3)


# ═══ ⑤ FLASH_TEX=false 回退（满载白乘现状锁） ═════════════════════
func _case5_flashtex_false_rollback() -> void:
	print("── ⑤ FLASH_TEX=false 回退（现状锁） ──")
	var base_tex: Texture2D = TextureFactory.enemy_tex(&"grunt")
	Enemy.FLASH_TEX = false
	var e := _acquire(&"E_R237_R1")
	Enemy.fullload_override = 1
	e._apply_flash(1.0)
	var m: Color = e._sprite.modulate
	_check("⑤a false 起闪强档：modulate==WHITE×2.4 且 texture 不变（现状锁）",
		absf(m.r - 2.4) < EPS and absf(m.g - 2.4) < EPS and absf(m.b - 2.4) < EPS
			and e._sprite.texture == base_tex and not bool(e.get("_flash_tex_on")),
		"mod=%s tex_ok=%s" % [str(m), str(e._sprite.texture == base_tex)])
	e._apply_flash(0.3)
	_check("⑤b false 弱档：WHITE×1.5（两档量化原样）",
		absf(e._sprite.modulate.r - 1.5) < EPS, "mod=%s" % str(e._sprite.modulate))
	e._apply_flash(0.0)
	_check("⑤c false 闪毕：modulate 复位纯白",
		e._sprite.modulate == Color.WHITE, "mod=%s" % str(e._sprite.modulate))
	_release(e)
	# 切换边界：true 期起闪（白变体在身）→ 翻 false 续闪 → 白乘接管 + 贴图复位
	var e2 := _acquire(&"E_R237_R2")
	Enemy.FLASH_TEX = true
	e2._apply_flash(1.0)
	var swapped: bool = e2._sprite.texture != base_tex
	Enemy.FLASH_TEX = false
	e2._apply_flash(1.0)
	_check("⑤d 切换边界：true 起闪白变体 → 翻 false 续闪 → 白乘接管 + 贴图复位本体",
		swapped and absf(e2._sprite.modulate.r - 2.4) < EPS
			and e2._sprite.texture == base_tex and not bool(e2.get("_flash_tex_on")),
		"swapped=%s mod=%s tex_ok=%s" % [str(swapped), str(e2._sprite.modulate),
			str(e2._sprite.texture == base_tex)])
	Enemy.FLASH_TEX = true                # 回默认 on 态（套件卫生）
	Enemy.fullload_override = -1
	_release(e2)


# ═══ ⑥ TextureFactory 白变体烘焙 + 邻接锚 ═════════════════════════
func _case6_bake_and_adjacency_anchors() -> void:
	print("── ⑥ 白变体烘焙口径 + 邻接锚 ──")
	var base_t: Texture2D = TextureFactory.enemy_tex(&"grunt")
	var s_t: Texture2D = TextureFactory.enemy_tex_flash(&"grunt", false, true)
	var w_t: Texture2D = TextureFactory.enemy_tex_flash(&"grunt", false, false)
	var base_img: Image = base_t.get_image()
	var s_img: Image = s_t.get_image()
	var w_img: Image = w_t.get_image()
	var s_ok := true
	var w_ok := true
	var a_ok := true
	var detail := ""
	for y in range(base_img.get_height()):
		for x in range(base_img.get_width()):
			var b: Color = base_img.get_pixel(x, y)
			var s: Color = s_img.get_pixel(x, y)
			var w: Color = w_img.get_pixel(x, y)
			if b.a <= 0.0005:
				if s.a > 0.0005 or w.a > 0.0005:
					a_ok = false
					detail = "透明位污染 (%d,%d)" % [x, y]
				continue
			if s.r < 0.995 or s.g < 0.995 or s.b < 0.995:
				s_ok = false
				detail = "强档非白 (%d,%d)" % [x, y]
			if absf(s.a - b.a) > PIX_TOL or absf(w.a - b.a) > PIX_TOL:
				a_ok = false
				detail = "alpha 漂移 (%d,%d)" % [x, y]
			if absf(w.r - lerpf(b.r, 1.0, 0.5)) > PIX_TOL \
					or absf(w.g - lerpf(b.g, 1.0, 0.5)) > PIX_TOL \
					or absf(w.b - lerpf(b.b, 1.0, 0.5)) > PIX_TOL:
				w_ok = false
				detail = "弱档混白偏差 (%d,%d)" % [x, y]
	_check("⑥a 强档烘焙：不透明位 RGB 全白（全白剪影）", s_ok, detail)
	_check("⑥b 弱档烘焙：不透明位 RGB==原色 0.5 混白（半白混合）", w_ok, detail)
	_check("⑥c alpha 保留：两变体 alpha 与基图逐位一致（透明位零污染）", a_ok, detail)
	_check("⑥d 变体互异 + 缓存同实例（两取同引用——烘焙缓存命中）",
		TextureFactory.enemy_tex_flash(&"grunt", false, true) == s_t
			and base_t != s_t and s_t != w_t,
		"")
	# 非满载路径零改动（R202 ③ 现状锁）
	var e := _acquire(&"E_R237_A1")
	var base_tex: Texture2D = TextureFactory.enemy_tex(&"grunt")
	Enemy.fullload_override = 0
	e._apply_flash(1.0)
	_check("⑥e 非满载零改动：材质挂回 + flash_amount==1.0 + 贴图不变 + modulate WHITE",
		e._sprite.material == e._material
			and absf(float(e._material.get_shader_parameter(&"flash_amount")) - 1.0) < EPS
			and e._sprite.texture == base_tex and e._sprite.modulate == Color.WHITE,
		"mat=%s tex_ok=%s" % [str(e._sprite.material == e._material),
			str(e._sprite.texture == base_tex)])
	e._apply_flash(0.0)
	_check("⑥f 非满载闪毕：材质摘除（R202 ③ 闪白窗外无逐敌 shader）",
		e._sprite.material == null, "mat=%s" % str(e._sprite.material))
	_release(e)
	# 满载闪白敌 is_batch_broken 反向（R237 契约：闪白期不再断批——本刀目的）
	var e2 := _acquire(&"E_R237_A2")
	Enemy.fullload_override = 1
	e2._apply_flash(1.0)
	_check("⑥g 满载闪白敌 is_batch_broken==false（闪白期不再断批——R237 契约迁移源）",
		e2._sprite.modulate == Color.WHITE and not e2.is_batch_broken(), "")
	e2._apply_flash(0.0)
	Enemy.fullload_override = -1
	_release(e2)
	# 源级锚（r213 B1 / r217 ⑤ 先例：grep 源码断言结构在位）
	var f := FileAccess.open(ENEMY_SOURCE, FileAccess.READ)
	var enemy_src := f.get_as_text().replace("\r\n", "\n") if f != null else ""
	if f != null:
		f.close()
	var tf := FileAccess.open(TF_SOURCE, FileAccess.READ)
	var tf_src := tf.get_as_text().replace("\r\n", "\n") if tf != null else ""
	if tf != null:
		tf.close()
	_check("⑥h 源级锚：FLASH_TEX 默认 true + enemy_tex_flash/_restore_flash_tex 接线在位 + TF 烘焙口在位",
		enemy_src.contains("static var FLASH_TEX: bool = true")
			and enemy_src.contains("TextureFactory.enemy_tex_flash(")
			and enemy_src.contains("_restore_flash_tex()")
			and tf_src.contains("static func enemy_tex_flash("),
		"enemy=%s tf=%s" % [str(enemy_src.contains("static var FLASH_TEX: bool = true")),
			str(tf_src.contains("static func enemy_tex_flash("))])


func _cleanup() -> void:
	Enemy.fullload_override = -1
	Enemy.FLASH_TEX = true                # 源默认 on 态复位（防跨套件泄漏）
	Enemy._fullload_latched = false
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null
