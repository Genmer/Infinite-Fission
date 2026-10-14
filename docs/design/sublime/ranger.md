# 游侠·岚 · 技能升华设计：「百影穿袭」

> R246 升华卡系统 · 设计师泳道（FEEDBACK_TRACKER 条目 3「全角色两套技能」）。
> 红色传说品质 buff 卡「技能升华」（爆率 0.001%）抽中后，本局 `ranger` 的主动技能
> 由普通版「影袭瞬步」升级为本文升华版。落地接线归 R246 实施员 skills 泳道（player.gd）。
>
> **R246 总监终审修订（2026-10-08）**：① 命名归一——字段 `skill_sublime: bool`（本文原口径即多数派，不变）+ 统一置位入口 `enable_sublime() -> void`（§6.1/§6.2 #10）；② 升华位随档裁定落定——serialize_run 单键 `"sublime"`、继续局 `_restore_run_state` 回填（§6.2 #10/§6.4/§8.3，修复「暂停→继续局升华蒸发」）。
>
> **R246 二审复核（2026-10-08 第二轮，本轮实测）**：① 锚点全量复核——`cd: 120.0` 实际在 character_table.gd:**43**（原引 :44 偏 1 行，已修正），player.gd / game_loop.gd 其余锚点逐一命中；② hud.gd 与 scripts/、tests/ 全库 grep `sublime` **零匹配**（exit 1）——红描边读口为全新接线，无既有撞名实现；③ serialize_run 快照字典（game_loop.gd:2762-2783，20 键）实证**无 sublime 键**——「继续局升华蒸发」缺口属实，§6.2 #10 修法维持；④ 本轮总监另两条必修（noah 召唤舰体 `_life_left` 与升华时长脱钩、fission 口径 B 双砍 12%→8%/10%→8%）不涉本档，归各自泳道文档。

- 角色：`ranger` 游侠·岚（character_table.gd:40-45；血 52 / 攻 +10% / 80 结晶购买解锁）
- 普通版：影袭瞬步——朝移动方向瞬步 260px 并短暂无敌（cd 120.0）
- 升华版：**百影穿袭**——更长更稳的穿袭：沿途敌受创、身后残影自爆拂弹、干净走位蓄「潜影」强化下一击
- CD 基准：**120s 不变**（无例外——本技能是保命位移技，缩 CD 会破坏「节拍式保命」定位；既有 CDR 乘区照常消费）

---

## 1. 普通版现状（代码事实）

| 项 | 值 | 代码锚点 |
|---|---|---|
| 触发分支 | `activate_skill()` match `&"ranger"` | player.gd:839-847 |
| 方向 | `_last_move_dir`（tick 内 total 非零时刷新，player.gd:301-302；ZERO 回落 `Vector2.UP`） | player.gd:840 |
| 位移 | `global_position += dir * 260.0` | player.gd:841 |
| 落点钳制 | `_clamp_to_playfield()`（活动区：x∈[16,704]，y∈[768,1264]，720×1280 下 40% 屏）——R246 修复后口径，任务锚点所引 `_clamp_to_playfield_pos`（player.gd:790-794，全屏界）**已弃用**，现仅存于 :843 注释 | player.gd:846、:1382-1388 |
| 无敌 | `invuln_left = maxf(invuln_left, 1.0)` | player.gd:847 |
| CD | 表 `cd: 120.0` → `refresh_skill_cd()` 乘 CDR 乘区（0.1 地板） | character_table.gd:43、player.gd:683-704 |
| 演出 | 瞬发型默认 0.8s 施放闪光 + `emit_skill_cast` 金环 | player.gd:860-864、:882 |
| 伤害/其他 | **无**——纯位移 + 无敌 | — |

普通版是纯走位保命技：名字里「影袭」的「袭」并无兑现，这是升华版机制设计的切入点。

---

## 2. 升华版总览

一句话：**瞬步化为穿袭**——位移更长、无敌更久、沿途斩击敌人、身后两道残影延时自爆并拂清弹幕；持续不受击则蓄「潜影」层，让下一次穿袭更远更狠（贴合「走位拉满」的角色描述，character_table.gd:40）。

三条新机制（贴合瞬步「位移/无敌/走位」本体，非通用模板）：

