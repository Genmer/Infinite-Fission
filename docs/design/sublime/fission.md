# 改造者·枢（fission）· 技能升华设计 —— 「本命同调」

> R246 角色技能升华系统 · 10 角色并发设计之 fission 篇（FEEDBACK_TRACKER 二cr）。
> 设计师产物：本文档 = 数值真源提案 + 实现挂点 + 测试要点，交设计总监终审后拆泳道实施。
> 读者注意：fission 是全表唯一 `no_skill` 角色（character_table.gd:81-86），其「升华」不是
> 技能升级，而是**身份被动通道的升华**——本文替代设计依据任务书「fission 无技能，其升华 =
> 强化『自选武器』身份的替代设计」。
> **R246 终审修订（设计总监意见，原地更新）**：①**命名归一**——升华标志 `_sublime_on` / 入口
> `grant_sublime()` 归一为全体裁定字段 `skill_sublime: bool` + 统一入口 `enable_sublime() -> void`
> （卡契约 _card_system.md:191/:315 入口名不变；§3/§6.1/§6.2/§6.3/§6.4/§7 同步）；②**口径 B 溢出双砍**
> ——Ω-超频 12%→8%、即时糖 10%→8%，满层口径 B ×2.30→≈×2.18 回落 2.2 带内；口径 A 满层随即时糖
> 联动 ×1.96→×1.92（口径框架与 1.6~2.2 带内承诺不变，不追加独立砍削——即时糖为攻击乘区构成因子，
> 双砍与「演进表 ×1.96 相应下调」裁定下此为唯一自洽值，§2/§4/§5 同步）；③**暂停续档**——卡系统
> 已接 serialize_run 单键 `"sublime"`（game_loop.gd:2738），本设计读口对齐（§6.3）。
> **修订2 复核（原地精修）**：三条 fission 意见落实独立复核通过（双砍数学复算：1.08×1.65×1.08≈1.92、
> 1.92×1.08×1.05≈2.18 带内、演进表 100~500 层逐列吻合）；锚点抽验属实（player.gd:826-827/:697-704、
> game_loop.gd:2738/:2847/:2903/:2912-2915、weapon_base.gd:608-616/:630-643、run_save.gd:31-38、
> tests/runner r212_skillresume 套件实在；全仓 grep 无升华半拉子实施）。精修两处：①头部同步清单补
> §6.3；②§6.3 补 clampi 整型口径注（意见原文 clampf，防脏语义同）。noah.md SummonDrone 意见不属本文档。

---

## 1. 现状锚定（真源引用）

| 事实 | 出处 |
|---|---|
| 角色：改造者·枢，血 65 / 攻 +0%，`no_skill: true, cd: 120.0`（cd 键仅为测试断言保留） | character_table.gd:81-86，:80 注释「★ cd 键必须保留（tests/runner/verify_feedback_cases.gd 遍历全角色断言 cd==120）」 |
| 无技能契约：`activate_skill` 早退（不置 CD / 不发 skill_cast / 不计数） | player.gd:826-827 |
| `has_skill()` 读表 no_skill 键，与 CharacterTable.has_skill 同源 | player.gd:797-802；character_table.gd:112-115 |
| CDR 折算被动：养成 CDR / 技能急速池 / 时之沙作用于不存在的技能 → 按 **0.5 折算率**转全武器射速乘区，**帽 +30%**；`comp_rof_mult` 由 WeaponBase 消费 | player.gd:697-704；weapon_base.gd:608-616（:615-616 乘区合成） |
| 首发自定义：`Meta.custom_weapon()`（图鉴已解锁 ∪ W1 白名单，持久化）；开局仲裁 + 对账双保险 | game_loop.gd:1436-1452（`_starting_weapon_id` / `_equip_starting_weapon`）、:1455-1469（对账）；meta_manager.gd:195/:665-676 |
| HUD 门：无技能角色技能键整键深置灰、图标压暗、CD 文本清空、手动/自动施放链 has_skill 守卫 | hud.gd:277-302、:517-520、:547-553、:574-588 |
| 技能依赖遗物门：REL_ATTACK_CDR（每击谐振）对无技能角色**不上架**（计费口 `skill_cd_left<=0` 恒早退 = 金卡零收益） | mechanic_gate.gd:112-131 |
| 击杀广播：`EventBus.enemy_killed(enemy)` 含 tags（TAG_ELITE / TAG_BOSS / TAG_FINAL_BOSS） | autoload/event_bus.gd:19；enemy.gd:15（tags 字段）、:1078/:1082（is_boss/is_elite） |
| 击杀计数真源在 HUD（`hud.kills`，hud.gd:116/:465），并随局内存档持久化 | hud.gd:116、:465；game_loop.gd:2767（save_run 写 kills）、:2841（读档回填） |
| 武器攻击注入先例：player 侧重写 `weapon.meta_atk_pct = Meta.atk_pct() + character_atk_pct` 后 `_invalidate_panel()` | player.gd:509-529（add_weapon :521）、:626-630（set_character 动态注入）；weapon_base.gd:29（字段）、:374（`base_atk = get_current_atk() × (1+meta_atk_pct)` 入面板） |

