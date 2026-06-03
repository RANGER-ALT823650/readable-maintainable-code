# SKILL: 可读且可维护的代码 (Readable & Maintainable Code)

适用于 AI 编码助手的 SKILL（技能包），指导生成或编辑过的代码添加面向维护的注释，并在修改后提供说明总结。

## 用途

帮助 Codex 等 AI 编码助手生成更容易被非专家或半专家开发者理解、修改和后续维护的代码。

## 触发方式

- 输入 `/🫪`
- 要求代码更易读或更易维护
- 提到"解释代码"
- 使用标记 `-s`（简单模式）、`-d`（详细模式）、`-sum`（生成总结）

## 规则要点

1. **为维护而注释，不要复述代码** — 解释意图、设计取舍、边界情况
2. **优先使用块级说明** — 复杂片段前加简短注释，直观代码不加
3. **说明修改热点** — 标记未来最可能变化的位置和安全修改范围
4. **为非平凡文件生成项目流程图** — 使用 Mermaid `flowchart` 语法，并可生成 HTML companion
5. **保持注释简洁** — 每条注释都必须值得存在
6. **提供开发者总结** — 按 `summary.md` 模板输出修改说明

## 示例文件

- [`SearchWordsFromVideosView.swift`](./SearchWordsFromVideosView.swift) — 应用本 SKILL 规则注释的 SwiftUI 源码
- [`SearchWordsFromVideosView.md`](./SearchWordsFromVideosView.md) — 配套的流程图与代码说明文档