- **M1 穿袭路径结算**：瞬步轨迹变为伤害胶囊，被穿过的敌人受一次 `(240% + 40%×潜影层)` 主武器 ATK 结算——把「影袭」的「袭」补全。
- **M2 残影爆破**：起点与轨迹中点各留一道 0.45s 引信残影，爆裂时对 150px 内敌结算 120% ATK + 向外击退，并拂清爆点 110px 内敌方弹幕（每影帽 6 发）——「影遁拂弹」，给贴脸穿袭留退路。
- **M3 潜影蓄能**：连续 12s 未受击 +1 层（帽 4 层）；每层 +30px 瞬步距离、+40% 路径伤害；受击清零、施放全部消耗——把「不被摸到」变成技能资源。

---

## 3. 数值对照表（普通 → 升华）

| 维度 | 普通版 | 升华版 | 倍率/说明 |
|---|---|---|---|
| CD 基准 | 120s | 120s | ×1.0（不变；吃既有养成 CDR / 技能急速 / 时之沙乘区，player.gd:690-692） |
| 瞬步距离 | 260px | 340px（潜影满 4 层 → 460px） | ×1.31~1.77（活动区纵深 496px，满层上穿≈93% 屏，仍被钳制收口） |
| 无敌时长 | 1.0s | 1.8s | ×1.8（仍低于哨兵 3.0s 纯无敌档，不越角色定位） |
| 路径伤害 | — | `(240% + 40%/层)` 主武器 ATK，帽 400%（0 层 240% ~ 满层 400%），AOE_SECONDARY、不暴击、KIN | 新增 |
| 残影爆破 | — | 2 影 × `120% ATK` / r=150px / 引信 0.45s / 击退冲量 160 | 新增 |
| 弹幕拂除 | — | 每影 r=110px 内 team==1 敌弹无效化，帽 6 发/影（合计 ≤12） | 新增 |
| 潜影 | — | 12s/层 · 帽 4 · 受击清零 · 施放消耗 | 新增 |
| 施放演出 | 0.8s | 1.2s（覆盖残影爆窗，HUD 时长条/光环倒数可读） | player.gd:868-882 加 ranger 升华分支 |

单次施放总伤估算（见 §5 假设）：0 层 ≈ 240%×4 + 120%×2×3 = **1680% ATK**；满潜影 ≈ 400%×4 + 720% = **2320% ATK**。

---

## 4. 新机制详设

### M1 穿袭路径结算
- 判定形状：起点→落点线段的胶囊近似（半径 56px；沿线每 64px 步进 `enemy_grid.query_circle`，uid 集合去重——同敌只结一次）。
- 伤害口径：与毒云/毒爆完全同构（player.gd:903-933 模板）——`DamageContext.make()` + `HIT_IS_AOE_SECONDARY` + `crit_chance=0` + `Element.KIN` + `_inject_relic_pools`（player.gd:736-743，技能通道遗物乘区）+ `pipeline.resolve`。
- `base_atk` 真源：`weapon_slots[0].build_panel_snapshot()["base_atk"]`（player.gd:750-753 同口径）；无武器防御路径直接跳过伤害段（仅位移+无敌，不崩）。
- 不清弹、不击退（穿袭是「穿过」不是「推开」；击退会把敌推到自己落点）。
- 施放前先按当前潜影层算 `dmg_pct` 与 `dist`，**再**消耗层（顺序见 §6 伪代码）。

### M2 残影爆破
- 位置：瞬步起点 + 轨迹中点（两合法活动区点的中点仍在凸矩形内，天然合法）。
- 引信 0.45s（`game_delta` 通道，顿帧/暂停自然冻结——毒云同口径 player.gd:272-281）。
- 爆裂：r=150px 圆查询 → 每敌 120% ATK（结算口径同 M1）+ 以爆心向外击退（`e.call(&"knockback", dir*160.0)` 鸭子调用，player.gd:1158-1159 模板）。
- 拂弹：爆心 r=110px 内 `team==1` 弹 → `emit_bullet_nullified` + `nullify()`，帽 6 发/影（player.gd:1160-1169 模板；帽为性能/公平护栏，与复活清弹 24 帽同哲学）。
- 幂等性（R244 诺亚教训显式核查）：残影是自然消费的短命列表；CDR 地板 0.1×120s=12s ≫ 引信 0.45s，**并发残影恒 ≤2**，无叠层数组膨胀路径。

