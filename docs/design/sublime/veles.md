# 裂变者·薇拉（veles）技能升华设计——「临界过载」

> R246 角色技能升华系统 · 设计师产物（10 角色并发设计之一）
> 真源：`scripts/meta/character_table.gd:26-31`（veles 条目）；
> 实现：`scripts/entities/player/player.gd`（activate_skill 分发 / tick 增益节拍）；
> 消费端：`scripts/combat/weapon/weapon_base.gd`（_player_rof_mult / _fire_interval）。
> 状态：🎨 设计完成，待泳道实施（skills=player.gd 泳道）。
> R246-r 总监修订：①升华标志命名归一——本文档原即多数派 `skill_sublime`（零改名），补统一入口 `enable_sublime()` 对齐（§3.1/§5）；②暂停→继续局升华位不蒸发的恢复序归卡系统修订承接，本文档同步契约衔接（§3.5/§4）。
> R246-r2 复核细化：全文锚点已按现行代码逐行复核（character_table/player/weapon_base/hud/game_loop/tests/runner 全命中，零行号勘误；`scripts/` 零 `sublime` 命中，"待泳道实施"属实）；§3.5 补存档键结构 `"sublime": {on, fission_layers}` 与 clampf 回填口径；§3.1 补卡系统文档字段滞后警示（其 :191/:249/:315 现文仍 `sublime`，实施以裁定 `skill_sublime` 为准）。

---

## 1. 普通版盘点（现状）

**「过载咆哮」**：4 秒内全武器射速翻倍（cd 120s）。

| 环节 | 锚点 | 行为 |
|---|---|---|
| 激活 | `player.gd:833-836` | `rof_mult=2.0` + `skill_active_left=4.0` + `refresh_weapon_intervals()`（R29：开启瞬间在途冷却按新节拍立即缩短） |
| 到期还原 | `player.gd:266-270` | 计时归零 → `rof_mult=1.0` 硬复位 + refresh（变长不回罚） |
| 消费端 | `weapon_base.gd:608-616` | `_player_rof_mult() = rof_mult × map_rof_mult × comp_rof_mult`（地板 0.1） |
| 节拍 | `weapon_base.gd:646-660` | BALLISTIC：`1/(rof×mult)`；其余形态：`cd×(1−cdr)/mult`；`weapon_base.gd:220-225` 每次开火重取 `_fire_interval()` |
| 迟到缩CD | `weapon_base.gd:663-677` | R29：mult 变大便缩短在途冷却（`min(剩余×新/旧, 新)`）；变大时长不回罚 |
| 表现 | `player.gd:874-875`、`hud.gd:313` | `_skill_fx_duration` veles=4.0 → HUD 时长条 + 金弧光环倒数 |
| 复位口 | `player.gd:623`（换角）、`player.gd:1282-1284`（重开，经 `_reset_skill_temp_state`:809） | `rof_mult=1.0`、`skill_active_left=0` |

共享通道注意：echo「双生回响」复用同一 rof_mult 通道（`player.gd:857-859`），升华改动必须与其正交。

**普通版战力口径**（全文统一用「超额射速秒」= ∫(mult−1)dt，即"折合多打了多少秒基础火力"）：
> (2.0−1) × 4s = **4.0 当量秒**（对 CD 120s 的局均 DPS 贡献 ≈ +3.3%）。

**普通版机制本质**：一段**恒温**射速窗口——开即满档 2.0、关即瞬间跌回 1.0，硬开关、无过程。升华版就是把这条水平线改写成一条**热机曲线**。

---

## 2. 升华版设计：「临界过载」

### 2.1 身份贴合论证（非通用模板）

普通版的两个独有节拍：①开启瞬间 R29 即时缩冷却（"立刻见效"）；②到期硬复位（"瞬间熄火"）。升华机制各咬住一个：

