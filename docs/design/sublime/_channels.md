# 渠道矩阵扩充设计——角色获取渠道 × 新角色 ×3 × 无尽深度成就阶梯（_channels）

> 来源：用户需求「现有角色渠道可维持；扩充新角色；渠道类型含成就解锁（解锁条件必须显示，
> 例『任意无尽模式通关 10/20/30/50』——即无尽深度成就阶梯）、关卡解锁、直购（结晶购买）等」。
> 本文为**纯设计文档**（本轮未动任何代码）；实现前须先在 FEEDBACK_TRACKER.md 登记
>（文件头纪律 FEEDBACK_TRACKER.md:3-4「必须先登记再动手」），编号建议 R247（登记时顺延核对）。
> 数据真源锚点：`repo/scripts/meta/character_table.gd:17-98`（10 角色全表）、
> `repo/scripts/meta/meta_manager.gd`（判定链/成就表/结算）、
> `repo/scripts/ui/menu_screen.gd:1430-1458`（锁定文案链）、
> `repo/scripts/entities/player/player.gd:822-882`（技能分发）。
> 本文中所有行号均为 2026-10-08 现状实读（非转抄侦查笔记）。

---

## 0. 结论速览

1. **现有 10 角色渠道全部维持零改动**（用户明示「可维持」）。
2. 新增 **3 角色**：战地医师·苏（无尽深度 20 层成就门）/ 坍缩者·汐（无尽深度 50 层成就门）/
   处刑者·刈（240 结晶直购）——分别落位**成就解锁、成就解锁（终局）、直购**三类渠道；
   **关卡解锁**由存量 veles/bulwark/mank/fission/echo 五角色覆盖（矩阵见 §3）。
3. 新增**无尽深度成就阶梯** 4 档（endless_depth_10/20/30/50），走既有 ACH_TIER_TABLE 模板
   展开与 `<type>_<target>` id 规则；链终档 50 奖 100 结晶，全表奖励 1465→1565，
   **封顶 1500→1600 同步调**（meta_manager.gd:53-54 裁定口径注释随改）。
4. 解锁条件显示走选人卡 `unlock_hint` 既有**单源句式**（全角空格前缀 +「<条件>解锁」），
   新门型文案：`　任意无尽模式深入 N 层解锁（当前 M）`（措辞裁定见 §5）。
5. 新增 1 个聚合读口 `Meta.best_endless_depth()`（跨地图 × 跨难度分档键取最大），同时供
   角色门与成就计数消费——**顺手根治「困/狱局无尽深度对读口不可见」的存量盲区**
   （meta_manager.gd:593-599 旧读口只查无后缀键，写入侧 :832 带后缀）。

---

## 1. 新角色提案（×3）

生态位论证基于 character_table.gd:17-98 全 10 角色实读 + player.gd:829-859 技能实现：
现有主动技能占用位——无敌护盾（sentinel）/ 射速增益窗 ×2（veles ×2 4s、echo +50% 5s）/
震退清弹（bulwark）/ 瞬步位移（ranger）/ 全场冻结（zero）/ 全屏爆发（mank）/ 毒云领域
DoT+减速（vera）/ 召唤僚机（noah）/ 无技能·首发自定义（fission）/ 开局随机双武装（echo）。

**未占生态位（本批三角色各取其一）：**

| 空白位 | 证据 | 本批落位 |
|---|---|---|
| 主动治疗/受伤减免 | 全 10 角色零治疗技能；复活是局外养成位（meta_manager.gd:209 revive），地图祝福「滋养」每波回 2%（map_table.gd:52）非角色技能 | 战地医师·苏 |
| 聚怪（群体牵引） | 唯一群位移是 bulwark 震退（方向相反）；zero 冻结只定身不移动 | 坍缩者·汐 |
| 伤害轴增益窗 | 现有增益窗全在射速轴（veles/echo，player.gd:833-836/:856-859 复用 rof_mult 通道）；伤害百分比窗空白——与射速窗分属不同乘区，且正向放大单发类效果 | 处刑者·刈 |