### M3 潜影蓄能
- 蓄能：`skill_sublime && character_id==&"ranger"` 时，每累计 12s 游戏时间未受击 +1 层，帽 4。
- 清零：`take_contact_damage()` **实减 HP 路径**（player.gd:447-454）清零；格挡力场吸收（:439-446）与无敌帧早退（:436-437）**不清**——格挡/无敌不算受创，奖励叠甲走位流。
- 消耗：施放升华穿袭时全部消耗（层在算完本次 `dmg_pct/dist` 后清）。
- 节奏说明（有意设计）：12s×4=48s < 120s CD，故首个 CD 转好后常态满 4 层；动态波动主源是「最近 48s 内是否被摸过」——把受击惩罚直接写进技能强度，走位容错即资源。开局首放（skill_cd_left 初始 0，player.gd:622）通常 0~1 层，成长曲线前倾。

---

## 5. 平衡核算（目标 1.6~2.2×）

**分轴倍率：**

| 轴 | 普通版 | 升华版 | 倍率 |
|---|---|---|---|
| 无敌覆盖/施放 | 1.0s | 1.8s | ×1.8 |
| 有效位移/施放 | 260px | 340~460px | ×1.31~1.77 |
| 弹幕清除/施放 | 0 | ≤12 发 | 新增（小额，定位仍属 bulwark） |
| 伤害/施放 | 0 | 1680~2320% ATK | 新增 |

**假设**（可调参数，实施后用实测覆盖）：
- 路径均命中 4 敌（活动区纵深 496px × 半径 56px 胶囊，中位波密度）；残影均各命中 3 敌。
- 中后期 5~7 武器稳态输出 ≈ 250~400% ATK/s → 技能输出折合角色总输出 **+4~7%**（2320%/120s ≈ 19% ATK/s，占稳态输出个位数百分比，输出轴总量克制）。

**合成判定**：普通版价值 100% 在生存+机动轴（该轴 ×1.8~1.85，含清弹附赠）；输出轴从 0 到 +4~7% 角色占比。按保命型技能「生存机动 ≈85% / 输出 ≈15%」的价值权重折算：

> 综合战力 ≈ 0.85×1.83 + 0.15×1.3 ≈ **1.75×**，波动区间 **1.7~2.0×**——落于 1.6~2.2 目标带内。
> 下限保障：无敌/位移/伤害/清弹四项全为正向、无任何削弱项，不可能低于 1.6；上限保障：单次总伤帽 2320% ATK、CD 不缩、无敌不越哨兵 3.0s 档，不可能高于 2.2。

**横向锚**：mank 毒沼绽放同 CD 全屏 150%×全场（≈20 敌=3000%+）尚且只是「一档输出技能」；游侠升华 2320% 还要求路径站位（贴脸穿袭才有满命中），风险换收益成立。

---

## 6. 实现设计

### 6.1 新增字段（player.gd 成员区，P2 参数惯例 player.gd:150-158）

