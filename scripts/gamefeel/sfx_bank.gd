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
# R184 导弹爆/反弹反馈（用户反馈「命中像转子马达，回弹的也优化一下，干脆点」）：boom 重做
# 分层合成（噪声冲击 + 低频 thump，总长 0.22s，去 0.5s 锯齿长滑轰鸣）；新增 bounce
# 高频短下滑 tick（bullet_bounced 事件接线，节流沿用既有 THROTTLE_MS）。
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
const BGM_COMBAT_VARIANTS := 3                   # R79 战斗曲库（Am-F-C-G / Em-C-G-D / Dm-Bb-F-C）
const BGM_MENU_VARIANTS := 2                     # R79 大厅曲库（Cmaj7 系 / Fmaj7 下行）

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
var _bgm_combat_variant := -1                  # R79 当前战斗套索引（每局随机）
var _bgm_menu_variant := -1                    # R79 当前大厅套索引（回大厅换曲）


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
	# R184 命中/反弹反馈重做（用户反馈「导弹命中跟转子马达一样，还有回弹的，干脆点」）：
	# boom = 噪声冲击 + 低频 thump 分层爆破（0.22s，替代 R80 0.5s 锯齿长滑轰鸣）；
	# bounce = 高频短下滑 tick（与 hit 的低频噪声明显可辨）；节流沿用 THROTTLE_MS
	_make_boom()
	_make(&"bounce", 0.05, 2400.0, 900.0, "sine", 0.20)
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
	_register(p_name, _synthesize(p_dur, p_f0, p_f1, p_kind, p_vol))


func _register(p_name: StringName, p_stream: AudioStreamWAV) -> void:
	# 流注册 + 专属播放器装配（_make / _make_boom 共用；音量/polyphony 同档）
	_streams[p_name] = p_stream
	var player := AudioStreamPlayer.new()
	player.name = "Sfx_%s" % String(p_name)
	player.stream = p_stream
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


func _make_boom() -> void:
	# R184 导弹爆音重做（用户反馈「跟转子马达一样」——旧 R80 0.5s saw 130→34Hz 下滑轰鸣）：
	# 分层干脆爆破 = ① 噪声冲击层（~1ms 快起音 + 0.06s 幂衰减——爆破的「脆」）+
	# ② 低频 thump 层（190→42Hz 正弦快滑 + 0.22s 幂衰减——冲击的「沉」）。
	# 总长 0.22s；双层包络尾点趋零（无拖尾无循环爆音）。play(&"boom") 接口与
	# 大范围爆（r>=100）0.8 音高乘子语义不变（0.8 乘子 → thump 落 152→34Hz 更沉）。
	_register(&"boom", _synthesize_boom(0.22, 190.0, 42.0, 0.06, 0.62))


