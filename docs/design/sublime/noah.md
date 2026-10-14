# 诺亚（noah·召唤师）技能升华设计——「万械共鸣」

> 红色传说 buff 卡「技能升华」（0.001% 爆率）命中后，本局 noah 的主动技能「召唤僚机」升级为升华版「万械共鸣」。
> 本文档为设计定案：数值真源 + 机制 + 伪代码 + 测试要点。所有行号锚点在本会话实读核实（见 §0）。
> CD 维持 120s 基准，无例外（升华只放大窗内与滚存收益，不动冷却轴——CDR 词条叠加下 R246 幂等口径继续成立）。
> 修订（总监意见，本会话二次实读核验）：①升华标志统一命名 `skill_sublime: bool` + 统一入口 `enable_sublime() -> void`（卡系统契约口径，弃 `_sublime_skill` 私名）；②护航舰寿命与升华窗全程同步——拔掉 `SummonDrone._life_left` 的 10.0 硬编码（player.gd:1511）；③升华标志暂停续档经卡系统 `serialize_run` 单键承载的边界写明（§2.2）。
> 修订2（复核轮，第三轮实读核验）：§0 全部锚点逐条复核命中——含 player.gd:1511 寿命硬编码 / :1492 相位分母硬编码（3 舰 i=2 撞整拍实证）/ :1571 舰弹乘区 / game_loop.gd:2738 serialize_run 与 :2903-2915 R212 恢复序先例 / event_bus.gd:19+:115-117 / 三处 `enemy_killed` 订阅先例（enemy_spawner.gd:32、relic_handler.gd:227、game_loop.gd:2395）；r212_skillresume 套件现存（`tests/runner/test_r212_skillresume.gd`+cases 体），§5 尾注引用属实。fission.md 双砍（Ω-超频 12%→8% / 即时糖 10%→8%）与本设计零交集：§三 平衡核算不消费 SUBLIME_MODPARTS / SUBLIME_INSTANT_ATK，数值无随动。§5 用例 1 断言按意见原文显式化「16s 时 3 舰仍在场」。

---

## 〇、本会话验证记录（实读锚点）

