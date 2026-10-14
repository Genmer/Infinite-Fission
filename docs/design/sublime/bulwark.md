# 技能升华设计 · 堡垒·磐（bulwark）——「余震壁垒」

> R246 升华卡体系 · 角色设计师产出（10 角色之一）。红色传说 buff 卡「技能升华」
> 0.001% 爆率抽到后，本局 bulwark 主动技能「震荡践踏」升级为升华版「余震壁垒」。
> 本文档 = 数值 + 机制 + 实现锚点 + 测试要点，供实施员泳道（skills=player.gd）落地。
> R246-修订1（总监裁定并入）：升华旗标全角色归一 `skill_sublime` + 统一入口
> `enable_sublime()`；继续局升华位经 serialize_run `"sublime"` 键往返保真
> （§4.1/§4.5/§5 已同步；数值与机制未动）。
> R246-修订2（总监四条意见复核，本文引用锚点已逐行实读核实）：①卡系统存档保真——
> 修订1 已并入，本轮补齐意见原文的 `clampf` 回填措辞（§4.1）；②命名归一——本文档
> 原即多数派 `skill_sublime`，复核零旧名残留；③noah 舰体寿命、④fission 口径 B 双砍
> 系角色专属，与 bulwark 零交叉（唯一交点 `enable_sublime()` 分发位不涉两者数值）
> ——数值/机制/测试要点零改动。

---

## 1. 角色与普通版基线（真源核对）

真源：`repo/scripts/meta/character_table.gd:32-38`

| 项 | 值 |
|---|---|
| id / 名 | `bulwark` / 堡垒·磐 |
| 定位 | 重装堡垒（血 95 / 攻 −5%），近身清场 |
| 技能 | 震荡践踏——「震退周围敌人并清除身旁弹幕」 |
| CD | 120s（全角色 `cd==120` 是 `verify_feedback_cases` 的遍历断言，character_table.gd:80 注释明示，升华不得改） |

普通版实现（`repo/scripts/entities/player/player.gd:1151-1169` `_skill_stomp`，分发锚点
player.gd:837-838 `activate_skill` 的 `&"bulwark"` 分支）：

| 参数 | 普通版值 | 代码依据 |
|---|---|---|
| 击退半径 | 220px | player.gd:1155 `query_circle(global_position, 220.0)` |
| 击退力 | 280（语义=总位移 px） | player.gd:1159 `knockback(dir * 280.0)` |
| 清弹半径 | 260px | player.gd:1163 `query_circle(..., 260.0)` |
| 清弹帽 | 24 颗 | player.gd:1168 `if cleared >= 24: break` |
| 形态 | 瞬发（fx 0.8s 施放闪光，`_skill_fx_duration` 走默认分支 player.gd:882） | — |
| 伤害 | **零**——纯空间重置 + 弹幕消除 | 全函数无伤害结算 |

普通版既有语义（升华自动继承，不重复设计）：
- Boss 完全免疫击退、精英 ×0.35（enemy.gd:888-903 `knockback` 的质量分级）；
- 击退打断自爆引导/爆虫 BLINK 信期（enemy.gd:898-901）；
- 每颗清除弹走 `EventBus.emit_bullet_nullified` 涟漪 + `nullify()`（player.gd:1165-1166）；
- 复活清弹 `REVIVE_CLEAR_CAP := 24` 与本技能同帽（player.gd:139 注释——**升华后本帽不动**，
  复活缓冲与技能清场权是两条线，公平性缓冲不该跟传说卡膨胀）。

**技能身份提炼**（升华机制必须长在这三点上，不许通用模板化）：
1. 全 10 角色唯一以「清除敌方弹幕」为核心收益的技能；
2. 零伤害纯防御——价值全部兑换成「生存空间」；
3. 一次性脉冲，按下去的那 0.3 秒决定成败，之后壁垒回到裸奔。

---

## 2. 升华版设计：余震壁垒

一句话：**主震更猛，大地再震三轮，吃掉的每一颗子弹都砌进壁垒自己的血里。**

### 2.1 数值对照表（普通 → 升华）

