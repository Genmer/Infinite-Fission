# R246 · 红色传说品质与「技能升华」卡 —— 全链路系统设计

> 设计师：R246 workflow「设计师-升华卡系统」（泳道 cards 侧真源文档）。
> 用户原话（FEEDBACK_TRACKER.md:1339）：「buff里多一个红色（传说级）buff就是升华角色技能，爆率只有0.001%」——抽到后**本局**技能升级为升华版。
> 升华技能本体（10 角色各自的升华版效果数值/机制）由 10 位角色设计师并行产出，真源在各自 `docs/design/sublime/` 文档 + `CharacterTable` 表键；**本文档只负责卡系统链路**：品质档、roll、卡型、卡面、拾取生效、fission 处理、统计与测试契约。
>
> 本文所有 `path:line` 引用均经设计期实读核验（2026-10-08）；基线套件 `test_qa_r220_mode.gd` 67/67 全绿（headless exit 0，本设计零代码改动前跑测）。

---

## 0. 决策总表（一句话版）

| # | 决策 | 一句话 |
|---|------|--------|
| D1 | 红档位 | `rarity=4` 排金(3)之上；`RARITY_NAMES[4]="传说"`、金档 `[3]` 改名 **"辉煌"**（只换字，金色值/数值/语义全不动） |
| D2 | 红色值 | 新独立常量 `PopPalette.RARITY_SUBLIME = Color("ff2e63")`（玫绯红），禁复用警示红 `ENEMY` |
| D3 | 缩放域 | `RARITY_VALUE_SCALE` **不扩档**——红品质=升华卡专属品质，不参与词条数值缩放；`_roll_rarity` 永不返回 4 |
| D4 | roll | 独立 `_sublime_rng` 实例流，每批 `generate_candidates` 一次 `randf() < 0.00001`（0.001% 字面精确），掷中替换末位非保底卡 |
| D5 | 卡型 | **单卡通用**（一张「技能升华」卡，效果=升华当前角色）；每角色一卡方案否决（理由见 §2.3） |
| D6 | 生效 | `apply_choice` 新 `CardKind.SUBLIME` 分支 → `player.enable_sublime()`（幂等），本局语义、不落 Meta 存档 |
| D7 | fission | 表有 `sublime_*` 键→正常上架读表文案（替代升华设计）；表无→掷中转不上架（绝不出现"抽了没反应"的破洞卡） |
| D8 | 挂机 | `AutoIdleStrategy.score` 对 SUBLIME 卡特判返 `998.0`（挂机必选，不被金词条压过） |
| D9 | 黑市 | 不上架（0.001% 不进金币经济；黑市词条链零改动） |
| D10 | 保底/替代获取 | **不做**——tracker #6 标记「❓用户裁定」，本文 §9 记开放问题 |

---

## 1. 品质现状与红档接入

### 1.1 现状锚点（实读核验）

- 品质是**裸 int 0..3，无独立 enum**；颜色/名称双单源在 `PopPalette`（`repo/scripts/ui/palette.gd:93-100`：`RARITY_COLORS=[灰蓝8a90b8, 天蓝3fa9ff, 葡萄紫8b5dff, 柠檬金ffc93c]`、`RARITY_NAMES=["普通","稀有","史诗","传说"]`），取色/取名经 `clampi` 钳制（palette.gd:118-124）——**扩第 5 档必须扩这两个数组**，否则红卡被钳成金色金名。
- 品质→数值倍率单源 `RARITY_VALUE_SCALE=[1.0,1.4,1.9,2.6]`（`repo/scripts/cards/card_generator.gd:60`）；消费点：`_apply_rarity_values`（card_generator.gd:142-146，clamp 到 size-1）、卡面预热 `enumerate_prewarm_variants`（card_generator.gd:921/951 按数组长度枚举）、黑市镜像 `_make_trait_ware`（`repo/scripts/ui/shop_ui.gd:182` 硬钳 `clampi 0..3`）。
- 金(3) 的显示名现为「传说」（palette.gd:100）——与「红色传说」直接撞名，必须处理（§1.2）。

### 1.2 D1 档位与命名：红=「传说」，金改「辉煌」

**裁定：`RARITY_NAMES` 扩为 `["普通","稀有","史诗","辉煌","传说"]`，`RARITY_COLORS` 追加 `[4]=RARITY_SUBLIME`。**

依据：

