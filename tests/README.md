# 测试入口与索引

正式基线为 Windows PowerShell 5.1、Pester 3.4.0。在仓库根目录运行单个套件或整个测试目录：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run_suite.ps1 -SuiteFile tests/MusicServer.Core.Tests.ps1 -LogFile artifacts/core-tests.log
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run_suite.ps1 -SuiteFile tests -LogFile artifacts/all-tests.log
```

入口固定加载 Pester 3.4.0，不自动安装依赖；默认排除 `RequiresLocalRuntime`。日志使用 UTF-8 BOM，包含计数、失败用例的 Describe/Context/Name、FailureMessage 和 StackTrace。退出码：`0` 为测试通过，`1` 为测试失败，`2` 为入口异常（包括依赖缺失、路径不存在或筛选后没有测试）。日志目录自动创建；日志写入失败时错误仍输出到 stderr。

需要验证真实本机数据时，在 Windows PowerShell 中明确指定：

```powershell
Import-Module Pester -RequiredVersion 3.4.0 -Force
Invoke-Pester -Path tests -Tag RequiresLocalRuntime -PassThru
```

| CI 分组 | 正式套件 `MusicServer.*.Tests.ps1` |
| --- | --- |
| state | Core、Database、V2、WorkerConcurrency、Recommendation、LegacyRetirement、Listening、Web、Tauri、ConfigurableLibrary、TestRunner |
| api | Http、UiProxyRuntime、MediaRuntime、ApiTransaction、ApiRuntime |

- `TestRunner` 在临时目录生成成功、故意失败、空套件及不存在路径，通过独立 `powershell.exe` 验证日志和退出码；故意失败的夹具不会被全量测试直接发现。
- `Web` 调用 `web-ui.behavior.test.cjs` 验证前端行为。
- `RuntimeFixture`、`WorkerChild`、`HttpRacer` 是测试辅助脚本。
- `verify_tauri_desktop.ps1` 用于真实 Tauri APP smoke；`worker_smoke.ps1` 是独立 worker smoke 工具。
- `desktop-build` 另行执行 Rust、NSIS 与脱离源码的安装验证。Pester 通过不能替代这个门禁或实际 APP 交互验收。

测试与测量日志存入忽略目录 `artifacts/`，不提交运行数据。
