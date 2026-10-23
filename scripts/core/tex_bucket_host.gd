# scripts/core/tex_bucket_host.gd
# R214 E' 树序分桶合批 host（vc21 定案：dc 与 fps 强负相关——dc≤400 才能稳 90-120fps；
# 满载 dc 700-1000 的大头=敌本体×120+弹×百发，贴图按 kind/阵营共享但池化树序随机交错
# 把 2D 批处理打碎，R212 素材②已点名弹侧阵营混排断批）。
# 做法：按渲染贴图（Texture2D 引用为键）把池化实体 reparent 进同贴图桶（桶=本节点
# 子级 Node2D，原点无变换——local position 语义恒等）。同贴图实体树序相邻 →
# gl_compatibility 2D 批处理自动合并（敌 120 item → 每 kind ≈1 批、弹百发 → 每
# 变体 ≈1 批）。桶内敌容器间的非渲染子件（Area2D/隐形 TelegraphCircle）不断批；
# 少数挂件（皇冠/余烬/卫星，非满载态 0 局本就稀少）会造成桶内少量断批——仍远优于
# 全交错。代价：桶间覆盖序=**首次遭遇序**（桶惰性建，创建序即渲染序——boss/精英桶
# 天然排多数杂兵桶之后，即任何 boss 盖任何杂兵；跨局可能翻转）；桶内序=place 序
# （同 z 重叠处叠放与出生序不同，读感无影响）；spawn/release 各一次 reparent（µs 级
# ×8/帧节流可忽略）。真机若见异常遮挡先查桶序。
# 生命周期：place=实体激活/贴图变化时自报（enemy._sync_visual 尾/弹 _apply_visual_
# variant 尾——换贴图自动换桶）；unplace=ObjectPool.release 开头统一归位池根。
# bucket_host 为 null 的池/实体（老测试直连池）零行为变化。
#
# ── R240 敌本体 MultiMesh 镜像（渲染轴 F1 敌域第二刀）──────────────────────────
# R237 渲染轴归因定案：战斗 dc 增量的 83-123% 在敌桶本体域（F1 边际 190-437dc，
# 120 敌展开 485-487 可见件），机理=本体贴图分桶后仍被「染色组合分组（组N 3-8）×
# 入场渐显 α 档×桶内瞬态件（施法扇等）交错」打碎成 ~0.4-0.9dc/件——闪白换桶刀
# （vc41）真机无可感收益实证断批主源不在闪白单点。本刀=把**本体绘制**从逐敌
# Sprite2D canvas item 改为**按贴图 MultiMesh 镜像**（每贴图 1 个
# MultiMeshInstance2D=恒 1 draw；逐实例 transform+color，实例色天然承载染色/渐显
# ——组色差异不再断批）。弹桶 540-694 件→0-3dc 已实证本路径上限。
# 结构：敌根仍 reparent 进桶（桶序语义零变化——瞬态件/装饰件树序渲染不动），仅
# `_sprite.visible=false` + 注册进镜像表；mm 节点挂桶**首位**（move_child 0）→
# 桶内本体层恒在瞬态件之下（施法指示器可读性口径——原实现后生敌盖先出指示器，
# 现为指示器恒在上，披露见 R240 报告）。每帧 _process 同步活敌 transform
# （owner.global×body.local——量化游标写点不变零读改）+合成色（root.modulate
# [渐显α]×modulate[恒白]×self_modulate[R217 量化染色]）。
# 注册/注销：实体 place 尾自报（贴图变化自动换 mm 键——变脸/闪白换桶同款）；
# unplace 统一注销。排除面（boss*/elite/bastion 与 FLASH_TEX=false——实例色 8-bit
# 钳位承载不了 >1 白乘）由敌侧 _mm_eligible 决定，本类只提供能力。门：
# Enemy.BODY_MM 单点回退（false=逐敌 Sprite 现状零扰动）。
class_name TexBucketHost
extends Node

