# 哨兵-9（sentinel）技能升华设计 —— 绝对屏障

> R246 升华卡系统 · 角色设计师稿（10 角色并发设计之一）
> 真源：`scripts/meta/character_table.gd:19-24`（角色定义）＋ `scripts/entities/player/player.gd`（技能实现主体）
> 日期：2026-10-08 · 总监终审修订版（同日）：①升华位随档保真（暂停续档不蒸发，§6 挂点 5/§8）；②命名归一 `skill_sublime`＋`enable_sublime()`＋HUD 读口（§6）
> 修订 2（同日复核）：全文代码行号引用逐条实测校准（player.gd/enemy.gd/game_loop.gd/hud.gd/event_bus.gd/character_table.gd 全中）；§6 卡契约同步范围精确化；§7 运行命令修正为 `-s` 入口脚本口径（与本文「入口只 load cases 体」惯例自洽）

---

## 1. 角色与普通版现状

**角色**（character_table.gd:19-24）：`&"sentinel"` 哨兵-9，均衡型防御机体，初始免费（新手底座），血 60 / 攻 +0%。

**普通版技能「紧急护盾」**：展开 3 秒无敌力场，CD 120s。

实现真源（player.gd）：

| 挂点 | 行号 | 现状 |
|---|---|---|
| `activate_skill` 哨兵分支 | player.gd:830-832 | `invuln_left = maxf(invuln_left, 3.0)`＋`_skill_shield_left = 3.0` |
| 受击无敌闸 | player.gd:436-437 | `take_contact_damage` 入口 `if _dead or invuln_left > 0.0: return` —— 全部来袭通道（敌接触 enemy.gd:829/995/1137/1245/1334/3310/3409/3486 + 敌弹 projectile_base.gd:484/806）的唯一漏斗（Q-16 简化路径） |
| 护盾泡表现 | player.gd:1462-1469 | `_tick_visual` 内 `_skill_shield_left` 衰减 + 青蓝泡泡呼吸（纯表现） |
| 演出时长 | player.gd:872-873 | `_skill_fx_duration` 哨兵 → 3.0（金环倒数弧 + HUD 时长条） |
| 无敌帧推进 | player.gd:246-249 | `tick` 内 `invuln_left -= game_delta` |

**普通版特点提炼**（升华必须贴合）：
- 纯防御「保命按钮」：3 秒内完全免疫一切来袭，无任何输出/位移/控场成分；
- 力场是**有形的泡**（护盾泡表现独立于无敌数值存在）；
- 用完即走：3 秒一过世界立刻恢复原状，盾落瞬间贴身敌人仍在身边。

---

## 2. 升华版总览

**名称：绝对屏障**（4 字；「紧急护盾 → 绝对屏障」体现从应急短盾到主权级力场的升格；避开零「时滞力场」的力场后缀，全角色无重名）

**一句话**：无敌 3s→5s，力场从「被动挨打的泡」变成「有实体、会反击、会吞能回充的相位屏障」——越是被围殴，屏障回充越快。

**卡面描述（角色表 skill_desc 升华版建议文案）**：
> 展开 5 秒绝对屏障：每 0.5 秒对身旁 120px 内敌人反冲 15% 攻击并击退；吞下来袭伤害即为屏障回充 2 秒冷却（单次施放至多回充 20 秒）。

---

## 3. 数值对照表（普通 → 升华）

| 维度 | 普通·紧急护盾 | 升华·绝对屏障 | 倍率 |
|---|---|---|---|
| 无敌时长 | 3.0s | **5.0s** | 1.67× |
| 技能 CD 基准 | 120s | **120s（不变，不例外）** | 1.0× |
| 力场输出 | 0 | **每 0.5s 一跳，120px 内 15% 主武器 ATK**（5s 共 10 跳 = 150% ATK） | 新增 |
| 力场击退 | 0 | **每跳 220px 冲量**（Boss 免疫 / 精英 ×0.35，沿 `enemy.knockback` 质量分级 enemy.gd:888-904） | 新增 |
| 吸收回充 | 无 | **力场期间每吞 1 次来袭伤害 → 技能 CD 立减 2s**（0.5s 节流计 1 次；单次施放回充帽 20s） | 新增 |
| 高压实战等效 CD | 120s | 100~120s（贴身打满吸收才到下限） | 1.0~1.2× 循环 |
| 演出倒数（金环/HUD） | 3.0s | 5.0s（`_skill_fx_duration` 同步） | — |