1. **渐增过载（爬坡）**——作用于窗口内 `rof_mult` 的**时间曲线**本身：从 2.0 线性爬升到 3.2，配合 R29 通道在途冷却即时缩短，得到「越打越快、火力滚雪球」的正反馈。这不是给面板白值加叠层，而是把原技能"开即满档"的方波改成热机斜坡——只有射速窗口型技能才成立的强化方向。
2. **余热层（击杀转化 + 渐冷软着陆）**——作用于原技能特有的**到期还原节拍**（`player.gd:266-270`）：窗口内每次击杀积攒 1 层余热；到期不再硬复位到 1.0，而是从 `1.0 + 4%×层数` 起**逐层降温**。「杀人书」方向在这里落地，但层数不进面板、不跨 CD 周期，只软化本技能自己的收尾口——过载完不是断电，是散热。

角色身份对齐：veles 高攻脆皮（血 45 / 攻 +25%），机制奖励窗口期内激进输出、奖励清杂效率，不提供任何防御补偿——输出特化的纯粹强化。

### 2.2 数值对照表（普通 → 升华）

| 项 | 普通「过载咆哮」 | 升华「临界过载」 |
|---|---|---|
| CD | 120s | **120s（不变，无例外）** |
| 窗口时长 | 4s | **5s** |
| rof_mult 曲线 | 恒 2.0 | **2.0 → 3.2 线性爬升**（0.25s/档，共 20 档） |
| 窗口平均 mult | 2.0 | ≈2.6 |
| 窗口峰值 mult | 2.0 | 3.2 |
| 到期行为 | 硬复位 `rof_mult=1.0` | **余热软着陆**：`1.0 + 4%×层数`，此后每 1.2s 掉 1 层 |
| 击杀交互 | 无 | **窗口内每次击杀 +1 余热层，上限 5 层** |
| 即时生效（R29） | 开启瞬间缩在途冷却 | 爬坡**每档**触发一次 R29 缩短（全程"立刻见效"） |
| 超额射速秒（核心窗口） | 4.0 | (2.6−1)×5 = **8.0** |
| 超额射速秒（余热，满层） | — | 4%×(5+4+3+2+1)×1.2s = **+0.72** |
| 战力比（对普通版） | 1× | **2.0×（0 击杀 / BOSS 单体）～ 2.18×（满 5 层）** |

### 2.3 平衡推演（1.6~2.2× 约束达成）

- **下界（BOSS 单体、窗口内零击杀）**：余热 0 层，纯核心窗口 8.0 当量秒 = 普通版 2.0×。
- **上界（群怪波次、满 5 层）**：8.0 + 0.72 = 8.72 当量秒 ≈ **2.18×**。
- 全场景落位 [2.0, 2.18] ⊂ [1.6, 2.2]：传说品质给足"峰值 3.2× 射速"的体感，账面不越界。
- 积分口径说明：伤害率 ∝ mult，超额当量 = ∫(mult−1)dt 为纯时间积分，与"射速高时发射更密"无关（已在时间轴内加权），线性平均口径即精确值。
- CD 120s 保持：机制收益全部内嵌于窗口及 ≤6s 的余热尾迹，与 CD 周期无耦合（余热最长 6s ≪ 任何 CDR 折算后的 CD，重施放时置 `_heat_stacks=0` 兜底，无叠加漏洞）。

### 2.4 与现有系统的正交性

- **echo 双生回响**（`player.gd:857-859`）：走 `skill_sublime==false` 的原路径（恒 1.5 / 5s / 硬复位），互不干扰。
- **改造者·枢 CDR 折算**（`comp_rof_mult`）：有技能角色恒 1.0（`player.gd:700-701`），与升华无交叠。
- **地图祝福狂热**（`map_rof_mult`）：消费端乘区照常叠乘（`weapon_base.gd:615-616`），升华只改 `rof_mult` 自身曲线。
- **测试基线**：`verify_feedback_cases.gd` 遍历全角色断言 `cd==120`——升华不改 cd 键，零回归。

---

## 3. 实现方案（skills=player.gd 泳道）

### 3.1 新增状态字段（player.gd 成员区，~:34 附近）

