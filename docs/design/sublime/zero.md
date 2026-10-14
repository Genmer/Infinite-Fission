# 演算者·零（zero）技能升华设计——「时滞奇点」

> R246 角色技能升华系统 · 设计师产物（10 角色并发设计之一）
> 真源：`scripts/meta/character_table.gd:46-52`（zero 条目：血 65 / 攻 +15% / 时滞力场 / cd 120）；
> 实现：`scripts/entities/player/player.gd`（activate_skill 分发 :848-849 / _skill_time_stop :721-733 / tick :256-269）；
> 消费端：`scripts/entities/enemy/enemy.gd:747-750` → `scripts/combat/elemental/elemental_state.gd:115-121`（get_speed_factor=0.0）。
> 状态：🎨 设计完成，待泳道实施（skills=player.gd 泳道）。
> R246 修订（总监意见·已并入）：升华标志命名归一（字段 `skill_sublime: bool` + 统一入口 `enable_sublime()`，§3.1/§3.6）；升华位续档保真契约（serialize_run `"sublime"` 键 + `_restore_run_state` 回填，§3.6/§4）。
> R246 修订2（核验·勘误）：引用锚点全量实测复核（player.gd :848-849/:721-733/:256-269/:605-625/:690-696/:809-819/:1281-1284、game_loop.gd :2738/:2903/:2912-2915、_card_system.md :191/:315、character_table.gd :46-52、r212_skillresume 套件在位）；勘误两处——§3.5 `_skill_fx_max` 多加一杀改读 `_ts_left`；§3.6「卡系统已接」改实测口径（_card_system.md 现文**未接**续档契约）。

---

## 1. 普通版盘点（现状）

**「时滞力场」**：全场敌人静止 2.5 秒（无视免疫），cd 120s。

| 环节 | 锚点 | 行为 |
|---|---|---|
| 激活 | `player.gd:848-849` | match `&"zero"` → `_skill_time_stop()`（瞬发，无持续态） |
| 主体 | `player.gd:721-733` | `query_circle(pos, 4096)`（超屏对角线≈1470px，即全场兜底）遍历在场敌 → **直写** `ElementalState.freeze_timer = 2.5`，**绕过 immune_mask**（角色终极无视免疫位）；`DebugStats.count(&"time_stop")` |
| 消费链 | `enemy.gd:747-750` → `elemental_state.gd:115-121` | tick 读 `elemental.get_speed_factor()`，freeze_timer>0 → 移速因子 0.0 |
| 计时衰减 | `elemental_state.gd:96` | `freeze_timer = maxf(freeze_timer − dt, 0)`（敌人侧重置无需玩家参与） |
| 常规冻结对照 | `elemental_system.gd:336-343`、`elemental_state.gd:254-270` | 元素通道冻结受 `IMMUNE_CHILL`/`IMMUNE_FREEZE` 双位门控、仅 1.2s——零的直写通道天然绕开两者，这是本技能的**签名** |
| CD | `player.gd:822-828`、`player.gd:690-696` | `skill_cd_left = skill_cd_base`；base = 表 cd 120 × 养成CDR × 技能急速池 × 时之沙 |
| 表现 | `player.gd:860-863`、`player.gd:868-882` | 瞬发 0.8s 施放闪光（`_skill_fx_duration` 落到 fallthrough :882）+ `emit_skill_cast` 金环 |
| 复位口 | `player.gd:620-623`（换角）、`player.gd:1281-1283`（重开，经 `_reset_skill_temp_state`:809） | 瞬发无持续态，现有两口已够 |

**冻结的真实边界（设计必须知道的三个细节）**：
1. **Boss 弹幕机全停摆**：`enemy.gd:1443-1448` `p_sf <= 0.0` 直接 return——前摇/冷却/跟射/螺旋全停。时滞对 Boss 是攻防双收的完整静止。
2. **普通远程兵仍可开火**：`enemy.gd:1172-1180` `fire_cd_left` 不乘 sf——冻结中的 RANGED 兵在射程内照常射击（只是不能逼近）。
3. **在途敌弹不受影响**：冻结只作用于敌人移速因子，已发射子弹照飞。

即：普通版 ≈ 2.5 秒「敌不动、Boss 哑火、我自由瞄准」的输出窗，而非绝对无敌。

**普通版战力口径**（全文统一用「**自由输出秒**」= 窗口时长 × 窗口内玩家输出效率，即"折合多打了多少秒满效火力"）：
> 2.5s × 1.0 = **2.5 当量秒**（CD 120s，局均时间占比 2.1%）。

