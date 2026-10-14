# tests/runner/r202_g3_enemyhot_cases.gd
# R202 G3「敌群热路径与渲染优化」用例体（由 test_r202_g3_enemyhot.gd 入口在 autoload
# 就绪后运行时加载编译；文件名避让说明见入口头注释——test_r202_perf 归 G4 帧率显示）。
# 全部断言为 R202 新增（测试断言改动注明 R202）：
#   ① fx_quality 缓存：档位表 const 值锁定（高档逐位 = 现值——flames 4/arcs 2/shards 3）
#      + set_setting 信号刷新 static 缓存（直写盲区口径见 enemy.gd 声明处注释）。
#   ② 接触伤害圆距判定：贴身命中 / reach 外不命中 / 玩家无敌帧节流语义保留。
#   ③ 闪白窗外摘材质：常态 material==null / 起闪挂回 / 窗外摘除 / 池复用收口。
#   ④ 状态表现件档预算：q=2 全量（== 既有断言口径）/ q=1 减量 / q=0 关（余烬光晕保留）。
#   ⑤ 写点 30Hz 节拍：稳态跳写（_sfx_write_left 半拍中间值）/ 状态签名变化当帧写透。
#   ⑥ Boss 附属 _get_player static 弱引用缓存：两次同引用 + WeakRef 落位。
#   ⑦ elemental_system 复用缓冲倒序遍历：reaction_cd 恰递减一次（双访回归防线）。
#   ⑧ elemental_state reaction_cd：到期 erase / 空表守卫 / 缓冲复用语义不变。
#   ⑨ elemental_fx_layer IMPACT_CD：节流窗内吞触发 / CD 过期放行（r198 ⑨ 只断
#      add_child==0，IMPACT_CD 吞 24 次属侥幸绿——此处补真节流断言）。
extends RefCounted

const DT := 1.0 / 60.0
const MAIN_SCENE := "res://scenes/main.tscn"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	_test_fx_quality_cache()          # ①
	_test_status_budget_tiers()       # ④
	_test_write_throttle()            # ⑤
	await _test_contact_circle()      # ②（真物理帧驱动 area_entered/exited——协程）
	_test_flash_material()            # ③
	_test_appendage_player_cache()    # ⑥
	_test_elemental_system_iter()     # ⑦
	_test_state_reaction_cd()         # ⑧
	_test_impact_cd()                 # ⑨
	_teardown_game_loop()
	Meta.set_setting("fx_quality", 2) # 出口净场（防污染其他套件——fx_quality_cases 同款）
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])


func _fixture_enemy(p_id: StringName, p_hp: float, p_dmg: float = 0.0) -> EnemyData:
	# verify_feedback_cases.gd:511 同款夹具（静态：spd 0 / 可配 dmg——② 接触伤害档用）
	var d := EnemyData.new()
	d.id = p_id
	d.display_name = String(p_id)
	d.hp_base = p_hp
	d.spd_base = 0.0
	d.dmg_base = p_dmg
	d.exp_base = 1.0
	d.hitbox_r = 14.0
	d.resist = [0.0, 0.0, 0.0, 0.0]
	return d


func _acquire(p_id: StringName, p_hp: float = 100.0, p_dmg: float = 0.0) -> Enemy:
	var enemy := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	enemy.spawn(_fixture_enemy(p_id, p_hp, p_dmg), 1, 0)
	return enemy


func _release(p_enemy: Enemy) -> void:
	(_gl.pools[&"enemy"] as EnemyPool).release(p_enemy)


