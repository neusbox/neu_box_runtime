# neu_box_runtime

容器接入 neu-box 沙盒的 **runtime 侧**：两个可执行文件、一份配置、一个装机脚本。

接口契约在 `neu_box_worker/docs/runtime-hook.md`（Worker / neu_box_runtime /
neu_box_goClient 三方共用）。**协议字段是跨仓库的，改这里之前先改契约。**

沙盒是授权方，容器是受托方。容器不搬进沙盒 cgroup，而是靠 mount namespace inode
把自己"挂"到某个沙盒名下（`container_owner[mnt_ns_inum] = sandbox_name`，BPF map）。
没登记的容器即使卡空着也一律拒绝设备 —— **fail-closed**。登记必须发生在容器
ENTRYPOINT 之前，OCI runtime hook 是唯一能卡在这个窗口里的点。

## 两个二进制

| 二进制 | 源码 | 干什么 |
|---|---|---|
| `neu-box-runtime` | `cmd/neu-runtime` | runc wrapper，占 Docker `default-runtime` 的位置：`create`/`run` 时把 hook 注入 OCI bundle，其余情况把 argv 逐字转发给真 runc |
| `neu-box-hook` | `cmd/neu-hook` | OCI hook，由 runc 在 `hooks.createRuntime` 阶段拉起（`NEU_BOX_HOOK_PHASE` 可切回 `prestart`）：从 stdin 读 OCI state，把容器登记到 Worker |

```
docker run --annotation sandbox_cgroup=<name> ...
        │
        ▼
   dockerd → containerd → neu-box-runtime（读 bundle/config.json，注入 hook）
        │
        ▼
   真 runc（建 namespace/cgroup）
        │
        ▼
   neu-box-hook（stdin 读 OCI state）→ POST /container/register
        │
   ┌────┴────┐
 2xx        4xx / 超时 / 连不上
   │            │
 hook 退 0    hook 退非 0 → runc create 失败，容器不启动
```

**登记不上就绝不放行。** 放行的代价是容器内第一次 NPU 初始化时驱动建出一张空
UDA 表并按 mnt ns 永久缓存，容器从此坏掉，事后补登记也修不回来。

## 安装

```bash
sudo bash scripts/install.sh              # 编译 + 安装
sudo bash scripts/install.sh --no-build   # 用 dist/ 里已有的二进制
```

脚本做这些事：编译（`CGO_ENABLED=0`，静态）→ 装到 `/usr/local/bin` → **验证二进制
能执行** → 写 `/etc/neu-box/runtime.env` → 改 `/etc/docker/daemon.json`。

顺序是硬要求，不是风格问题：`neu-box` 是 **默认 runtime**，`default-runtime` 指向
一个不存在或跑不起来的二进制，**dockerd 会起不了任何容器**。所以脚本先验证
（`neu-box-runtime --help` 会转发给真 runc，一次验证两件事）再动 daemon.json。
`uninstall.sh` 反过来：**先还原 daemon.json，再删二进制**。

脚本**不会**重启 dockerd —— `runtimes` / `default-runtime` 不支持热加载，而重启会
杀掉当时所有运行中的容器，这个决定得由人来做：

```bash
docker ps                        # 先看会杀掉谁
systemctl restart docker
docker info --format '{{.DefaultRuntime}} {{.Runtimes}}'
```

### 手工安装

1. 编译并装二进制（见下），装到 `/usr/local/bin/neu-box-runtime` 和
   `/usr/local/bin/neu-box-hook`。
2. 写 `/etc/neu-box/runtime.env`（模板 `deploy/config/runtime.env.example`，
   权限 `0640 root:root`）。注意 `NEU_BOX_WORKER_URL` 的端口要和 worker 的
   `NEU_BOX_PORT` 保持一致。
3. 改 `/etc/docker/daemon.json`（**先备份**）：

```json
{
  "default-runtime": "neu-box",
  "runtimes": { "neu-box": { "path": "/usr/local/bin/neu-box-runtime" } }
}
```

4. 重启 dockerd。

回滚：`sudo bash scripts/uninstall.sh`。

## 配置

`/etc/neu-box/runtime.env`（角色约定：`/etc/neu-box/<role>.env`，dotenv 格式，
键一律 `NEU_BOX_*` 前缀）：

| 键 | 默认值 | 说明 |
|---|---|---|
| `NEU_BOX_WORKER_URL` | `http://127.0.0.1:59075` | Worker 地址，hook 往这里登记 |
| `NEU_BOX_HOOK` | `/usr/local/bin/neu-box-hook` | 注入进 config.json 的 hook 路径 |
| `NEU_BOX_HOOK_PHASE` | `createRuntime` | 注入到哪个 OCI hook 阶段（`prestart` 可切回，见「phase 验证记录」） |
| `NEU_BOX_REAL_RUNC` | `/usr/local/bin/runc` | wrapper 后面真正接的 runtime |

环境变量优先于文件（和 worker 的 `load_dotenv(override=False)` 一致），
`NEU_BOX_CONFIG=<path>` 可以把两个二进制指到另一个配置文件。

配置文件是主要通道，不是可有可无的备选：hook 是 runc 拉起来的，继承的是
**dockerd 的环境**，`docker run -e` 传不进去。

配置读不动（文件缺失、语法错）不致命：用默认值接着干活，问题打一行 stderr。
在容器创建路径上因为配置文件打不开就拒绝启动，代价比配错了还大。

