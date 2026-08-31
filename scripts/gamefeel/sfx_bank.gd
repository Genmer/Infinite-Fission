# scripts/gamefeel/sfx_bank.gd
# SfxBank（META_ROADMAP §5.8 表现层一期，用户反馈至今全静音）：程序化音效——启动期
# PCM 合成（正弦/方波/锯齿/噪声 + 包络），零外部素材。静态单例 I 供 UI 直调；
# 高频事件（命中/击杀）70ms 节流。音量 -14dB，polyphony 4。
# BGM 环境音通道（P2 起，2026-08-31 用户反馈「电流声/杂音」重制）：循环 PCM 启动期一次性
# 预生成（音乐化三声部：C-G-Am-F 暖音色和弦 pad + 五声琶音 + Boss 期战鼓心跳层，
# 16s 无缝循环）——运行期零逐帧生成（用户机器卡顿敏感，纯循环播放）；战斗态播 pad、
# Boss 存活期叠加战鼓第二循环（同长循环锁相 + stream_paused 拨运输），菜单暂停。
# 音量 -18dB 级别（AudioServer 之外仅 player.volume_db，不动总线/场景树结构）。
# 设置页音量接线（P3，META_ROADMAP §5.10「设置页」）：Meta.settings(sfx/bgm_volume)
# 线性 0~1 → 响度近似 db（linear_to_db(max(v,0.001))，0 → -60dB 静音档）——音量 1.0 =
# 既有基准档；settings_changed 信号驱动实时应用。
class_name SfxBank
extends Node

static var I: SfxBank = null                   # 静态单例（HUD/菜单直调 play）

var _streams: Dictionary = {}                  # StringName → AudioStreamWAV
var _players: Dictionary = {}                  # StringName → AudioStreamPlayer
var _last_ms: Dictionary = {}                  # StringName → 上次播放 ms（节流）
const THROTTLE_MS := 70

# ── BGM 环境音参数（数值真源） ────────────────────────────────────
# 2026-08-31 用户反馈「BGM 像电流声/杂音」重制：旧版 = 110/165/220Hz 三纯正弦 + 块步进 LFO
#（纯低频正弦叠加听感即变压器嗡鸣，86Hz 步进边带叠加成电流杂音）。新版为音乐化三声部：
# ① 和弦 pad：C-G-Am-F 四和弦（每和弦 4s，暖音色 = 基频 + 0.35×二次 + 0.12×三次谐波，
#    逐采样连续包络，和弦首尾归零 → 无缝无爆音）；② 五声琶音：0.5s 一粒指数衰减拨音；
# ③ Boss 层：战鼓心跳（180→70Hz 滑频鼓 + 起振噪声瞬态）替代旧 55Hz 纯正弦噗（嗡鸣源之二）。
const BGM_RATE := 22050                        # 采样率（22.05k：谐波/起振瞬态无混叠）
const BGM_LOOP_S := 16.0                       # 循环长（4 和弦 × 4s）
const BGM_PAD_DB := -18.0                      # pad 层音量（-18dB 级别）
const BGM_BOSS_DB := -16.0                     # Boss 脉冲层音量（略高于 pad，仍在环境级）
const SFX_BASE_DB := -14.0                     # 音效基准音量（既有 -14dB 档；设置音量 1.0 = 此档）
# 和弦进行（I–V–vi–IV，C 大调暖色进行；频率真源：C3=130.81 G3=196.00 A3=220.00 F3=174.61，
# 上方声部按纯律三度/五度近似取值——听感为准的圆整值）
const BGM_CHORDS: Array[Array] = [
	[130.81, 196.00, 261.63, 329.63],   # C：C3 G3 C4 E4
	[98.00, 196.00, 246.94, 293.66],    # G：G2 G3 B3 D4
	[110.00, 220.00, 261.63, 329.63],   # Am：A2 A3 C4 E4
	[87.31, 174.61, 220.00, 261.63],    # F：F2 F3 A3 C4
]
const BGM_ARP_NOTES: Array[float] = [261.63, 293.66, 329.63, 392.00, 440.00, 523.25]   # C 五声琶音池