1. **用户字面**：用户原话「红色（传说级）」——红色在用户心智里就叫传说。任务书也点名概率文案形如「0.001% 传说」。红档=「传说」是对用户原话最忠实的落点。
2. **金改名的真实影响面 = 1 行单源**：`rarity_name` 全仓消费只有两处卡面露出——类别行（`repo/scripts/cards/card_select_ui.gd:247-248`）与精通卡连升括注（card_generator.gd:230，精通最高紫不到 3，实际不露出「辉煌」字样）。侦查已确认**无任何测试锁名称字面**。金色的一切既有读感锚点是**颜色**（`#ffc93c`）、◆金徽记、「品质金」角色（`repo/scripts/ui/theme.gd:189-198`）——全部不读 `RARITY_NAMES[3]`，零触碰。
3. **位阶自洽**：普通→稀有→史诗→辉煌→传说，严格递增，老玩家对金档的认知迁移成本仅一个词（颜色、数值、稀有度顺序全不变）。

实施注意：金改名后需复跑 `verify_feedback_cases` / `pkg4_cases` 全量确认无隐性字面断言（侦查口径「未锁」，但以跑测为准）。

### 1.3 D2 色值：独立常量 `RARITY_SUBLIME`，三重避让

**裁定：`PopPalette.RARITY_SUBLIME := Color("ff2e63")`（玫绯红），`RARITY_COLORS` 追加引用。**

palette.gd:3 钉死「所有视觉层取色只经本表，禁止散落字面量色值」——新红必须入表为独立常量。选 `#ff2e63` 的避让核算：

| 既有红 | 值 | 载体 | 与 #ff2e63 区分 |
|---|---|---|---|
| `ENEMY` 警示红 | `#ff5d5d`（palette.gd:15） | 诅咒卡名/类别行文字、敌方体色 | 色相偏品红（绿分量 0x2e vs 0x5d，明显偏冷调）；且载体不同——红品质落**整条顶带+5 圆珠**，警示红只染文字 |
| `ENEMY_DEEP` 深警示红 | `#ff4040`（palette.gd:19） | 爆虫充能 | 同上，色相与载体双区分 |
| 碎裂描边 | `#e0483e`（palette.gd:33） | 反应跳字 | 低明度暖红 vs 高饱和玫红；不同 UI 层 |

**撞色场景结构性不存在**：升华卡是新 `CardKind.SUBLIME`（§2.1），而诅咒标记 `curse_last` 只打第 4 张词条卡（card_generator.gd:135-136 写 `out[3]["cursed"]=true`，本设计将其收紧为仅 TRAIT 卡）——**红品质卡永不带诅咒**，「传说诅咒卡上两红不可分」的评审风险直接消除。

### 1.4 D3 缩放域不扩档（红≠更强的词条）

**裁定：`RARITY_VALUE_SCALE` 保持 4 档不动；红档不参与任何词条数值缩放。**

三条理由：

1. **语义**：用户语义里红品质=「升华角色技能」这张卡本身，不是「数值 ×3.4 的金上加强版词条」。若红也缩放词条，数值膨胀失控（金 2.6 → 红 3.4 即 +31% 系统性通胀），且与升华卡毫无关系。
2. **契约冻结**：R220 拆解契约冻结 `_scaled_description` 本体零改动（`repo/docs/design/2026-10-03-R220-拆解契约.md`）；`enumerate_prewarm_variants` 按 `RARITY_VALUE_SCALE.size()` 枚举（card_generator.gd:921/951）——扩档会自动生成 ×5 档预热变体（约 +25% 队列量）并撞翻测试硬锁。
3. **测试锁**：`r220_cardprewarm_cases.gd:336-339` 硬编码 `scales=[1.0,1.4,1.9,2.6]+range(4)`；`qa_r220_mode_cases.gd:175` 断言「×1.0/×1.4/×1.9/×2.6」四变体各就位（本设计基线跑测 67/67 绿，见 §0 引言）。不扩档=这些锁**天然保持绿**。

推论（省下的改动面）：`_roll_rarity` 硬编码权重不动（card_generator.gd:992-1003，永不返回 4）；`_apply_rarity_values` 的 TRAIT/MASTERY 分支不动；黑市镜像 `shop_ui.gd:182` 的 `clampi 0..3` 不动（黑市 roll 源无 4）；`pause_overlay.gd:561-562` 徽记数组 `["蓝","紫","金"][eff_rarity-1]` 不动（徽记读词条数据 `max_rarity`，词条 rarity 域仍 0..3——红只在升华卡 dict 上，不产生 rarity=4 的词条数据）；MASTERY 钳紫（card_generator.gd:214-220）、RELIC/SLOT_BONUS 硬编码 3（card_generator.gd:805/818）全部不动。

### 1.5 与「金=满层质变预告」语义的冲突消解

