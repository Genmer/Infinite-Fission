# 回响·伊可 —— 技能升华设计（红色传说 buff 卡「技能升华」联动）

> 状态：设计稿（数值/机制/实现挂点/测试要点）｜角色：echo（回响·伊可）｜2026-10-08
> 修订：2026-10-08 总监裁定——升华标志命名归一（`sublime_skill` → `skill_sublime`，统一入口 `enable_sublime()`，入口契约 `_card_system.md:191/:315`）+ 对齐暂停续档「升华位随档恢复」统一键口径（§5 挂点 9/10、§8）
> 真源：`scripts/meta/character_table.gd:90`（echo 条目）；实现主体 `scripts/entities/player/player.gd`

---

## 1. 角色与普通版技能现状

### 1.1 角色真源（character_table.gd:87-97）

| 键 | 值 |
|---|---|
| id / name | `&"echo"` / 回响·伊可 |
| 定位 | 随机武装体（血 55 / 攻 +0%），开局随机双武器 |
| `random_dual` | `true` —— GameLoop 开局随机双武器注入（有技能角色） |
| 解锁 | `unlock_hard_clear`（任意地图困难/地狱通关） |
| 技能 | 双生回响：5 秒内全武器射速 +50% |
| CD | 120s |

### 1.2 普通版实现锚点（已核实）

| 锚点 | 位置 | 现状 |
|---|---|---|
| 技能分发 | `player.gd:856-859`（`activate_skill()` 的 `&"echo"` 分支） | `rof_mult=1.5`、`skill_active_left=5.0`、`refresh_weapon_intervals()`（复用 veles 射速窗通道） |
| 窗口到期 | `player.gd:266-270`（`tick()`） | `skill_active_left` 递减，到期 `rof_mult=1.0` + `refresh_weapon_intervals()` |
| fx 时长 | `player.gd:880-881`（`_skill_fx_duration()` echo 分支） | 恒 5.0（HUD 时长条 + 金弧倒数） |
| 临时态收口 | `player.gd:809-819`（`_reset_skill_temp_state()`，换角/重开共用） | 毒云清零 + 僚机还原；不含射速窗（respawn `player.gd:1282-1283` 另置 `skill_active_left=0`、`rof_mult=1.0`） |
| 射速消费端 | `scripts/combat/weapon/weapon_base.gd:608-616`（`_player_rof_mult()`） | `rof_mult × map_rof_mult × comp_rof_mult`，`_fire_interval()`（646）消费；含僚机/镜面同口径刷新（`player.gd:707`） |
| 双武器注入 | `scripts/loop/game_loop.gd:1472-1515`（`_grant_random_dual_loadout()`） | 门内池−W1、有放回×2（P(同款)≈1/9）、每日种子确定性、池空兜底双 W1；调用点 `game_loop.gd:1569`（start_run）与 `game_loop.gd:3467-3468`（restart_run 重 roll） |

**普通版特点提炼**（升华设计必须贴着的骨架）：
1. **回响是一次性的**——5s 固定窗口，声音响起又戛然而止，无叠层无延续；
2. **「双生」在技能名里、机制里却没有**——技能本体与「开局随机双武器」身份零交互；
3. 复用 veles 通道，是纯数值窗（无任何专属机制）。

---

## 2. 升华版设计总览

| 项 | 内容 |
|---|---|
| 技能名 | **无尽回响** |
| 一句话 | 主窗射速更强，窗口内每击杀激起一层「回声」，主窗结束后化作渐弱余韵绵延——回声不灭，只是衰减；双武器同款异款各有一条高光路线 |
| CD | **120s 不变**（无特殊例外理由：击杀叠层的收益上限已被余韵系数钳住，不需要动 CD 做平衡） |
| 战力定位 | 单次施放期望增量 ≈ 普通版 **1.6~2.2 倍**（场景测算见 §4.3） |

### 2.1 设计意图（为什么是这三个机制）

「回响」的物理直觉是：**每一次撞击激起新的回声，回声在源消逝后渐弱绵延**。普通版只表达了「声音变大」（射速 +50%），升华版把「回声」补完：

