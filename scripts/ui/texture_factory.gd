# scripts/ui/texture_factory.gd
# 方向 C「晴空糖果」程序贴图工厂（美术派发单：无外部资源，程序化生成 + 惰性缓存）。
# 全部贴图 = SDF 光栅化（本体填充 + 厚描边 + AA），Boot 后首次使用时生成一次并缓存；
# 运行期零重生成（静态缓存命中）。亮底风格三件套：厚描边 / 高饱和填充 / 白高光点。
class_name TextureFactory
extends RefCounted

static var _cache: Dictionary = {}            # 键 -> ImageTexture（惰性生成）


# ── 实体贴图 ──────────────────────────────────────────────────────
static func bead(p_fill: Color, p_size: int = 64, p_highlight: bool = true) -> ImageTexture:
	# 圆珠（弹幕/卫星/相位点）：厚描边圆 + 左上白高光点（亮底辨识度核心）。
	# 描边占径 ~18%——小半径弹珠（r5~14）缩放后描边仍 ≥1.6px，亮底可辨
	var key := "bead_%s_%d_%s" % [p_fill.to_html(), p_size, str(p_highlight)]
	return _cached(key, func() -> ImageTexture:
		var r := float(p_size) * 0.5 - 9.0
		var layers: Array = [
			{"sd": _circle_at(Vector2.ZERO, r), "fill": p_fill, "ow": 9.0},
		]
		if p_highlight:
			layers.append({"sd": _circle_at(Vector2(-r * 0.34, -r * 0.38), r * 0.3),
				"fill": Color(1.0, 1.0, 1.0, 0.95), "ow": 0.0})
		return _render(p_size, p_size, _shade(layers)))


static func ship(p_silhouette: bool = false) -> ImageTexture:
	# 玩家「哨兵-9」拦截机（用户试玩反馈 2026-08-29：圆舰像救生艇 → 重设计有主角相的
	# 小机甲战机，贴纸厚描边风）：锐利三角翼主体 + 双侧引擎舱 + 机头炮塔 + 座舱盖
	#（白高光玻璃感，内嵌哨兵-9 机器人驾驶员剪影——圆头 + 天线，呼应菜单吉祥物）。
	# 96px 画布；本体半径口径 38 不变（Player._ready 缩放换算零改动）。
	var key := "ship_%s" % str(p_silhouette)
	return _cached(key, func() -> ImageTexture:
		if p_silhouette:
			# 受击闪白剪影（白色战机轮廓，叠加在机体上）
			return _render(96, 96, _shade([
				{"sd": _poly_sd(_ship_body_pts()), "fill": Color.WHITE, "ow": 0.0},
				{"sd": _box_rot_at(Vector2(-20.0, 26.0), Vector2(8.5, 11.0), 6.5, 0.0),
					"fill": Color.WHITE, "ow": 0.0},
				{"sd": _box_rot_at(Vector2(20.0, 26.0), Vector2(8.5, 11.0), 6.5, 0.0),
					"fill": Color.WHITE, "ow": 0.0},
				{"sd": _box_at(Vector2(0.0, -34.0), Vector2(2.4, 7.5), 1.4),
					"fill": Color.WHITE, "ow": 0.0},
			]))
		var deep := PopPalette.PLAYER.lerp(PopPalette.OUTLINE, 0.32)   # 派生深空蓝（引擎舱/炮塔）
		var glass := Color(1.0, 1.0, 1.0, 0.96)
		var body := {"sd": _poly_sd(_ship_body_pts()), "fill": PopPalette.PLAYER, "ow": 7.0}
		var pod_l := {"sd": _box_rot_at(Vector2(-20.0, 26.0), Vector2(8.5, 11.0), 6.5, 0.0),
			"fill": deep, "ow": 5.0}
		var pod_r := {"sd": _box_rot_at(Vector2(20.0, 26.0), Vector2(8.5, 11.0), 6.5, 0.0),
			"fill": deep, "ow": 5.0}
		var stripe_l := {"sd": _box_rot_at(Vector2(-19.0, 13.0), Vector2(2.2, 6.0), 1.0, 0.62),
			"fill": PopPalette.XP, "ow": 0.0}
		var stripe_r := {"sd": _box_rot_at(Vector2(19.0, 13.0), Vector2(2.2, 6.0), 1.0, -0.62),
			"fill": PopPalette.XP, "ow": 0.0}
		var barrel := {"sd": _box_at(Vector2(0.0, -34.0), Vector2(2.4, 7.5), 1.4),
			"fill": deep, "ow": 3.0}
		var turret := {"sd": _circle_at(Vector2(0.0, -26.0), 6.5), "fill": deep, "ow": 4.0}
		var canopy := {"sd": _box_at(Vector2(0.0, -6.0), Vector2(11.0, 13.0), 8.0),
			"fill": glass, "ow": 3.5}
		# 座舱驾驶员「哨兵-9」剪影：圆头 + 天线 + 珊瑚红天线珠（菜单吉祥物呼应）
		var pilot_head := {"sd": _circle_at(Vector2(0.0, -9.0), 4.6), "fill": PopPalette.OUTLINE, "ow": 0.0}
		var pilot_ant := {"sd": _box_at(Vector2(0.0, -17.0), Vector2(0.9, 3.4), 0.4),
			"fill": PopPalette.OUTLINE, "ow": 0.0}
		var pilot_tip := {"sd": _circle_at(Vector2(0.0, -21.2), 1.5), "fill": PopPalette.ENEMY, "ow": 0.0}
		var glass_hi := {"sd": _circle_at(Vector2(-4.2, -13.0), 2.6), "fill": Color(1.0, 1.0, 1.0, 0.9), "ow": 0.0}
		var tip_l := {"sd": _circle_at(Vector2(-29.5, 19.5), 2.2), "fill": Color.WHITE, "ow": 0.0}
		var tip_r := {"sd": _circle_at(Vector2(29.5, 19.5), 2.2), "fill": Color.WHITE, "ow": 0.0}
		return _render(96, 96, _shade([pod_l, pod_r, body, stripe_l, stripe_r, barrel, turret,
			canopy, pilot_head, pilot_ant, pilot_tip, glass_hi, tip_l, tip_r])))