金的非品质语义清单与逐项消解：

| 金语义锚点 | 位置 | 冲突？ | 消解 |
|---|---|---|---|
| 满层质变预告金名 | card_select_ui.gd:258-259（`milestone→GOLD`） | 否 | 升华卡不走词条链，`milestone` 恒 `false`（§2.1 卡 dict）——永不触发金名，红名独占 |
| 质变达成金名（词条面板） | `repo/scripts/ui/pause_overlay.gd:541-548` | 否 | 升华卡不挂词条栈、不进词条面板 |
| ◆质变◆ 前缀 + ×1.6 尾注 | card_generator.gd:776-778 | 否 | 升华卡不走 `_make_trait_card` |
| 武器 L5 质变 transcend 金播报 | `repo/scripts/combat/weapon/weapon_base.gd:557-576` | 否 | 不涉技能升华 |
| 挂机预选描金 | card_select_ui.gd:145-168（`highlight_candidate→GOLD`） | **是**：红卡被预选时顶带被金覆盖=读感降级 | **D11：`highlight_candidate` 对目标卡 `rarity==4` 的槽位跳过描色**（红卡自带全货架最高视觉优先级——红顶带+5 珠，无需再描金提示；仅记录槽位保持 `highlighted_slots()` 观测口语义）。`_clear_highlight`（:176-186）零改动——未描色槽位重上色幂等无害 |
| HUD「品质金」角色硬保全 | theme.gd:189-198（`LabelRole.GOLD`，test_r230_k4 锁） | 否 | 金角色不动；红播报若需 HUD 角色，`LabelRole` **末位追加** `SUBLIME`（枚举只追加不重排，palette.gd:80-81 同纪律）+ 同步 r230 套件；代价高则回落 `mechanics_intro` 横幅（§5.3） |
| 精英皇冠/XP 金档/技能金环 | palette.gd:20/103/113 | 否 | 零触碰 |

**总结：红档与金语义的冲突面收敛到唯一一处（挂机描金），用「跳过」消解，零新机制。**

---

## 2. 升华卡卡型：`CardKind.SUBLIME`

### 2.1 枚举与卡结构

```gdscript
# card_generator.gd —— 枚举只追加不重排（现值 MASTERY,TRAIT,RELIC,FALLBACK,WEAPON,SLOT_BONUS = 0..5）
enum CardKind { MASTERY, TRAIT, RELIC, FALLBACK, WEAPON, SLOT_BONUS, SUBLIME }   # SUBLIME = 6

const SUBLIME_CHANCE := 0.00001   # 0.001% 字面（1e-5；randf() ∈ [0,1) 精确等概）

func _make_sublime_card(p_player: Node) -> Dictionary:
    # 文案真源 = CharacterTable 当前角色条目 sublime_* 键（meta 泳道落表，角色设计师填值；
    # 本函数只读表拼接——卡系统不持有任何角色升华数值）
    var cid := StringName(String(p_player.get("character_id"))) if p_player != null else &"sentinel"
    var ch := CharacterTable.get_character(cid)
    var sname := String(ch.get("sublime_name", ""))
    var sdesc := String(ch.get("sublime_desc", ""))
    return {
        "kind": CardKind.SUBLIME,
        "id": &"SUBLIME_SKILL",
        "rarity": 4,
        "value_scale": 1.0,          # 无品质加成尾行（compose_desc_text :500 守卫 value_scale>1）
        "data": null,                # 不挂词条栈、不写共享 .tres（E-08 天然不破）
        "display_name": "技能升华" + ("：%s" % sname if sname != "" else ""),
        "description": (sdesc + "\n" if sdesc != "" else "") + "本局技能升级为升华版 · 爆率 0.001%（红色传说）",
        "milestone": false,
        "overcap": false,
    }
```

要点：

- **`data: null` + `value_scale: 1.0`**：升华卡不是词条，不进 `_apply_rarity_values` 的 TRAIT/MASTERY 缩放分支（match 无 SUBLIME case 自然落空；建议实施时在 match 前对 `kind==SUBLIME` 显式 `continue`，免得 `clampi` 算出无用 scale 的死值）。
- **`target_weapon` 不存在**：无挂载目标，`apply_choice` 走 RELIC/SLOT_BONUS 同款「即时应用卡型」分支（card_generator.gd:347-401 现有先例）。
- 描述里的「爆率 0.001%」即任务要求的**概率卡面显示**（全仓此前无品级概率文案挂点，这是新挂点；§5.2 列其余露出位）。

### 2.2 D4 roll 链：独立 RNG 掷，0.001% 字面精确