var _buckets: Dictionary = {}                   # Texture2D -> Node2D（惰性建）
var _home: Node = null                          # 归位目标（宿主池根）

# ── R271 台架短路注入口（设计 §3.2 短路臂——仅测试态可达，产品默认零短路；──────
# trail_halffreq_override〔projectile_base.gd:51〕同款先例：static 面 + 默认值=现状。
# S1 桶周转：place/unplace 早退（弹保持池根不动——树进出/桶链面短路）；
# S7 桶宿主同步：_process 变换/颜色同步环早退（MM 每帧同步 idle 成本面短路）。
# 计数器仅供台架断言「注入生效」（短路分支内自增——零短路时零成本）。
static var shortcircuit_place: bool = false
static var shortcircuit_sync: bool = false
static var place_skip_count: int = 0
static var sync_skip_count: int = 0

# ── R240 镜像态 ──
var _mm_meshes: Dictionary = {}                 # Texture2D -> MultiMeshInstance2D（惰性建，挂桶首位）
var _mm_lists: Dictionary = {}                  # Texture2D -> Array[Node2D]（owner 列表，序=place 序=实例序）
var _mm_owner_tex: Dictionary = {}              # Node2D -> Texture2D（注销/换键 O(1)）
var _mm_owner_body: Dictionary = {}             # Node2D -> CanvasItem（transform/色读源，注册期存储）


func setup(p_home: Node) -> void:
	_home = p_home


func _bucket_for(p_tex: Texture2D) -> Node2D:
	if not _buckets.has(p_tex):
		var b := Node2D.new()
		b.name = "TexBucket%d" % _buckets.size()
		add_child(b)
		_buckets[p_tex] = b
	return _buckets[p_tex]


func place(p_node: Node2D, p_tex: Texture2D) -> void:
	# 贴图桶落位（已在目标桶则零操作；换贴图实体自动换桶——boss 怒相变脸等）
	if shortcircuit_place:                  # R271 S1：台架短路（默认 false=零短路零成本）
		place_skip_count += 1
		return
	DebugStats.bucket_begin(&"bucket")     # R269：桶µs（place=含 reparent+MM 注册的落位 µs——只加计时不改行为）
	if p_tex == null or _home == null or not is_instance_valid(p_node):
		DebugStats.bucket_end(&"bucket")
		return
	var b := _bucket_for(p_tex)
	if p_node.get_parent() != b:
		p_node.reparent(b)
	DebugStats.bucket_end(&"bucket")


func unplace(p_node: Node2D) -> void:
	# 池归还前归位（桶下 → 池根；池根下零操作）。R240：镜像同步注销（防桶外残留实例）
	if shortcircuit_place:                  # R271 S1：台架短路（与 place 同门——归位链一并短路）
		place_skip_count += 1
		return
	DebugStats.bucket_begin(&"bucket")     # R269：桶µs（unplace=归位+镜像注销 µs）
	if _home == null or not is_instance_valid(p_node):
		DebugStats.bucket_end(&"bucket")
		return
	mirror_unregister(p_node)
	if p_node.get_parent() != _home and is_ancestor_of(p_node):
		p_node.reparent(_home)
	DebugStats.bucket_end(&"bucket")


func unplace_lazy(p_node: Node2D) -> void:
	# R271 V-C1（verdict 坐实池周转链→§3.3 刀 C1，boost 门内默认）：弹 release 惰性归位——
	# 仅镜像注销（防幽灵实例绘制），**不 reparent 回池根**：空闲弹留桶下 invisible（不绘
	# 不断批），同变体 acquire 复用时 place() 的「已在目标桶零操作」既有语义承接零
	# reparent；变体变更 place() 自然换桶（桶语义零变化）。boost 关侧走 unplace() 现状
	# 逐位（ObjectPool.release 按 PerfGovernor.boost_mode() 单谓词门分派）。
	# 台架交互：S1 短路门与本口同门（shortcircuit_place 早退——短路臂测的桶链全量面）。
	if shortcircuit_place:                  # R271 S1：台架短路（与 unplace 同门）
		place_skip_count += 1
		return
	DebugStats.bucket_begin(&"bucket")     # R269：桶µs 口径不变（归位面 µs——本口零 reparent）
	if _home == null or not is_instance_valid(p_node):
		DebugStats.bucket_end(&"bucket")
		return
	mirror_unregister(p_node)
	DebugStats.bucket_end(&"bucket")


