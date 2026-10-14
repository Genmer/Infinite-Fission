# scripts/ui/palette.gd
# 方向 C「晴空糖果」调色板单源（美术方向 C 派发单）：
# 明亮底 + 厚描边 + 高饱和敌我区分。所有视觉层取色只经本表——禁止散落字面量色值。
# 纯常量容器（RefCounted，无运行时状态）。
class_name PopPalette
extends RefCounted

# ── 世界基调 ──────────────────────────────────────────────────────
const BG := Color("eef3ff")                   # 淡云蓝白（默认清屏色/菜单底）
const CLOUD := Color(1.0, 1.0, 1.0, 0.55)     # 云朵白（低对比，不抢弹幕）
const CLOUD_FAR := Color(1.0, 1.0, 1.0, 0.32)

# ── 敌我/功能色（高饱和区分） ─────────────────────────────────────
const PLAYER := Color("3d8bff")               # 我方 = 天空蓝
const ENEMY := Color("ff5d5d")                # 敌方 = 珊瑚红
const XP := Color("ffc93c")                   # 经验 = 柠檬黄
const SUCCESS := Color("2ed573")              # 成功 = 薄荷绿
const SHOCK := Color("af8ec1")                # 感电 = 柔电紫（R192 原神色系收敛；8b5dff 葡萄紫让位 RARITY_EPIC 专属，后者独立常量不动）
const ENEMY_DEEP := Color("ff4040")           # 爆虫充能警示（更深的红）
const GOLD := Color("ffc93c")                 # 精英皇冠/传说金
const ORANGE := Color("ff8c1a")               # 二db 橙盾（躲雷奖励）——HUD 橙条/填充专属

# ── 描边/文字 ─────────────────────────────────────────────────────
const OUTLINE := Color("22254a")              # 统一深藏青描边（实体/UI 3~4px）
const INK := Color("22254a")                  # 正文
const INK_SOFT := Color("8a90b8")             # 弱化文字
const PANEL := Color("ffffff")                # 面板纯白（圆角 20 + 藏青描边 + 厚投影）
const PANEL_PRESS := Color("e2e7fb")          # 按下下沉变暗
const DIM := Color(0.133, 0.145, 0.29, 0.55)  # 全屏压暗（藏青半透）

# ── 元素反应跳字双色（R186 反应字体：填充=主读感亲、描边=副亲；描边全深色——
#    亮底 BG #eef3ff 与暗色怪堆双可读；避 FIR 元素橙 #ef7938 / 敌红 #ff5d5d / 金档 #ffc93c） ──
const RXN_FILL_SHATTER := Color("ffefd6")     # 碎裂内填充 暖雪白（灼融白热）
const RXN_LINE_SHATTER := Color("e0483e")     # 碎裂描边 绯红（重击感）
const RXN_FILL_OVERLOAD := Color("ff7a3d")    # 过载内填充 爆裂橙（火归填充）
const RXN_LINE_OVERLOAD := Color("3f2d7a")    # 过载描边 暗电紫（雷归描边，呼应 fx 紫橙双环）
const RXN_FILL_SUPER := Color("d7ecff")       # 超导内填充 冰晶白（呼应雾环）
const RXN_LINE_SUPER := Color("5a3ec8")       # 超导描边 靛紫（深紫保亮底可读）

