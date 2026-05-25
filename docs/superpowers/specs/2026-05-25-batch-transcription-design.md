# 批量音频转写设计

**日期**: 2026-05-25  
**状态**: 待实现  
**范围**: Audio File 页 — 文件夹批量转写，输出到指定目录

---

## 1. 背景与目标

### 1.1 现状

WhisperClip 的 **Audio File** 功能当前仅支持：

- 单文件：拖放或 `NSOpenPanel` 选择一个音频
- 转写管道：`VoiceToTextFactory` → STT →（可选）当前 Prompt + LLM
- 结果：界面展示、剪贴板、`TranscriptionHistory`（UserDefaults）

不支持：选择文件夹、递归扫描、将转写结果写入磁盘。

### 1.2 目标

在 **不替换** 单文件能力的前提下，增加 **文件夹批量转写**：

1. 用户选择 **输入文件夹**（递归扫描支持的音频格式）
2. 用户选择 **输出文件夹**
3. 按相对路径保留子目录结构，每个音频生成对应 `.txt`
4. 批量结束后在界面显示 **本次汇总**（成功 / 跳过 / 失败 / 是否用户取消）
5. 单文件模式行为保持不变（含 History 与剪贴板）

### 1.3 非目标（YAGNI / v2）

- 拖入文件夹、文件对话框多选、监视文件夹自动转写
- 批量写入 `TranscriptionHistory`、批量自动更新剪贴板
- 并行转写多个文件（首版串行，避免双份模型内存）
- 导出 `.srt` / `.md`（首版统一 `.txt` UTF-8）
- 独立侧边栏「Batch」页（首版扩展现有 Audio File 页）
- CLI 批量命令（可与本设计共用 Coordinator，但不在本 spec 范围）

---

## 2. 需求决策记录

| 主题 | 决策 |
|------|------|
| 结果去向 | **C**：落盘 + 界面汇总；批量不刷 History；单文件照旧 |
| 输入方式 | **A**：仅选择文件夹，自动扫描 |
| 扫描范围 | **B**：递归包含所有子文件夹 |
| LLM | **C**：勾选「应用当前 Prompt」，**默认勾选** |
| 输出目录结构 | **A**：保留相对输入根目录的子路径 |
| 输出文件冲突 | **D**：批量开始前用户选择：覆盖 / 跳过 / 自动改名 |
| 单文件失败 | **C**：勾选「遇错继续」，**默认勾选** |
| 批量剪贴板/History | **C**：批量不写入 History；不自动改剪贴板；界面显示本次汇总 |
| 取消 | **MVP 包含**：协作式取消按钮（见 §5.4） |
| UI 布局 | **方案 1**：扩展 `FileTranscriptionView`，单文件区 + 批量区 |

---

## 3. 推荐架构

### 3.1 模块划分

```
FileTranscriptionView
    ├── 单文件区（现有）
    └── 批量区（新增）
            │
            ▼
    BatchTranscriptionCoordinator (@MainActor, ObservableObject)
            │
    ┌───────┼────────────┬─────────────────┐
    ▼       ▼            ▼                 ▼
AudioFile   TranscriptWriter   VoiceToTextFactory   LLMFactory
Enumerator                     (现有)               (可选)
```

| 模块 | 文件（建议） | 职责 |
|------|----------------|------|
| `AudioFileEnumerator` | `Sources/AudioFileEnumerator.swift` | 递归枚举输入根目录下支持的音频；稳定排序 |
| `TranscriptWriter` | `Sources/TranscriptWriter.swift` | 计算输出路径、创建子目录、写 UTF-8 `.txt`、执行冲突策略 |
| `BatchTranscriptionCoordinator` | `Sources/BatchTranscriptionCoordinator.swift` | 队列编排、进度、取消、汇总、调用 STT/LLM |
| `FileTranscriptionPipeline`（可选抽取） | `Sources/FileTranscriptionPipeline.swift` | 单文件与批量共用的「STT → 可选 LLM → 文本」逻辑 |
| `SettingsStore` 扩展 | `Sources/SettingsStore.swift` | 持久化上次 **输出文件夹** security-scoped bookmark |

**不修改** `VoiceToTextProtocol`、Parakeet/WhisperKit 实现；仅复用 `process(filepath:)`。

### 3.2 与现有代码关系

- 单文件 `transcribeFile()` 逻辑与批量单步一致，建议抽成共享方法避免重复。
- 支持的扩展名与 `FileTranscriptionView.supportedTypes` 保持一致（mp3, wav, m4a, flac, ogg, aiff, 通用 audio）。
- 会议转写（`MeetingRecorder` + `AsrManager`）不在本 spec 范围。

---

## 4. 用户界面

### 4.1 布局（Audio File 页）