**普通版机制本质**：一次**快照式**全场定身——施放瞬间给当时在场的每个敌人挂 2.5s 倒数，之后玩家与力场再无关系：窗口中不能续、不能延、新刷入的敌人不吃、玩家自身无任何增益。名字叫"力场"，实际是一发脉冲。升华版就是把「脉冲」做成真正的「场」，并让猎杀喂养时间本身。

---

## 2. 升华版设计：「时滞奇点」

### 2.1 身份贴合论证（非通用模板）

普通版的三个独有节拍，升华机制各咬住一个：

1. **时之收割（击杀延长）**——时停类技能的原生幻想就是「在静止的世界里收割，收割让世界更久地静止」：窗口内每击杀一名**仍处于凝滞**的敌人，静止延长 +0.15s（上限 +0.9s）。这不是通用"杀人书"叠攻击面板——层数不进任何属性池，只兑换成**本技能自己的持续时间**，且判定口径独一无二：读亡敌死亡瞬间的 `freeze_timer>0`（`enemy.gd:1085-1099` 派发时序保证 elemental 状态仍在，佐证 `elemental_system.gd:107` 注释）——"被我停住的时间杀死的东西，才是喂给时间的燃料"。
2. **力场成真（持续按压）**——把 `player.gd:727` 那次孤立的 query_circle 升级为 0.25s 节拍的**持续力场**：窗口未耗尽前，脉冲期间新刷入的敌人一并凝滞。普通版"施放后 1 秒刷出的潮你的技能就管不着了"的快照局限，正是"力场"二字该兑现而未兑现的部分；实现上还顺带让击杀延展只需递增玩家侧单一真值 `_ts_left`（脉冲负责把它压进每个敌人的 freeze_timer），无需逐敌补写。
3. **唯我演算（主观加速）**——演算者·零的角色叙事是"战术演算体"：世界停摆、唯我超频。窗口内玩家全武器射速 +20%（`rof_mult=1.2`，复用 veles/echo 的 `skill_active_left` 窗口节拍与 :266-269 既有到期复位口，零新还原代码）。幅度刻意压在 echo（+50%/5s）之下——它只是骑在时停窗上的风味增益，同时是喂养机制 ① 的油门（打得越快 → 凝滞击杀越多 → 时间越长）。

无视免疫签名保持：脉冲延续普通版的 `freeze_timer` 直写，`immune_mask` 全程不经手（`player.gd:722-723` 注释口径不变）。

角色身份对齐：零是「控场终局」定位（攻 +15%），升华全部投资在**控场时长与窗口内输出环境**，不掺毒、不掺召唤、不掺防御——三条强化线都长在"时间静止"这一根主干上。

### 2.2 数值对照表（普通 → 升华）

| 项 | 普通「时滞力场」 | 升华「时滞奇点」 |
|---|---|---|
| CD | 120s | **120s（不变，无例外）** |
| 冻结时长（基础） | 2.5s | **3.5s** |
| 生效方式 | 一次性快照脉冲（仅施放瞬间在场敌） | **持续力场**：0.25s 节拍按压全场至窗口耗尽，**脉冲期间新入场敌一并凝滞** |
| 击杀交互 | 无 | **每击杀一名「凝滞中」敌人 +0.15s，上限 +0.9s（6 杀）** |
| 单次最大时长 | 2.5s | **4.4s** |
| 玩家侧增益 | 无 | **窗口内全武器射速 +20%**（rof_mult 1.2，R29 开启即时缩在途冷却） |
| 无视冻结免疫 | 是 | **是（签名保持）** |
| Boss 弹幕停摆 | 是 | 是（消费端零改动，自动继承） |
| 自由输出秒（战力口径） | 2.5 × 1.0 = **2.5** | 3.5~4.4 × 1.2 = **4.2 ~ 5.28** |
| 战力比（对普通版） | 1× | **1.68×（零击杀/BOSS 单体）~ 2.11×（6 杀满额）** |

### 2.3 平衡推演（1.6~2.2× 约束达成）