- **撞击激起回声** → 窗口内击杀叠层（「杀人书」方向，但强度只微增、主要转化进余韵——贴合射速窗本体，不是通用攻击叠层）；
- **回声渐弱而非戛然而止** → 主窗结束进入半强度余韵（区别于 veles 纯窗的「到期即断」）；
- **双生终于有了「生」** → 施放时按当前双武器快照分流两条路线，让 `random_dual` 的随机结果（P(同款)=1/9）从「构筑随机性」升格为「技能高光时刻」——同款低概率高起点，异款保底长余韵。

---

## 3. 新机制详述

### 3.1 机制一「回声叠响」（击杀叠层 · 层数转化）

- 生效区间：**仅主窗内**（`skill_active_left > 0`）。余韵期击杀不再叠层。
- 每击杀 1 名敌人（任意死因，走 `EventBus.enemy_killed` 唯一广播）叠 1 层「回声」，**上限 6 层**（弹幕海/毒云波护栏）。
- 每层主窗射速 **+2%**（`rof_mult +0.02`，满 6 层主窗合计 ×1.92——仅异款路线享受，见 3.3）。

### 3.2 机制二「渐弱余韵」（层数转化 · 渐退而非渐增）

- 触发：主窗 `skill_active_left` 归零瞬间，不直接落回 `rof_mult=1.0`，而是进入余韵态。
- 余韵强度：**`rof_mult = 1.35`（+35%，约主窗增幅的一半）**，随余韵结束才归 1.0。
- 余韵时长：**0.5s × 层数**（异款「双声部」0.6s × 层数），**上限 3.0s / 3.6s**。
- 层数在主窗结束瞬间快照锁定，余韵中不再变化。
- 节拍纪律沿用 R29：主窗→余韵、余韵→结束两次换挡均调 `refresh_weapon_intervals()`（升挡立即缩短当前武器倒计时；降挡「节拍变长不回罚」同款口径）。

### 3.3 机制三「双生和弦」（双武器身份路线分流）

施放瞬间（`activate_skill()` echo 升华分支内）读取 `weapon_slots[0]` / `weapon_slots[1]` 的 `data.id` 快照，二选一分流，**本次施放内不变**：

| 双武器形态 | 路线名 | 规则 |
|---|---|---|
| 同 id（双持同款，含开局 1/9 或后期合成） | **同频共振** | 主窗基础 `rof_mult = 1.90`（+90%）固定，**不吃**每层 +2% 主窗增益（「起点即共振，无需渐强」）；叠层照常、余韵效率 0.5s/层（上限 3.0s） |
| 异 id（默认形态） | **双声部长吟** | 主窗基础 `rof_mult = 1.80`（+80%）+ 每层 +2%；余韵效率 **0.6s/层**（上限 3.6s，「双声部回声更绵长」） |
| 单武器兜底（第二槽为空/被清） | 按双声部处理 | 不额外补偿（双武器是 echo 的契约身份，空槽本身是异常态） |

施放时以开场横幅同款通道（`EventBus.emit_mechanics_intro`，`player.gd:528` 先例）播报「同频共振！」，给低概率随机构筑一个可感知的高光瞬间。

---

## 4. 数值对照与平衡论证

### 4.1 普通 → 升华数值对照表

| 项 | 普通版·双生回响 | 升华版·无尽回响 |
|---|---|---|
| 主窗时长 | 5.0s | 5.0s（不变） |
| 主窗基础射速 | ×1.50（+50%） | 异款 ×1.80（+80%）／同款 ×1.90（+90%） |
| 击杀叠层 | — | +1 层/杀，上限 6 层（仅主窗内） |
| 层数·主窗增益 | — | +2%/层（仅异款；满层 ×1.92） |
| 余韵 | — | ×1.35（+35%），0.5s/层（异款 0.6s/层），上限 3.0s / 3.6s |
| CD | 120s | 120s（不变） |
| fx 时长 | 5.0s | 主窗 5.0s + 余韵实际秒数（余韵段弧线渐暗，见 §6） |
| 单次施放期望增量* | 2.5 DPS·s | 4.0 ~ 5.6 DPS·s |

