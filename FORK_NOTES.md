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

```sh
# 构建（Go 1.26）
go build -trimpath -ldflags "-s -w -X main.version=v1.13-xymhh.1" -o xboard-node ./cmd/xboard-node

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

### 与上游的关系

本修复尚未上游化。若上游后续合入同类能力（社区 PR #60 只涉及出站协议支持，未涉及热更新），可弃用本 fork。
