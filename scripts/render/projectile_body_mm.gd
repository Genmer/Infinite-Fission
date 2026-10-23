# scripts/render/projectile_body_mm.gd
# R293 刀A：弹本体 MultiMesh 合批——静态门面（门控/注册册记/生命周期治理；本文件零渲染代码）。
# 弹池 Node2D 逻辑节点（命中/网格/池语义）逐位保留；**本体绘制**从逐弹 Sprite2D canvas
# item 让位给按贴图桶的 MultiMeshInstance2D（R240 敌本体 BodyMM 同款——渲染机构完全
# 复用 TexBucketHost 既有镜像机制，本文件只负责：门、册、翻转治理）：
#   · 注册：弹侧 _place_in_bucket 尾自报（贴图定档后唯一口——变体切换/反弹金染升格
#     自动换 mm 键，与换桶同款语义；敌方先例 enemy.gd _apply_body_mirror 同构）；
#     注销挂池 release 链 unplace/unplace_lazy → host.mirror_unregister（弹侧零改动
#     ——E-04/E-05 回收顺序承重墙不碰；R271 留桶空闲件 invisible 不绘不断批契约由
#     unplace_lazy 既有镜像注销口天然承接）。
#   · 门（三重单谓词合取）：BODY_MM 单点回退（false=逐弹 Sprite 现状零扰动，Enemy.BODY_MM
#     同款先例）× PerfGovernor.boost_mode()（与 R271 惰性归位同一读口——boost 关侧
#     零节点零注册零 sprite 触碰=逐位不变承重墙）× host 具备镜像能力（老测试桩容错）。
#   · 每帧同步：host._process 通用环逐帧写 owner.global×body.local 变换 + root.modulate×
#     body.modulate×body.self_modulate 合成色（曳光/导弹/剑/斧朝向跟踪与 LTG 电花/回旋
#     自旋的 _sprite.rotation 每帧真写天然被承载——无『视觉恒定』优化集）。
#   · 叠序披露（修轮1）：本体让位 MM 后拖尾叠序翻转——原 _sprite 为弹根子件（父 _draw
#     恒绘于子件之下=拖尾在体下，projectile_base._ready 组装位），现 BodyMM 挂桶首位
#     （_build_mm move_child 0）为桶内最低层、弹根（拖尾画布 _draw_boom_trail/
#     _draw_sword_stab_trail）恒在其上 → 拖尾翻为「体上」，且同桶全部拖尾恒压全部弹
#     本体（跨个体面）。半透明拖尾（回旋金弧/灵剑刺痕）叠上刃体的观感差=已知披露项
#     非缺陷（R240 敌侧「本体层恒在瞬态件之下」move_child 0 同款披露先例；qa 点4 4e
#     叠序结构断言在册）。
#   · 元素染色保真：弹侧染色=换贴图非 modulate（_plain_fill→TextureFactory.bead 静态
#     缓存同色同实例），分桶即分色；弹 modulate 恒白 → 实例色 8-bit 钳位零风险（敌方
#     排除面风险在弹侧不存在）。
#   · S1 台架短路臂共门（shortcircuit_place 早退=零注册——R271 verdict 表保真；本类
#     不写 host 计数器）。
# 懒挂层 ProjectileMMLayer：首注册期挂 host 下（R269 聚合 Label「boost 关态永不建」同款
# 懒建先例）——boost 关→逐弹复原 sprite.visible+注销+层自拆；boost 开翻转前已活弹由
# 层首帧追赶扫补注册。本类不声明 class_name（game_loop.gd:3155 同款纪律：新类首次出现
# 须路径直引，防 -s headless 全局类缓存未刷新）。
extends RefCounted

# 单点回退（false=本系统整刀失效——逐弹 Sprite 现状零扰动；测试/回滚口，Enemy.BODY_MM 先例）
static var BODY_MM: bool = true