**普通版战力构成**（改造者·枢）：
1. 自选首发 = 构筑自由度（提前 3~4 波成型，等效 DPS 优势约 +10~15%，估算口径）；
2. CDR 折算被动 = 极限投入（养成 CDR + 急速池 + 时之沙）时全武器射速 **+30% 封顶**，典型投入（时之沙 0.8 + 养成 10%）约 +14%；
3. 无技能的代价面：无爆发窗、无瞬发保命/控场——全表唯一「平A到死」角色。

---

## 2. 设计目标

1. **身份纯化而非补技能**：枢的立身之本是「我的技能就是我的武器」。升华不给主动技能（无技能契约 `no_skill` **不破**，HUD 置灰 / 遗物门 / skill_cast 链零回归面），而是把「自选武器」升格为**会成长的本命武装**——抽到升华卡的那一刻，你选的那把武器开始和你并肩变强。
2. **叠加型越打越强，贴在武器上**：任务方向参考「杀人书」——但通用模板（角色叠层加攻）不贴枢。枢的层数**只作用于本命武装**（开局自选那把），叠的是「武器与驾驶者的同调率」：改造者从每场战斗数据里持续改装自己的武器。
3. **成长的节拍感**：平滑小层数 + 每 100 层装载一件「Ω 改装件」（攻击/弹速/弹体/暴击/攻速五档）——呼应项目「满层质变」的既有语言（mechanic_gate.gd:71-74，milestone ×1.6），把一条枯燥曲线切成 5 个可感节点。
4. **晚抽不亏**：0.001% 爆率意味着多数抽取发生在局中后期。成长型机制最怕「晚抽 = 白板」——抽卡瞬间按本局已击杀数 **50% 追溯回填**层数。
5. **平衡约束**：本命武装**攻击乘区满层 ×1.92**（落于 1.6~2.2 区间中位偏上；终审双砍前 ×1.96，即时糖 10%→8% 为其构成因子故联动微降，见 §5.2）；新机制溢出（超频/质量件）已随终审双砍收敛：满层口径 B ≈×2.18 带内（§5.2 核算）。CD 无概念——例外理由见 §5.3。

---

## 3. 升华技能定义

| 项 | 内容 |
|---|---|
| 升华名 | **本命同调**（4 字） |
| 卡面描述（红·传说） | 「改造者·枢升华：本命武装觉醒。击杀叠加同调层（每层攻击 +0.13%，精英 ×3、Boss ×15），每 100 层装载一件 Ω 改装件，满层进入超频态；技能冷却折算率与射速帽提升（+30% → +45%）。抽到瞬间按已击杀数回填半数层数。」 |
| 类型 | **纯被动**（无主动段、无 CD、无 skill_cast、无演出窗） |
| 授予入口 | `Player.enable_sublime(p_ctx: Dictionary = {})` **统一入口**（R246 终审命名归一：10 角色统一 `enable_sublime()`，卡契约 _card_system.md:191/:315 不变——内部置 `skill_sublime=true` 并分发角色初始化；默认参兼容 cards 泳道 apply 钩子 `call(&"enable_sublime")` 无参调用；fission 分支消费 `p_ctx.backfill_kills` = `hud.kills`） |
| 本命武装判定 | 与首发仲裁同源：`Meta.custom_weapon()` → 兜底 W1（即 game_loop.gd:1436-1444 `_starting_weapon_id` 的返回值口径，**零改动复用**）；注入目标 = `weapon_slots` 中 `data.id` 等于该 id 的武器实例 |

---