- **下界（BOSS 单体、窗口内零击杀）**：3.5s × 1.2 = 4.2 当量秒 = **1.68×**。
- **上界（群怪波次、6 杀满额）**：4.4s × 1.2 = 5.28 当量秒 = **2.11×**。
- 全场景落位 [1.68, 2.11] ⊂ [1.6, 2.2]；典型局（窗口内 3~4 凝滞击杀）≈ 3.95~4.1s × 1.2 ≈ **1.9×**，中位给足。
- **口径说明（为何不用「敌·秒」）**：若按受控敌人数 × 秒数积分，力场覆盖新入场敌会使群怪比值显著高于上表（如 28 在场敌 × 4.4s ≈ 145 敌·秒 vs 普通 50 敌·秒 ≈ 2.9×）。但控场的边际价值随敌数急剧饱和——玩家 DPS 与注意力才是瓶颈，第 20 只凝滞杂兵与第 5 只带来的输出增益几乎相同，安全价值也随"窗内本就无威胁逼近"饱和。约束口径取玩家侧自由输出秒（与 veles 设计文档的"超额射速秒"同族口径，跨角色可比）。
- **成长期望**：+0.15s/杀 × 6 杀上限的软上限设计——杂兵潮轻松喂满（回报密度感），BOSS 战吃不满（下界仍达标）；击杀延长兑换的是时间而非面板，不会与其他乘区滚雪球。
- **CD 120s 保持**：全部收益内嵌于 ≤4.4s 窗口内，与 CD 周期无耦合；重施放时 `_ts_left` 必然已归零（4.4s ≪ 任何 CDR 折算后的 120s 基准），无叠加漏洞，无需特殊处理。
- **循环自洽性**：射速 +20% → 凝滞击杀更快 → 更快到 +0.9s 上限：正反馈链的终点被 6 杀硬上限钉死，不可 runaway。

### 2.4 与现有系统的正交性

- **veles/echo 的 rof_mult 共享通道**（`player.gd:834-836` / `:857-859`）：角色互斥（`character_id` 单选），同场必只有一家写 `rof_mult`；零升华复用同一条 `skill_active_left` 驱动 + :266-269 到期复位口，语义同构零分叉。
- **改造者·枢 CDR 折算**（`comp_rof_mult`，`player.gd:700-701`）：有技能角色恒 1.0，无关。
- **元素 ICE 冻结通道**（`elemental_state.gd:254-270` / `elemental_system.gd:336-343`）：同字段共存，脉冲用 `maxf` 压入不覆盖更长冻结；升华冻结同样点亮 `is_state_active(ICE)`（`elemental_state.gd:135` 含 freeze_timer）→ SYN_FROST_EXEC 族条件池在升华窗内吃满（协同增益，非冲突）。
- **点燃 DOT / 超导 / 绽放计时**：`elemental.tick` 不受 freeze 门控（冻结只拦移速因子），火毒构筑在静止窗内 DOT 照跳——既有协同，升华不改变其口径。
- **测试基线**：`verify_feedback_cases.gd` 遍历全角色断言 `cd==120`——升华不改 cd 键，零回归。
- **技能急速/时之沙/养成 CDR**（`player.gd:690-696`）：照常缩 CD，与本设计无耦合（CD 缩短提升升华出场频率，与普通版同比例受益，不破坏 1.6~2.2× 口径）。

---

## 3. 实现方案（skills=player.gd 泳道）

### 3.1 新增状态字段（player.gd 成员区，~:39 附近）

> R246 命名归一裁定（10 份角色文档统一）：字段名 `skill_sublime: bool`（多数派口径，本设计原名不变）+ 统一授予入口 `enable_sublime() -> void`（卡系统契约 `_card_system.md:191/:315` 不变——指调用方只认 `enable_sublime()` 入口；入口内部置 `skill_sublime=true` 并分发角色初始化含 fission 回填）；HUD 技能键红描边读口统一 `player.get("skill_sublime")`。修订2 核验注：卡系统文档现文滞后于裁定——`_card_system.md:191/:315` 字段仍写 `sublime: bool`、:249 HUD 读口仍写 `player.get("sublime")`，实施时以本裁定 `skill_sublime` 为准（卡系统文档同步属其泳道，防四泳道撞名返工）。

```gdscript
var skill_sublime: bool = false        # R246 升华位（enable_sublime() 内部置 true；本技能只读消费，不直写）
var _ts_left: float = 0.0              # 时滞奇点窗口剩余（玩家侧唯一真值；脉冲压进敌 freeze_timer）
var _ts_bonus: float = 0.0             # 击杀延展已积攒量（封顶账本）
var _ts_pulse_left: float = 0.0        # 距下一次力场按压剩余
const TS_WINDOW: float = 3.5           # 升华基础窗口时长
const TS_EXT_PER_KILL: float = 0.15    # 每次凝滞击杀延展量
const TS_EXT_MAX: float = 0.9          # 延展上限（6 杀）
const TS_PULSE_INTERVAL: float = 0.25  # 力场按压节拍
const TS_ROF: float = 1.2              # 唯我演算：窗口内射速乘区
```