---

## 4. 新机制详述

### 4.1 机制一：相位反冲（贴合点：力场有实体）

普通版的无敌是「数值豁免」——泡只是画出来的。升华版让力场拥有物理存在感：屏障存续期间每 0.5s 向外一次相位脉冲，对 120px 内敌人结算 15% 主武器 ATK（AOE_SECONDARY 直结算通道，不吃暴击）并施加 220px 击退冲量。

- **实现先例完全同构**：伤害结算照 `_skill_poison_nova`（player.gd:746-774，DamageContext + pipeline + `weapon_slots[0].build_panel_snapshot().base_atk` + `_inject_relic_pools`）；击退照 `_skill_stomp`（player.gd:1151-1159，`enemy_grid.query_circle` + `knockback(方向×距离)`）。
- **设计意图**：① 把 5 秒无敌从「干挨打」变成「顶着弹幕推线」的进攻窗口（贴脸输出环境）；② 击退在**力场结束瞬间清空身周 120px**，直接免掉普通版「盾一掉立刻被贴身围死」的痛点——防御技能的防御性补强。
- 输出量级刻意压在 mank 单发全屏毒爆（150%）同级：占构筑总 DPS 小头（<5%），是佐餐不是主菜，防越界抢输出角色定位。

### 4.2 机制二：吸收回充（贴合点：护盾「吞」伤害 → 杀人书式压力成长）

力场存续期间，每次 `take_contact_damage` 被无敌闸挡下（= 屏障吞掉一次来袭，接触伤与敌弹同漏斗同权重计数），立即为技能自身回充 **CD −2s**。

- **节流**：吸收计数闸 0.5s（`_sub_absorb_gate_left`）——敌接触是物理帧级调用（enemy.gd:819 注释口径），不节流会把单次重叠算成每秒 60 次；节流后 5s 力场期内至多计 10 次。
- **回充帽**：单次施放累计回充 ≤20s（≈基准 CD 的 16.7%）。极端高压全程贴身时实战等效 CD 100s；规避打法吃不满则维持 120s。
- **成长方向**：「越是被围殴，屏障回充越快」——把叠加/渐增方向移植到防御技能上：压力本身就是成长资源。哨兵从「躲着放保命盾」变成「主动扎进怪堆里吃伤害养 CD」，玩法身份质变而技能按钮不变。
- **强限定**：只在 `_sub_field_left > 0`（升华力场存续）期间计数——复活保护 / 受击无敌帧 / 重生无敌（player.gd:1271）期间被打**不**回充，防与通用无敌帧串味。

### 4.3 刻意不做（防超界与模板化）

- **不缩短 CD 基准**：CD 保持 120s 基准不例外；回充是局内压力响应机制且有帽，不构成常驻 CD 缩减。
- **不做余辉减伤**（力场结束后 dr 减伤渐退）：dr 通道（player.gd:448-449）现成可用，但三机制叠加会把战力推过 2.2× 上沿，且稀释「绝对无敌」的爽点。列为二期候选。
- **不做无敌时长叠加成长**（击杀延长无敌）：与 zero 时停 / mank 毒爆的「持续结算窗」区分度不足，且时长越长越接近无敌挂机，风险收益比差。

---

## 5. 平衡推导（1.6~2.2× 论证）

威胁模型（地狱难度 10 分钟局，取后期均值）：接触均伤 ≈12（0.6s 节流），密集贴身期受击频率 ≈1.7 次/s（接触节流上限口径）。

**普通版**：CD 120s → 5 次施放；单次 3s 期望免伤 ≈ 3 × 1.7 × 12 ≈ 61 ≈ **1.0× max_hp（60）**；总有效免伤 ≈ 5×max_hp；输出贡献 0。

**升华版**：
- 单次免伤窗口 5s ≈ 102 ≈ 1.7× max_hp（**1.67×**）；
- 回充：贴身打满 → 单施放 CD −20s → 实战 CD 100s → 10 分钟 6 次施放（**1.2× 循环**）；轻压/规避 → 120s 仍 5 次（1.0×）；
- 反冲输出：6 次 × 150% ATK = 900% ATK/局，占构筑总输出 <5%（权重 ≈0.05~0.1）；
- 击退隔离：盾落瞬间身周清场，等效再省 ~0.1~0.2× 后续伤害。

