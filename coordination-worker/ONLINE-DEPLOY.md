# 在线部署与自动更新

整个流程在 GitHub 和 Cloudflare 网页中完成，无需 clone、本地 Node.js 或终端。
构建命令只是复制到 Cloudflare 表单，服务器会代为执行。

## 一键部署（无需 clone）

点击 README 中的 **Deploy to Cloudflare** 按钮。按钮指向自动生成的
`coordination-worker` 分支，Cloudflare 会把这个分支当成独立仓库根目录；主应用根目录的
`.env.example`、`PORT`、`SERVER_URL`、`APP_USER` 等字段不会进入这个设置页面。
分支包含自己的 Wrangler 配置、依赖清单、协议类型和 `.dev.vars.example`，所以不需要
本地 Node.js 或终端。Cloudflare 会创建自己的 Git 仓库并在该仓库的生产分支更新时重新部署。

首次表单只需要填写 Worker 运行时配置；`ENABLE_OFFLINE_HANDOFF` 已在 Wrangler 配置中预设为
`true`，因此不会作为额外输入项出现。部署后仍可在 Cloudflare 的 Variables and Secrets
中改成 `false`：

| 名称 | 类型 | 值 |
| --- | --- | --- |
| `ALLOWED_IDENTITY_ORIGINS` | Text | 你信任的 Navidrome/Subsonic HTTPS origin，多个用逗号分隔 |
| `ENABLE_OFFLINE_HANDOFF` | Boolean | 是否允许离线设备接管播放，默认 `true`，首次部署已预设 |
| `MAX_DEVICES` | Number | 每个账号最多注册设备数，范围 1–1000，默认 `100` |
| `STABLE_KEY` | Secret | 至少 32 字符的随机密钥 |

`PORT` 由 Workers 管理，不能配置；如果页面出现它，说明打开的是旧的根目录部署链接。

## GitHub fork 自动跟随上游

