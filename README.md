# xboard-node（xymhh fork）

[Xboard](https://github.com/cedar2025/Xboard) 的节点端后端，支持 `sing-box` / `xray-core` 双内核。

本仓库是 [cedar2025/Xboard-Node](https://github.com/cedar2025/Xboard-Node) 的 fork，基线 `v1.13`（`0a29338`），
与上游**只差一处功能修复**：

> **sing-box 内核下，面板修改「自定义出口 / 自定义路由」保存后立即生效，不用重启节点进程。**

上游的行为是：保存后日志只打一行 `config updated, N users`，但实际不生效，必须 `systemctl restart xboard-node`。
本 fork 改为：检测到出站 / 路由 / DNS 变化就**重建内核**——进程不重启，WS 连接、上报循环、证书、流量计数全部保留，
中断为亚秒级；新配置起不来则自动回滚到上一个可用配置。

- 修复原理、代价、与上游的差异清单：[FORK_NOTES.md](FORK_NOTES.md)
- 已发布二进制：<https://github.com/xymhh/Xboard-Node/releases>
- 同步上游：`git fetch upstream && git rebase upstream/dev`（改动集中在 `internal/kernel/singbox/singbox.go` 加一个测试文件）

> 免责声明：本项目仅供学习研究使用。

## 功能（与上游一致，未做任何删减）

- 协议：V2Ray 系、Trojan、Shadowsocks、Hysteria2、TUIC、AnyTLS
- 同步：WebSocket 推送 + REST 轮询双通道
- 用户控制：限速、设备数限制、在线 IP 统计、热更新
- 部署模式：node（单节点）/ machine（多节点托管）/ standalone（无面板）
- 多实例：单进程绑定多个面板 / 节点

## 安装 / 升级

### 场景一：节点本来就用面板给的命令装的（推荐路径）

面板给的安装命令（`curl ... | sudo bash -s -- --mode machine ...`）装出来的路径是固定的：

| 项 | 路径 |
| --- | --- |
| 二进制 | `/usr/local/bin/xboard-node` |
| 配置 | `/etc/xboard-node/config.yml` |
| systemd 单元 | `/etc/systemd/system/xboard-node.service` |
| 备份 | `/etc/xboard-node/backups/<时间戳>/` |
| 命令行工具 | `/usr/local/bin/xbctl` |

换成带修复的二进制——**一条命令**（自动取最新 Release，不用记版本号）：

```bash
curl -fsSL https://raw.githubusercontent.com/xymhh/Xboard-Node/dev/fork-upgrade.sh | sudo bash
```

`fork-upgrade.sh` 做的事：识别架构 → 下载最新 Release 的 `xboard-node-linux-<arch>` → 自检能否运行 →
备份现有二进制到 `/etc/xboard-node/backups/manual/` → 替换 `/usr/local/bin/xboard-node` →
重启 `xboard-node.service` → 健康检查（`/healthz`），起不来**自动回滚**。

常用参数：

```bash
# 固定某个版本（不写就是 latest）
curl -fsSL .../fork-upgrade.sh | sudo bash -s -- --tag v1.13-xymhh.2
# 只下载 + 自检，不落盘、不重启
curl -fsSL .../fork-upgrade.sh | sudo bash -s -- --dry-run
# 回滚到最近一次备份
curl -fsSL .../fork-upgrade.sh | sudo bash -s -- --rollback
```

不想跑脚本，手动两步也行：

```bash
# 1) 取二进制：latest 永远指向最新 Release；要锁版本就把 latest 换成 tag
curl -fL -o /tmp/xboard-node \
  https://github.com/xymhh/Xboard-Node/releases/latest/download/xboard-node-linux-amd64

# 2) 用官方安装器替换（自动备份 + 重启 + 健康检查，失败自动回滚）
curl -fsSL https://raw.githubusercontent.com/cedar2025/xboard-node/dev/install.sh -o /tmp/install.sh
sudo bash /tmp/install.sh upgrade --binary /tmp/xboard-node --xbctl-binary /usr/local/bin/xbctl
```

几点说明：

- 升级**不会**改 `config.yml`：token、machine-id、内核类型、端口全部保持不变。
- `machine` 模式下，一台机器一个二进制托管多个节点实例，**每台机器只需换一次**。
- 多台机器先换一台灰度，验证通过再铺开。

### 场景二：全新安装

先用上游安装器装好，再按场景一的第 1、3 步换成 fork 二进制。

```bash
# 单节点模式
curl -fsSL https://raw.githubusercontent.com/cedar2025/xboard-node/dev/install.sh | \
  sudo bash -s -- --mode node --panel https://panel.example.com --token TOKEN --node-id 1

# 多节点托管模式
curl -fsSL https://raw.githubusercontent.com/cedar2025/xboard-node/dev/install.sh | \
  sudo bash -s -- --mode machine --panel https://panel.example.com --token TOKEN --machine-id 1
```

### 验证修复是否生效

```bash
systemctl show -p MainPID --value xboard-node    # 先记下 PID
journalctl -u xboard-node -f                     # 保持跟踪日志
# 然后到面板改一次「自定义出口」并保存，日志应出现：
#   [core] sing-box: static config changed (outbounds/routes/dns), rebuilding kernel
#   [core] sing-box kernel rebuilt users=3
# 同时上面记下的 PID 应保持不变（进程没有重启）
```

日志怎么读：

| 日志 | 含义 |
| --- | --- |
| `static config changed ... rebuilding kernel` | 出站/路由/DNS 变了，正在重建内核（修复生效） |
| `kernel rebuilt users=N` | 重建完成，用户数 N |
| `routing reload failed, rebuilding kernel` | 路由引用了新出口，走重建（正常） |
| `rebuild failed, restoring previous config` | 新配置有问题，已自动回滚，节点仍可用 |

### 回滚

```bash
# 方式一：脚本回滚（用最近一次自动备份）
curl -fsSL https://raw.githubusercontent.com/xymhh/Xboard-Node/dev/fork-upgrade.sh | sudo bash -s -- --rollback

# 方式二：手动指定备份（安装器和升级脚本的备份都在这两个目录）
ls -t /etc/xboard-node/backups/manual/          # 升级脚本的备份
ls -t /etc/xboard-node/backups/*/xboard-node    # 官方安装器的备份
sudo install -m755 <选中的备份文件> /usr/local/bin/xboard-node
sudo systemctl restart xboard-node
```

## 后续更新

**节点机**：以后每次更新都是同一条命令，不用改版本号：

```bash
curl -fsSL https://raw.githubusercontent.com/xymhh/Xboard-Node/dev/fork-upgrade.sh | sudo bash
```

**fork 出下一个版本**（上游有新提交，或本 fork 有改动时）：

```bash
git fetch upstream && git rebase upstream/dev && git push -f origin dev   # 同步上游
git tag v1.14-xymhh.1 && git push origin refs/tags/v1.14-xymhh.1          # 打 tag → CI 自动出包
```

- tag 命名规则：`<上游版本>-xymhh.<fork 序号>`；上游发 `v1.14` 时本 fork 从 `v1.14-xymhh.1` 开始。
- push tag 后约 5 分钟，`releases/latest/download/...` 就指向新版本，节点机再跑一次上面那条命令即可。
- 想锁版本：`--tag v1.14-xymhh.1`；不锁就是 latest。

## 构建

**不在本机编译**，推 tag 交给 GitHub Actions（约 5 分钟出包）：

```bash
git tag v1.13-xymhh.2 && git push origin refs/tags/v1.13-xymhh.2
```

Release 资产名与官方安装器一致，可直接喂给 `--binary`：
`xboard-node-linux-amd64`、`xboard-node-linux-arm64`、`xbctl-linux-amd64`、`xbctl-linux-arm64`。

> 注意：fork 的 Actions 默认处于未启用状态，新建 fork 后首次 push **不会**产生 run。
> 需到仓库 Actions 页面点一次 Enable，或调用
> `PUT /repos/<owner>/<repo>/actions/permissions {"enabled":true}`。

本地编译（离线或调试时用）：

```bash
make build-linux          # linux/amd64
make build-linux-arm64    # linux/arm64
```

要求 Go 1.26，交叉编译 `CGO_ENABLED=0`。

## Docker

本 fork 的 CI **不**构建镜像（上游那个 job 推 `ghcr.io/cedar2025/xboard-node`，fork 没有该命名空间的写权限）。
用 Docker 部署请用官方镜像（**不含**本修复），或自行构建本仓库：

```bash
docker build -t xboard-node:xymhh .
```

## xbctl

安装后运行 `xbctl` 查看帮助。常用命令：

```bash
xbctl list                          # 列出所有实例
xbctl status                        # 运行状态
xbctl bind add-node --panel URL --token TOKEN --node-id 1
xbctl bind add-machine --panel URL --token TOKEN --machine-id 1
xbctl bind remove-node --panel URL --node-id 1
xbctl service restart
```

## 配置

兼容旧的单面板配置；追加绑定会自动迁移成 `instances` 格式。字段说明见 `config.yml.example`。

## 扩展文档

- 自定义路由：[docs-custom-routes.md](docs-custom-routes.md)
- 自定义出口：[docs-custom-outbounds.md](docs-custom-outbounds.md)
- DNS 服务商（ACME DNS-01）：[docs-dns-providers.md](docs-dns-providers.md)

## 许可

MPL-2.0。
