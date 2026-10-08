# tests/_tmp_r231_gridbench.gd
# R231 一次性微基准：SpaceGrid.query_circle 玩家弹链热路径成本分解（临时文件，勿入电池）。
# R231 刀A 后改造：真实 query_circle 已无常量字典路径——旧读路径以手写复刻臂保留，
# 全部四臂同进程交替实测（对消跨进程机器噪声——探针跨进程墙钟噪声 ±30% 实测）。
#   A_old：刀A 前 query_circle 逐行复刻（_radii Dictionary 取值 + _pos_of live 读）；
#   B_newlive：真实 query_circle（刀A 后 live 口径：常量半径、无字典、快照解析实体）；
#   C_replica：快照读手写复刻（int 桶 + 快照位置数组直读）；
#   D_real：真实 query_circle_snap（AC-P2 ≤6.0µs 验收臂）。
# 另测 rebuild 双口径（AC-P3 ≤+0.15ms 验收）：old_replica（_radii 字典全量重插）vs
# 真实 rebuild（快照两数组同步 append）。
# 场景：420 查询×60 帧×120 敌半聚团，Q_RADIUS=40（2026-10-03 三臂基线同参——
# 当时读数 A=25.4µs B=9.1µs C=4.9µs）。
extends SceneTree

const N_ENEMIES := 120
const N_PROJ := 420
const ITER := 60          # ~1 秒 @60fps 的查询量
const Q_RADIUS := 40.0    # 玩家弹典型 effective_radius


