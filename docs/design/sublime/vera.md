# 薇拉（vera）技能升华设计——「毒理学终章」

> 红色传说品质 buff 卡「技能升华」配套设计（0.001% 爆率，抽到后本局技能升级为升华版）。
> 本文为策划案真源：数值表 / 机制 / 伪代码 / 测试要点。实现时按项目惯例登记 FEEDBACK_TRACKER.md
> 并占用新 R 编号注释。

- 角色：毒系学者·薇拉（`character_table.gd` id=`vera`，血 55 / 攻 +8%，图鉴累计击杀 500 解锁）
- 普通版：毒云领域（300px 毒云 6 秒：域内敌每 0.5s 受 8% 攻击毒伤并减速 20%，CD 120s）
- 升华版：**毒理学终章**（CD 120s 不变）

---

## 1. 普通版现状（代码真源）

| 项 | 值 | 真源 |
|---|---|---|
| 半径 | 300px | `POISON_CLOUD_RADIUS` player.gd:151 |
| 持续 | 6.0s | `POISON_CLOUD_DURATION` player.gd:152 |
| 结算节拍 | 0.5s/跳 | `POISON_CLOUD_TICK` player.gd:153 |
| 每跳伤害 | 8% 主武器 ATK（直结算，KIN，不暴击） | `POISON_CLOUD_ATK_PCT` player.gd:154；结算体 `_poison_cloud_pulse` player.gd:903-933 |
| 减速 | 20%（`ext_slow_mult=0.8`，刷新窗 0.6s） | `POISON_CLOUD_SLOW`/`POISON_SLOW_REFRESH` player.gd:155-156；Enemy 侧字段 enemy.gd:28-29 |
| 施放 | 置窗 + 首跳即刻 | `_skill_poison_cloud` player.gd:892-900 |
| 节拍 | 剩余推进 + 0.5s 一跳 + 到期广播 `poison_cloud_end` | tick 段 player.gd:271-281 |
| 表现 | 毒圈绿雾：cast/tick 带 (pos, radius)，结束入渐隐 | EventBus 43-45 / elemental_fx_layer.gd:843-867 |

单敌泡满全程总伤：首跳 + 6.0/0.5 = **13 跳 × 8% ≈ 104% ATK**；控场为域内 20% 减速。

普通版特征（升华机制必须贴合）：**以玩家为中心的持续领域 + 周期跳伤 + 外部减速乘区**——
伤害是「时间 × 覆盖」的积分，敌人泡得越久吃伤越多；这是全角色中唯一的「驻留惩罚」型技能。

## 2. 升华版总览

毒理学学者的毕生研究走到终章：毒云不再是一层固定浓度的雾，而是**会在敌体内积累、
会自我生长、结束时把积累一次性引爆**的活体疫灶。三条新机制全部围绕普通版
「泡得越久越痛」的驻留惩罚内核展开，不做通用模板：

1. **毒蚀叠层**（渐增·越泡越浓）：每跳给域内敌人 +1 层「毒蚀」（上限 12 层），
   每层使该敌人受到的毒云跳伤 +6%、减速额外加深 1.5%。层数记在**敌人个体**上，
   后进域的敌人从 0 层起——领域版「杀人书」，但对单敌积累、不靠击杀。
2. **领域滋生**（领域成长）：半径随持续时间从 300px 线性蔓延至 390px——
   毒云本身在生长（终值 +30%，非一次性放大）。
3. **催化解离**（层数转化）：领域消散瞬间，对**所有携带毒蚀的敌人**（不限域内）
   按层数结算终结毒伤，每层 3% ATK——泡满整场再走出毒圈的敌人，在云散那一刻付出代价。

## 3. 数值对照表（普通 → 升华）