var _bgm_player: AudioStreamPlayer = null      # pad 循环宿主
var _bgm_boss_player: AudioStreamPlayer = null # Boss 脉冲层宿主（与 pad 同长锁相）
var _bgm_active := false                       # 战斗态播放 / 菜单暂停
var _bgm_boss_on := false                      # Boss 存活期第二循环
var _bgm_started := false                      # 首次激活起播（此后仅 stream_paused 拨运输）
var _wt: PackedFloat32Array = PackedFloat32Array()  # 正弦查找表（PCM 预生成提速）


func _ready() -> void:
	I = self
	_build_all()
	_build_bgm()
	apply_settings_volumes()
	Meta.settings_changed.connect(_on_settings_changed)   # 设置页拖动 → 实时应用


func _on_settings_changed(p_key: String) -> void:
	# 设置段音量键变更（P3）→ 立即换算应用（写即存链路的播放侧落点）
	if p_key == "sfx_volume" or p_key == "bgm_volume":
		apply_settings_volumes()


static func linear_gain_db(p_linear: float) -> float:
	# 线性 0~1 → 响度近似 db：db = linear_to_db(max(v, 0.001))——
	# 0 → -60dB 静音档（简单稳妥：不拨 stream_paused，数学下限即听感静音）
	return linear_to_db(maxf(clampf(p_linear, 0.0, 1.0), 0.001))


func apply_settings_volumes() -> void:
	# 设置页音量接线（P3）：音量 1.0 = 既有基准档（sfx -14 / pad -18 / boss -16），
	# 相对基准叠加增益——线性→响度近似，零档全播放器统一 -60dB 静音档
	var sfx_db := SFX_BASE_DB + linear_gain_db(float(Meta.settings("sfx_volume")))
	for key: Variant in _players:
		(_players[key] as AudioStreamPlayer).volume_db = sfx_db
	var bgm_db := linear_gain_db(float(Meta.settings("bgm_volume")))
	if _bgm_player != null:
		_bgm_player.volume_db = BGM_PAD_DB + bgm_db
	if _bgm_boss_player != null:
		_bgm_boss_player.volume_db = BGM_BOSS_DB + bgm_db


func play(p_name: StringName) -> void:
	if not _players.has(p_name):
		return
	var now := Time.get_ticks_msec()
	if _last_ms.has(p_name) and now - int(_last_ms[p_name]) < THROTTLE_MS:
		return
	_last_ms[p_name] = now
	(_players[p_name] as AudioStreamPlayer).play()


func _build_all() -> void:
	_make(&"shoot", 0.05, 760.0, 380.0, "square", 0.20)
	_make(&"hit", 0.05, 180.0, 120.0, "noise", 0.16)
	_make(&"kill", 0.16, 520.0, 130.0, "saw", 0.30)
	_make(&"level", 0.42, 440.0, 1320.0, "sine", 0.34)     # 上行琶音感（连续滑频）
	_make(&"skill", 0.28, 200.0, 1400.0, "saw", 0.30)
	_make(&"coin", 0.14, 980.0, 1470.0, "sine", 0.30)
	_make(&"shield", 0.20, 300.0, 900.0, "sine", 0.26)
	_make(&"boss", 0.55, 110.0, 70.0, "saw", 0.40)
	_make(&"buy", 0.12, 700.0, 1050.0, "sine", 0.28)
	# 量级分档联动音（P2 伤害数字分级）：紫档金属「叮」高频短音 / 金档重击低频
	_make(&"tier_high", 0.09, 1760.0, 1480.0, "sine", 0.26)
	_make(&"tier_epic", 0.22, 240.0, 70.0, "saw", 0.34)


func _make(p_name: StringName, p_dur: float, p_f0: float, p_f1: float,
		p_kind: String, p_vol: float) -> void:
	var stream := _synthesize(p_dur, p_f0, p_f1, p_kind, p_vol)
	_streams[p_name] = stream
	var player := AudioStreamPlayer.new()
	player.name = "Sfx_%s" % String(p_name)
	player.stream = stream
	player.volume_db = SFX_BASE_DB
	player.max_polyphony = 4
	add_child(player)
	_players[p_name] = player


