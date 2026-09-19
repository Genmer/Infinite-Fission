# tools/gen_music.gd
# R75 场景自适应音乐 · 离线作曲器（一次性 -s 运行，产物 .res 提交入库）：
#   ../tools/Godot_v4.3-stable_win64.exe --headless --path . -s tools/gen_music.gd
# 六轨全部 16.000s @22050Hz 单声道 LOOP_FORWARD —— 等长锁相（pad/贝斯/琶音/踩镲/战鼓
# 同帧起播自然对齐；大厅轨独立成曲）。作曲规格真源见各 _compose_* 头注。
# 生成后 sfx_bank 经 load("res://assets/music/<名>.res") 消费——boot 零合成开销，
# 曲目复杂度不受启动预算约束（P2 版实时合成的上限即在于此）。
extends SceneTree

const RATE := 22050
const LOOP_S := 16.0
const N := int(RATE * LOOP_S)              # 352800
const STEP := 0.125                        # 16 分 @120BPM；和弦 4s = 32 步；全曲 128 步
const OUT_DIR := "res://assets/music"

# ── 音色件（纯函数合成） ────────────────────────────────────────────

static func _warm(p_phase: float) -> float:
	# 暖音色：基频 + 0.35×二次 + 0.12×三次（P2 pad 同源配方）
	return sin(p_phase) + 0.35 * sin(2.0 * p_phase) + 0.12 * sin(3.0 * p_phase)


static func _pluck(p_phase: float) -> float:
	# 拨弦：基频 + 0.22×二次 + 0.10×四次（奇偶混合的亮拨音）
	return sin(p_phase) + 0.22 * sin(2.0 * p_phase) + 0.10 * sin(4.0 * p_phase)


static func _tri(p_phase: float) -> float:
	# 近三角：基频 + 0.18×三次 + 0.06×五次（ odd 谐波 = 圆润）
	return sin(p_phase) + 0.18 * sin(3.0 * p_phase) + 0.06 * sin(5.0 * p_phase)


static func _hash_noise(p_i: int) -> float:
	# 确定性白噪（可复现生成——同机同曲）
	var h := (p_i * 2654435761) % 4294967296
	h = (h ^ (h >> 13)) % 4294967296
	return float(h % 20000) / 10000.0 - 1.0


func _add_note(p_buf: PackedFloat32Array, p_start_s: float, p_dur: float,
		p_freq: float, p_vel: float, p_timbre: Callable, p_decay: float,
		p_attack := 0.006, p_echo: Array = []) -> void:
	# 单音渲染：attack/指数衰减包络 × 音色；p_echo = [延迟秒, 增益]（单 tap 回声）
	# 循环点护栏：音尾（含回声 tap）压回 15.95s 内——包络自然衰减，无截断爆音
	var dur := p_dur
	if p_start_s + p_dur > LOOP_S - 0.05:
		dur = maxf(LOOP_S - 0.05 - p_start_s, 0.05)
	var n0 := int(p_start_s * RATE)
	var nn := int(dur * RATE)
	var phase := 0.0
	var inc := TAU * p_freq / float(RATE)
	for i in range(nn):
		var idx := n0 + i
		if idx >= N:
			break
		var t := float(i) / float(RATE)
		var env := (t / p_attack if t < p_attack else 1.0) * exp(-t / p_decay)
		p_buf[idx] += p_vel * env * float(p_timbre.call(phase))
		phase += inc
	# 回声 tap（不移相位，独立渲染衰减拷贝）
	if not p_echo.is_empty():
		var delay_s := float(p_echo[0])
		var gain := float(p_echo[1])
		var e0 := n0 + int(delay_s * RATE)
		for i in range(nn):
			var idx := e0 + i
			if idx >= N:
				break
			var t := float(i) / float(RATE)
			var env := (t / p_attack if t < p_attack else 1.0) * exp(-t / p_decay)
			p_buf[idx] += p_vel * gain * env * float(p_timbre.call(p_freq * (t + delay_s) * TAU))