| 项 | 普通 | 升华 | 倍率/说明 |
|---|---|---|---|
| CD | 120s | 120s（不变） | 领域型技能不缩 CD，强度全部给在领域内 |
| 半径 | 300px 固定 | 300px → 线性成长至 390px | 终值 ×1.3；平均覆盖面积 ≈ +33% |
| 持续 | 6.0s | 7.0s | ×1.17；总跳数 13 → 15 |
| 结算节拍 | 0.5s | 0.5s（不变） | 保持「每 0.5s 一跳」的手感锚 |
| 每跳基础伤害 | 8% ATK | 8% ATK（不变） | **基础跳伤不涨**，成长全部走叠层机制 |
| 跳伤成长 | — | 每层 +6%，上限 12 层 | 满层单跳 8%×1.72 = 13.76% ATK |
| 减速 | 20% 固定 | 20% + 每层 1.5% | 满层 38%（`ext_slow_mult` 最低 0.62） |
| 终结爆发 | — | 领域结束时每层 3% ATK | 满层 36% ATK，直结算同管线 |
| 满层时刻 | — | 第 13 跳（≈6.0s）到 12 层 | 末 2 跳 + 催化均吃满层 |

## 4. 平衡演算（约束：升华 ≈ 普通战力 1.6~2.2 倍）

单敌泡满全程（同一敌人、主武器 ATK 归一）：

- **普通版**：13 跳 × 8% = **104% ATK**
- **升华版跳伤**：15 跳，第 k 跳层数 = min(k−1, 12)，跳伤 = 8% × (1 + 0.06×层数)。
  层数序列 0,1,…,11,12,12,12 的 Σ = 102，总伤 = 8% × (15 + 0.06×102) = 8% × 21.12 = **169% ATK**
- **催化解离**：12 层 × 3% = **36% ATK**
- **合计**：205% ATK ≈ **1.97 倍**（纯单敌伤害，落于 1.6~2.2 区间中位偏上）

计入控场增量（半径成长平均覆盖 +33%、满层减速 20%→38%）后，综合战力约 2.1~2.2 倍，
贴近但不破区间上限。下限保护：敌人只泡 2 秒就跑（t=0/0.5/1.0/1.5 共 4 跳，层 0~3）→ 升华总伤 =
8%×(4+0.06×6) + 4×3% ≈ 47% vs 普通版同窗 4×8% = 32%，仅 **≈1.46 倍（46.88/32，低于 1.6 下限）**——
短驻留场景升华不占便宜，强度全部兑现在「把敌人按在毒云里」的玩法执行上，符合领域控场
角色的操作上限定位，也避免升华后无脑挂机化。

反刷保护：层数上限 12 封顶单敌理论极值；层数记个体不记领域，敌群换血（前波死、
后波进）不继承；CD 120s 下不可能双云叠加（无技能期内再施放重置场景，同普通版幂等口径）。

## 5. 实现方案

### 5.1 常量（player.gd:151-156 后追加升华组）

```gdscript
# ── 薇拉升华「毒理学终章」（真源 docs/design/sublime/vera.md）──
const POISON_CLOUD_SUBLIME_DURATION := 7.0          # 持续 6.0→7.0s
const POISON_CLOUD_SUBLIME_RADIUS_END := 390.0      # 半径成长终值 px（300 起线性）
const POISON_STACK_MAX := 12                        # 毒蚀层数上限
const POISON_STACK_DMG_PER := 0.06                  # 每层跳伤 +6%
const POISON_STACK_SLOW_PER := 0.015                # 每层减速额外 +1.5pp
const POISON_CATALYSIS_PER_STACK := 0.03            # 催化解离每层 3% ATK
```

升华开关（命名依总监裁定归一，卡系统契约 _card_system.md:191/:315 的 `sublime` 字段随裁定同步改名）：

- 字段统一 **`skill_sublime: bool`**（多数派口径；抽到「技能升华」卡经入口置 true，本局有效）。
- 入口统一 **`enable_sublime() -> void`**（卡契约不变：幂等，内部置 `skill_sublime=true` 并分发
  角色初始化（含 fission 回填——fission 泳道细节，本设计不展开）；卡侧 `apply_choice` 只调它，
  本设计不开第二条置位路径）。