### 1.1 战地医师·苏（id `&"medic"`）——成就门·无尽深度 20 层

- **定位**：战场续航。血 75（介于哨兵 60 与堡垒 95 之间）/ 攻 +0%（生存换输出，同 sentinel/fission 档）。
- **技能**：`应急修复`——立即回复 30% 最大生命，且 4 秒内受到的伤害减半。
  （实现挂点：activate_skill 新分支；回复走 max_hp 口径（player.gd:612 含养成 hp_bonus）；
  减伤 = 新窗口位 `_dr_window_left`，受伤入口乘 0.5，与无敌独立不叠加；fx 时长 4.0。
  治疗通道有先例：复活满血 + bless_nurture 每波回血。）
- **渠道**：`unlock_endless_depth: 20`（新门键，见 §4/§6）。中段长线目标——
  草原打到第 30 波 / 冰原 35 / 沼泽 50 即达成，普通玩家 1~2 张图的进阶期可及。

### 1.2 坍缩者·汐（id `&"vortex"`）——成就门·无尽深度 50 层（终局奖励位）

- **定位**：聚怪终结。血 55（同 vera/echo 档）/ 攻 +10%（同 ranger 档）。
- **技能**：`奇点坍缩`——在身前凝聚引力奇点 3 秒：持续把全场敌人向奇点拖拽聚拢，
  结束瞬间对奇点 220px 半径内敌人结算 120% 攻击。
  （实现挂点：enemy_grid 查询先例 player.gd:727/:755；拖拽豁免照击退口径——Boss 免疫、
  精英 ×0.35；结束爆发照 `_skill_poison_nova`（player.gd:746-774）DamageContext +
  AOE_SECONDARY + KIN 通道；每帧全量 query 有成本，拖拽可降频至每 2 物理帧一次、位移翻倍
  补偿；fx 时长 3.0。）
- **渠道**：`unlock_endless_depth: 50`。终局档——草原等价第 60 波（与 run_wave_60
  「无尽征服」同量级），给硬核玩家一个与 echo 困难通关并列的顶端目标。

### 1.3 处刑者·刈（id `&"reaper"`）——直购·240 结晶

- **定位**：爆发窗口玻璃炮。血 50（同 noah 档）/ 攻 +20%（全表第二，仅次 veles +25%——
  veles 仍保「攻击天花板」身份，刈以 5% 攻换 5 血 + 爆发窗）。
- **技能**：`处决时刻`——6 秒内全武器伤害 +50%（射速不变）。
  （实现挂点：新窗口位并入武器 `meta_atk_pct` 重算——消费点 player.gd:629；启停即时刷新
  照 veles 射速窗先例 refresh_weapon_intervals（player.gd:833-836、:707-718）；fx 时长 6.0。
  与射速窗乘算独立、与单发类词条正向联动，构成与 veles 不同的构筑取向。）
- **渠道**：`unlock_price: 240`——价梯 80（ranger）→ 160（zero）→ 240 顺延，
  结晶直购入口两段式现成（Meta.purchase_character meta_manager.gd:404-415 +
  buy_btn menu_screen.gd:1534-1550 零改动，价格与文案全数据驱动）。

### 1.4 条目草案（character_table.gd CHARACTERS 尾部追加，cd 键必留 =120）