### 3.2 激活分支改造（`player.gd:848-849`，activate_skill match `&"zero"`）

```gdscript
&"zero":
    if skill_sublime:
        _skill_time_stop_sublime()
    else:
        _skill_time_stop()             # ↓↓↓ 普通版原样保留 ↓↓↓
```

### 3.3 施放与力场按压（player.gd 新函数，紧邻 `_skill_time_stop`:721-733）

```gdscript
func _skill_time_stop_sublime() -> void:
    # R246 时滞奇点（演算者·零·升华）：持续力场 + 击杀延展 + 唯我演算
    _ts_left = TS_WINDOW
    _ts_bonus = 0.0
    _ts_pulse_left = 0.0                       # 本帧即首压（挂场即有反馈，vera 毒云 :899 同款）
    _timestop_pulse()
    rof_mult = TS_ROF                          # 唯我演算：复用 veles/echo 射速窗通道
    skill_active_left = TS_WINDOW              # 到期复位骑既有 :266-269 口（rof_mult 自动回 1.0）
    if not EventBus.enemy_killed.is_connected(_on_enemy_killed_timestop):
        EventBus.enemy_killed.connect(_on_enemy_killed_timestop)   # 先例：:221-222 连接口
    refresh_weapon_intervals()                 # R29：开启瞬间在途冷却立即按新节拍缩短
    DebugStats.count(&"time_stop_sublime")

func _timestop_pulse() -> void:
    # 力场按压：以玩家为心 4096 半径（全屏兜底，与 :727 同口径）把窗口剩余压进
    # freeze_timer——直写绕过 immune_mask（升华保持普通版「无视免疫」签名，:722-723 注释口径）
    var grid: Variant = _deps.get("enemy_grid")
    if grid == null:
        return
    for e in (grid as SpaceGrid).query_circle(global_position, 4096.0):
        if e == null or bool(e.get("dead")):
            continue
        var st: Variant = e.get("elemental")
        if st is ElementalState:
            (st as ElementalState).freeze_timer = \
                maxf((st as ElementalState).freeze_timer, _ts_left)
```

### 3.4 tick 节拍改造（`player.gd:256-269` 段，skill_cd_left 递减之后、skill_active_left 段之前插入）

```gdscript
# R246 时滞奇点：窗口推进 + 0.25s 力场按压（覆盖新入场敌）；窗口耗尽收口
if _ts_left > 0.0:
    _ts_left = maxf(_ts_left - p_game_delta, 0.0)
    _ts_pulse_left -= p_game_delta
    if _ts_pulse_left <= 0.0 and _ts_left > 0.0:
        _ts_pulse_left = TS_PULSE_INTERVAL
        _timestop_pulse()
    if _ts_left <= 0.0:
        _ts_left = 0.0
        _ts_bonus = 0.0
        if EventBus.enemy_killed.is_connected(_on_enemy_killed_timestop):
            EventBus.enemy_killed.disconnect(_on_enemy_killed_timestop)   # 窗外零监听
# ↓ 既有 skill_active_left 段（:266-269）原样保留：归零 → rof_mult=1.0，即唯我演算的到期复位 ↓
```

> 敌侧 freeze_timer 与 `_ts_left` 双轨倒数、脉冲 0.25s 对齐一次：窗外尾差 ≤ 0.25s（最后一拍多停 ≤ 一拍，体感无差，不另做收尾拍）。顿帧/暂停走 game_delta 通道，双轨天然同步。

### 3.5 击杀延展回调（player.gd 新函数）

```gdscript
func _on_enemy_killed_timestop(p_enemy: Node2D) -> void:
    # R246 时之收割：仅升华零的窗口内、击杀「死亡瞬间仍凝滞」的敌人才延展——
    # 派发时 elemental 状态仍在（enemy.gd:1085-1099 置序 + elemental_system.gd:107 注释佐证）
    if not skill_sublime or character_id != &"zero" or _ts_left <= 0.0:
        return
    var st: Variant = p_enemy.get("elemental")
    if st is ElementalState and (st as ElementalState).freeze_timer > 0.0 \
            and _ts_bonus < TS_EXT_MAX:
        _ts_bonus = minf(_ts_bonus + TS_EXT_PER_KILL, TS_EXT_MAX)
        _ts_left = minf(_ts_left + TS_EXT_PER_KILL, TS_WINDOW + TS_EXT_MAX)
        skill_active_left = maxf(skill_active_left, _ts_left)   # 射速窗随延展同步拉长
        _skill_fx_left = maxf(_skill_fx_left, TS_EXT_PER_KILL)  # （表现 polish）HUD 时长条随延展续命
        _skill_fx_max = maxf(_skill_fx_max, _ts_left)  # 修订2 勘误：_ts_left 上一行已含本次延展，再 +1 杀会虚高（满额 4.55≠4.4）
```