static func _ship_body_pts() -> PackedVector2Array:
	# 拦截机三角翼主体剪影（锐利机鼻 + 后掠翼尖 + 尾部内凹）
	return PackedVector2Array([
		Vector2(0.0, -38.0), Vector2(33.0, 24.0), Vector2(0.0, 14.0), Vector2(-33.0, 24.0),
	])


static func engine_flame() -> ImageTexture:
	# 双引擎喷焰（朝下锥形；青蓝外焰 + 白内焰；挂两侧引擎舱，运行期只做缩放抖动）
	var key := "engine_flame"
	return _cached(key, func() -> ImageTexture:
		var cyan := PopPalette.PLAYER.lerp(PopPalette.SUCCESS, 0.38)   # 派生青蓝（表内 lerp 派生）
		var pts_outer := PackedVector2Array([
			Vector2(-10.0, -16.0), Vector2(10.0, -16.0), Vector2(0.0, 22.0),
		])
		var pts_inner := PackedVector2Array([
			Vector2(-5.0, -13.0), Vector2(5.0, -13.0), Vector2(0.0, 12.0),
		])
		return _render(40, 56, _shade([
			{"sd": _poly_sd(pts_outer), "fill": cyan, "ow": 4.0},
			{"sd": _poly_sd(pts_inner), "fill": Color(1.0, 1.0, 1.0, 0.92), "ow": 0.0},
		])))


static func enemy_tex(p_kind: StringName, p_angry: bool = false) -> ImageTexture:
	# 敌人分型贴图（64px 画布，逻辑半径 32 = hitbox 口径；Boss 96px 画布）。
	# 「晴空糖果」敌人角色化套装（美术深化 2026-08-29）：厚描边 + 圆润填充 + 分型剪影/表情：
	#   grunt=E1 杂兵（珊瑚圆球 + 好奇眼睛 + 腮红 + 呆毛）/ dart=E2 疾冲（尖头飞镖 + 怒目缝眼）/
	#   bastion=E3 重甲（内芯脸板 / 外甲板 / 裂纹外甲板 三张贴，引擎侧双层错位）/
	#   volatile=E4 爆虫（calm 好奇 → scared 惊恐 → detonate 闭眼引爆 三段脸）/
	#   elite=E5 精英（基底 + 金腹徽 + 呆毛，引擎侧加皇冠/悬浮阴影/微光）/
	#   boss1/2/3=大型聚合体（剪影互异：黏菌冠 / 裂变核独眼 / 多眼裂母；angry=二阶段变脸）。
	# （图层装配拆至 _enemy_layers——lambda 体不以 match 臂收尾，规避 Godot 4.3 解析器限制）
	var key := "enemy_%s_%s" % [String(p_kind), str(p_angry)]
	return _cached(key, func() -> ImageTexture:
		var canvas := 96 if String(p_kind).begins_with("boss") else 64
		return _render(canvas, canvas, _shade(_enemy_layers(p_kind, p_angry))))


