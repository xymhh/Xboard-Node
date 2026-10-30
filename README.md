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

换成带修复的二进制：

```bash
# 1) 下载本 fork 的二进制（按机器架构选 amd64 / arm64）
curl -fL -o /tmp/xboard-node \
  https://github.com/xymhh/Xboard-Node/releases/download/v1.13-xymhh.1/xboard-node-linux-amd64

# 2) 取安装器（若本机已有 /etc/xboard-node/install.sh，可直接用那份）
curl -fsSL https://raw.githubusercontent.com/cedar2025/xboard-node/dev/install.sh -o /tmp/install.sh

# 3) 换二进制：自动备份 → 重启 → 健康检查（失败自动回滚）
sudo bash /tmp/install.sh upgrade --binary /tmp/xboard-node --xbctl-binary /usr/local/bin/xbctl
```

几点说明：

- `upgrade` **不会**改 `config.yml`：token、machine-id、内核类型、端口全部保持不变。
- `machine` 模式下，一台机器一个二进制托管多个节点实例，**每台机器只需换一次**。
- 多台机器先换一台灰度，验证通过再铺开。
- 装错架构或想退回：见下面「回滚」。

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
# 安装器每次升级前都会把旧二进制存进 backups/ 目录
sudo install -m755 /etc/xboard-node/backups/<时间戳>/xboard-node /usr/local/bin/xboard-node
sudo systemctl restart xboard-node
```

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