## 4. 机制详解

### M1 本命同调层数（核心新机制 · 杀人书·贴武器版）

- **叠层**：任意来源击杀 +1 层（订阅 `EventBus.enemy_killed`，**不区分死因**——毒云/新星/弹丸击杀均算，改造者从战场数据学习，同时判定极简可测）；`TAG_ELITE` +3；`TAG_BOSS | TAG_FINAL_BOSS` +15（enemy.gd:15 tags 位判，不依赖 is_boss() 方法调用——探针用例可直接造 tags 字段）。
- **效果**：每层本命武装面板攻击 **+0.13%**（与 `meta_atk_pct` 同区合成，weapon_base.gd:374 消费口零新增）。
- **上限**：500 层 = **+65%**。
- **追溯回填**：抽卡瞬间 `_reson_layers = min(计(本局已击杀 × 0.5), 500)`——第 15 波（约 450 杀）抽到即 225 层起步（两件改装件已装载），晚抽即战力。

### M2 Ω 改装件（层数转化 · 成长节拍器）

每满 100 层自动装载一件，**只作用本命武装**；装载瞬间 `EventBus.emit_mechanics_intro` 横幅（复用 game_loop 玩法横幅通道，先例 player.gd:528 新武器首获横幅）：

| 档位 | 改装件 | 效果（本命武装） | 消费口 |
|---|---|---|---|
| 100 层 | Ω-弹匣 | 攻击 +8% | meta_atk_pct 同区 |
| 200 层 | Ω-推进 | 弹速 +8% | `_proj_spd_mult`（weapon_base.gd:630-635） |
| 300 层 | Ω-聚焦 | 弹体碰撞半径 +8% | `_proj_size_mult`（weapon_base.gd:637-643） |
| 400 层 | Ω-火控 | 暴击率 +5% | `build_panel_snapshot` 面板键（weapon_base.gd:359-386） |
| 500 层 | Ω-超频 | 攻速 +8%（独立乘区；终审双砍 12%→8%） | `_player_rof_mult` 尾乘（weapon_base.gd:608-616） |

### M3 CDR 折算强化（数值强化 · 既有身份被动升级）

`refresh_skill_cd`（player.gd:700-701）折算率 **0.5 → 0.65**、全武器射速帽 **+30% → +45%**：

| 投入情形 | 普通 comp_rof_mult | 升华 comp_rof_mult |
|---|---|---|
| 零 CDR 投入（基准） | ×1.00 | ×1.00（不变——折算只对已有 CDR 生效，不无中生有） |
| 典型（时之沙 0.8 + 养成 10%）：new/base = 0.72 | 1 + 0.28×0.5 = **×1.14** | 1 + 0.28×0.65 = **×1.182** |
| 极限（养成 + 急速池踩 0.1 地板 + 时之沙）：new/base ≈ 0.072 | 1 + min(0.464, 0.30) = **×1.30（帽）** | 1 + min(0.603, 0.45) = **×1.45（帽）** |

（数学地板约束不变：急速池因子 `maxf(1−池, 0.1)`、折算变化即时 `refresh_weapon_intervals`——player.gd:692/:702-704 既有逻辑零改动，只参数化两常量。）

### M4 抽卡即时糖（数值强化）

抽卡瞬间本命武装攻击 **+8%**（与 M1/M2-弹匣同区合成；终审双砍 10%→8%）——0.001% 传说卡的即时满足，无需等成长兑现。

### 不变项（契约面，回归断言点）

- `has_skill()` 恒 false → HUD 技能键仍置灰（hud.gd:277-302）、手动/自动施放链仍短路（hud.gd:547-553/:574-588）、REL_ATTACK_CDR 仍不上架（mechanic_gate.gd:122-129）。
- `activate_skill()` 仍于 :826-827 早退：不置 CD、不发 skill_cast、不计数 skill_used。
- character_table 的 `cd: 120.0` 键**不动**（verify_feedback_cases 全角色断言 cd==120）。

---

## 5. 数值对照表与平衡核算

### 5.1 普通 → 升华总对照