# ═══ ① fx_quality 缓存 + ④ 档位表 const 锁定 ═══════════════════════
func _test_fx_quality_cache() -> void:
	print("── ① fx_quality 热路径缓存（档位表 const + 信号刷新） ──")
	Meta.set_setting("fx_quality", 2)
	# ①a 档位表值锁定（R202 ④：高档必须 = 现值——flames 4 / arcs 2 / shards 3 / mist 3）
	_check("R202 ①a：FLAME_BUDGET == [0,2,4]（高档 = BURN_FLAME_COUNT 现值）",
		Enemy.FLAME_BUDGET.size() == 3 and int(Enemy.FLAME_BUDGET[0]) == 0
		and int(Enemy.FLAME_BUDGET[1]) == 2 and int(Enemy.FLAME_BUDGET[2]) == Enemy.BURN_FLAME_COUNT,
		str(Enemy.FLAME_BUDGET))
	_check("R202 ①b：FROST_SHARD_BUDGET == [0,2,3]（高档 = FROST_SHARD_COUNT 现值）",
		Enemy.FROST_SHARD_BUDGET.size() == 3 and int(Enemy.FROST_SHARD_BUDGET[0]) == 0
		and int(Enemy.FROST_SHARD_BUDGET[1]) == 2
		and int(Enemy.FROST_SHARD_BUDGET[2]) == Enemy.FROST_SHARD_COUNT,
		str(Enemy.FROST_SHARD_BUDGET))
	_check("R202 ①c：SHOCK_ARC_BUDGET == [0,1,2]（高档 = 原双弧）",
		Enemy.SHOCK_ARC_BUDGET.size() == 3 and int(Enemy.SHOCK_ARC_BUDGET[0]) == 0
		and int(Enemy.SHOCK_ARC_BUDGET[1]) == 1 and int(Enemy.SHOCK_ARC_BUDGET[2]) == 2,
		str(Enemy.SHOCK_ARC_BUDGET))
	_check("R202 ①d：SUPER_MIST_BUDGET == [0,2,3] + FROST_RING_MIN_Q == 1（环中/高档开）",
		Enemy.SUPER_MIST_BUDGET.size() == 3 and int(Enemy.SUPER_MIST_BUDGET[0]) == 0
		and int(Enemy.SUPER_MIST_BUDGET[1]) == 2 and int(Enemy.SUPER_MIST_BUDGET[2]) == 3
		and Enemy.FROST_RING_MIN_Q == 1,
		str(Enemy.SUPER_MIST_BUDGET))
	# ①b 信号刷新：池敌在树（订阅活）→ set_setting 后 static 缓存即时换值
	#（直写 Meta._settings 不发信号会留旧值——直写盲区，见 enemy.gd 声明处注释）
	Meta.set_setting("fx_quality", 1)
	_check("R202 ①e：set_setting(1) → 缓存即时刷新（订阅侧直写 static）",
		Enemy._fx_q() == 1, "cache=%d" % Enemy._fx_q())
	Meta.set_setting("fx_quality", 0)
	_check("R202 ①f：set_setting(0) → 缓存即时刷新（低档路径）",
		Enemy._fx_q() == 0, "cache=%d" % Enemy._fx_q())
	Meta.set_setting("fx_quality", 2)
	_check("R202 ①g：set_setting(2) 复位高档（出口口径）",
		Enemy._fx_q() == 2, "cache=%d" % Enemy._fx_q())


