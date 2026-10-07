# R240 敌本体 MultiMesh 镜像刀 — A/B 对照与评审收口报告

日期：2026-10-07 ｜ 轮次：R240 ｜ 交付目标：vc45（v0.1.44）

## 1. 刀述

敌本体绘制从逐敌 Sprite2D 改为按贴图 MultiMeshInstance2D 镜像（每贴图恒 1 draw，
实例色承载染色/渐显/闪白——组色差异不断批）。排除面=boss*/elite/bastion（叠层子件
语义）+ FLASH_TEX=false（实例色 8-bit 钳位承不住 >1 白乘）。单点回退门 `Enemy.BODY_MM`。

动机链：vc44 轻压力局判读（渲ms 16.4-16.8 单独封顶 60fps=轻载主犯）→ R237 归因
F1 敌桶本体=战斗 dc 增量 83-123%（off 臂复测 326dc/72.8%）→ 本刀直取敌桶。

## 2. A/B 刀效（探针 probe_r240_bodymm_{off,on}.json，同 content v2 满载局）

| 读数（BATTLE 满载窗） | OFF 臂 | ON 臂 | Δ |
|---|---|---|---|
| battle_dc (p50) | 547 | **387** | **-160dc / -29.3%** |
| battle_render_ms | 74.7 | **64.1** | **-10.6ms** |
| increment_dc（满载增量） | 448 | 288 | -160dc / -35.7% |

判定：远超 dc 带宽 ±20-30% 非平稳带，**刀效成立**。减量与 off 臂 F1 敌桶本体
326dc 的结构预判吻合（敌桶多贴图各自合为 1 draw）。

披露：①ON 臂 K_NULL 空刀对照 dcΔ=-108 超带（±58）——配对窗程式漂移大，快刀读数
降级披露（K_DECOR on 臂 -6.8% 不可信同理）；主结论不依赖单快刀，用同 content 注入
的 anchor/满载窗两臂对照。②OFF 臂 K_NULL dcΔ=-27 带内可信用。

真机预期：渲轴轻载局（16.5ms 封顶）敌桶减批主要作用于满载段；真机 A/B 以 vc45
深载局日志判读为准。

## 3. 评审 BLOCKER 与修复（R240-B1）

**BLOCKER：敌人全部上下颠倒。** QuadMesh 的 UV v=0 在底（GL 惯例），2D canvas
渲染相对 Sprite2D 垂直翻转——grunt/volatile_scared 等非对称贴图逐像素实证
（vflipped diff=0.0000），双渲染器（forward+/gl_compatibility）均复现；dart/longbow
朝向贴图指向错误。22/22 旧断言只盖 transform/色数据层，漏渲染取向层。

**修复：** `_build_mm` 弃 QuadMesh，自建 ArrayMesh（`_quad_mesh_uv_up`）：XY 平面
quad，UV-up 取向（左上(-hw,-hh)↔UV(0,0)）=Sprite2D 等价；中心原点、像素 1:1；
canvas 无背面剔除，绕序两向可绘。mesh 侧翻 UV（评审建议方案——实例变换补 Y 翻转
会与拉伸/旋转复合出错向）。

**验证三链：**
- 探针 `probe_r240_uvfix.json`（窗口）：grunt direct=**0.0000**（vflipped=0.0693）、
  volatile_scared direct=**0.0000**（vflipped=0.1260）——逐像素相等双证。
- 套件 ⑤d（恒跑机制门）：UV 数组逐位断言（左上↔(0,0) 四角全钉）。
- 套件 ⑤e（窗口态像素门）：同位置先后渲染消背景对拍 direct≤0.012。

## 4. 评审其余意见处置

| 项 | 级别 | 处置 |
|---|---|---|
| headless 20/22（⑤a/⑤b 假红） | HIGH | 评审跑的是修复前旧快照；QA-R240-002 门控（Dummy 渲染器降级）已在——headless 28/28 exit=0 复核 |
| 像素取向断言缺口 | 必修 | ⑤d+⑤e 落套件（见上） |
| 阶梯 realloc 写穿缺口 | 应补 | ⑦b：40 实例跨 16→32→48，窗口态头/中/尾读回 PASS（评审代验结论固化） |
| 释亡压缩/隐藏 owner 缺口 | 应补 | ⑦c：free 后帧尾清表+隐藏跳绘+复显回绘 3 断言 PASS |
| on/off A/B 留档 | 应补 | 本报告 §2（评审所读 `_probe_r240_*.log` 为探针 stdout，JSON 数据落 docs/qa/） |
| 元素子件覆盖序披露 | 披露 | 敌 A 的元素子件（火苗/冰渣/电弧）现绘于敌 B 本体之上——与「瞬态件恒在上」同类同披露（place 序整树覆盖语义不变） |
| `owner` 局部遮蔽 Node.owner | LOW | 告警级噪声，不改（改动即触碰 QA-R240-001 去类型化语义） |
| 运行期翻门延迟回退 | LOW | 调试态影响（下次 _place_in_bucket 才回 Sprite），不改 |

## 5. 测试面

- `test_r240_bodymm`：28/28（headless 电池口径 exit=0；窗口态同 28/28 含 ⑤a/⑤b/⑤e/⑦b
  渲染器读回）。
- 邻接回归：r237_flashtex 35/35（契约迁移 BODY_MM=false 基准态）、verify_feedback
  666/666、r220_simchain 74/74、r191_rework 131/131、r239_native 30/30。
- 电池全量 120 套件 FAILS:0（r195/r230 两红为 R241 契约迁移面，断言基线更新后复绿：
  r195 580/580（16 键白名单+skill_auto_cast）、r230 26/26（计数 30/36/30/4——
  自动施放按钮全走 label_color，刀面精神不破））。
