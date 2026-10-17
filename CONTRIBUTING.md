# 参与贡献

这是一个纯 PowerShell 5.1 脚本项目，没有依赖、没有构建工具链，改起来门槛很低。动手前先看一遍 `docs/MAINTAINING.md`，那里写了模块划分、内部函数职责和扩展点。

## 提交前请自检

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\work\build.ps1
```

构建脚本会做三件事：把 `work\src\` 下的 4 个源文件按顺序拼成单文件、做语法解析自检（语法不过直接报错，不出包）、写出 `outputs\` 里的产物。构建通过再提 PR。

如果改的是 `work\build.ps1` 本身，先给它补 BOM 再跑：

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\work\addbom.ps1 work\build.ps1
```

## 编码规则

1. 会被 `powershell.exe` 直接执行的脚本必须有 UTF-8 BOM。没有 BOM 时 PowerShell 5.1 按本地代码页（中文系统是 GBK）解码，中文会变乱码，甚至吞掉后面一个字符，最后变成莫名其妙的语法错误。
2. `.bat` 一律保持纯 ASCII 内容，不要出现中文。需要引用中文文件名时用通配符，例如 `for %%f in (Optimize-*.ps1)`。
3. 面向使用者的中文文案改了，记得同步改 `work\assets\使用说明.txt`，否则压缩包里的说明书会和程序实际行为对不上。

## 代码风格

- 函数名用 `Verb-Noun` 形式，参数尽量带类型
- 面向使用者的输出集中在已有的输出工具函数里，不要到处 `Write-Host` 拼格式
- 新增改动项要在 `$script:TweakCatalog` 里登记，并保证能回滚（应用时记录原值和类型）
- 只读原则：采集和记录阶段不允许写任何系统设置

## PowerShell 5.1 的坑

- `@($someGenericList)` 在 5.1 上会抛 `Argument types do not match`，改用 `[object[]]$list` 或 `.ToArray()`
- `Sort-Object -Property @{...}, @{...}` 这种多属性计算写法在 5.1 上不支持，拆成两步排
- 格式化字符串里的花括号要转义
- 不要用 7.0 以上才有的语法（`??`、`?.`、三元 `? :`）

## 提 Issue 时

附上这些信息能少来回好几轮：Windows 版本、CPU 与显卡型号、用的是体检还是记录模式、报告里标了「未能确认」的条目，以及 `优化与方案` 或 `性能记录` 文件夹里的报告。报告里可能有用户名、磁盘序列号之类的内容，发之前自己先删一下。

## 不要做的事

- 不要加入超频、破解、外挂、内存注入，以及关闭安全防护（Defender、防火墙、内核隔离）相关的改动项
- 不要引入需要联网或需要安装的依赖