func _synthesize(p_dur: float, p_f0: float, p_f1: float, p_kind: String,
		p_vol: float) -> AudioStreamWAV:
	var rate := 22050
	var n := int(p_dur * rate)
	var data := PackedByteArray()
	data.resize(n * 2)
	var phase := 0.0
	for i in range(n):
		var prog := float(i) / float(n)
		var f := lerpf(p_f0, p_f1, prog)
		phase += f / float(rate)
		var sample := 0.0
		match p_kind:
			"square":
				sample = 1.0 if fmod(phase, 1.0) < 0.5 else -1.0
			"saw":
				sample = fmod(phase, 1.0) * 2.0 - 1.0
			"noise":
				sample = randf() * 2.0 - 1.0
			_:
				sample = sin(TAU * phase)
		var env := pow(1.0 - prog, 1.6)              # 指数衰减包络（去爆音）
		var v := int(clampf(sample * env * p_vol, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, v)
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = data
	return wav


# ── BGM 环境音（P2：预生成 PCM 循环——运行期零逐帧生成） ──────────
func _build_bgm() -> void:
	# 查找表 + 双层循环一次性预生成（启动期 ~2×8s@11025Hz；Boot <3s 预算内）
	_wt.resize(1024)
	for i in range(1024):
		_wt[i] = sin(TAU * float(i) / 1024.0)
	_bgm_player = AudioStreamPlayer.new()
	_bgm_player.name = "BgmPad"
	_bgm_player.stream = _synthesize_pad_loop()
	_bgm_player.volume_db = BGM_PAD_DB
	add_child(_bgm_player)
	_bgm_boss_player = AudioStreamPlayer.new()
	_bgm_boss_player.name = "BgmBoss"
	_bgm_boss_player.stream = _synthesize_boss_pulse_loop()
	_bgm_boss_player.volume_db = BGM_BOSS_DB
	add_child(_bgm_boss_player)


func bgm_set_active(p_active: bool) -> void:
	# 战斗态开关（GameLoop.change_state 驱动：PLAYING → true，MENU → false）
	_bgm_active = p_active
	_bgm_transport()


func bgm_set_boss_layer(p_on: bool) -> void:
	# Boss 存活期第二循环开关（boss_spawned / Boss 击杀驱动）
	_bgm_boss_on = p_on
	_bgm_transport()


func bgm_is_active() -> bool:
	return _bgm_active


func bgm_boss_layer_on() -> bool:
	return _bgm_boss_on


func bgm_loop_seconds() -> float:
	# 观测口（测试断言 8s 循环）
	return BGM_LOOP_S


func bgm_pad_stream() -> AudioStreamWAV:
	return _bgm_player.stream as AudioStreamWAV


func _bgm_transport() -> void:
	# 双层同源起播（等长 8s 循环自然锁相）；此后仅 stream_paused 拨运输——零重建零重定位
	if not _bgm_started:
		if not _bgm_active:
			return
		_bgm_started = true
		_bgm_player.play()
		_bgm_boss_player.play()
	_bgm_player.stream_paused = not _bgm_active
	_bgm_boss_player.stream_paused = not (_bgm_active and _bgm_boss_on)


func _synthesize_pad_loop() -> AudioStreamWAV:
	# 音乐化 pad（16s 循环 = 4 和弦 × 4s）：暖音色和弦声部 + 五声琶音拨音 + 低音衬底。
	# 无缝判据：每和弦段包络（0.5s attack → 平台 → 0.8s release）在段首/段尾精确归零，
	# 循环点（末和弦 release 结束 → 首和弦 attack 开始）两侧样本均为 0 → 无爆音无跳变；
	# 逐采样连续 LFO（0.09Hz 呼吸）——旧版 128 样本块步进的 86Hz 边带（电流杂音源）已消除。
	var n := int(BGM_LOOP_S * float(BGM_RATE))
	var chord_len := int(float(n) / float(BGM_CHORDS.size()))
	var data := PackedByteArray()
	data.resize(n * 2)
	var phases: Array[float] = [0.0, 0.0, 0.0, 0.0]
	var bass_phase := 0.0
	var arp_phase := 0.0
	var arp_left := 0.25
	var arp_note := 0.0
	var arp_idx := 0
	for i in range(n):
		var t := float(i) / float(BGM_RATE)
		# 和弦段包络（段内归零起止）
		var seg := i / chord_len
		var seg_t := float(i - seg * chord_len) / float(chord_len)
		var env := 0.0
		if seg_t < 0.125:
			env = seg_t / 0.125                        # 0.5s attack
		elif seg_t > 0.8:
			env = maxf(1.0 - (seg_t - 0.8) / 0.2, 0.0)  # 0.8s release
		else:
			env = 1.0
		# 呼吸 LFO（逐采样连续——正弦慢呼吸，无步进边带）
		var breath := 0.82 + 0.18 * sin(TAU * 0.09 * t + 0.7)
		var s := 0.0
		var chord: Array = BGM_CHORDS[mini(seg, BGM_CHORDS.size() - 1)]
		for j in range(4):
			phases[j] = fmod(phases[j] + chord[j] / float(BGM_RATE), 1.0)
			# 暖音色：基频 + 0.35 二次 + 0.12 三次（非纯音——去「电流嗡鸣」感的关键）
			var tone := _wt[int(phases[j] * 1024.0) & 1023] \
				+ 0.35 * _wt[int(fmod(phases[j] * 2.0, 1.0) * 1024.0) & 1023] \
				+ 0.12 * _wt[int(fmod(phases[j] * 3.0, 1.0) * 1024.0) & 1023]
			s += tone * (0.34 if j == 0 else 0.22)
		# 低音衬底（根音低八度纯正弦，慢颤音；幅度小于旧版避免嗡鸣）
		bass_phase = fmod(bass_phase + chord[0] * 0.5 / float(BGM_RATE), 1.0)
		s += _wt[int(bass_phase * 1024.0) & 1023] * 0.20
		s *= env * breath
		# 五声琶音拨音（0.25s 起每 0.5s 一粒，指数衰减 0.42s；调度窗 [0.25, 15.5]——
		# 末粒 15.25s 起、15.7s 前衰减归零 → 循环点两侧样本为 0，无缝无爆音）
		if arp_left <= 0.0 and t >= 0.25 and t <= 15.5:
			arp_left = 0.5
			arp_note = BGM_ARP_NOTES[arp_idx % BGM_ARP_NOTES.size()]
			arp_idx += 1
			arp_phase = 0.0
		arp_left -= 1.0 / float(BGM_RATE)
		var arp_t := 0.5 - arp_left
		if arp_t < 0.42:
			arp_phase = fmod(arp_phase + arp_note / float(BGM_RATE), 1.0)
			s += _wt[int(arp_phase * 1024.0) & 1023] \
				* 0.16 * exp(-arp_t / 0.16)
		data.encode_s16(i * 2, int(clampf(s * 0.5, -1.0, 1.0) * 32767.0))
	return _wav_loop(data)


func _synthesize_boss_pulse_loop() -> AudioStreamWAV:
	# Boss 层战鼓心跳（16s 循环）：每 1.0s 一记低鼓（180→70Hz 快速滑频 + 起振噪声瞬态 +
	# 二次衰减尾），1 拍 = 8s/8 整除 → 循环点尾音归零后静默，无缝无爆音。
	# （旧版 55Hz 纯正弦短噗每 0.5s ×16——纯正弦低频持续脉冲即「电流嗡鸣」观感，弃用）
	var n := int(BGM_LOOP_S * float(BGM_RATE))
	var data := PackedByteArray()
	data.resize(n * 2)
	var beats := int(BGM_LOOP_S / 1.0)
	var beat_len := n / beats
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260831                         # 噪声瞬态确定性（同 Boot 同波形）
	for i in range(n):
		var b := i / beat_len
		var t_in := float(i - b * beat_len) / float(BGM_RATE)
		var s := 0.0
		if t_in < 0.42:
			var u := t_in / 0.42
			var f := lerpf(180.0, 70.0, minf(u * 3.0, 1.0))   # 起振 0.14s 内滑到鼓底频
			var body := _wt[int(fmod(f * t_in, 1.0) * 1024.0) & 1023]
			var attack_noise := (rng.randf() * 2.0 - 1.0) * maxf(1.0 - u * 14.0, 0.0) * 0.22
			s = (body * (1.0 - u) * (1.0 - u) * 0.85 + attack_noise)
		data.encode_s16(i * 2, int(clampf(s, -1.0, 1.0) * 32767.0))
	return _wav_loop(data)


func _wav_loop(p_data: PackedByteArray) -> AudioStreamWAV:
	# 16bit 单声道循环 wav（LOOP_FORWARD 全段；loop_end 单位 = 帧）
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = BGM_RATE
	wav.stereo = false
	wav.data = p_data
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_begin = 0
	wav.loop_end = p_data.size() / 2
	return wav