```gdscript
# ── R246 升华·游侠「百影穿袭」参数（数值真源：docs/design/sublime/ranger.md） ──
const SHADOW_DASH_BASE_DIST := 340.0      # 基础瞬步距离 px（普通版 260 → 340）
const SHADOW_DASH_DIST_PER_LURK := 30.0   # 每层潜影 +30px（满 4 层 460）
const SHADOW_DASH_INVULN := 1.8           # 无敌 s（普通版 1.0 → 1.8）
const SHADOW_DASH_ATK_BASE := 2.4         # 路径伤害 240% 主武器 ATK
const SHADOW_DASH_ATK_PER_LURK := 0.4     # 每层 +40%（满层 400%）
const SHADOW_SWEEP_RADIUS := 56.0         # 穿袭胶囊半径 px
const SHADOW_SWEEP_STEP := 64.0           # 沿线步进 px
const SHADOW_ECHO_FUSE := 0.45            # 残影引信 s
const SHADOW_ECHO_ATK := 1.2              # 残影爆伤 120% ATK
const SHADOW_ECHO_RADIUS := 150.0         # 残影爆伤半径 px
const SHADOW_ECHO_KNOCK := 160.0          # 残影击退冲量
const SHADOW_ECHO_CLEAR_R := 110.0        # 残影拂弹半径 px
const SHADOW_ECHO_CLEAR_CAP := 6          # 每影拂弹帽
const LURK_STACK_MAX := 4                 # 潜影层帽
const LURK_STACK_INTERVAL := 12.0         # 蓄层间隔 s（不受击）

var skill_sublime: bool = false           # 升华标记（本局有效）。置位口 = 统一入口 enable_sublime()（卡契约 _card_system.md:191——注意：该行现行文本仍是 `Player.sublime`+「重置点清零」**旧口径**（二审实测），归卡系统泳道按 R246 归一裁定同步改为 `skill_sublime`+随档回填，本字段按裁定后口径实现；内部置本字段=true 并分发角色初始化——R246 命名归一裁定：字段 skill_sublime / 入口 enable_sublime，player 内部不直接写；HUD 技能键红描边统一读 player.get("skill_sublime")）
var _lurk_stacks: int = 0                 # 潜影层（会话态，不入档）
var _lurk_timer: float = 0.0              # 蓄层计时
var _echo_fuses: Array[Dictionary] = []   # 待爆残影 {pos: Vector2, left: float}
```

### 6.2 挂点（implAnchors）

| # | 挂点 | 改动 |
|---|---|---|
| 1 | `activate_skill()` `&"ranger"` 分支 player.gd:839-847 | `skill_sublime` 为真改调 `_skill_shadow_dash()`；为假原 260px 逻辑**逐字节不动**（零回归） |
| 2 | `_clamp_to_playfield()` player.gd:1382-1388 | 复用（落点钳制单一真源，R246 口径） |
| 3 | `tick()` player.gd:240-354 | 毒云节拍块（:272-281）邻位新增两块：残影引信推进（到点 `_shadow_echo_blast`）、潜影蓄能（帽内计时） |
| 4 | `take_contact_damage()` player.gd:432-459 | hp 实减段（:450-454）后潜影清零；格挡/无敌早退路径不清 |
| 5 | `_skill_poison_nova()` player.gd:746-774 | 结算模板：DamageContext + AOE_SECONDARY + KIN + crit 0 + `_inject_relic_pools`（:736-743）+ `pipeline.resolve` |
| 6 | `_skill_stomp()` player.gd:1151-1169 | 残影击退（:1158-1159 knockback 鸭子调用）与拂弹（:1160-1169 nullify + 帽）模板 |
| 7 | `_skill_fx_duration()` player.gd:868-882 | ranger 升华返回 1.2（HUD 时长条/光环倒数含残影爆窗） |
| 8 | `_reset_skill_temp_state()` player.gd:809-819 | 追加：`_echo_fuses.clear()` + 潜影归零（换角/重开收口）。**只清会话态、不动 `skill_sublime`**——该位随档，生死归局层（新局清零、继续局 `_restore_run_state` 回填，见 #10），player 泳道不在重置函数里清它（避免再撞「set_character 清零 vs 继续局回填」缺口） |
| 9 | 新函数 ×3 | `_skill_shadow_dash()` / `_shadow_sweep_damage()` / `_shadow_echo_blast()`（置于 `_skill_stomp` 邻域） |
| 10 | 接口约定（cards 泳道，R246 终审**已裁定**） | ① 命名归一：置位口 = 统一入口 `enable_sublime() -> void`（幂等；内部置 `skill_sublime=true` 并分发角色初始化，含 fission 回填）；HUD 技能键红描边统一读 `player.get("skill_sublime")`。② 随档：serialize_run（game_loop.gd:2738，`skill_cd` 键 :2776 同层）新增单键 `"sublime": {on: bool, fission_layers: int}`；`_restore_run_state`（game_loop.gd:2847）在 set_character（:2903）**之后** clampf/幂等回填 `enable_sublime()`——与 R212 `skill_cd` 回填（:2915）同型同序，闭合「继续局经 set_character 重建后仅回填快照键、升华蒸发」缺口；`fission_layers` 子键归 fission 泳道，ranger 只消费 `on`；旧档无键零迁移；r212_skillresume 套件补该键往返保真断言。player 侧只提供字段与 `enable_sublime()`，零耦合 |