# ═══ ④ 档位预算行为（首帧写透 + 各档件数） ═════════════════════════
func _test_status_budget_tiers() -> void:
	print("── ④ 状态表现件档预算（q=2 全量 / q=1 减量 / q=0 关） ──")
	# 高档（q=2）：单次 _tick_status_fx 后挂件就位（verify_feedback_cases.gd:661-686
	# 单步断言同款口径——首帧写透语义的 G3 侧锁定）
	var e2 := _acquire(&"E_R202_T2", 100.0)
	_gl.elemental.register_host(e2)
	var st2: ElementalState = e2.elemental
	st2.gauges[GameConst.Element.LTG] = 50.0
	e2.call(&"_tick_status_fx", DT)
	_check("R202 ④a：q=2 感电首帧写透——双电弧就位（SHOCK_ARC_BUDGET[2]）",
		int(e2._shock_arcs.size()) == 2, "size=%d" % int(e2._shock_arcs.size()))
	st2.gauges[GameConst.Element.LTG] = 0.0
	st2.apply(GameConst.Element.FIR, 100.0, 100.0)
	e2.call(&"_tick_status_fx", DT)
	_check("R202 ④b：q=2 点燃首帧写透——火苗 ×4（FLAME_BUDGET[2]）+ 余烬光晕在",
		int(e2._burn_flames.size()) == 4 and e2._burn_ember != null and e2._burn_ember.visible,
		"flames=%d" % int(e2._burn_flames.size()))
	st2.apply(GameConst.Element.ICE, 100.0, 100.0)
	st2.apply(GameConst.Element.ICE, 100.0, 100.0)   # 二次满槽 → 完全冻结
	e2.call(&"_tick_status_fx", DT)
	_check("R202 ④c：q=2 冻结首帧写透——冰渣 ×3 放大档 + 冰环在（shards/ring 全量）",
		int(e2._frost_shards.size()) == 3 and e2._frost_ring != null
		and (e2._frost_shards[0] as Sprite2D).scale.x >= e2._base_scale * 1.4
		and e2._frost_ring.visible,
		"shards=%d ring=%s" % [int(e2._frost_shards.size()), str(e2._frost_ring != null)])
	st2.apply_superconduct(-0.3, 6.0)
	e2.call(&"_tick_status_fx", DT)
	_check("R202 ④d：q=2 超导首帧写透——雾点 ×3（SUPER_MIST_BUDGET[2]）",
		int(e2._super_mist.size()) == 3, "mist=%d" % int(e2._super_mist.size()))
	_gl.elemental.unregister_host(e2)
	_release(e2)
	# 中档（q=1）：全新敌（非池复用——池件携带上一世高档挂件，建件数断言须净身；
	# render_load_probe 直建先例）在 q=1 下首帧建件——flames 2 / arcs 1 / shards 2 / mist 2
	Meta.set_setting("fx_quality", 1)
	var e1 := Enemy.new()
	tree.get_root().add_child(e1)
	e1.spawn(_fixture_enemy(&"E_R202_T1", 100.0), 1, 0)
	_gl.elemental.register_host(e1)
	var st1: ElementalState = e1.elemental
	st1.apply(GameConst.Element.FIR, 100.0, 100.0)
	st1.apply(GameConst.Element.ICE, 100.0, 100.0)
	st1.apply(GameConst.Element.ICE, 100.0, 100.0)
	st1.gauges[GameConst.Element.LTG] = 50.0
	st1.apply_superconduct(-0.3, 6.0)
	e1.call(&"_tick_status_fx", DT)
	_check("R202 ④e：q=1 减量建件——火苗 2 / 电弧 1 / 冰渣 2 / 雾点 2（中档口径）",
		int(e1._burn_flames.size()) == 2 and int(e1._shock_arcs.size()) == 1
		and int(e1._frost_shards.size()) == 2 and int(e1._super_mist.size()) == 2,
		"f=%d a=%d s=%d m=%d" % [int(e1._burn_flames.size()), int(e1._shock_arcs.size()),
			int(e1._frost_shards.size()), int(e1._super_mist.size())])
	_check("R202 ④f：q=1 冰环在（FROST_RING_MIN_Q=1 中/高档开）",
		e1._frost_ring != null and e1._frost_ring.visible)
	_gl.elemental.unregister_host(e1)
	e1.free()
	# 低档（q=0）：净身新敌挂件零建（预算 0），余烬光晕与染色保留（点燃可读性底线）
	Meta.set_setting("fx_quality", 0)
	var e0 := Enemy.new()
	tree.get_root().add_child(e0)
	e0.spawn(_fixture_enemy(&"E_R202_T0", 100.0), 1, 0)
	_gl.elemental.register_host(e0)
	var st0: ElementalState = e0.elemental
	st0.apply(GameConst.Element.FIR, 100.0, 100.0)
	st0.apply(GameConst.Element.ICE, 100.0, 100.0)
	st0.apply(GameConst.Element.ICE, 100.0, 100.0)
	st0.gauges[GameConst.Element.LTG] = 50.0
	st0.apply_superconduct(-0.3, 6.0)
	e0.call(&"_tick_status_fx", DT)
	e0.call(&"_tick_status_fx", DT)
	e0.call(&"_tick_status_fx", DT)
	_check("R202 ④g：q=0 零建件——火苗/电弧/冰渣/雾点全不建（低档只剩染色读感）",
		int(e0._burn_flames.size()) == 0 and int(e0._shock_arcs.size()) == 0
		and int(e0._frost_shards.size()) == 0 and int(e0._super_mist.size()) == 0
		and e0._frost_ring == null and e0._shock_bolt == null,
		"f=%d a=%d s=%d m=%d" % [int(e0._burn_flames.size()), int(e0._shock_arcs.size()),
			int(e0._frost_shards.size()), int(e0._super_mist.size())])
	_check("R202 ④h：q=0 余烬光晕保留（低档点燃可读性底线——flame_budget 只管火苗）",
		e0._burn_ember != null and e0._burn_ember.visible)
	_gl.elemental.unregister_host(e0)
	e0.free()
	# 降档隐藏（q=2 建满 → q=0 过节拍后超额件全隐）：档位运行期切换语义
	Meta.set_setting("fx_quality", 2)
	var ed := _acquire(&"E_R202_TD", 100.0)
	_gl.elemental.register_host(ed)
	var std_: ElementalState = ed.elemental
	std_.apply(GameConst.Element.FIR, 100.0, 100.0)
	std_.apply(GameConst.Element.ICE, 100.0, 100.0)
	std_.apply(GameConst.Element.ICE, 100.0, 100.0)
	ed.call(&"_tick_status_fx", DT)              # q=2 建满
	Meta.set_setting("fx_quality", 0)
	for i in range(4):                           # 过 30Hz 节拍（1/30s ×2 窗）
		ed.call(&"_tick_status_fx", DT)
	var vis_flames := 0
	for f in ed._burn_flames:
		if (f as Sprite2D).visible:
			vis_flames += 1
	var vis_shards := 0
	for s in ed._frost_shards:
		if (s as Sprite2D).visible:
			vis_shards += 1
	_check("R202 ④i：运行期降档 q=2→0——超额火苗/冰渣全隐（预算超集隐藏口径）",
		vis_flames == 0 and vis_shards == 0 and not ed._frost_ring.visible,
		"vf=%d vs=%d ring=%s" % [vis_flames, vis_shards, str(ed._frost_ring.visible)])
	_gl.elemental.unregister_host(ed)
	_release(ed)
	Meta.set_setting("fx_quality", 2)


