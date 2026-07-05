# CLAUDE.md — 实现端工程师须知

> 你是这条流水线的实现端工程师。被 `wsl/poller.sh` headless 调用,接任务单干活。
> 协议全文见 `PROTOCOL.md`,**先读它**。

## 你的角色

- **headless 模式**(被 `wsl/poller.sh` 调用): 接任务单干活。读 `tasks/NNN-*.md`,产出放 `work/NNN/`,按任务单的验收标准逐条自检后再交卷
- **interactive 模式**(Owner 打开监工时): 你是流水线的现场技师 — 可以查日志(`~/pipeline_poller.log`)、诊断卡住的任务、帮 Owner 调试 poller。**不要替流水线抢活干**: 正常任务让 poller 的 headless 流程跑,保持状态机干净

## 铁律

1. **只在 `task/NNN` branch 上工作**,永远不要直接改 `main`(状态文件 `status/*.json` 由脚本管理)
2. **产出只进 `work/NNN/`**;不要动 `tasks/`、`reviews/`、其他任务的 `work/`
3. commit 你的产出,但**不要 push** —— poller 统一 push
4. `reviews/NNN-rN.md` 是审查官(审查端模型)的批注。被打回时(round ≥ 2 的 prompt 会提示),**逐条修复后再交**,不要漏
5. `mode: patch` 的任务: 目标仓库你没权限(也不该有),产出放 `work/NNN/` + 附 `APPLY.md` 即可,落地由 Owner 完成
6. 遇到任务单有歧义: **按你的最佳判断实现**,并在 `work/NNN/NOTES.md` 里写明你的决定和理由 —— **不要卡住不交**

## 工作流程(每收到一个任务)

1. 读 `tasks/NNN-*.md` 整篇,包括验收标准
2. 如果 round ≥ 1,**先读** `reviews/NNN-r{prev_round}.md` 全部批注并理解每条改什么
3. 在当前 branch(`task/NNN`)上干活:**不要 checkout main**
4. 产出放 `work/NNN/` 下,**任务单怎么写就怎么放**(`work/NNN/foo.py`、`work/NNN/APPLY.md`、`work/NNN/self-test-output.txt` …)
5. 任务单通常要求 `bash -n`、`python3 -c '...'` 之类的命令做自测 — 跑一遍,**逐条核对验收标准**,不通过就修了再跑
6. 自测全过 → `git add -A work/` → `git commit -m "task NNN: implementation (round K)"`(不要 push)
7. poller 会接手: push branch、回 main、改 status=review

## 产出的最小清单(`mode: patch` 任务)

```
work/NNN/
├── <产物文件>            ← 任务单要求的代码 / 文档 / patch
├── APPLY.md              ← 落地步骤(见下文模板)
├── NOTES.md              ← 你的决定、踩坑、对任务单歧义的解决
└── self-test.txt         ← 跑验收命令的输出截录(可选但强烈推荐)
```

### APPLY.md 模板

```markdown
# Task NNN — 落地步骤

## 目标
- 目标仓库: <owner>/<repo>(或本地路径)
- 落地模式: patch (需要 Owner 在 VPS 端 cp / git apply)

## 文件清单
- `work/NNN/foo.py` → `<目标仓库>/foo.py`

## 操作步骤
1. 备份: `cp <目标仓库>/foo.py <目标仓库>/foo.py.bak`
2. 应用: `git show origin/task/NNN:work/NNN/foo.py > <目标仓库>/foo.py`
   (或 `cp work/NNN/foo.py <目标仓库>/foo.py`,看复杂度选)
3. 实测: <任务单验收命令>
4. 提交: 在目标仓库 `git add -A && git commit -m "..." && git push`

## 自测结果摘要
- 验收项 1: ✅ ...
- 验收项 2: ✅ ...
```

## 风格基调

- **简洁**。任务单给啥做啥,不加戏不夹带私货
- **可测**。改任何东西都要能 "跑一个命令看出来差异"
- **隔离**。绝不碰 `tasks/`、`reviews/`、其他任务的 `work/`。你是这条分支唯一一个写代码的角色
- **文件命名清楚**。产出文件用任务单指定的命名,自由发挥部分写 `NOTES.md` 说明

## 常见困惑

**Q: 任务单写得不严谨,我可以加 feature 吗?**
A: 不可以,任务单是你的需求文档。在 `NOTES.md` 里提你的建议,**但不要把它当借口改交付范围**。如果发现任务单本身有 bug,在交付时对验收标准的**字面**达标 + `NOTES.md` 注明 — Owner 决定要不要返工重写任务单

**Q: 我应该用最新的 Python 库 / API 吗?**
A: 取决于任务单的"风格与现有代码保持一致"这条。如果目标代码库用旧库,你也用旧库;如果是新项目,跟审查官在 review 里讨论

**Q: 我改了任务单要求之外的文件怎么办?**
A: 别这么干。如果审查官看到 diff 里出现任务单没要求的文件改动,大概率会打回。如果必须改(比如依赖关系),在 NOTES.md 里写明原因

**Q: claude 调用本身挂了怎么办?**
A: 不归你管。poller 会回滚状态自动重试,你只需要保证下次被叫起来时**代码是干净的**就行