### 6.3 伪代码

```gdscript
func activate_skill() -> bool:            # player.gd:839 分支内
	...
	&"ranger":
		if skill_sublime:
			_skill_shadow_dash()
		else:
			var dir := _last_move_dir if _last_move_dir != Vector2.ZERO else Vector2.UP
			global_position += dir * 260.0
			_clamp_to_playfield()
			invuln_left = maxf(invuln_left, 1.0)      # ← 普通版原样保留


func _skill_shadow_dash() -> void:
	# 百影穿袭：先按潜影层算参数，再位移/结算，最后消耗层（顺序不可倒）
	var dir := _last_move_dir if _last_move_dir != Vector2.ZERO else Vector2.UP
	var from := global_position
	var dist := SHADOW_DASH_BASE_DIST + SHADOW_DASH_DIST_PER_LURK * float(_lurk_stacks)
	var dmg_pct := SHADOW_DASH_ATK_BASE + SHADOW_DASH_ATK_PER_LURK * float(_lurk_stacks)
	global_position += dir * dist
	_clamp_to_playfield()                    # R246 活动区口径（唯一钳制真源）
	invuln_left = maxf(invuln_left, SHADOW_DASH_INVULN)
	var to := global_position
	_shadow_sweep_damage(from, to, dmg_pct)  # M1 路径结算（uid 去重）
	_echo_fuses.append({"pos": from, "left": SHADOW_ECHO_FUSE})             # M2 起点残影
	_echo_fuses.append({"pos": from.lerp(to, 0.5), "left": SHADOW_ECHO_FUSE})  # 中点残影
	_lurk_stacks = 0                         # M3 施放消耗
	_lurk_timer = 0.0


func _shadow_sweep_damage(p_from: Vector2, p_to: Vector2, p_dmg_pct: float) -> void:
	# 胶囊近似：沿线步进圆查询 + uid 去重；结算口径 = _skill_poison_nova（:746-774）
	var grid: Variant = _deps.get("enemy_grid")
	var pipeline: Variant = _deps.get("pipeline")
	var w0: Variant = weapon_slots[0] if weapon_slots.size() > 0 else null
	if grid == null or w0 == null:
		return
	var base := float((w0 as WeaponBase).build_panel_snapshot().get("base_atk", 0.0))
	var steps := int(ceilf(p_from.distance_to(p_to) / SHADOW_SWEEP_STEP)) + 1
	var hit_uids := {}
	for i in range(steps + 1):
		var c := p_from.lerp(p_to, float(i) / float(maxi(steps - 1, 1)))
		for e in (grid as SpaceGrid).query_circle(c, SHADOW_SWEEP_RADIUS):
			if e == null or bool(e.get("dead")) or hit_uids.has(int(e.get("uid"))):
				continue
			hit_uids[int(e.get("uid"))] = true
			var ctx := DamageContext.make()          # 逐字段同 _poison_cloud_pulse :920-932
			ctx.source_uid = int(get_instance_id())  # 玩家侧幂等键（mank/vera 同口径）
			ctx.target = e
			ctx.target_uid = int(e.get("uid"))
			ctx.frame_stamp = GameConfig.frame_stamp
			ctx.base_atk = base * p_dmg_pct
			ctx.element = GameConst.Element.KIN
			ctx.hit_flags |= GameConst.HIT_IS_AOE_SECONDARY
			ctx.crit_chance = 0.0
			ctx.pos = (e as Node2D).global_position
			_inject_relic_pools(ctx, e)
			if pipeline != null and (pipeline as Object).has_method(&"resolve"):
				pipeline.call(&"resolve", ctx)
	if not hit_uids.is_empty():
		DebugStats.count(&"shadow_dash_sweep")


# tick() 内新增（毒云节拍块 player.gd:272-281 邻位，同 game_delta 通道）：
# ① 残影引信
# for i in range(_echo_fuses.size() - 1, -1, -1):
# 	var f: Dictionary = _echo_fuses[i]
# 	f["left"] = maxf(float(f["left"]) - p_game_delta, 0.0)
# 	if float(f["left"]) <= 0.0:
# 		_shadow_echo_blast(f["pos"])
# 		_echo_fuses.remove_at(i)
# ② 潜影蓄能
# if skill_sublime and character_id == &"ranger" and _lurk_stacks < LURK_STACK_MAX:
# 	_lurk_timer += p_game_delta
# 	if _lurk_timer >= LURK_STACK_INTERVAL:
# 		_lurk_timer -= LURK_STACK_INTERVAL
# 		_lurk_stacks += 1
# 		queue_redraw()   # 光环/读口表现


func _shadow_echo_blast(p_pos: Vector2) -> void:
	# 残影爆：150px 结算 120% ATK + 向外击退 160（stomp :1155-1159 模板）
	#          + 110px 拂弹帽 6（stomp :1160-1169 模板）
	var grid: Variant = _deps.get("enemy_grid")
	... 圆查询 p_pos/SHADOW_ECHO_RADIUS → 每敌 DamageContext（base*SHADOW_ECHO_ATK，
	    同上口径）+ e.call(&"knockback", ((e.global_position - p_pos).normalized())
	    * SHADOW_ECHO_KNOCK)
	var bgrid: Variant = _deps.get("enemy_bullet_grid")
	if bgrid != null:
		var cleared := 0
		for b in (bgrid as SpaceGrid).query_circle(p_pos, SHADOW_ECHO_CLEAR_R):
			if b is ProjectileBase and (b as ProjectileBase).team == 1:
				EventBus.emit_bullet_nullified((b as Node2D).global_position)
				(b as ProjectileBase).nullify()
				cleared += 1
			if cleared >= SHADOW_ECHO_CLEAR_CAP:
				break


# take_contact_damage() hp 实减段后（player.gd:454 emit_player_hit 邻位）：
# if _lurk_stacks > 0:
# 	_lurk_stacks = 0
# 	_lurk_timer = 0.0   # 受创断影（格挡 :439-446 / 无敌早退 :436-437 不清）


# _reset_skill_temp_state()（player.gd:809-819）追加：
# _echo_fuses.clear()
# _lurk_stacks = 0
# _lurk_timer = 0.0
```