> 凝滞判定用 `freeze_timer > 0` 而非 `_ts_left > 0` 单条件：元素通道冻结（ICE 二次满槽/冰水反应，1.2s）恰落在升华窗内的亡敌同样算数——它在窗口内确实被"停住了"，口径自洽且无需区分冻结来源。

### 3.6 收尾改造

| 挂点 | 改动 |
|---|---|
| `_skill_fx_duration` zero 分支（`player.gd:868-882`，现走 fallthrough 0.8） | 升华改增益窗口型演出：match 内加 `&"zero": return TS_WINDOW if skill_sublime else 0.8`——HUD 时长条 + 光环倒数随窗口（延展续命见 3.5 polish 行） |
| `_reset_skill_temp_state`（`player.gd:809-819`） | 追加：`_ts_left=0.0`、`_ts_bonus=0.0`；若已连接则断开 `_on_enemy_killed_timestop`（换角/重开不残留监听）。该函数已被 `set_character`（:625）与重开复位（:1284）调用，`rof_mult=1.0` 复位两口（:623 / :1283）现成，零额外接线。`skill_sublime` 位本身按卡系统重置点契约同步清零（`_card_system.md:191`：随本函数/set_character/重开——skills 泳道统一实现，非本技能专属） |
| `skill_sublime` 授予（统一入口） | 升华卡系统（cards 泳道）抽中调 `player.enable_sublime()`（R246 归一：不再直写字段）——入口内部置 `skill_sublime=true` 并分发角色初始化；本技能只在 activate_skill zero 臂消费——卡落地前该位恒 false，全走原路径。HUD 技能键红描边（hud.gd 技能键 sublime 态，cards/ui 泳道）统一读 `player.get("skill_sublime")` |
| 升华位续档保真（game_loop 泳道；修订2 实测：卡系统文档**未接**） | 重置点清零契约与继续局恢复序冲突：`game_loop.gd` 继续局经 `set_character`（`repo/scripts/loop/game_loop.gd:2903`）重建后仅回填快照键（:2912-2915 R212 先例），run 存档无 sublime 键则 0.001% 抽到的升华在暂停续档后蒸发。修法：`serialize_run`（:2738）新增单键 `"sublime": {on: bool, fission_layers: int}`（本角色仅消费 `on`）；`_restore_run_state` 在 set_character 之后按 `on` 幂等回填 `enable_sublime()`（clampf 口径防脏档）；旧档无键零迁移；r212_skillresume 套件补该键往返保真断言。修订2 勘误注：`_card_system.md` 现文只有重置点清零契约（:191），全文无 serialize `"sublime"` 键内容——本行即 skills 侧契约口径，卡系统文档同步并入属其泳道必修项 |

**消费端零改动**：`enemy.gd` 移速因子（:747-750）、Boss 弹幕停摆（:1443-1448）、`elemental_state.gd` 冻结语义（:96/:115-121）全部按 `freeze_timer` 数值自动生效——升华只改这条数值的时间行为，不新增任何敌侧/元素侧代码路径。

### 3.7 性能与实现注意

- 力场按压 = 每 0.25s 一次 `query_circle(4096)` 遍历在场敌（只读写一个标量）：窗口 ≤4.4s → **每施放 ≤18 次查询**；对比 vera 毒云每 0.5s × 6s = 12 次且每敌新建 DamageContext（更重），量级同档、频率可忽略（120s 一次）。
- `enemy_killed` 每击杀一发：回调三条件短路（非升华局零监听、窗口外已断开）；连接/断开幂等（is_connected 守卫）。
- 无新节点、无新信号、无 per-frame 分配（脉冲复用 grid 迭代器，窗口内无数组构造）。
- 已知坑对齐：cases 体不直接引用 EventBus/ElementalState 编译期符号时走运行时 load；对敌断言先 `is_instance_valid`/`is` 再类型化赋值；测试敌用裸构造不 add_child 池化节点。

---

## 4. 测试要点（r246 套件，tests/runner/ 探针式）