```gdscript
{
	# R247 新角色①：续航生态位——全表首个治疗/减伤技能；无尽深度 20 层成就门
	"id": &"medic", "name": "战地医师·苏", "desc": "后勤医疗体（血 75 / 攻 +0%），战场续航",
	"unlock_endless_depth": 20,
	"hp": 75.0, "atk_pct": 0.0,
	"skill_name": "应急修复", "skill_desc": "立即回复 30% 生命，且 4 秒内受伤减半",
	"cd": 120.0,
},
{
	# R247 新角色②：聚怪生态位（震退的反向位）；无尽深度 50 层成就门（终局奖励位）
	"id": &"vortex", "name": "坍缩者·汐", "desc": "引力操控者（血 55 / 攻 +10%），聚怪终结",
	"unlock_endless_depth": 50,
	"hp": 55.0, "atk_pct": 0.10,
	"skill_name": "奇点坍缩", "skill_desc": "凝聚奇点 3 秒牵引全场敌人聚拢，结束爆发 120% 攻击",
	"cd": 120.0,
},
{
	# R247 新角色③：伤害轴增益窗生态位；结晶直购价梯顺延 80→160→240
	"id": &"reaper", "name": "处刑者·刈", "desc": "处刑专家（血 50 / 攻 +20%），爆发窗口",
	"unlock_price": 240,
	"hp": 50.0, "atk_pct": 0.20,
	"skill_name": "处决时刻", "skill_desc": "6 秒内全武器伤害 +50%",
	"cd": 120.0,
},
```

id 冲突自查（2026-10-08 全仓 *.gd grep）：`medic`/`vortex`/`reaper` 零命中，干净。
中文名与既有 10 角色零重名；「医师/坍缩者/处刑者」称号无占用（召唤师/改造者风格同族）。
三个 id 均非 no_skill、非 random_dual → GameLoop 特殊机制路径（_starting_weapon_id /
_grant_random_dual_loadout）零改动。

---

## 2. 无尽深度成就阶梯设计

### 2.1 计数器：新增聚合读口 `best_endless_depth()`

```gdscript
func best_endless_depth() -> int:
	# R247：任意地图 × 任意难度档的历史最深无尽深度（成就阶梯与角色门共用计数源）。
	# 聚合 map_records 全键（含 "#1"/"#2" 分档键）——存量读口 endless_depth()（:593）
	# 只查无后缀键，困难/地狱局深度（写入侧 :832 mkey 带后缀）对它不可见；本口不查
	# MapTable（无需 final_wave，深度值已落账），天然规避「带后缀查表必空」坑（:637-639 教训）。
	var best := 0
	for key: Variant in map_records.keys():
		best = maxi(best, int((map_records[key] as Dictionary).get("endless_depth", 0)))
	return best
```

- 旧读口 `endless_depth(p_map_id)`（meta_manager.gd:593-599）**保留不动**（分图口径，
  测试 verify_feedback_cases.gd:1805/1882 锚定）；两读口语义不同并存。
- 旧档兼容：无 `endless_depth` 键的记录 → 0；老档若已有够深的记录，下次结算全表扫
  （_check_achievements meta_manager.gd:971-1001）自动补发成就，角色门为派生谓词即时生效。
- 每日局：结算提前分流（meta_manager.gd:819-822）不写深度、不解锁——与 fission/echo 口径一致。

### 2.2 阶梯模板（ACH_TIER_TABLE 追加一行，meta_manager.gd:55-84 表尾）

```gdscript
	# R247 无尽深度族（+4 条）：任意地图无尽模式深入 N 层（跨难度分档聚合）——
	# 20 层门解锁战地医师·苏 / 50 层门解锁坍缩者·汐（角色门 unlock_endless_depth 同源计数）
	{"type": "endless_depth", "targets": [10, 20, 30, 50], "rewards": [0, 0, 0, 100],
		"names": ["初窥深渊", "渊底回声", "噬渊而行", "深渊尽头"],
		"desc_fmt": "任意无尽模式深入 %d 层"},
```

- **id 自动生成** `endless_depth_10/20/30/50`，走展开器 `<type>_<target>` 规则
  （meta_manager.gd:135）；新 type 无撞档（展开器 seen_slots 按 type/target 判撞 :136）。
  生成条目非手写 → 不碰「手写 11 条 id/reward 逐字保留」存档兼容锚（:31-33）；
  noah 门 `wave_20`（character_table.gd:74）不动。
- **与 run_wave 族的关系**：run_wave 记绝对波次（「单局抵达第 60 波」），无尽深度是
  按图归一化的深度（草原 60 波 = 深度 50，沼泽 80 波 = 深度 50）——不同计数、不同 id，
  无冲突；两者可同局达成，属预期叠奖。