1. [在 GitHub 创建 fork](https://github.com/realtvop/aonsoku-reborn/fork)，保留
   `main` 分支。使用真正的 fork，以便同步上游；不要创建没有 fork 关系的代码副本。
2. 打开 [Cloudflare 控制台](https://dash.cloudflare.com/)，在 Workers & Pages 中
   创建 Worker，选择导入 Git 仓库，授权并选择你的 fork。选择生产分支 `main`，
   Worker 名称使用 `aonsoku-coordination`，与代码中的配置一致。
3. 填写构建配置：

   | 字段 | 值 |
   | --- | --- |
   | Root directory | 仓库根目录 `/` |
   | Build command | `pnpm --filter @aonsoku/coordination-worker run build:ci` |
   | Deploy command | `pnpm --filter @aonsoku/coordination-worker run deploy:ci` |
   | Build variable `NODE_VERSION` | `22` |
   | Build variable `PNPM_VERSION` | `10` |

   使用整个仓库是为了让 fork 的上游同步工作流保持可用。Cloudflare 自动安装 pnpm
   workspace 依赖，上面的命令只构建和部署 Worker。两个 CI 命令使用
   `coordination-worker/wrangler.ci.jsonc`，其中声明 Durable Object 绑定和 SQLite
   migration，但不声明运行时变量，避免覆盖网页设置。
   不要使用交互式的 `coordination:deploy`。
   这些环境变量填在 **Build Variables and Secrets** 中。

   仓库根目录的 `.env.example` 是主 Web 应用的 Docker/静态站点模板，
   不属于 Worker 配置。它不会影响上面的独立分支一键部署；如果 fork/Workers Builds
   表单显示 `PORT` 等字段，请在仓库根目录部署中手动删除这些无关变量。
4. 首次部署完成后，在该 Worker 的 **Settings → Variables and Secrets**
   中添加以下运行时配置，然后保存并部署：

   | 名称 | 类型 | 值 |
   | --- | --- | --- |
   | `ALLOWED_IDENTITY_ORIGINS` | Text | 你信任的 Navidrome/Subsonic HTTPS origin，例如 `https://music.example.com`；多个用逗号分隔 |
   | `ENABLE_OFFLINE_HANDOFF` | JSON | 填 `true` 或 `false`，是否允许从离线设备接管播放；省略时默认 `true` |
   | `MAX_DEVICES` | JSON | 填数字，例如 `100`；每个账号最多注册设备数，范围 1–1000，省略时默认 `100` |
   | `STABLE_KEY` | Secret | 用密码管理器生成并保存的至少 32 字符随机密钥 |

   **运行时配置和构建变量是两个不同的页面。** `ALLOWED_IDENTITY_ORIGINS` 是普通
   Text 变量，只有 `STABLE_KEY` 是 Secret；Secret 在 Cloudflare 中始终只显示
   名称而隐藏值，这是预期的安全行为。未配置时 `/readyz` 会报错，
   服务不接受注册；补齐后才能使用。地址只填 origin，不包含 Navidrome 的路径。
   `STABLE_KEY` 只设置一次，并保存在密码管理器中；后续更新不要更换。
   `deploy:ci` 使用不含 `vars` 的 CI 配置和 `keep_vars` 保留网页设置，部署不会覆盖
   已有密钥。不要改用 `deploy` 或根目录的 `npx wrangler deploy`：普通配置中的
   默认值会覆盖同名网页变量，即使设置了 `keep_vars`。
   Workers 由 Cloudflare 管理监听端口，部署不需要也不能设置 `PORT`；如果模板
   里出现 `PORT`，可以删除，它不会被本 Worker 读取。
5. 打开部署得到的 HTTPS URL 的 `/readyz`，确认返回成功。
   将该 URL 填入 Aonsoku 的协调服务设置。

SQLite Durable Object 由代码中的 migration 创建，不需要手动创建 D1/KV/R2。
如果需要自定义 Worker 名称，在 fork 网页编辑 `coordination-worker/wrangler.ci.jsonc`
的 `name`，并保持 Cloudflare 中的名称一致；这会成为 fork 中的自定义修改。

## 自动跟随上游

Cloudflare Workers Builds 会在你的 fork 的生产分支有更新时构建并部署。
要让 fork 自动跟随本项目，在 GitHub 网页做一次设置：

1. 在 fork 的 **Actions** 页面允许运行工作流。
2. 在 **Settings → Secrets and variables → Actions → Variables** 新增
   `COORDINATION_AUTO_SYNC`，值为 `true`。这是普通变量，无需配置个人访问令牌。
3. 在 **Actions → coordination upstream sync** 启用该工作流，并通过
   **Run workflow** 手动运行一次，确认权限和同步正常。

此后工作流每天 UTC 04:23（台北时间 12:23）尝试通过 GitHub 的
`merge-upstream` API 同步上游默认分支，再由 Workers Builds 自动部署。
它只在主动开启的本项目直接 fork 中运行，使用 GitHub 自带 token，
不会强制推送或丢弃你的修改。合并冲突、权限限制等错误会让工作流失败，
需要在 GitHub 网页处理；配置留在 Cloudflare 中能减少代码冲突。
同步的是整个 fork，包含客户端代码；Cloudflare 只构建协调服务。

在 Cloudflare 的 **Settings → Builds → Build watch paths** 中可以限定包含路径：

```text
coordination-worker/**
pnpm-lock.yaml
pnpm-workspace.yaml
package.json
```

这样客户端其他改动不会引起协调服务重复部署。关闭非生产分支自动构建，
或为预览配置独立 Worker/存储，避免预览命令部署到正式服务。

GitHub 的定时任务可能延迟；公共仓库 60 天无活动时定时工作流会被停用，
届时需在 Actions 网页重新启用。此流程跟随上游默认分支，每天检查一次，
不是实时更新或永远无需维护的保证。可随时在网页关闭自动同步或自动部署。

## 为什么按钮使用独立分支

Cloudflare 的 Deploy to Cloudflare 表单会扫描源仓库中的 `.env.example`。主应用必须保留
根目录模板，因此按钮使用由 `.github/workflows/coordination-worker-branch.yml` 从
`coordination-worker/` 自动生成的独立分支。这个分支根目录没有主应用模板，Worker 的协议
类型也已经自包含；主分支每次更新 Worker 目录后，分支会自动更新。按钮创建的副本仍与
原仓库分开管理；如果需要每天跟随上游，请使用上面的 GitHub fork + Workers Builds 流程。

依据：[Workers Builds](https://developers.cloudflare.com/workers/ci-cd/builds/)、
[构建配置](https://developers.cloudflare.com/workers/ci-cd/builds/configuration/)、
[构建环境](https://developers.cloudflare.com/workers/ci-cd/builds/build-image/)、
[一键部署的 monorepo 限制](https://developers.cloudflare.com/workers/platform/deploy-buttons/#limitations)、
[GitHub 同步 API](https://docs.github.com/en/rest/branches/branches#sync-a-fork-branch-with-the-upstream-repository)、
[GitHub 定时工作流限制](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule)。