static func _enemy_layers(p_kind: StringName, p_angry: bool) -> Array:
	# 分型图层装配（普通函数体内的 match，无解析器歧义）。取色只经 PopPalette（允许
	# 表内常量的 lerp 派生——单源不变）。腮红/软色 = 珊瑚红向白插值的派生浅珊瑚。
	var blush := PopPalette.ENEMY.lerp(Color.WHITE, 0.45)
	match p_kind:
		&"dart":
			# E2 疾冲者：尖头飞镖（朝上，引擎侧旋转）——尖吻 + 后掠翼 + 怒目缝眼
			var body := PackedVector2Array([
				Vector2(0.0, -30.0), Vector2(11.0, -6.0), Vector2(26.0, 16.0),
				Vector2(0.0, 10.0), Vector2(-26.0, 16.0), Vector2(-11.0, -6.0),
			])
			var fin_l := PackedVector2Array([
				Vector2(-26.0, 16.0), Vector2(-9.0, 3.0), Vector2(-9.0, 20.0),
			])
			var fin_r := PackedVector2Array([
				Vector2(26.0, 16.0), Vector2(9.0, 3.0), Vector2(9.0, 20.0),
			])
			return [
				{"sd": _poly_sd(body), "fill": PopPalette.ENEMY, "ow": 6.5},
				{"sd": _poly_sd(fin_l), "fill": PopPalette.ENEMY_DEEP, "ow": 3.0},
				{"sd": _poly_sd(fin_r), "fill": PopPalette.ENEMY_DEEP, "ow": 3.0},
				{"sd": _box_rot_at(Vector2(0.0, -14.0), Vector2(1.6, 10.0), 1.4, 0.0),
					"fill": PopPalette.ENEMY_DEEP, "ow": 0.0},
				{"sd": _box_rot_at(Vector2(-6.5, -2.0), Vector2(5.4, 2.1), 1.0, -0.42),
					"fill": Color.WHITE, "ow": 0.0},
				{"sd": _box_rot_at(Vector2(6.5, -2.0), Vector2(5.4, 2.1), 1.0, 0.42),
					"fill": Color.WHITE, "ow": 0.0},
				{"sd": _circle_at(Vector2(-4.4, -3.0), 1.4), "fill": PopPalette.OUTLINE, "ow": 0.0},
				{"sd": _circle_at(Vector2(4.4, -3.0), 1.4), "fill": PopPalette.OUTLINE, "ow": 0.0},
			]
		&"bastion_core":
			# E3 重甲内芯：红脸方芯（引擎侧与外甲板分层错位摆动）
			var layers: Array = [
				{"sd": _box_at(Vector2.ZERO, Vector2(13.0, 13.0), 6.0), "fill": PopPalette.ENEMY, "ow": 5.5},
				{"sd": _circle_at(Vector2(-5.0, -2.0), 3.8), "fill": Color.WHITE, "ow": 2.0},
				{"sd": _circle_at(Vector2(5.0, -2.0), 3.8), "fill": Color.WHITE, "ow": 2.0},
				{"sd": _circle_at(Vector2(-4.4, -1.4), 1.8), "fill": PopPalette.OUTLINE, "ow": 0.0},
				{"sd": _circle_at(Vector2(5.6, -1.4), 1.8), "fill": PopPalette.OUTLINE, "ow": 0.0},
				{"sd": _box_at(Vector2(0.0, 6.5), Vector2(3.4, 1.1), 1.0), "fill": PopPalette.OUTLINE, "ow": 0.0},
			]
			return layers
		&"bastion_armor":
			# E3 外甲板：深红厚板 + 四铆钉（完整态）
			return _bastion_armor_layers(false)
		&"bastion_armor_cracked":
			# E3 外甲板（受击裂纹态）：裂纹细线 + 缺口崩边
			return _bastion_armor_layers(true)
		&"volatile_scared":
			# E4 爆虫·惊恐态：瞪圆眼 + 张嘴 + 汗滴（引导前期）
			var scared: Array = _volatile_body(false)
			scared.append({"sd": _circle_at(Vector2(-8.0, -4.0), 7.6), "fill": Color.WHITE, "ow": 2.4})
			scared.append({"sd": _circle_at(Vector2(8.0, -4.0), 7.6), "fill": Color.WHITE, "ow": 2.4})
			scared.append({"sd": _circle_at(Vector2(-6.8, -2.4), 1.8), "fill": PopPalette.OUTLINE, "ow": 0.0})
			scared.append({"sd": _circle_at(Vector2(9.2, -2.4), 1.8), "fill": PopPalette.OUTLINE, "ow": 0.0})
			scared.append({"sd": _circle_at(Vector2(0.0, 9.5), 4.4), "fill": PopPalette.OUTLINE, "ow": 0.0})
			scared.append({"sd": _circle_at(Vector2(0.5, 8.0), 1.6), "fill": Color.WHITE, "ow": 0.0})
			scared.append({"sd": _circle_at(Vector2(-16.0, -16.0), 2.4), "fill": Color(1.0, 1.0, 1.0, 0.85), "ow": 0.0})
			return scared
		&"volatile":
			if p_angry:
				# E4 爆虫·引爆态：深红 + 闭眼线 + 张大嘴（最后 0.3s；越滚越大由引擎侧缩放承担）
				var boom: Array = _volatile_body(true)
				boom.append({"sd": _box_rot_at(Vector2(-8.0, -5.0), Vector2(4.6, 1.3), 0.6, -0.30),
					"fill": Color.WHITE, "ow": 0.0})
				boom.append({"sd": _box_rot_at(Vector2(8.0, -5.0), Vector2(4.6, 1.3), 0.6, 0.30),
					"fill": Color.WHITE, "ow": 0.0})
				boom.append({"sd": _circle_at(Vector2(0.0, 8.0), 6.0), "fill": PopPalette.OUTLINE, "ow": 0.0})
				boom.append({"sd": _circle_at(Vector2(0.0, 6.6), 2.2), "fill": PopPalette.ENEMY_DEEP, "ow": 0.0})
				return boom
			# E4 爆虫·平静态：好奇眼 + 顶部引信小火花（甜甜弹外表）
			var calm: Array = _volatile_body(false)
			calm.append({"sd": _circle_at(Vector2(-8.0, -4.0), 5.8), "fill": Color.WHITE, "ow": 2.4})
			calm.append({"sd": _circle_at(Vector2(8.0, -4.0), 5.8), "fill": Color.WHITE, "ow": 2.4})
			calm.append({"sd": _circle_at(Vector2(-7.0, -3.0), 2.2), "fill": PopPalette.OUTLINE, "ow": 0.0})
			calm.append({"sd": _circle_at(Vector2(9.0, -3.0), 2.2), "fill": PopPalette.OUTLINE, "ow": 0.0})
			calm.append({"sd": _circle_at(Vector2(0.0, 9.0), 3.2), "fill": PopPalette.OUTLINE, "ow": 0.0})
			return calm
		&"elite":
			# E5 精英：杂兵基底 + 金腹徽（引擎侧再叠皇冠/悬浮阴影/微光粒）
			var g: Array = _grunt_face(blush, 26.0)
			g.append({"sd": _circle_at(Vector2(0.0, 11.0), 8.5), "fill": PopPalette.GOLD, "ow": 2.6})
			g.append({"sd": _poly_sd(_star_pts(3.4, 1.5)), "fill": Color.WHITE, "ow": 0.0})
			return g
		&"boss1":
			# Boss1 聚合体：黏菌冠大球（顶部三鼓包 union）+ 大眼 + 龅牙嘴 + 腮红
			var bumps: Array = [
				[Vector2(0.0, 2.0), 38.0], [Vector2(-28.0, 16.0), 16.0], [Vector2(28.0, 16.0), 16.0],
				[Vector2(-15.0, -28.0), 11.0], [Vector2(0.0, -34.0), 12.0], [Vector2(15.0, -28.0), 11.0],
			]
			return _boss_face(_multi_circle_min(bumps), blush, p_angry)
		&"boss2":
			# Boss2 裂变之核：深红六钝刺核 + 独眼 + 辉光环（angry=瞳孔变红刺变利）
			var layers2: Array = []
			var spike_color := PopPalette.ENEMY if p_angry else PopPalette.ENEMY_DEEP
			for i in range(6):
				var ang := -PI * 0.5 + TAU * float(i) / 6.0
				var pos := Vector2(cos(ang), sin(ang)) * 30.0
				layers2.append({"sd": _box_rot_at(pos, Vector2(7.0, 10.5), 4.0, ang + PI * 0.5),
					"fill": spike_color, "ow": 5.0})
			layers2.append({"sd": _circle_at(Vector2.ZERO, 30.0), "fill": PopPalette.ENEMY_DEEP, "ow": 7.0})
			layers2.append({"sd": _ring_at(19.0, 2.2), "fill": Color(1.0, 1.0, 1.0, 0.35), "ow": 0.0})
			if p_angry:
				layers2.append({"sd": _box_rot_at(Vector2(-9.0, -12.0), Vector2(7.0, 2.0), 1.0, -0.5),
					"fill": PopPalette.OUTLINE, "ow": 0.0})
				layers2.append({"sd": _box_rot_at(Vector2(9.0, -12.0), Vector2(7.0, 2.0), 1.0, 0.5),
					"fill": PopPalette.OUTLINE, "ow": 0.0})
			layers2.append({"sd": _circle_at(Vector2(0.0, -2.0), 10.5), "fill": Color.WHITE, "ow": 3.4})
			layers2.append({"sd": _circle_at(Vector2(1.5, -0.5), 4.6),
				"fill": PopPalette.ENEMY_DEEP if p_angry else PopPalette.OUTLINE, "ow": 0.0})
			layers2.append({"sd": _circle_at(Vector2(-8.0, 12.0), 3.2), "fill": Color(1.0, 1.0, 1.0, 0.45), "ow": 0.0})
			return layers2
		&"boss3":
			# Boss3 无穷裂母：多 lob 簇团 + 三眼 + 宽牙嘴（angry=眼色变红 + 怒眉）
			var cluster := _multi_circle_min([
				[Vector2(0.0, 4.0), 22.0], [Vector2(-20.0, -8.0), 14.0], [Vector2(20.0, -8.0), 14.0],
				[Vector2(-13.0, 18.0), 12.0], [Vector2(13.0, 18.0), 12.0], [Vector2(0.0, -24.0), 12.0],
			])
			var layers3: Array = [{"sd": cluster, "fill": PopPalette.ENEMY, "ow": 7.5}]
			var eye_col := PopPalette.ENEMY_DEEP if p_angry else PopPalette.OUTLINE
			if p_angry:
				layers3.append({"sd": _box_rot_at(Vector2(-13.0, -16.0), Vector2(6.0, 1.8), 0.9, -0.45),
					"fill": PopPalette.OUTLINE, "ow": 0.0})
				layers3.append({"sd": _box_rot_at(Vector2(13.0, -16.0), Vector2(6.0, 1.8), 0.9, 0.45),
					"fill": PopPalette.OUTLINE, "ow": 0.0})
			# 主眼 ×2 + lob 上的三只小眼（「裂母」多眼辨识点）
			layers3.append({"sd": _circle_at(Vector2(-11.0, -4.0), 7.0), "fill": Color.WHITE, "ow": 2.8})
			layers3.append({"sd": _circle_at(Vector2(11.0, -4.0), 7.0), "fill": Color.WHITE, "ow": 2.8})
			layers3.append({"sd": _circle_at(Vector2(-9.5, -2.5), 3.2), "fill": eye_col, "ow": 0.0})
			layers3.append({"sd": _circle_at(Vector2(12.5, -2.5), 3.2), "fill": eye_col, "ow": 0.0})
			layers3.append({"sd": _circle_at(Vector2(-26.0, -14.0), 3.0), "fill": Color.WHITE, "ow": 1.6})
			layers3.append({"sd": _circle_at(Vector2(-25.0, -13.2), 1.4), "fill": eye_col, "ow": 0.0})
			layers3.append({"sd": _circle_at(Vector2(26.0, -14.0), 3.0), "fill": Color.WHITE, "ow": 1.6})
			layers3.append({"sd": _circle_at(Vector2(27.0, -13.2), 1.4), "fill": eye_col, "ow": 0.0})
			layers3.append({"sd": _circle_at(Vector2(0.0, -30.0), 2.6), "fill": Color.WHITE, "ow": 1.5})
			layers3.append({"sd": _circle_at(Vector2(0.0, -29.4), 1.2), "fill": eye_col, "ow": 0.0})
			# 宽嘴 + 双牙
			layers3.append({"sd": _box_at(Vector2(0.0, 12.0), Vector2(10.0, 4.5), 4.0),
				"fill": PopPalette.OUTLINE, "ow": 0.0})
			layers3.append({"sd": _poly_sd(PackedVector2Array([
				Vector2(-5.0, 8.5), Vector2(-1.5, 8.5), Vector2(-3.2, 13.5),
			])), "fill": Color.WHITE, "ow": 0.0})
			layers3.append({"sd": _poly_sd(PackedVector2Array([
				Vector2(1.5, 8.5), Vector2(5.0, 8.5), Vector2(3.2, 13.5),
			])), "fill": Color.WHITE, "ow": 0.0})
			return layers3
		_:
			# grunt（E1 杂兵）：珊瑚圆球 + 好奇眼睛 + 腮红小嘴 + 顶呆毛（气球结剪影）
			return _grunt_face(blush, 26.0)