func _add_noise_hit(p_buf: PackedFloat32Array, p_start_s: float, p_dur: float,
		p_vel: float, p_decay: float, p_seed: int, p_ring_hz := 0.0) -> void:
	# 打击噪声件：白噪指数衰减（+ 可选金属感 ring 正弦）
	var n0 := int(p_start_s * RATE)
	var nn := int(p_dur * RATE)
	for i in range(nn):
		var idx := n0 + i
		if idx >= N:
			break
		var t := float(i) / float(RATE)
		var env := exp(-t / p_decay)
		var s := _hash_noise(p_seed + i * 7) * env
		if p_ring_hz > 0.0:
			s += 0.4 * env * sin(TAU * p_ring_hz * t)
		p_buf[idx] += p_vel * s


func _add_kick(p_buf: PackedFloat32Array, p_start_s: float, p_vel: float) -> void:
	# 底鼓：150→45Hz 滑频 0.09s + 3ms 噪声 click
	var n0 := int(p_start_s * RATE)
	var nn := int(0.11 * RATE)
	var phase := 0.0
	for i in range(nn):
		var idx := n0 + i
		if idx >= N:
			break
		var t := float(i) / float(RATE)
		var f := lerpf(150.0, 45.0, clampf(t / 0.09, 0.0, 1.0))
		phase += TAU * f / float(RATE)
		var env := exp(-t / 0.055)
		var s := sin(phase) * env
		if t < 0.003:
			s += 0.5 * _hash_noise(9000 + i) * (1.0 - t / 0.003)
		p_buf[idx] += p_vel * s


# ── 各轨作曲 ───────────────────────────────────────────────────────

func _compose_menu() -> PackedFloat32Array:
	# 大厅曲（76BPM 体感 · 稀疏事件 + 华彩和声）：Cmaj7→Am7→Fmaj7→G6，
	# 双失谐暖 pad（每和弦 0.8s 起/收）+ 慢五声拨弦（每和弦 5 粒，回声 0.375s）
	# + 低八度 sub 根音。安静、开阔、无鼓。
	var buf := PackedFloat32Array()
	buf.resize(N)
	var chords: Array[Array] = [
		[130.81, 164.81, 196.00, 246.94],   # Cmaj7：C3 E3 G3 B3
		[110.00, 130.81, 164.81, 196.00],   # Am7：A2 C3 E3 G3
		[87.31, 110.00, 130.81, 164.81],    # Fmaj7：F2 A2 C3 E3
		[98.00, 123.47, 146.83, 164.81],    # G6：G2 B2 D3 E3
	]
	var subs: Array[float] = [65.41, 55.00, 43.65, 49.00]
	var pents: Array[float] = [261.63, 293.66, 329.63, 392.00, 440.00, 523.25, 587.33, 659.26]
	var pluck_steps := [[0, 6, 12, 20, 26], [2, 8, 14, 22, 28], [0, 4, 10, 18, 24, 30], [6, 12, 18, 24]]
	for ci in range(4):
		var c0 := float(ci) * 4.0
		# pad：双失谐（±0.12%）同 env；和弦边界归零（循环无缝）
		var det := 1.0012
		for k in range(2):
			var detune := det if k == 0 else 2.0 - det
			for f in chords[ci]:
				_add_swell_note(buf, c0, 4.0, f * detune, 0.055, _warm, 0.8)
		# sub 根音（-1 八度，正弦，更慢起收）
		_add_swell_note(buf, c0, 4.0, subs[ci], 0.09, func(ph: float) -> float: return sin(ph), 1.1)
		# 五声拨弦：轮廓随和弦走向（低→高→回），粒间留白（76BPM 呼吸）
		var contour := [0, 2, 4, 3, 1, 5, 2, 4] if ci % 2 == 0 else [4, 5, 3, 2, 4, 1, 0, 2]
		var steps: Array = pluck_steps[ci]
		for si in range(steps.size()):
			var deg: int = contour[si % contour.size()] + (2 if ci == 3 else 0)
			var f: float = pents[clampi(deg, 0, pents.size() - 1)]
			var vel := 0.30 + 0.06 * float(si % 3)
			_add_note(buf, c0 + float(steps[si]) * STEP, 1.4, f, vel, _pluck,
				0.5, 0.008, [0.375, 0.35])
	return buf