| 锚点 | 核实内容 |
|---|---|
| `repo/scripts/meta/character_table.gd:68-74` | noah 定义：血 50 / 攻 +5%，技能「召唤僚机」，`skill_desc`＝随机复制 2 把当前武器（含全部强化）参战 10s，舰体伴随火力＝主武器 ATK 12%，`cd=120.0`，`unlock_achievement=wave_20` |
| `repo/scripts/entities/player/player.gd:157-158` | `SUMMON_COPIES := 2` / `SUMMON_DURATION := 10.0`（常量真源） |
| `player.gd:936-979` | `_skill_summon_orbs`：先 `_summon_restore()`（R246 叠层根治）→ `_spawn_fallback_drones()` → 复制池过滤 `W5_prism` → 随机 2 副本（相位错开 `cooldown_left = interval × i/N`）→ `_summon_left = 10.0` → 横幅「召唤僚机：复制了 X (+ Y)」 |
| `player.gd:982-1014` | `_make_weapon_copy`：`copy_full` 词条栈全量拷 + `copy.level/meta_atk_pct` 继承 + ELE 反应乘区按副本 uid 独立注册 → `_apply_copy_ruling` |
| `player.gd:1017-1031` | `_apply_copy_ruling`：W4 `sub_beams_override=0` + `copy_tint` 等折减裁定 |
| `player.gd:1135-1148` | `_summon_restore`：护航舰/副本回收 + ELE `unregister_reaction_mult`，对空数组幂等 |
| `player.gd:809-819` | `_reset_skill_temp_state`：换角色/重开收口（毒云清零 + `_summon_restore`；刻意不含镜面） |
| `player.gd:283-286` | tick 内 `_summon_left` 推进 → 归零即 `_summon_restore()` |
| `player.gd:339-352` | tick 火段：副本（`_summon_copies`）/镜面/护航舰（`_summon_drones`）同拍 `tick(p_game_delta)` 驱动 |
| `player.gd:1481-1494` | `_spawn_fallback_drones`：2 架 SummonDrone，侧翼 ±74px，相位错开（分母硬编码 `SUMMON_COPIES`，:1492）——**不接收时长参数，舰体寿命走内部默认值** |
| `player.gd:1497-1574` | `SummonDrone` 内部类：`FIRE_INTERVAL=0.55`、射程 340px、`_fire_at_nearest` 弹伤 `panel_snapshot.base_atk = 主武器面板 × 0.12`（:1561-1571），弹 `weapon_uid = 宿主实例 id`（:1570，无独立击杀归因通道） |
| `player.gd:1511` + `:1527-1537` | `var _life_left := 10.0` **舰体寿命硬编码**：tick 内 `-= p_game_delta` 至 `<=0` 即 `queue_free()` 自毁（:1527-1529），末 1.5s 闪烁预警（:1535-1537）。升华 16s 基时/24s 满窗下第 10s 舰体先于窗自毁（§4.1 修复点） |
| `player.gd:860-862` | `activate_skill` 尾段 `_skill_fx_left = _skill_fx_max = _skill_fx_duration()`——**在 match 分支之后执行**（升华分支先更新 `_resonance_time_bonus` 再被此处读取的时序依据；现 noah 分支返回 `SUMMON_DURATION`=10.0，:878-879，同为 10s 锚） |
| `repo/scripts/loop/game_loop.gd:2903-2915` | 继续局恢复序：`set_character` 重建后逐键回填快照——R212 `skill_cd` 键即「set_character 之后 clampf 回填、旧档无键零迁移」先例（升华标志续档同款，见 §2.2；serialize_run 本体 :2738） |
| `player.gd:868-882` | `_skill_fx_duration`：noah 分支 `return SUMMON_DURATION`（HUD 时长条/光环倒数） |
| `repo/autoload/event_bus.gd:19,115-117` | `signal enemy_killed(enemy: Node2D)` + `emit_enemy_killed`；enemy.gd:1099 死亡时发射；订阅先例：enemy_spawner.gd:32、relic_handler.gd:227、game_loop.gd:2395（信号不带击杀者来源——见 §3.1 归因取舍） |
| `repo/scripts/combat/weapon/mirror_image.gd:86-89` + `repo/scripts/combat/weapon/laser_weapon.gd:564-568` | `meta_atk_pct` **mid-run 回写即时生效**先例（R191 修复确认该字段入伤害面板：`base_atk = get_current_atk() × (1 + meta_atk_pct)`，weapon_base.gd:374） |
| `player.gd:713` | 副本随增益启停即时见效先例（`refresh` 类遍历 `_summon_copies` 同口径） |

---

## 一、普通版基线（现状，一图流）

**「召唤僚机」**（CD 120s）：施放瞬间随机复制 2 把当前已装备武器（`copy_full` 全词条、同等级同养成、ELE 反应乘区按副本 uid 重注册、按 R187 裁定表折减：W4 只主束 / W6 齐射 1 发 / W7 集束 ≤3 / W8 蓄能单例），+ 2 架护航舰（12% 主武器 ATK、0.55s/发、340px），**持续 10s 后全部离场**。效果期内再施放＝先回收再重掷（R246）。

痛点（升华设计靶心）：
1. **一次性**：到期即清零，两波施放之间零沉淀——与「召唤师·使役者」的成长幻想不符；
2. **随机无补偿**：复制 2 把可能歪到弱武器，玩家无任何后手；
3. **伴随火力存在感低**：12% × 0.55s 节拍的舰炮是装饰件。

---

## 二、升华版「万械共鸣」

> 一句话：僚机把每一份击杀记进军械库——**在场越久杀得越多，杀得越多僚机越强、归航越晚、下次出击底子越厚**。

### 2.1 数值对照表（普通 → 升华）