```
┌─ 单文件（保留）────────────────────────────────────┐
│  虚线拖放区 / click to browse                       │
│  [Transcribe] → 结果区 + 剪贴板 + History          │
└────────────────────────────────────────────────────┘

┌─ 批量处理（新增）──────────────────────────────────┐
│ 输入文件夹:  [路径或「未选择」]  [选择…]            │
│ 输出文件夹:  [路径或「未选择」]  [选择…]            │
│ ☑ 应用当前 Prompt（默认开）                         │
│ ☑ 遇错继续（默认开）                                │
│ [开始批量转写]  [取消批量]  ← 运行中显示取消        │
│ 进度: 3 / 12                                        │
│ 当前: week1/lecture-a.mp3                           │
│ 完成后: 成功 10 · 跳过 1 · 失败 1 · 已取消          │
│ [展开详情] 失败 / 跳过列表                          │
└────────────────────────────────────────────────────┘
```

### 4.2 控件启用规则

| 状态 | 开始 | 取消 | 文件夹选择 | 勾选项 |
|------|------|------|------------|--------|
| idle | 需已选输入+输出 | 隐藏 | 启用 | 启用 |
| running | 禁用 | 启用 | 禁用 | 禁用 |
| completed / cancelled / failed | 启用 | 隐藏 | 启用 | 启用 |

### 4.3 冲突策略对话框

**触发条件**：扫描完成后，若至少一个输出 `.txt` 已存在（按所选冲突策略判定）。

**选项**（三选一，仅本次批量有效）：

1. **覆盖** — 覆盖已有文件  
2. **跳过** — 不转写该输入，计入 `skipped`  
3. **自动改名** — 同目录下 `name.txt` → `name-2.txt` → `name-3.txt` … 直至可写  

未冲突文件正常处理。

### 4.4 空目录与校验

- 输入文件夹内（含子目录）无支持音频 → 提示，不启动  
- 未选输入或输出 → 「开始」禁用  

---

## 5. 核心流程

### 5.1 批量主流程

```
1. 用户选择 inputRoot（NSOpenPanel, canChooseDirectories=true）
2. 用户选择 outputRoot（同上；写入 SettingsStore bookmark）
3. 用户配置：applyPrompt, continueOnError
4. 点击「开始批量转写」
5. files = AudioFileEnumerator.enumerate(root: inputRoot, types: supportedTypes)
6. 若 files.isEmpty → alert，结束
7. 若存在输出冲突 → 弹出冲突策略选择
8. coordinator.run(inputRoot, outputRoot, files, options)
9. 对每个 file（串行）:
     a. 若 isCancelled → break（见 §5.4）
     b. 若 conflict=skip 且输出已存在 → skipped++, next
     c. text = STT.process(filepath)
     d. 若 applyPrompt && prompt 非空 → LLM；若 LLM 未就绪 → 失败
     e. 若 isCancelled（当前文件完成后）→ 不写盘，break
     f. TranscriptWriter.write(text, relativePath → outputRoot)
     g. succeeded++
     h. on failure: failed++; if !continueOnError → break
10. 发布 BatchSummary，UI 展示汇总
```

### 5.2 输出路径规则

设 `inputRoot` 为用户选择的输入文件夹（标准化 URL）。

- 相对目录：`file.deletingLastPathComponent().path` 相对于 `inputRoot.path` 的相对路径  
- 输出文件：`outputRoot/appendingPathComponent(relativeDir).appendingPathComponent(stem + ".txt")`  
- 写前 `GenericHelper.folderCreate` 确保父目录存在  

**示例**：

```
输入: ~/Lectures/week1/a.mp3
输出根: ~/Out/
结果: ~/Out/week1/a.txt
```

### 5.3 单文件路径（不变）

拖放 / browse → `transcribeFile()`：

- STT → 可选 LLM  
- `resultText` + `copyToClipboard` + `TranscriptionHistory.add(source: .file)`  

批量 **不** 调用 `TranscriptionHistory.add`。

### 5.4 取消（协作式）

用户点击 **取消批量**：

1. `coordinator.requestCancel()` 设置 `isCancelled = true`  
2. **不** 强行中断正在进行的 `transcribe` / LLM（底层无可靠 cancel API）  
3. 当前文件推理 **允许跑完**；完成后若 `isCancelled`，**不写入**该文件输出，且 **不** 启动下一个文件  
4. 此前已成功写入的 `.txt` **保留**  
5. 状态 → `cancelled`，`BatchSummary.cancelledByUser = true`  
6. UI 在取消后显示「正在完成当前文件…」（可选文案）

**循环检查点**：

- 每个文件 **开始前** `guard !isCancelled`  
- 每个文件 **STT+LLM 完成后、写盘前** 再次检查  

### 5.5 与 LLM / Prompt