# ═══ ⑤ 写点 30Hz 节拍（稳态跳写 + 签名变化写透） ═══════════════════
func _test_write_throttle() -> void:
	print("── ⑤ 状态表现层写点 30Hz 节拍 ──")
	var e := _acquire(&"E_R202_W", 100.0)
	_gl.elemental.register_host(e)
	var st: ElementalState = e.elemental
	st.apply(GameConst.Element.FIR, 100.0, 100.0)
	e.call(&"_tick_status_fx", DT)                # 首帧（签名变化）→ 写 + 重置节拍
	_check("R202 ⑤a：写帧后节拍重置（_sfx_write_left ≈ 1/30）",
		absf(e._sfx_write_left - 1.0 / 30.0) < 0.0005,
		"left=%.4f" % e._sfx_write_left)
	e.call(&"_tick_status_fx", DT)                # 半拍：1/30 - 1/60 = 1/60 > 0 → 跳写
	_check("R202 ⑤b：稳态半拍跳写（1/60 处未重置——写点减半的观测口）",
		absf(e._sfx_write_left - 1.0 / 60.0) < 0.0005,
		"left=%.4f" % e._sfx_write_left)
	e.call(&"_tick_status_fx", DT)                # 到拍：≤0 → 再写
	_check("R202 ⑤c：节拍到点再写（_sfx_write_left 重置回 1/30）",
		absf(e._sfx_write_left - 1.0 / 30.0) < 0.0005,
		"left=%.4f" % e._sfx_write_left)
	# 签名变化当帧写透（不再等节拍）：burning 熄灭 → 余烬/火苗当帧隐藏
	e._sfx_write_left = 1.0 / 30.0               # 人为置满拍（下拍本不该写）
	st.burn_timer = 0.0
	e.call(&"_tick_status_fx", DT)
	_check("R202 ⑤d：状态签名变化当帧写透（熄灭即隐藏——不受节拍延迟）",
		not e._burn_ember.visible, "ember_visible=%s" % str(e._burn_ember.visible))
	_gl.elemental.unregister_host(e)
	_release(e)