| 项 | 普通版 | 升华版 | 倍率/说明 |
|---|---|---|---|
| CD | 120s | **120s（不变）** | 1.0×；全角色 cd==120 不变量（见 §1） |
| 主震·击退半径 | 220px | **300px** | 1.36× |
| 主震·击退力 | 280 | **380** | 1.36×（总位移 px 口径不变） |
| 主震·清弹半径 | 260px | **340px** | 1.31× |
| 主震·清弹帽 | 24 | **40** | 1.67× |
| 余震 | 无 | **×3 跳**（施放后 t+1/+2/+3s，间隔 1.0s） | 新机制 A |
| 余震·击退 | — | 200px 半径 / 力 140 | ≈0.5 个主震单位/跳 |
| 余震·清弹 | — | 220px 半径 / 帽 8 颗/跳 | — |
| 余震·中心 | — | **玩家实时位置**（跟随推进） | 壁垒是移动堡垒 |
| 磐岩护壁 | 无 | **每清 1 颗敌弹 +1.5 护壁 HP**（主震+余震都计），单次施放帽 48，跨施放续接取 `min(残+得, 48)` | 新机制 B |
| 护壁·吸收位 | — | 受击漏斗中减伤闸之后、扣血之前，先行吸收；耗尽即透 | — |
| fx 时长 | 0.8s | **3.8s**（HUD 时长条覆盖余震窗） | `_skill_fx_duration` 加 `&"bulwark"` 分支 |
| 伤害 | 0 | **0（保持零伤）** | 壁垒的技能不产伤，只产「不被打死」 |

### 2.2 新机制 A —— 三重余震（渐进脉冲，非持续光环）

施放后 1/2/3 秒，各以**玩家当时所在位置**为中心追加一跳弱化版践踏（200px 击退 140 力 +
220px 清弹帽 8）。设计意图与贴合点：

- 贴合「震荡」语义：地震本来就有余震，主震开路、余震荡尾；
- 把「一次脉冲」变成「随壁垒推进的 4 秒禁区」——贴堡垒·磐「重装推进」的打法幻想：
  踩一脚之后 4 秒内你可以顶着弹幕往前走，余震替你把扑回来的怪和补进来的弹继续碾掉；
- 刻意**不是持续光环**（区别于 vera 毒云领域的持续域）：仍是 3 个离散瞬脉冲，每次都要
  「当下有东西可清才有价值」——压强越大盘子越大，轻压下余震落空（见 §3 场景甲），
  这是防御技能应有的压强缩放，而不是无脑常驻减伤。

### 2.3 新机制 B —— 磐岩护壁（层数转化，但货币是「本技能清掉的弹」）

升华版每清除 1 颗敌方弹幕，转化为 1.5 点「磐岩护壁」：一个先于 HP 被扣除的吸收池
（帽 48 ≈ 堡垒·磐满血 95 的 50.5%）。设计意图与贴合点：

- 「层数转化/越打越强」方向的本角色化：叠加货币**不是击杀数**，而是「被这脚踩掉的弹幕」
  ——普通版唯一核心收益就是清弹（§1 身份点 1），升华把这份收益结转成生存资本，
  「吃掉的弹幕变成壁垒的血」，机制与幻想完全同构，换任何一个角色都不成立；
- 兑换率故意压得很薄（1 颗中波敌弹 ≈10 伤害，1.5 护壁 ≈ 只返还 15%），护壁是
  「这脚踩得值」的加成，不是新的回血引擎；
- 48 帽在标准~重压场景（清 32+ 颗）基本会被打满，价值可预期、可被终审一眼核算。

吸收细则（实现按此执行）：
- 位置：`take_contact_damage` 内、结晶减伤闸（player.gd:448-449）之后、`hp -= dmg`
  （player.gd:450）之前——结晶 ×(1−dr) 先算，护壁吃净伤；
- **全吸收**（护壁 ≥ 本次伤害）：照常给 `contact_tick` 无敌帧（与 MEC_SHIELD 格挡同款
  防同帧连击秒破，player.gd:443 先例），发独立的「岩壁碎屑」表现事件，`return`；
- **部分吸收**：护壁归零、余量继续走 HP 扣除 + 受击闪白（既有路径不动）；
- `emit_player_hit` 上报**吸收后净伤**（统计口径不虚报）；
- 不设时限：护壁留到被打穿或下一跳补充（跨施放 `min(残+得, 48)`），纯会话态零存档
  （`dr_left` 先例 player.gd:62——读档即失，可接受，见 §5 边界）。