**合成**：防御轴 1.67 ×（循环 1.0~1.2）= 1.67~2.0×，加输出与隔离 ≈ **1.8~2.2×**；上界由「单施放回充帽 20s + CD 基准 120s 不动」双锁死，不越 2.2×。下界（完全不吃吸收的保守玩法）1.67×，仍高于 1.6× 门槛。

---

## 6. 实现挂点与伪代码

**命名口径（总监终审裁定，10 份角色文档归一）**：升华标志字段统一 `skill_sublime: bool`（多数派口径，替代 `sublime_skill`/`_sublime_skill`/`_sublime_on`/`Player.sublime` 四分裂写法）；置位唯一入口统一 `enable_sublime() -> void`（卡系统接线契约 `_card_system.md:183-191` 的**入口签名不变**——内部置 `skill_sublime=true` 并分发角色初始化，含 fission 回填分支；其 :191 契约行 `Player.sublime: bool` 与 :315 泳道表 `sublime: bool` 的字段名随归一改写为 `skill_sublime`，由 skills/cards 泳道同步落笔）；HUD 技能键红描边统一读 `player.get("skill_sublime")`（hud.gd:277-302 读口，has_method 守卫同 R186 式）。

新增状态（player.gd:40 `_skill_shield_left` 旁，同注释块）：

```gdscript
var skill_sublime := false        # R246 升华位（命名归一：skill_sublime）；唯一置位入口
                                  # enable_sublime()（卡 apply_choice → player.enable_sublime()，幂等）。
                                  # 局内会话态：重开/换局清零；暂停→继续局随 run_save "sublime"
                                  # 单键保真（挂点 5/§8）——旧「不入存档」口径作废
var _sub_field_left := 0.0        # 升华力场权威计时（tag：当前无敌来自升华技能）
var _sub_field_tick_left := 0.0   # 相位反冲节拍（0.5s 一跳）
var _sub_absorb_gate_left := 0.0  # 吸收计数节流闸（0.5s 计 1 次）
var _sub_absorb_reduced := 0.0    # 本施放已回充 CD 量（帽 20s）
```

### 挂点 1：`activate_skill` 哨兵分支（player.gd:830-832）

```gdscript
&"sentinel":
    if skill_sublime:
        invuln_left = maxf(invuln_left, 5.0)     # 数值强化：3→5s
        _skill_shield_left = 5.0                 # 护盾泡同步（表现）
        _sub_field_left = 5.0                    # 权威 tag + 节拍/回充复位
        _sub_field_tick_left = 0.0
        _sub_absorb_gate_left = 0.0
        _sub_absorb_reduced = 0.0
    else:
        invuln_left = maxf(invuln_left, 3.0)     # 普通版逐位不变
        _skill_shield_left = 3.0
```

施放时判定 flag：**档期中抽到升华卡（`apply_choice` → `enable_sublime()` 置 `skill_sublime=true`，_card_system.md:183-191）不影响当次已展开的普通护盾**（下次施放生效），语义简单且对自动施法（R241）零特判。

### 挂点 2：`take_contact_damage` 无敌闸（player.gd:436-437）

```gdscript
if _dead or invuln_left > 0.0:
    if _sub_field_left > 0.0:
        _sub_absorb_hit()          # 升华力场：吞下这口伤害 → 回充（内部自带节流与帽）
    return

func _sub_absorb_hit() -> void:
    if _sub_absorb_gate_left > 0.0 or _sub_absorb_reduced >= 20.0:
        return
    _sub_absorb_gate_left = 0.5
    _sub_absorb_reduced += 2.0
    skill_cd_left = maxf(skill_cd_left - 2.0, 0.0)
    EventBus.emit_shield_blocked(global_position)   # 复用格挡涟漪表现（event_bus.gd:196 先例）
    DebugStats.count(&"sub_field_absorb")           # 可观测口（1Hz 差分判读）
```

### 挂点 3：`tick` 无敌帧衰减块后（player.gd:246-249 之后，照毒云节拍 :272-281 先例）

```gdscript
if _sub_field_left > 0.0:
    _sub_field_left = maxf(_sub_field_left - p_game_delta, 0.0)
    _sub_absorb_gate_left = maxf(_sub_absorb_gate_left - p_game_delta, 0.0)
    _sub_field_tick_left -= p_game_delta
    if _sub_field_tick_left <= 0.0:
        _sub_field_tick_left += 0.5
        _sub_field_pulse()
```