- **结算链天然覆盖**：深度唯一写点在结算（meta_manager.gd:841），其后 `_check_achievements()`
  （:842）全表扫——**无需新增事件口**。
- **成就三处注册**（漏一即永久漏检，R192 口径）：①上表模板行；②`_counter_value` 加
  `"endless_depth": return best_endless_depth()` 分支（:907-933）；③`_check_achievements`
  counters 字典加 `"endless_depth": best_endless_depth()` 键（:974-986）。
- **成就墙归类**：`ACH_TYPE_CATEGORY`（menu_screen.gd:53-59）建议显式加
  `"endless_depth": "进阶"` 一行（未加也不丢行——未知 type 兜底「进阶」:51-52/:1316，
  但显式登记可读性更好）。全表容量 ~128 → ~132 条，远低于 500 虚拟化阈值
  （meta_manager.gd:36 裁定）；既有容量断言 `ACHIEVEMENTS.size() <= 200`
  （r191_rework_cases.gd:1153）不受影响。

### 2.3 奖励预算核算（封顶同步）

| 项 | 数值 | 依据 |
|---|---|---|
| 现行全表成就奖励合计 | 1465 结晶 | meta_manager.gd:53 注释裁定口径（未逐条复算，引用原注释） |
| 本批新增奖励 | +100（仅 endless_depth_50 链终档；10/20/30 照族惯例 0） | 同 :52-53「中间档 0 / 链终档 10~100」曲线 |
| 新合计 | **1565 结晶** | — |
| 封顶 | **1500 → 1600**（meta_manager.gd:53-54 注释同步改） | 对冲口径：新增消耗端 reaper 直购 240 结晶 |

### 2.4 阶梯分配总表（10/20/30/50 具体分配）

| 档位 | id | 名称 | 奖励 | 分配 |
|---|---|---|---|---|
| 10 层 | `endless_depth_10` | 初窥深渊 | 0 | 纯成就档（入门路标；草原 20 波即得，教学「无尽继续」入口） |
| 20 层 | `endless_depth_20` | 渊底回声 | 0 | **解锁新角色① 战地医师·苏**（门键 unlock_endless_depth:20，与成就同源同阈值） |
| 30 层 | `endless_depth_30` | 噬渊而行 | 0 | 纯成就档（中段里程碑） |
| 50 层 | `endless_depth_50` | 深渊尽头 | 100 | **解锁新角色② 坍缩者·汐** + 链终 100 结晶（终局双奖励） |

> 门与成就的等价性：门 = `best_endless_depth() >= N`，成就 = 同计数器 `>= N`——
> 同计数同阈值，解锁时刻恒同步（成就解锁的 `achievements_changed` 信号
> meta_manager.gd:943/:998 恰在角色解锁边沿发出）。因此**不需要**为两个新角色照
> fissioner_unlocked/echo_unlocked（:18-19/:844-848）新增专属信号；若要大厅「·新」
> 角标（_char_new_badge menu_screen.gd:60），可订阅 achievements_changed 对
> {endless_depth_20, endless_depth_50} 置位（P2 可选项；noah 成就门现状亦无角标，行为一致）。

---

## 3. 全角色渠道矩阵表（10 存量 + 3 新 = 13）

解锁判定链真源 `Meta.is_character_unlocked`（meta_manager.gd:378-401，if/elif 固定次序）；
显示文案链 `menu_screen.gd:1430-1458`（与判定链平行同序）。**存量 10 行全部维持现状。**