| 参数 | 普通版 | 升华版 | 常量名（拟） |
|---|---|---|---|
| CD | 120s | 120s（不变） | — |
| 复制武器数 | 2 把 | **3 把** | `SUBLIME_SUMMON_COPIES` |
| 基础持续 | 10s | **16s** | `SUBLIME_SUMMON_DURATION` |
| 恋战延时 | — | 共鸣每 5 层 +1s（施放预支 + 窗内跨阈值即时续，封顶 **+8s** → 最长 24s） | `RESONANCE_TIME_PER / RESONANCE_TIME_BONUS_CAP` |
| 护航舰数 | 2 架 | **3 架** | 同 `SUBLIME_SUMMON_COPIES` |
| 护航舰弹伤 | 12% 主武器 ATK | **18%** 主武器 ATK × 共鸣乘区 | `SUBLIME_DRONE_ATK_PCT` |
| 护航舰寿命 | 10s（`SummonDrone._life_left` 默认值硬编码，player.gd:1511） | **与本窗全程同步**：施放即置 16s+预支，延时兑点同帧随涨（舰体不先于窗离场） | —（随窗推导，无独立常量） |
| 副本伤害 | 基准 | **× (1 + 1.5% × 共鸣层数)**（封顶 40 层 → ×1.6） | `RESONANCE_DMG_PER_STACK / RESONANCE_MAX` |
| 共鸣层数 | — | 僚机在场期间全场击杀 +1/只；封顶 40；**本局永久、跨施放保留、到期不清零**；换角色/重开清零 | `_resonance_stacks` |
| 施放横幅 | 「召唤僚机：复制了 X + Y」 | 「万械共鸣：复制了 X + Y + Z（共鸣 N 层）」 | — |
| 复制池/折减裁定 | 排除 W5、R187 折减表 | **逐条不变**（升华不触碰 R187 区分总裁定） | — |

### 2.2 核心新机制：军械共鸣（一条层数驱动三个消费口）

贴合点：普通版的身份是「临时复制 + 到期清场」，升华把「临时」改成「有记忆的军团」——**层数是唯一新增状态**，三个消费口全部读它，无平行系统：

1. **获取（杀人书）**：`_summon_left > 0` 窗口内，`EventBus.enemy_killed` 每次广播 +1 层（封顶 40）。主题：僚机在战场记录每一份击杀数据。
   - 归因取舍：信号不带击杀者（`emit_enemy_killed(self)`，enemy.gd:1099；`apply_damage(p_value)` 无来源通道），按「僚机在场期间的全场击杀」计——避免为本卡新建击杀归因管线（伤害管线改动远超升华卡 scope）。工程上等价于「技能窗内的波次清怪速率」，速率天然随波次成长，与书曲线同构。
2. **即时转化（层数→火力）**：每层为**在场全部副本武器与护航舰弹** +1.5% 伤害乘区。挂点：副本 `meta_atk_pct` live 回写（镜面 R191 同款先例，`weapon_base.gd:374` 确认即时入面板）；舰弹在 `_fire_at_nearest` 的 `panel_snapshot.base_atk` 乘区（player.gd:1571 邻位改 2 行）。层数涨的**当帧**回写，下一发弹即吃满。
3. **恋战延时（层数→时长）**：施放时按存量层数预支 `floor(层数/5)s`；效果期内每跨一个 5 层阈值即时 `_summon_left += 1`（封顶 +8s），**同帧同步全部 `_summon_drones[i]._life_left += gain`**——窗长、HUD 时长条、舰体寿命三处一体同涨，永不脱钩（修复 :1511 硬编码下「窗 16s 舰 10s 自毁、恋战延时只抬窗抬不到舰」）。「战斗越激烈，僚机越不肯归航」——把清怪速率反馈成可见的时长条延长。

到期/再施放：`_summon_restore` 照旧回收副本与舰体，**不清层数**（书跨施放滚存；R246 先回收再重掷的幂等口径不动——新副本施放即按存量层数拿到全额乘区与预支时长）。换角色/重开/续档重建：`_reset_skill_temp_state` 清书与已兑延时（本局身份）。

**暂停续档边界**（总监裁定，衔接卡系统 `_card_system.md`）：升华标志本身经 `serialize_run`（game_loop.gd:2738）新增单键 `"sublime": {on: bool, fission_layers: int}` 承载，`_restore_run_state` 在 `set_character` 之后按 R212 `skill_cd` 同款 clampf/幂等回填 `enable_sublime()`——0.001% 抽到的升华不因暂停续档蒸发（旧档无键零迁移；往返保真由 r212_skillresume 套件断言）。**该键无 noah 位：共鸣层数是局内易变态，不序列化**——续档重建后从 0 起算（与换角色清零同口径）。

### 2.3 边界裁定（防撞已有红线）

- **R187「临时件永不产出永久件」不冲突**：该裁定针对复制池产出永久武器槽位件（排除 W5 的理由）。共鸣层数是纯数值态：不占槽位、不进 `_summon_copies`/`_mirror_images`、不进选卡目标与存档序列化，仅在副本/舰弹的面板乘区上消费。
- **与 W5 镜面军团读感区分**：镜面＝永久白板（零 buff、银白染色）；共鸣＝本局数值书（全 buff 副本、金色染色 + 层数读条）。升华不新增任何「永久武器件」。
- **弹生成配额**：副本 2→3 后 `_summon_copies` 与本体共享 `SPAWN_QUOTA_PER_STEP=32`（player.gd:320-335）——配额机制天然钳制齐射帧，无需额外处理；这是副本数止步于 3 的主因（4 把边际收益被配额挤占且伤本体手感）。