func _add_swell_note(p_buf: PackedFloat32Array, p_start_s: float, p_dur: float,
		p_freq: float, p_vel: float, p_timbre: Callable, p_edge: float) -> void:
	# 长音：attack/release 线性斜坡（p_edge 秒），首尾归零——pad/静音和弦专用
	var n0 := int(p_start_s * RATE)
	var nn := int(p_dur * RATE)
	var phase := 0.0
	var inc := TAU * p_freq / float(RATE)
	var na := int(p_edge * RATE)
	for i in range(nn):
		var idx := n0 + i
		if idx >= N:
			break
		var t := float(i) / float(RATE)
		var env := 1.0
		if i < na:
			env = float(i) / float(na)
		elif i > nn - na:
			env = float(nn - i) / float(na)
		# 轻微颤音（pad 活体感）
		var vib := 1.0 + 0.004 * sin(TAU * 0.7 * t)
		p_buf[idx] += p_vel * env * float(p_timbre.call(phase * vib))
		phase += inc


func _compose_pad() -> PackedFloat32Array:
	# 战斗和声床（P2 pad 升级）：C-G-Am-F 暖 pad（原配方）+ 8 分轻脉冲（呼吸律动）
	var buf := PackedFloat32Array()
	buf.resize(N)
	var chords: Array[Array] = [
		[130.81, 196.00, 261.63, 329.63],
		[98.00, 196.00, 246.94, 293.66],
		[110.00, 220.00, 261.63, 329.63],
		[87.31, 174.61, 220.00, 261.63],
	]
	for ci in range(4):
		var c0 := float(ci) * 4.0
		for f in chords[ci]:
			_add_pulse_note(buf, c0, 4.0, f, 0.10, _warm, 0.5, 0.06)
	return buf


func _add_pulse_note(p_buf: PackedFloat32Array, p_start_s: float, p_dur: float,
		p_freq: float, p_vel: float, p_timbre: Callable, p_edge: float, p_pulse_depth: float) -> void:
	# pad + 8 分幅度脉冲（0.25s 周期，脉冲包络 60ms）——和声床带轻微心跳律动
	var n0 := int(p_start_s * RATE)
	var nn := int(p_dur * RATE)
	var phase := 0.0
	var inc := TAU * p_freq / float(RATE)
	var na := int(p_edge * RATE)
	var pulse_period := 0.25 * float(RATE)
	var pulse_len := 0.06 * float(RATE)
	for i in range(nn):
		var idx := n0 + i
		if idx >= N:
			break
		var env := 1.0
		if i < na:
			env = float(i) / float(na)
		elif i > nn - na:
			env = float(nn - i) / float(na)
		var pi := i % int(pulse_period)
		var pulse := 1.0 + p_pulse_depth * (exp(-float(pi) / pulse_len) if pi < pulse_len * 3.0 else 0.0)
		p_buf[idx] += p_vel * env * pulse * float(p_timbre.call(phase))
		phase += inc