# ═══ R240 敌本体 MultiMesh 镜像 ═══════════════════════════════════════

func mirror_register(p_owner: Node2D, p_body: CanvasItem, p_tex: Texture2D) -> void:
	# 本体镜像注册（place 尾自报——同键幂等；换贴图自动换键）。p_body 只作 transform/
	# 色读源（敌侧已 visible=false，不进渲染树语义）。
	if p_tex == null or not is_instance_valid(p_owner) or not is_instance_valid(p_body):
		return
	var prev: Variant = _mm_owner_tex.get(p_owner)
	if prev != null:
		if prev == p_tex:
			return                       # 同键幂等（续闪/重复 place）
		mirror_unregister(p_owner)       # 换键（变脸/闪白换桶同款语义）
	if not _mm_meshes.has(p_tex):
		_mm_meshes[p_tex] = _build_mm(p_tex)
		_mm_lists[p_tex] = []
	(_mm_lists[p_tex] as Array).append(p_owner)
	_mm_owner_tex[p_owner] = p_tex
	_mm_owner_body[p_owner] = p_body


func mirror_unregister(p_owner: Node2D) -> void:
	if not _mm_owner_tex.has(p_owner):
		return
	var tex: Texture2D = _mm_owner_tex[p_owner]
	_mm_owner_tex.erase(p_owner)
	_mm_owner_body.erase(p_owner)
	var lst: Array = _mm_lists.get(tex)
	if lst != null:
		lst.erase(p_owner)               # O(n) n=桶内敌数（≤120）——release 一次可忽略


func mirror_tex_of(p_owner: Node2D) -> Texture2D:
	# 测试/诊断读口（未注册返 null）
	return _mm_owner_tex.get(p_owner)


func mirror_count() -> int:
	var n := 0
	for tex in _mm_lists:
		n += (_mm_lists[tex] as Array).size()
	return n


func mirror_resync(p_tex: Texture2D) -> void:
	# R293 拆收期同步口：批量 mirror_unregister 后立即调——受影响桶的 MM 变换表/
	# visible_instance_count 即刻与册对齐（不待下一 _process 拍）。teardown 同帧复原
	# sprite.visible 场景防「复原精灵 + 陈旧 MM 实例」一帧双绘（QA-R293 修轮2 定罪）。
	# 敌弹同桶共用时重排亦安全（同步体=全量重建非增量）；S7 短路期共门零写（verdict 保真）。
	if shortcircuit_sync:
		return
	if p_tex == null or not _mm_meshes.has(p_tex) or not _mm_lists.has(p_tex):
		return
	if _sync_bucket(p_tex):
		_compact_lists()


func _build_mm(p_tex: Texture2D) -> MultiMeshInstance2D:
	var b := _bucket_for(p_tex)
	var mmi := MultiMeshInstance2D.new()
	mmi.name = "BodyMM"
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true                  # 实例色=染色/渐显载体（须先于 instance_count 建）
	mm.mesh = _quad_mesh_uv_up(p_tex)     # ⚠mesh 挂 MultiMesh（非实例）——canvas/RD 双路径
	                                     # 硬要求（缺 mesh=_render_batch mesh.is_null 拒绘）。
	                                     # 评审 R240-B1：QuadMesh 的 UV v=0 在底（GL 惯例），
	                                     # 2D canvas 渲染相对 Sprite2D 垂直翻转（敌人全部倒置，
	                                     # 双渲染器像素对拍实证）——自建 ArrayMesh 给 UV-up
	                                     # 取向（v=0 在上=Sprite2D 等价），mesh 侧翻 UV 最稳
	                                     # （实例变换补 Y 翻转会与拉伸/旋转复合出错向）
	mm.custom_aabb = AABB(Vector3(-1e7, -1e7, -1.0), Vector3(2e7, 2e7, 2.0))   # 实例散布全场——禁网格 aabb 误剔除
	mm.instance_count = 0
	mmi.multimesh = mm
	mmi.texture = p_tex                   # 2D 路径 albedo 绑定（mmprobe6 实证双渲染器可绘）
	b.add_child(mmi)
	b.move_child(mmi, 0)                  # 桶首位=本体层在瞬态件（施法扇/爆环）之下
	return mmi


