# scripts/gamefeel/sfx_bank.gd
# SfxBank（META_ROADMAP §5.8 表现层一期，用户反馈至今全静音）：程序化音效——启动期
# PCM 合成（正弦/方波/锯齿/噪声 + 包络），零外部素材。静态单例 I 供 UI 直调；
# 高频事件（命中/击杀）70ms 节流。音量 -14dB，polyphony 4。
class_name SfxBank
extends Node

static var I: SfxBank = null                   # 静态单例（HUD/菜单直调 play）

var _streams: Dictionary = {}                  # StringName → AudioStreamWAV
var _players: Dictionary = {}                  # StringName → AudioStreamPlayer
var _last_ms: Dictionary = {}                  # StringName → 上次播放 ms（节流）
const THROTTLE_MS := 70


func _ready() -> void:
	I = self
	_build_all()


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


func _make(p_name: StringName, p_dur: float, p_f0: float, p_f1: float,
		p_kind: String, p_vol: float) -> void:
	var stream := _synthesize(p_dur, p_f0, p_f1, p_kind, p_vol)
	_streams[p_name] = stream
	var player := AudioStreamPlayer.new()
	player.name = "Sfx_%s" % String(p_name)
	player.stream = stream
	player.volume_db = -14.0
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