static func _grunt_face(p_blush: Color, p_r: float) -> Array:
	# E1 杂兵脸（E5 精英复用基底）：球体 + 双好奇眼 + 腮红 + 小嘴 + 呆毛
	return [
		{"sd": _circle_at(Vector2(0.0, -p_r - 3.0), 3.4), "fill": PopPalette.ENEMY, "ow": 4.0},
		{"sd": _circle_at(Vector2.ZERO, p_r), "fill": PopPalette.ENEMY, "ow": 6.5},
		{"sd": _circle_at(Vector2(-8.5, -4.0), 6.0), "fill": Color.WHITE, "ow": 2.6},
		{"sd": _circle_at(Vector2(8.5, -4.0), 6.0), "fill": Color.WHITE, "ow": 2.6},
		{"sd": _circle_at(Vector2(-7.5, -3.0), 2.6), "fill": PopPalette.OUTLINE, "ow": 0.0},
		{"sd": _circle_at(Vector2(9.5, -3.0), 2.6), "fill": PopPalette.OUTLINE, "ow": 0.0},
		{"sd": _circle_at(Vector2(-16.0, 6.0), 3.4), "fill": p_blush, "ow": 0.0},
		{"sd": _circle_at(Vector2(16.0, 6.0), 3.4), "fill": p_blush, "ow": 0.0},
		{"sd": _box_at(Vector2(0.5, 8.0), Vector2(2.4, 1.2), 1.1), "fill": PopPalette.OUTLINE, "ow": 0.0},
	]


