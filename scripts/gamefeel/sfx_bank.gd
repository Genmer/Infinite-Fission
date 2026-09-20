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

# R75 场景自适应音乐：六轨等长 16s 烘焙循环（tools/gen_music.gd 作曲，boot 零合成）。
# 分层运输：大厅曲（MENU 独占）| 战斗 pad+贝斯（基底）→ +琶音（强度1）→ +踩镲（强度2）
# → Boss 战鼓（存活期叠加）。战斗五轨同长锁相（同帧起播自然对齐）；音量档全部环境级。
const BGM_BASS_DB := -15.0                      # R75b：-17→-15（存在感——用户反馈战斗听感没变）
const BGM_ARP_DB := -16.0                       # R75b：-17.5→-16（琶音 w1 起即战斗主体之一）
const BGM_ARP_HIGH_DB := -19.0
const BGM_HATS_DB := -20.0
const BGM_MENU_DB := -15.0
const BGM_TRACK_DIR := "res://assets/music"

var _bgm_player: AudioStreamPlayer = null      # pad 和声床宿主
var _bgm_bass_player: AudioStreamPlayer = null # 贝斯律动宿主
var _bgm_arp_player: AudioStreamPlayer = null  # 琶音拨弦宿主（强度 ≥1）
var _bgm_hats_player: AudioStreamPlayer = null # 踩镲宿主（强度 ≥1）
var _bgm_arp_high_player: AudioStreamPlayer = null # 高八度琶音宿主（强度 2）
var _bgm_boss_player: AudioStreamPlayer = null # Boss 战鼓宿主（存活期）
var _bgm_menu_player: AudioStreamPlayer = null # 大厅曲宿主（MENU 独占）
var _bgm_active := false                       # 战斗态播放 / 菜单暂停
var _bgm_boss_on := false                      # Boss 存活期战鼓层
var _bgm_intensity := 0                        # 战斗强度档 0/1/2（波次推进驱动；0 已含琶音）
var _bgm_menu_on := false                      # 大厅曲开关（MENU 态驱动）
var _bgm_started := false                      # 战斗五轨首次激活起播（此后仅拨 stream_paused）
var _bgm_menu_started := false                 # 大厅曲首次起播


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
	if _bgm_bass_player != null:
		_bgm_bass_player.volume_db = BGM_BASS_DB + bgm_db
	if _bgm_arp_player != null:
		_bgm_arp_player.volume_db = BGM_ARP_DB + bgm_db
	if _bgm_hats_player != null:
		_bgm_hats_player.volume_db = BGM_HATS_DB + bgm_db
	if _bgm_arp_high_player != null:
		_bgm_arp_high_player.volume_db = BGM_ARP_HIGH_DB + bgm_db
	if _bgm_boss_player != null:
		_bgm_boss_player.volume_db = BGM_BOSS_DB + bgm_db
	if _bgm_menu_player != null:
		_bgm_menu_player.volume_db = BGM_MENU_DB + bgm_db


func play(p_name: StringName, p_pitch_mult: float = 1.0) -> void:
	# p_pitch_mult：G1 连杀音调爬升（击杀声随 combo 档位升 key——爽感听感化）
	if not _players.has(p_name):
		return
	var now := Time.get_ticks_msec()
	if _last_ms.has(p_name) and now - int(_last_ms[p_name]) < THROTTLE_MS:
		return
	_last_ms[p_name] = now
	var player: AudioStreamPlayer = _players[p_name]
	player.pitch_scale = randf_range(0.94, 1.06) * pitch_scale_clamped(p_pitch_mult)
	player.play()