### 2.4 明确不做（防串味）

- 不加任何直接伤害/反伤——零伤是堡垒技能的身份红线（撞车 sentry 护盾位则失去辨识度）；
- 不做持续减速域/光环——那是 vera 毒云（character_table.gd:61-66）的领地；
- 不动复活清弹帽 24（player.gd:139）——复活缓冲是公平性底线，不跟传说卡膨胀；
- 不改 CD/不加充能层数——120s 单发全角色不变量（character_table.gd:80）。

---

## 3. 平衡测算

### 3.1 价值模型（防御技能无量纲化，透明可查）

| 量纲 | 单位价值 | 依据 |
|---|---|---|
| 清 1 颗敌弹 | 1.0 | 普通版核心收益 |
| 击退 1 敌 | 力/280 | 位移买时间，线性近似 |
| 1 点护壁 | 0.1 | 兑换即返还：1.5 护壁/弹 ≈ 中波弹伤（~10HP）的 15%，折价反映「仅缓冲、不防控、要后续被打才兑现」 |

### 3.2 场景表（同一 120s 周期内的单次施放）

| 场景 | 环境 | 普通版 | 升华版 | 倍率 |
|---|---|---|---|---|
| 甲·轻压 | 3 敌贴身 + 6 弹；余震仅 1 跳接到 2 弹/2 敌 | 6+3 = **9.0** | 6 + 3×1.36 + 2 + 2×0.50 + 8×1.5×0.1 = **14.2** | **1.58×**（带沿，有意） |
| 乙·标准遭遇 | 8 敌 + 30 弹；其后 4s 再入 6 弹/回拢 3 敌 | 24+8 = **32.0** | 30 + 8×1.36 + 6 + 3×0.50 + 48×0.1 = **53.2** | **1.66×** ✓ |
| 丙·重压 | 12 敌 + 55 弹；再入 14 弹/回拢 6 敌 | 24+12 = **36.0** | 40 + 12×1.36 + 14 + 6×0.50 + 48×0.1 = **78.1** | **2.17×** ✓ |
| 理论上限 | 全帽满吃、余震全接满 | 36.0 | 40 + 16.3 + 3×(8+6×0.50) + 4.8 ≈ **93.4** | **2.59×**（见下） |

结论与申辩：
- 标准与重压场景（也就是这颗按钮真正会被按下去的场景）落在 **1.66×~2.17×**，带内；
- 场景甲 1.58× 略低于带沿是**有意设计**：压强缩放——轻压下升华与普通差距小、
  重压下拉开，贴合「壁垒在被围攻时最强」的角色幻想，也天然抑制无脑施放；
- 理论上限 2.59× 超带沿 0.4：达成条件是**站在最大密度火线里整整 4 秒**（主震帽 40 +
  3×8 余震帽全满 + 回拢敌全接）——同一环境下普通版只清 24 颗后剩 31 颗弹直接打在
  身上，玩家大概率已死。防御技能的上限兑换的是「活下来」而非输出，且每一跳都有帽
  硬封顶、技能本身零伤害贡献，与 sentinel 同 CD 的 3 秒完全无敌横向比并不超卖。

降档旋钮（终审判超模时按序拧，不必重设计）：
① 余震力 140→110；② 护壁转化 1.5→1.2；③ 余震清弹帽 8→6。
单拧 ① 即可把上限压到 ≈2.4×，场景乙/丙 仍 ≈1.6×/2.1×。

---

## 4. 实现方案

### 4.1 契约：升华旗标与统一入口（跨泳道对接，注入调用方=卡系统）

```gdscript
# player.gd 状态区（player.gd:38-41 技能状态块旁）
var skill_sublime: bool = false   # 抽中升华卡置 true；缺省 false=普通版，零回归
                                   # （R246-修订1 裁定：全 10 角色统一此字段名——
                                   #   勿用 sublime / sublime_skill / _sublime_on 旧分裂名）

func enable_sublime() -> void:    # 统一入口（卡契约 _card_system.md:191/:315，幂等）
    skill_sublime = true
    # ……分发各角色升华初始化（含 fission 替代回填，见卡系统/各角色文档）——
    # bulwark 分支为空操作：余震窗/护壁本就是「施放时」才播种的会话态，
    # 旗标置位即完整生效，无任何需预建/重建的派生态。
```