func _initialize() -> void:
	var root := get_root()
	# 敌人替身：真实路径=树内 Node2D（_pos_of 走 global_position）
	var enemies: Array[Node2D] = []
	for i in range(N_ENEMIES):
		var e := Node2D.new()
		if i < N_ENEMIES / 2:
			e.position = Vector2(100.0 + randf() * 520.0, 200.0 + randf() * 900.0)
		else:
			# 深载聚团：半数敌挤在 300×300 波团里
			e.position = Vector2(210.0 + randf() * 300.0, 500.0 + randf() * 300.0)
		root.add_child(e)
		enemies.append(e)

	var grid := SpaceGrid.new()
	grid.configure(Vector2(720.0, 1280.0), 192.0, 64.0)
	grid.rebuild(enemies)

	# 查询点：420 弹位（战斗带内随机）+ 预生成避免入计时
	var qpos: Array[Vector2] = []
	for i in range(N_PROJ):
		qpos.append(Vector2(randf() * 720.0, randf() * 1280.0))

	# 旧读路径复刻夹具（A 臂）：Node2D 桶 + _radii 字典（与刀A 前 rebuild 产物同构）
	var old_buckets: Array[Array] = []
	for b in grid._buckets:
		var nb: Array = []
		for idx_i in b:
			nb.append(grid._snap_items[idx_i])
		old_buckets.append(nb)
	var old_radii: Dictionary = {}
	for e in enemies:
		old_radii[e] = 64.0
	var cell_size := 128.0
	var origin := Vector2(-192.0, -192.0)
	var cols := 9
	var rows := 13

	# C 臂复刻夹具：int 桶 + 快照位置数组
	var snap_idx_buckets: Array[Array] = []
	for bi in range(grid._buckets.size()):
		var ib: Array = []
		for idx_i in grid._buckets[bi]:
			ib.append(idx_i)
		snap_idx_buckets.append(ib)
	var snap_pos: Array[Vector2] = []
	for e in enemies:
		snap_pos.append(e.position)

	var t0 := 0
	var sink := 0                            # 防死代码消除的累计器

	# 预热一轮（页/分支缓存）
	for w in range(3):
		for i in range(N_PROJ):
			sink += grid.query_circle_snap(qpos[i], Q_RADIUS).size()

	# 臂 A：刀A 前 query_circle 逐行复刻（_radii.get + _pos_of live 读）
	t0 = Time.get_ticks_usec()
	for it in range(ITER):
		for i in range(N_PROJ):
			var pos := qpos[i]
			var c0 := clampi(int((pos.x - Q_RADIUS - 64.0 - origin.x) / cell_size), 0, cols - 1)
			var c1 := clampi(int((pos.x + Q_RADIUS + 64.0 - origin.x) / cell_size), 0, cols - 1)
			var r0 := clampi(int((pos.y - Q_RADIUS - 64.0 - origin.y) / cell_size), 0, rows - 1)
			var r1 := clampi(int((pos.y + Q_RADIUS + 64.0 - origin.y) / cell_size), 0, rows - 1)
			for row in range(r0, r1 + 1):
				var row_base := row * cols
				for col in range(c0, c1 + 1):
					for cand in old_buckets[row_base + col]:
						var c: Node2D = cand
						var rc := float(old_radii.get(c, 0.0))
						var reach := Q_RADIUS + rc
						var cp: Vector2 = c.global_position if c.is_inside_tree() else c.position
						if cp.distance_squared_to(pos) <= reach * reach:
							sink += 1
	var a_us := float(Time.get_ticks_usec() - t0) / float(ITER)

	# 臂 B：真实 query_circle（刀A 后 live 口径）
	t0 = Time.get_ticks_usec()
	for it in range(ITER):
		for i in range(N_PROJ):
			var res := grid.query_circle(qpos[i], Q_RADIUS)
			sink += res.size()
	var b_us := float(Time.get_ticks_usec() - t0) / float(ITER)

	# 臂 C：快照读手写复刻（int 桶 + 快照位置直读）
	t0 = Time.get_ticks_usec()
	for it in range(ITER):
		for i in range(N_PROJ):
			var pos := qpos[i]
			var reach := Q_RADIUS + 64.0
			var c0 := clampi(int((pos.x - reach - origin.x) / cell_size), 0, cols - 1)
			var c1 := clampi(int((pos.x + reach - origin.x) / cell_size), 0, cols - 1)
			var r0 := clampi(int((pos.y - reach - origin.y) / cell_size), 0, rows - 1)
			var r1 := clampi(int((pos.y + reach - origin.y) / cell_size), 0, rows - 1)
			for row in range(r0, r1 + 1):
				var row_base := row * cols
				for col in range(c0, c1 + 1):
					for idxi in snap_idx_buckets[row_base + col]:
						var cp := snap_pos[idxi]
						if cp.distance_squared_to(pos) <= reach * reach:
							sink += 1
	var c_us := float(Time.get_ticks_usec() - t0) / float(ITER)

	# 臂 D：真实 query_circle_snap（AC-P2 验收臂）
	t0 = Time.get_ticks_usec()
	for it in range(ITER):
		for i in range(N_PROJ):
			var res := grid.query_circle_snap(qpos[i], Q_RADIUS)
			sink += res.size()
	var d_us := float(Time.get_ticks_usec() - t0) / float(ITER)

	# rebuild 双口径（AC-P3）：真实 rebuild vs 旧口径复刻（清字典 + 全量重插）
	var items := enemies
	t0 = Time.get_ticks_usec()
	for it in range(ITER):
		grid.rebuild(items)
	var rn_us := float(Time.get_ticks_usec() - t0) / float(ITER)
	t0 = Time.get_ticks_usec()
	for it in range(ITER):
		# 旧 rebuild 复刻：清字典/桶 + 逐个 _cell_index+_pos_of+字典写+桶 append
		for b in old_buckets:
			b.clear()
		old_radii.clear()
		for e in items:
			var ep: Vector2 = e.global_position if e.is_inside_tree() else e.position
			var cc := clampi(int((ep.x - origin.x) / cell_size), 0, cols - 1)
			var rr := clampi(int((ep.y - origin.y) / cell_size), 0, rows - 1)
			old_buckets[rr * cols + cc].append(e)
			old_radii[e] = 64.0
	var ro_us := float(Time.get_ticks_usec() - t0) / float(ITER)

	print("R231GRID per_query_us A_old=%.1f B_newlive=%.1f C_replica=%.1f D_real=%.1f  (N_PROJ=%d ITER=%d enemies=%d sink=%d)"
		% [a_us / float(N_PROJ), b_us / float(N_PROJ), c_us / float(N_PROJ), d_us / float(N_PROJ), N_PROJ, ITER, N_ENEMIES, sink])
	print("R231GRID per_frame_ms A_old=%.2f B_newlive=%.2f C_replica=%.2f D_real=%.2f"
		% [a_us / 1000.0, b_us / 1000.0, c_us / 1000.0, d_us / 1000.0])
	print("R231GRID rebuild_ms old_replica=%.3f new_real=%.3f delta=%.3f (per call, n=%d)"
		% [ro_us / 1000.0, rn_us / 1000.0, (rn_us - ro_us) / 1000.0, ITER])
	quit(0)