func _compose_bass() -> PackedFloat32Array:
	# 战斗贝斯（8 分律动）：每和弦 16 槽（0.25s/槽）走 R-R-5-R / R-5-R-O groove，
	# 重拍重、弱拍轻（vel 1.0/0.55 交替）——根音驱动 + 五度/八度点缀
	var buf := PackedFloat32Array()
	buf.resize(N)
	var roots: Array[float] = [65.41, 49.00, 55.00, 43.65]
	var fifths: Array[float] = [98.00, 73.42, 82.41, 65.41]
	var octaves: Array[float] = [130.81, 98.00, 110.00, 87.31]
	# [槽, 音区 0=R 1=5th 2=8ve, vel]
	var pattern: Array[Array] = [
		[0, 0, 1.0], [2, 0, 0.55], [4, 1, 0.75], [6, 0, 0.55],
		[8, 0, 1.0], [10, 0, 0.55], [12, 1, 0.75], [13, 2, 0.6], [14, 0, 0.8],
	]
	for ci in range(4):
		var c0 := float(ci) * 4.0
		for ev in pattern:
			var slot := int(ev[0])
			var f: float = roots[ci] if int(ev[1]) == 0 else (fifths[ci] if int(ev[1]) == 1 else octaves[ci])
			_add_note(buf, c0 + float(slot) * 0.25, 0.24, f, 0.5 * float(ev[2]),
				func(ph: float) -> float: return sin(ph) + 0.30 * sin(2.0 * ph),
				0.13, 0.004)
	return buf


func _compose_arp() -> PackedFloat32Array:
	# 战斗琶音（16 分五声拨弦）：C 大调五声跨两八度，四组和弦各一条固定轮廓
	# （旋律化而非机械上下行），偶数步为主 + 每和弦 2 处 16 分连续进；回声 0.25s
	var buf := PackedFloat32Array()
	buf.resize(N)
	var scale: Array[float] = [523.25, 587.33, 659.26, 783.99, 880.00, 1046.50, 1174.66, 1318.51]
	# 每和弦 32 步的音级轮廓（-1 = 休止）；accent=奇数位轻
	var contours: Array[Array] = [
		[0, -1, 2, -1, 4, -1, 2, 3, 5, -1, 4, -1, 2, 3, 4, -1,
		 5, -1, 6, -1, 5, 4, -1, 2, 4, -1, 3, -1, 2, -1, 1, -1],
		[2, -1, 4, -1, 5, -1, 6, -1, 5, 4, -1, 2, 4, -1, 5, -1,
		 6, -1, 5, -1, 4, -1, 2, 1, 2, -1, 4, -1, 5, -1, 6, -1],
		[4, -1, 3, -1, 2, -1, 4, -1, 5, -1, 4, 2, 3, -1, 2, -1,
		 1, -1, 2, -1, 4, -1, 5, 6, 5, -1, 4, -1, 2, 3, 4, -1],
		[5, 4, -1, 2, 4, -1, 5, -1, 7, -1, 6, -1, 5, -1, 4, 5,
		 6, -1, 5, -1, 4, -1, 2, -1, 4, 5, 6, -1, 7, -1, 5, -1],
	]
	for ci in range(4):
		var c0 := float(ci) * 4.0
		var contour: Array = contours[ci]
		for s in range(32):
			var deg: int = contour[s]
			if deg < 0:
				continue
			var f: float = scale[clampi(deg, 0, scale.size() - 1)]
			var vel := 0.26 + (0.07 if s % 8 == 0 else 0.0) - (0.06 if s % 4 == 2 else 0.0)
			_add_note(buf, c0 + float(s) * STEP, 0.30, f, vel, _tri,
				0.11, 0.004, [0.25, 0.30])
	return buf


func _compose_hats() -> PackedFloat32Array:
	# 踩镲（8 分）：闭镲 0.05s 衰减每 0.5s，反拍 accent ×1.3；
	# 每和弦末（step 28）开镲 0.35s 衰减——段落换气读感
	var buf := PackedFloat32Array()
	buf.resize(N)
	for ci in range(4):
		var c0 := float(ci) * 4.0
		for s8 in range(8):                  # 8 个八分位（0.5s 间隔）
			var t0 := c0 + float(s8) * 0.5
			var vel := 0.20 * (1.3 if s8 % 2 == 1 else 1.0)
			var ring := 6200.0 if s8 % 2 == 1 else 5400.0
			_add_noise_hit(buf, t0, 0.09, vel, 0.022, 500 + ci * 100 + s8, ring)
		_add_noise_hit(buf, c0 + 3.5, 0.45, 0.17, 0.16, 9700 + ci, 5800.0)  # 开镲
	return buf