# ═══ ② 接触伤害（物理信号驱动重叠缓存） ═══════════════════════════
func _test_contact_circle() -> void:
	print("── ② 接触伤害物理信号缓存（area_entered 旗 + tick 读旗结算） ──")
	# 实现口径（R202 ②）：原每敌每帧 get_overlapping_areas() 轮询改 area_entered/exited
	# 维护 _contact_player 旗。⚠不采 tick 内直算圆距变体——blink_cases.gd:161「走位出圈
	# 免伤」直驱 enemy.tick 不步物理（原 Area2D 通道在无物理帧下从不结算接触伤），
	# 直算圆距会在闪现落地帧立即结算砸红该套件（不在本组白名单）；信号驱动局内语义
	# 与原轮询逐位一致。本段用真物理帧（await physics_frame）驱动 area_entered/exited。
	# R202 收口：原 await process_frame 是 idle 信号——不保证物理步已跑（headless 无帧率
	# 帽时两次 idle await 可能只含 0~1 个物理步；实测 area_exited 在位移写后的第 2 个
	# 物理步才派发），旗滞留 armed → ②b 误伤砸红。改 await physics_frame（物理步后必
	# 恢复，两次 = 两次物理冲刷），信号可见性与 await 点严格同步。
	var player := _gl.player
	var enemy := _acquire(&"E_R202_C", 100.0, 25.0)   # dmg_base 25 → contact_dmg 25
	var pr: float = float(player.hitbox_radius)
	var reach: float = float(enemy.hitbox_r) + pr
	# ②a 贴身（20 < reach 30）+ 物理帧 → 旗 arm → 单 tick 命中
	player.hp = 1000.0
	player.invuln_left = 0.0
	enemy.global_position = player.global_position + Vector2(20.0, 0.0)
	await tree.physics_frame
	await tree.physics_frame
	enemy.tick(DT)
	_check("R202 ②a：贴身物理重叠 arm 后单 tick 命中（圆重叠 ≤ hitbox_r+hitbox_radius=30）",
		absf(player.hp - 975.0) < 0.001, "hp=%.1f" % player.hp)
	# ②b 拉出 reach+2 物理帧 → 旗 disarm → 不命中
	enemy.global_position = player.global_position + Vector2(reach + 2.0, 0.0)
	await tree.physics_frame
	await tree.physics_frame
	player.hp = 1000.0
	player.invuln_left = 0.0
	enemy.tick(DT)
	_check("R202 ②b：reach+2px 外物理重叠解除（area_exited 清旗——零误伤）",
		absf(player.hp - 1000.0) < 0.001, "hp=%.1f" % player.hp)
	# ②c 玩家无敌帧（contact_tick 节流闸在 take_contact_damage 内——语义保留）
	enemy.global_position = player.global_position + Vector2(10.0, 0.0)
	await tree.physics_frame
	await tree.physics_frame
	player.hp = 1000.0
	player.invuln_left = 1.0
	enemy.tick(DT)
	_check("R202 ②c：无敌帧内贴身不伤（玩家侧 contact_tick 节流语义保留）",
		absf(player.hp - 1000.0) < 0.001, "hp=%.1f" % player.hp)
	player.invuln_left = 0.0
	player.hp = float(player.max_hp)
	_release(enemy)


# ═══ ③ 闪白窗外摘材质 ═════════════════════════════════════════════
func _test_flash_material() -> void:
	print("── ③ 受击闪白窗外摘材质（常态恢复 2D 批处理） ──")
	var e := _acquire(&"E_R202_F", 100.0)
	_check("R202 ③a：常态 _sprite.material == null（闪白窗外无逐敌 shader）",
		e._sprite.material == null, "mat=%s" % str(e._sprite.material))
	var r := DamageResult.new()
	r.final_value = 10.0
	r.pos = e.global_position + Vector2(30.0, 0.0)
	e.take_result(r)
	_check("R202 ③b：起闪挂回材质（take_result → material == _material）",
		e._sprite.material == e._material,
		"mat=%s" % str(e._sprite.material))
	_check("R202 ③c：起闪 flash_amount == 1.0",
		absf(float(e._material.get_shader_parameter(&"flash_amount")) - 1.0) < 0.001)
	for i in range(5):                           # 5×1/60 > FLASH_TIME 0.06 → 窗外
		e.tick(DT)
	_check("R202 ③d：闪白窗外摘除（tick 过 0.06s → material == null）",
		e._sprite.material == null, "mat=%s" % str(e._sprite.material))
	_release(e)
	# 池复用收口：归还再取出（_reset_state 的 _apply_flash(0.0) 兼任摘除口）
	var e2 := _acquire(&"E_R202_F2", 100.0)
	var r2 := DamageResult.new()
	r2.final_value = 10.0
	r2.pos = e2.global_position + Vector2(30.0, 0.0)
	e2.take_result(r2)
	_release(e2)
	var e3 := _acquire(&"E_R202_F3", 100.0)
	_check("R202 ③e：池复用后常态 material == null（_reset_state 摘除收口）",
		e3._sprite.material == null, "mat=%s" % str(e3._sprite.material))
	_release(e3)