```gdscript
var skill_sublime: bool = false        # R246 升华位（命名归一口径：全 10 角色统一 skill_sublime，HUD 读口统一 player.get("skill_sublime")；仅由统一入口 enable_sublime() 置 true，本技能只读不写）
var _overload_ramp_t: float = 0.0      # 升华窗口爬坡累计时间（与 skill_active_left 解耦推进）
var _heat_stacks: int = 0              # 余热层（窗口内击杀积累，到期后逐层冷却）
var _heat_drop_left: float = 0.0       # 距下一次掉层剩余
const SUBLIME_WINDOW: float = 5.0      # 升华窗口时长
const SUBLIME_ROF_START: float = 2.0   # 爬坡起点（= 普通版恒温值）
const SUBLIME_ROF_PEAK: float = 3.2    # 爬坡峰值
const SUBLIME_RAMP_STEP: float = 0.25  # 爬坡步长（20 档；档间才 refresh，避免帧级 R29 调用）
const HEAT_STACK_MAX: int = 5          # 余热层上限
const HEAT_STACK_PCT: float = 0.04     # 每层余热射速增益
const HEAT_DROP_INTERVAL: float = 1.2  # 掉层间隔（满层冷却尾迹 6s）
```

**统一入口对齐（R246-r 命名归一裁定）**：升华位授予统一走卡契约入口 `enable_sublime() -> void`（`_card_system.md:191/:315`，skills 泳道一次实现、10 角色共用）：内部置 `skill_sublime=true` 并分发角色初始化（含 fission 回填）——卡系统/存档侧不再直写字段。veles 无额外初始化需求：爬坡/余热全部状态在 activate_skill 施放时惰性归零（§3.2 前 4 行），授予时机早晚零影响；HUD 技能键红描边读口统一 `player.get("skill_sublime")`。（核验注：卡系统文档现文滞后于裁定——`_card_system.md:191` 字段仍写 `Player.sublime: bool`、:249 HUD 读口仍写 `player.get("sublime")`、:315 泳道表仍列 `sublime: bool`，实施时以本裁定 `skill_sublime` 为准；卡文档同步属卡系统泳道修订项，防四泳道照旧字段名实现撞名返工。）

### 3.2 激活分支改造（`player.gd:833-836`，activate_skill match &"veles"）

```gdscript
&"veles":
    if skill_sublime:
        # 临界过载：5s 窗口，rof_mult 由 2.0 线性爬升至 3.2；击杀计余热层
        _overload_ramp_t = 0.0
        rof_mult = SUBLIME_ROF_START
        skill_active_left = SUBLIME_WINDOW
        _heat_stacks = 0                       # 重施放兜底清层（防极端 CDR 下跨周期残留）
        _heat_drop_left = 0.0
        if not EventBus.enemy_killed.is_connected(_on_enemy_killed_overload):
            EventBus.enemy_killed.connect(_on_enemy_killed_overload)   # 先例：:221-222 槽位/结晶事件同款连接口
        refresh_weapon_intervals()
    else:
        rof_mult = 2.0                          # ↓↓↓ 普通版三行原样保留（echo 共用通道不动）↓↓↓
        skill_active_left = 4.0
        refresh_weapon_intervals()
```

### 3.3 tick 增益节拍改造（`player.gd:266-270` 段）