static func _volatile_body(p_charged: bool) -> Array:
	# E4 爆虫躯体（三态共享）：球体 + 顶部引信 + 双小脚；charged=深红充能色
	var body_col := PopPalette.ENEMY_DEEP if p_charged else PopPalette.ENEMY
	return [
		{"sd": _box_rot_at(Vector2(2.0, -25.0), Vector2(1.2, 4.5), 0.6, 0.4),
			"fill": PopPalette.OUTLINE, "ow": 0.0},
		{"sd": _circle_at(Vector2(4.5, -28.0), 2.6), "fill": PopPalette.XP, "ow": 1.8},
		{"sd": _circle_at(Vector2.ZERO, 25.0), "fill": body_col, "ow": 6.5},
		{"sd": _circle_at(Vector2(-8.0, 23.0), 3.6), "fill": body_col, "ow": 4.0},
		{"sd": _circle_at(Vector2(8.0, 23.0), 3.6), "fill": body_col, "ow": 4.0},
	]


static func _bastion_armor_layers(p_cracked: bool) -> Array:
	# E3 外甲板（完整/裂纹双态）：深红厚板 + 四铆钉；裂纹态加折线裂缝 + 崩边缺口
	var layers: Array = [
		{"sd": _box_at(Vector2.ZERO, Vector2(23.0, 23.0), 9.0), "fill": PopPalette.ENEMY_DEEP, "ow": 8.0},
		{"sd": _circle_at(Vector2(-15.0, -15.0), 2.8), "fill": PopPalette.PANEL, "ow": 1.4},
		{"sd": _circle_at(Vector2(15.0, -15.0), 2.8), "fill": PopPalette.PANEL, "ow": 1.4},
		{"sd": _circle_at(Vector2(-15.0, 15.0), 2.8), "fill": PopPalette.PANEL, "ow": 1.4},
		{"sd": _circle_at(Vector2(15.0, 15.0), 2.8), "fill": PopPalette.PANEL, "ow": 1.4},
	]
	if p_cracked:
		layers.append({"sd": _box_rot_at(Vector2(-10.0, -4.0), Vector2(9.0, 1.1), 0.4, 0.5),
			"fill": PopPalette.OUTLINE, "ow": 0.0})
		layers.append({"sd": _box_rot_at(Vector2(2.0, 4.0), Vector2(8.0, 1.1), 0.4, -0.7),
			"fill": PopPalette.OUTLINE, "ow": 0.0})
		layers.append({"sd": _box_rot_at(Vector2(8.0, -10.0), Vector2(6.0, 1.1), 0.4, 0.25),
			"fill": PopPalette.OUTLINE, "ow": 0.0})
		layers.append({"sd": _poly_sd(PackedVector2Array([
			Vector2(23.0, -6.0), Vector2(14.0, -2.0), Vector2(23.0, 3.0),
		])), "fill": PopPalette.BG, "ow": 2.0})
	return layers


static func _boss_face(p_body_sd: Callable, p_blush: Color, p_angry: bool) -> Array:
	# Boss1 聚合体脸（普通/二阶段变脸共用装配）：大眼 + 嘴 + 腮红；angry=怒眉红瞳龇牙
	var layers: Array = [{"sd": p_body_sd, "fill": PopPalette.ENEMY, "ow": 8.0}]
	if p_angry:
		layers.append({"sd": _box_rot_at(Vector2(-14.0, -18.0), Vector2(8.0, 2.2), 1.1, -0.5),
			"fill": PopPalette.OUTLINE, "ow": 0.0})
		layers.append({"sd": _box_rot_at(Vector2(14.0, -18.0), Vector2(8.0, 2.2), 1.1, 0.5),
			"fill": PopPalette.OUTLINE, "ow": 0.0})
	layers.append({"sd": _circle_at(Vector2(-13.0, -8.0), 8.6), "fill": Color.WHITE, "ow": 3.6})
	layers.append({"sd": _circle_at(Vector2(13.0, -8.0), 8.6), "fill": Color.WHITE, "ow": 3.6})
	layers.append({"sd": _circle_at(Vector2(-12.0, -7.0), 4.0),
		"fill": PopPalette.ENEMY_DEEP if p_angry else PopPalette.OUTLINE, "ow": 0.0})
	layers.append({"sd": _circle_at(Vector2(14.0, -7.0), 4.0),
		"fill": PopPalette.ENEMY_DEEP if p_angry else PopPalette.OUTLINE, "ow": 0.0})
	if p_angry:
		layers.append({"sd": _box_at(Vector2(0.0, 15.0), Vector2(9.0, 5.0), 4.0),
			"fill": PopPalette.OUTLINE, "ow": 0.0})
		layers.append({"sd": _poly_sd(PackedVector2Array([
			Vector2(-6.0, 10.5), Vector2(-2.0, 10.5), Vector2(-4.0, 16.5),
		])), "fill": Color.WHITE, "ow": 0.0})
		layers.append({"sd": _poly_sd(PackedVector2Array([
			Vector2(2.0, 10.5), Vector2(6.0, 10.5), Vector2(4.0, 16.5),
		])), "fill": Color.WHITE, "ow": 0.0})
	else:
		layers.append({"sd": _circle_at(Vector2(0.0, 16.0), 6.0), "fill": PopPalette.OUTLINE, "ow": 0.0})
	layers.append({"sd": _circle_at(Vector2(-24.0, 10.0), 4.6), "fill": p_blush, "ow": 0.0})
	layers.append({"sd": _circle_at(Vector2(24.0, 10.0), 4.6), "fill": p_blush, "ow": 0.0})
	return layers