**随机源**：新增 `var _sublime_rng := RandomNumberGenerator.new()`，构造期定种（建议 `seed = 20261008`，R88 `_slot_rng` 先例 card_generator.gd:18/38）。**不与主 `rng` / `_slot_rng` 混流**——架构 §0.1-5「影响确定性的掷骰走 RandomNumberGenerator 实例流」纪律，且不扰动 pkg4 等按固定种子断言分布的既有序列（`pkg4_cases.gd:464-470` 金 500 抽分布锁）。

**概率落点**：`_roll_rarity` 硬编码 dict（card_generator.gd:995-997）**不动**。理由：它是**相对权重**（现行 {46,30,15,6} 和=97，金实际占比 6/97≈6.19%≠名义 6%）——若为塞进 0.001% 重算全表，四档概率全部漂移、分布锁直接翻红；且 `data/balance/balance_tables.tres` 的 `rarity_weights` 是全仓零消费点的僵尸镜像（`data_validator.gd:409-412` 还按 `int()` 截断累加，放 0.00097 会被截 0），**不接线**（§8 记后续清理建议）。

**掷法**（唯一 roll 落点）：

```gdscript
# generate_candidates 尾段（floor/fixed/curse 全部应用之后、return 之前）：
var sublime_roll := player != null and player.has_method(&"enable_sublime") \
        and _sublime_available(player) \
        and _sublime_rng.randf() < SUBLIME_CHANCE
# _sublime_available（§3）：fission 且表无 sublime_desc 键 → 恒 false（不掷）；
# 其余角色（含 fission 表有键）→ true。掷中 → 末位非保底卡替换为 _make_sublime_card(player)。
```

- **每批一次掷**（不是每张）：R185 已裁定的同型先例——金卡「武器槽+1」从「每张 4%」收敛为「每批一次 5%」（card_generator.gd:93-97 注释原话）。批概率 = 1e-5，期望 **100,000 批一遇**（以每局数十批计为数千局量级一遇；不给具体局数承诺，期望值公式即答案）。
- **插入位置=替换末位非保底卡**：从货架末位向前找第一张 `kind != FALLBACK` 且 `kind != SLOT_BONUS` 的卡替换之（保底卡神圣不可替换——card_generator.gd:95-96 既有口径同款）；全批皆保底（空注册表测试态）→ 本批放弃上架（**掷中即耗掉，不补偿不重掷**——0.001% 概率语义严格，出现率恒 ≤ 名义值，绝不超发）。成对模式（6 卡满）同规则替换末位非保底卡，无槽位溢出问题。
- **插入时机天然豁免四类副作用**：
  - `slot_roll` 替换（:97-104）在 deal 循环内，先于升华插入 → 不会覆盖升华卡；
  - `EARLY_WEAPON` 末位替换（:119-125）在 deal 后、升华前 → 同上；
  - `REL_OVERCLOCK` 保底 `out[0]["rarity"] = max(rarity, floor)`（:127-128）→ 升华卡在末位且在其后插入，天然不撞；
  - `REL_WORDS_TIDE` `fixed_rarities` 逐位覆盖（:130-133）与 `curse_last`（:135-136）同理。
  **仍要求显式防线**（防未来插入点前移的回归）：fixed 循环与 floor 语句各加 `if int(out[i].get("kind",-1)) == CardKind.SUBLIME: continue` 跳过；`curse_last` 收紧为仅 `kind==TRAIT` 才置 `cursed`（同时根治「未来任何非 TRAIT 卡被打诅咒」的面）。**0.001% 被 100% 保底顶穿、或被重随改写稀有度 = 设计破洞，这三处豁免是硬契约，r246 套件锁死（§7 T3）。**
- **每日挑战定种**：`game_loop.gd:1553-1559` 段同步注入——每日局 `_sublime_rng.seed = p_daily_seed`（与 `card_generator.rng` 同点，全服同日同批出卡）；常规局 `_sublime_rng.randomize()`。继续局（:2816 只 randomize 主 rng 处）同点补掷流重randomize——存档不含 RNG 状态，既有口径。

### 2.3 D5 单卡通用 vs 每角色一卡