| 维度 | 普通版 | 升华版 | 倍率 |
|---|---|---|---|
| 主动技能 | 无（:826-827 短路） | 无（契约不破，纯被动系统） | — |
| 本命武装攻击乘区 | ×1.00（攻 +0%） | 即时 ×1.08 → 满层 ×1.92（1.08 即时糖 × 1.65 层数 × 1.08 弹匣） | **×1.92** |
| 本命武装弹速 / 弹体 | ×1.00 / ×1.00 | ×1.08 / ×1.08（Ω-推进 / Ω-聚焦） | — |
| 本命武装暴击率 | 基线 | +5%（Ω-火控） | — |
| 本命武装攻速 | ×1.00 | ×1.08（Ω-超频，满层解锁；终审 12%→8%） | — |
| CDR 折算率 / 射速帽 | 0.5 / +30% | 0.65 / +45% | 帽 ×1.5 |
| 追溯回填 | — | 已击杀 ×50% 即时折层 | — |
| cd 表键 | 120.0 | 120.0（**不动**） | — |

本命武装攻击乘区演进（抽卡时点按第 5 波 ≈ 120 杀回填 60 层起算；即时糖按终审 8%）：

| 层数 | 0（回填前） | 100 | 200 | 300 | 400 | 500（满） |
|---|---|---|---|---|---|---|
| 攻击乘区 | ×1.08 | ×1.32 | ×1.47 | ×1.62 | ×1.77 | **×1.92** |

### 5.2 战力倍率核算（两口径，诚实呈报）

- **口径 A（主承诺）·本命武装通道攻击乘区**：满层 **×1.92**（终审双砍前 ×1.96；即时糖 10%→8% 为攻击乘区构成因子，随双砍联动微降 ×1.96→×1.92——「演进表 ×1.96 相应下调」与「口径 B ≈2.2 带内」两项裁定下唯一自洽值；口径框架与 1.6~2.2 带内主承诺**不变**，不追加独立砍削），落于约束区间中位偏上；时间加权（第 5 波抽卡、第 15~17 波满层、20 波局）约 **×1.55~1.65**。
- **口径 B ·本命武装总输出峰值**（攻击 × 超频 × 质量件折算）：终审双砍后 ×1.92 × 1.08 × ~1.05 ≈ **×2.18**，回落至 2.2 上限带内（双砍前 ×1.96 × 1.12 × ~1.05 ≈ ×2.30 溢出；本节原预置刀口「优先砍 Ω-超频 12%→8%（单砍峰值 ×2.22 仍微溢）、次选即时糖 10%→8%」被终审**双砍全采**）；残余溢出面 = 质量/火控三件**新机制贡献**，仅在满层后（约局程 60% 起）存在，且需要 ~450 击杀的时间成本。
- **口径 C ·全角色总输出参考**：本命武装按占总输出 35% 计（玩家会围绕本命主动构筑），满层全角色总输出 ≈ ×1.38（双砍前 ×1.42，随口径 B 按同权重微降），时间加权 ≈ ×1.24~1.29。对照技能型角色（升华技能 ×1.6~2.2，对总输出贡献通常 +10~20%）：枢略高，对冲项 = 无爆发窗/无保命的普适代价 + 0.001% 传说定位 + 成长时间成本。**此口径不做承诺，仅供终审横评。**
- 校准依赖：满层时点按「20 波局 600~900 杀、第 15 波 ≈ 450 杀」估算（无实测曲线）——**QA 实测校准点**：若 20 波常规局中位击杀 < 450，则 500 层帽改 400 层（每层 +0.163%）保持 +65% 终值不变。

### 5.3 CD 基准例外说明

任务约束「CD 仍 120s 基准（有特殊理由可例外并说明）」——**枢例外：无 CD 概念**。理由：①`no_skill` 是角色契约（character_table.gd:77-85 注释明示 G1 机制组），升华新增主动技能将击穿 HUD 门（hud.gd:277-302）、自动施放链（:574-588）、遗物门（mechanic_gate.gd:122-129）与激活短路（player.gd:826-827）四处静态语义，回归面不成比例；②REL_ATTACK_CDR 的上架门读 `CharacterTable.has_skill(Meta.character_id)`（表静态真源），运行时翻转技能存在性会让「来源侧门」与「计费口」时序错位（卡池开局已定型，局中变有技能 = 已滤掉的卡无法追补）；③身份纯度：枢的卖点就是「不放技能」。表 `cd` 键 120.0 原样保留满足全角色断言。

---

## 6. 实现方案

### 6.1 挂点清单（player.gd 为主，skills 泳道）

