# scripts/gamefeel/sfx_bank.gd
# SfxBank（META_ROADMAP §5.8 表现层一期，用户反馈至今全静音）：程序化音效——启动期
# PCM 合成（正弦/方波/锯齿/噪声 + 包络），零外部素材。静态单例 I 供 UI 直调；
# 高频事件（命中/击杀）70ms 节流。音量 -14dB，polyphony 4。
# BGM 环境音通道（P2，META_ROADMAP §5.10「BGM 环境音」）：循环 PCM 启动期一次性预生成
# （正弦叠加 + 缓慢 LFO，4 小节 8s 无缝循环）——运行期零逐帧生成（用户机器卡顿敏感，
# 纯循环播放）；战斗态播 pad、Boss 存活期叠加低频脉冲第二循环（同长循环锁相 +
# stream_paused 拨运输），菜单暂停。音量 -18dB 级别（AudioServer 之外仅 player.volume_db，
# 不动总线/场景树结构）。
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
const BGM_RATE := 11025                        # 采样率（低频 pad 充裕；预生成量/Boot 预算折中）
const BGM_LOOP_S := 8.0                        # 循环长（4 小节）
const BGM_PAD_DB := -18.0                      # pad 层音量（-18dB 级别）
const BGM_BOSS_DB := -16.0                     # Boss 脉冲层音量（略高于 pad，仍在环境级）
const BGM_LFO_BLOCK := 128                     # LFO 步进块（≈11.6ms——慢 LFO 听感连续）
const SFX_BASE_DB := -14.0                     # 音效基准音量（既有 -14dB 档；设置音量 1.0 = 此档）

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
	# 战斗深度对抗音效：重装盾格挡脆响 + 迫击炮呼啸与爆炸
	_make(&"shield_block", 0.08, 960.0, 420.0, "square", 0.28)
	_make(&"mortar_warn", 0.32, 280.0, 580.0, "sine", 0.22)
	_make(&"mortar_blast", 0.28, 180.0, 40.0, "noise", 0.36)


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
	# 环境垫（4 小节 8s 无缝循环）：A2 110 / E3 165 / A3 220 三正弦叠加 + 0.125/0.25Hz
	# 双 LFO 缓慢呼吸。无缝判据：分量频率与 LFO 频率均为「1/8s 的整数倍」→ 循环点相位连续
	#（110=880/8 · 165=1320/8 · 220=1760/8 · LFO 周期 8s/4s）；幅度头空 ×0.62（Σamp=1.0）
	var n := int(BGM_LOOP_S * float(BGM_RATE))
	var data := PackedByteArray()
	data.resize(n * 2)
	var freqs: Array[float] = [110.0, 165.0, 220.0]
	var amps: Array[float] = [0.5, 0.28, 0.22]
	var lfo_hz: Array[float] = [0.125, 0.25]
	var lfo_phase: Array[float] = [0.0, PI * 0.5]
	var phases: Array[float] = [0.0, 0.0, 0.0]
	var lfo_now: Array[float] = [1.0, 1.0]
	var block_left := 0
	for i in range(n):
		if block_left <= 0:
			block_left = BGM_LFO_BLOCK
			for k in range(2):
				lfo_now[k] = 0.78 + 0.22 * sin(
					TAU * lfo_hz[k] * float(i) / float(BGM_RATE) + lfo_phase[k])
		block_left -= 1
		var s := 0.0
		for j in range(3):
			phases[j] = fmod(phases[j] + freqs[j] / float(BGM_RATE), 1.0)
			s += amps[j] * lfo_now[0 if j != 1 else 1] * _wt[int(phases[j] * 1024.0) & 1023]
		data.encode_s16(i * 2, int(clampf(s * 0.62, -1.0, 1.0) * 32767.0))
	return _wav_loop(data)


func _synthesize_boss_pulse_loop() -> AudioStreamWAV:
	# Boss 层低频脉冲：55Hz 正弦短噗 ×16（每 0.5s 一发、0.4s 平方衰减尾）——
	# 16 发 = 8s 整数倍 + 尾音归零后静默至循环点 → 无缝无爆音
	var n := int(BGM_LOOP_S * float(BGM_RATE))
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in range(n):
		var t_in := fmod(float(i) / float(BGM_RATE), 0.5)
		var s := 0.0
		if t_in < 0.4:
			var u := t_in / 0.4
			s = (1.0 - u) * (1.0 - u) * _wt[int(fmod(55.0 * t_in, 1.0) * 1024.0) & 1023] * 0.9
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