- 读侧只在本文件 `&"bulwark"` 分支与 `_skill_fx_duration` 消费；其余 9 角色零感知；
- HUD 读口（hud.gd 技能键红描边，_card_system.md §5.1）统一读
  `player.get("skill_sublime")`（has_method 守卫，R186 同式）——与字段名裁定同源，
  实施时勿读旧名；
- 旗标生命周期 = 卡系统契约（_card_system.md:191）：重置点随
  `_reset_skill_temp_state`/`set_character`/重开清零；**继续局保真**（R246-修订1）：
  `serialize_run`（game_loop.gd:2738）新增单键 `"sublime": {on: bool,
  fission_layers: int}`（bulwark 只消费 `on`，fission_layers 与本角色无关），
  `_restore_run_state` 在 `set_character` 之后 clampf/幂等回填 `enable_sublime()`
  （R246-修订2：clampf 只辖 `fission_layers` 防脏档越界——game_loop.gd:2913
  `skill_cd_left` 的 clampf 同款写法；bulwark 消费的 `on` 是布尔，置位即全量，
  无 clamp 空间）——
  R212 skill_cd 同款恢复序先例（game_loop.gd:2912-2915：set_character 重建后仅回填
  快照键，快照无键即丢——升华旗标此前正漏在此处）；旧档无键 → 零迁移。
  本文件只需在 `_reset_skill_temp_state` 清 bulwark 专属态，不碰旗标本身；
- 抽卡时点无中途切态问题：bulwark 是瞬发技能、无常驻增益窗，卡契约
  「已在增益窗中的普通版不中途切态、下次施放起生效」对本角色自动满足。

### 4.2 挂点清单（本会话逐一核实过的行号）

| # | 挂点 | 改动 |
|---|---|---|
| 1 | `activate_skill` player.gd:837-838 | `&"bulwark"` 分支：`_skill_stomp()` 改读 `skill_sublime` 选参 + 播种余震窗 |
| 2 | `_skill_stomp` player.gd:1151-1169 | 重构为参化 `_stomp_pulse(p_knock_r, p_force, p_clear_r, p_cap, p_feed)`；普通(220,280,260,24,false) / 升华主震(300,380,340,40,true) / 余震(200,140,220,8,true) |
| 3 | tick 倒计时块 player.gd:256-268 | 追加余震调度（`_stomp_aftershock_pulses/_left`，`_dead` 守卫） |
| 4 | `take_contact_damage` player.gd:432-459 | dr 闸（:448-449）后、`hp -= dmg`（:450）前插护壁吸收闸 |
| 5 | `_reset_skill_temp_state` player.gd:809-820 | 清余震定时器 + 护壁（换角/重开收口，与毒云清零同段） |
| 6 | `_skill_fx_duration` player.gd:868-882 | 加 `&"bulwark": return 3.8 if skill_sublime else 0.8`（HUD 时长条盖余震窗） |
| 7 | enemy.gd:888-903 `knockback` | **零改动**——Boss 免疫/精英 ×0.35/打断语义自动继承 |

### 4.3 状态变量（全部纯会话态，零存档——`dr_left` 先例 player.gd:62）

```gdscript
const STOMP_AFTERSHOCK_INTERVAL := 1.0   # 余震间隔
const STOMP_AFTERSHOCK_PULSES := 3       # 余震跳数
const STOMP_BARRIER_PER_BULLET := 1.5    # 每清 1 弹转化的护壁
const STOMP_BARRIER_CAP := 48.0          # 护壁帽

var _stomp_aftershock_pulses: int = 0    # 剩余余震跳数（0=无窗）
var _stomp_aftershock_left: float = 0.0  # 距下一跳余震的倒计时
var _stomp_barrier: float = 0.0          # 磐岩护壁剩余吸收量
```

### 4.4 伪代码

