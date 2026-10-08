# tests/runner/r211_xpstar_cases.gd
# R211 用例体：经验星星三合一验收。
# R216 刀① 有意契约变更（帧率优先口径，vc23 桶遥测定案：碎片同贴图但每片 modulate
# 唯一=全员断批、死亡堆数百片=dc 大头）：档色/档内透明度从「白体贴图 × 逐片 modulate」
# 改为**烤进贴图变体**（4 档×3 量化 alpha + 彩档 6 色相步进，star() 缓存键含填充色
# 自动分键），modulate 恒白；亮度表现改缩放通道。本套锁新契约：
# ①变体贴图：像素=档色原值（棕星根修语义保持——烤色与乘法数学恒等）、四档贴图互异、
#   modulate 恒白（合批红线）；
# ②xp_tier_alpha 纯函数零改动（连续值单源保持——量化只发生在 _baked_tier_color）；
# ③量化映射：连续 alpha 1/3 带宽取整 0.5/0.75/1.0；
# ④merge 爬档换贴图（缓存实例切换）；
# ⑤动画路径不写 modulate（回归亮闪=缩放脉冲）；彩档 6 步进换贴图；
# ⑥池复用无残留（_rainbow_step 清零+重取重算）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0
const EPS := 0.0001

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
	_test_1_baked_texture_tiers()
	_test_2_alpha_formula()
	_test_3_quantize_mapping()
	_test_4_merge_reclimb_texture()
	_test_5_anim_paths_no_modulate()
	_test_6_pool_reuse_no_residue()
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
	# boot 骨架（r209/r210 同款）：GameLoop→MENU→start_run→置回 MENU 冻结波次。
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R211GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_gl.state = GameConst.GameStatus.MENU
	_gl.player.global_position = Vector2(360.0, 900.0)


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


func _rgb_close(p_a: Color, p_b: Color) -> bool:
	# rgb 三通道近似相等（不含 a——alpha 单独断言）
	return absf(p_a.r - p_b.r) < EPS and absf(p_a.g - p_b.g) < EPS \
		and absf(p_a.b - p_b.b) < EPS


func _center_px(p_tex: ImageTexture) -> Color:
	return p_tex.get_image().get_pixel(22, 22)     # 星体中心（fill 纯色区）


# ── ① 变体贴图：像素=档色原值、四档互异、modulate 恒白 ──────────────
func _test_1_baked_texture_tiers() -> void:
	print("── ① 变体贴图（烤色=档色原值 × modulate 恒白） ──")
	var pool := _gl.pools[&"xp"] as XPPool
	var shard: XpShard = pool.acquire()
	shard.activate(30.0, 4.0)               # ratio 7.5 → 紫档（旧链棕星重灾区）
	var center := _center_px(shard._sprite.texture)
	_check("①像素：紫档贴图中心 rgb == #b06ef7 原值（棕星回归锚——烤色与乘法恒等）",
		_rgb_close(center, PopPalette.xp_tier_color(2)),
		"center=%s want=%s" % [center.to_html(false), PopPalette.xp_tier_color(2).to_html(false)])
	var old_style: Color = PopPalette.xp_tier_color(2) * PopPalette.XP
	_check("①反证：旧链乘积 b06ef7×ffc93c=%s ≠ 档色（赭石棕根因已断）" % old_style.to_html(false),
		not _rgb_close(old_style, PopPalette.xp_tier_color(2)), "")
	_check("①modulate：恒纯白（合批红线——逐片唯一 modulate=断批根因）",
		shard._sprite.modulate.is_equal_approx(Color.WHITE),
		"m=%s" % str(shard._sprite.modulate))
	# 四基础档全链：贴图像素逐档 == 档色原值且互异（全档可分辨红线）
	var tiers := [0, 1, 2, 3]
	var vals := [4.0, 12.0, 30.0, 60.0]     # 基线 4 → ratio 1/3/7.5/15 → 白/蓝/紫/金
	var htmls: Array[String] = []
	var texs: Array = []
	var all_match := true
	for i in tiers.size():
		shard.activate(vals[i], 4.0)
		if int(shard._tier) != tiers[i]:
			all_match = false
		var px := _center_px(shard._sprite.texture)
		if not _rgb_close(px, PopPalette.xp_tier_color(tiers[i])):
			all_match = false
		htmls.append(px.to_html(false))
		texs.append(shard._sprite.texture)
	_check("①四档：白/蓝/紫/金 贴图像素 rgb 逐档 == XP_TIER_COLORS 原值（%s）" % "、".join(htmls),
		all_match, "")
	var all_distinct := true
	for a in texs.size():
		for b in range(a + 1, texs.size()):
			if texs[a] == texs[b]:
				all_distinct = false
	_check("①可分辨：四档贴图缓存实例互异（五档递进红线——档色值零改动）",
		all_distinct, "")
	pool.release(shard)