func _synthesize_boom(p_dur: float, p_thump_f0: float, p_thump_f1: float,
		p_crack_dur: float, p_vol: float) -> AudioStreamWAV:
	# 分层爆破合成：噪声冲击 + thump 双层线性叠加。容器口径与 _synthesize 一致
	#（FORMAT_16_BITS 单声道 22.05k——时长 = data 字节 ÷ 2 ÷ mix_rate）；~1ms 起音斜坡
	#（消起振 DC 爆音）+ 双层幂衰减包络（尾点趋零，无长滑音无拖尾）。
	var rate := 22050
	var n := int(p_dur * rate)
	var crack_n := mini(int(p_crack_dur * rate), n)
	var attack_n := maxi(int(0.001 * float(rate)), 1)
	var data := PackedByteArray()
	data.resize(n * 2)
	var phase := 0.0
	for i in range(n):
		var prog := float(i) / float(n)
		var ease_out := 1.0 - (1.0 - prog) * (1.0 - prog)     # 前段快降贴底（先「砸」后余沉）
		var f := lerpf(p_thump_f0, p_thump_f1, ease_out)
		phase += f / float(rate)
		var thump := sin(TAU * phase) * pow(1.0 - prog, 2.4) * 0.52
		var crack := 0.0
		if i < crack_n:
			var c_prog := float(i) / float(maxi(crack_n, 1))
			crack = (randf() * 2.0 - 1.0) * pow(1.0 - c_prog, 1.8) * 0.42
		var attack := minf(float(i) / float(attack_n), 1.0)
		var v := int(clampf((thump + crack) * attack * p_vol, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, v)
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = data
	return wav


# ── BGM 环境音（P2：预生成 PCM 循环——运行期零逐帧生成） ──────────
func _build_bgm() -> void:
	# R75/R79 轨道装载：踩镲/战鼓固定单轨；pad/贝斯/琶音/高琶 = 战斗变体四件；
	# 大厅曲独立变体。变体选择走 roll（随机 + 换流重启锁相）
	var fixed: Array = [
		["bgm_hats", "_bgm_hats_player", "BgmHats", BGM_HATS_DB],
		["bgm_drums", "_bgm_boss_player", "BgmBoss", BGM_BOSS_DB],
	]
	for entry in fixed:
		var fp := AudioStreamPlayer.new()
		fp.name = String(entry[2])
		fp.stream = load("%s/%s.res" % [BGM_TRACK_DIR, String(entry[0])])
		fp.volume_db = float(entry[3])
		add_child(fp)
		set(entry[1], fp)
	var stems: Array = [
		["_bgm_player", "BgmPad", BGM_PAD_DB],
		["_bgm_bass_player", "BgmBass", BGM_BASS_DB],
		["_bgm_arp_player", "BgmArp", BGM_ARP_DB],
		["_bgm_arp_high_player", "BgmArpHigh", BGM_ARP_HIGH_DB],
	]
	for entry in stems:
		var sp := AudioStreamPlayer.new()
		sp.name = String(entry[1])
		sp.volume_db = float(entry[2])
		add_child(sp)
		set(entry[0], sp)
	_bgm_menu_player = AudioStreamPlayer.new()
	_bgm_menu_player.name = "BgmMenu"
	_bgm_menu_player.volume_db = BGM_MENU_DB
	add_child(_bgm_menu_player)
	bgm_roll_combat_variant()
	bgm_roll_menu_variant()


func bgm_apply_combat_variant(p_v: int) -> void:
	# R79 战斗套切换（roll 的确定性入口——测试注入用）：四件换流；已起播则六轨
	# 同步 stop+play 重锁相（等长 16s 循环，重启即对齐）
	var v := wrapi(p_v, 0, BGM_COMBAT_VARIANTS)   # wrapi 上界排他——0..N-1
	if v == _bgm_combat_variant:
		return
	_bgm_combat_variant = v
	var players: Array = [_bgm_player, _bgm_bass_player, _bgm_arp_player, _bgm_arp_high_player]
	var names: Array = ["bgm_pad", "bgm_bass", "bgm_arp", "bgm_arp_high"]
	for i in range(players.size()):
		players[i].stream = load("%s/%s_v%d.res" % [BGM_TRACK_DIR, String(names[i]), v])
	if _bgm_started:
		for p: AudioStreamPlayer in [_bgm_player, _bgm_bass_player, _bgm_arp_player,
				_bgm_hats_player, _bgm_arp_high_player, _bgm_boss_player]:
			p.stop()
			p.play()


func bgm_roll_combat_variant() -> int:
	# R79 每局随机抽一套战斗曲（start_run 调用——首播前换流零重锁成本）
	var v := randi_range(0, BGM_COMBAT_VARIANTS - 1)
	bgm_apply_combat_variant(v)
	return _bgm_combat_variant


func bgm_apply_menu_variant(p_v: int) -> void:
	var v := wrapi(p_v, 0, BGM_MENU_VARIANTS)
	if v == _bgm_menu_variant:
		return
	_bgm_menu_variant = v
	_bgm_menu_player.stream = load("%s/bgm_menu_v%d.res" % [BGM_TRACK_DIR, v])
	if _bgm_menu_started:
		_bgm_menu_player.stop()
		_bgm_menu_player.play()


func bgm_roll_menu_variant() -> int:
	# R79 回大厅换曲（change_state MENU 驱动）
	var v := randi_range(0, BGM_MENU_VARIANTS - 1)
	bgm_apply_menu_variant(v)
	return _bgm_menu_variant


func bgm_combat_variant_index() -> int:
	return _bgm_combat_variant


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