- 旗为 false 时**零行为差异**（普通版回归守卫的测试基础）。
- **暂停→继续局不丢升华位**（卡系统必修项，本设计消费其口径）：`serialize_run`
  （game_loop.gd:2738）新增单键 `"sublime": {on: bool, fission_layers: int}`（`fission_layers`
  归 fission 泳道，vera 只读 `on`），`_restore_run_state` 在 set_character 之后 clampf/幂等回填
  `enable_sublime()`——R212 `skill_cd` 同款位置与口径（game_loop.gd:2915 先例），旧档无键零迁移。
  vera 战斗临时态（层表/pending/云窗）**不随档持久化**：续档经 set_character 重建后从零起，
  与普通版同口径（现快照本无云窗键，serialize_run 仅 weapons/hp/skill_cd 等）。

### 5.2 挂点与伪代码

**① `_skill_poison_cloud()`（player.gd:892-900）——升华分支置窗 + 清层表**

```gdscript
func _skill_poison_cloud() -> void:
    if skill_sublime:
        _poison_cloud_left = POISON_CLOUD_SUBLIME_DURATION   # 7.0s 窗
        _poison_stack_table.clear()                          # uid→{"e":敌, "layers":int}
        _poison_catalysis_pending = false
    else:
        _poison_cloud_left = POISON_CLOUD_DURATION
    EventBus.emit_poison_cloud_cast(global_position, _cloud_radius_now())
    _poison_cloud_tick_left = 0.0
    _poison_cloud_pulse()

func _cloud_radius_now() -> float:
    # 领域滋生：300 → 390 线性插值（普通版恒 300）
    if not skill_sublime:
        return POISON_CLOUD_RADIUS
    var t := 1.0 - _poison_cloud_left / POISON_CLOUD_SUBLIME_DURATION
    return lerpf(POISON_CLOUD_RADIUS, POISON_CLOUD_SUBLIME_RADIUS_END, clampf(t, 0.0, 1.0))
```

**② `_poison_cloud_pulse()`（player.gd:903-933）——半径插值 + 逐敌计层/乘区/深减速**

在现有循环内（保留直结算管线通道、KIN、不暴击、遗物注入全不动）：

```gdscript
var radius := _cloud_radius_now()                 # query_circle 与 emit 共用此值
for e in (grid as SpaceGrid).query_circle(global_position, radius):
    ...死敌 continue（现状）...
    var layers := _poison_stack_layers(e)         # 取层（无记录=0）
    # 减速：20% 基础 + 每层 1.5pp（升华）；普通版仍 1.0 - POISON_CLOUD_SLOW
    var slow := POISON_CLOUD_SLOW + (POISON_STACK_SLOW_PER * layers if skill_sublime else 0.0)
    e.set("ext_slow_mult", 1.0 - slow)
    e.set("ext_slow_left", POISON_SLOW_REFRESH)
    ...
    ctx.base_atk = base * POISON_CLOUD_ATK_PCT * (1.0 + POISON_STACK_DMG_PER * layers if skill_sublime else 1.0)
    ...resolve（现状）...
    if skill_sublime:
        _poison_stack_add(e)                      # 结算后 +1 层（上限 12）
# 半径成长随跳下发的实际改点：emit_poison_cloud_tick 现挂 tick 段（player.gd:278，
# pulse() 调用后一行），把该行定参 POISON_CLOUD_RADIUS 改传 _cloud_radius_now()
# （与 pulse 内 query 同源）——FX 零改动；勿在 pulse 内另新增 emit（278 行不删则每跳双发）
```

层表实现（player.gd 成员，不侵入 enemy.gd——`ext_slow_*` 是现成外部乘区可复用，
层数是新概念，收在技能主体内自洽）：

```gdscript
var _poison_stack_table: Dictionary = {}           # int uid → {"e": Variant, "layers": int}
var _poison_catalysis_pending := false

func _poison_stack_layers(p_e: Variant) -> int:
    var uid := int(p_e.get("uid"))
    var rec: Variant = _poison_stack_table.get(uid)      # 先 Variant 取出（类型化赋值坑）
    if rec == null:
        return 0
    var e: Variant = rec.get("e")
    if not is_instance_valid(e) or bool(e.get("dead")):  # 死敌条目惰性回收
        _poison_stack_table.erase(uid)
        return 0
    return int(rec.get("layers"))

func _poison_stack_add(p_e: Variant) -> void:
    var uid := int(p_e.get("uid"))
    var rec: Dictionary = _poison_stack_table.get_or_add(uid, {"e": p_e, "layers": 0})
    rec["layers"] = mini(int(rec.get("layers")) + 1, POISON_STACK_MAX)
```