| 维度 | 单卡通用（推荐 ✅） | 每角色一卡（10 张） |
|---|---|---|
| 用户原话贴合 | 「多**一个**红色 buff」「升华**角色**技能（当前角色）」——单数、指向所玩角色 | 原话无 10 张卡的暗示 |
| 玩家可感知概率 | 0.001% 全额集中在一张卡 | 每张 0.0001%，玩家只玩 1-2 主力 → 有效感知率被再除 10，其余 9 张是永远见不到的死内容 |
| 与升华效果的关系 | **正交**：卡只触发 `player.enable_sublime()`，10 份升华细节真源在 CharacterTable/player.gd（skills+meta 泳道），卡系统零感知 | 卡系统须维护 10 份卡定义/文案/过滤（无技能角色还得池内剔除） |
| fission | 单点处理（§3） | fission 卡要么剔除要么单独设计，复杂度翻倍 |
| 图鉴 | 1 条红卡图鉴位，清晰 | 10 条图鉴位，0.001% 下长期全灰（换角色才可能点亮） |
| 预热/黑市/挂机 | 每链路 1 份文案 | 每链路 ×10 |

**裁定：单卡通用。** 「卡的通用」与「效果的专属」（每角色各自的升华版）正交解耦——这是本设计最重要的结构决策：**卡系统只提供触发器，角色系统自解释升华后变成什么**（卡面描述动态读表，抽到时即显示当前角色的升华预告文案）。

### 2.4 D6 卡面渲染

- **类别行**：`KIND_NAMES` 追加 `"升华"`（card_select_ui.gd:23，第 7 位对应 kind 6）→ 类别行自动显示 **「升华 · 传说」**（:247-248 单源拼接，零额外改动）。类型圆章 `TextureFactory.type_icon` **必须加 kind 6 分支**（红环菱形/红圆章）——kind 5 无分支落灰菱形是 R185 登记的 P2 遗留前科，新卡别重蹈。
- **顶带**：`_setup_button` :236-238 走 `PopPalette.rarity_color(4)` 自动红（palette 扩档后 clamp 放行）——唯一通道 `_apply_band_color` 零改动。
- **圆珠**：预建 `range(4)` 扩 `range(5)`（card_select_ui.gd:478）→ `rarity=4` 显 **5 珠全红**（:303 显隐逻辑 `rarity+1` 零改动自动跟随；r212 `dots==rarity+1` 断言对 0..3 卡保持绿，红卡 5 珠由 r246 新断言锁）。
- **描述**：`compose_desc_text`（:491-512）单源——升华卡 `value_scale=1.0` 不触发品质尾行，描述自带「本局技能升级为升华版 · 爆率 0.001%（红色传说）」尾句；预热键=实拼键契约天然保持（R220 冻结不破）。
- **诅咒染名**（:264-269）不触发：升华卡 `cursed` 恒 false（§2.2 收紧后结构性保证）。

### 2.5 D6+D7 拾取即生效（本局语义）

`apply_choice` 追加分支（card_generator.gd:347-401 match 块）：

```gdscript
CardKind.SUBLIME:
    # R246 技能升华卡：拾取即生效（本局）；幂等；不落 Meta 存档（用户原话「本局技能升级为升华版」）
    if p_player != null and p_player.has_method(&"enable_sublime"):
        p_player.call(&"enable_sublime")
        EventBus.mechanics_intro.emit("红色传说 · 技能已升华！（本局有效）")   # 播报见 §5.3
        if Engine.is_editor() == false:
            DebugStats.count(&"sublime_card_chosen")
        # Meta.sublime_total += 1（局外纯统计，可选展示 §6；不走 Meta 存档构筑位）
```

- **本局语义**：`player.enable_sublime()` 置局内布尔 `sublime=true`；`activate_skill`（player.gd:822-865）在 match 分发前检查 `sublime` → 走升华版分发（**skills 泳道**实现 10 角色升华版；本文档只定接线契约：`Player.sublime: bool` + `enable_sublime() -> void` 幂等 + activate_skill 升华分支表 + 重置点随 `_reset_skill_temp_state`/`set_character`/重开清零）。**本局内已在增益窗中的普通版技能不中途切态——下次施放起生效**（实现最稳，无中途切态风险）。
- **幂等**：同局第二张（概率 1e-10）重复调用 `enable_sublime` 无害（布尔置位幂等），不做叠层补偿——设计克制。
- **死亡仲裁**：GameLoop E-16「死亡优先、GameOver 丢弃升级请求」对升华卡一视同仁，无特例。
- **手动玩家可以不选它**（三选一自由），挂机必选（§4 交互面 D8）。

---

## 3. fission（改造者·枢，无技能角色）处理

现状：fission 条目 `no_skill: true`（`repo/scripts/meta/character_table.gd:85`），`player.activate_skill` 入口早退（player.gd:826-827），HUD 技能键深置灰（hud.gd:285-296）。tracker #3 已派「fission 无技能角色出替代设计」给角色设计师——**替代升华的内容不在本卡系统职责内，本系统只保证管线正确**。

