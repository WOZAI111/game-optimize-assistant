# 把它发布到 GitHub

这份文件写给仓库维护者。按顺序做完，就是一个可以公开分享的仓库。

## 一、发布前必须改的

1. 把 `LICENSE` 里的 `<YOUR NAME OR GITHUB USERNAME>` 换成你的名字或 GitHub 用户名。
2. 想好了仓库名就统一一下（下面示例用 `game-optimize-assistant`）。
3. 重新构建一次，确认产物正常：

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\work\build.ps1
```

## 二、第一次上传（三条路，选一条）

### 路线 A：GitHub Desktop（推荐，全程图形界面，会自动帮你装好 Git）

1. 打开 https://desktop.github.com 下载安装，用 GitHub 账号登录。
2. 菜单 File → Add local repository，选这个文件夹。提示 not a Git repository 时点 create a repository，名字填 `game-optimize-assistant`，Local path 保持当前文件夹，点 Create。
3. 左下角 Summary 填 `v0.1.0 初始版本`，点 Commit to main。
4. 顶部点 Publish repository，要公开就取消勾选 Keep this code private，点 Publish。
5. 仓库地址会是 `https://github.com/<你的用户名>/game-optimize-assistant`。

### 路线 B：命令行（已经装了 Git for Windows）

```
cd <这个文件夹>
git init -b main
git add .
git status
git -c user.name="<你的名字>" -c user.email="<你的邮箱>" commit -m "v0.1.0 初始版本"
git remote add origin https://github.com/<你的用户名>/game-optimize-assistant.git
git push -u origin main
```

`git status` 那步要确认 `outputs\` 和 `work\test*` 这些临时目录没有被加进来（`.gitignore` 已经挡住了）。首次 push 会弹浏览器授权，按提示走一次就行。

### 路线 C：网页上传（什么都不想装）

1. 在 GitHub 点 New repository，名字填 `game-optimize-assistant`，选 Public，创建。
2. 在空仓库页面点 uploading an existing file。
3. 把 `.gitignore`、`LICENSE`、`README.md`、`CONTRIBUTING.md`、`CHANGELOG.md`、`docs`、`work`、`.github` 一起拖进去，`outputs` 不要拖。
4. Commit message 填 `v0.1.0 初始版本`，点 Commit changes。

这条路最省事，缺点是改文件只能一个个传。

## 三、发一个 Release（让别人有压缩包可下）

构建出来的 `outputs\` 不进仓库，压缩包走 Release 附件：

1. 仓库右侧 Releases → Create a new release。
2. Tag 填 `v0.1.0`，Target 选 main。
3. Title 填 `v0.1.0 初始版本`，描述可以直接抄 `CHANGELOG.md`。
4. 把 `outputs\游戏优化助手.zip` 拖进 Attach binaries 区域。
5. Publish release。

`.github\workflows\release.yml` 做的是同一件事：打了 `v` 开头的 tag 后，Actions 会在 Windows 机器上自动构建、建 Release、把 zip 附上去。两种方式选一种，别重复操作。

## 四、发布后核对

- Releases 页面能下到 zip，解开后里面有 7 个文件（2 个 ps1、4 个 bat、1 个 txt）
- README 在网页上中文正常、表格和代码块正常
- 用了 workflow 的话，Actions 页面最近一次运行是绿色
- 记一下这次 zip 的 SHA256 写进 Release 描述，方便别人校验：

```
Get-FileHash .\outputs\游戏优化助手.zip -Algorithm SHA256
```