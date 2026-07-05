# WSL / Linux 端安装(实现端,5 分钟)

前提: 你的实现端机器已经装好 claude CLI(可执行 `claude` 命令),并且有 git。

## 1. clone 传送带

```bash
cd ~
git clone git@github.com:<your-account>/pipeline-bus.git
```

把 `<your-account>` 换成你实际放这个 repo 的 GitHub 账户。需要 SSH key 已经配好(可以 `git push` 试一下)。

## 2. 设置实现工人模型(可选)

实现工人模型来自环境变量 `PIPELINE_MODEL`。**不设就用你本机 `~/.claude/settings.json` 里的默认**(通常是订阅制便宜模型)。

```bash
# 例: 临时覆盖
export PIPELINE_MODEL=claude-sonnet-4-6

# 持久化
echo 'export PIPELINE_MODEL=claude-sonnet-4-6' >> ~/.bashrc
```

要换模型时改这个变量就行,**`poller.sh` 一个字都不用动**。

## 3. 试跑一次

```bash
bash ~/pipeline-bus/wsl/poller.sh
tail ~/pipeline_poller.log
```

应当看到 `claiming task NNN ... submitted for review` 这种日志(对应任务单排队状态)。没活就静默退出 —— 不报错就对了。

## 4. 挂定时

### 方案 A: cron(推荐 Linux/WSL)

```cron
@reboot sleep 60 && bash ~/pipeline-bus/wsl/poller.sh
*/10 * * * * bash ~/pipeline-bus/wsl/poller.sh
```

`@reboot` 那条保证开机 60 秒后自动起一轮,不用等下一个 10 分钟点。

### 方案 B: systemd-timer(Linux 现代方式)

```ini
# ~/.config/systemd/user/pipeline-poller.timer
[Unit]
Description=Pipeline bus poller

[Timer]
OnBootSec=1min
OnUnitActiveSec=10min

[Install]
WantedBy=timers.target
```

```ini
# ~/.config/systemd/user/pipeline-poller.service
[Service]
ExecStart=/bin/bash -lc 'bash /home/<your-user>/pipeline-bus/wsl/poller.sh'
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now pipeline-poller.timer
```

### 方案 C: Windows 任务计划(WSL 桥接)

任务计划程序 → 新建任务 → 触发器「登录时」+「每 15 分钟」→
操作: `wsl.exe -e bash -lc "bash ~/pipeline-bus/wsl/poller.sh"`

## 5. 检验

- 关电脑/重启后开机 1 分钟内 `tail ~/pipeline_poller.log` 应该能看到日志追加
- 在 pipeline-bus 仓库的 main 上 push 一张新任务单(status=queued),10 分钟内应被认领并开始实现
- 想手动催一轮:`bash ~/pipeline-bus/wsl/poller.sh`(幂等)

## 注意

- poller **幂等 + 带 `flock`**,重复触发无害
- 电脑关机=暂停,**开机自动补作业**(`@reboot` 起一轮)
- `--dangerously-skip-permissions` 仅用于此隔离工作流(poller 只在 bus repo 里干活)。任务单来源只有 Owner(唯一有 push 权限的人),供应链封闭
- 日志默认在 `~/pipeline_poller.log`,要换位置设 `PIPELINE_LOG` 环境变量
- 默认 BUS 路径 `~/pipeline-bus`,要换位置设 `PIPELINE_BUS` 环境变量