func pitch_scale_clamped(p_mult: float) -> float:
	# 音调乘子钳制（AudioStreamPlayer 安全域 0.05~10；连杀实用域 ≤1.5）
	return clampf(p_mult, 0.25, 2.0)


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
	# R23 施法/预警音色（Boss 弹幕前摇读感——低特效档由调用方门控静音）
	_make(&"cast_warn", 0.14, 260.0, 620.0, "sine", 0.22)
	_make(&"cast_snap", 0.06, 900.0, 420.0, "square", 0.22)
	_make(&"tier_epic", 0.22, 240.0, 70.0, "saw", 0.34)
	# 夜间R15 反应音色（此前反应只有视觉无声音）：碎裂=玻璃感高频下滑 /
	# 过载=电感锯齿上行 / 超导=低频衰减嗡鸣
	_make(&"rxn_shatter", 0.18, 2200.0, 620.0, "sine", 0.24)
	_make(&"rxn_overload", 0.16, 320.0, 980.0, "saw", 0.22)
	_make(&"rxn_super", 0.30, 180.0, 90.0, "saw", 0.20)
	# 夜间R16 满槽状态触发音：点燃=低鸣上行 / 寒滞=结晶高频短音 / 感电=短促 zap
	_make(&"ele_ignite", 0.22, 140.0, 420.0, "saw", 0.20)
	_make(&"ele_frost", 0.14, 1800.0, 1100.0, "sine", 0.22)
	_make(&"ele_zap", 0.08, 1200.0, 240.0, "square", 0.20)
	# 夜间R19 Boss 阶段音：切换=号角上行 / 狂暴=低吼下行
	_make(&"boss_phase", 0.35, 220.0, 660.0, "saw", 0.30)
	_make(&"boss_enrage", 0.45, 160.0, 60.0, "saw", 0.36)
	# 夜间R24 结算音：胜利=三段上行琶音感 / 失败=低沉下行
	_make(&"victory", 0.85, 440.0, 1560.0, "sine", 0.32)
	_make(&"defeat", 0.70, 300.0, 70.0, "saw", 0.32)


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
	# R75 六轨装载（烘焙 .res——曲复杂度在离线作曲期付清，启动仅 load）
	var layers: Array = [
		["bgm_pad", "_bgm_player", "BgmPad", BGM_PAD_DB],
		["bgm_bass", "_bgm_bass_player", "BgmBass", BGM_BASS_DB],
		["bgm_arp", "_bgm_arp_player", "BgmArp", BGM_ARP_DB],
		["bgm_hats", "_bgm_hats_player", "BgmHats", BGM_HATS_DB],
		["bgm_arp_high", "_bgm_arp_high_player", "BgmArpHigh", BGM_ARP_HIGH_DB],
		["bgm_drums", "_bgm_boss_player", "BgmBoss", BGM_BOSS_DB],
		["bgm_menu", "_bgm_menu_player", "BgmMenu", BGM_MENU_DB],
	]
	for entry in layers:
		var player := AudioStreamPlayer.new()
		player.name = String(entry[2])
		player.stream = load("%s/%s.res" % [BGM_TRACK_DIR, String(entry[0])])
		player.volume_db = float(entry[3])
		add_child(player)
		set(entry[1], player)


func bgm_set_active(p_active: bool) -> void:
	# 战斗态开关（GameLoop.change_state 驱动：PLAYING → true，非 PLAYING → false）
	_bgm_active = p_active
	_bgm_transport()


func bgm_set_boss_layer(p_on: bool) -> void:
	# Boss 存活期战鼓层开关（boss_spawned / Boss 击杀驱动）
	_bgm_boss_on = p_on
	_bgm_transport()


func bgm_set_intensity(p_level: int) -> void:
	# R75 战斗强度档（wave_started 驱动）：0 = 前期（pad+贝斯）/ 1 = 中期（+琶音）/
	# 2 = 后期（+踩镲）——战斗随波次推进逐渐饱满；Boss 战鼓独立叠加
	_bgm_intensity = clampi(p_level, 0, 2)
	_bgm_transport()


func bgm_set_scene_menu(p_on: bool) -> void:
	# R75 大厅曲开关（MENU 态驱动）：大厅独立成曲（慢五声 + 华彩和声，无鼓）；
	# GAME_OVER/PAUSED/LEVEL_UP 由调用方双 false——全场静默（结算/暂停戏剧性）
	_bgm_menu_on = p_on
	_bgm_transport()


func bgm_intensity_level() -> int:
	return _bgm_intensity


func bgm_menu_layer_on() -> bool:
	return _bgm_menu_on


func bgm_bass_stream() -> AudioStreamWAV:
	return _bgm_bass_player.stream as AudioStreamWAV


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
	# R75 六轨运输：战斗五轨等长锁相同帧起播（首激活一次性 play，此后仅拨
	# stream_paused——零重建零重定位）；大厅曲独立起播（与战斗曲不同帧源，各自循环）
	if _bgm_active and not _bgm_started:
		_bgm_started = true
		_bgm_player.play()
		_bgm_bass_player.play()
		_bgm_arp_player.play()
		_bgm_hats_player.play()
		_bgm_arp_high_player.play()
		_bgm_boss_player.play()
	if _bgm_menu_on and not _bgm_menu_started:
		_bgm_menu_started = true
		_bgm_menu_player.play()
	_bgm_player.stream_paused = not _bgm_active
	_bgm_bass_player.stream_paused = not _bgm_active
	_bgm_arp_player.stream_paused = not _bgm_active
	_bgm_hats_player.stream_paused = not (_bgm_active and _bgm_intensity >= 1)
	_bgm_arp_high_player.stream_paused = not (_bgm_active and _bgm_intensity >= 2)
	_bgm_boss_player.stream_paused = not (_bgm_active and _bgm_boss_on)
	_bgm_menu_player.stream_paused = not _bgm_menu_on