| # | 挂点 | 改动 |
|---|---|---|
| 1 | player.gd:221-222（`_ready` EventBus 接线段） | 增 `EventBus.enemy_killed.connect(_on_enemy_killed_resonance)`（同款先例 :221/:222） |
| 2 | player.gd P2 常量区（:150-158 后） | 增升华常量块（§6.2 顶部）+ 统一标志 `skill_sublime`（10 角色归一字段名，HUD 红描边读口 `player.get("skill_sublime")`）/ 会话态字段 `_reson_layers` |
| 3 | player.gd:697-704 `refresh_skill_cd` 折算段 | 折算率/帽两常量参数化（`skill_sublime` 三目）——唯一既有函数改动，两行 |
| 4 | player.gd:626-630 `set_character` 注入循环（复用模式） | 新函数 `_apply_resonance()` 照此模式重写本命武器 `meta_atk_pct`；`set_character` 开头增升华态清口（换角/重开共用——respawn :1287 经此收口） |
| 5 | player.gd:826-827 `activate_skill` 短路 | **零改动**（回归断言锚） |
| 6 | player.gd:797-802 `has_skill` | **零改动**（契约锚） |
| 7 | game_loop.gd:1436-1452 | **零改动**（本命 id 仲裁同源复用 `_starting_weapon_id` 读口） |

跨泳道最小依赖（weapon_base.gd，4 读点各 +1 行，归属与实施泳道协商——建议随 skills 泳道一并出）：新增 `var extern_buffs: Dictionary = {}`（player 侧注入聚合面板，默认空 = 零位移，不影响其余 9 角色）：`_player_rof_mult` 尾乘 `(1+rof)`、`_proj_spd_mult`/`_proj_size_mult` 各尾乘、`build_panel_snapshot` 暴击键 `+crit`。

### 6.2 伪代码

