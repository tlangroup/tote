# tote 工程交接说明（给新工作空间）

> 本文是 t 编译器工程（C:\seesaw\codebuddy\t）当前会话写给「tote 新工作空间」的交接。
> 新空间启动 tote 开发前，请先读 `docs/design/DESIGN.md`（完整设计稿）和本文件。

---

## 0. 一句话定位

tote 是 **t 语言的官方项目构建管理器**，定位类似 Rust 的 cargo，但**从第一性原理重做**——
继承 cargo 真正优雅的精神（约定优于配置 / 清单即真相 / 可复现 / 依赖一等 / 统一 CLI），
抛弃其历史包袱（build.rs / feature unification / 0.x caret 怪癖 / 三重依赖 / 库不锁 / registry 硬编码 / 工具链外部固定）。

tote 的**灵魂差异化能力**：t 语言的 `extend` 特性让**编译器本身成为可派生的工程级构建输入**——
这是 cargo 完全没有、也永远无法拥有的架构。

---

## 1. 工程现状（2026-10-15）

```
C:\seesaw\codebuddy\tote\
├── tote.toml              # 自身清单（同时是 schema 自我示范）
├── .gitignore             # 忽略 out/，但 tote.lock 永不忽略
├── src/tote.tc            # 当前是"薄 driver"：转发 build/run/check/... 给 tc + 字符串扫描 entry/deps
├── tests/ examples/ benches/   # 约定目录（空）
└── docs/
    ├── design/DESIGN.md   # ★ 完整设计稿（阶段一·待用户确认过闸门①）
    ├── HANDOFF.md         # 本文件
    └── TC_INTERFACE_REQUESTS.md  # tc 工程侧需配合的接口修改建议 + 请求信箱
```

**当前 tote.tc 只是 driver，不是真正的包管理器**：它缺依赖解析、lockfile、fetch、构建图。
这正是 MVP 要补的洞。详见 DESIGN §1。

---

## 2. 设计精神速查

| 维度 | 继承（cargo 优雅处） | 丢弃（cargo 包袱）及替代 |
|---|---|---|
| 配置 | 约定优于配置、目录即配置 | — |
| 清单 | 单一声明式 `tote.toml` + `tote.lock` | — |
| 可复现 | lockfile + 内容寻址缓存 | — |
| 依赖 | 声明式版本区间 + 多源 | registry 硬编码 → path/git 一等公民（B6） |
| 代码生成 | — | `build.rs` 任意脚本 → `comptime`(下层)+`extend`(上层) 两层原生机制（B1） |
| feature | — | 全局 unification 地狱 → 默认无 feature，条件走 comptime（B2） |
| 版本 | — | 0.x caret 怪癖 → 统一"最左非零段"规则（B3） |
| 依赖分类 | — | normal/dev/build 三重 → normal/dev 两重（build 并入 comptime）（B4） |
| lockfile | — | 库不强制 → **永远提交 tote.lock**（B5） |
| 工具链 | — | rust-toolchain.toml 半吊子 → 根 tc 固定基础 + `extend` 派生 per-project 变体（B7） |

完整表见 DESIGN §2、§10。

---

## 3. ★ 核心不变式：extend 与派生变体（务必先懂）

> **不变式（Invariant）**：`extend` 永远只产出"**本工程专属的 tc 变体（variant）**"；
> **根 tc 不可变、永不被任何第三方 extend 触碰**。变体与其父（根 tc）是**派生关系，不是修改关系**。

- 因为变体在机制上是"派生"而非"修改"，**hermetic（封闭性）结构性成立、无需政策强制**：
  依赖永远不可能被本工程的 tc 变体编译（依赖各由"自己的根 tc / 自己的变体"编译）；根 tc 永不被污染。
- 用户指定：**tc 把对外暴露的编译器钩子移入 `std.tc`**（标准库），以
  **开放枚举 / 开放变量体 / 开放结构体**形式声明；`extend` 模块只需 `import std` 即可改写这些开放类型
  （例如某结构体类型某运算符的语义）。详见 DESIGN §3.1、§3.2。

```
root tc（语言本身，含 std，不可变基础）
  ├─ 项目P: extend 模块 ──(root tc 编译)──► tc_P'  变体
  │     └─ tc_P' 编译 P 自身源码      ──► 制品
  ├─ 依赖D: 各自 extend ──(root tc 编译)──► tc_D'  变体
  │     └─ tc_D' 编译 D 自身源码      ──► .tlib（供 P 链接）
  └─ 无 extend 的包：直接用 root tc 编译
```

