# app-source — AI-Shikikan 软件源

本仓库只做一件事：消费主仓库 `AI-Shikikan` 的发布资产（Linux `dotnet` 变体归档 + `index.json`），
按索引拆出三个模块系统包，生成 apt / rpm / pacman 元数据，并发布到 `gh-pages` 分支。

## 模块包与依赖链

安装 `ai-shikikan-gui` 会级联安装 `ai-shikikan-core` 与 `ai-shikikan-worker`：

```
ai-shikikan-gui  →  ai-shikikan-core  →  ai-shikikan-worker
```

| 包 | 内容 | 安装路径 |
|---|---|---|
| `ai-shikikan-worker` | Worker 可执行树 | `/usr/lib/ai-shikikan/worker/` |
| `ai-shikikan-core` | `AIShikikan.Core.dll` | `/usr/lib/ai-shikikan/` |
| `ai-shikikan-gui` | GUI 主体 + 桌面入口 + 图标 | `/usr/lib/ai-shikikan/`、`/usr/bin/ai-shikikan` |

> 只用 `dotnet` 变体：AOT / selfcontained 会把 Core 静态链接进可执行文件，无法拆出独立的 Core.dll。

## 触发方式

1. 主仓库 Release 完成后通过 `repository_dispatch`（`event_type: release`）自动触发；
2. Actions 页面手动 `workflow_dispatch`，可填版本号（留空自动取主仓库最新 Release）。

## 仓库配置

主仓库地址与触发目标都已写死，无需仓库变量：

| 位置 | 写死值 | 说明 |
|---|---|---|
| 本仓库 `.github/workflows/build-source.yml` | `MAIN_REPO: BlockHaity/AI-Shikikan` | 消费的主仓库 |
| 主仓库 `.github/workflows/release.yml` | `SOURCE_REPOSITORY: BlockHaity/AI-Shikikan-Source` | 发布后触发的软件源仓库 |

更换仓库时改对应文件中的这一行即可。

工作流拆分为：`source.yml` 只做触发入口（`repository_dispatch` / `workflow_dispatch`），通过 `workflow_call` 调用 `build-source.yml` 执行实际构建；两者均声明 `contents: write` 权限，`build-source.yml` 也可被本仓库其他工作流复用。

### 配置步骤

1. 把本目录推送到公开仓库 `BlockHaity/AI-Shikikan-Source`（本地 Gitea 远端为 `http://192.168.1.5:3000/develop/AI-Shikikan-Source.git`）。
2. 本仓库 Settings → Pages → Source 选择 `gh-pages` 分支。
3. 主仓库 Settings → Secrets and variables → Actions 新建 Secret：
   - `SOURCE_REPO_TOKEN`：有本仓库 `contents: write` 权限的 Personal Access Token（Fine-grained 或 classic `public_repo` 均可）。
4. 两个仓库都是公开仓库，读取 Release 资产无需任何令牌。

> 跨仓库 `repository_dispatch` 是写操作，`GITHUB_TOKEN` 只作用于当前仓库，即使目标仓库公开也必须用 PAT。未配置时主仓库发布仍会成功，只跳过自动触发；可在本仓库 Actions 页面手动 Run workflow 填版本号重建。

## 本地构建

```bash
# 1) 下载主仓库对应版本的 Linux 归档与索引到 downloads/
# 2) 解压某一个 RID 的归档
mkdir -p app/linux-x64 && tar xzf downloads/AIShikikan-*-linux-x64-dotnet.tar.gz -C app/linux-x64

# 3) 拆分模块包
VERSION=1.0.0-vibe INDEX=downloads/index.json APP_DIR=app/linux-x64 \
  RID=linux-x64 OUT_DIR=dist ./scripts/package-modules.sh

# 4) 生成软件源元数据（需要 dpkg-dev / createrepo-c / docker）
DIST=dist PUBLIC=public PAGES_URL=https://example.github.io/app-source \
  ./scripts/build-repo.sh
```

## 软件源地址

```
apt:    deb [trusted=yes] https://<owner>.github.io/<repo>/ stable main
rpm:    https://<owner>.github.io/<repo>/rpm/$basearch
pacman: Server = https://<owner>.github.io/<repo>/pacman/$arch
```

> 仓库未做 GPG 签名，apt 客户端需加 `[trusted=yes]`，rpm/pacman 已关闭校验。