```gdscript
# ── player.gd 升华段（R247：fission 本命同调——数值真源本文件 §4/§5；R246 终审：字段/入口命名归一 + 双砍）──
var skill_sublime := false            # 升华统一标志（10 角色归一裁定；HUD 红描边读口 player.get("skill_sublime")）
var _reson_layers := 0                  # 同调层 0..500
const SUBLIME_RESON_CAP := 500
const SUBLIME_RESON_PER_LAYER := 0.0013 # +0.13%/层
const SUBLIME_INSTANT_ATK := 0.08       # M4 即时糖（终审双砍 0.10→0.08）
const SUBLIME_BACKFILL := 0.5           # 追溯回填比
const SUBLIME_CDR_RATE := 0.65          # M3 折算率（普 0.5）
const SUBLIME_CDR_CAP := 0.45           # M3 射速帽（普 0.30）
const SUBLIME_MODPARTS := [             # M2 档位表（单一真源——UI 读口同源）
    {"at": 100, "id": &"mag",   "name": "Ω-弹匣", "atk": 0.08},
    {"at": 200, "id": &"thrust","name": "Ω-推进", "spd": 0.08},
    {"at": 300, "id": &"focus", "name": "Ω-聚焦", "size": 0.08},
    {"at": 400, "id": &"fc",    "name": "Ω-火控", "crit": 0.05},
    {"at": 500, "id": &"oc",    "name": "Ω-超频", "rof": 0.08},  # 终审双砍 0.12→0.08
]

func enable_sublime(p_ctx: Dictionary = {}) -> void:
    # 升华统一入口（R246 终审归一：卡契约 _card_system.md:191/:315 入口名/幂等不变，签名 -> void；
    # 默认参兼容 cards apply 钩子 call(&"enable_sublime") 无参调用。skills 泳道分发器内部置
    # skill_sublime=true 后按角色分发初始化——本函数体 = 其 fission 分支（其余 9 角色见各自设计）。
    # 非 fission / 已升华零副作用（原 grant_sublime 返回 bool 的幂等/拒绝语义内化为状态断言，见 §7-G4）
    if skill_sublime or character_id != &"fission":
        return
    skill_sublime = true
    _reson_layers = mini(int(round(float(p_ctx.get("backfill_kills", 0)) * SUBLIME_BACKFILL)),
        SUBLIME_RESON_CAP)
    _apply_resonance(-1)                # -1 = 静默（抽卡横幅归卡面，改装件横幅才走这里）
    refresh_skill_cd()                  # M3 折算参数变化即时重算（comp 变化内部自刷节拍 :702-704）
    # ※ R247 终修实现口径勘误（实现=player.gd:1473-1486，两处合理简化已实测等价）：
    # ① 签名零参——实现为 enable_sublime() 无参直调（卡契约 _card_system.md 零参调用一致），
    #   回填击杀源改 player 内部 run 作用域计数器 _reson_kill_count（hud.kills 语义等价：
    #   均为本局击杀，且不受存档回填污染）；② 取整口径 round()——奇数击杀进位（5 杀→3 层），
    #   本文初稿 int() 截断（5 杀→2 层）为准设计文档侧勘误，偶数击杀两口径无差。

func _on_enemy_killed_resonance(p_enemy: Node2D) -> void:
    # M1 叠层（EventBus.enemy_killed 订阅——_ready :221 同款接线；死因不区分）
    if not skill_sublime or _reson_layers >= SUBLIME_RESON_CAP:
        return
    var gained := 1
    var tags := int(p_enemy.get("tags"))
    if (tags & (GameConst.TAG_BOSS | GameConst.TAG_FINAL_BOSS)) != 0:
        gained = 15
    elif (tags & GameConst.TAG_ELITE) != 0:
        gained = 3
    var before := _reson_layers
    _reson_layers = mini(_reson_layers + gained, SUBLIME_RESON_CAP)
    _apply_resonance(before)            # before 传入 = 档位跨越检测用

func _reson_atk_extra() -> float:
    # 本命武装攻击加区（M4 + M1 + Ω-弹匣；非升华恒 0 = 其余角色零位移）
    if not skill_sublime:
        return 0.0
    var pct := SUBLIME_INSTANT_ATK + _reson_layers * SUBLIME_RESON_PER_LAYER
    for part in SUBLIME_MODPARTS:       # 攻击类档位走表（未来加档只改表）
        if _reson_layers >= int(part.at) and part.has("atk"):
            pct += float(part.atk)
    return pct

func _modpart_buffs() -> Dictionary:
    # 本命武装质量/攻速注入口（Ω-推进/聚焦/火控/超频；空表 = 零位移）
    var out := {}
    if skill_sublime:
        for part in SUBLIME_MODPARTS:
            if _reson_layers >= int(part.at):
                for key in [&"spd", &"size", &"crit", &"rof"]:
                    if part.has(key):
                        out[key] = float(out.get(key, 0.0)) + float(part[key])
    return out

func _apply_resonance(p_prev_layers: int) -> void:
    # 注入：遍历 weapon_slots，data.id == 本命 id（_starting_weapon_id 同源：custom_weapon 兜底 W1）
    var sig := _signature_weapon_id()
    var buffs := _modpart_buffs()
    var atk_extra := _reson_atk_extra()
    for w in weapon_slots:
        # ★守卫序：is_instance_valid 在前（freed 实例上后续取值报脚本错——:628 先例注释）
        if w == null or not is_instance_valid(w) or w.data == null:
            continue
        var mine := StringName(String(w.data.id)) == sig
        var target_pct := Meta.atk_pct() + character_atk_pct + (atk_extra if mine else 0.0)
        if not is_equal_approx(w.meta_atk_pct, target_pct):
            w.meta_atk_pct = target_pct            # 复用 :626-630 注入模式
            w._invalidate_panel()                  # 面板失效（weapon_base.gd:374 消费）
        var want_buffs := buffs if mine else {}
        if not is_equal_approx(float(w.extern_buffs.get(&"rof", 0.0)),
                float(want_buffs.get(&"rof", 0.0))):
            w.extern_buffs = want_buffs            # 质量/攻速注入口（weapon_base 4 读点消费）
            w.refresh_fire_interval()              # 攻速档跨越即时节拍刷新（R29 先例 :707-718）
    # 档位跨越横幅（装载瞬间一次性；回填 -1 静默口由 enable_sublime 控制是否播报改装件）
    if p_prev_layers >= 0:
        for part in SUBLIME_MODPARTS:
            if p_prev_layers < int(part.at) and _reson_layers >= int(part.at):
                EventBus.emit_mechanics_intro("【改装件装载】%s（本命武装 %s）"
                    % [part.name, _modpart_desc(part)])

func _signature_weapon_id() -> StringName:
    # 本命仲裁 = 首发仲裁同源（Meta.custom_weapon → 兜底 &"W1_pistol"；与
    # game_loop._starting_weapon_id :1436-1444 同口径，此处不依赖 registry——脏 id
    # 由 GameLoop 装备期兜底成 W1，局内 slot0 实际 id 即真相，故另加 slot0 活体优先）
    var s0: WeaponBase = weapon_slots[0] if weapon_slots.size() > 0 else null
    if s0 != null and is_instance_valid(s0) and s0.data != null:
        return StringName(String(s0.data.id))      # slot0 活体优先（对账双保险后必为本命）
    var saved := Meta.custom_weapon()
    return saved if saved != &"" else &"W1_pistol"

# refresh_skill_cd :700-701 改动（唯一既有行）：
#   var rate := SUBLIME_CDR_RATE if skill_sublime else 0.5
#   var cap  := SUBLIME_CDR_CAP   if skill_sublime else 0.30
#   var comp := 1.0 if has_skill() \
#       else 1.0 + minf((1.0 - new_base / maxf(base, 0.01)) * rate, cap)

# set_character 开头清口（换角/重开共用——respawn :1287 经此；继续局恢复序 = set_character
# 重建后由 _restore_run_state 幂等回填 enable_sublime()，先清后回无冲突，见 §6.3）：
#   skill_sublime = false; _reson_layers = 0
```