# R192 反应矩阵扩容（3→20）：新增 17 对沿用「填充浅色主读 / 描边深色副亲」双通道——
# 命名 = RXN_FILL_<反应 id 去 RXN_ 前缀> / RXN_LINE_<同>（id 派生零别名）；按族取色：
# 伤害转化族暖爆（蒸发/绽放）、扩散族按转移元素浅染、减益标签族冷深（冻结/感电/燃烧/激化）、
# 结晶族按被晶元素浅染 + 深晶描边。
const RXN_FILL_FIR_HYD := Color("ffe3d1")     # 蒸发内填充 蒸汽暖白
const RXN_LINE_FIR_HYD := Color("c95a35")     # 蒸发描边 蒸橙（深焙保读）
const RXN_FILL_HYD_DEN := Color("e4f7d4")     # 绽放内填充 花蕊绿白
const RXN_LINE_HYD_DEN := Color("3f8f4f")     # 绽放描边 深花绿
const RXN_FILL_FIR_ANE := Color("ffe4d1")     # 扩散·火内填充 火浸暖白（转移元素浅染）
const RXN_LINE_FIR_ANE := Color("b35a2e")     # 扩散·火描边 深火
const RXN_FILL_ICE_ANE := Color("ddf1ff")     # 扩散·冰内填充 冰浸青白
const RXN_LINE_ICE_ANE := Color("3e7f9e")     # 扩散·冰描边 深冰蓝
const RXN_FILL_LTG_ANE := Color("e9e2ff")     # 扩散·雷内填充 电浸紫白
const RXN_LINE_LTG_ANE := Color("6a539e")     # 扩散·雷描边 深雷紫
const RXN_FILL_HYD_ANE := Color("d9eeff")     # 扩散·水内填充 水浸湛白
const RXN_LINE_HYD_ANE := Color("2f7fa8")     # 扩散·水描边 深水蓝
const RXN_FILL_ANE_DEN := Color("e6f5d1")     # 扩散·草内填充 草浸嫩白
const RXN_LINE_ANE_DEN := Color("4f8f3a")     # 扩散·草描边 深草绿
const RXN_FILL_ICE_HYD := Color("e0f4ff")     # 冻结内填充 冻晶蓝白
const RXN_LINE_ICE_HYD := Color("255a92")     # 冻结描边 深冻蓝
const RXN_FILL_LTG_HYD := Color("e6e0ff")     # 感电内填充 电弧白紫
const RXN_LINE_LTG_HYD := Color("4a34a0")     # 感电描边 深电紫（连锁弧光）
const RXN_FILL_FIR_DEN := Color("ffe8c4")     # 燃烧内填充 灼草暖黄
const RXN_LINE_FIR_DEN := Color("a8622a")     # 燃烧描边 燃橙褐
const RXN_FILL_LTG_DEN := Color("eef5d8")     # 激化内填充 激草青白
const RXN_LINE_LTG_DEN := Color("5f7a2e")     # 激化描边 深激草
const RXN_FILL_FIR_GEO := Color("ffe9cf")     # 结晶·火内填充 晶火暖白
const RXN_LINE_FIR_GEO := Color("a8502a")     # 结晶·火描边 深晶火
const RXN_FILL_ICE_GEO := Color("d8f0fc")     # 结晶·冰内填充 晶冰淡蓝
const RXN_LINE_ICE_GEO := Color("3a86b0")     # 结晶·冰描边 晶冰蓝
const RXN_FILL_LTG_GEO := Color("e7e0fd")     # 结晶·雷内填充 晶电淡紫
const RXN_LINE_LTG_GEO := Color("5f4a9e")     # 结晶·雷描边 晶电紫
const RXN_FILL_HYD_GEO := Color("d5ecfd")     # 结晶·水内填充 晶水淡蓝
const RXN_LINE_HYD_GEO := Color("2a72c2")     # 结晶·水描边 晶水蓝
const RXN_FILL_DEN_GEO := Color("e4f3cd")     # 结晶·草内填充 晶草嫩白
const RXN_LINE_DEN_GEO := Color("558f2e")     # 结晶·草描边 晶草绿
const RXN_FILL_ANE_GEO := Color("d8f0e2")     # 结晶·风内填充 晶风青白
const RXN_LINE_ANE_GEO := Color("3f9a78")     # 结晶·风描边 晶风青

# ── 元素色（R192 元素矩阵启用：原神色系七色单源——跳字配色 / 图鉴配方环 / 死亡迸色 /
#    武器光效统一取色，damage_popup 本地副本已删） ──
# 键 = GameConst.Element 序 int（枚举只追加不重排：KIN..LTG=0..3 既有位不动，
# HYD/ANE/GEO/DEN=4..7 追加位；enum 值即 int，按序直索引）
const ELEMENT_COLORS := {
	0: Color(1.0, 1.0, 1.0),                    # KIN 物理 白
	1: Color("ef7938"),                         # FIR 火 落日橙
	2: Color("9fd6e3"),                         # ICE 冰 冰晶蓝
	3: SHOCK,                                   # LTG 雷 柔电紫（单源引用 SHOCK；RARITY_EPIC 8b5dff 独立不动）
	4: Color("4cc2f1"),                         # HYD 水 湛蓝
	5: Color("74c2a8"),                         # ANE 风 青碧
	6: Color("fab632"),                         # GEO 岩 琥珀金
	7: Color("a5c83b"),                         # DEN 草 嫩草绿
}

