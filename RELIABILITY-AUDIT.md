# 可靠性审查与验收（2026-10-01—2026-10-02）

## 范围与原则

审查对象是本目录的 Windows/WSL 代理配置、WSL 本地转发器、验证与回滚。用户要求由主代理制定计划及验收、Luna 实施；现有 sing-box 和当前连接不能中断。不操作其他项目，不读取或修改 provider 配置和 API Key。

## 提交后的默认机制

```text
WSL 中继承 proxy-env.sh 环境的应用
  → 优先 HTTP_PROXY / HTTPS_PROXY = http://127.0.0.1:20122
  → 仅当原生镜像回环不可达且 enableWslInteropFallback=true：
      [::1]:wslInteropPort → WSL Python TCP 转发器
      → 每个发送过至少一个字节的连接对应一个 Windows PowerShell 互操作进程
      → Windows sing-box 127.0.0.1:20122
  → sing-box 配置的出口 → 目标网站
```

原生镜像回环恢复后，不再把额外进程路径作为正常默认路径。互操作实现仍不会为零字节 TCP 探测启动 Windows 进程；并发上限 32、首字节等待 10 秒、客户端 EOF 后最多排空 3 秒均已实现并通过 runtime 测试，健康流式连接不因空闲时长被截断。TLS（传输层安全）仍由原始应用与目标网站建立，转发器只复制字节，不解密 HTTPS；HTTP 代理承载 HTTPS 网站与 HTTPS 代理端点的证书校验是两件不同的事。Windows 应用仍直接使用 Windows 代理。WSL 的 NAT 路径继续使用默认网关；镜像模式不能把局域网默认网关当作 Windows 主机。`wslinfo --networking-mode` 是模式判断依据；`autoProxy=false` 是全局 WSL2 配置，而代理变量只由选定发行版的 Bash profile 注入。

## 已确认的问题

| 问题 | 证据与影响 | 验收要求 |
| --- | --- | --- |
| 连接关闭后的资源回收不完整 | 旧 Python PID 1187 下 PowerShell 子进程 PID 1217 存活约 18 分钟；WSL TCP 连接处于 CLOSE-WAIT，仍占 3 个线程、7 个文件描述符。旧代码只等待下载线程完成 | 模拟客户端 EOF、RST、子进程挂起，有限时间内回收；长连接正常数据不被无故截断 |
| 端口开放被误当成自身健康 | 旧启动函数只做 nc，不核对进程、版本、目标 | 外部程序占用相同端口时明确失败，不把用户流量交给它 |
| 并发启动与 PID 复用 | 无启动锁；仅按命令行包含 interop-proxy.py 判断并发送 kill | 并发启动只产生一个实例；过期 PID 不杀其他进程 |
| 更新配置后运行进程保留旧目标 | 安装覆盖脚本，但已运行 Python 的常量不会更新 | 目标或版本不一致时明确报错，或为新连接安全加载新配置 |
| 验证目标混淆 | 上轮 -Verify -ProxyPort 20199 在 Windows 报失败，但 WSL 实际仍请求已安装的 20122 并显示 PASS | WSL 必须说明目标一致性，不能以旧目标通过代替本次配置 |
| 配置字符串直接插入 shell | noProxy 和候选主机直接进入 shell 双引号模板 | 特殊字符不可变成 shell 命令 |
| 并发和超时缺少上限 | 每次连接创建线程和 Windows 进程，缺少统一资源上限 | 有明确并发上限、启动超时和退出回收路径 |
| 互操作环境与路径脆弱 | 固定 /mnt/c Windows 路径，后台进程继承第一次启动的 WSL_INTEROP | 路径正确解析；失效环境明确报错或从有效 socket 恢复 |
| 回滚保护不完整 | 创建的 INI 节仅剩用户注释时可能被删除；损坏的管理标记需保护 | 隔离配置样例证明保留注释、用户后续改动及原始值 |

## 能力边界

- 这是供本机开发应用使用的 HTTP/HTTPS 代理入口，不是 VPN，也不是全系统透明代理。不自动覆盖 UDP、QUIC、ICMP、容器网络、独立 systemd 服务、其他用户或未继承 shell 环境的程序。
- proxy_off 只清除当前 shell 的环境，不能修改已经启动的程序。恢复和切换目标通常需要新 shell 或 `source ~/.profile`；`proxy_refresh` 只适用于当前 shell 已加载兼容的新 profile 函数。
- 使用互操作转发需要 WSL 能运行 Windows 程序、Python、IPv6 回环和现有 Windows 代理可用。每个活动连接启动 Windows 进程有额外成本，不适合高并发服务器负载。
- 401/403/404 证明能收到 HTTP 响应，不证明 API 凭证、额度、模型权限或所有业务请求成功。
- 自动启动不等于服务监督；是否具有崩溃自动恢复、登录后恢复、无终端时恢复须分别说明和测试。
- 回滚的 Windows 部分是关闭代理/清除变量，不是恢复任意安装前的旧代理快照；本轮不得将其称为完整系统时光回退。

## 根因结论的证据范围