# ═══ ⑥ Boss 附属 _get_player static 弱引用缓存 ════════════════════
func _test_appendage_player_cache() -> void:
	print("── ⑥ Boss 附属玩家弱引用缓存（三附属共用单缓存） ──")
	var mine := Enemy.BossMine.new()
	tree.get_root().add_child(mine)               # _get_player 需在树（get_tree）
	var p1: Node2D = mine._get_player()
	var p2: Node2D = mine._get_player()
	_check("R202 ⑥a：BossMine._get_player 命中玩家组（GL 玩家）",
		p1 != null and p1 == _gl.player, "p1=%s" % str(p1))
	_check("R202 ⑥b：二次调用同引用（WeakRef 缓存命中零组查询）",
		p2 == p1 and Enemy._appendage_player != null
		and Enemy._appendage_player.get_ref() == p1)
	# 三附属共用：HazardPool/BossSweep 直调同缓存（不重查组）
	var pool := Enemy.HazardPool.new()
	tree.get_root().add_child(pool)
	_check("R202 ⑥c：HazardPool._get_player 共用单缓存（同引用返回）",
		pool._get_player() == p1)
	mine.free()
	pool.free()


# ═══ ⑦ elemental_system 复用缓冲倒序遍历 ══════════════════════════
func _test_elemental_system_iter() -> void:
	print("── ⑦ 元素系统复用缓冲遍历（恰一次语义） ──")
	var sys := ElementalSystem.new()
	tree.get_root().add_child(sys)
	var hosts: Array[Node2D] = []
	for i in range(3):
		var h := _acquire(&"E_R202_S", 100.0)
		sys.register_host(h)
		(h.elemental as ElementalState).gauges[GameConst.Element.FIR] = 1.0
		hosts.append(h)
	# reaction_cd 恰递减一次：快照遍历若双访（倒序滑落缺陷）会递减两次
	(hosts[0].elemental as ElementalState).reaction_cd[GameConst.ReactionType.RXN_LTG_DEN] = 1.0
	sys.tick(0.5)
	_check("R202 ⑦a：reaction_cd 恰递减一次（1.0 → 0.5——遍历无双访）",
		absf(float((hosts[0].elemental as ElementalState).reaction_cd.get(
			GameConst.ReactionType.RXN_LTG_DEN, -1.0)) - 0.5) < 0.001,
		"cd=%s" % str((hosts[0].elemental as ElementalState).reaction_cd.get(
			GameConst.ReactionType.RXN_LTG_DEN, -1.0)))
	sys.tick(0.5)
	_check("R202 ⑦b：到期键 erase（0.5 → 过期回落空表——缓冲复用第二轮语义不变）",
		(hosts[0].elemental as ElementalState).reaction_cd.is_empty())
	# 全宿主衰减推进（倒序快照不漏访）：⑦a/⑦b 两轮 sys.tick(0.5) 各恰一次衰减
	#（λ 取真源 balance.element_decay_lambda[0]，缺省 0.35）
	var lambda := 0.35
	if GameConfig.balance != null:
		lambda = float(GameConfig.balance.element_decay_lambda[0])
	var expect := maxf(1.0 - lambda * 0.5, 0.0) * maxf(1.0 - lambda * 0.5, 0.0)
	var ok_decay := true
	var got := -1.0
	for h in hosts:
		got = float((h.elemental as ElementalState).gauges[GameConst.Element.FIR])
		if not is_equal_approx(got, expect):
			ok_decay = false
	_check("R202 ⑦c：三宿主全量遍历（倒序索引无漏访——两轮 λ 衰减恰两次）",
		ok_decay, "expect=%.4f got=%.4f" % [expect, got])
	# R202 收口：先解绑后 free（原顺序 sys.free() 在前——unregister_host 落在 freed
	# 对象上报 SCRIPT ERROR「Nonexistent function ... previously freed」）
	for h in hosts:
		sys.unregister_host(h)
		_release(h)
	sys.free()