### 6.4 口径与边界

- **存档**：`skill_sublime` **随档已裁定**（R246 终审）：serialize_run（game_loop.gd:2738）单键 `"sublime".on` 存档、继续局 `_restore_run_state`（game_loop.gd:2847）在 set_character（:2903）之后幂等回填 `enable_sublime()`（与 :2915 R212 `skill_cd` 回填同型同序）；旧档无键零迁移。会话态 `_echo_fuses`/`_lurk_stacks`/`_lurk_timer` 仍不进档——恢复局丢弃未爆残影（0.45s 窗可忽略）、潜影清零重计，零额外迁移。
- **时间通道**：残影/潜影全走 `game_delta`（tick 入参），顿帧/时间缩放/暂停自然冻结。
- **自动施法（R241）**：CDR 堆叠下自动施放会朝 `_last_move_dir` 打出升华穿袭——伤害/清弹随动生效；并发残影 ≤2（§4 M2 幂等核查），无需额外闸。
- **表现层建议**（实施员裁量）：残影 = `TextureFactory.ship()` 半透明剪影（ranger 色 0.66/1.0/0.92，player.gd:638），0.45s 渐隐；爆点复用 `emit_bullet_nullified` 既有特效与伤害飘字；`emit_skill_cast` 金环照常（player.gd:863）。潜影层可画在技能光环 `_draw`（现有弧通道）。
- **HUD**：`skill_active_ratio()`（player.gd:885-889）自动随 `_skill_fx_duration` 返回 1.2 联动，无需改 HUD 代码；技能键红描边（升华指示）统一读 `player.get("skill_sublime")`（R246 命名归一裁定，ui 泳道统一接线——hud.gd 现无任何 sublime 读口，实测确认），ranger 侧零额外暴露。

---

## 7. 测试要点（SceneTree 探针套件，惯例：`-s` 入口只 load cases 体）

建议套件：`tests/runner/sublime_ranger_cases.gd`（入口 `test_sublime_ranger.gd`，结构照 test_r212_skillresume.gd:1-33）。注意已知坑：入口编译早于 autoload（入口只 load cases 体）；类型化赋值先于 `is_instance_valid` 判序；勿对池化节点 add_child。