```gdscript
func _sub_field_pulse() -> void:
    # 结构 = _skill_stomp 击退段（player.gd:1153-1159）+ _skill_poison_nova 结算段（:746-774）
    var grid: Variant = _deps.get("enemy_grid")
    var pipeline: Variant = _deps.get("pipeline")
    var w0: Variant = weapon_slots[0] if weapon_slots.size() > 0 else null
    if grid == null or w0 == null:
        return
    var base := float((w0 as WeaponBase).build_panel_snapshot().get("base_atk", 0.0)) * 0.15
    for e in (grid as SpaceGrid).query_circle(global_position, 120.0):
        if e == null or bool(e.get("dead")):
            continue
        var ctx := DamageContext.make()
        ctx.source_uid = int(get_instance_id())     # 玩家侧幂等键（Player 无 uid 字段，同 nova 口径）
        ctx.target = e
        ctx.target_uid = int(e.get("uid"))
        ctx.frame_stamp = GameConfig.frame_stamp
        ctx.base_atk = base
        ctx.element = GameConst.Element.KIN         # 无元素通道（R199 D14 口径，免疫敌不拦零）
        ctx.hit_flags |= GameConst.HIT_IS_AOE_SECONDARY
        ctx.crit_chance = 0.0                       # 技能通道不吃暴击（同 :767）
        ctx.pos = (e as Node2D).global_position
        _inject_relic_pools(ctx, e)                 # R199 D07 遗物乘区同注入
        if pipeline != null and (pipeline as Object).has_method(&"resolve"):
            pipeline.call(&"resolve", ctx)
        if e.has_method(&"knockback"):
            e.call(&"knockback",
                ((e as Node2D).global_position - global_position).normalized() * 220.0)
    DebugStats.count(&"sub_field_pulse")
```

### 挂点 4：`_skill_fx_duration` 哨兵分支（player.gd:872-873）

```gdscript
&"sentinel":
    return 5.0 if skill_sublime else 3.0    # 金环倒数弧/HUD 时长条与实际同步
```

### 挂点 5：`_reset_skill_temp_state`（player.gd:809）追加收口

```gdscript
_sub_field_left = 0.0
_sub_field_tick_left = 0.0
_sub_absorb_gate_left = 0.0
_sub_absorb_reduced = 0.0
# skill_sublime 本身不在此清（局内 buff 态）：重开/换局由 GameLoop 复位清零；
# 暂停→继续局例外保真——serialize_run（game_loop.gd:2738）落单键
# "sublime": {on, fission_layers}，继续局 set_character 重建清零后，_restore_run_state
# 在 set_character 之后照 R212 skill_cd 回填序（game_loop.gd:2912-2915 同位）
# clampf/幂等回填 enable_sublime()；旧档无键 → 不回填，零迁移
```

### 表现层建议（cards/ui 泳道裁定）

- 吸收回充：复用 `emit_shield_blocked` 涟漪（零新增信号即可读）；
- 相位反冲：建议新增轻量事件 `field_pulse(pos, radius)`（照 `poison_cloud_tick` 的「表现层专用」签名先例 event_bus.gd:44），或复用该信号由 fx 层按 character_id 分流配色（哨兵青金色）。

---

## 7. 测试要点（tests/runner 探针式套件，建议文件对：入口 `test_sublime_sentinel.gd` ＋ 用例体 `sublime_sentinel_cases.gd`）

按项目惯例：`-s` 入口只 load cases 体（入口编译早于 autoload）；勿 add_child 池化节点；GDScript 类型化赋值先判 `is_instance_valid`。