```gdscript
# ── 挂点 1：activate_skill 的 &"bulwark" 分支 ──
&"bulwark":
    if skill_sublime:
        _stomp_pulse(300.0, 380.0, 340.0, 40, true)          # 升华主震
        _stomp_aftershock_pulses = STOMP_AFTERSHOCK_PULSES   # 播种余震窗
        _stomp_aftershock_left = STOMP_AFTERSHOCK_INTERVAL
    else:
        _stomp_pulse(220.0, 280.0, 260.0, 24, false)         # 普通版（逐位等价旧行为）

# ── 挂点 2：_skill_stomp 参化重构（原查询/调用体原样保留）──
func _stomp_pulse(p_knock_r: float, p_force: float, p_clear_r: float,
        p_cap: int, p_feed: bool) -> void:
    var grid: Variant = _deps.get("enemy_grid")
    if grid != null:
        for e in (grid as SpaceGrid).query_circle(global_position, p_knock_r):
            if e == null or bool(e.get("dead")):
                continue
            if e.has_method(&"knockback"):
                e.call(&"knockback",
                    ((e as Node2D).global_position - global_position).normalized() * p_force)
    var bgrid: Variant = _deps.get("enemy_bullet_grid")
    if bgrid != null:
        var cleared := 0
        for b in (bgrid as SpaceGrid).query_circle(global_position, p_clear_r):
            if b is ProjectileBase and (b as ProjectileBase).team == 1:
                EventBus.emit_bullet_nullified((b as Node2D).global_position)
                (b as ProjectileBase).nullify()
                cleared += 1
            if cleared >= p_cap:
                break
        if p_feed and cleared > 0:                            # 新机制 B：清弹→护壁
            _stomp_barrier = minf(_stomp_barrier + cleared * STOMP_BARRIER_PER_BULLET,
                STOMP_BARRIER_CAP)
            EventBus.emit_stomp_barrier_gained(cleared)       # 新事件（表现层，见 §6）

# ── 挂点 3：tick 倒计时块（skill_cd_left 块旁并列）──
if _stomp_aftershock_pulses > 0 and not _dead:
    _stomp_aftershock_left -= p_game_delta
    if _stomp_aftershock_left <= 0.0:
        _stomp_pulse(200.0, 140.0, 220.0, 8, true)           # 余震：读实时 global_position
        EventBus.emit_stomp_pulse(global_position)           # 新事件（表现层，可裁）
        _stomp_aftershock_pulses -= 1
        _stomp_aftershock_left = STOMP_AFTERSHOCK_INTERVAL

# ── 挂点 4：take_contact_damage 内、dr 闸后 hp -= 前 ──
if _stomp_barrier > 0.0:
    var soaked := minf(_stomp_barrier, dmg)
    _stomp_barrier -= soaked
    dmg -= soaked
    EventBus.emit_stomp_barrier_soak(soaked)                 # 新事件（表现层，可裁）
    if dmg <= 0.0:                                           # 全吸收：同 MEC_SHIELD 口径
        invuln_left = GameConfig.balance.contact_tick if GameConfig.balance != null else 0.6
        return
# …继续既有 hp -= dmg / 闪白 / player_hit（上报的是吸收后净伤 dmg）──

# ── 挂点 5：_reset_skill_temp_state 追加 ──
_stomp_aftershock_pulses = 0
_stomp_aftershock_left = 0.0
_stomp_barrier = 0.0
```

新增 EventBus 信号（3 个，全部表现层专用、无逻辑消费、可被 fx 泳道裁并）：
`stomp_pulse(pos)` / `stomp_barrier_gained(count)` / `stomp_barrier_soak(amount)`——
沿用 event_bus.gd:36-50 表现层信号惯例；余震消弹涟漪**复用既有**
`bullet_nullified`（player.gd:1165 已逐颗发，零新增成本）。

### 4.5 边界与坑（实现时逐条对齐）

- `_dead` 守卫：死亡瞬间余震窗未跳完 → tick 块 `not _dead` 停跳，`_on_died`/重开走挂点 5 清零；
- 读档（两层口径，R246-修订1 后必须区分）：升华旗标本身随卡系统 `"sublime"` 键
  往返保真（serialize_run 单键承载、继续局 set_character 后幂等回填
  `enable_sublime()`，见 §4.1）——抽到的升华不再因暂停续档蒸发；bulwark 的
  余震窗（≤3s）与护壁仍是纯会话态，不进 RunSave，读档即失——`dr_left` 同口径
  （player.gd:62）。探针断言口径 = 快照无 **bulwark 专属键**（护壁/余震窗），
  **不得**断言「无任何新增键」——顶层 `"sublime"` 键是卡系统契约键，会误伤；