---

## 三、平衡核算（期望模型）

**模型假设**（写明口径，供测试与验收对表）：
- 本体持续火力 = 1.0；单副本有效火力 = k ≈ 0.7（R187 折减裁定均摊：W4 只主束 / W6 齐射 1 发 / W7 ≤3 集束 / W8 蓄能单例，W1 近全值）；
- 护航舰组合计 ≈ 普通版 0.10 / 升华版 0.16（12%→18% × 舰数 2→3，0.55s 节拍折算）；
- 全程平均战力 = 1 + 窗内附加火力 × (有效窗长 / 120s)。
- 上表升华列**默认护航舰与副本全程在场**——该假设由 §4.1 舰体寿命同步修复兜底（修复前 :1511 硬编码 10s 自毁，16s/24s 窗后段舰炮实际不存在，护航舰火力按全程计会高估）。

| 阶段 | 窗内附加 | 窗内总火力 | 有效窗 | 全程平均 vs 本体 | vs 普通版全程 |
|---|---|---|---|---|---|
| 普通版 | 2×0.7 + 0.10 = 1.50 | 2.50× | 10s | **1.13×** | 1.00× |
| 升华·首放（0 层） | 3×0.7 + 0.16 = 2.26 | 3.26× | 16s | 1.30× | 1.15× |
| 升华·中期（≈20 层，×1.3） | 3×0.7×1.3 + 0.16×1.3 = 2.94 | 3.94× | 16+4=20s | 1.51× | 1.34× |
| 升华·满层（40 层，×1.6） | 3×0.7×1.6 + 0.16×1.6 = 3.62 | 4.62× | 16+8=24s | **1.72×** | **1.53×** |

- **窗内峰值口径**：满层 4.62 / 普通 2.50 = **1.85×**；**全程稳态口径**：满层后每次施放均为 1.72× vs 1.13× = **1.53× 全程 / 1.85× 峰值**，两口径均落 1.6~2.2 目标的下沿至中段。
- **成长型前低后高是本设计的刻意曲线**（「杀人书」代价）：首放必然发生在层数=0 的局早期（1.15×），中期 1.34×，后期满层稳态 1.53~1.85×。若验收口径要求「全程平均 ≥1.6×」，调参优先级：`RESONANCE_DMG_PER_STACK` 1.5%→2.0%（满层 ×1.8 → 窗内 5.07× / 全程 1.81×）＞ 时长 +8s→+10s（占空比 21.7%）＞ 副本 3→4（受配额钳制，不推荐）。
- **护航舰不再装饰**：18% × 共鸣乘区 × 3 舰，满层单窗舰炮 ≈ 0.26 本体火力，可感知但不抢副本戏。
- **不叠乘区**：共鸣乘区只乘副本/舰弹，不乘本体武器、不进 ELE 反应乘区（副本的 ELE 注册值照 R183 原值，防 ×雪球）。

---

## 四、实现挂点与伪代码

### 4.1 挂点清单（`player.gd`）