| # | id | 角色 | 渠道类型 | 判定键 | 选人卡锁定文案（unlock_hint 单源句式） |
|---|---|---|---|---|---|
| 1 | sentinel | 哨兵-9 | 初始免费 | unlock_map:空 | （无——恒解锁） |
| 2 | veles | 裂变者·薇拉 | 关卡通关 | unlock_map:world_grass | `　通关「晴空草原」解锁` |
| 3 | bulwark | 堡垒·磐 | 关卡通关 | unlock_map:world_frost | `　通关「寒霜冰原」解锁` |
| 4 | mank | 腐化者·莽 | 关卡通关 | unlock_map:world_swamp | `　通关「翠毒沼泽」解锁` |
| 5 | fission | 改造者·枢 | 关卡通关（分档） | unlock_normal_clear | `　通关普通难度解锁（首关10 波）` |
| 6 | echo | 回响·伊可 | 关卡通关（分档） | unlock_hard_clear | `　任意地图·困难难度通关解锁` |
| 7 | vera | 毒系学者·薇拉 | 挑战（击杀） | unlock_kills:500 | `　图鉴累计击杀 500 解锁` |
| 8 | noah | 召唤师·诺亚 | 成就 | unlock_achievement:wave_20 | `　成就「深入敌阵」解锁` |
| 9 | ranger | 游侠·岚 | 直购 | unlock_price:80 | `　结晶解锁 80（当前 N）` |
| 10 | zero | 演算者·零 | 直购 | unlock_price:160 | `　结晶解锁 160（当前 N）` |
| 11 | **medic（新）** | 战地医师·苏 | **成就·无尽深度** | **unlock_endless_depth:20** | **`　任意无尽模式深入 20 层解锁（当前 M）`** |
| 12 | **vortex（新）** | 坍缩者·汐 | **成就·无尽深度（终局）** | **unlock_endless_depth:50** | **`　任意无尽模式深入 50 层解锁（当前 M）`** |
| 13 | **reaper（新）** | 处刑者·刈 | **直购** | **unlock_price:240** | **`　结晶解锁 240（当前 N）`** |

- M = `Meta.best_endless_depth()` 实时值（打开面板即读，属查询非解锁动作）；
  N = `Meta.crystals` 余额（照存量购买门 :1457-1458 先例带余额显示）。
- 渠道类型覆盖核对（用户要求）：成就解锁 ✓（noah 存量 + medic/vortex 新）、
  关卡解锁 ✓（存量 ×5）、直购 ✓（ranger/zero 存量 + reaper 新）、挑战 ✓（vera）、
  免费 ✓（sentinel）。存量零改动，新门型仅 1 个。
- 购买门 UI（「解锁 240」按钮 + ui_gem icon + 余额置灰）与结算音效链路全数据驱动，
  reaper 零 UI 改动（menu_screen.gd:1534-1550/:1601-1607）。

---

## 4. 解锁条件显示（单源句式规范）

- **句式**：行首全角空格 +「<条件>解锁」[+ 括注进度/余额]，与存量六种门文案完全同族
  （menu_screen.gd:1430-1458）。**禁 emoji 前缀**（R196 定案：Android 系统字体缺 SMP
  字形，:1431-1432）；结晶符号走 ui_gem icon 方案。
- **新门型 elif**（插入位置：`unlock_hard_clear` 之后、`unlock_kills` 之前——判定链
  meta_manager.gd:378-401 与文案链 menu_screen.gd:1433-1458 **两处同位同序**，漏改文案侧
  则锁定角色 hint 为空串）：

```gdscript
		elif int(def.get("unlock_endless_depth", 0)) > 0:
			unlock_hint = "　任意无尽模式深入 %d 层解锁（当前 %d）" % [
				int(def.get("unlock_endless_depth", 0)), Meta.best_endless_depth()]
```

- **措辞裁定**：用户例句「任意无尽模式通关 10/20/30/50」落地为「深入 N **层**」——
  「通关」在本作语境 = 清完 final_wave 触发胜利（meta_manager.gd:541-545），无尽深度
  = 超出 final_wave 的波数（:839-841），HUD 现行口径「无尽 N」（game_loop.gd:1301、
  verify_feedback_cases.gd:1865）；「通关 N 层」易与通关判定混淆，故取「深入」。
  若评审坚持原词，回退「任意无尽模式通关 %d 层解锁」句长相同、零实现差异。