static func _quad_mesh_uv_up(p_tex: Texture2D) -> ArrayMesh:
	# R240-B1 翻转修复体：XY 平面 quad，UV-up 取向（v=0 顶行=图片顶部）= Sprite2D
	# 渲染等价（QuadMesh 的 v=0 在底→2D canvas 渲染垂直镜像）。中心在原点、像素 1:1
	# （centered 语义）；canvas 渲染无背面剔除，绕序两向均可绘。
	var hw := float(p_tex.get_width()) * 0.5
	var hh := float(p_tex.get_height()) * 0.5
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-hw, -hh, 0.0), Vector3(hw, -hh, 0.0),
		Vector3(hw, hh, 0.0), Vector3(-hw, hh, 0.0)])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(1.0, 0.0),
		Vector2(1.0, 1.0), Vector2(0.0, 1.0)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return am


func _process(_delta: float) -> void:
	if shortcircuit_sync:                   # R271 S7：台架短路（变换/颜色同步环早退——脏标门注入面）
		sync_skip_count += 1
		return
	if _mm_meshes.is_empty():
		return                         # 无 mm（注册表空亦含）——但建过 mm 必须进循环
	                                   # 熄灭空桶（早退会留幽灵实例：vis 默认 -1=全绘）
	var has_dead := false
	for tex in _mm_lists:
		if _sync_bucket(tex):
			has_dead = true
	if has_dead:
		_compact_lists()


func _sync_bucket(p_tex: Texture2D) -> bool:
	# 单桶同步体（_process 每帧环抽体——R293 mirror_resync 复用；返回桶内是否见释亡
	# 实例——帧尾 _compact_lists 门同原）。
	var lst: Array = _mm_lists[p_tex]
	var mm: MultiMesh = (_mm_meshes[p_tex] as MultiMeshInstance2D).multimesh
	if lst.is_empty():
		if mm.visible_instance_count != 0:
			mm.visible_instance_count = 0   # 清空桶须熄灭（跳过会留幽灵实例绘制）
		return false
	var n := 0
	var has_dead := false
	for i in range(lst.size()):
		var owner = lst[i]            # QA-R240-001：勿类型化——freed 实例类型化赋值即
		                             # 运行时报错（先于下一行判亡），去类型化后 is_instance_valid 可达
		if not is_instance_valid(owner):
			has_dead = true           # 释亡实例——帧尾清理（防表膨胀）
			continue
		if not (owner as Node2D).is_visible_in_tree():
			continue
		var body: CanvasItem = _mm_owner_body.get(owner)
		if body == null or not is_instance_valid(body):
			continue
		if n >= mm.instance_count:
			mm.instance_count = n + 16   # 容量阶梯增长（realloc 罕见）
		mm.set_instance_transform_2d(n, owner.global_transform * body.transform)
		mm.set_instance_color(n, owner.modulate * body.modulate * body.self_modulate)
		n += 1
	mm.visible_instance_count = n
	return has_dead


func _compact_lists() -> void:
	for tex in _mm_lists:
		var lst: Array = _mm_lists[tex]
		for i in range(lst.size() - 1, -1, -1):
			var o = lst[i]                # QA-R240-001 同款：去类型化（freed 赋值先于判亡自坏）
			if not is_instance_valid(o):
				lst.remove_at(i)
				_mm_owner_tex.erase(o)
				_mm_owner_body.erase(o)