| # | 用例 | 断言要点 |
|---|---|---|
| G1 | 零回归 | `skill_sublime=false` 施放：位移 260px、`invuln_left==1.0`、无 DamageContext 结算、`_echo_fuses` 空（与 R246 probe_r246_ranger_blink 口径兼容） |
| G2 | 升华位移与钳制 | 0 层位移 340px / 4 层 460px；上向/横向施放落点均在活动区 x∈[16,704] y∈[768,1264]（贴上边界时净位移最大化、无回弹——R246 语义保持） |
| G3 | 路径结算 | 沿线摆 3 假敌（含步进圆重叠区同敌）→ 各恰好结一次（uid 去重）、伤害 = base_atk×dmg_pct、hit_flags 含 AOE_SECONDARY、crit_chance==0 |
| G4 | 潜影数值 | 0 层 dmg 240% / 满 4 层 400%；`_lurk_stacks` 帽 4 不溢出 |
| G5 | 残影爆 | 推进 game_delta 0.45s → 两影各结算 120%/r150 + 击退调用 + 拂弹（team==1 才清、帽 6、`emit_bullet_nullified` 计数）；引信期间不结算 |
| G6 | 潜影节拍 | 12s 无伤 +1 层；`take_contact_damage` 实减血清零；格挡吸收（shield_ready 路径）不清；施放消耗后归零 |
| G7 | 收口 | `_reset_skill_temp_state()` 后 `_echo_fuses` 空、潜影 0（换角/重开）；CD 不变：`skill_cd_base` 仍 = 表 cd×CDR 乘区（升华不改 refresh_skill_cd） |
| G8 | 边界 | 无武器（weapon_slots 空）施放不崩、仍位移+无敌；`_last_move_dir==ZERO` 回落 UP；顿帧（game_delta=0）残影/蓄能冻结 |

运行命令（exit 0 = 全过）：

```
E:\Code\Agent\Infinite-Fission\android_export\Godot_v4.3-stable_win64.exe --headless --path E:\Code\Agent\Infinite-Fission\repo -s tests/runner/test_sublime_ranger.gd
```

回归伴随：probe_r246_ranger_blink（普通版瞬步口径）+ r212_skillresume（CD 随档；R246 终审追加 `"sublime"` 键往返保真断言——抽中升华→暂停→继续局 `skill_sublime` 仍为真，归卡系统泳道补）+ verify_feedback_cases。

---

## 8. 风险与开放问题

1. **路径命中数假设**（§5 均 4 敌）未经实测——落地后用 DebugStats `shadow_dash_sweep` 计数与波密度遥测校准 `SHADOW_DASH_ATK_BASE`（240% 单旋钮可调，不动结构）。
2. **格挡不清潜影**是有意口径（格挡=「挡住」非「受创」）；若 QA 判定过强，单点改为也清零即可（take_contact_damage :439-446 段加一行）。
3. **`skill_sublime` 跨暂停/继续随档——已裁定落定**（R246 终审，原开放问题关闭）：卡系统 serialize_run 新增单键 `"sublime": {on: bool, fission_layers: int}`、`_restore_run_state` 在 set_character 之后 clampf/幂等回填 `enable_sublime()`——闭合「继续局经 set_character 重建后仅回填快照键（game_loop.gd:2903-2915 实证；快照字典 :2762-2783 现无 sublime 键，二审复核实证缺口属实）、0.001% 抽到的升华在续档后蒸发」缺口；r212_skillresume 补往返保真断言；旧档无键零迁移。player 侧零耦合（§6.2 #10）。⚠ 落地前置：_card_system.md:191/:315 现行文本仍写 `Player.sublime` 且 :191 明文「重置点随 `_reset_skill_temp_state`/`set_character`/重开清零」——与本随档裁定**直接冲突**（即总监所指「卡系统文档未接」），卡系统泳道修订该文档时须同步改名 `skill_sublime` 并撤销 set_character 清零口径；本档 §6.2 #8（`_reset_skill_temp_state` 不动 `skill_sublime`）即按裁定后口径设计，勿回读旧契约返工。
4. 表侧（character_table.gd）**不改**：升华是局内 buff 态不是新角色行；`verify_feedback_cases` 遍历全角色断言 `cd==120` 不受影响。