- `applyPrompt == true` 且 `settings.currentPrompt` 非空 → 与单文件相同调用 `LLMFactory`  
- `applyPrompt == false` 或 prompt 为空 → 仅输出 STT 原文  
- LLM 未就绪 → 该文件记为 `failed`，错误信息含「LLM is not ready」  

---

## 6. 数据模型

### 6.1 `BatchTranscriptionOptions`

```swift
struct BatchTranscriptionOptions {
    var applyPrompt: Bool          // 默认 true
    var continueOnError: Bool      // 默认 true
    var conflictPolicy: OutputConflictPolicy  // 本次批量，对话框选择
}

enum OutputConflictPolicy {
    case overwrite
    case skipExisting
    case autoRename
}
```

### 6.2 `BatchSummary`

```swift
struct BatchSummary {
    var total: Int
    var succeeded: Int
    var skipped: Int
    var failed: Int
    var cancelledByUser: Bool
    var failedItems: [(url: URL, error: String)]
    var skippedItems: [URL]
}
```

### 6.3 `BatchTranscriptionCoordinator` 发布状态

```swift
enum BatchRunState {
    case idle
    case running
    case completed
    case cancelled
    case failed   // 未取消但因 continueOnError=false 遇错停止
}

@Published var state: BatchRunState
@Published var progress: (current: Int, total: Int)
@Published var currentFileName: String?
@Published var summary: BatchSummary?
@Published var isFinishingCurrentAfterCancel: Bool  // 可选 UI
```

### 6.4 Settings 扩展

| Key | 类型 | 说明 |
|-----|------|------|
| `batchOutputDirectoryBookmark` | `Data?` | 输出文件夹 security-scoped bookmark |
| `batchApplyPrompt` | `Bool` | 可选：记住上次勾选，默认 `true` |
| `batchContinueOnError` | `Bool` | 可选：记住上次勾选，默认 `true` |

输入文件夹 **不** 持久化（避免误扫大目录）；输出文件夹 **建议** 记住。

---

## 7. 权限与安全

- 使用 `NSOpenPanel` 让用户选择输入/输出目录  
- 输出目录保存 bookmark；写文件前 `startAccessingSecurityScopedResource()`  
- 与现有 `WhisperClip.entitlements` 中 `com.apple.security.files.user-selected.read-write` 一致  
- 首版 **串行** 访问文件，避免并发 bookmark 问题  

---

## 8. 错误处理

| 场景 | 行为 |
|------|------|
| 枚举到 0 个文件 | Alert，不启动 |
| STT 抛错 | `failed++`；`continueOnError` 则继续，否则停止 |
| LLM 未就绪且需要 LLM | 同 STT 失败 |
| 写盘失败 | `failed++`，记录路径与错误 |
| 用户取消 | 见 §5.4；汇总中 `cancelledByUser=true` |
| 磁盘满 | 写盘失败，按失败项处理 |

日志：使用现有 `Logger`，`log: Logger.audio`；不记录完整转写正文（与 `logSensitiveData` 一致）。

---

## 9. 测试计划

### 9.1 单元测试

| 组件 | 用例 |
|------|------|
| `AudioFileEnumerator` | 递归、过滤非音频、空目录、排序稳定 |
| `TranscriptWriter` | 相对路径映射、创建子目录、overwrite/skip/rename |
| `BatchTranscriptionCoordinator` | Mock STT；成功计数；遇错继续 on/off；取消在文件间生效；取消后不写盘 |

### 9.2 手动测试

1. 小文件夹 3 个音频，保留子目录结构，检查 `.txt`  
2. 冲突三种策略各跑一遍  
3. 运行中取消：确认已写完的保留、后续不处理  
4. 勾选/不勾选 Prompt；LLM 未下载时的失败提示  
5. 单文件转写仍写 History + 剪贴板  

---

## 10. 实现顺序建议

1. `AudioFileEnumerator` + `TranscriptWriter` + 测试  
2. `BatchTranscriptionCoordinator`（含取消）+ 测试  
3. `SettingsStore` bookmark 与目录选择  
4. `FileTranscriptionView` 批量 UI 与冲突对话框  
5. 抽取 `FileTranscriptionPipeline`（可选，减少重复）  
6. 手动回归单文件 + 批量  

---

## 11. 后续扩展（不在本 spec）

- `Task.cancel()` 与引擎级中断（若 API 成熟）  
- 并行度=1 可配置、批内并发 2  
- 批量完成后「在 Finder 中显示输出文件夹」  
- CLI：`whisperclip batch --input --output`  
- 拖放文件夹到批量区  
- 导出 `.md` / 带时间戳字幕  

---

## 12. 批准记录

| 角色 | 日期 | 结论 |
|------|------|------|
| 产品/用户 | 2026-05-25 | 需求问答完成；含取消按钮 |
| 工程 | — | 待实现 |

---

*本文档由 brainstorming 流程生成，实现前请审阅。通过后使用 writing-plans 技能生成 `implementation plan`。*