- **长度预算**：`　任意无尽模式深入 50 层解锁（当前 35）` ≈ 19 全角 ≈ 380px <
  406px 行宽（menu_screen.gd:1461，≈21.5 全角单行预算，R198 二aw-7 注释），单行可容；
  name_l 已有 autowrap 兜底（:1464）。
- 成就墙同步可见条件：阶梯 desc「任意无尽模式深入 %d 层」（生成于 desc_fmt），
  与选人卡文案同词——条件在两处均「必须显示」且零漂移。

---

## 5. 实现触点清单（按文件，含行号锚点）

| # | 文件 | 改动 |
|---|---|---|
| 1 | FEEDBACK_TRACKER.md | **先登记再动手**（头纪律 :3-4）：R247 条目 + 本文档链接 |
| 2 | character_table.gd | CHARACTERS 追加 3 条（§1.4；cd 键必留 120，:80 契约注释）；头注解锁矩阵块 :5-13 补一行新门型 |
| 3 | meta_manager.gd | ① `best_endless_depth()` 新函数（§2.1，建议放 :593 endless_depth 邻位）；② ACH_TIER_TABLE 加行（§2.2）；③ `_counter_value` match 加分支（:907-933）；④ `_check_achievements` counters 加键（:974-986）；⑤ `is_character_unlocked` 加 elif（§4 位置；:378-401）；⑥ :53-54 预算注释 1465→1565 / 1500→1600；⑦（可选）:36 容量注释 ~128→~132 |
| 4 | menu_screen.gd | ① unlock_hint 加 elif（§4，:1433-1458 同序插入）；②（建议）ACH_TYPE_CATEGORY 加 `"endless_depth": "进阶"`（:53-59）；③（可选 P2）「·新」角标订阅 achievements_changed（§2.4 注） |
| 5 | player.gd | ① activate_skill match 加 3 分支（:829-859）；② `_skill_fx_duration` 加 3 case（medic 4.0 / vortex 3.0 / reaper 6.0，:868-882）；③ 技能私有函数 ×3（治疗+减伤窗 / 奇点拖拽+爆发照 nova 先例 :746-774 / 伤害窗并入 meta_atk_pct 消费点 :629 + 启停即时刷新照 :833-836）；④ 窗口字段与 tick 收口（换角/重开清理照 `_reset_skill_temp_state` :809-819 模式） |
| 6 | player.gd | apply_character_visual tints 加 3 色（:636-642；建议：medic 白绿 / vortex 深紫蓝 / reaper 暗红） |
| 7 | texture_factory.gd | skill_icon match 加 3 case（:1569 起；`_:` 兜底不裸奔但无辨识度——照 R198 二aw-5 口径逐角色补：医疗十字 / 漩涡 / 镰刃） |
| 8 | verify_feedback_cases.gd | :1034-1035 `count()==10` 硬断言改 13（文案同步改「R247 +3」）；:1428-1434 cd==120 遍历断言自动覆盖新角色（cd 键已合规，无需改） |
| 9 | GameLoop | **零改动**（三新角色均无 no_skill/random_dual） |
| 10 | 存档 | **零新增存档键**（门为派生谓词 + 成就走 achievements_done 既有键；reaper 复用 unlocked_characters） |

---

## 6. 兼容与风险（坑位对照）

1. **双链同改**：判定链（meta_manager.gd:378-401）与文案链（menu_screen.gd:1433-1458）
   平行 elif，新门必须两处同位同序（§4/§5 已定插入位）。
2. **硬断言**：verify_feedback_cases.gd:1034-1035 count==10 必改；:1428-1434 cd 契约
   由条目 cd:120.0 满足。
3. **分档盲区根治**：困/狱局深度落 #1/#2 键（:832），新聚合口取全键最大（§2.1）——
   不查 MapTable，无「带后缀查表必空」风险（:637-639 教训不适用）。