| # | 用例 | 断言 |
|---|---|---|
| 1 | 普通版回归 | `skill_sublime=false` → activate 后 `invuln_left==3.0`、`_skill_shield_left==3.0`、`_sub_field_left==0`（普通版逐位不变） |
| 2 | 升华施放 | flag=true → `invuln_left==5.0`、`_sub_field_left==5.0`、`_skill_fx_max==5.0` |
| 3 | 相位反冲 | 真件武器 + grid 内 120px 放 1 敌 → tick 0.5s 敌掉血 = 15% base_atk（KIN / AOE_SECONDARY / crit 0） |
| 4 | 反冲节拍 | 5s 全程恰好 10 跳（`sub_field_pulse` 计数 ==10）；力场结束后不再跳 |
| 5 | 吸收节流 | 力场内同帧连打 `take_contact_damage` ×10 → `skill_cd_left` 只减 2.0、`_sub_absorb_reduced==2.0` |
| 6 | 回充帽 | 模拟跨 5s 的 12 次节流到期吸收 → 累计回充 ==20.0 封顶 |
| 7 | 归零保护 | `skill_cd_left<2` 时吸收 → clamp 到 0 不为负 |
| 8 | 强限定 | 非升华无敌期（如手动置 `invuln_left=1.0`）被打 → CD 不减（`_sub_field_left==0` 分支） |
| 9 | 收口 | `_reset_skill_temp_state` 后 `_sub_field_*` 全 0（重开/换角/复活路径 player.gd:1284 先例） |
| 10 | 击退分级 | 脉冲击退对 boss 免疫、精英 ×0.35（`knockback` 内建口径，只验调用参数 220 不越 stomp 的 280） |
| 11 | 续档保真 | 升华局 `serialize_run` 含 `"sublime": {"on": true}`（哨兵无 fission_layers）；暂停→继续局（set_character 重建）后 `skill_sublime==true`、下次 activate 走 5s 升华分支；未升华局/旧档无键恢复后仍 `false`（零迁移） |

用例 11 归口 **r212_skillresume 套件**（总监修订指定的键往返保真断言处）；本套件只做引用冒烟（续档后 activate → `invuln_left==5.0`）。

命令：`Godot_v4.3-stable_win64.exe --headless --path repo -s tests/runner/test_sublime_sentinel.gd`（exit 0 = 全过）。`-s` 目标**必须是入口脚本**（入口编译早于 autoload，故入口在 autoload 就绪后 load 用例体——同 `test_r212_skillresume.gd` → `r212_skillresume_cases.gd` 的现行文件对结构）。

---

## 8. 边界与兼容

- **自动施法（R241）**：升华版走同一 `activate_skill` 入口，零特判；「高压自动回充」与自动施法天然互补。
- **格挡力场（MEC_SHIELD 词条）**：无敌闸在最前（:436），升华力场期间词条护盾不消耗（无敌优先于格挡），与普通版哨兵行为一致。
- **结晶晶盾 dr**：力场期内无敌已挡全部伤害，dr 无从叠加，无交互。
- **档期中抽卡**：只影响下次施放（挂点 1 判定时机）。
- **复活/重生**：`_reset_skill_temp_state` 收口（挂点 5），重生无敌（RESPAWN_INVULN_S）不计吸收（挂点 2 强限定）。
- **暂停→继续局（升华位保真，总监修订必修）**：`serialize_run`（game_loop.gd:2738）新增单键 `"sublime": {on: bool, fission_layers: int}`（哨兵只写 `on`）；继续局经 `set_character` 重建（`skill_sublime` 随之清零）后，`_restore_run_state`（game_loop.gd:2847）在 set_character 之后按 R212 skill_cd 同序（:2912-2915 先例）clampf/幂等回填 `enable_sublime()`——0.001% 抽到的升华不再因暂停续档蒸发；旧档无键零迁移。力场瞬态（`_sub_field_left`/`_sub_absorb_reduced`）**不入档**：续档视为力场已结束（与 `invuln_left` 走 RESUME_GRACE_S 保护帧同口径），升华位与 skill_cd（R212 键）保真，下次施放即升华版。
- **HUD 读口**：技能键升华红描边统一读 `player.get("skill_sublime")`（命名归一口径；hud.gd:277-302，has_method 守卫同 R186 式）。
- **顿帧/暂停**：全部计时走 `p_game_delta` 通道（tick/_tick_visual 现行口径），自然冻结。

---

## 9. 文案汇总

| 项 | 内容 |
|---|---|
| 升华技能名 | 绝对屏障 |
| 升华 desc | 展开 5 秒绝对屏障：每 0.5 秒对身旁 120px 内敌人反冲 15% 攻击并击退；吞下来袭伤害即为屏障回充 2 秒冷却（单次施放至多回充 20 秒） |
| 卡面风味字（建议） | 「紧急已成为过去——力场即主权。」 |