static func crown() -> ImageTexture:
	# 精英金色皇冠小标（挂件，引擎侧定位头顶）
	var key := "crown"
	return _cached(key, func() -> ImageTexture:
		var pts := PackedVector2Array([
			Vector2(-15.0, 11.0), Vector2(-15.0, -3.0), Vector2(-7.5, 4.0), Vector2(0.0, -10.0),
			Vector2(7.5, 4.0), Vector2(15.0, -3.0), Vector2(15.0, 11.0),
		])
		return _render(40, 30, _shade([
			{"sd": _poly_sd(pts), "fill": PopPalette.GOLD, "ow": 3.6},
		])))


static func star(p_size: int = 44, p_fill: Color = PopPalette.XP) -> ImageTexture:
	# 经验柠檬五角星（经验碎片/精通卡图标）
	var key := "star_%d_%s" % [p_size, p_fill.to_html()]
	return _cached(key, func() -> ImageTexture:
		var outer := float(p_size) * 0.5 - 5.0
		return _render(p_size, p_size, _shade([
			{"sd": _poly_sd(_star_pts(outer, outer * 0.46)), "fill": p_fill, "ow": outer * 0.3},
		])))


static func shadow_ellipse(p_w: int = 64, p_h: int = 20) -> ImageTexture:
	# 柔边椭圆底影（E5 精英悬浮 / Boss 底影；深藏青低透明，引擎侧只做缩放）
	var key := "shadow_%d_%d" % [p_w, p_h]
	return _cached(key, func() -> ImageTexture:
		var img := Image.create(p_w, p_h, false, Image.FORMAT_RGBA8)
		var cx := float(p_w) * 0.5
		var cy := float(p_h) * 0.5
		for y in range(p_h):
			for x in range(p_w):
				var d := Vector2((float(x) + 0.5 - cx) / cx, (float(y) + 0.5 - cy) / cy).length()
				var a := clampf(1.0 - d, 0.0, 1.0)
				img.set_pixel(x, y, Color(PopPalette.OUTLINE.r, PopPalette.OUTLINE.g,
					PopPalette.OUTLINE.b, 0.30 * a * a))
		return ImageTexture.create_from_image(img))


static func cloud(p_w: int = 190, p_h: int = 110) -> ImageTexture:
	# 大圆/胶囊云（世界基调：淡云蓝白上的低对比云；引擎侧 self_modulate 控制透明度）
	var key := "cloud_%d_%d" % [p_w, p_h]
	return _cached(key, func() -> ImageTexture:
		var body := _multi_circle_min([
			[Vector2(-p_w * 0.26, p_h * 0.12), p_h * 0.3],
			[Vector2(0.0, -p_h * 0.08), p_h * 0.4],
			[Vector2(p_w * 0.26, p_h * 0.12), p_h * 0.3],
		])
		return _render(p_w, p_h, _shade([{"sd": body, "fill": Color.WHITE, "ow": 0.0}])))


static func soft_dot(p_size: int = 64) -> ImageTexture:
	# 径向柔边白点（远层大气泡/粒子贴图）
	var key := "soft_dot_%d" % p_size
	return _cached(key, func() -> ImageTexture:
		var img := Image.create(p_size, p_size, false, Image.FORMAT_RGBA8)
		var c := float(p_size) * 0.5
		for y in range(p_size):
			for x in range(p_size):
				var t := clampf(1.0 - Vector2(float(x) + 0.5 - c, float(y) + 0.5 - c).length() / c, 0.0, 1.0)
				img.set_pixel(x, y, Color(1.0, 1.0, 1.0, t * t))
		return ImageTexture.create_from_image(img))


static func confetti_piece(p_kind: int) -> ImageTexture:
	# 彩纸屑（0=小矩形 1=圆点；白色本体，运行期 modulate 上多色）。
	# 圆点用细描边（bead 厚描边在小画布上会反超本体——多色糖粒观感优先）
	var key := "confetti_%d" % p_kind
	return _cached(key, func() -> ImageTexture:
		if p_kind == 0:
			return _render(14, 20, _shade([
				{"sd": _box_at(Vector2.ZERO, Vector2(6.0, 9.0), 2.5), "fill": Color.WHITE, "ow": 0.0},
			]))
		return _render(24, 24, _shade([
			{"sd": _circle_at(Vector2.ZERO, 10.0), "fill": Color.WHITE, "ow": 2.2},
		])))