本机证实 mirrored 模式下 Windows IPv4 localhost 代理超时，而 Windows 侧代理正常，IPv6 本地互操作通路成功。没有对本机完成包级证据链，因此不能确认是特定内核缺陷、TUN 劫持或 SYN-ACK 端口改写。

Microsoft 文档说明 mirrored 支持从 WSL 访问 Windows 的 127.0.0.1，不支持通过 ::1 访问 Windows；这里的 ::1 服务位于 Linux 内。问题报告 #40343 描述了相似症状，但报告环境和本机版本不同。参考：[WSL 网络说明](https://learn.microsoft.com/en-us/windows/wsl/networking)、[WSL 配置说明](https://learn.microsoft.com/en-us/windows/wsl/wsl-config)、[相似问题报告](https://github.com/microsoft/WSL/issues/40343)。

## 验收计划

1. Luna 完成代码修复、隔离回归测试；主代理逐项检查实现与证据。
2. 在 PowerShell 5.1 下运行解析、模板、dry-run、隔离 INI 测试；不得把真实全局状态变更当作本轮必要步骤。
3. 用独立临时目录和 IPv6 端口测试运行时身份、并发、断线回收和配置更新；不终止现有转发器。
4. 如需启用新版，用另一个本地端口并行部署，先验证再切换新 shell；保留旧连接使用的进程。
5. 实测新登录 shell 中的 TCP 与 HTTPS；核对监听只在回环地址。
6. 整机重启、睡眠/恢复、WSL shutdown、真实全局回滚和长期稳定性测试不冒充已执行结果；若未执行，最终结果明确列为未测试。

## 最终验收记录（2026-10-02，部署快照）

以下是当天约 13:00 的部署与验收快照，不代表之后任意时刻的 PID 仍然存在：

- 完整 runtime 命令
  `wsl.exe -- env DEV_PROXY_TEST_REAL_WINDOWS=1 PYTHONDONTWRITEBYTECODE=1
  python3 -B -m unittest tests.test_interop_runtime -v`：15 tests、46.866s、
  0 skipped；包括 13 个 runtime case（含 SIGTERM）、1 个 unit case 和 1 个
  real-Windows case。
- 真实 Windows case 的 PID 36448、18912 均回收，Linux 侧回到 1 个线程、4 个
  文件描述符。
- 并行迁移状态：新 `::1:20181` relay（当时 PID 62371）已验证；旧
  `::1:20180` relay（当时 PID 1039）保留以服务旧连接，未主动停止。
- Windows sing-box PID 22020 的启动时间为 `2026-10-02 06:47:02`；部署前后
  一致。`.wslconfig` SHA-256 为
  `13716E14B042743362EC93E12F0877F12999A6663C3F0193BB8B6DC32128272A`，未变化。
- 重装 profile backup 数量保持 4→4，active source 保持 1。错误端口 20199
  验证按预期失败并报告目标不匹配，未改变 `config.json` 时间戳。
- 独立验证 `verify` exit 0：mirrored / `mirrored-interop` / host `::1` /
  port `20181` / TCP reachable；Anthropic GET 返回 404、curl exit 0；
  `git ls-remote HEAD` 返回 `aca97b0eeaae9c2adff75883c41d2137b56ddb0e`、exit 0。
  未执行 pull、fetch 或 npm。
- 9 个 shell case、2 个 PowerShell fixture、14 个 maintenance checks 均通过。
- 迁移备份位于私有目录 `.dev-proxy-migration-backup-20261002-131024`，并已由
  `git/info/exclude` 忽略；本审查不读取其内容。

整机重启、睡眠/恢复、WSL shutdown、真实全局 rollback、长期 soak 和真实 NAT
切换未测。历史 PID 1187/1217 的 CLOSE-WAIT 泄漏仍是旧实现证据；不据此声称
当时的旧 PID 1039 存在同一泄漏。

## 后续 fallback 收敛验收（2026-10-02）

原生镜像 localhost 恢复后，代码改为直连优先，只有全部直连候选不可达且
`enableWslInteropFallback=true` 时才启动互操作 relay。新增隔离用例分别证明：
原生 `127.0.0.1` 可达时不创建 relay 状态；开关关闭时不启动 relay；原生候选
被隔离夹具移除时仍可经动态 `[::1]` 临时端口访问 Anthropic 并收到 HTTP 404。

- Windows PowerShell 5.1 只读维护检查：14 passed、0 failed、0 skipped。
- WSL runtime 与 shell：26 tests，其中 25 passed；需要显式环境变量启用的
  real-Windows runtime case 本轮 skipped。另一个动态端口 relay 集成测试通过。
- PowerShell 配置与 WSL 安装/回滚夹具通过；未运行会改真实状态的 `-Full`。
- 未重启 WSL、未改 sing-box、未停止 `20180/20181` relay，也未把更新安装进
  当前真实 profile。

## 最终结果

本轮代码、隔离 fixture、维护检查和部署快照验收已完成；上述未测项目仍是
明确限制，不应被描述为通过。部署快照中的生产端口切换采用并行 relay，旧
连接继续使用旧端口。代码的后续默认策略已收敛为原生镜像 localhost 优先、
互操作 relay 仅作可关闭的自动兜底；更新后的 profile 在未来重新安装后生效，
不要求为本次提交重启 WSL 或停止现有 relay。