\* 期望增量 = Σ(窗口内 DPS 加成 × 时间)，以基线 DPS=1 计；普通版 = 5s × 0.5。

### 4.2 新增常量（建议登记 player.gd 顶部常量区）

```gdscript
# ★升华·无尽回响（echo sublime）——数值真源
const ECHO_SUBLIME_MULT_HETERO := 1.80   # 双声部·主窗基础射速
const ECHO_SUBLIME_MULT_HOMO := 1.90     # 同频共振·主窗基础射速
const ECHO_SUBLIME_PER_STACK := 0.02     # 每层主窗增益（仅双声部）
const ECHO_SUBLIME_STACK_CAP := 6        # 回声层上限（清屏波护栏）
const ECHO_SUBLIME_AFTERGLOW_MULT := 1.35  # 余韵射速（主窗增幅之半）
const ECHO_SUBLIME_AFTERGLOW_PER := 0.5    # 余韵 s/层（同频共振）
const ECHO_SUBLIME_AFTERGLOW_PER_HETERO := 0.6  # 余韵 s/层（双声部）
const ECHO_SUBLIME_AFTERGLOW_CAP := 3.0    # 余韵时长上限（双声部 3.6）
```

### 4.3 场景测算（平衡自证）

击杀节奏假设：Boss 波 5s 内 0~1 杀；混合波 ~4 杀；清屏小怪波 6+ 杀（封顶）。

| 场景 | 普通增量 | 升华增量（异款） | 升华增量（同款） | 倍率（异/同） |
|---|---|---|---|---|
| Boss 战（0 杀） | 2.5 | 5 × 0.80 = 4.00 | 5 × 0.90 = 4.50 | **1.60× / 1.80×** |
| Boss 战（1 杀） | 2.5 | 4.02（余韵 0.5s×0.35=0.18） | 4.68 | 1.61× / 1.87× |
| 混合波（4 杀，层均匀累积） | 2.5 | 主窗均益 ~0.84×5=4.20 + 余韵 2.4s×0.35=0.84 → 5.04 | 4.50 + 2.0s×0.35=0.70 → 5.20 | **2.02× / 2.08×** |
| 清屏波（≥6 杀封顶） | 2.5 | 主窗均益 ~0.86×5=4.30 + 余韵 3.6s×0.35=1.26 → 5.56 | 4.50 + 3.0s×0.35=1.05 → 5.55 | **2.22× / 2.22×** |

- 期望落点（按场景频率加权）≈ **1.9~2.1×**，区间中段；
- 2.22× 仅出现在「满层顺风局」，是上限而非期望（「≈1.6~2.2」的 ≈ 容差内；同款开局 P≈1/9 本身是低概率高光，保这个辨识度）；
- 下限 1.60×（零击杀 Boss 战）恰在区间下沿——**杀人书机制的预算自调关键**：击杀层不放大主窗强度（每层仅 +2%），而是转化为「半强度余韵时长」（0.5~0.6s/层、硬上限 3.0/3.6s），总增量天花板 4.0+1.6≈5.6 DPS·s 被常量钳死，不会随弹幕海失控。
- 全程 DPS 口径（120s CD）：普通 +2.1% 平均、升华 +3.3~4.7% 平均，均属「技能对齐爆发」型收益，不侵蚀走位/构筑价值。

---

## 5. 实现挂点（implAnchors）

全部挂点均已读码核实：