**D7 裁定（两态收敛）**：

1. **表有 `sublime_*` 键**（fission 设计师产物已合入 CharacterTable）：正常掷、正常上架。卡面描述动态读 fission 条目的 `sublime_desc`（显示替代升华文案，如「初始武器改造协议：……」——内容由该设计师定）；`apply_choice` 同一 SUBLIME 分支 → `enable_sublime()` 内对 `no_skill` 角色走 fission 替代分支（skills 泳道实现）。**单卡通用方案下 fission 与有技能角色共用同一张卡，仅文案与生效内容不同。**
2. **表无键**（集成窗口期/泳道未合）：掷中**转不上架**（generate_candidates ②步守卫直接跳过掷骰或掷中作废），杜绝「0.001% 抽到一张什么都不发生的破洞卡」。

判定函数（卡系统侧唯一 fission 感知点）：

```gdscript
func _sublime_available(p_player: Node) -> bool:
    # fission 替代升华的真源 = CharacterTable sublime_desc 键（角色设计师落表）；
    # 表无键 → 不掷（不出「抽了没反应」的卡）。有技能角色恒可用。
    if p_player == null: return false
    var ch := CharacterTable.get_character(StringName(String(p_player.get("character_id"))))
    return CharacterTable.has_skill(StringName(String(p_player.get("character_id")))) \
            or String(ch.get("sublime_desc", "")) != ""
```

（注意 GDScript 已知坑：`CharacterTable.get_character` 恒返回 Dictionary（兜底 CHARACTERS[0]，character_table.gd:101-105），无判空问题；`has_skill` 是 static（:112-115）。）

---

## 4. 遗物/保底/黑市/预热/挂机 交互面

| 链路 | 交互 | 处理 |
|---|---|---|
| REL_OVERCLOCK 稀有度保底 | `min_rarity_floor` 顶 `out[0]`（card_generator.gd:127-128，relic_handler 侧注入） | 插入时机天然豁免 + §2.2 显式 `continue` 防线；**保底永不顶穿红档**（顶穿=把 0.001% 变 100%，设计破洞，T3 锁死） |
| REL_WORDS_TIDE 重随 | `fixed_rarities` 逐位覆盖（:130-133） | 同上豁免：升华卡槽位不被覆盖、`rarity` 恒 4 |
| REL_GAMBLER 诅咒 | `curse_last` 打 `out[3]`（:135-136） | 收紧为仅 TRAIT 卡；升华卡永不带诅咒 |
| 金卡槽位替换 | `_slot_rng.randf()<0.05`（:97） | 插入在其后，天然不撞；且升华卡 `kind==SUBLIME` 本就不在 slot 替换的替换源判断内（:102 只查非 SLOT_BONUS 非 FALLBACK——实施时此行加 `and kind != SUBLIME` 双保险） |
| 黑市 | `_reroll_wares` 走 TRAIT 池 + `_roll_rarity`（shop_ui.gd:131）、`_make_trait_ware` 硬钳 0..3（:182） | **D9 不上架**：黑市 roll 源无 4、镜像逻辑零改动零分叉（R37/R188 黑市口径分叉前科同型风险直接消除）。0.001% 不进金币经济 |
| 卡面预热 | `enumerate_prewarm_variants` ③段固定文案卡（card_generator.gd:959-977，`_make_*` 零 rng 直调先例） | ③段追加：全角色 `sublime_desc` 非空条目逐条 `_emit_prewarm_variant`（每角色 1 条 + 兜底通用 1 条，至多 11 条变体，+2% 队列量级）；零 rng 契约保持（T9 断言 `rng.state` 前后不变）。红卡开窗预热 miss 至多 1 条/窗可忽略（诅咒卡同口径先例 card_select_ui.gd:497-498） |
| 挂机评分 | `score` clampi 0..3（auto_idle_strategy.gd:32） | **D8：`score` 首行加 `if int(p_card.get("kind",-1))==CardGenerator.CardKind.SUBLIME: return 998.0`**。998 > 一切非诅咒组合上限（rarity3×scale2.6+质变2 = 9.8）且与诅咒域（−999）不相交；`clampi` 本体不动（其他卡评分零漂移）。挂机永不跳过 0.001% 的升华卡（挂机静默损失最贵卡=用户无感最大伤害） |
| 挂机描金预选 | `highlight_candidate`（card_select_ui.gd:145-168） | D11：目标槽位卡 `rarity==4` 时跳过描色（红卡无需金提示） |

---

## 5. 显示层全清单