| 挂点 | 改动 |
|---|---|
| 常量区 `player.gd:157-158` 邻位 | 新增升华常量组（§2.1 表）+ 状态 `var _resonance_stacks := 0`、`var _resonance_time_bonus := 0.0`、`var _summon_meta_base: Array[float] = []`（副本乘区基准快照） |
| `enable_sublime()`（skills 泳道统一入口，卡系统契约） | 内部置 **`skill_sublime = true`**（全体 10 角色统一字段名）并分发角色初始化；HUD 技能键红描边读口统一 `player.get("skill_sublime")`。noah 分支无额外初始化态——书与已兑延时均懒起算（首次升华施放时按存量/0 结算） |
| `_skill_summon_orbs` `player.gd:936-979` | 入口按 **`skill_sublime`**（`enable_sublime()` 置位的局内标志）分派：副本数 3、**dur 先算**（16s + 预支延时）再传 `_spawn_fallback_drones(dur)`、横幅带层数；副本 append 时同步记 `_summon_meta_base` |
| `_spawn_fallback_drones` `player.gd:1481-1494` | **签名加参 `p_dur: float = SUMMON_DURATION`**（默认值=普通版现行为，:947 无参调用零改动）：生成时置 `drone._life_left = p_dur`（拔掉 :1511 硬编码 10s）；舰数与相位分母随升华态取 n=2/3——原 :1492 分母硬编码 `SUMMON_COPIES`，3 舰时 i=2 相位=0.55×(2/2) 整拍、与 0 号舰永久同拍（错开失效），须改 `/float(n)` |
| `_make_weapon_copy` `player.gd:982-1014` | `copy.meta_atk_pct = p_src.meta_atk_pct + 共鸣加成`（施放即全额继承存量层数） |
| `_skill_fx_duration` noah 分支 `player.gd:878-879` | `return (SUBLIME_SUMMON_DURATION + _resonance_time_bonus) if skill_sublime else SUMMON_DURATION`——HUD 时长条初值含预支（时序成立：match 分支先更新 `_resonance_time_bonus`，:860-862 在其后读取） |
| tick 到期段 `player.gd:283-286` | 零改动（恋战延时直接抬 `_summon_left`；`_skill_fx_left/_skill_fx_max` 与舰体 `_life_left` 在延时兑点同步 `+= gain`——舰体 tick 与本体同拍同 delta（:350-352），寿命同设同涨后不漂移） |
| `_summon_restore` `player.gd:1135-1148` | 回收逻辑零改动；**刻意不清 `_resonance_stacks`**（到期=书保留） |
| `_reset_skill_temp_state` `player.gd:809-819` | 追加清书与已兑延时：`_resonance_stacks = 0`、`_resonance_time_bonus = 0.0`（换角色/重开/续档重建口径） |
| `SummonDrone._life_left` `player.gd:1511` | 默认值 10.0 仅作普通版兜底；升华路径经 `_spawn_fallback_drones(p_dur)` 注入本窗 dur（含施放预支）。末 1.5s 闪烁预警（:1535-1537）读 `_life_left`，语义随新寿命自动对齐，零改动 |
| `SummonDrone._fire_at_nearest` `player.gd:1561-1571` | 弹伤系数 0.12 → 宿主升华 ? 0.18 : 0.12，再乘 `(1 + 1.5% × 层数)`（宿主字段经 **`p_host.get("skill_sublime")`** / `p_host.get("_resonance_stacks")` 读取——该函数已是鸭子读法） |
| 订阅口（`_ready` 或 `setup`） | `EventBus.enemy_killed.connect(_on_resonance_kill)`（enemy_spawner.gd:32 同款；断连随节点销毁/换局收口） |

### 4.2 伪代码（GDScript 骨架，非最终实现）