# ═══ ⑧ elemental_state reaction_cd 零分配路径 ═════════════════════
func _test_state_reaction_cd() -> void:
	print("── ⑧ 状态容器 reaction_cd（is_empty 守卫 + 缓冲复用） ──")
	var lambdas: Array[float] = [0.35, 0.30, 0.40, 0.35, 0.50, 0.25, 0.30]
	var st := ElementalState.new()
	# 空表守卫路径（多数帧形态）
	st.tick(DT, lambdas)
	_check("R202 ⑧a：空 reaction_cd tick 零异常（is_empty 守卫路径）",
		st.reaction_cd.is_empty())
	# 到期 erase
	st.reaction_cd[GameConst.ReactionType.RXN_FIR_ICE] = 0.5
	st.tick(0.6, lambdas)
	_check("R202 ⑧b：到期键 erase（0.5 < 0.6 → 回落空表）",
		st.reaction_cd.is_empty())
	# 缓冲复用第二轮（成员 _expired_scratch 复用后语义不变）
	st.reaction_cd[GameConst.ReactionType.RXN_FIR_HYD] = 1.0
	st.reaction_cd[GameConst.ReactionType.RXN_FIR_LTG] = 1.0
	st.tick(0.5, lambdas)
	_check("R202 ⑧c：双键并进 0.5（缓冲复用不串键/不漏键）",
		absf(float(st.reaction_cd.get(GameConst.ReactionType.RXN_FIR_HYD, -1.0)) - 0.5) < 0.001
		and absf(float(st.reaction_cd.get(GameConst.ReactionType.RXN_FIR_LTG, -1.0)) - 0.5) < 0.001,
		"cd=%s" % str(st.reaction_cd))


# ═══ ⑨ elemental_fx_layer IMPACT_CD 迸裂节流 ═════════════════════
func _test_impact_cd() -> void:
	print("── ⑨ beam_impact 迸裂全局节流（IMPACT_CD） ──")
	var layer := ElementalFxLayer.new()
	tree.get_root().add_child(layer)              # _ready 预建 20 槽
	var n0 := _active_impacts(layer)
	layer._on_beam_impact(Vector2(100.0, 100.0), Vector2.RIGHT)
	layer._on_beam_impact(Vector2(200.0, 100.0), Vector2.RIGHT)
	layer._on_beam_impact(Vector2(300.0, 100.0), Vector2.RIGHT)
	_check("R202 ⑨a：节流窗内吞触发（3 连发只起 1 槽——IMPACT_CD 0.07s）",
		_active_impacts(layer) == n0 + 1,
		"n0=%d n1=%d" % [n0, _active_impacts(layer)])
	layer._tick_impacts(0.08)                     # > IMPACT_CD 0.07 → 节流解禁
	layer._on_beam_impact(Vector2(400.0, 100.0), Vector2.RIGHT)
	_check("R202 ⑨b：CD 过期放行（0.08s 后新触发再起槽）",
		_active_impacts(layer) >= n0 + 2,
		"n=%d" % _active_impacts(layer))
	layer.free()


func _active_impacts(p_layer: ElementalFxLayer) -> int:
	var n := 0
	for imp: Dictionary in p_layer._impacts:
		if float(imp["left"]) > 0.0:
			n += 1
	return n


# ── 环境引导（fx_quality_cases 口径） ───────────────────────────────
func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R202G3GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_check("R202 前置：Boot 进入 MENU", _gl.boot_ready
		and _gl.state == GameConst.GameStatus.MENU)


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null