**tote 侧只需消费 `[compiler].extend` 指向的模块路径**；具体 extend 语法随 t 语言 extend 特性落地而确定（见 TC_INTERFACE_REQUESTS.md IR-1）。

---

## 4. 已决项全表（设计已闭环，无需再问用户）

| 项 | 结论 |
|---|---|
| D1 extend 声明 | `[compiler] extend = "src/extend.tc"`（可选；缺省=无变体，直接用 root tc） |
| D2 可扩展面暴露 | tc 钩子移入 `std.tc`（开放枚举/变量体/结构体）；extend 只需 `import std` |
| D3 变体缓存 | 内容寻址 `out/compiler/<hash>/tc'` |
| D4 依赖是否受 tc' 影响 | 结构性不可能（不变式已决）：依赖各由 root tc / 自身变体编译 |
| D5 extend 鸡生蛋 | extend 模块及其依赖由 root tc 编译（tc' 尚未存在） |
| D6 MVP 依赖源 | **仅 path + git**，registry 后置 |
| D7 feature 模型 | 无 feature；条件走 comptime |
| D8 代码生成 | `build.tc` 沙箱 comptime 脚本 |
| D9 增量粒度 | **target 级**（模块级后置） |
| D10 lockfile | **永远提交 tote.lock** |
| D11 版本 caret | 统一最左非零段 |

完整表 + 理由见 DESIGN §11。

---

## 5. MVP 范围与推荐起步顺序（DESIGN §12）

1. **真正的 TOML parser**（替换 src/tote.tc 现有字符串扫描 hack）——建议 tote 自带纯 t 实现。
2. **清单 schema v1**：`[package]` / `[dependencies]`(path+git) / `[build]` / `[profile]`。
3. **Resolver + `tote.lock`**（永远提交）。
4. **Fetcher**：path 软链 + git checkout 到内容寻址 store。
5. **变体派生流水线**（若 `[compiler].extend`）。
6. **Scheduler**：target 级增量 + 并行，调 tc。
7. **CLI**：`new/init build run test check clean update add remove metadata`。
8. **约定目录发现**：src/bin/tests/examples/benches。

> 起步建议：先不做 extend 变体（D5 链式依赖 tc 的 extend 语法），先把「无 extend 的普通工程」
> （path+git 依赖 → 解析 → fetch → 调 tc 编译 → 运行）端到端跑通，再叠加变体派生。

---

## 6. 协作纪律（建议 tote 沿用 t 工程的三阶段闸门）

t 工程有 `docs/AGENT_WORKFLOW.md` 规定的**三阶段强制确认闸门**：
① 设计完成（用户确认）→ ② 任务规划逐节点确认 → ③ 编码完成 + 用户手动测试通过 → 合入。
**任一口闸门未获用户主动明确确认，不得进入下一阶段**；且严禁擅自处理未决设计项。

**建议**：tote 工程复制到 `tote/docs/AGENT_WORKFLOW.md` 或在本文件补一份等价约定，新空间沿用同一纪律。

Git 约定（t 工程侧）：特性分支 `feat/<topic>`；完成验证链后 merge 进 `wb` 分支、停下等用户拍板；
非经用户明确"直接推 main"不直推；需要 PR 由用户主动告知。tote 工程若独立仓库，可沿用或简化此约定。

---

## 7. 与 tc 工程的接口依赖

tote 不实现编译器，全部委托 tc（或其派生变体）。tote 需要 tc 侧配合的接口修改，**建议位置与形态**
见 **`docs/TC_INTERFACE_REQUESTS.md`**（由 t 工程当前会话先给出基线建议）。

**请求流程约定**：
- 新 tote 空间在实现过程中，若确定需要 tc 工程改什么，请把**具体、可执行的请求**追加到
  `TC_INTERFACE_REQUESTS.md` 的「CONCRETE REQUESTS（请求信箱）」一节（模板见该文件）。
- t 工程当前会话会读取该信箱并落地接口修改；改完回写状态。
- 这样两个空间通过 `tote/docs/TC_INTERFACE_REQUESTS.md` 这一个文件异步协作，互不阻塞。

---

## 8. 给新空间的第一件事

1. 通读 `docs/design/DESIGN.md` 与本文。
2. 在 tote 工程内确认/建立三阶段协作纪律（见 §6）。
3. 从 §5 的 MVP 第 1 步（TOML parser）起步，先把「无 extend 普通工程」端到端跑通。
4. 遇到需要 tc 改动时，按 §7 写入请求信箱。