1. **`player.gd:829 activate_skill()` → `&"echo"` 分支（856-859）**——升华开关分流：置 `rof_mult`（异 1.80+层增起点 / 同 1.90）、`skill_active_left=5.0`、`_echo_stacks=0`、双生和弦 id 快照、`refresh_weapon_intervals()`；同频共振播报 `EventBus.emit_mechanics_intro("同频共振！…")`。
2. **`player.gd:266-270 tick()` 技能窗到期段**——echo 升华改道：主窗归零 → `_echo_enter_afterglow()`（而非直接 `rof_mult=1.0`）；紧随其后新增 `elif _echo_afterglow_left > 0.0` 递减段，余韵归零才 `rof_mult=1.0` + `refresh_weapon_intervals()`。
3. **`player.gd:221-222 _ready()` EventBus 订阅区**——新增 `EventBus.enemy_killed.connect(_on_echo_kill_stack)`（player 侧订阅先例：slot_unlocked / crystal_shield_request；信号真源 `autoload/event_bus.gd:19`，唯一发点 `enemy.gd:1099`，零改动直接订阅）。
4. **`player.gd:707 refresh_weapon_intervals()`**——余韵两次换挡直接复用（已含僚机/镜面同口径）。
5. **`player.gd:809 _reset_skill_temp_state()`**（换角/重开共用）——新增清 `_echo_stacks`、`_echo_afterglow_left`（rof 归 1 已由 respawn `player.gd:1282-1283` 覆盖，此处双保险）。
6. **`player.gd:868-882 _skill_fx_duration()` echo 分支**——主窗段返回 5.0 不变；余韵段在 `_echo_enter_afterglow()` 内重置 `_skill_fx_left/_skill_fx_max`（HUD 时长条 + 光环倒数无缝续接，`skill_active_ratio()` 消费口零改动）。
7. **`scripts/combat/weapon/weapon_base.gd:608-616 _player_rof_mult()`**——射速消费端零改动（升华只写 `player.rof_mult` 一个乘区位，验证探针从此处读终值）。
8. **`scripts/loop/game_loop.gd:1472 _grant_random_dual_loadout()`（调用点 1569 / 3467-3468）**——注入逻辑零改动；「双生和弦」快照消费其产物（weapon_slots），文档关联锚点（随机双武器 = 和弦分流的输入源）。
9. **升华开关位**：`player.gd` 新增 `var skill_sublime: bool = false`（**命名归一**：全体角色文档统一字段 `skill_sublime`，多数派口径；统一入口 `enable_sublime() -> void` 幂等——入口契约沿用卡系统 `_card_system.md:191/:315`，该文档现行字段 `Player.sublime` 随本裁定同步归一为 `skill_sublime`，属卡系统泳道修订项，echo 侧只认 `skill_sublime` 勿读别名）——「技能升华」卡生效回调（GameLoop 卡牌侧）改调 `enable_sublime()`（内部置 `skill_sublime=true` 并分发各角色升华初始化，含 fission 回填；echo 侧分发无额外初始化：`enemy_killed` 订阅常驻 `_ready`，运行期守卫判位即可），**不再各自直写布尔**；`set_character`（`player.gd:620-623` 附近复位区）随角色切换清 false（重置点契约不变）。各分支以 `skill_sublime and character_id == &"echo"` 为守卫，**非升华 echo / veles 走原路径零回归**。
10. **升华位续档恢复（卡系统统一键，echo 侧零私有改动）**：暂停续档经 `set_character`（`game_loop.gd:2903`）重建后仅回填快照键（R212 `skill_cd` clampf 回填实证段 `:2911-2915`——先清后回恢复序的既有先例），升华位若不入档则 0.001% 抽到即蒸发——按卡系统修法统一承载：`serialize_run`（`game_loop.gd:2738`）新增单键 `"sublime": {on: bool, fission_layers: int}`；`_restore_run_state` 在 `set_character` 之后 clampf/幂等回填 `enable_sublime()`（R212 `skill_cd` 同款恢复序与防脏档口径，旧档无键零迁移；fission 泳道已按同一键口径对齐，`fission.md` §6.3「先清后回无冲突」）。echo 的 `_echo_stacks` / `_echo_afterglow_left` 为窗内临时态，随 `_reset_skill_temp_state` 清零即正确，**不入档**；`"sublime"` 键往返保真断言归 `r212_skillresume` 套件（卡系统泳道），echo 套件不重复。

### 5.1 新增状态字段（player.gd 成员区，`skill_active_left` 声明附近）