## 构建

```bash
CGO_ENABLED=0 go build -trimpath -ldflags '-s -w' -o dist/neu-box-runtime ./cmd/neu-runtime
CGO_ENABLED=0 go build -trimpath -ldflags '-s -w' -o dist/neu-box-hook    ./cmd/neu-hook
```

标准库够用，没有第三方依赖；产物是静态二进制。

## 测试

```bash
go test ./...     # 不需要 root、不需要 Docker、不需要 runc
go vet ./...
gofmt -l .
```

测试怎么做到不碰真东西：

- **wrapper**：临时 bundle + 临时 config.json；端到端那条用假 runc（一个 shell
  脚本，把收到的 argv 写进文件），验证 `syscall.Exec` 之后真 runc 拿到的 argv
  逐字不变；`TestMain` 里有个子进程模式，让测试二进制把自己当成
  `neu-box-runtime` 重新拉起来（`run()` 最后会 exec 换掉自己，没法在测试进程里
  直接调）。
- **hook**：`httptest` 冒充 Worker，断言请求 body 只有契约里那三个必填字段、
  2xx 退 0、4xx 和连不上退非零。
- **配置**：临时 env 文件 + `t.Setenv`，不读这台机器上的真配置。

## phase 验证记录（别把"验过"的范围说过头）

内容抄自契约 `docs/runtime-hook.md`「neu-box-hook」一节，改这里之前先改那边。

- **`createRuntime`（当前默认）**：**直连 runc 验过**（`runc run -b`，不经过
  dockerd）—— hook 被调用、读得到容器 mnt ns（`mnt:[4026549739]` ≠ hook 自己的
  `mnt:[4026531841]`）和容器 cgroup scope 及其 inode、hook 退非 0 时 payload 不
  执行。phase 是 runc 自己的行为，Docker/containerd 只负责挑 runtime 二进制，
  所以这一层验过就够。选它当默认还因为 `prestart` 在 OCI 规范里已废弃，迟早会被
  runc 摘掉。
- **`prestart`**：**整条 Docker 链路验过** —— Docker 28.5.2 → containerd 1.7.28 →
  runc 1.3.3，探针实测 hook 里能读到容器 host PID、容器 mnt ns、
  `/system.slice/docker-<id>.scope` 及其 inode；hook 退非 0 时容器创建失败、
  payload 不执行。
- **两个 phase 都没验过的**：**整条 Docker 链路上跑 `createRuntime`**。真机装机时
  第一次跑就是它，出问题就把 `NEU_BOX_HOOK_PHASE` 切回 `prestart` —— 这就是这个
  开关留着的原因，也是 `prestart` 不能删的原因。

> **顺带一条实测教训**：两次跑出来的容器 `mnt ns inum` 是同一个数
> （`mnt:[4026549739]`）—— 第一个容器退出后内核把 inum 回收给了第二个。
> **光有 inum 分不清"同一个容器"和"回收后重用的号"**，所以 Worker 侧的
> `ContainerIdentity` 必须带 `init_start_time`（`/proc/<pid>/stat` 第 22 字段）。
> 这条是 Worker 的活，写在这里是因为"hook 报什么"和"Worker 怎么认"是同一件事的
> 两头。

## 边界

- **`neu-box` 是默认 runtime**，所以 wrapper 在这台机器**所有**容器的启动路径上。
  它对看不懂的输入（别的子命令、没 `--bundle`、config.json 读不了、JSON 坏了、
  没有 annotation）一律**原样转发**，绝不因为自己的问题挡住无关容器；只有
  "已经确认是沙盒容器（annotation 就在 config.json 里）但注入没做成"才拒绝启动。
  日志只写 stderr，不碰 stdout。
- **注入的 phase 默认 `createRuntime`**，`prestart` 可以切回去。**别把 `prestart`
  当遗留垃圾删掉** —— 它是退路，理由见上面「phase 验证记录」。
- **注入 `create` 和 `run`**（契约规定）。containerd 只用 `create`；`run`
  （= create + start）是给本机直接 `runc run` 验证用的，行为和走 Docker 一致。
  其余子命令逐字转发。`--bundle` 除契约里的 `--bundle DIR` / `--bundle=DIR`
  两种写法外，也认 runc 自己的短别名 `-b DIR` —— 否则"本机用 `runc run` 验证"
  这条路的现成写法（`runc run -b <bundle>`）走不通，`-b` 在 runc 里也只出现在
  create/run 上，不会认错。
- **hook 只发契约里的三个必填字段**。`container_cgroup` / `mount_namespace` 是
  可选的"hook 观察值"，Worker 会拿它和自己从 `/proc/<pid>` 读到的真值做交叉验证、
  不一致就 409 —— 报错了会把登记搞失败，而这两个值 Worker 本来就要自己读一遍，
  从同一个 `/proc` 再读一遍不提供额外信息，所以不发。
- **超时预算**：hook 自身 10s（wrapper 写进 OCI hook 记录的 `timeout`），其中
  Worker HTTP 请求 8s。HTTP 必须严格小于 hook 的 timeout，否则 runc 杀 hook 时
  连错误都拿不到。
- 鉴权、孤儿登记回收、Kubernetes、与 Ascend Docker Runtime 串接都不在本次范围
  （见契约「这轮明确不做」）。