- 换角色：`_reset_skill_temp_state` 清 bulwark 专属态，护壁不泄漏给下一角色；
- 类型化赋值坑：`_stomp_pulse` 内 grid/bgrid 仍是 Variant 局部（原函数同款），勿提前
  `as SpaceGrid` 进条件表达式（项目已知坑：类型化赋值先于 is_instance_valid）；
- 池化节点：余震/护壁不新建常驻节点，全部走事件→表现层自管（测试勿 add_child 池化节点同因）；
- fx 3.8s 与余震窗的差 0.8s：主震闪光 0.8s + 3 跳到 t+3.0s 后留 0.8s 收尾呼吸，
  `_skill_fx_duration` 返 3.8 即 HUD 时长条完整盖住余震窗。

---

## 5. 测试要点（建议套件 `tests/runner/r246_sublime_bulwark.gd` + `_cases.gd`，-s 入口只 load cases 体）

1. **零回归**：`skill_sublime=false` 时参数逐位等价普通版——220/280/260/24、无余震
   （推进 4s 断言零脉冲）、护壁恒 0、`_skill_fx_duration` 走 0.8 默认；
2. **主震参数**：升华下 300px 内敌收到 `knockback(×380)`（探针监听）、301px 外不动；
   boss 零调用 / 精英力 ×0.35（enemy.gd 语义不回归，mock 两 tag 各一）；
3. **清弹帽**：340px 布 41 颗 team=1 弹 → 清 40 留 1，`bullet_nullified` 事件计数 40；
4. **余震时序**：cast 后按 game_delta 推进，t=1/2/3s 各一跳、t=4s 起零脉冲；
   期间玩家移动 100px → 第 2 跳中心=新位置（跟随断言）；每跳独立帽 8；
5. **护壁转化与吸收**：清 N 弹 → 护壁 = min(残+1.5N, 48)；
   `take_contact_damage(20)` 在护壁 30 时 → hp 不动、护壁 10、净伤上报 0；
   护壁 15 受击 20 → hp 只掉 5；护壁 0 → 原路径逐位不变（含全吸收给 contact_tick 无敌帧）；
6. **收口**：`_reset_skill_temp_state`（换角/重开路径）清余震+护壁；死亡态余震停跳；
7. **CD 不变量**：升华激活后 `skill_cd_base == 120`（`verify_feedback_cases` 全角色
   cd==120 断言必须仍过——回归门禁直接复跑该套件）；
8. **存档正交**：RunSave 快照无护壁/余震键（**bulwark 专属键**黑名单断言；顶层
   `"sublime"` 键归卡系统承载，其往返保真断言在 r212_skillresume 套件补，本套件不碰）；
9. **续档生效**：走 `_restore_run_state` 同款路径——`set_character` 重建后再
   `enable_sublime()` 置位 → 断言 `skill_sublime == true` 且下一次 `activate_skill`
   直达升华参数（300/380/340/40）：bulwark 置位即完整生效，续档后零派生态需重建。

---

## 6. 表现层建议（非阻塞，fx 泳道可自由裁并）

- 主震：沿用 `skill_cast` 金环（event_bus.gd:50）+ 升华加土褐色二重环与 CRIT 级震屏（仅主震）；
- 余震：`stomp_pulse` → 扩散土环 + 低频闷响，强度为主震 40%；
- 护壁：HUD 在技能时长条旁挂灰岩色弧条（余量/48），受击碎屑走 `stomp_barrier_soak`
  （与 MEC_SHIELD 的 `_shield_ring` player.gd:123 视觉区分色：土金 vs 青蓝）；
- 卡面文案（升华卡描述）：「壁垒·磐技能升华：践踏化作余震壁垒——主震更猛，
  其后三重余震随你推进，每一颗被踩碎的弹幕都砌进壁垒的血里。」