# sprite 复原面真源：Node2D(弹) -> CanvasItem(本体 _sprite)。只记「本系统藏过」的弹
# （释放/翻转期复原与 QA 诊断读口用；非 host 镜像表镜像——host 侧注销先于本表清理，
# 释亡键由读口 is_instance_valid 跳过、teardown 时统一清）。
static var _hidden: Dictionary = {}
# 注册期快照的宿主（产品面=弹池唯一 TexBucketHost；teardown 注销用。is_instance_valid 守卫）
static var _host_ref: Node = null
# 懒挂层引用（boost 关态恒 null——零节点零成本）
static var _layer: Node = null


# ── 弹侧唯一自报口（_place_in_bucket 尾调用——激活期/变体定档后） ─────────
static func notify_place(p_proj: Node2D, p_body: Sprite2D, p_host: Node) -> void:
	# 门开：册记 + 镜像注册 + 本体让位（sprite 恒隐——仅作 transform/色读源，敌方同款）；
	# 门关：零触碰（未册记过=纯读门零副作用——boost 关侧逐位不变）。曾册记件在门关后
	# 再落桶（池复用跨 boost 翻转）→ 复原 sprite + 注销，幂等。
	if TexBucketHost.shortcircuit_place:          # R271 S1 共门（台架短路期零注册——计数器归 host 不碰）
		return
	if not _eligible(p_host):
		if _hidden.has(p_proj):
			p_body.visible = true
			_hidden.erase(p_proj)
			if p_host != null and p_host.has_method(&"mirror_unregister"):
				p_host.call(&"mirror_unregister", p_proj)
		return
	_hidden[p_proj] = p_body
	_host_ref = p_host
	p_host.call(&"mirror_register", p_proj, p_body, p_body.texture)
	p_body.visible = false                        # 本体绘制让位 MM（拖尾=弹根 _draw 不受影响；叠序翻转为体上——头注披露）
	_ensure_layer(p_host)


static func _eligible(p_host: Node) -> bool:
	# 镜像资格：单点门 × boost 谓词 × host 能力（老测试直连池/桩容错——enemy._mm_eligible 同款）
	if not BODY_MM:
		return false
	if not PerfGovernor.boost_mode():
		return false
	if p_host == null or not p_host.has_method(&"mirror_register"):
		return false
	return true


# ── 翻转治理（ProjectileMMLayer 调——boost 开追赶扫 / boost 关整体拆收） ────
static func catchup_sweep(p_host: Node) -> void:
	# boost 开侧追赶：翻转前已活弹（spawn 早于层创建/上一 boost 会话遗珠）沿桶实扫补注册。
	# 桶=host 子级 Node2D；桶内件=活弹+留桶空闲弹+host 惰建 BodyMM——非弹件（MMI）与
	# is_clean 件（R271 留桶空闲弹：invisible 不绘不断批）逐类跳过，notify_place 同口径注册。
	if TexBucketHost.shortcircuit_place:          # R271 S1 共门（短路期不追赶——verdict 表保真）
		return
	if not _eligible(p_host):
		return
	for b in p_host.get_children():
		if not (b is Node2D):
			continue                              # 本层等非桶件（桶=host 子级 Node2D）
		for child in (b as Node).get_children():
			if child is MultiMeshInstance2D:
				continue                          # host 惰建 BodyMM（桶首位）
			var clean_v: Variant = child.get("is_clean")
			if clean_v == null:
				continue                          # 非弹件（防御桩——弹必带 is_clean 池清洁标记）
			if bool(clean_v):
				continue                          # 留桶空闲件（不绘不断批——不补注册）
			if not (child as CanvasItem).is_visible_in_tree():
				continue                          # 池根待命/隐藏件
			if _hidden.has(child):
				continue                          # 已在册（幂等）
			var body_v: Variant = child.get("_sprite")
			if body_v is Sprite2D and (body_v as Sprite2D).texture != null:
				notify_place(child as Node2D, body_v as Sprite2D, p_host)