func _compose_drums() -> PackedFloat32Array:
	# Boss 战鼓：kick 四踩（每 1s）+ 第 4 拍前 3.5s 加一脚；snare 反拍（1s/3s）；
	# 32 分双踩镲轻；末和弦 124~127 步 tom 填充（下行 200→110Hz）——循环回 downbeat
	var buf := PackedFloat32Array()
	buf.resize(N)
	for ci in range(4):
		var c0 := float(ci) * 4.0
		for beat in range(4):
			_add_kick(buf, c0 + float(beat) * 1.0, 0.62)
		_add_kick(buf, c0 + 3.5, 0.45)
		_add_noise_hit(buf, c0 + 1.0, 0.16, 0.42, 0.045, 3100 + ci, 190.0)
		_add_noise_hit(buf, c0 + 3.0, 0.16, 0.42, 0.045, 3200 + ci, 190.0)
		for s in range(0, 32, 2):           # 32 分双踩镲（极轻，密度质感）
			_add_noise_hit(buf, c0 + float(s) * STEP, 0.05, 0.10, 0.012, 7700 + s, 0.0)
		if ci == 3:
			var toms: Array[float] = [200.0, 170.0, 140.0, 110.0]
			for ti in range(4):
				var t0 := float(124 + ti) * STEP
				var n0 := int(t0 * RATE)
				var nn := int(0.11 * RATE)
				var phase := 0.0
				for i in range(nn):
					var idx := n0 + i
					if idx >= N:
						break
					var tt := float(i) / float(RATE)
					phase += TAU * toms[ti] / float(RATE)
					p_buf_tom(buf, idx, phase, tt, 0.5 + 0.05 * float(ti))
	return buf


func p_buf_tom(p_buf: PackedFloat32Array, p_idx: int, p_phase: float, p_t: float, p_vel: float) -> void:
	# tom：正弦 + 少量二次 + 短噪起振（内联函数——数组按引用传递原位写）
	var env := exp(-p_t / 0.07)
	var s := sin(p_phase) + 0.25 * sin(2.0 * p_phase)
	if p_t < 0.004:
		s += 0.5 * _hash_noise(4200 + p_idx % 97) * (1.0 - p_t / 0.004)
	p_buf[p_idx] += p_vel * env * s


# ── 输出 ───────────────────────────────────────────────────────────

func _normalize(p_buf: PackedFloat32Array, p_peak := 0.5) -> void:
	var m := 0.0
	for v in p_buf:
		m = maxf(m, absf(v))
	if m < 0.0001:
		return
	var g := p_peak / m
	for i in range(p_buf.size()):
		p_buf[i] *= g


func _to_wav_res(p_buf: PackedFloat32Array) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(p_buf.size() * 2)
	for i in range(p_buf.size()):
		var v := int(clampf(p_buf[i], -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, v)
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.stereo = false
	wav.data = data
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_begin = 0
	wav.loop_end = p_buf.size()
	return wav


func _initialize() -> void:
	_run()


func _run() -> void:
	print("══════════ R75 音乐作曲器 · 六轨烘焙 ══════════")
	var t0 := Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var tracks: Array = [
		["bgm_menu", _compose_menu()],
		["bgm_pad", _compose_pad()],
		["bgm_bass", _compose_bass()],
		["bgm_arp", _compose_arp()],
		["bgm_hats", _compose_hats()],
		["bgm_drums", _compose_drums()],
	]
	for entry in tracks:
		var name: String = entry[0]
		var buf: PackedFloat32Array = entry[1]
		_normalize(buf)
		var path := "%s/%s.res" % [OUT_DIR, name]
		var err := ResourceSaver.save(_to_wav_res(buf), path)
		var rms := 0.0
		for i in range(0, buf.size(), 97):
			rms += buf[i] * buf[i]
		rms = sqrt(rms / float(buf.size() / 97))
		print("  %s → %s（err=%d rms=%.3f）" % [name, path, err, rms])
	print("作曲完成 %.1fs" % (float(Time.get_ticks_usec() - t0) / 1000000.0))
	quit(0)