> 惯例：`test_r246_zero_sublime.gd`（-s 入口，只 load cases 体）+ `r246_zero_sublime_cases.gd`；
> 入口脚本编译早于 autoload → cases 体不直接引用 EventBus 常量（运行时 load / 字符串路径）；断言前先 `is_instance_valid` 再类型化赋值；不 add_child 池化节点。

1. **激活分流**：`skill_sublime=false` → 原路径：grid 内敌 `freeze_timer==2.5`、`rof_mult==1.0`、`enemy_killed` 未连接；`enable_sublime()`（统一授予入口，勿直写字段）→ `skill_sublime==true` 且 `_ts_left==3.5`、在场敌 `freeze_timer==3.5`、`rof_mult==1.2`、已连接。
2. **免疫绕过保持**：置 `immune_mask = GameConst.IMMUNE_FREEZE` 的敌，升华脉冲后 `freeze_timer==3.5`（对照元素通道 1.2s 冻结会被拒——`elemental_system.gd:337` 口径反证）。
3. **新入场覆盖**：施放 0.3s 后构造非池化测试敌入 grid → 推进 tick 至下一拍（≤0.25s）后其 `freeze_timer>0`（普通版快照脉冲对同敌恒 0——反向断言）。
4. **击杀延展与封顶**：窗口内 `emit_enemy_killed(伪造敌， elemental.freeze_timer=0.5)`×N → `_ts_left = 3.5 + minf(N,6)*0.15`；第 7 杀不再加；`skill_active_left ≥ _ts_left`。
5. **非凝滞击杀不计**：亡敌 `freeze_timer==0`（窗外击杀/元素窗已尽）→ `_ts_left` 不变。
6. **窗口外击杀不计**：`_ts_left==0` 时 emit → 回调早退（断言监听已断开）。
7. **唯我演算窗**：施放后非池化测试武器 `_fire_interval()` 按 1.2 缩短（R29 在途冷却钳进新节拍）；推满 `_ts_left` 归零后下一 tick `rof_mult==1.0`（骑 :266-269 既有复位口）。
8. **脉冲节拍窗内敌 freeze 同步**：推 0.5s 后敌 `freeze_timer` 与 `_ts_left` 差 ≤ 0.25s（双轨对齐界）。
9. **CD 基线回归**：升华前后 `CharacterTable` zero 条目 `cd==120` 断言不变（`verify_feedback_cases.gd` 全角色口径继续通过）。
10. **换角/重开清口**：`_reset_skill_temp_state()` 后 `_ts_left==0`、`rof_mult==1.0`、`enemy_killed.is_connected(...)==false`。
11. **授予入口幂等与续档口径**：`enable_sublime()` 二次调用幂等（`skill_sublime` 位不变、无叠层副作用）；`_reset_skill_temp_state()`/`set_character` 后 `skill_sublime==false`（卡系统重置点契约）。升华位跨暂停续档的往返保真由 r212_skillresume 套件断言（game_loop 泳道：serialize_run `"sublime"` 键 ↔ `_restore_run_state` 于 set_character 之后回填 `enable_sublime()`、旧档无键零迁移），非本套件职责。
12. **门禁命令**：`android_export\Godot_v4.3-stable_win64.exe --headless --path repo -s tests/runner/test_r246_zero_sublime.gd`（exit 0 = 全过）+ 干净复跑一遍判红（集成冒烟惯例）。

---

## 5. 文案（卡面 / HUD）

- 升华技能名：**时滞奇点**
- 升华技能描述（选人界面 / 图鉴口径）：
  「全场时间凝滞 3.5 秒并形成持续力场——静止期间入场的敌人一并凝滞；期间每击杀一名凝滞之敌，静止延长 0.15 秒（至多 +0.9 秒）；静止中你的全武器射速 +20%。无视冻结免疫。」
- 升华卡获得 toast（cards 泳道统一文案位）：「技能升华：时滞力场 → 时滞奇点」
- 普通版描述保持：`character_table.gd` 的 `skill_desc` 不动（升华描述由升华卡系统/选人界面按 `skill_sublime` 位切换展示，属 cards/ui 泳道；HUD 技能键红描边读口统一 `player.get("skill_sublime")`，has_method 守卫口径——R246 归一裁定）。

## 6. 登记建议

- FEEDBACK_TRACKER.md「二cr」表格 #3 行下挂本文件路径（R246 设计师产物之一，实施拆入 skills=player.gd 泳道，配 r246_zero_sublime 套件）。
