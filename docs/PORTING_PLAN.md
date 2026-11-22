# DSH NovelAI 插件 → Flutter 移植计划

本文件对照 `plugins/novelai-studio/README.md`（DSH 插件的功能文档），梳理 NovelAI Harness（Flutter）
已有的能力、缺失的能力与移植批次。作为后续每个功能批次的验收清单。

> 前置：本仓库要求 `dart analyze` 0 警告、相关测试通过；当前环境尚未安装 Flutter SDK，
> 安装完成后再逐批验证，避免提交未通过门禁的代码。

## 一、能力映射

| 插件文档能力 | 本仓库现状 | 结论 |
|---|---|---|
| 三卡片工作台 / 参数 / 提示词双模式 | ✅ 已有（parameters_page、prompts_page） | 不移植 |
| 多角色 caption / 坐标拖拽 / 防串色 | ✅ 已有（character_card_item、position canvas） | 不移植 |
| 文生图 / 图生图 / 超分 | ✅ 已有（NovelAiService、generate dock） | 不移植 |
| 局部修复 / 焦点特写 / 批注联动 | ✅ 已有（InpaintService、inpaint_page） | 不移植 |
| 外部模型 AI 整图编辑 | ✅ 已有（ImageEditService） | 不移植 |
| 自由大画布 / 批注 / 便签连线 | ✅ 已有（board_* 系列） | 不移植 |
| 图片导出管道 / 可见水印 / DCT 盲水印 / 元数据脱敏 | ✅ 已有（WatermarkService） | 不移植 |
| 图片命名宏 / 无覆盖落盘 / 缓存目录 | ✅ 已有（ImageSavePathService、ImageFileStore、cache/） | 不移植 |
| 32 万离线标签库 / 在线检索 / 画师推荐 | ✅ 已有（TagDictionaryService、DanbooruSearchService） | 不移植 |
| 提示词 AST / 语法高亮 / SD⇄NAI 转换 | ✅ 已有（PromptAstEngine、rich_prompt_text_controller） | 不移植 |
| 提示词组合预设库 | ✅ 已有（PromptLibraryService + 画廊） | 不移植 |
| AI 对话 / 思考链 / 多模态 / 会话分支 | ✅ 已有（AgentHarness、agent_chat_*） | 不移植 |
| 内置技能（V5 架构师 / 修复专家 / 标签大师） | ✅ 已有（BuiltinSkills） | 不移植 |
| Agent 工具（生图/修复/批注/词库/画板/参数） | ✅ 已有（core/harness/tools/*） | 不移植 |
| **诺微（Novi）人设技能** | 🚧 本次新增（BuiltinSkills.noviPersona） | 已移植 |
| **AITag 图源：搜索 / 真实提示词 / 参数导入 / 角色 caption 去重** | ❌ 缺失 | 本次新增数据层；UI 待做 |
| 法典（codex pack）图源：浏览 / 搜索 / 套用 tags | ❌ 缺失 | 批次 2 |
| 本地画廊：三列瀑布流 / 无限滚动 / 滚动记忆 | ❌ 缺失（当前只有历史侧栏与灯箱） | 批次 2 |
| 外部图源详情灯箱：元数据 + 负面 + 套用 | ❌ 缺失 | 批次 2 |
| 资料库（文档读取） | ❌ 缺失 | 批次 3 |
| AI 梳理（分析/角色/梳理串 + 工具） | ❌ 缺失 | 批次 3 |
| WD14 独立反推工作区 | ❌ 缺失（现有仅对话多模态反查） | 批次 3 |
| 私有 tag（stripTags）：参与生成、出图后从元数据移除 | ❌ 缺失 | 批次 4 |
| 保留图片开关（不勾选只进 cache，超限滚动删除） | ⚠️ 部分已有（未保存缓存 + 自动保存开关），需明确上限与设置项 | 批次 4 |

## 二、批次安排

### 批次 1（已开始）

- [x] `lib/data/models/aitag_models.dart`：作品行、详情、角色 caption
- [x] `lib/data/services/aitag_service.dart`：搜索、详情解析（`ai_json.Comment`）、
      `prompt_text` 与 `v4_prompt.caption` 去重、图片下载（pixiv referer）
- [x] `test/aitag_service_test.dart`：MockClient 覆盖搜索、详情、去重
- [x] `BuiltinSkills.noviPersona`：诺微人设（17k 字，raw string）

### 批次 2：图源画廊（AITag / 法典 / 本地画廊）——进行中

- [x] 侧栏「图源」页 + 三列瀑布流 + 滚动到底自动加载
- [x] AITag 搜索、详情弹层、套用（提示词/负面/模型/尺寸/步数/采样/seed/角色 caption）
- [x] 法典 pack 下拉、搜索、分页追加、套用（清理自动补的质量词）
- [x] 本地画廊瀑布流（图源页「本地」页签，收藏/筛选/灯箱）
- [x] AITag / 法典收藏与「只看收藏」筛选
- [x] 详情弹层复制按钮

### 批次 4：生成输出选项（进行中）

- [x] 图生图：`img2imgBytes` + 强度/噪声，进 `toApiPayload`，参数页可选画板当前图
- [x] 精准参考：Vibe Transfer `reference_image_multiple`（强度 / 提取信息量 / V5 normalize）
- [x] 图源页新增「本地」瀑布流 + 收藏心标 + 只看收藏 + 点击进灯箱
- [x] 收藏持久化（SharedPreferences）
- [x] agent `update_studio_parameters` 支持 img2img 强度/噪声、画板图作源图/参考、清除
- [ ] 从本地文件选择源图/参考图（目前只支持画板当前图）
- [ ] 参考图「提取信息量」滑杆
- [ ] stripTags：私有 tag 参与生成，导出时从 PNG Comment 移除
- [ ] `keepImages` 上限：cache 目录按修改时间滚动删除

### 批次 3：资料库（只读，不做 AI 梳理）

- 用户已确认不需要「分析/角色/梳理串」；资料库只做文档选择、读取与搜索
- [x] 选择文件夹读取 txt/md/json/csv/yaml/docx；pdf 通过外部 pdftotext（poppler）读取
- [x] 「资料库」页签：列表 / 搜索 / 预览 / 刷新
- [x] agent 工具 `library`（list / read / search）

### 批次 4：生成输出选项

- `stripTags`：私有 tag 参与生成，导出时从 PNG `Comment` 中移除（不改内部历史）
- `keepImages`：不勾选时仅写 `cache/`，设置上限后按修改时间滚动删除
- 与现有 `WatermarkService.processExportImage` 的顺序约束保持一致

## 三、约束与风险

- **代理**：AITag / 法典 / Danbooru 在线服务在部分网络需要代理；本仓库当前用
  `package:http` 默认客户端，未读取系统代理。批次 2 需要增加代理配置或复用现有网络设置。
- **图片直链**：AITag 的图片来自 pixiv，必须带 `Referer: https://aitag.win/`；服务层已封装
  `fetchImage`，UI 侧统一走服务取字节，避免 `Image.network` 缺 referer 403。
- **l10n**：新增 UI 文案需同时更新 `lib/l10n/*.arb` 并重新生成（`l10n.yaml`），否则 `dart analyze` 报缺失文案。
- **测试**：数据层改动补单测；纯 UI 布局不堆测试。


## 四、轮次外补充

- [x] 图生图（源图 + 强度/噪声）与 Vibe Transfer 参考图（强度 / 提取信息量）
- [x] 图生图/参考图本地文件选择 + 画板当前图
- [x] 跨会话长期记忆：`memory` 工具（list / add / remove）+ SharedPreferences 持久化
- [x] PDF 解析：调用外部 pdftotext（未安装时给出明确提示）