### 5.1 必改（ui 泳道）

| 文件:行 | 改动 |
|---|---|
| palette.gd:93-100 | `RARITY_SUBLIME := Color("ff2e63")` 新常量；`RARITY_COLORS` 追加；`RARITY_NAMES` 改 `[普通,稀有,史诗,辉煌,传说]` |
| card_select_ui.gd:23 | `KIND_NAMES` 追加 `"升华"`（第 7 位） |
| card_select_ui.gd:478 | 圆珠预建 `range(4)` → `range(5)` |
| card_select_ui.gd:145-168 | `highlight_candidate` 对 `rarity==4` 槽位跳过描色 |
| TextureFactory.type_icon | kind 6 分支（红圆章）——**勿重蹈 R185 kind5 灰菱形前科** |
| hud.gd:277-302 | 技能键 sublime 态：`player.get("sublime")` 读口（has_method 守卫，R186 同式）→ 图标 fg 红色描边/红环（`RARITY_SUBLIME`）；无技能角色置灰逻辑不动 |

### 5.2 概率文案露出位（任务要求「0.001% 传说」）

1. **卡面描述尾句**（主露出）：「本局技能升级为升华版 · 爆率 0.001%（红色传说）」——静态串写死在 `_make_sublime_card`，随卡面预热入缓存。
2. **图鉴/统计位**（可选，§6）。
3. 全仓无既有品级概率文案挂点（设计期 grep 核验：难度描述 `game_const.gd:368-373`「升级 5% 概率成对抉择」与 HUD 槽位 tooltip `hud.gd:1160` 是仅有的两处概率措辞静态串）——**不新增全局概率面板**，红卡概率只随卡面/统计露出，保持 0.001% 的「见过才知道」的传说感。

### 5.3 播报通道

抽到生效时二选一（ui 泳道定夺，推荐前者）：

- **优先**：`EventBus.mechanics_intro`（event_bus.gd:51，HUD 开局长 toast 横幅）——「红色传说 · 技能已升华！（本局有效）」；零新色彩角色、文本自带「红色传说」，R230「品质金」锁零触碰。
- **备选**（若要金色 toast 同款短提示）：`emit_trait_milestone` 通道（event_bus.gd:40/231，weapon_base.gd:283 先例）+ theme.gd `LabelRole` **末位追加** `SUBLIME` 角色 → 需同步 `test_r230_k4_hud_quant` 套件（互异/明度序断言含新角色）。

---

## 6. 图鉴/统计（可选，不强求）

- **局内遥测**：`DebugStats.count(&"sublime_card_chosen")`（§2.5 已含）+ `count(&"sublime_card_rolled")`（掷中未选也计——含「错过红卡」的黑洞遥测）。
- **局外统计**：`Meta.sublime_total: int`（跨局累计抽到并选用的次数，纯计数不参与构筑）。
- **图鉴条目**（后续可选）：红卡条目「技能升华 · 红色传说——爆率 0.001%」+ 累计次数 + 最近升华角色名。**不进首版验收**（tracker 未要求），接口预留即止。

---

## 7. 测试契约（r246 套件 + 回归清单）

新套件 `tests/runner/r246_sublime_cases.gd`（cases 体）+ `test_r246_sublime.gd`（-s 入口只 load cases 体——入口编译早于 autoload 的已知坑）。测试纪律：固定种子复现（pkg4 先例 seed 777/1234）；**勿靠真随机掷出 0.001%**——用 `_sublime_rng.seed` 定种使首掷必中/必不中两态，或直接构造 `rarity=4` 卡 dict 测显示层；勿 add_child 池化节点；`registry.get_trait` 返回值判空前勿 `:=` 强转下游调用。