```gdscript
var skill_sublime: bool = false         # 技能升华卡·本局生效位（enable_sublime() 置位，换角清；命名归一口径，见挂点 9）
var _echo_stacks: int = 0                # 回声层（仅主窗内叠，余韵锁定）
var _echo_afterglow_left: float = 0.0    # 渐弱余韵剩余
var _echo_chord_homo: bool = false       # 双生和弦快照：true=同频共振（同 id）
```

### 5.2 伪代码

```gdscript
# ── activate_skill() &"echo" 分支改造（player.gd:856）──
&"echo":
    if skill_sublime:
        # 双生和弦：施放瞬间快照武器 id（第二槽空 → 按异款兜底）
        var ids: Array[String] = []
        for i in range(2):
            var w = weapon_slots[i] if i < weapon_slots.size() else null
            ids.append(String(w.data.id) if w != null and is_instance_valid(w) and w.data != null else "")
        _echo_chord_homo = ids[0] != "" and ids[0] == ids[1]
        _echo_stacks = 0
        rof_mult = ECHO_SUBLIME_MULT_HOMO if _echo_chord_homo else ECHO_SUBLIME_MULT_HETERO
        if _echo_chord_homo:
            EventBus.emit_mechanics_intro("【同频共振】双生回响·同款共鸣：射速 +90%！")
    else:
        rof_mult = 1.5                    # 原路径（零回归）
    skill_active_left = 5.0
    refresh_weapon_intervals()

# ── tick() 窗口段改造（player.gd:266-270）──
if skill_active_left > 0.0:
    skill_active_left = maxf(skill_active_left - p_game_delta, 0.0)
    if skill_active_left <= 0.0:
        if skill_sublime and character_id == &"echo" and _echo_stacks > 0:
            _echo_enter_afterglow()       # 有层 → 渐弱余韵
        else:
            rof_mult = 1.0                # 原路径（含 veles / 零层升华）
            refresh_weapon_intervals()
elif _echo_afterglow_left > 0.0:          # 新增段：余韵递减
    _echo_afterglow_left = maxf(_echo_afterglow_left - p_game_delta, 0.0)
    if _echo_afterglow_left <= 0.0:
        _echo_stacks = 0
        rof_mult = 1.0
        refresh_weapon_intervals()        # R29：降挡「节拍变长不回罚」同款

# ── 新函数 ──
func _echo_enter_afterglow() -> void:
    var per := ECHO_SUBLIME_AFTERGLOW_PER_HETERO if not _echo_chord_homo \
        else ECHO_SUBLIME_AFTERGLOW_PER
    var cap := ECHO_SUBLIME_AFTERGLOW_CAP + (0.6 if not _echo_chord_homo else 0.0)
    _echo_afterglow_left = minf(float(_echo_stacks) * per, cap)
    rof_mult = ECHO_SUBLIME_AFTERGLOW_MULT
    refresh_weapon_intervals()            # R29：换挡立即生效
    _skill_fx_left = _echo_afterglow_left # fx 续接（比率读口零改动）
    _skill_fx_max = maxf(_echo_afterglow_left, 0.01)

func _on_echo_kill_stack(_e: Node2D) -> void:   # EventBus.enemy_killed 订阅
    if not (skill_sublime and character_id == &"echo"):
        return
    if skill_active_left <= 0.0 or _echo_stacks >= ECHO_SUBLIME_STACK_CAP:
        return                              # 仅主窗内叠；余韵期/封顶短路
    _echo_stacks += 1
    if not _echo_chord_homo:                # 双声部：层微增主窗（同频共振不吃）
        rof_mult = minf(rof_mult + ECHO_SUBLIME_PER_STACK,
            ECHO_SUBLIME_MULT_HETERO + ECHO_SUBLIME_PER_STACK * ECHO_SUBLIME_STACK_CAP)
        refresh_weapon_intervals()          # 层数变化的瞬间节拍同步

# ── _reset_skill_temp_state() 追加（player.gd:809，换角/重开共用）──
_echo_stacks = 0
_echo_afterglow_left = 0.0
```

---

## 6. 表现层要点（轻量）

