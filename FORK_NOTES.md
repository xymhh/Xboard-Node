# Fork 说明（xymhh/Xboard-Node）

本仓库是 [cedar2025/Xboard-Node](https://github.com/cedar2025/Xboard-Node) 的 fork，
基线 `v1.13 (0a29338)`，只做**一处**功能修复，便于随上游 rebase。

## 修复：sing-box 内核下，面板改「自定义出口 / 自定义路由」保存后不生效

### 现象

- 面板修改 `自定义出口(custom_outbounds)` / `自定义路由(custom_routes)` 并保存 → 节点日志有 `config updated, N users`，但**流量仍走旧出口/旧规则**。
- 必须 `systemctl restart xboard-node` 才生效。xray 内核无此问题。

### 原因

`internal/kernel/singbox/singbox.go` 的 `Reload()` 只做两件事：替换路由规则、按 tag 重建 inbound。
**出站表（OutboundManager）从不重建** —— sing-box 也没有「原地替换某个出站」的 API。于是：

- `custom_outbounds` 变化 → 静默忽略；
- `custom_routes` 里引用新出口的规则 → `UpdateRules` 失败，但错误只写 Debug 日志，同样静默忽略；
- `Reload()` 返回 nil，服务层认为「配置已更新」，于是不会有任何补偿动作。

### 修复

1. 新增 `staticSectionsKey()`：把 `Reload` 无法增量应用的配置段（`outbounds` / `route` / `dns` / `experimental`）序列化成规范字符串，在 `Start` 成功后记录为 `s.staticKey`。
2. `Reload()` 开头比对：变了 → 走 `rebuildLocked()` 重建整个 box（不再静默忽略）。
3. `rebuildLocked()`：先 `stop(false)`（关监听、不等待排空——sing-box 监听未开 `SO_REUSEPORT`，旧 box 占着端口时新 box 无法 bind），再 `startLocked()`；**新配置起不来则回滚到上一个可用配置**，保证坏配置不会把节点打挂。
4. `UpdateRules` 报错时同样升级为重建（原来是 Debug 静默降级）。
5. `Start()` 拆出无锁的 `startLocked()`，`Reload` 可复用（`Start` 内部持 `s.mu`，直接调用会死锁）。
6. 用户增删/到期仍走增量热更新，**不**触发重建。

### 语义与代价

- 效果等价于 `systemctl restart xboard-node`，但**不重启进程**：WS 连接、上报循环、证书管理、流量计数全部保留，中断为亚秒级（关旧 box → 建新 box）。
- 触发条件只在出站/路由/DNS/experimental 变化时；改端口/协议/TLS/用户仍走原有热更新路径。
- 改路由也会触发重建（取舍：宁可多一次亚秒重建，也不要「规则指向不存在的出口」这种静默降级）。

### 日志（部署后判断是否生效看这几行）

```
[core] sing-box: static config changed (outbounds/routes/dns), rebuilding kernel
[core] sing-box kernel rebuilt users=N
[core] sing-box rebuild failed, restoring previous config error=...
[core] routing reload failed, rebuilding kernel error=...
```

### 验证

- 新增 `internal/kernel/singbox/reload_rebuild_test.go`：真实 sing-box 实例上验证「出站变化重建并生效」「路由变化重建」「仅用户变化不重建」「配置未变不重建」「坏配置回滚」。
- 同一批测试在**未打补丁的上游代码**上失败（`outbound change must rebuild the box` / `route change must rebuild the box`），补丁后全部通过 → 修复可证伪。
- `go test ./... -count=1` 全绿；`go build ./...`、`go vet` 通过。

### 部署 / 回滚

#### 构建：用 GitHub Actions，不在本机编译

fork 保留了上游 `.github/workflows/ci.yml`，改动三处（见下「CI 与上游的差异」）。**推 tag 即出二进制**：

```sh
git tag v1.13-xymhh.1 && git push origin v1.13-xymhh.1
# 构建完成后（约 5 分钟）下载对应架构的二进制：
curl -fL -o /tmp/xboard-node https://github.com/xymhh/Xboard-Node/releases/download/v1.13-xymhh.1/xboard-node-linux-amd64
```

Release 里的资产名与官方安装器一致：`xboard-node-linux-amd64` / `xboard-node-linux-arm64` / `xbctl-linux-*`。

已发布并核验：`v1.13-xymhh.1`（2026-10-30），amd64 资产 66,977,954 B，`./xboard-node -v` 输出
`xboard-node v1.13-xymhh.1 (built 2026-10-30T02:29:31Z)`，二进制内含 `static config changed (outbounds/routes/dns), rebuilding kernel` 等补丁字符串。

> fork 的 Actions 在 GitHub 上默认未启用：新建 fork 后首次 push **不会**产生 run，需要
> `PUT /repos/<owner>/<repo>/actions/permissions {"enabled":true}` 与
> `PUT /repos/<owner>/<repo>/actions/workflows/ci.yml/enable`（或到 Actions 页面点一次 Enable）。

本地编译（仅离线或调试时用）：

```sh
go build -trimpath -ldflags "-s -w -X main.version=v1.13-xymhh.1" -o xboard-node ./cmd/xboard-node
```

#### A. 用官方安装器装的节点（推荐，本 fork 目标机型）

面板给出的安装命令是
`curl -fsSL https://raw.githubusercontent.com/cedar2025/xboard-node/dev/install.sh | sudo bash -s -- --mode machine --panel ... --token ... --machine-id N`，
安装器（`install.sh` 顶部常量）固定了这些路径：

| 项 | 路径 |
| --- | --- |
| 二进制 | `/usr/local/bin/xboard-node` |
| 配置 | `/etc/xboard-node/config.yml` |
| 单元 | `/etc/systemd/system/xboard-node.service`（`ExecStart=/usr/local/bin/xboard-node -c /etc/xboard-node/config.yml`） |
| 备份 | `/etc/xboard-node/backups/<YYYYmmdd-HHMMSS>/` |
| CLI | `/usr/local/bin/xbctl` |

用安装器自带的 `upgrade` 换二进制：自动备份 → 重启 → 健康检查，失败会自动回滚。

```sh
# 1) 现状（顺带确认安装器副本是否存在）
sudo bash /etc/xboard-node/install.sh status

# 2) 把新二进制放到 /tmp/xboard-node（scp 或本机 go build）
# 2') 若上面提示 install.sh 不存在：当初是管道安装，脚本没落到本机，先取一份
curl -fsSL https://raw.githubusercontent.com/cedar2025/xboard-node/dev/install.sh -o /tmp/install.sh

# 3) 覆盖（--xbctl-binary 复用已装的 xbctl，避免联网下载失败中断升级）
sudo bash /tmp/install.sh upgrade --binary /tmp/xboard-node --xbctl-binary /usr/local/bin/xbctl

# 4) 验证
systemctl show -p MainPID --value xboard-node      # 记下 PID
journalctl -u xboard-node -n 30 --no-pager
# 然后在面板改一次自定义出口：日志应出现 rebuilding kernel，且上面的 PID 不变

# 5) 回滚（安装器每次升级前都把旧二进制存进 backups/）
sudo install -m755 /etc/xboard-node/backups/<时间戳>/xboard-node /usr/local/bin/xboard-node
sudo systemctl restart xboard-node
```

要点：

- `upgrade` **不会**重渲染 `config.yml`（token / machine-id / kernel / health-port 全不动），只换二进制、`xbctl` 和 systemd 单元。
- `--mode machine` 下一台机器一个二进制托管多个节点实例 → 每台机器只需换一次。
- 多台机器先换一台灰度，验证日志 + PID 不变后再铺开。

#### B. 手动控制（不用安装器）

```sh
# 替换（先备份原二进制）
systemctl stop xboard-node
install -m755 xboard-node /usr/local/bin/xboard-node   # 路径以你机器上 systemd 单元为准
systemctl start xboard-node

# 回滚
systemctl stop xboard-node && install -m755 /root/xboard-node.v1.13.bak /usr/local/bin/xboard-node && systemctl start xboard-node
```

### 上游同步

```sh
git remote add upstream https://github.com/cedar2025/Xboard-Node.git   # 已加
git fetch upstream && git rebase upstream/dev
```
改动集中在 `internal/kernel/singbox/singbox.go`（+新增测试文件），冲突面很小。

### CI 与上游的差异（fork 专属，共 3 处）

`.github/workflows/ci.yml` 只动了这几处，test / build / release 的构建逻辑与上游一致：

1. 删除 `build-docker` job —— 它推 `ghcr.io/cedar2025/xboard-node`，fork 没有该命名空间写权限，每次必失败。
2. `release` job 改为只在 **tag 推送**时触发（上游是 tag 或 `dev` 分支推送）—— 避免与仓库里已存在的 `dev` tag 撞名，也避免把 fork 的 dev 当滚动发布。
3. 新增 `workflow_dispatch`（Actions 页可手动触发）；Go 版本 `1.25.7` → `1.26`，对齐 `go.mod` 的 `go 1.26`。

### 与上游的关系

本修复尚未上游化。若上游后续合入同类能力（社区 PR #60 只涉及出站协议支持，未涉及热更新），可弃用本 fork。