| # | 断言 | 锚点 |
|---|---|---|
| T1 | 品质表：`RARITY_NAMES.size()==5`、`[4]=="传说"`、`[3]=="辉煌"`；`rarity_color(4)` 与 `ENEMY/ENEMY_DEEP` 互异；`rarity_color(5)/rarity_name(99)` clamp 安全 | palette.gd:99-100/118-124 |
| T2 | 掷率字面：`SUBLIME_CHANCE == 0.00001`；定种 `_sublime_rng` 首掷 <1e-5 态出卡、≥1e-5 态不出 | §2.2 |
| T3 | 豁免面：掷中批叠 `fixed_rarities=[3,3,3]`+`min_rarity_floor=3`+`curse_last`+slot_roll——升华卡 `rarity` 恒 4、`cursed` 恒 false、不被槽位卡替换 | §2.2/§4 |
| T4 | 替换规则：末位 FALLBACK（空注册表）/SLOT_BONUS 不被替换；全保底批不上架且不补偿 | §2.2 |
| T5 | apply_choice：stub player `enable_sublime` 调用计数==1；二次调用幂等（计数仍 1 或 player 侧布尔不变） | §2.5 |
| T6 | fission：no_skill+表无 `sublime_desc` → 掷中不上架；表有键 → 上架且描述含表文案 | §3 |
| T7 | 卡面：构造卡 dict 直测——类别行文本「升华 · 传说」、5 珠显隐（`dots==rarity+1` 扩展口径）、`compose_desc_text` 含「0.001%」且预热键=实拼键 | §2.4 |
| T8 | 挂机：`score(sublime卡)==998.0` > `score(金词条卡)`；`pick` 返回升华卡槽位；软排除清单不含升华卡 | §4 |
| T9 | 预热：`enumerate_prewarm_variants` 含升华文案变体（表有键角色各 1 + 通用兜底 1）；调用前后 `rng.state` 不变（零 rng 契约） | §4 |
| T10 | RNG 纪律：`_sublime_rng` 掷 100 批，主 `rng.state` 与 `_slot_rng.state` 不变（不扰动既有确定性序列——pkg4 分布锁的前置保证） | §2.2 |

**回归清单**（实施后全跑，headless exit 0）：`verify_feedback_cases`（R38/R60/R67/R68/R85 品质口径锁）、`pkg4_cases`（金 500 抽分布 :464-470、unlocked_slots=99 钉死 :25-26）、`r220_cardprewarm_cases`（4 档 scale 硬锁 :336-339——D3 不扩档应保持绿）、`r212_carddigest_cases`（dots==rarity+1 :165-178）、`qa_r220_mode`（本设计基线已跑 67/67 绿）、`market_supply_cases`、`test_r230_k4_hud_quant`（若动 theme LabelRole 才需同步）、`probe_r244_skill_stack`/`probe_r246_ranger_blink`（R246 Phase2 已修口径，skills 泳道改动后必跑）。

---

## 8. 明确不做 / 后续清理建议

- **不接线** `balance_tables.tres` 的 `rarity_weights`（僵尸镜像、validator `int()` 截断 data_validator.gd:409-412）——红档概率走代码常量 `SUBLIME_CHANCE`（与 `_roll_rarity` 硬编码同存态）。后续清理建议（独立工单）：rarity_weights 接线三源纪律或删僵尸键，与本设计解耦。
- **不做**保底/替代获取（每日首抽红卡券、成就解锁等）——tracker #6「❓用户裁定」，见 §9。
- **不做**红档词条（红品质永远只属于升华卡，§1.4 语义钉死）。
- **不动**金档任何数值/色值/稀有度顺序。

## 9. 开放问题（❓用户裁定）

1. **0.001% 长期体验**：纯字面 0.001%（期望 10 万批一遇，多数玩家终其游玩不见一张）是否需要保底/替代获取（如「累计 N 局未见→下一张必红」软保底、成就「红色时刻」补偿、结晶直购）？**当前设计=纯 0.001%，无任何保底**（tracker #6 标记用户裁定，未裁定前不实现）。
2. 金档改名「辉煌」的用户确认（若用户强烈认为金应保留「传说」名，回退方案=红档名改「神话」、`RARITY_NAMES=[普通,稀有,史诗,传说,神话]`、概率文案改「0.001% 神话」——单行反转即可，其余设计全部不变）。

---

## 附：实施泳道映射（与 R246 编排对齐）

| 泳道 | 文件 | 改动 |
|---|---|---|
| cards | card_generator.gd | CardKind.SUBLIME、`_sublime_rng`+`SUBLIME_CHANCE`、`_make_sublime_card`、`_sublime_available`、generate_candidates 尾段插入+三处豁免+curse_last 收紧、apply_choice 分支、enumerate_prewarm_variants ③追加、（实施注释 R246 编号） |
| ui | palette.gd / card_select_ui.gd / TextureFactory / hud.gd /（可选 theme.gd） | §5.1 清单 |
| skills | player.gd | `sublime: bool`、`enable_sublime()` 幂等（含 fission 替代分支）、`activate_skill` 升华分发、重置点清零、HUD 读口 |
| meta | character_table.gd / Meta | 10 角色 `sublime_name/sublime_desc/sublime_mech` 键（角色设计师产物）、`Meta.sublime_total` 计数 |

FEEDBACK_TRACKER 登记：本设计落地实施时在 tracker #2 行原地更新状态（绝不删行），代码注释 R246 编号随改随标。