```gdscript
if skill_active_left > 0.0:
    skill_active_left = maxf(skill_active_left - p_game_delta, 0.0)
    # R246 升华·临界过载：窗口内爬坡（0.25s 一档；档间 refresh 触发 R29 在途冷却缩短）
    if skill_sublime and character_id == &"veles":
        _overload_ramp_t += p_game_delta
        var step := int(_overload_ramp_t / SUBLIME_RAMP_STEP)
        var target := lerpf(SUBLIME_ROF_START, SUBLIME_ROF_PEAK,
                clampf(float(step) * SUBLIME_RAMP_STEP / SUBLIME_WINDOW, 0.0, 1.0))
        if not is_equal_approx(target, rof_mult):
            rof_mult = target
            refresh_weapon_intervals()          # 变短方向：在途冷却立即缩短（越打越快体感核心）
    if skill_active_left <= 0.0:
        if skill_sublime and character_id == &"veles" and _heat_stacks > 0:
            rof_mult = 1.0 + _heat_stacks * HEAT_STACK_PCT   # 余热软着陆（替硬复位）
            _heat_drop_left = HEAT_DROP_INTERVAL
            _overload_ramp_t = 0.0
        else:
            rof_mult = 1.0
        refresh_weapon_intervals()   # R29：过载到期登记新基准（节拍变长不回罚）——原注释保留
# R246 余热渐冷（窗口结束后的独立段，紧随其后）
elif skill_sublime and character_id == &"veles" and _heat_stacks > 0:
    _heat_drop_left -= p_game_delta
    if _heat_drop_left <= 0.0:
        _heat_stacks -= 1
        rof_mult = 1.0 + _heat_stacks * HEAT_STACK_PCT
        refresh_weapon_intervals()   # 掉层 = mult 变小 → R29 契约变长不回罚，在途冷却原样保留
        _heat_drop_left = HEAT_DROP_INTERVAL
```

### 3.4 击杀计层回调（player.gd 新函数）

```gdscript
func _on_enemy_killed_overload(_enemy: Node2D) -> void:
    # R246 临界过载·余热计层：仅升华 veles 的窗口内击杀计层（僚机/毒云等玩家侧输出同算）
    if skill_sublime and character_id == &"veles" and skill_active_left > 0.0:
        _heat_stacks = mini(_heat_stacks + 1, HEAT_STACK_MAX)
```

### 3.5 收尾改造

| 挂点 | 改动 |
|---|---|
| `_skill_fx_duration` veles 分支（`player.gd:874-875`） | `return 5.0 if skill_sublime else 4.0`——HUD 时长条与金弧倒数自动同步 5s |
| `_reset_skill_temp_state`（`player.gd:809-819`） | 追加：`_heat_stacks=0`、`_heat_drop_left=0.0`、`_overload_ramp_t=0.0`；若 `EventBus.enemy_killed.is_connected(_on_enemy_killed_overload)` 则断开（换角/重开不残留监听）。该函数已被 `set_character`（:625）与重开复位（:1284）调用，rof_mult=1.0 复位两口（:623 / :1283）现成，零额外接线。**skill_sublime 本身不在本清单**：其重置点清零属卡契约基础位（`_card_system.md:191`，skills 泳道一次实现）；暂停→继续局的升华位不蒸发由卡系统修订承接——serialize_run（`game_loop.gd:2738`，现键含 `skill_cd` 尚无 `sublime`）新增单键 `"sublime": {on: bool, fission_layers: int}`（veles 仅消费 `on`；`fission_layers` 为枢升华层数回填位，键结构由卡系统统一定）、_restore_run_state 在 set_character 之后 clampf/幂等回填 `enable_sublime()`（R212 skill_cd 同款恢复序，`game_loop.gd:2911-2915`；旧档无键零迁移）。续档重建经 set_character 清 veles 临时态与既有口径一致（skill_active_left 同不入快照，窗口中暂停=窗口作废），enable_sublime() 重放后下次施放全量重置，veles 侧零额外接线 |

**消费端零改动**：`weapon_base.gd` 的 `_player_rof_mult`（:608-616）、`_fire_interval`（:646-660）、tick 开火重取节拍（:220-225）、R29 迟到缩CD（:663-677）全部按 `rof_mult` 数值自动生效——升华只改这条数值的时间曲线，不新增任何武器侧代码路径。

### 3.6 性能与实现注意