static func type_icon(p_kind: int, p_pool: int) -> ImageTexture:
	# 选卡类型圆章：白圆章 + 藏青描边，内嵌类别形（ADD 菱 / MULT 三角 / LOCAL 圆角方 /
	# MECH 六边 / ELEM 圆环 / MASTERY 金星 / RELIC 葡萄钻 / FALLBACK 灰菱）
	var key := "type_icon_%d_%d" % [p_kind, p_pool]
	return _cached(key, func() -> ImageTexture:
		var layers: Array = [
			{"sd": _circle_at(Vector2.ZERO, 26.0), "fill": PopPalette.PANEL, "ow": 5.0},
		]
		var ink := PopPalette.OUTLINE
		match p_kind:
			1:                                    # TRAIT：按 PoolClass 分形
				match p_pool:
					0: layers.append({"sd": _poly_sd(_regular_pts(4, 13.5)), "fill": PopPalette.SUCCESS, "ow": 0.0})
					1: layers.append({"sd": _poly_sd(_regular_pts(3, 14.5)), "fill": PopPalette.ENEMY, "ow": 0.0})
					2: layers.append({"sd": _box_at(Vector2.ZERO, Vector2(10.5, 10.5), 4.5), "fill": ink, "ow": 0.0})
					3: layers.append({"sd": _poly_sd(_regular_pts(6, 14.0)), "fill": PopPalette.PLAYER, "ow": 0.0})
					_: layers.append({"sd": _ring_at(9.0, 4.6), "fill": PopPalette.SHOCK, "ow": 0.0})
			0: layers.append({"sd": _poly_sd(_star_pts(14.0, 6.4)), "fill": PopPalette.GOLD, "ow": 0.0})   # MASTERY
			2: layers.append({"sd": _poly_sd(_regular_pts(4, 13.5, 0.0)), "fill": PopPalette.SHOCK, "ow": 0.0})  # RELIC
			_: layers.append({"sd": _poly_sd(_regular_pts(4, 13.5)), "fill": PopPalette.INK_SOFT, "ow": 0.0})  # FALLBACK
		return _render(64, 64, _shade(layers)))


static func ring_tex(p_fill: Color, p_size: int = 32, p_thickness: float = 4.5) -> ImageTexture:
	# 圆环（Boss 相位空心点 / ELEM 章）
	var key := "ring_%s_%d_%.1f" % [p_fill.to_html(), p_size, p_thickness]
	return _cached(key, func() -> ImageTexture:
		var r := float(p_size) * 0.5 - 5.0
		return _render(p_size, p_size, _shade([
			{"sd": _ring_at(r, p_thickness), "fill": p_fill, "ow": 0.0},
		])))


static func flame_bit() -> ImageTexture:
	# 点燃小火苗（敌人顶部上飘火星/元素 DOT 火星共用）：橙红锥形火苗 + 亮黄内芯
	#（取色 = 表内 ENEMY→XP lerp 派生橙；小尺寸薄描边——confetti 同口径，防描边反超本体）
	var key := "flame_bit"
	return _cached(key, func() -> ImageTexture:
		var orange := PopPalette.ENEMY.lerp(PopPalette.XP, 0.55)
		var pts := PackedVector2Array([
			Vector2(0.0, -10.0), Vector2(5.5, 3.0), Vector2(0.0, 9.0), Vector2(-5.5, 3.0),
		])
		var pts_inner := PackedVector2Array([
			Vector2(0.0, -4.0), Vector2(2.6, 3.0), Vector2(0.0, 6.5), Vector2(-2.6, 3.0),
		])
		return _render(20, 26, _shade([
			{"sd": _poly_sd(pts), "fill": orange, "ow": 2.6},
			{"sd": _poly_sd(pts_inner), "fill": PopPalette.XP, "ow": 0.0},
		])))


static func ice_shard() -> ImageTexture:
	# 结霜小晶体（菱形冰渣）：淡冰蓝菱形 + 白高光 + 藏青描边（贴纸风统一）
	var key := "ice_shard"
	return _cached(key, func() -> ImageTexture:
		var ice := PopPalette.PLAYER.lerp(Color.WHITE, 0.62)           # 派生淡冰蓝
		var pts := PackedVector2Array([
			Vector2(0.0, -11.0), Vector2(7.0, 0.0), Vector2(0.0, 11.0), Vector2(-7.0, 0.0),
		])
		return _render(26, 26, _shade([
			{"sd": _poly_sd(pts), "fill": ice, "ow": 3.2},
			{"sd": _circle_at(Vector2(-1.8, -3.0), 1.8), "fill": Color.WHITE, "ow": 0.0},
		])))


static func ui_glyph(p_kind: int) -> ImageTexture:
	# 暂停按钮贴纸图标（白底圆角方 + 藏青描边 + 藏青图形）：0=⏸ 双竖条 / 1=▶ 三角
	var key := "ui_glyph_%d" % p_kind
	return _cached(key, func() -> ImageTexture:
		var layers: Array = [
			{"sd": _box_at(Vector2.ZERO, Vector2(26.0, 26.0), 14.0), "fill": PopPalette.PANEL, "ow": 5.0},
		]
		if p_kind == 0:
			layers.append({"sd": _box_at(Vector2(-8.0, 0.0), Vector2(4.5, 12.0), 2.0),
				"fill": PopPalette.OUTLINE, "ow": 0.0})
			layers.append({"sd": _box_at(Vector2(8.0, 0.0), Vector2(4.5, 12.0), 2.0),
				"fill": PopPalette.OUTLINE, "ow": 0.0})
		else:
			layers.append({"sd": _poly_sd(PackedVector2Array([
				Vector2(-7.0, -13.0), Vector2(14.0, 0.0), Vector2(-7.0, 13.0),
			])), "fill": PopPalette.OUTLINE, "ow": 0.0})
		return _render(64, 64, _shade(layers)))