# ── ② xp_tier_alpha 纯函数边界（50% 档底 → 100% 档顶，顶档封顶）──
func _test_2_alpha_formula() -> void:
	print("── ② 档内 alpha 公式（纯函数零改动） ──")
	var a := func(p_v: float, p_b: float) -> float: return XpShard.xp_tier_alpha(p_v, p_b)
	_check("②档底：2.5/5.0/12.0（蓝/紫/金底）均 = 0.5",
		absf(a.call(2.5, 1.0) - 0.5) < EPS and absf(a.call(5.0, 1.0) - 0.5) < EPS
			and absf(a.call(12.0, 1.0) - 0.5) < EPS,
		"%.4f/%.4f/%.4f" % [a.call(2.5, 1.0), a.call(5.0, 1.0), a.call(12.0, 1.0)])
	_check("②线性：3.75 → 0.75（蓝档中点）",
		absf(a.call(3.75, 1.0) - 0.75) < EPS, "%.4f" % a.call(3.75, 1.0))
	_check("②档顶：4.999 / 11.999 ≈ 1.0（蓝/金档顶渐进到满）",
		a.call(4.999, 1.0) > 0.999 and a.call(11.999, 1.0) > 0.999,
		"%.4f/%.4f" % [a.call(4.999, 1.0), a.call(11.999, 1.0)])
	_check("②封顶：40.0 = 80.0 = 1.0（顶档按 value/顶阈值封顶）",
		absf(a.call(40.0, 1.0) - 1.0) < EPS and absf(a.call(80.0, 1.0) - 1.0) < EPS,
		"%.4f/%.4f" % [a.call(40.0, 1.0), a.call(80.0, 1.0)])
	_check("②降级：基线≤0 恒 0.5（(7.7,0) 与 (99,-1) 同口径）",
		absf(a.call(7.7, 0.0) - 0.5) < EPS and absf(a.call(99.0, -1.0) - 0.5) < EPS, "")


# ── ③ 量化映射：连续 alpha → 3 级（0.5/0.75/1.0，1/3 带宽取整） ────
func _test_3_quantize_mapping() -> void:
	print("── ③ 档内 alpha 量化 ──")
	var pool := _gl.pools[&"xp"] as XPPool
	var shard: XpShard = pool.acquire()
	# 白档：ratio 0/0.5/1/2/2.4999 → 连续 alpha 0.5/0.6/0.7/0.9/1.0 → 量化级逐点核对
	var cases := [0.0, 0.5, 1.0, 2.0, 2.4999]
	var ok := true
	var got := ""
	for cv in cases:
		shard.activate(float(cv), 1.0)
		var px := _center_px(shard._sprite.texture)
		# 期望量化级：连续值 (a-0.5)×6 取整 → 0.5/0.75/1.0 三级；像素 alpha 容差
		# 8-bit（0.75×255=191.25 渲染取整 191/255≈0.749——烤进贴图的量化精度下限）
		var q := clampi(int((XpShard.xp_tier_alpha(float(cv), 1.0) - 0.5) * 6.0), 0, 2)
		var want := 0.5 + 0.25 * q
		if absf(px.a - want) > 0.004:
			ok = false
			got = "v=%s a=%.4f want=%.2f" % [str(cv), px.a, want]
	_check("③量化：贴图像素 a ∈ {0.5, 0.75, 1.0}（连续值 (a-0.5)×6 取整带宽 1/3）", ok, got)
	shard.activate(45.0, 1.0)
	var px4 := _center_px(shard._sprite.texture)
	_check("③彩档实断：_tier=4、像素 a=1.0、_rainbow_step ∈ [0,5]",
		int(shard._tier) == 4 and absf(px4.a - 1.0) < EPS
			and shard.get("_rainbow_step") != null and int(shard._rainbow_step) >= 0
			and int(shard._rainbow_step) <= 5,
		"tier=%d a=%.4f step=%d" % [int(shard._tier), px4.a, int(shard._rainbow_step)])
	pool.release(shard)


# ── ④ merge 爬档换贴图（缓存实例切换） ─────────────────────────────
func _test_4_merge_reclimb_texture() -> void:
	print("── ④ merge 爬档 ──")
	var pool := _gl.pools[&"xp"] as XPPool
	var shard: XpShard = pool.acquire()
	shard.activate(4.0, 4.0)                # ratio 1 → 白档 q1（alpha 0.7 → 0.75）
	var tex0: ImageTexture = shard._sprite.texture
	shard.merge_value(30.0, 4.0)            # value 34，ratio 8.5 → 紫档
	var tex1: ImageTexture = shard._sprite.texture
	_check("④爬档：+30 → 贴图换紫档（缓存实例切换，像素==紫档色）",
		int(shard._tier) == 2 and tex1 != tex0
			and _rgb_close(_center_px(tex1), PopPalette.xp_tier_color(2)),
		"tier=%d tex_swapped=%s" % [int(shard._tier), str(tex1 != tex0)])
	shard.merge_value(126.0, 4.0)           # value 160，ratio 40 → 彩档
	var tex2: ImageTexture = shard._sprite.texture
	_check("④顶档：+126 → 彩档（第三次换贴图；merge 必经 _sync_visual 重算）",
		int(shard._tier) == 4 and tex2 != tex1, "tier=%d" % int(shard._tier))
	pool.release(shard)


