# VPS / 审查端安装(5 分钟)

审查端通常是一台跑 24/7 的小 VPS,也可以和派单端共用一台机器。
审查官要装 `claude` CLI(注意: **审查端大概率以 root 跑**,所以会用 `--allowedTools` 白名单而不是 `--dangerously-skip-permissions`,详见 README §4 坑①)。

## 1. clone 传送带

```bash
# 默认放 /opt,要换位置就 export PIPELINE_BUS=...
sudo git clone git@github.com:<your-account>/pipeline-bus.git /opt/pipeline-bus
sudo chown -R "$USER" /opt/pipeline-bus
```

把 `<your-account>` 换成你的 GitHub 账户。需要 SSH key 配好能 push。

## 2. 设置审查官模型(可选)

```bash
# 默认 sonnet,要换就覆盖
export PIPELINE_REVIEWER_MODEL=sonnet    # 或 sonnet-4-6 / opus-4-8 / 你的内部别名
echo 'export PIPELINE_REVIEWER_MODEL=sonnet' >> ~/.bashrc
```

审查官**必须**是稳定的中档模型 — 输出风格/格式如果变,`head -1 | grep -o 'APPROVED\|NEEDS_CHANGES'` 的判定会失效。详见 README §5 Q1。

## 3. 通知 hook(可选)

不配就不通知(终态静静躺着等 Owner 来翻 `cat status/*.json`)。
要通知就照 `vps/notify.sh.example` 改:

```bash
cd /opt/pipeline-bus/vps
cp notify.sh.example notify.sh
chmod +x notify.sh
# 取消注释 + 填 token / webhook url
$EDITOR notify.sh
```

挂到环境变量:

```bash
echo 'export PIPELINE_NOTIFY=/opt/pipeline-bus/vps/notify.sh' >> ~/.bashrc
```

## 4. crontab 挂定时

```cron
*/10 * * * * bash /opt/pipeline-bus/vps/reviewer_poll.sh
```

`flock` 自带防重入,重复触发无害。

## 5. 试跑

```bash
bash /opt/pipeline-bus/vps/reviewer_poll.sh
tail /tmp/pipeline_reviewer.log
```

有 `state==review` 的任务就会开始审;没有就静默退出。

## 6. allowedTools 解释

`reviewer_poll.sh` 给审查官的 claude 调用加了 `--allowedTools` 白名单,这是审查端跟实现端的关键差异:

| 工具 | 作用 | 为什么需要 |
|---|---|---|
| `Read, Glob, Grep` | 看代码 / 列文件 / 搜内容 | 审查官要看的所有东西 |
| `Write, Edit` | 写 `reviews/NNN-rN.md` | 审查报告 |
| `Bash(git *)` | `git diff`、`git log`、`git show`、`git add`、`git commit` | 看 diff、commit 报告 |
| `Bash(ls *), Bash(cat *), Bash(head *), Bash(wc *)` | 列目录、读文件、计数 | 静态审查辅助 |
| `Bash(python3 -c *)` | 快速跑小段代码读 JSON 状态 | 看 status 文件 |
| 一切其他(Bash 任意 / `WebFetch` / `WebSearch` / 网络工具) | **拒绝** | 防止审查官跑实现端代码或抓外网 |

这等价于: 审查官能看、能 commit 一份报告,**但不能执行审查对象的代码、不能写审查范围外的文件、不能访问网络**。即使审查官的 prompt 被对手污染,损失也被钳制在 "一张乱写的批注" 范围内。

---

## 7. 故障排查

### 审查官说 `permission denied` / "command not allowed"

说明 `--allowedTools` 白名单里有需要但没列的工具。常见追加项:

- `Bash(date *)` — 想在报告里加时间
- `Bash(stat *)` — 看文件元信息
- `Bash(jq *)` — 解析 JSON

加进 `reviewer_poll.sh` 那行 `--allowedTools "..."` 即可。

### 审查官报告第一行没法解析

- 检查 `reviews/NNN-rN.md` 的第一行: 必须是 `VERDICT: APPROVED` 或 `VERDICT: NEEDS_CHANGES`(冒号后空格,大小写敏感)
- 如果审查官写了 `Verdict: Approved`(小写)或漏了冒号,poller 会把它当 `PARSE_FAIL` → 进 `stuck`

解决方法: 在 prompt 里强调 **"第一行必须是 VERDICT: APPROVED 或 VERDICT: NEEDS_CHANGES,大小写敏感"**,或换个更稳定的审查官模型。

### 想强制某任务重新审一次

修改 `status/NNN.json` 把 `state` 拨回 `"review"`、`round` 减 1,然后 push main:

```bash
python3 -c "
import json,datetime
d=json.load(open('/opt/pipeline-bus/status/NNN.json'))
d['state']='review'
d['updated']=datetime.datetime.now().astimezone().isoformat()
json.dump(d,open('/opt/pipeline-bus/status/NNN.json','w'),ensure_ascii=False)"
cd /opt/pipeline-bus && git add status/NNN.json && git commit -m "force re-review NNN" && git push
```

下个 tick 自动认领。