- 爬坡 0.25s 一档（20 档/窗口），档间才 `refresh_weapon_intervals()`（O(武器数+僚机+镜面) 的乘除）：整窗 ≤20 次刷新，与现有启停 2 次同量级；且 `weapon_base.gd:224` 开火时本就重取 `_fire_interval()`，refresh 只为"在途冷却立即缩短"的即时手感，不做也仅损失手感不损失数值。
- `enemy_killed` 每击杀一发，回调体三个布尔短路（非升华角色恒零开销）；连接/断开幂等（is_connected 守卫）。
- 余热掉层方向是 mult 变小（interval 变长），R29 契约天然不回罚（`weapon_base.gd:675` 仅 `new_interval < _last_interval` 才缩）——无需新增防回罚代码。

---

## 4. 测试要点（r246 套件，tests/runner/ 探针式）

> 惯例：`test_r246_veles_sublime.gd`（-s 入口，只 load cases 体）+ `r246_veles_sublime_cases.gd`；
> 入口脚本编译早于 autoload → cases 体不直接引用 EventBus 常量（用 `Engine.get_singleton`/字符串路径或运行时 load）；断言前先 `is_instance_valid` 再类型化赋值；不 add_child 池化节点。

1. **激活分流**：置 `skill_sublime=true` + `character_id=&"veles"` → `activate_skill()` 后 `skill_active_left==5.0`、`rof_mult==2.0`、`EventBus.enemy_killed` 已连接；`skill_sublime=false` 走原路径（4.0 / 2.0）。
2. **爬坡曲线**：模拟 tick 累计 2.5s → `rof_mult≈2.6`（lerp 中点，档位离散误差 ≤0.04）；累计 5s+ → `rof_mult==3.2` 封顶不再涨。
3. **R29 联动**：挂一把非池化测试武器（先例：r187/qa_r220 套件的裸 WeaponBase 构造法），窗口中期断言其 `cooldown_left ≤ _fire_interval()`（档间 refresh 后在途冷却被钳进新节拍）。
4. **余热计层与软着陆**：窗口内 `EventBus.emit_enemy_killed(伪造 Node2D)`×N → 到期 tick 后 `rof_mult == 1.0 + minf(N,5)*0.04`；继续推 1.2s×k 掉 k 层；推满 6s 后 `rof_mult==1.0`、`_heat_stacks==0`。
5. **不回罚反向断言**：余热掉层瞬间（mult 变小），武器在途 `cooldown_left` 不被拉长（原值保留）。
6. **换角/重开清口**：`_reset_skill_temp_state()` 后 `_heat_stacks==0`、`rof_mult==1.0`、`enemy_killed.is_connected(...)==false`（skill_sublime 的清零与续档往返保真断言归卡系统 r212_skillresume 套件补 `"sublime": {on, fission_layers}` 键往返保真用例，r246 不重复断言——避免依赖基础位实现时序）。
7. **echo 回归**：echo 激活（1.5 / 5s / 硬复位）到期后 `rof_mult==1.0` 且无余热残留——共享通道正交性。
8. **cd 基线回归**：`verify_feedback_cases.gd` 全角色 `cd==120` 断言继续通过（升华不动 cd 键）。
9. **门禁命令**：`android_export\Godot_v4.3-stable_win64.exe --headless --path repo -s tests/runner/test_r246_veles_sublime.gd`（exit 0 = 全过）+ 干净复跑一遍判红（集成冒烟惯例）。

---

## 5. 文案（卡面 / HUD）

- 升华技能名：**临界过载**
- 升华技能描述（选人界面 / 图鉴口径）：
  「5 秒内全武器射速由 2 倍持续爬升至 3.2 倍，越战越猛；窗口内每次击杀积攒 1 层余热（至多 5 层），结束后火力不再骤停，以每层 +4% 射速逐层冷却、缓缓熄炉。」
- 普通版描述保持：`character_table.gd` 的 `skill_desc` 不动（升华描述由升华卡系统/选人界面按 `skill_sublime` 位切换展示，HUD/卡面读口统一 `player.get("skill_sublime")`，属 cards/ui 泳道）。

## 6. 登记建议

- FEEDBACK_TRACKER.md「二cr」表格 #3 行下挂本文件路径（R246 设计师产物之一，实施拆入 skills=player.gd 泳道，配 r246_veles_sublime 套件）。