# ── 光栅化内核 ────────────────────────────────────────────────────
static func _render(p_w: int, p_h: int, p_shade: Callable) -> ImageTexture:
	# 逐像素着色（Boot/首次使用一次性成本；缓存后运行期零生成）
	var img := Image.create(p_w, p_h, false, Image.FORMAT_RGBA8)
	var half_w := float(p_w) * 0.5
	var half_h := float(p_h) * 0.5
	for y in range(p_h):
		var py := float(y) + 0.5 - half_h
		for x in range(p_w):
			img.set_pixel(x, y, p_shade.call(float(x) + 0.5 - half_w, py))
	return ImageTexture.create_from_image(img)


static func _cached(p_key: String, p_builder: Callable) -> ImageTexture:
	if _cache.has(p_key):
		return _cache[p_key] as ImageTexture
	var tex := p_builder.call() as ImageTexture
	_cache[p_key] = tex
	return tex


static func _shade(p_layers: Array) -> Callable:
	# 图层合成器：[{sd: Callable(x,y)->float, fill: Color, ow: 描边宽, oc: 描边色}]
	# 先绘制在下、后绘制在上；描边在下层、填充在上层，统一 1px AA。
	return func(p_x: float, p_y: float) -> Color:
		var col := Color(0.0, 0.0, 0.0, 0.0)
		for layer_v: Variant in p_layers:
			var layer: Dictionary = layer_v
			var sd: Callable = layer["sd"]
			var d: float = sd.call(p_x, p_y)
			var fill: Color = layer["fill"]
			var ow := float(layer.get("ow", 0.0))
			var oc: Color = layer.get("oc", PopPalette.OUTLINE)
			var body := clampf(0.5 - d, 0.0, 1.0)
			var with_edge := clampf(0.5 - d + ow, 0.0, 1.0)
			col = _over(col, Color(oc.r, oc.g, oc.b, oc.a * (with_edge - body)))
			col = _over(col, Color(fill.r, fill.g, fill.b, fill.a * body))
		return col


static func _over(p_dst: Color, p_src: Color) -> Color:
	# src-over 标准合成
	var a := p_src.a + p_dst.a * (1.0 - p_src.a)
	if a <= 0.0005:
		return Color(0.0, 0.0, 0.0, 0.0)
	var c := (p_src * p_src.a + p_dst * (p_dst.a * (1.0 - p_src.a))) / a
	c.a = a
	return c


# ── SDF 基元 ──────────────────────────────────────────────────────
static func _circle_at(p_center: Vector2, p_r: float) -> Callable:
	return func(p_x: float, p_y: float) -> float:
		return sqrt(pow(p_x - p_center.x, 2.0) + pow(p_y - p_center.y, 2.0)) - p_r


static func _multi_circle_min(p_circles: Array) -> Callable:
	# 多圆 union（[[center, radius], ...]）
	return func(p_x: float, p_y: float) -> float:
		var best := 1e9
		for entry: Variant in p_circles:
			var pair: Array = entry
			var c: Vector2 = pair[0]
			var r: float = pair[1]
			var d := sqrt(pow(p_x - c.x, 2.0) + pow(p_y - c.y, 2.0)) - r
			best = minf(best, d)
		return best


static func _box_at(p_center: Vector2, p_half: Vector2, p_rad: float) -> Callable:
	return func(p_x: float, p_y: float) -> float:
		return _sd_box(p_x - p_center.x, p_y - p_center.y, p_half, p_rad)


static func _box_rot_at(p_center: Vector2, p_half: Vector2, p_rad: float, p_angle: float) -> Callable:
	# 旋转圆角盒（爆虫斜眉）
	return func(p_x: float, p_y: float) -> float:
		var rel := Vector2(p_x - p_center.x, p_y - p_center.y).rotated(-p_angle)
		return _sd_box(rel.x, rel.y, p_half, p_rad)


static func _ring_at(p_r: float, p_thickness: float) -> Callable:
	return func(p_x: float, p_y: float) -> float:
		return absf(sqrt(p_x * p_x + p_y * p_y) - p_r) - p_thickness


static func _poly_sd(p_pts: PackedVector2Array) -> Callable:
	# 多边形 SDF（负在内：交叉计数 + 边最近距离）
	return func(p_x: float, p_y: float) -> float:
		var inside := false
		var best := 1e9
		var n := p_pts.size()
		var p := Vector2(p_x, p_y)
		for i in range(n):
			var a := p_pts[i]
			var b := p_pts[(i + 1) % n]
			var ab := b - a
			var ap := p - a
			var t := clampf(ap.dot(ab) / maxf(ab.length_squared(), 0.0001), 0.0, 1.0)
			best = minf(best, (ap - ab * t).length())
			if (a.y > p_y) != (b.y > p_y):
				var xint := a.x + (p_y - a.y) / (b.y - a.y) * (b.x - a.x)
				if p_x < xint:
					inside = not inside
		return -best if inside else best


static func _sd_box(p_x: float, p_y: float, p_half: Vector2, p_rad: float) -> float:
	var qx := absf(p_x) - p_half.x + p_rad
	var qy := absf(p_y) - p_half.y + p_rad
	return Vector2(maxf(qx, 0.0), maxf(qy, 0.0)).length() + minf(maxf(qx, qy), 0.0) - p_rad


static func _regular_pts(p_sides: int, p_radius: float, p_rot: float = -PI * 0.5) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(p_sides):
		var a := p_rot + TAU * float(i) / float(p_sides)
		pts.append(Vector2(cos(a), sin(a)) * p_radius)
	return pts


static func _star_pts(p_outer: float, p_inner: float, p_rot: float = -PI * 0.5) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(10):
		var r := p_outer if i % 2 == 0 else p_inner
		var a := p_rot + TAU * float(i) / 10.0
		pts.append(Vector2(cos(a), sin(a)) * r)
	return pts