```gdscript
# ── 常量（player.gd:157 邻位） ──
const SUBLIME_SUMMON_COPIES := 3
const SUBLIME_SUMMON_DURATION := 16.0
const SUBLIME_DRONE_ATK_PCT := 0.18
const RESONANCE_MAX := 40
const RESONANCE_DMG_PER_STACK := 0.015
const RESONANCE_TIME_PER := 5          # 每 5 层 +1s
const RESONANCE_TIME_BONUS_CAP := 8.0

# var skill_sublime := false   # ← 卡系统统一契约字段：enable_sublime() 置位（skills 泳道
#                              #   统一入口，含角色初始化分发）；HUD 红描边读口
#                              #   player.get("skill_sublime")。noah 文档全程用此名。
var _resonance_stacks := 0
var _resonance_time_bonus := 0.0       # 当窗已兑延时 s（施放预支 + 窗内兑点累计）
var _summon_meta_base: Array[float] = []   # 副本 meta_atk_pct 基准（防重复叠加）

func _on_resonance_kill(_e: Node2D) -> void:
    if not skill_sublime or _summon_left <= 0.0:
        return                              # 窗外击杀不计
    if _resonance_stacks >= RESONANCE_MAX:
        return
    _resonance_stacks += 1
    _apply_resonance_mult()                 # 即时火力回写
    # 恋战延时：跨 5 层阈值即时 +1s（封顶 +8s）——窗长/时长条/舰体寿命三处同帧同涨
    var target := minf(floorf(float(_resonance_stacks) / RESONANCE_TIME_PER),
            RESONANCE_TIME_BONUS_CAP)
    if target > _resonance_time_bonus:
        var gain := target - _resonance_time_bonus
        _resonance_time_bonus = target
        _summon_left += gain                # tick 段 283-286 零改动即消费
        _skill_fx_left += gain              # HUD 时长条/光环倒数同步延长
        _skill_fx_max += gain
        for d in _summon_drones:            # 舰体寿命随窗同步——不提前离场（修复点）
            if d != null and is_instance_valid(d):
                d._life_left += gain

func _apply_resonance_mult() -> void:
    var bonus := RESONANCE_DMG_PER_STACK * _resonance_stacks
    for i in _summon_copies.size():
        var c := _summon_copies[i]
        if c != null and is_instance_valid(c):
            c.meta_atk_pct = _summon_meta_base[i] + bonus   # 基准+加成，幂等可重入
    # 护航舰无字段：_fire_at_nearest 开火时现读层数（见 4.1 末行挂点）

func _skill_summon_orbs() -> void:          # 升华分支骨架
    _summon_restore()                        # R246 前置回收——升华同口径
    _summon_meta_base.clear()
    var dur := SUMMON_DURATION               # dur 必须先算：舰体寿命/时长条初值都吃它
    if skill_sublime:
        _resonance_time_bonus = minf(floorf(float(_resonance_stacks)
                / RESONANCE_TIME_PER), RESONANCE_TIME_BONUS_CAP)   # 存量预支
        dur = SUBLIME_SUMMON_DURATION + _resonance_time_bonus
    _spawn_fallback_drones(dur)              # 舰体寿命=本窗 dur（含预支）——修复 :1511 硬编码
    var copies_n := SUBLIME_SUMMON_COPIES if skill_sublime else SUMMON_COPIES
    # …（复制池过滤 W5 / 随机 / 相位错开：照现逻辑，range(copies_n)）
    #   _make_weapon_copy 内：copy.meta_atk_pct = p_src.meta_atk_pct
    #       + (RESONANCE_DMG_PER_STACK * _resonance_stacks if skill_sublime else 0.0)
    #   append 时：_summon_meta_base.append(p_src.meta_atk_pct)
    _summon_left = dur
    # 横幅：skill_sublime 时「万械共鸣：复制了 X + Y + Z（共鸣 N 层）」
    # 注：activate_skill :860-862 随后经 _skill_fx_duration() 读
    #   SUBLIME_SUMMON_DURATION + _resonance_time_bonus（match 分支已先行更新预支值）——
    #   HUD 时长条初值即含预支，与本窗对齐

func _spawn_fallback_drones(p_dur: float = SUMMON_DURATION) -> void:
    # 签名加参：默认值=普通版现行为（:947 无参调用零改动）；舰数 n 随升华态取 3/2
    var n := SUBLIME_SUMMON_COPIES if skill_sublime else SUMMON_COPIES
    for i in range(n):
        var drone := SummonDrone.new()
        # …（命名/侧翼 ±74px 照现逻辑 :1487-1488）
        drone._life_left = p_dur            # ← 拔掉 :1511 硬编码 10.0（本窗全程在场）
        if i > 0:
            drone._fire_left = SummonDrone.FIRE_INTERVAL * (float(i) / float(n))
                                            # 相位分母随舰数 n——原 /SUMMON_COPIES 在
                                            # 3 舰时 i=2 撞整拍、与 0 号舰永久同拍
        # add_child(drone) / _summon_drones.append(drone) 照现逻辑

# SummonDrone._fire_at_nearest（player.gd:1561-1571 两行改）：
#   var pct := 0.18 if bool(p_host.get("skill_sublime")) else 0.12
#   var res := 1.0 + RESONANCE_DMG_PER_STACK * int(p_host.get("_resonance_stacks"))
#   … "base_atk": base * pct * res
```

---

## 五、测试要点（`tests/runner/test_sublime_noah.gd`，SceneTree 探针式）

套件遵守项目坑位约定：`-s` 入口脚本只 `load` cases 体（入口编译早于 autoload）；断言内勿 `add_child` 池化节点（副本是 WeaponBase 普通节点、护航舰 SummonDrone 是 Node2D——按现套件对 `_summon_copies` 的既有断言模式走）。