4. **预算封顶**：+100 奖励顶到 1565 > 1500，必须同步调 :53-54 注释与封顶值（§2.3）。
5. **成就 id 不可撞**：新族 id 由展开器生成（endless_depth_*），与手写 11 条（含 noah 门
   wave_20 双锚点）零交集；展开器撞档守卫（:136-137）兜底。
6. **每日局天然排除**：结算分流早退（:819-822）不解锁新门——与 fission/echo 一致，设计内。
7. **解锁信号纪律**：角色门是派生谓词，勿在查询口发信号；成就信号已在结算兑现点恰发一次
   （:942-945/_check_achievements 循环，R191 批量单次落盘口径）。
8. **测试纪律**：headless 自动切测试档（save_path :24-25）但套件内仍须快照-还原
   （saved_* 模式，照 :1045-1070 结晶/unlocked_characters、:1797-1809 map_records 先例）；
   勿 add_child 池化节点；-s 入口只 load cases 体。
9. **性能**：vortex 每帧全量 grid query → 降频拖拽（§1.2）；best_endless_depth 每结算/开面板
   一次 O(键数 ≤15) 可忽略。

---

## 7. 测试计划（新套件 + 存量更新）

新套件：`tests/runner/test_r247_endless_channel.gd`（-s 入口）+ `r247_endless_channel_cases.gd`
（cases 体，SceneTree 探针式）。运行口径：
`E:\Code\Agent\Infinite-Fission\android_export\Godot_v4.3-stable_win64.exe --headless --path E:\Code\Agent\Infinite-Fission\repo -s tests/runner/test_r247_endless_channel.gd`（exit 0 = 全过）。

断言组：
1. **表结构**：CharacterTable.count()==13；三新角色条目键齐（id/name/hp/atk_pct/cd=120/
   skill_name）；ACHIEVEMENTS 含 endless_depth_10/20/30/50（id、reward=[0,0,0,100]、命名）；
   ACHIEVEMENTS.size() ≤ 200（r191 口径）。
2. **聚合读口**：map_records 三键（无后缀 / #1 / #2）各写不同深度 → best_endless_depth()
   取最大；空表 → 0（快照-还原 saved_mr）。
3. **角色门**：深度 19 → medic/vortex 双锁；写 20 → medic 解锁、vortex 仍锁；困/狱键
   （#1/#2）深度同样驱动门（分档盲区修复验证）；reaper 不随任何通关/成就解锁。
4. **结算全链**：set_run_map + _on_wave_started(final+N) + _on_state_changed(GAME_OVER)
   （照 :1800-1803 手法）→ endless_depth_N 成就解锁 + 结晶 +100（50 档）；
   set_run_daily(true) 局不写深度、不解锁。
5. **购买门**：240 结晶三拒路径（不足 / 已购 / 无价格角色拒购）+ 扣费解锁，照 :1044-1070 模式。
6. **旧档兼容**：无 endless_depth 键 / 无新成就键的 map_records + achievements_done →
   读口 0、门锁、面板构建不崩。

存量更新：verify_feedback_cases.gd:1034-1035（10→13 + 文案）；其余套件零涉及
（ach 面板断言动态取 N，:868-873；cd 遍历断言自动覆盖）。
全量回归照项目惯例跑全套件（引擎命令同上逐套件）。

---

## 8. 验收标准

1. 新档：三个新角色按矩阵渠道可解锁（medic 20 层 / vortex 50 层 / reaper 240 结晶），
   选人卡锁定态显示 §3 文案（含当前进度/余额括注），解锁后可选用。
2. 老档：已有深度 ≥20/50 的玩家，进入后角色门即时解锁、下次结算补发阶梯成就（+100 结晶
   仅对 ≥50 档）；无深度记录玩家零变化。
3. 成就墙「进阶」页签出现 4 条无尽深度成就，desc 与选人卡解锁文案同词。
4. 存量 10 角色渠道、文案、判定逐位不变（verify_feedback_cases 全量回归绿）。
5. 全表成就奖励合计 1565 ≤ 新封顶 1600（注释与数值同步）。