# ── 稀有度（普通灰蓝 / 稀有天蓝 / 史诗葡萄紫 / 辉煌柠檬金 / 升华传说玫绯红） ──
const RARITY_NORMAL := Color("8a90b8")
const RARITY_RARE := Color("3fa9ff")
const RARITY_EPIC := Color("8b5dff")
const RARITY_LEGEND := Color("ffc93c")
# R246 D2：升华红（红色传说档 [4] 专属「技能升华」卡）——独立常量入表（视觉层取色
# 单源纪律），三重避让既有红：ENEMY #ff5d5d（绿分量 0x5d 偏品红冷调）/ENEMY_DEEP
# #ff4040（爆虫充能）/碎裂描边 #e0483e（低明度暖红）——色相与载体双区分；
# 禁复用警示红 ENEMY（诅咒染名语义钉同源，不得混流）
const RARITY_SUBLIME := Color("ff2e63")

# R246 D1：红档=「传说」（用户原话「红色（传说级）」），金档 [3] 改名「辉煌」——
# 只换字：金色值 #ffc93c / 数值缩放（RARITY_VALUE_SCALE 不扩档，红品质不参与词条
# 缩放）/稀有度顺序全不动
const RARITY_COLORS: Array[Color] = [RARITY_NORMAL, RARITY_RARE, RARITY_EPIC,
	RARITY_LEGEND, RARITY_SUBLIME]
const RARITY_NAMES: Array[String] = ["普通", "稀有", "史诗", "辉煌", "传说"]

# ── 彩纸屑（Boss 死亡签名瞬间；多色小矩形/圆） ────────────────────
const CONFETTI: Array[Color] = [PLAYER, ENEMY, XP, SUCCESS, SHOCK, Color("ff9f43")]

# ── 经验碎片分档（R208 五档：面值/基线比 <2.5 白 <5 蓝 <12 紫 <40 金 ≥40 七彩；
#    阈值/公式单源在 XpShard.XP_TIER_THRESHOLDS，基线=exp_base×通胀^(w-1)） ──
# [3] 七彩档不走本表：R216 起彩档着色=6 色相步进烤进贴图变体（XpShard._baked_tier_color），
#     非彩档档色亦改烤贴图（modulate 恒白保合批）；白档色 [0] 被直读（含预热队列）
const XP_TIER_COLORS: Array[Color] = [
	Color("fff1b8"),                            # 白档 淡柠檬白（近现行 XP 观感）
	Color("3da9fc"),                            # 蓝档 天蓝（R208 五色递进第 2 档）
	Color("b06ef7"),                            # 紫档 兰紫（R208 五色递进第 3 档）
	Color("ffc93c"),                            # 金档 柠檬金（现行 XP 同值）
	Color("ffffff"),                            # 七彩占位（不直读）
]


static func rarity_color(p_rarity: int) -> Color:
	# 稀有度取色（越界钳制——fallback 卡/坏数据安全）
	return RARITY_COLORS[clampi(p_rarity, 0, RARITY_COLORS.size() - 1)]


static func rarity_name(p_rarity: int) -> String:
	return RARITY_NAMES[clampi(p_rarity, 0, RARITY_NAMES.size() - 1)]


static func xp_tier_color(p_tier: int) -> Color:
	# 经验分档取色（越界钳制——坏数据/降级路径安全，rarity_color 同式）
	return XP_TIER_COLORS[clampi(p_tier, 0, XP_TIER_COLORS.size() - 1)]


static func hp_fill(p_pct: float) -> Color:
	# HP 条填充色：满 → 薄荷绿，中段 → 柠檬黄，低 → 珊瑚红（纯渐变无表情，方向 C 口径）
	var pct := clampf(p_pct, 0.0, 1.0)
	if pct > 0.5:
		return SUCCESS.lerp(XP, (1.0 - pct) * 2.0)
	return XP.lerp(ENEMY, (0.5 - pct) * 2.0)