**③ tick 节拍（player.gd:271-281）——到期转挂催化 pending（关键：错帧）**

```gdscript
if _poison_cloud_left <= 0.0:
    EventBus.emit_poison_cloud_end()
    if skill_sublime and not _poison_stack_table.is_empty():
        _poison_catalysis_pending = true          # 不在同帧直接结算（见下）
# tick() 顶部另起一段（在毒云段之前）：
if _poison_catalysis_pending:
    _poison_catalysis_pending = false
    _poison_catalysis_burst()
```

> **为什么必须错一帧**：伤害管线幂等键为 `(source_uid, target_uid, frame_stamp)`
> （damage_pipeline.gd:108）。7.0s ÷ 0.5s 整除，末跳与 `left` 归零**必然同帧同源同目标**，
> 同帧内再 resolve 催化跳会被幂等检查短路吞成 0 伤。挂 pending 到下一 tick 帧，
> 帧号自然错开，玩家无感（1/60s）。

**④ `_poison_catalysis_burst()`（新函数，player.gd `_poison_cloud_pulse` 后）——催化解离**

```gdscript
func _poison_catalysis_burst() -> void:
    # 领域消散：对所有带层敌人（不限域内——毒已入体）按层数终结结算后清层
    var pipeline: Variant = _deps.get("pipeline")
    var base := _weapon0_base_atk()               # 抽取现有 w0 快照逻辑复用
    for uid in _poison_stack_table.keys():
        var rec: Variant = _poison_stack_table[uid]
        var e: Variant = rec.get("e")
        if not is_instance_valid(e) or bool(e.get("dead")):
            continue
        var layers := int(rec.get("layers"))
        if layers <= 0 or base <= 0.0 or pipeline == null:
            continue
        var ctx := DamageContext.make()
        ctx.source_uid = int(get_instance_id())   # 与毒云跳同口径
        ctx.target = e
        ctx.target_uid = int(e.get("uid"))
        ctx.frame_stamp = GameConfig.frame_stamp  # 已错帧，键不冲突
        ctx.base_atk = base * POISON_CATALYSIS_PER_STACK * layers
        ctx.element = GameConst.Element.KIN       # 无元素通道（D14 同批口径）
        ctx.hit_flags |= GameConst.HIT_IS_AOE_SECONDARY
        ctx.crit_chance = 0.0
        ctx.pos = (e as Node2D).global_position
        _inject_relic_pools(ctx, e)
        pipeline.call(&"resolve", ctx)
    _poison_stack_table.clear()
    DebugStats.count(&"poison_catalysis_burst")
```

**⑤ `_skill_fx_duration()`（player.gd:876-877）——vera 分支升华返回 7.0**

```gdscript
&"vera":
    return POISON_CLOUD_SUBLIME_DURATION if skill_sublime else POISON_CLOUD_DURATION
```

### 5.3 FX 与周边适配

- **半径成长**：`poison_cloud_tick(pos, radius)` 每跳携带半径、FX 层每跳刷新
  （elemental_fx_layer.gd:853-860）——成长**零表现层改动**，毒圈自然随跳变大。
- **cast 时长**：elemental_fx_layer.gd:846-847 硬编码 `left/dur = 6.0`，升华 7.0s 会在
  第 6s 提前渐隐。最小改法：`poison_cloud_cast` 信号不变，FX 侧 left/dur 改从
  Player 查询（或信号加 dur 参数——改 3 处 connect/emit/handler，择一，建议后者，
  显式数据流）。
- **催化表现**（可选加分项）：爆发时在带层敌人位置出小绿爆点（复用
  `_spawn_reaction_ring` + ELEMENT_COLORS[KIN] 惯例），不阻塞核心落地。