| # | 用例 | 断言要点 |
|---|---|---|
| 1 | 升华分派 | `skill_sublime=true` 施放后 `_summon_copies.size()==3`、`_summon_drones.size()==3`、`_summon_left == 16.0`（0 层时）；**舰体 `_life_left == 16.0`，tick 推进 10.0s（旧硬编码自毁点）后 `_summon_drones.size()==3` 且全部 `is_instance_valid`；推进至 16.0s（窗尽时）`_summon_drones.size()==3` 仍在场——跨过 16.0s `_summon_left` 归零帧方触发 `_summon_restore` 清场** |
| 2 | 普通回归 | `skill_sublime=false` 逐位不变：2 副本 / 2 舰 / 10.0s / 舰体 `_life_left == 10.0`（默认参回归锚）/ 舰弹 `base_atk == base×0.12`（升华标志是纯增量，基线零回归） |
| 3 | 层数获取 | 窗内 `EventBus.emit_enemy_killed(e)` ×50 → `_resonance_stacks==40`（封顶）；窗外（`_summon_left==0`）emit 不涨 |
| 4 | 即时乘区 | 层数=10 时副本 `meta_atk_pct == src值 + 0.15`；跨层回写幂等（重复 `_apply_resonance_mult` 值不变——基准快照防叠错）；舰弹 `base_atk == base×0.18×1.15` |
| 5 | 恋战延时 | 0 层施放→窗内杀满 40：`_summon_left` 总增量 == 8.0；且任一时刻 `_summon_left ≤ 24.0`；`_skill_fx_max` 同步 == 24.0；**兑点帧 `_summon_drones[i]._life_left` 同步 `+= gain`（逐舰断言），满层全程 3 舰在场直至 24.0s 窗尽** |
| 6 | 施放预支 | 先积 23 层（窗外/上一窗）→再施放：`_summon_left == 16.0 + 4.0`（floor(23/5)=4）；`_skill_fx_max == 20.0`（:860-862 经 `_skill_fx_duration` 读预支——HUD 初值对齐）；舰体 `_life_left == 20.0` |
| 7 | 书保留/清零 | `_summon_restore()` 后 `_resonance_stacks` 原值保留；`_reset_skill_temp_state()` 后 `_resonance_stacks==0` 且 `_resonance_time_bonus==0.0` |
| 8 | R246 幂等 | 升华效果期内再施放：旧副本/舰先回收（`_summon_copies` 无泄漏、ELE `unregister` 已调）再重掷 3 把 |
| 9 | 配额共存 | 帧率优先模式下 3 副本 + 本体同帧 due：`quota_request` 放行合计 ≤ `SPAWN_QUOTA_PER_STEP`（沿 R220 刀12 断言模式） |

运行命令（沿用引擎路径约定）：
`E:\Code\Agent\Infinite-Fission\android_export\Godot_v4.3-stable_win64.exe --headless --path E:\Code\Agent\Infinite-Fission\repo -s tests/runner/test_sublime_noah.gd`（exit 0 = 全过）

> 升华标志本身的暂停续档往返（`serialize_run` `"sublime"` 键 → `_restore_run_state` 回填 `enable_sublime()`）由卡系统在 `r212_skillresume` 套件断言，本套件不重复覆盖；本套件只锁 noah 局内行为（§2.2 边界：共鸣层数不序列化）。

---

## 六、验收清单（摘要）

- [ ] 升华仅经卡系统统一入口 `enable_sublime()` 置 **`skill_sublime`** 生效（字段名/入口与全体 10 角色及 HUD 读口 `player.get("skill_sublime")` 同口径）；普通版路径逐位零回归（用例 2）。
- [ ] 舰体寿命与升华窗全程同步：施放即 16s+预支、延时兑点同帧随涨、16s/24s 全程 3 舰在场（用例 1/5/6）——`player.gd:1511` 的 10s 硬编码不再独立生效。
- [ ] 满层窗内峰值 4.62× / 全程稳态 1.72×（模型 §三，验收以用例 4/5 的乘区与时长上限代验：×1.6 封顶、+8s 封顶）。
- [ ] R187 区分总裁定逐条不动（复制池排 W5、折减表、金色染色）；共鸣不产任何永久件、不进存档。
- [ ] R246 叠层根治口径在升华分支继续成立（用例 8）。
- [ ] 暂停续档：升华标志经卡系统 `serialize_run` `"sublime"` 键回填 `enable_sublime()` 不丢（r212_skillresume 断言，旧档无键零迁移）；共鸣层数为局内易变态，续档重建后清零重来（§2.2 边界）。