- 余韵段光环/时长条沿用 `skill_active_ratio()` 比例倒数，仅 `_draw` 内按 `_echo_afterglow_left > 0` 切换弧色（金 → 暗金渐暗），表达「回声渐弱」；
- 同频共振播报走 `EventBus.emit_mechanics_intro`（`player.gd:528` 新武器横幅同通道）；
- 击杀叠层可复用 `DebugStats.count(&"echo_stack")`（`player.gd:864` skill_used 同款调试计数）；
- HUD 技能键红描边（升华指示）统一读 `player.get("skill_sublime")`（hud.gd，全体角色同口——命名归一后勿读任何私有别名；hud.gd 现无任何升华读口，接线属 ui 泳道，本条即其唯一读口约定）。

## 7. 测试要点（tests/runner/ 探针套件）

按项目惯例 SceneTree 探针式（`-s` 入口只 load cases 体，勿在入口引用 autoload；勿 add_child 池化节点）。建议套件 `tests/runner/verify_echo_sublime_cases.gd`：

1. **分档基础值**：构造 player 置 `skill_sublime=true`（或调 `enable_sublime()`）、注入异款/同款双武器 → `activate_skill()` 后 `rof_mult` 分别 1.80 / 1.90；`skill_sublime=false` 时仍 1.5（零回归）。
2. **叠层与封顶**：主窗内连发 `EventBus.emit_enemy_killed(null)`（或探针敌节点）×8 → `_echo_stacks == 6`；异款 `rof_mult` 封顶 1.92，同款恒 1.90。
3. **余韵进入与时长**：主窗 tick 至归零 → `rof_mult == 1.35`、`_echo_afterglow_left == min(0.5|0.6 × 层数, 3.0|3.6)`；零层时直接归 1.0。
4. **余韵结束还原**：余韵 tick 至归零 → `rof_mult == 1.0` 且武器 `refresh_fire_interval` 被调（节拍还原）。
5. **换挡即时性**（R29 口径）：余韵进入/结束当帧，武器 `_fire_interval()` 读值随 `rof_mult` 同步变化。
6. **收口**：`_reset_skill_temp_state()` / `respawn()` 后层与余韵清零；换角色后 `skill_sublime=false` 且 veles 通道（`rof_mult=2.0`、4s 窗）不受污染。
7. **CD 契约**：升华版施放后 `skill_cd_left == 120.0`（`tests/runner/verify_feedback_cases.gd` 全角色 cd==120 断言继续通过）。
8. 运行命令：`E:\Code\Agent\Infinite-Fission\android_export\Godot_v4.3-stable_win64.exe --headless --path E:\Code\Agent\Infinite-Fission\repo -s tests/runner/verify_echo_sublime_cases.gd`（exit 0 = 全过）。

## 8. 边界与已知风险

- **层与余韵的跨施放残留**：新施放入口 `_echo_stacks=0`、余韵中再施放（CD 120s 下不可能，但防御性）会重置余韵计时——伪代码已覆盖；
- **`_skill_fx_max` 为 0 保护**：`skill_active_ratio()` 已有 `<= 0` 短路（`player.gd:887-889`），余韵 0 层不进余韵分支，无除零路径；
- **kill 信号参数为 Node2D**（`autoload/event_bus.gd:19`），订阅函数签名须 `(_e: Node2D)`（探针发 null 时同签名兼容）；
- **双生和弦快照时序**：须在 `_grant_random_dual_loadout`（`game_loop.gd:1569` start_run 调用）完成装备后施放才有效——开局瞬间（波次 1 前玩家点技能）槽位已就位，无竞态；restart_run（3467-3468）重 roll 后同理。
- **升华位暂停续档蒸发（总监修订对齐项）**：继续局经 `set_character` 重建后仅回填快照键，run_save 无 sublime 键则抽到的升华直接丢失——已按卡系统统一修法对齐（`serialize_run` `"sublime"` 单键 + `_restore_run_state` 在 set_character 之后幂等回填 `enable_sublime()`，详见 §5 挂点 10）；echo 侧无私有持久化字段，无额外风险面。