```gdscript
# ── weapon_base.gd 最小接线（4 读点各 +1 行；跨泳道依赖）──
var extern_buffs: Dictionary = {}   # player 侧注入口（升华本命专用；空 = 零位移）
# _player_rof_mult 尾部（:615-616 之后）：
#   return maxf(... * float(extern_buffs.get(&"rof", 0.0) + 1.0), 0.1)  # Ω-超频乘区
# _proj_spd_mult / _proj_size_mult（:630-643）各乘 (1.0 + extern_buffs[&"spd"/&"size"])
# build_panel_snapshot（:359-386）暴击键叠加 extern_buffs[&"crit"]
```

### 6.3 存档与读档口径（R246 终审闭环：卡系统已接单）

- **暂停→继续局不丢升华位**（终审必修·原「决策归卡系统」已由卡系统接单）：`serialize_run`（game_loop.gd:2738）新增单键 `"sublime": {on: bool, fission_layers: int}`（`on` 即 `skill_sublime` 序列化位）；继续局 `_restore_run_state`（game_loop.gd:2847）在 `set_character`（:2903）重建 player 后**幂等回填** `enable_sublime()`（fission 分支再经 `restore_resonance(d)` 按 `fission_layers` 恢复层数，`clampi(d.fission_layers, 0, SUBLIME_RESON_CAP)` 防旧档脏值——终审意见原文 clampf，层数为整型故取 clampi，防脏语义同）——先清（set_character 清口）后回（restore 回填），顺序幂等无冲突；**旧档无键零迁移**（`p_data.get("sublime", {})` 空字典自然短路）。往返保真断言由卡系统泳道 `r212_skillresume` 套件覆盖。
- 本设计读口对齐上述键结构：`resonance_snapshot() -> Dictionary`（返回 `{on: skill_sublime, fission_layers: _reson_layers}`，serialize_run 直接透传）与 `restore_resonance(d: Dictionary)`（幂等：仅 `skill_sublime == true` 时生效，clamp 后 `_apply_resonance(-1)` 重注入）。RunSave 扁平键值兼容（run_save.gd:31-38 直接透传）。
- 换武器卡（新增武器进槽）后需重注入：`add_weapon`（player.gd:509-529）尾部追加 `_apply_resonance(-1)` 一行——新装的本命第二实例（同 id 重复获取，理论不发生但防御）与被挤位武器均正确落位。

### 6.4 表现与 UI 建议（ui 泳道可选，非阻塞）

- HUD 技能键：升华后建议由「深置灰」改「Ω 金态常亮 + 层数角标」（读口 `player.resonance_layers()` / `resonance_ratio()`）——置灰语义（不可按）不变，只是从「没技能」变「武器即技能」的可视化；不改也零功能损失。**升华红描边读口全体归一**：`player.get("skill_sublime")`（10 角色统一字段名裁定；卡系统 §5.1 hud.gd 行同步改此读口，本字段即 hud.gd:277-302 技能键红描边的真源）。
- 本命武装悬浮化身金染（先例：诺亚僚机金色染色 player.gd R93 注释）、Ω 改装件装载横幅（机制已含）。

