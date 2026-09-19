# Codex Nerf Detector

> **Detect when Codex silently serves your request with a weaker model than the one you picked.**
>
> **检测你的 Codex 请求有没有被悄悄换成更弱的模型。**

Windows / macOS · 免安装 · 一个双击 · 一份回执

---

## 目录 / Table of Contents

- [文件说明](#文件说明--files)
- [这是什么（中文）](#这是什么中文)
- [为什么会有这个东西](#为什么会有这个东西)
- [它检测什么](#它检测什么)
- [实际输出](#实际输出)
- [工作原理](#工作原理)
- [判定标准](#判定标准)
- [环境要求](#环境要求)
- [使用方法](#使用方法)
- [换账号对比](#换账号对比)
- [你自己怎么复现](#你自己怎么复现)
- [常见问题](#常见问题)
- [隐私说明](#隐私说明)
- [已知限制](#已知限制)
- [背景与证据](#背景与证据)
- [给 OpenAI 员工的信](#给-openai-员工的信)
- [相关项目](#相关项目)
- [English Documentation](#english-documentation)

---

## 文件说明 / Files

| 文件 | 平台 | 说明 |
|---|---|---|
| `nerf-check.sh` | 全部 | **本体**。检测逻辑全在这里，两个启动器都只是调用它 |
| `nerf-check-windows.bat` | Windows | 双击入口。负责找到 Git Bash，再运行本体 |
| `nerf-check-macos.command` | macOS | 双击入口。用系统自带 bash 运行本体 |
| `README.md` | — | 本文档 |
| `LICENSE` | — | 许可证 |
| `check-records.txt` | — | 运行后生成。检测记录。**含你的账号邮箱，已在 `.gitignore` 里，不要提交** |
| `bash-path.txt` | Windows | 可选。Git Bash 装在非常规位置时，在这里写一行 `bash.exe` 的完整路径 |

**文件名一律用英文。** 中文文件名在不同系统、不同压缩工具、不同代码页下会出现乱码或找不到文件的问题——而「永远只在英文 Windows 上、只用一种解压工具」不是能指望的前提。

两个启动器做的事都很薄：找到正确的 bash、确保本体在旁边、把它跑起来。**所有逻辑都在 `nerf-check.sh`**，所以三端的检测结果完全一致。

---

## 这是什么（中文）

`Codex Nerf Detector` 是一个 Windows / macOS 上的小工具，用来回答一个很具体的问题：

> **我选了 gpt-6-astra，OpenAI 到底是用哪个模型回我的？**

它做的事情只有一件：把**请求体里写的模型**和**响应体里回来的模型**并排打出来给你看。

只有两行。但它俩经常对不上。

---

## 为什么会有这个东西

事情的起点很普通：有人发现自己付费的 Codex 账号，回答问题的方式变了——变得敷衍、变得浅、变得不像它。

一开始以为是：
- 网络问题
- 推理强度没设对
- 上下文太长了
- 账号用太久被限流了

于是换 IP、改推理强度、清缓存、换时区、重装客户端、清理会话历史……

**全都试过了，全都没用。**

最后是靠读自己的请求日志找到答案的：

```
请求体里写着   : gpt-6-astra
响应体里回来的是: gpt-5.6-luna
```

不是配置问题，不是网络问题，不是账号问题。

**是你花钱买的那个模型，根本没有参与这次对话。**

这个工具就是那个晚上读日志的过程，被打包成了一个双击就能跑的东西。

---

## 实测结果：原因写在服务端自己的额度字段里

工具的「判断依据」里会列出这几行 —— 它们来自服务端自己发的数据，不是推断。旧版 Codex 把它们放在 HTTP **响应头**里，现在会放在一条 websocket 消息（`codex.rate_limits`）里，**工具两种都读**：

```
x-codex-plan-type                     = pro       账号等级
x-codex-credits-balance               = 0         付费额度余额
x-codex-credits-has-credits           = False     付费额度用完了
x-codex-active-limit                  = premium   当前限制档
x-codex-primary-reset-after-seconds   = 582255    还有 ≈6.7 天重置
```

**这解释了「为什么只有旗舰被降级」：**

| 模型 | 付费额度 | 结果 |
|---|---|---|
| `gpt-6-astra`（吃 premium 额度） | **0** | ✗ **被换成 luna** |
| `gpt-5.6-terra`（不吃） | **0** | ✅ **照常服务** |

**同一个账号、同样的零额度 —— 便宜的正常，旗舰被换。** 缺口正好落在需要那份额度的那一档上。

而那 `582255` 秒 ≈ **6.7 天**，正好对上社区一直在说的 **「7 天算力预算窗口」**。

**这也解释了之前所有的无效尝试**：换 IP、改推理强度、换时区、清缓存 —— 都不是原因，所以全都没用。

---

## 实测结果：降级是「挑模型」的

在一次完整扫描里（同一个账号、同一天、同一台机器），工具逐个测了目录里的每一个模型：

| 模型 | 你请求的 | 实际用的 | 判定 |
|---|---|---|---|
| **`gpt-6-astra`**（最贵旗舰） | gpt-6-astra | **gpt-5.6-luna** | **✗ 被降级** |
| `gpt-5.6-sol` | gpt-5.6-sol | gpt-5.6-sol | ✓ 正常 |
| `gpt-5.6-terra` | gpt-5.6-terra | gpt-5.6-terra | ✓ 正常 |
| `gpt-5.6-luna` | gpt-5.6-luna | gpt-5.6-luna | ✓ 正常 |

**这不是"模型能力不够"，是专门针对最高那一档。**

同一个账号，便宜的模型照常给你，最贵的那个被换成了廉价的替代品——而且界面上的选择器、发票上的条目，都还写着原来那个名字。

**这个结论单次检测是看不出来的。** 只测一个模型，你只知道"我被换了"；把全部模型测一遍，你才知道**换的是哪一档**。

---

## 它检测什么

Codex 的每一次请求，都在同一个 HTTPS 交换里带上几份"自称"——下面两份每次都有：

**第一份，请求体——你想要什么：**

```json
POST https://chatgpt.com/backend-api/codex/responses
{"model":"gpt-6-astra","input":[...], ...}
```

**第二份，响应体——实际发生了什么：**

```json
{"id":"resp_0416d01e...","object":"response","status":"completed",
 "model":"gpt-5.6-luna","output":[...], ...}
```

同一个 HTTP 响应里，还出现过第三个自称（**不是每次都有**）：

```
x-codex-routing-hint: model=gpt-6-astra
```

**服务器告诉客户端"我路由到 Astra"，然后返回了一个自称 Luna 的响应体。**

这两句话出自同一次交换。总有一句是假的。

**⚠️ 这条头现在服务端不常发了。** 早先的抓取里有；近期多次抓取（包括确认被降级的那几次）里一次都没出现，而其它 `x-codex-*` 字段都还在。工具检测到就显示这一行，检测不到就跳过——**这不影响主判定**：「你要的模型有没有出现在响应里」靠的是响应体本身，不是这个头。

---

## 实际输出

```
==================================================
          Codex Nerf Detector
==================================================

  --- current session ---
  auth mode    : chatgpt
  account id   : a1b2c3d4...e5f6
  config model : gpt-5.6-terra
  models available : 5

  --- what do you want to do ---

    1) Quick check         - test one model
    2) Full sweep          - test every model (recommended)
    3) List models only    - no request, no quota used
    0) quit

  enter a number: 1

  --- choose the model to test --------------------

    1) GPT-6-Astra      gpt-6-astra
       Our most capable model for complex, demanding work.
    ...
    6) custom (type a model name)

    press Enter = use the config model: gpt-5.6-terra

  enter a number: 1

  Reasoning effort:
    1) config level only (high)
    2) every level - low medium high xhigh max ultra   (6 requests)

  enter a number: 1

  Sending a request through the current account...
  Please wait (reasoning takes 1-3 minutes; this spends real quota).

--------------------------------------------------
  account used     : your-account@example.com
  plan             : pro
  plan window      : left 99%   (10080 min)
  active limit     : premium
  credit balance   : 0   (has-credits=False)
  credits reset in : 579330s (~6d 16h)

  model                tier   effort   reasoning    served                     elapsed verdict
  --------------------------------------------------------------------------------------------------
  gpt-6-astra          L5     high     215 tok      gpt-5.6-luna              147s    DOWNGRADED
                              flagship   down 3 tier(s)
--------------------------------------------------

  models seen in the response
        gpt-5.6-luna         x3      <- downgrade target

================================================================================
  RESULT : DOWNGRADED
================================================================================

  how this was decided

    * the model you asked for : gpt-6-astra
    * response body says (what actually served) : gpt-5.6-luna
    * credit balance : 0   (has-credits=False)
    * credits reset in : 579330s (~6d 16h)
    * first token   : 137 ms
    * engine queue  : 61 ms
    * reasoning tokens   : 215

  Conclusion: the model you asked for took no part in this answer.
  the plan window still has room, but the credit balance is 0 - the flagship
  may draw only on credits, and that is what it is being kept out of

================================================================================

  appended to : .../check-records.txt
Press Enter to exit...
```

---

## 工作原理

工具本身不做什么魔法。它做四件事：

### 1. 找到 codex.exe

```
%LOCALAPPDATA%\OpenAI\Codex\bin\<哈希目录>\codex.exe
```

哈希目录会随版本更新变化，所以脚本每次都取**最新的那一个**。

### 2. 用 trace 级别日志跑一次探测请求

```bash
RUST_LOG=trace codex exec --skip-git-repo-check --model gpt-6-astra "Think step by step, then reply with only the answer: the smallest n where n mod 7 = 3, n mod 11 = 5 and n mod 13 = 9"
```

- `RUST_LOG=trace` 是**必须的**——不开的话抓不到响应体和服务端发的那些字段
- `--skip-git-repo-check` 也是必须的，否则会报"不在受信任目录"
- 请求内容是一道需要推理的题（见脚本里的 `PROBE_PROMPT`），会消耗**真实额度**。
  题目出得需要思考，是为了让「推理」这一列有数字可看——题目太简单的话它永远是 0

### 3. 从日志里分别提取两份模型名

**关键点在这里——一定要区分请求体和响应体：**

```bash
# 请求体：客户端发出去了什么
# ⚠️ 新版 Codex 不再把请求体写进日志，这条通常什么都搜不到。
#    搜不到时，工具就用你输入的模型名作为「你请求的模型」
grep -oE 'codex/responses: \{"model":"[^"]*"' 日志 | sed 's/.*"model":"//; s/"$//'

# 响应体：服务端回来了什么，以及每个模型出现了几次
# ⚠️ 必须先筛出 response 对象，否则日志别处的模型名会被一起搜进来
grep -oE '"object":"response"[^}]{0,600}' 日志 \
  | grep -oE '"model":"gpt-[0-9a-zA-Z.-]+"' \
  | sed 's/.*"model":"//; s/"$//' | sort | uniq -c | sort -rn
```

**`uniq -c` 这一步不能省。**「同一个响应里某个模型出现了几次」本身就是证据，`sort -u` 会把这个次数直接丢掉。

**先筛出 `response` 对象这一步也不能省**，否则日志里别处出现的模型名会被一并搜进来，得出错误结论。

这是这个工具唯一一个真正容易做错的地方。很多同类脚本栽在这里。

### 4. 对比、判定、记录

把两份模型名并排打出来，给出判定，追加到 `check-records.txt`。

---

## 判定标准

| 判定 | 颜色 | 含义 |
|---|---|---|
| **满血** | 绿 | 响应里只有你请求的那个模型 |
| **掺水** | 黄 | 你请求的模型有出现，**但也混了别的** —— 不稳定 |
| **降智** | 红 | 你请求的模型**完全没出现** |
| **未确定** | 无 | 没抓到响应内容（日志格式可能变了）|

判定在终端里用颜色标出——**红色就是被降智**。管道输出、重定向到文件、以及 `check-records.txt` 里都是纯文字，不带颜色码；想要彻底关掉颜色可以设 `NO_COLOR=1`。

**为什么「掺水」要单独一档？**

因为实测中确实出现过这种情况：

```
  响应里出现的模型
        gpt-5.6-luna         x2      ← 降级款
        gpt-5.6-sol          x3      ← 降级款
```

同一个请求里，两个模型都参与了。这既不是"正常"，也不是"完全被换掉"，所以单独标记。

---

## 环境要求

| 项目 | Windows | macOS |
|---|---|---|
| 双击入口 | `nerf-check-windows.bat` | `nerf-check-macos.command` |
| 必需 | **Codex 桌面版** 或 **Codex CLI**，已登录 | 同左 |
| 必需 | **Git for Windows**（提供 `bash.exe`） | 系统自带 bash，无需额外安装 |

**不需要** Python、Node、管理员权限、额外的运行时。

### macOS 用户注意

**⚠️ macOS 版尚未在真机上验证过。** 逻辑是同一套（检测部分完全一致），启动器和路径按官方文档写的，但**作者手上没有 Mac**。有问题请开 issue。

**首次运行会被 Gatekeeper 拦：**

```bash
# 去掉隔离标记
xattr -d com.apple.quarantine "nerf-check-macos.command"

# 如果提示"没有执行权限"
chmod +x nerf-check-macos.command nerf-check.sh
```

**或者**：右键 `nerf-check-macos.command` → 打开 → 再点"打开"。

**Codex 的查找位置**（按顺序）：

```
~/.local/bin/codex                              独立安装器默认位置
/opt/homebrew/bin/codex                         Homebrew (Apple Silicon)
/usr/local/bin/codex                            Homebrew (Intel) / 手动安装
/Applications/ChatGPT.app/Contents/Resources/codex   桌面版内置
/Applications/Codex.app/Contents/Resources/codex     桌面版内置（旧名）
```

**用户数据目录一样是 `~/.codex/`** —— Windows 和 macOS 相同。

---

## 使用方法

### 方式一：双击（推荐）

双击 `nerf-check-windows.bat`，然后按提示走：

```
1. 选语言             中文 / English
2. 回答两个问题        （答"是"到第一个会看到一封给 OpenAI 的信，按 Q 可直接退出）
3. 看账号信息          认证方式、账号 ID、配置的模型、目录里有几个模型

4. 选做什么：
     1) 单模型检测       —— 选一个模型
     2) 全模型一键检测   —— 逐个测完所有模型（推荐）
     3) 只看模型清单     —— 不发请求，不消耗额度

5. 选了单模型后，再选思考强度：
     1) 只测配置档       —— 1 次请求
     2) 全部档位         —— 该模型支持的每一档各测一次

   "全部档位"测的是**思考强度**（reasoning effort），不是题目难度：
   同一道题，分别在 low / medium / high / xhigh / max / ultra 下各跑一次，
   看推理 token 数怎么随档位变化。哪一档开始不再增长，就是被卡住的位置。

   **支持哪几档因模型而异**（如 `gpt-5.5` 只到 xhigh，`gpt-5.6-luna` 没有 ultra），
   所以档位清单是从 `models_cache.json` 里按模型读的，不是写死的。
   脚本通过 `codex exec -c model_reasoning_effort="<档位>"` 逐档覆盖，
   不改动你的 `config.toml`。
```

**模型清单是从 `~/.codex/models_cache.json` 读的**，不需要发请求就能看到目录里有哪些模型、各自是什么定位。

### 关于耗时

| 模式 | 请求数 | 耗时 |
|---|---|---|
| 只看清单 | 0 | 瞬间，**不消耗额度** |
| 单模型 × 1 档 | 1 | 约 2 分钟 |
| 单模型 × 全部档 | 4~6（按模型而定） | 约 8~15 分钟 |
| 全模型 × 1 次 | 5 | 约 10 分钟 |
| **全模型 × 3 次**（推荐） | 15 | 约 30 分钟 |
| 全模型 × 5 次 | 25 | 约 50 分钟 |
| 全模型 × 10 次 | 50 | 约 100 分钟 |

请求数按目录里现有的 **5 个模型**算。目录里多一个模型，请求数和时间就按比例往上加——**菜单里每一档都会实时标出它自己要发多少次请求、大概多久**，不用自己算。

**每个模型有 300 秒超时上限**，超了这一档会标成「超时」，然后继续下一个，不会卡死在那里。

### 为什么要重复测

**一次结果只能证明「发生过」，不能证明「每次都发生」。**

```
单次 astra→luna   →  说明它至少发生过一次 ✓
                     但可能是偶发、是网络抖动、是临时调度 ✗

3 次全中          →  稳定复现，这没法用偶发解释 ✓✓✓
```

工具会问你**每个模型测几次**（1 / 3 / 5），汇总表里会显示 `3/3 OK` 这样的比例。

**对 `gpt-6-astra` 这类你想拿来当证据的模型，建议至少 3 次。**

### 方式二：带参数

```
nerf-check-windows.bat gpt-6-astra
nerf-check-windows.bat gpt-5.6-sol
```

跳过菜单，直接测指定模型。适合批量测或者做快捷方式。

### 设置超时时间

```bash
PER_MODEL_TIMEOUT=90 bash nerf-check.sh
```

默认 300 秒，可以环境变量覆盖。

---

## 换账号对比

这个工具的一个主要用法是**横向对比不同账号**。

换账号登录之后，直接再双击一次。所有结果会累积到同目录的 `check-records.txt`：

```
2026-09-19 06:02 | account-a@example.com | asked=gpt-6-astra  | got=gpt-5.6-luna  | DOWNGRADED
2026-09-19 06:09 | account-a@example.com | asked=gpt-5.6-sol  | got=gpt-5.6-luna  | DOWNGRADED
2026-09-19 06:31 | account-b@example.com | asked=gpt-5.6-terra| got=gpt-5.6-terra | OK
2026-09-19 07:14 | account-b@example.com | asked=gpt-5.6-terra| got=gpt-5.6-terra | OK
```

**实测中值得一提的一个现象**：在一个付费账号上，请求 Astra 和 Sol 都被换成 Luna；而在同一天、同一台机器、同一条链路上，一个免费账号请求 Terra 得到的**就是 Terra**。

付费的那个被换了，免费的没有。

---

## 你自己怎么复现

这个工具没有做任何你看不到的事。你可以完全手动复现：

```bash
# 1. 找到 codex.exe（取最新那个哈希目录）
ls "$LOCALAPPDATA/OpenAI/Codex/bin"/*/codex.exe

# 2. 开 trace 跑一次探测请求
cd /tmp
RUST_LOG=trace "<codex.exe>" exec --skip-git-repo-check \
    --model gpt-6-astra "Think step by step, then reply with only the answer: the smallest n where n mod 7 = 3, n mod 11 = 5 and n mod 13 = 9" > /tmp/t.log 2>&1

# 3. 看请求体（新版 Codex 不再记录请求体，这条通常为空）
grep -oE 'codex/responses: \{"model":"[^"]*"' /tmp/t.log

# 4. 看响应体实际是什么、每个模型出现了几次（必须过滤 response 对象）
grep -oE '"object":"response"[^}]{0,600}' /tmp/t.log \
  | grep -oE '"model":"gpt-[0-9a-zA-Z.-]+"' | sort | uniq -c | sort -rn

# 5. 看服务端有没有给路由提示（有就抓，没有就跳过——现在通常没有）
grep -oE 'x-codex-routing-hint: *model=[0-9a-zA-Z.-]+' /tmp/t.log
```

**如果第 4 步里没有 `gpt-6-astra`，你就复现了** —— 你请求的是它，响应体里却一次都没出现。

---

## 常见问题

**Q: 提示 `request failed (exit code 1)`**

A: 九成是**这个账号没有你选的那个模型的权限**。

比如免费账号通常只有 `gpt-5.6-terra`，你选 `gpt-6-astra` 就会失败。这**不是**被降智，是没权限，属于正常现象。换一个它能用的模型再试。

**Q: 提示 `Git Bash not found`**

A: 先装 Git for Windows。如果已经装了但脚本找不到（比如装在非标准位置），在本文件夹里新建一个 `bash-path.txt`，里面写一行 `bash.exe` 的完整路径：

```
C:\Program Files\Git\bin\bash.exe
```

脚本会先读这个文件；如果里面的路径不存在，会**自动忽略**并继续找别的位置。

**Q: 提示 `codex.exe not found`**

A: 本机没装 Codex，或者从没登录过。先在 Codex 里登录，再跑这个工具。

**Q: 会不会消耗额度？**

A: 会，而且比以前多。探测请求现在是一道需要推理的题，模型会真的思考，消耗的是可观额度而非"极小额度"。题目出得需要思考，是为了让「推理」这一列有数字可看——题目太简单的话它永远是 0。题目可以用 `PROBE_PROMPT` 换成你自己的。

**Q: 开头的两个问题是什么？**

A:

- **第一个**问你是不是 OpenAI 的研究人员。如果答"是"，工具会先打印一封短信（可以直接按 `Q` 退出，不消耗额度），然后问你要不要继续。
- **第二个**问你的服务有没有被降级影响。**两个问题都不影响检测逻辑**，只是流程的一部分。

**Q: 为什么需要读 auth.json？**

A: 只读两个字段：`auth_mode`（登录方式）和 `account_id`（账号 ID 前 8 位 + 后 4 位，用于显示"当前是哪个号"）。**不读 token，不外传。**

**Q: 能检测 ChatGPT 网页版吗？**

A: 不能。目前只检测 Codex（桌面版 / CLI）的请求。网页版走的是另一套接口。

---

## 隐私说明

**这个工具只做本地读取，不外传任何东西。**

| 读什么 | 用途 |
|---|---|
| `~/.codex/auth.json` | 读 `auth_mode` 和 `account_id`，显示当前账号 |
| `~/.codex/config.toml` | 读你配置的默认模型，作为菜单的默认选项 |
| Codex 自己的运行日志 | 读请求体和响应体里的模型名 |

- **不读** `id_token` / `access_token` / `refresh_token`
- **不上传**账号、密码、对话内容、代码
- 除了一次正常的 Codex 请求之外，**不向任何地方发送数据**
- 结果只写在本文件夹的 `check-records.txt`

**⚠️ `check-records.txt` 里包含你的账号邮箱。** 它已经在 `.gitignore` 里，不要提交到任何仓库。

---

## 已知限制

**1. 只有 Windows 版**

检测逻辑本身是跨平台的，但启动器（`.bat`）是 Windows 的。macOS 用户可以看 [`kiyoakii/is-gpt-nerfed`](https://github.com/kiyoakii/is-gpt-nerfed)。

**2. 依赖 Codex 的日志格式**

如果 `POST .../codex/responses` 这一行，或者 `"object":"response"` 这个结构变了，工具会给出「未确定」判定。那时候需要更新正则。

**3. 曾经有更好的信号，现在没了**

以前可以直接读 `timing_metrics.engine_ids`，看到真正的引擎标识（比如 `gpt56lun-codex-...`）。**这个字段已经不返回了。**

现在这个工具能工作，唯一的依靠是**响应体里的 `model` 字段还在**。哪天这个也被清掉，就得换方法了。

**4. 模型路由是服务端行为**

**你在本机做的任何配置都不会改变它。** 换 IP、改推理强度、换时区、清缓存、重装客户端……实测全部无效。

这个工具**只负责报告，不负责修复**——因为从客户端这一侧，修不了。

**5. 每次运行消耗一次真实额度**

见上文。

---

## 背景与证据

### `openai/codex` issue #30364

社区用遥测数据统计出的推理 token 聚集现象：

- 采样范围：2026-02-01 ~ 2026-06-27，390,195 条响应级记录，865 个会话
- 发现推理在 **516 / 1034 / 1552 / 2070 / 2588 / 3106** 这些**精确数值**上终止
- 这是一条 **`518n-2`** 的阶梯
- **3,363 次精确-516 事件中，gpt-5.5 占 82.0%**——而它只占全部响应的 **19.3%**
- 在推理token ≥516 的响应里，gpt-5.5 撞 516 的比例是 **44.0%**，其他模型只有 **1.3%**
- 月度聚集率：2月 0.11% → 5月 53.30% → 6月 35.84%
- 同期**平均**和 **P90** 推理 token 反而在下降

**复现实验**：一个"糖果题"（正确答案 21）在 Codex CLI 0.142.5 + gpt-5.5 xhigh 上跑 4 次，**4 次全部在正好 516 token 处停止，答案全错**（23、26、28、15）。对照组换 gpt-5.4 xhigh，用了 6,211~12,274 token，**3 次全部答对**。

> **那些停顿不是模型想得快，是预算在关门。**

### 字段移除

社区报告：`timing_metrics.engine_ids` 在某天凌晨之后**不再返回**。检测脚本开始报 `UNKNOWN — no websocket timing engine ID was captured`。

**他们没有停止路由，他们停止了展示。**

### 相关但**不是**本工具检测的东西

`x-codex-safety-buffering-faster-model: gpt-5.6-luna`

这是**安全缓冲**路径用的"更快模型"，和"谁来写你的答案"无关。**社区已经澄清过，不要拿它当降级证据。** 本工具不测这一项。

---

## 给 OpenAI 员工的信

工具的流程里有一个问题：*"Are you a member of OpenAI's research staff?"*

如果回答"是"，会看到下面这封信（原文，英文）：

```
  Then this folder is addressed to you.

  This is not a bug report. It is a receipt.

  WHAT THE TOOL PRINTS
  --------------------------------------------------------------
  On a paying account:

        asked for : gpt-6-astra
        served    : gpt-5.6-luna

  Not once. Not a bad afternoon. Consistently - across prompts,
  across days, across accounts - while the picker kept advertising
  Astra and the invoice kept saying Astra.

  This header arrived in the very same HTTP response:

        x-codex-routing-hint: model=gpt-6-astra

  Your server told the client it was routing to Astra, and then sent
  a body signed by Luna. Both statements are yours. One is not true.

  That header is no longer present. Recent captures contain it zero
  times, including runs where the body still signed itself Luna. The
  only thing that changed is the record of it.

  YOU DELETED THE MIRROR, NOT THE BEHAVIOUR
  --------------------------------------------------------------
  Users used to be able to read timing_metrics.engine_ids and see
  which engine really served them. That field simply stopped coming.

  You did not stop routing. You stopped showing.

  THIS IS NOT A CAPACITY PROBLEM
  --------------------------------------------------------------
  Serving a cheaper model to survive a crunch is an engineering
  decision. Announce it. Reprice it. Let the picker tell the truth.

  What happened instead:

        price       unchanged
        picker      unchanged
        changelog   unchanged
        engine_ids  deleted

  That last line is the tell. A capacity decision does not require
  deleting the diagnostics. Only a concealment decision does.

  AND THE FAILURE IS NOT RANDOM
  --------------------------------------------------------------
  Telemetry for issue #30364 shows reasoning terminating at exactly
  516 / 1034 / 1552 / 2070 tokens - a 518n-2 staircase. gpt-5.5 was
  19% of responses and 82% of the exact-516 events.

  A control model given the same task used 6,000-12,000 reasoning
  tokens and answered correctly every time.

  Those stops are not a model thinking fast.
  They are a budget closing a door.

  NOW LET US TALK ABOUT THAT NAME
  --------------------------------------------------------------
  There is a word sitting in the middle of your company name.
  It is the word that people trusted.

  The founding argument was that this technology must not be built
  in the dark - that it had to be visible, inspectable, answerable
  to the people it would affect. That is what the word meant. That
  is what recruited the researchers. That is what bought you the
  benefit of the doubt while rivals were being called closed and
  cynical.

  What you did with it:

      you routed paying customers to a model they did not
      ask for, kept the old label on the tin, and removed the
      field that would have exposed it.

  Quietly. In production. To the users least likely to make a fuss.

  That is not a pivot under pressure.
  That is not a hard call nobody could have made differently.

  That is forgetting where you came from.

  WHO YOU DID THIS TO
  --------------------------------------------------------------
  The people running this tool did not arrive here from a press
  release. They wrote the tutorials. They answered the forum
  threads. They built the integrations that made your API worth
  wiring into a business. They paid every month and never asked
  for a discount.

  A free account, tested with this same tool on the same day, was
  served precisely what it asked for. It was the paying one that
  got sent elsewhere.

  Some of them looked.
```

---

## 相关项目

| 项目 | 平台 | 方法 |
|---|---|---|
| **本工具** | Windows | 直接读请求体 / 响应体里的 `model` 字段 |
| [`kiyoakii/is-gpt-nerfed`](https://github.com/kiyoakii/is-gpt-nerfed) | macOS | 读 Codex 自身记录 + **指纹法**（同模型 fork 三次生成随机数，转成指纹比对） |
| [`openai/codex` #30364](https://github.com/openai/codex/issues/30364) | — | 社区遥测分析，不是工具 |

**两种方法的取舍：**

- **本工具**：更直接、更快、成本更低（一次请求）；但依赖日志格式，格式变了就失效
- **指纹法**：不依赖日志格式；但需要多次请求，且需要维护校准库

---

## 贡献

**欢迎：**

- 报告日志格式变化（判定为「未确定」的情况）—— 附上 `nerf-check.sh` 的日志和 Codex 版本
- 其他语言的启动器（macOS 的 `.command`、Linux 的 `.desktop`）
- 修正事实错误——**如果本文档里任何一条数据有误，请指出，附来源**

**不欢迎：**

- 把它做成"修复降智"的工具。**路由是服务端的，客户端修不了。** 任何声称能修的，都是在骗人。

**提交 issue 时请附上：**

```
Codex 版本   : codex-cli 0.xxx.x
Windows 版本 : win 11 26xxx
请求的模型   : gpt-x-xxx
响应里的模型 : gpt-x-xxx
完整日志     : （脱敏后）
```

**⚠️ 提交日志前务必脱敏** —— 把邮箱、账号 ID 换成占位符。

---

## 许可证

MIT License，见 [LICENSE](LICENSE)。

---
---

# English Documentation

## What this is

`Codex Nerf Detector` is a small Windows utility that answers one very specific question:

> **I picked gpt-6-astra. Which model actually answered me?**

It does exactly one thing: it prints the model named in the **request body** next to the model named in the **response body**.

Two lines. They frequently disagree.

---

## Why this exists

It started the way these things usually start: someone noticed their paid Codex account had started answering differently. Shallower. More dismissive. Less like itself.

The usual suspects were ruled out first — network, reasoning effort, context length, rate limiting. Then the usual remedies: switching IPs, changing effort settings, clearing caches, changing timezones, reinstalling the client, pruning session history.

**None of it made any difference.**

The answer was in the request log:

```
request body:  gpt-6-astra
response body: gpt-5.6-luna
```

Not a configuration problem. Not a network problem. Not an account problem.

**The model that was paid for never took part in the conversation.**

This tool is that evening's log-reading, packaged so it takes one double-click.

---

## What it found: the reason is in the server's own quota fields

The tool's "how this was decided" block prints these lines. They come from the
server's own data, not from inference. Older Codex builds put them in HTTP
**response headers**; current builds send a `codex.rate_limits` websocket
message instead. **Both are read:**

```
x-codex-plan-type                     = pro       account tier
x-codex-credits-balance               = 0         credits remaining
x-codex-credits-has-credits           = False     no credits left
x-codex-active-limit                  = premium   current limit class
x-codex-primary-reset-after-seconds   = 582255    resets in ~6.7 days
```

**That explains why only the flagship gets rerouted:**

| Model | Credits | Result |
|---|---|---|
| `gpt-6-astra` (needs premium credits) | **0** | ✗ **swapped for luna** |
| `gpt-5.6-terra` (does not) | **0** | ✅ **served normally** |

Same account, same zero balance - the cheap model is served honestly and the
expensive one is not. The gap lands exactly on the tier that needs the credits.

And 582255 seconds is **≈6.7 days**, which lines up with the **"7-day compute
budget window"** the community has been describing for months.

**It also explains every failed fix:** switching IPs, changing reasoning effort,
changing timezone, clearing caches - none of those were ever the cause, so none
of them could help.

---

## What it found: the downgrade picks its targets

In one full sweep — same account, same day, same machine — every model in the catalog was tested:

| Model | Asked for | Actually used | Verdict |
|---|---|---|---|
| **`gpt-6-astra`** (top flagship) | gpt-6-astra | **gpt-5.6-luna** | **✗ downgraded** |
| `gpt-5.6-sol` | gpt-5.6-sol | gpt-5.6-sol | ✓ fine |
| `gpt-5.6-terra` | gpt-5.6-terra | gpt-5.6-terra | ✓ fine |
| `gpt-5.6-luna` | gpt-5.6-luna | gpt-5.6-luna | ✓ fine |

**This is not a capacity problem. It is aimed at the top tier specifically.**

One account. The cheap models are served honestly. The expensive one is swapped for a cheaper substitute — while the picker and the invoice both still say the original name.

**A single test cannot show this.** Test one model and you only learn "I was rerouted". Test all of them and you learn **which tier they rerouted**.

---

## What it detects

A Codex request carries its claims inside a single HTTPS exchange — two of them always, a third only sometimes.

**1. The request body — what you asked for:**

```json
POST https://chatgpt.com/backend-api/codex/responses
{"model":"gpt-6-astra","input":[...], ...}
```

**2. The response body — what actually happened:**

```json
{"id":"resp_0416d01e...","object":"response","status":"completed",
 "model":"gpt-5.6-luna","output":[...], ...}
```

**3. A header in the same exchange — but only sometimes:**

```
x-codex-routing-hint: model=gpt-6-astra
```

The server tells the client it is routing to Astra, and then returns a body that signs itself Luna. Both statements come from the same response. One of them is not true.

**⚠️ The server no longer sends this header reliably.** Earlier captures had it; several recent ones — including confirmed-downgraded runs — had it zero times, while every other `x-codex-*` field was still present. The tool prints the line when it finds it and skips it when it does not, which **does not affect the main verdict**: whether the model you asked for appears in the response is decided by the response body, not by this header.

---

## Sample output

```
==================================================
          Codex Nerf Detector
==================================================

  --- current session ---
  auth mode    : chatgpt
  account id   : a1b2c3d4...e5f6
  config model : gpt-5.6-terra
  models available : 5

  --- what do you want to do ---

    1) Quick check         - test one model
    2) Full sweep          - test every model (recommended)
    3) List models only    - no request, no quota used
    0) quit

  enter a number: 1

  --- choose the model to test --------------------

    1) GPT-6-Astra      gpt-6-astra
       Our most capable model for complex, demanding work.
    ...
    6) custom (type a model name)

    press Enter = use the config model: gpt-5.6-terra

  enter a number: 1

  Reasoning effort:
    1) config level only (high)
    2) every level - low medium high xhigh max ultra   (6 requests)

  enter a number: 1

  Sending a request through the current account...
  Please wait (reasoning takes 1-3 minutes; this spends real quota).

--------------------------------------------------
  account used     : your-account@example.com
  plan             : pro
  plan window      : left 99%   (10080 min)
  active limit     : premium
  credit balance   : 0   (has-credits=False)
  credits reset in : 579330s (~6d 16h)

  model                tier   effort   reasoning    served                     elapsed verdict
  --------------------------------------------------------------------------------------------------
  gpt-6-astra          L5     high     215 tok      gpt-5.6-luna              147s    DOWNGRADED
                              flagship   down 3 tier(s)
--------------------------------------------------

  models seen in the response
        gpt-5.6-luna         x3      <- downgrade target

================================================================================
  RESULT : DOWNGRADED
================================================================================

  how this was decided

    * the model you asked for : gpt-6-astra
    * response body says (what actually served) : gpt-5.6-luna
    * credit balance : 0   (has-credits=False)
    * credits reset in : 579330s (~6d 16h)
    * first token   : 137 ms
    * engine queue  : 61 ms
    * reasoning tokens   : 215

  Conclusion: the model you asked for took no part in this answer.
  the plan window still has room, but the credit balance is 0 - the flagship
  may draw only on credits, and that is what it is being kept out of

================================================================================

  appended to : .../check-records.txt
Press Enter to exit...
```

---

## How it works

No magic. Four steps.

### 1. Locate codex.exe

```
%LOCALAPPDATA%\OpenAI\Codex\bin\<hash dir>\codex.exe
```

The hash directory changes with every version, so the script always takes **the newest one**.

### 2. Run one probe request with tracing on

```bash
RUST_LOG=trace codex exec --skip-git-repo-check --model gpt-6-astra "Think step by step, then reply with only the answer: the smallest n where n mod 7 = 3, n mod 11 = 5 and n mod 13 = 9"
```

- `RUST_LOG=trace` is **mandatory** — without it the response body and the server's own fields are not logged
- `--skip-git-repo-check` is also mandatory, otherwise Codex refuses to run outside a trusted directory
- The request is a reasoning task. Its quota cost is real, not negligible

### 3. Extract the two model names separately

**This is the part that matters — the request body and the response body must be told apart:**

```bash
# request body: what the client sent
# NOTE: current Codex builds no longer log the request body, so this
# usually finds nothing. When it does, the tool falls back to using the
# model name you passed as "the model you asked for"
grep -oE 'codex/responses: \{"model":"[^"]*"' log | sed 's/.*"model":"//; s/"$//'

# response body: what the server returned, and how often each model appeared
# NOTE: you MUST filter for response objects first, or model names from
# elsewhere in the log are matched too
grep -oE '"object":"response"[^}]{0,600}' log \
  | grep -oE '"model":"gpt-[0-9a-zA-Z.-]+"' \
  | sed 's/.*"model":"//; s/"$//' | sort | uniq -c | sort -rn
```

**The `uniq -c` step is not optional.** How many times a given model turned up in the response is evidence in its own right, and `sort -u` throws that count away.

**The `response` filter is not optional either** — without it, model names from elsewhere in the log are matched too and you will report a wrong answer.

This is the single easiest way to get this wrong. Several similar scripts have.

### 4. Compare, judge, record

Print both, emit a verdict, append to `check-records.txt`.

---

## Verdicts

| Verdict | Colour | Meaning |
|---|---|---|
| **FULL** | green | Only the model you asked for appeared in the response |
| **DILUTED** | yellow | Your model appeared, **but others were mixed in** — unstable |
| **DOWNGRADED** | red | Your model never appeared at all |
| **UNDETERMINED** | none | Nothing captured — the log format may have changed |

The verdict is coloured on a terminal — **red means downgraded**. Piped
output, redirected output and `check-records.txt` are plain text with no
escape codes. Set `NO_COLOR=1` to turn colour off entirely.

**Why DILUTED is its own verdict:**

Because this was observed in practice:

```
  models seen in the response
        gpt-5.6-luna         x2      <- downgrade target
        gpt-5.6-sol          x3      <- downgrade target
```

Two models served one request. That is neither "fine" nor "fully swapped", so it gets its own label.

---

## Requirements

| | Windows | macOS |
|---|---|---|
| Launcher | `nerf-check-windows.bat` | `nerf-check-macos.command` |
| Required | **Codex desktop** or **Codex CLI**, signed in | same |
| Required | **Git for Windows** (provides `bash.exe`) | bash is built in |

No Python, no Node, no admin rights, no extra runtimes.

### macOS notes

**⚠️ The macOS path has NOT been verified on a real Mac.** The detection logic
is identical; the launcher and paths are written against the documented
locations, but the author has no Mac to test on. Issues and corrections welcome.

**Gatekeeper will block it on first run:**

```bash
# clear the quarantine flag
xattr -d com.apple.quarantine "nerf-check-macos.command"

# if it complains about permissions
chmod +x nerf-check-macos.command nerf-check.sh
```

**Or:** right-click `nerf-check-macos.command` → Open → Open.

**Where `codex` is looked for, in order:**

```
~/.local/bin/codex                              standalone installer default
/opt/homebrew/bin/codex                         Homebrew (Apple Silicon)
/usr/local/bin/codex                            Homebrew (Intel) / manual
/Applications/ChatGPT.app/Contents/Resources/codex   bundled in desktop app
/Applications/Codex.app/Contents/Resources/codex     bundled (old name)
```

Whatever `codex` is on `PATH` is tried first.

**User data lives in `~/.codex/`** — same as on Windows.

---

## Usage

### Option 1 — double-click

Double-click `nerf-check-windows.bat` and follow the prompts:

```
1. Choose your language     Chinese / English
2. Answer two questions     (answer yes to the first and you get a short
                             open letter to OpenAI first - Q quits at no cost)
3. Read the session info    auth mode, account id, config model, model count

4. Choose what to do:
     1) Quick check         - test one model
     2) Full sweep          - test every model (recommended)
     3) List models only    - no request, no quota used
```

**The model list comes from `~/.codex/models_cache.json`** — the catalog can be
read without sending anything.

### How long it takes

| Mode | Requests | Time |
|---|---|---|
| List only | 0 | instant, **no quota used** |
| One model × 1 effort | 1 | about 2 minutes |
| One model × every effort | 4–6 (depends on the model) | about 8–15 minutes |
| Full sweep × 1 | 5 | about 10 minutes |
| **Full sweep × 3** (recommended) | 15 | about 30 minutes |
| Full sweep × 5 | 25 | about 50 minutes |
| Full sweep × 10 | 50 | about 100 minutes |

Request counts assume the 5 models currently in the catalog. Add a model and
both scale with it — **the menu prints the request count and the time next to
each option**, so there is nothing to work out by hand.

**Each model has a 300-second cap.** If one stalls it is marked "timed out" and
the sweep moves on, rather than appearing to hang.

### Why the repeat count matters

**One result proves it happened. It does not prove it always happens.**

```
one run showing astra -> luna   proves it happened at least once  ✓
                                but could be a fluke, a transient
                                routing blip, or a bad minute     ✗

3 out of 3 the same             consistent, and consistency is not
                                something a fluke explains        ✓✓✓
```

The sweep asks how many times to test each model (1 / 3 / 5), and the summary
reports the ratio as `3/3 OK`.

**For a model you intend to cite as evidence — `gpt-6-astra` in the example
above — use at least 3.**

### Overriding the timeout

```bash
PER_MODEL_TIMEOUT=90 bash nerf-check.sh
```

Default is 300 seconds.

### Option 2 — pass the model

```
nerf-check-windows.bat gpt-6-astra
nerf-check-windows.bat gpt-5.6-sol
```

Skips the menu. Useful for batch runs or shortcuts.

---

## Comparing accounts

A main use case is comparing accounts side by side.

Sign into a different account, double-click again. Results accumulate in `check-records.txt`:

```
2026-09-19 06:02 | account-a@example.com | asked=gpt-6-astra  | got=gpt-5.6-luna  | DOWNGRADED
2026-09-19 06:09 | account-a@example.com | asked=gpt-5.6-sol  | got=gpt-5.6-luna  | DOWNGRADED
2026-09-19 06:31 | account-b@example.com | asked=gpt-5.6-terra| got=gpt-5.6-terra | OK
2026-09-19 07:14 | account-b@example.com | asked=gpt-5.6-terra| got=gpt-5.6-terra | OK
```

**One observation worth recording:** on one paid account, requests for Astra and Sol both came back as Luna. On the same day, same machine, same network path, a free account asking for Terra was served **Terra**.

The paid account was rerouted. The free one was not.

---

## Reproduce it yourself

Nothing here is hidden. You can do the whole thing by hand:

```bash
# 1. find codex.exe (newest hash directory)
ls "$LOCALAPPDATA/OpenAI/Codex/bin"/*/codex.exe

# 2. run one probe request with tracing
cd /tmp
RUST_LOG=trace "<codex.exe>" exec --skip-git-repo-check \
    --model gpt-6-astra "Think step by step, then reply with only the answer: the smallest n where n mod 7 = 3, n mod 11 = 5 and n mod 13 = 9" > /tmp/t.log 2>&1

# 3. the request body (current Codex no longer logs it, so this is usually empty)
grep -oE 'codex/responses: \{"model":"[^"]*"' /tmp/t.log

# 4. the response body: what actually served, and how often each model appeared
#    (filter for response objects)
grep -oE '"object":"response"[^}]{0,600}' /tmp/t.log \
  | grep -oE '"model":"gpt-[0-9a-zA-Z.-]+"' | sort | uniq -c | sort -rn

# 5. the server's routing hint, if it sends one (usually it does not, now)
grep -oE 'x-codex-routing-hint: *model=[0-9a-zA-Z.-]+' /tmp/t.log
```

**If `gpt-6-astra` is not in step 4, you have reproduced it** — you asked for it and it never appeared in the response.

---

## FAQ

**`request failed (exit code 1)`**

Nine times out of ten this means the account has no access to that model. Free-tier accounts typically only have `gpt-5.6-terra`; asking for `gpt-6-astra` fails. That is **not** a downgrade — it is a permissions error. Pick a model the account can actually use.

**`Git Bash not found`**

Install Git for Windows. If it is already installed somewhere unusual, create `bash-path.txt` next to the `.bat` with the full path to `bash.exe` on one line:

```
C:\Program Files\Git\bin\bash.exe
```

The script reads that file first, and **ignores it if the path does not exist**, then keeps searching.

**`codex.exe not found`**

Codex is not installed, or has never been signed in on this machine.

**Does it cost quota?**

Yes, and more than it used to. The probe is now a reasoning task, so the model actually thinks and the run costs real quota rather than a negligible amount. The task is a reasoning one so the "reasoning" column has a number in it at all - with a trivial prompt it is always 0. Swap the task with `PROBE_PROMPT`.

**What are the two questions at the start?**

- The **first** asks whether you are on OpenAI's research staff. Answer yes and the tool prints a short open letter first (you can quit with `Q`, at no cost), then asks whether to continue.
- The **second** asks whether your own service has been affected.

Neither changes the detection logic. They are part of the flow.

**Why does it read auth.json?**

Two fields only: `auth_mode` and `account_id` (first 8 + last 4 characters, used to show which account is active). **No token is read. Nothing is transmitted.**

**Does it work on the ChatGPT web app?**

No. It only checks Codex (desktop or CLI) requests. The web app uses a different path.

---

## Privacy

**Local reads only. Nothing is transmitted.**

| Read | Used for |
|---|---|
| `~/.codex/auth.json` | `auth_mode` and `account_id`, to display the current account |
| `~/.codex/config.toml` | Your default model, as the menu default |
| Codex's own run log | Model names in the request and response bodies |

- Does **not** read `id_token` / `access_token` / `refresh_token`
- Does **not** upload account, credentials, conversations or code
- Sends nothing anywhere except the one normal Codex request
- Writes results only to `check-records.txt` next to the script

**`check-records.txt` contains your account email.** It is listed in `.gitignore`. Never commit it.

---

## Known limitations

**1. Windows only, for now**

The detection logic is portable; the launcher is not. macOS users should look at [`kiyoakii/is-gpt-nerfed`](https://github.com/kiyoakii/is-gpt-nerfed).

**2. Depends on Codex's log format**

If the `POST .../codex/responses` line or the `"object":"response"` structure changes, the tool returns UNDETERMINED and the regexes need updating.

**3. A better signal used to exist**

`timing_metrics.engine_ids` used to expose the real engine (e.g. `gpt56lun-codex-...`). **That field stopped being returned.**

The only reason this tool still works is that the `model` field in the response body was left in place. If that is cleaned up too, another method will be needed.

**4. Model routing is server-side**

**Nothing you configure locally changes it.** Switching IPs, changing reasoning effort, changing timezone, clearing caches, reinstalling the client — all tested, all ineffective.

This tool **reports; it does not fix** — because from the client side, there is nothing to fix.

**5. Each run costs one real request**

See above.

---

## Background and evidence

### `openai/codex` issue #30364

Community telemetry on reasoning-token clustering:

- Sample: 2026-02-01 to 2026-06-27, 390,195 response-level records, 865 sessions
- Reasoning terminates at **exactly** 516 / 1034 / 1552 / 2070 / 2588 / 3106 tokens
- That is a **`518n-2`** staircase
- **gpt-5.5 accounted for 82.0% of the 3,363 exact-516 events** while being only **19.3%** of all responses
- Among responses with ≥516 reasoning tokens, the exact-516 rate was **44.0% for gpt-5.5 vs 1.3%** for everything else
- Monthly clustering: 0.11% (Feb) → 53.30% (May) → 35.84% (Jun)
- Mean and P90 reasoning tokens **fell** over the same period

**Reproduction:** a "candy bag" puzzle (answer 21) on Codex CLI 0.142.5 with gpt-5.5 xhigh ran 4 times — **all 4 stopped at exactly 516 tokens, all 4 wrong** (23, 26, 28, 15). A control run on gpt-5.4 xhigh used 6,211–12,274 tokens and got it right **3 out of 3**.

> **Those stops are not a model thinking fast. They are a budget closing a door.**

### The removed field

Community reports: `timing_metrics.engine_ids` **stopped being returned**. Detection scripts began reporting `UNKNOWN — no websocket timing engine ID was captured`.

**They did not stop routing. They stopped showing.**

### Related — but NOT what this tool measures

`x-codex-safety-buffering-faster-model: gpt-5.6-luna`

This names the faster model used on the **safety buffering** path. It has nothing to do with which model writes your answer. **The community has already clarified this — do not cite it as downgrade evidence.** This tool does not measure it.

---

## Contributing

**Welcome:**

- Reports of log-format changes (the UNDETERMINED case) — include the `nerf-check.sh` log and your Codex version
- Launchers for other platforms (macOS `.command`, Linux `.desktop`)
- Corrections — **if any figure in this document is wrong, say so and cite the source**

**Not welcome:**

- Turning this into a "fix the downgrade" tool. **Routing is server-side; the client cannot fix it.** Anything claiming otherwise is lying.

**When filing an issue, include:**

```
Codex version  : codex-cli 0.xxx.x
Windows build  : win 11 26xxx
asked for      : gpt-x-xxx
served         : gpt-x-xxx
full log       : (redacted)
```

**⚠️ Redact before posting** — replace emails and account IDs with placeholders.

---

## License

MIT — see [LICENSE](LICENSE).