static func teardown_mirrors() -> void:
	# boost 关侧整体拆收（幂等；层自拆前的复原口）：逐弹复原 sprite.visible + 镜像注销
	# （含留桶空闲件——池复用跨 boost 关态的首帧可见性正确性）+ 受影响桶即时 resync
	# （R293 修轮2：复原精灵与陈旧 MM visible_instance_count 同帧并绘=一帧双绘——同步
	# 熄灭/重排不待下一 _process 拍；敌弹同桶共用安全）+ 层释放 + 册清。
	var host: Node = _host_ref
	_host_ref = null
	var live_host: bool = host != null and is_instance_valid(host)
	var can_resync: bool = live_host and host.has_method(&"mirror_resync")
	var touched: Array = []               # 拆收涉及桶集（tex 须先于注销取——注销后 tex_of 恒 null）
	if not _hidden.is_empty():
		for proj in _hidden.keys():
			var body: CanvasItem = _hidden[proj]
			if is_instance_valid(proj):
				if can_resync and host.has_method(&"mirror_tex_of"):
					var tex: Variant = host.call(&"mirror_tex_of", proj)
					if tex != null and not touched.has(tex):
						touched.append(tex)
				if is_instance_valid(body):
					body.visible = true
				if live_host and host.has_method(&"mirror_unregister"):
					host.call(&"mirror_unregister", proj)
		_hidden.clear()
	if can_resync:
		for tex in touched:
			host.call(&"mirror_resync", tex)
	if _layer != null and is_instance_valid(_layer):
		_layer.queue_free()
	_layer = null


static func _ensure_layer(p_host: Node) -> void:
	# 懒挂自管理层（R269 聚合 Label 同款）：首注册期挂 host 下；boost 关态本函数不可达
	# （notify_place 门内）=永不建。层职责仅翻转治理+追赶扫——每帧变换/色同步在 host。
	# 层脚本经运行时 load（层 preload 本门面——单向引用防编译期循环 preload；资源
	# 缓存下重复 load 零重编译）。
	if _layer != null and is_instance_valid(_layer):
		return
	if p_host == null or not is_instance_valid(p_host):
		return
	var layer_script: GDScript = load("res://scripts/render/projectile_mm_layer.gd")
	if layer_script == null:
		return
	var layer: Node = layer_script.new()
	layer.name = "ProjMMLayer"
	p_host.add_child(layer)
	_layer = layer


# ── QA/诊断读口（r240 mirror_tex_of/mirror_count 同族；释亡键一律跳过） ─────
static func is_tracked(p_proj: Node2D) -> bool:
	# sprite 复原面在册（曾由本系统藏过 _sprite——与 host 镜像在册是两个口径：
	# release 后本表仍留键直到复用/拆收，host 表即时注销）
	return _hidden.has(p_proj)


static func tracked_count() -> int:
	# 复原面在册活口数（释亡键不计——host trim_free_to 可释放池件）
	var n := 0
	for k in _hidden:
		if is_instance_valid(k):
			n += 1
	return n


static func grouped_counts() -> Dictionary:
	# 分桶实例数读口：键=Vector2i(贴图实例 id, team) → host 镜像在册活口数（桶键含贴图
	# 与 team 的验收口径——同贴图同 team 计一桶；元素染色=贴图键故各元素自然分桶）。
	# 以 host.mirror_tex_of 为在册真源（release/unplace 已注销件不计——留桶空闲弹零计）。
	var out: Dictionary = {}
	var host: Node = _host_ref
	if host == null or not is_instance_valid(host) or not host.has_method(&"mirror_tex_of"):
		return out
	for k in _hidden.keys():
		if not is_instance_valid(k):
			continue
		var tex_v: Variant = host.call(&"mirror_tex_of", k)
		if tex_v == null:
			continue                              # 已注销（release 链——unplace/unplace_lazy）
		var team_v: Variant = (k as Node).get("team")
		var team := int(team_v) if team_v != null else -1
		var key := Vector2i(int((tex_v as Texture).get_instance_id()), team)
		out[key] = int(out.get(key, 0)) + 1
	return out


static func layer_node() -> Node:
	# 结构断言口（boost 关态恒 null——懒建承诺的可观测面）
	return _layer