---

## 7. 测试要点（r246 套件建议：tests/runner/sublime_fission_cases.gd）

> 惯例：`-s` 入口只 load cases 体（入口编译早于 autoload）；探针勿 add_child 池化节点；武器断言用 WeaponBase 真件（pkg2 先例）；守卫序 is_instance_valid 在前。

| 组 | 用例 | 断言要点 |
|---|---|---|
| G1 契约不破 | 升华前后 `has_skill()` 恒 false；`activate_skill()` 恒 false；`skill_cd_left` 恒 0；无 `skill_cast` emit、`skill_used` 不计数 | player.gd:826-827 / :797-802 零回归 |
| G2 叠层 | 普通 Node2D（无 tags）+1；`tags=TAG_ELITE` +3；`tags=TAG_BOSS` +15；帽 500 不越；**未升华态零计数**（订阅常挂、旗标守卫） | EventBus.emit_enemy_killed 直发探针 |
| G3 注入 | 本命 id 武器 `build_panel_snapshot().base_atk` = 基础 ×(1+养成+角色+加区)；异 id 武器零注入；`extern_buffs` 在 200/300/400/500 层各含 spd/size/crit/rof 键；非本命武器 extern 恒空 | 加区合成序 = §6.2 `_reson_atk_extra` |
| G4 回填 | `enable_sublime({"backfill_kills": 600})` → 300 层；`1000` → 500 帽；重复调用幂等（层数不重置不叠加、`skill_sublime` 恒 true）；非 fission 角色调用零副作用（fission 分支守卫） | kills 真源 hud.kills 由 cards 泳道传入；原 grant 返回 bool 语义已按卡契约 `-> void` 内化为状态断言 |
| G5 CDR 折算 | 升华态造急速池：new/base=0.72 → comp ×1.182；极端投入钳 ×1.45 帽；普通态同投入 ×1.30 帽（基线回归）；折算变化后 `refresh_weapon_intervals` 已刷（节拍立即变） | refresh_skill_cd :697-704 参数化 |
| G6 攻速档 | 500 层时本命 `_fire_interval` ÷1.08（终审 12%→8%）；499 层无；档位跨越当帧节拍刷新（R29 语义） | weapon_base `_player_rof_mult` |
| G7 清口 | `set_character` 换角 → 层/旗清零、注入还原；`respawn()` 后同；G2~G6 全程无脚本错（守卫序） | respawn :1259-1294 |
| G8 回归 | 未升华 fission 与基线行为逐字节一致（comp 常量 0.5/0.30、无 extern 写入）；其余 9 角色零 extern_buffs 写入 | 全角色循环探针 |
| G9 续档往返 | `resonance_snapshot()` / `restore_resonance()` 键值保真（on / fission_layers）；恢复序 = `set_character` 后 `enable_sublime()` 幂等回填 + clampi 防旧档脏值；旧档无 `"sublime"` 键零迁移 | 卡系统泳道 `r212_skillresume` 套件覆盖该键往返保真（跨套件协调）；本套件只测两读口 |

---

## 8. 边界与已知限制

1. **满层时点为估算**（§5.2 校准依赖）：20 波局 600~900 杀无实测曲线，QA 需实测后定 500/400 层帽（终值 +65% 不变）。
2. **诺亚僚机 / W5 镜面交互**：同调注入只遍历 `weapon_slots`（诺亚副本 `_summon_copies` / 镜面 `_mirror_images` 不吃本命加成）——诺亚与枢互斥不可能同场，无实义；镜面若复刻本命武器，攻击面板按重推导时点快照（R187 既有语义），不随层实时刷新——**登记为已知行为**，不修。
3. **本命武器移除**：当前无武器移除/替换机制（卡只增不减），`_signature_weapon_id` 的 slot0 活体优先 + custom_weapon 兜底已覆盖空槽期（注入遍历自然空转）。
4. **REL_ATTACK_CDR 依然不上架**（升华后亦然）：无技能契约不破的推论——文档明示，防后续误报「升华了怎么还没有每击谐振」。
5. **FEEDBACK_TRACKER 登记**：本文档为设计师产物，R247 实施时由实施泳道按项目纪律登记（登记条目建议：fission 升华 = 替代设计·本命同调，CD 例外理由 §5.3）。