- **HUD**：`skill_active_ratio` 通道不变（fx_max 自动随 `_skill_fx_duration` 变 7.0）；
  升华可视（技能键红描边）统一读 `player.get("skill_sublime")`（hud.gd，卡系统 UI 泳道
  接线——本设计不另开读口，防命名再分裂）。

## 6. 测试要点（tests/runner/ 新套件，参照 test_r199_g6.gd 探针式）

入口零游戏类编译期引用（-s 早于 autoload 编译坑）；敌人用直构 Enemy 脚本不入池
（勿 add_child 池化节点坑）。跑法：
`Godot_v4.3-stable_win64.exe --headless --path repo -s tests/runner/<套件>.gd`（exit 0 = 全过）。

1. **普通版零回归**：`skill_sublime=false` 时 cast → left==6.0、半径恒 300、跳伤 8% 整、
   减速 0.8、无层表增长、无催化结算（guard 全套）。
2. **置窗与首跳**：升华 cast → `_poison_cloud_left==7.0` 且首跳当帧即结算（沿普通版口径）。
3. **叠层递增**：单敌连续 6 跳后层=5（首跳结算时 0 层），第 6 跳 ctx.base_atk ==
   base×8%×(1+0.06×5)。
4. **层数上限**：≥14 跳后层恒 12，不再增。
5. **深减速**：满层敌 `ext_slow_mult == 1−0.20−0.015×12 == 0.62`；域外 0.6s 后自愈 1.0
   （enemy.gd 到期还原通道不被破坏）。
6. **半径成长**：`_cloud_radius_now()` 随 left 递减单调升，起点 300 / 终点 390；
   emit_poison_cloud_tick 的 radius 参数同步递增（FX 消费同一值）。
7. **催化错帧与结算**：到期帧带层敌**不**立即受伤；下一 tick 帧每层 3% 一次入账
   （幂等键不冲突——总伤 = 层数×3%，无吞跳）；**域外带层敌**同样入账；空层表/无武器
   零结算不崩。
8. **催化后清层**：burst 后 `_poison_stack_table.is_empty()`；死敌条目（层表残留已死 uid）
   被跳过且不崩（is_instance_valid 先于取字段）。
9. **平衡对拍**：模拟单敌泡满全程，伤害累计 ∈ [200%, 210%] × ATK 桶（对照普通版
   [100%, 108%]，倍率落 1.6~2.2 区间的回归护栏）。
10. **换角/重开清口**：角色切换或重开时层表、pending、云窗全清（对齐 R199 H01 换角清口通道）。
11. **暂停→继续局升华位保真**：run_save 带 `"sublime": {on: true}` 续档 → `_restore_run_state`
    回填 `enable_sublime()` 后 `player.get("skill_sublime") == true`、下次施放走升华分支；
    层表/pending/云窗随续档重建从零起（不复活旧局残层）。键往返保真断言落在
    r212_skillresume 套件（卡系统必修项），本套件只锁 vera 侧重放行为；旧档无 `sublime`
    键时零迁移（不置位、走普通版）。

## 7. 风险与边界

- **多毒源互扰**：mank 毒沼绽放（`_skill_poison_nova`）与毒云共用 `ext_slow` 乘区但
  独立结算通道，层表仅 vera 毒云写入，无交叉（测试要点 1 顺带守卫）。
- **极端 CDR**：若未来有效 CD < 7s（当前 120s 基准不可能），cast 先清层表 +
  `_summon_restore` 同款「先回收再重掷」幂等口径已覆盖（5.2①）。
- **对象生命周期**：层表持敌引用跨帧，`_poison_stack_layers`/burst 双处
  is_instance_valid + dead 守卫；池归还复位（enemy.gd:1997-1998）后旧 uid 记录
  惰性回收，不误伤新敌（uid 唯一性由池保证）。
- **表现层 6.0s 硬编码**：不修则升华毒圈第 6s 起提前渐隐（纯视觉、不伤结算），
  随实现批一并修（5.3 第 2 条）。