# ── ⑤ 动画路径不写 modulate（回归亮闪=缩放脉冲；彩档步进换贴图） ────
func _test_5_anim_paths_no_modulate() -> void:
	print("── ⑤ 动画路径零 modulate ──")
	var pool := _gl.pools[&"xp"] as XPPool
	var shard: XpShard = pool.acquire()
	shard.activate(30.0, 4.0)               # 紫档
	shard._phase = XpShard.PHASE_BOB        # 跳过出生弹跳臂，直入回归分支
	shard._homing = true
	shard._homing_flash = 0.0               # 巡航帧（原 ×1.15 提亮——已改缩放通道）
	shard._tick_visual_anim(DT)
	_check("⑤巡航：homing 帧 modulate 仍恒白（提亮乘法已移除→不断批）",
		shard._sprite.modulate.is_equal_approx(Color.WHITE),
		"m=%s" % str(shard._sprite.modulate))
	shard._homing_flash = 0.15              # 亮闪帧（ft=0.5 → 缩放脉冲 1+0.45×0.5）
	shard._tick_visual_anim(DT)
	var s_post: Vector2 = shard._sprite.scale
	_check("⑤亮闪：flash 帧为缩放脉冲（x ≈ _value_scale×1.225）且 modulate 恒白",
		shard._sprite.modulate.is_equal_approx(Color.WHITE)
			and absf(s_post.x - shard._value_scale * (1.0 + 0.45 * 0.5)) < 0.05,
		"s=%s vs=%.3f" % [str(s_post), shard._value_scale])
	pool.release(shard)
	# 彩档步进：_anim_t 推进 → 色相步进变 → 贴图切换（modulate 恒白全程）
	var rb: XpShard = pool.acquire()
	rb.activate(200.0, 4.0)                 # ratio 50 → 彩档
	rb._phase = XpShard.PHASE_BOB
	rb._anim_t = 0.0
	rb._sync_visual()                       # 步进初值 0
	var rb_tex0: ImageTexture = rb._sprite.texture
	var rb_step0: int = int(rb._rainbow_step)
	rb._anim_t = 1.0                        # 步进 1×0.35=0.35 → step 2
	rb._tick_visual_anim(DT)
	var rb_tex1: ImageTexture = rb._sprite.texture
	_check("⑤彩档：_anim_t 0→1 步进 0→2 换贴图（六色回环保持可辨）",
		rb_step0 == 0 and int(rb._rainbow_step) == 2 and rb_tex1 != rb_tex0,
		"step %d→%d swapped=%s" % [rb_step0, int(rb._rainbow_step), str(rb_tex1 != rb_tex0)])
	_check("⑤彩档：全程 modulate 恒白（HSV 逐帧乘法已除）",
		rb._sprite.modulate.is_equal_approx(Color.WHITE),
		"m=%s" % str(rb._sprite.modulate))
	pool.release(rb)


# ── ⑥ 池复用无残留（归还清零 → 再取重算档色） ──────────────────────
func _test_6_pool_reuse_no_residue() -> void:
	print("── ⑥ 池复用残留 ──")
	var pool := _gl.pools[&"xp"] as XPPool
	var shard: XpShard = pool.acquire()
	shard.activate(30.0, 4.0)               # 紫档
	pool.release(shard)                     # _reset_state：modulate 回白+步进清 -1
	_check("⑥归还：_reset_state 后 modulate 恒白且 _rainbow_step=-1",
		shard._sprite.modulate.is_equal_approx(Color.WHITE)
			and int(shard._rainbow_step) == -1,
		"m=%s step=%d" % [str(shard._sprite.modulate), int(shard._rainbow_step)])
	var again: XpShard = pool.acquire()     # 空闲栈 LIFO → 同一实例
	_check("⑥复取：acquire 弹出同一实例（真·复用路径）", again == shard, "")
	again.activate(1.0, 1.0)                # ratio 1 → 白档（非上一碎片紫档残留）
	_check("⑥重算：activate(1,1) → 白档贴图（像素==白档色，无紫档残留）",
		_rgb_close(_center_px(again._sprite.texture), PopPalette.xp_tier_color(0)),
		"px=%s" % _center_px(again._sprite.texture).to_html(false))
	pool.release(again)
