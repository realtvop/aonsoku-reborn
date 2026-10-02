# 在线部署与自动更新

整个流程在 GitHub 和 Cloudflare 网页中完成，无需 clone、本地 Node.js 或终端。
构建命令只是复制到 Cloudflare 表单，服务器会代为执行。

## 首次部署

1. [在 GitHub 创建 fork](https://github.com/realtvop/aonsoku-reborn/fork)，保留
   `main` 分支。使用真正的 fork，以便同步上游；不要创建没有 fork 关系的代码副本。
2. 打开 [Cloudflare 控制台](https://dash.cloudflare.com/)，在 Workers & Pages 中
   创建 Worker，选择导入 Git 仓库，授权并选择你的 fork。选择生产分支 `main`，
   Worker 名称使用 `aonsoku-coordination`，与代码中的配置一致。
3. 填写构建配置：

   | 字段 | 值 |
   | --- | --- |
   | Root directory | 仓库根目录 `/`（根目录的 `wrangler.jsonc` 是在线部署入口） |
   | Build command | `pnpm --config.node-linker=isolated install --filter @aonsoku/coordination-worker --frozen-lockfile --ignore-scripts && pnpm --filter @aonsoku/coordination-worker check` |
   | Deploy command | `npx wrangler deploy` |
   | Build variable `SKIP_DEPENDENCY_INSTALL` | `1` |
   | Build variable `NODE_VERSION` | `22` |
   | Build variable `PNPM_VERSION` | `10` |

   使用整个仓库，因为 Worker 引用了 `src/coordination/types.ts`。根目录
   `wrangler.jsonc` 会指向 `coordination-worker/src/index.ts`，并声明 Durable Object
   绑定和 SQLite migration。只安装 Worker
   依赖（覆盖仓库的 hoisted 链接设置），跳过 Electron/Cypress 等安装脚本。
   不要使用交互式的 `coordination:deploy`。
   这些环境变量填在 **Build Variables and Secrets** 中。

   仓库根目录的 `.env.example` 是主 Web 应用的 Docker/静态站点模板，
   不属于 Worker 配置。已有的 Cloudflare 设置页可能仍显示它解析出的旧字段；
   关闭旧流程并从最新提交重新开始，才能读取根目录 `wrangler.jsonc`。
4. 首次部署完成后，在该 Worker 的 **Settings → Variables and Secrets**
   中添加以下运行时配置，然后保存并部署：

   | 名称 | 类型 | 值 |
   | --- | --- | --- |
   | `ALLOWED_IDENTITY_ORIGINS` | Text | 你信任的 Navidrome/Subsonic HTTPS origin，例如 `https://music.example.com`；多个用逗号分隔 |
   | `ENABLE_OFFLINE_HANDOFF` | Boolean | 是否允许从离线设备接管播放，默认 `true` |
   | `MAX_DEVICES` | Number | 每个账号最多注册设备数，范围 1–1000，默认 `100` |
   | `STABLE_KEY` | Secret | 用密码管理器生成并保存的至少 32 字符随机密钥 |

   **运行时配置和构建变量是两个不同的页面。** `ALLOWED_IDENTITY_ORIGINS` 是普通
   Text 变量，只有 `STABLE_KEY` 是 Secret；Secret 在 Cloudflare 中始终只显示
   名称而隐藏值，这是预期的安全行为。未配置时 `/readyz` 会报错，
   服务不接受注册；补齐后才能使用。地址只填 origin，不包含 Navidrome 的路径。
   `STABLE_KEY` 只设置一次，并保存在密码管理器中；后续更新不要更换。
   Wrangler 使用 `keep_vars` 保留网页设置的变量，部署不会覆盖已有密钥。
   Workers 由 Cloudflare 管理监听端口，部署不需要也不能设置 `PORT`；如果模板
   里出现 `PORT`，可以删除，它不会被本 Worker 读取。
5. 打开部署得到的 HTTPS URL 的 `/readyz`，确认返回成功。
   将该 URL 填入 Aonsoku 的协调服务设置。

SQLite Durable Object 由代码中的 migration 创建，不需要手动创建 D1/KV/R2。
如果需要自定义 Worker 名称，在 fork 网页编辑 `wrangler.jsonc` 的 `name`，并保持
Cloudflare 中的名称一致；这会成为 fork 中的自定义修改。

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
src/coordination/types.ts
pnpm-lock.yaml
pnpm-workspace.yaml
package.json
```

这样客户端其他改动不会引起协调服务重复部署。关闭非生产分支自动构建，
或为预览配置独立 Worker/存储，避免预览命令部署到正式服务。

GitHub 的定时任务可能延迟；公共仓库 60 天无活动时定时工作流会被停用，
届时需在 Actions 网页重新启用。此流程跟随上游默认分支，每天检查一次，
不是实时更新或永远无需维护的保证。可随时在网页关闭自动同步或自动部署。

## 为什么没有子目录一键部署按钮

Cloudflare 的 Deploy to Cloudflare 按钮会把指定子目录当作新仓库根目录。
当前 Worker 使用目录外的共享协议类型，直接提供子目录按钮会造成构建失败；
按钮创建的代码副本也不能直接使用 fork 同步 API。因此这里采用 GitHub fork
和 Cloudflare 原生 Git 集成，保留整个仓库及自动更新关系。

依据：[Workers Builds](https://developers.cloudflare.com/workers/ci-cd/builds/)、
[构建配置](https://developers.cloudflare.com/workers/ci-cd/builds/configuration/)、
[构建环境](https://developers.cloudflare.com/workers/ci-cd/builds/build-image/)、
[一键部署的 monorepo 限制](https://developers.cloudflare.com/workers/platform/deploy-buttons/#limitations)、
[GitHub 同步 API](https://docs.github.com/en/rest/branches/branches#sync-a-fork-branch-with-the-upstream-repository)、
[GitHub 定时工作流限制](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule)。
