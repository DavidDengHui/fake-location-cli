# Fake Location CLI - flc（iPhone 虚拟定位命令行工具，Windows 便携版）

[English](README.md) | **中文**

本仓库名为 **Fake Location CLI**；工具本体在文档中一律写作并以 **``flc``** 命令调用。

一个小巧、自包含的命令行工具，用于模拟已连接 iPhone 的 GPS 位置。它基于
[pymobiledevice3](https://github.com/doronz88/pymobiledevice3) 构建，并自带便携
Python，因此**无需预先安装任何环境**（iPhone USB 驱动也已内置离线安装包）。

所有内容都在一个文件夹内。把整个文件夹复制到任意 Windows 电脑即可运行。

---

## 1. 目录内容

```
flc\
  flc.cmd                              启动器（运行它 / 即“flc”命令）
  flc-main.ps1                          全部程序逻辑（引擎，由 flc.cmd 调用）
  flc_set.py                            位置保持脚本（保活 + 自动重连）
  flc_route.py                          从文本/CSV 或逐行输入生成 GPX 路线
  flc_ddi.py                            离线开发者镜像（DDI）管理
  requirements.txt                      精确定版的 Python 依赖（构建时使用）
  assets\                               所有运行依赖都集中在这一个文件夹
    python\                             精简后的便携 Python 3.12 + pymobiledevice3
    drivers\
      AppleMobileDeviceSupport64.msi    离线 Apple USB 驱动
    ddi\                                离线开发者镜像（约 16 MB）
    dist\                               构建材料（仅在执行“flc configure”后出现）
      python-3.12.10.nupkg              官方 NuGet Python 包
      wheels\                           全部定版 wheel（离线安装缓存）
  data\                                 生成的路线与数据（自动创建）
    example-route.gpx / .txt            内置示例路线
  logs\                                 日志文件（自动创建）
  README.md
  README-CN.md
```

所有第三方运行组件都集中放在 `assets\` 下，程序目录保持整洁。发布的便携包已包含
`assets\python`、`assets\drivers` 和 `assets\ddi`，无需任何下载即可运行。
`assets\dist` 仅在你执行 `flc configure` 从源码重建运行时才会出现。

`wintun` 隧道驱动已内置在 pymobiledevice3 包内（amd64/arm64/x86/arm），无需另装
隧道驱动。

### 运行要求

- Windows 10 / 11（64 位）。
- **iOS 17 或更新**的 iPhone（已在 iOS 17–27 测试）。
- USB 数据线（首次配对时使用）。配好之后，同一台 iPhone 也可以**走 Wi-Fi、不用数据线**
  （`flc wifi on`）。
- 仅以下操作需要管理员权限：安装驱动、启动/停止 Apple 服务。修改定位本身**不需要**
  管理员权限（USB 与 Wi-Fi 均如此）。

---

## 2. 快速开始

### A) 使用便携包（推荐）

发布的 `flc` 文件夹已包含便携 Python、驱动和 DDI。**在该文件夹内**打开命令窗口
（`Shift+右键` → *在此处打开终端/PowerShell*），然后：

1. **准备这台电脑**（仅一次）。推荐：
   ```
   flc make install
   ```
   它会把当前文件夹加入用户 PATH，**并自动**安装 USB 驱动（弹一次 UAC——点**是**）、
   缓存离线 DDI；若此时已连接 iPhone，还会顺带把 DDI 准备到手机上。完成后**新开**一个
   命令窗口，即可在任意目录直接输入 `flc`。

   若不想改动 PATH，可只运行驱动这一步：`flc drivers install`（需要管理员）；DDI 会在
   第一次 `flc set` 时自动准备。

2. 用 USB **连接 iPhone**，解锁手机，然后：
   ```
   flc devices connect
   ```
   同意 UAC，并**在 iPhone 上点击“信任”并输入锁屏密码**。

3. **开启开发者模式**（iOS 16+ 及 DVT 定位功能需要）：在 iPhone 上进入
   **设置 → 隐私与安全性 → 开发者模式 → 打开**，按提示重启手机。（开发者模式菜单
   在首次开发者连接后才会出现。）

4. **设置位置**（无需管理员）。直接给两个数字——纬度在前、经度在后。窗口会保持
   打开并**持续维持**该位置。
   ```
   flc set 23.137106 113.331353
   ```
   不写数字会引导你逐个输入。所需的开发者镜像已**离线内置**在 `assets\ddi\`，
   会自动准备，因此第一次 `set` 不会下载大文件。完成后 iPhone 在地图等 App 中会
   显示新位置。

5. **回到真实位置**：在运行窗口中点击并按 **Ctrl+C**（工具会清除模拟并恢复真实
   GPS），或运行：
   ```
   flc set own
   ```
   如果未按 Ctrl+C 直接关闭窗口且虚拟位置仍在，运行一次 `flc set own` 即可。

### B) 无线使用——不用数据线

iPhone 用 USB 完成一次信任（上面的第 1–3 步）之后，数据线就是可选的了：

1. iPhone 仍插着数据线并保持解锁，然后运行：
   ```
   flc wifi on
   ```
   它会打开 iPhone 的 Wi-Fi 同步开关（就是 iTunes/Finder 里那个开关）。每台 iPhone
   与这台电脑之间只需做一次。
2. 拔掉数据线。让 iPhone 保持**解锁**状态，与电脑在**同一个 Wi-Fi 网络**下，并且打开
   Wi-Fi（与蓝牙）。`flc wifi status` 会告诉你发现设备所依赖的 Bonjour/mDNS 服务是否
   在运行。
3. 确认电脑已经发现这台 iPhone：
   ```
   flc wifi list
   ```
4. 用 Wi-Fi 设置位置——只要加上 `--wifi`：
   ```
   flc set 23.137106 113.331353 --wifi
   flc set gpx data\example-route.gpx --wifi
   flc set own --wifi
   ```
   位置保持、Ctrl+C、GPX 回放和 `--keep` 的行为与 USB 完全一致。网络里有多台 iPhone 时，
   用 `--udid <UDID>` 指定一台（`flc devices list` 会列出 UDID）。

如果 iPhone 始终不出现，请看[第 6 节常见问题](#6-常见问题)里的无线部分。

### C) 仅从源码开始（GitHub / 源码包）

纯源码文件夹没有 `assets\`，需先构建运行时。在能联网的电脑上：

```
flc configure
flc make
```

`flc configure` 会从官方来源把便携 Python NuGet 包、全部定版 Python wheel、Apple
驱动 `.msi` 和离线 DDI 下载到 `assets\`（已存在且完整的项目会跳过）。随后
`flc make` 离线构建精简版便携 Python 到 `assets\python`（无需编译器）。之后按上面
的第 1–5 步继续。

以后升级到最新版，无需重新下载整个包，直接运行：

```
flc make update          # 默认从 Gitee 更新（国内直连）
flc make update github   # 或从 GitHub 更新（本机需可访问 GitHub）
```

更新只覆盖程序源码，`assets\`、`data\`、`logs\` 全部保留。

---

## 3. 命令参考

所有命令都支持短别名（例如 `flc -c`）。

### configure — 下载全部运行依赖

| 命令 | 别名 | 含义 |
|---|---|---|
| `flc configure` | `-c` | 从官方来源把全部运行依赖下载到 `assets\`（NuGet Python 包、定版 wheel、Apple 驱动 `.msi`、离线 DDI）。已存在且完整的项目自动跳过，可重复执行。 |

下载的构建材料放在 `assets\dist\`；驱动和 DDI 分别放到 `assets\drivers\` 和
`assets\ddi\`。需要联网。发布的便携包无需此命令。

### make — 构建运行时、安装/卸载命令

| 命令 | 别名 | 含义 |
|---|---|---|
| `flc make` | — | 用 `assets\dist` 离线构建精简便携 Python 到 `assets\python`（完全离线，无需编译器）。在 `flc configure` 之后运行。 |
| `flc make update` | `--update` | 从 Gitee（默认，无需代理）或 GitHub（`flc make update github`）更新到最新源码。Git 克隆的仓库直接 `git pull`；源码包安装（无 `.git`）会下载最新源码归档并就地覆盖，**保留 `assets\`、`data\`、`logs\`**。更新完成后会**自动清空旧配对记录**（保留 SystemConfiguration / SystemBUID），下次连接时在 iPhone 上重新信任即可。 |
| `flc make install` | `-i` | 把当前文件夹加入**用户 PATH**，随后自动安装 USB 驱动（弹一次 UAC）、缓存离线 DDI、在已连接手机时准备 DDI，最后输出一次完整的 `flc server status` 状态总览。 |
| `flc make -i --prefix=路径` | `--p=路径` | 把整个程序（含 `assets\`）复制到该路径并加入用户 PATH。`-i` 是 install 短标志，`--p=` 是 prefix 短标志。示例：`flc make -i --p="C:\flc"`（等价于 `flc make install --prefix="C:\flc"`）。 |
| `flc make uninstall` | `-u` | 从用户 PATH 移除该文件夹；随后**先询问是否卸载 Apple USB 驱动**（Apple Mobile Device Service + USB Driver）并清空 `C:\ProgramData\Apple\Lockdown` 的配对记录（确认后提权执行），再询问是否删除整个程序文件夹。加 `-y` 直接删除文件夹（**不会**删除驱动）。 |
| `flc make clean` | `-c` | 删除整个 `assets\` 文件夹（构建好的 Python、驱动、DDI、构建材料），只保留程序源码。之后可用 `flc configure` 再 `flc make` 重建。需输入 `YES`；加 `-y` 跳过确认。 |

执行 `flc make install` 后，**新开**一个命令窗口再输入 `flc help`。

`--prefix` 也支持空格形式 `--prefix 路径`。即使不加入 PATH，直接运行文件夹内的
`flc.cmd` 也始终可用。

### server — 后台组件

| 命令 | 别名 | 含义 |
|---|---|---|
| `flc server status` | `-s` | 查看便携 Python、pymobiledevice3 版本、Apple 服务、tunneld 端口、离线驱动/DDI、已连接设备，以及当前有几台 iPhone 通过 Wi-Fi 可见。 |
| `flc server kill` | `-k` | 结束冲突的后台进程（占用 tunneld 端口 49151 的进程，以及残留的 `pymobiledevice3 tunneld` / `simulate-location` 进程）。需要管理员。 |
| `flc server kill --pair` | `-p` | 在结束进程之外，额外清空旧配对记录并重启 Apple Mobile Device Service，用于修复配对 / 安装 DDI 时报 usbmux 错误 **183**（旧配对记录冲突）。需要管理员；执行后请重插手机、在 iPhone 上重新点「信任」，再运行 `flc ddi install`。 |

### drivers — iPhone USB 驱动

| 命令 | 别名 | 含义 |
|---|---|---|
| `flc drivers list` | `-l` | 列出所需驱动，以及是否已内置离线安装包。 |
| `flc drivers status` | `-s` | 查看驱动是否已安装、服务状态和实时 USB 节点。 |
| `flc drivers install` | `-i` | 静默安装驱动（有离线 `.msi` 则用之，否则先下载）。需要管理员。 |
| `flc drivers uninstall` | `-u` | 卸载 Apple Mobile Device Support（Apple Mobile Device Service + USB Driver）。加 `--clear` 同时清空 Lockdown 下**全部**配对 plist（含 SystemConfiguration）。需要管理员。 |

### devices — 已连接的 iPhone

| 命令 | 别名 | 含义 |
|---|---|---|
| `flc devices list` | `-l` | 列出已连接的 Apple 设备（名称、型号、iOS、UDID、USB/Wi-Fi）。 |
| `flc devices connect` | `-c` | 启动 Apple 服务并发起配对请求（在 iPhone 上点信任）。需要管理员。 |
| `flc devices disconnect` | `-d` | 停止 Apple 服务，释放所有 iPhone 连接。需要管理员。 |
| `flc devices reconnect` | `-r` | 重启 Apple 服务并重新列出设备（出问题时很有用）。需要管理员。 |

### wifi — 无线连接 iPhone（不用数据线）

flc 可以走 Wi-Fi 与 iPhone 通信，而不必插数据线。Apple Mobile Device Support 会通过
Bonjour 广播这台手机，它随即以网络设备出现在 `usbmux list` 中，之后建立的是同一套用户态
隧道——同样**不需要管理员权限**，也不需要后台 tunneld。

| 命令 | 别名 | 含义 |
|---|---|---|
| `flc wifi status` | `-s` | 查看 Bonjour/mDNS 服务、iPhone 上的 Wi-Fi 同步是否已开启，以及当前通过 Wi-Fi 可见的 iPhone。 |
| `flc wifi on` | `-o` | 打开 iPhone 的 Wi-Fi 同步（仅一次，此时需要插着数据线）。之后就可以不插线使用。 |
| `flc wifi off` | `-f` | 关闭 Wi-Fi 同步（需要 USB 连接）。 |
| `flc wifi list` | `-l` | 列出当前通过 Wi-Fi 可见的 iPhone。 |
| `flc wifi browse` | `-b` | 用 Bonjour 搜索局域网里的 iPhone——在它还没出现在 `flc wifi list` 时很有用。 |
| `flc wifi pair [名称]` | `-p` | 直接通过 Wi-Fi 配对 iPhone（RemotePairing）。需要 iPhone 开启开发者模式；在列表里选设备，并把电脑上显示的配对码输入到 iPhone。 |

无线使用的前提：这台 iPhone 已在这台电脑上用 USB 信任过至少一次，手机**已解锁**，且与电脑
在**同一个 Wi-Fi 网络**；同时 Apple Mobile Device Support 安装的 **Bonjour 服务**必须处于
运行状态（`flc wifi status` 会报告，`flc drivers install` 可修复）。

### ddi — 离线开发者镜像

iOS 17+ 的定位服务要求设备上存在开发者镜像（DDI）。镜像本身（约 16 MB）已**离线
内置**在 `assets\ddi\`，flc 不会去 GitHub 下载大文件。首次 `set` 前会自动把它复制
到本地缓存。

| 命令 | 别名 | 含义 |
|---|---|---|
| `flc ddi status` | `-s` | 查看内置与缓存的 DDI build 号，以及已连接 iPhone 是否已安装。 |
| `flc ddi sync` | — | 把内置离线 DDI 复制到本地缓存（首次 `set` 时也会自动执行）。 |
| `flc ddi install [UDID]` | `-i` | 对已连接 iPhone 个性化并安装 DDI（通常首次 `set` 时自动完成）。给出 UDID 可指定设备，例如指定无线那台。 |

唯一无法预先内置的联网步骤，是对**每台 iPhone** 首次安装时苹果一次性的个性化签名
（仅几 KB）；之后 DDI 会保留在手机上，后续运行完全离线。

### 定位

| 命令 | 含义 |
|---|---|
| `flc set <纬度> <经度>` | 用两个纯数字设置并**保持**位置（纬度在前、经度在后）。示例：`flc set 23.137106 113.331353` |
| `flc set <纬度> <经度> --keep <秒>` | 自定义**保活间隔**（1–3600 秒，默认 15 秒）。短选项：`-k`。示例：`flc set 23.137106 113.331353 --keep 5` |
| `flc set` | 不写坐标——会引导你逐个输入纬度和经度（给出示例：`23.137106 113.331353`）。 |
| `flc set -Lat <纬度> -Lng <经度>` | 命名参数形式，等价于两个纯数字形式。 |
| `flc set gpx <文件>` | 回放路线（`.gpx`，或自动转换的 `.txt`/`.csv`），结束后保持最后一个点。见 [GPX 回放](#gpx-回放)。 |
| `flc set gpx <文件> --keep <秒>` | 回放路线，并用自定义间隔保持终点（默认 15 秒，短选项 `-k`）。 |
| `flc set gpx new` | **逐行**输入（时间 + 纬度 + 经度）生成路线并回放。见 [生成路线](#生成路线)。 |
| `flc set own` 或 `flc set -o` | 清除模拟，恢复真实位置。 |
| `flc set <纬度> <经度> --wifi` | 同上，但走 **Wi-Fi** 而不是 USB（短选项 `-w`）。上面各种 `set` 形式都可以加。 |
| `flc set <纬度> <经度> --udid <UDID>` | 指定某台设备（USB 或 Wi-Fi 均可）。短选项 `-U`；UDID 由 `flc devices list` 列出。 |
| `flc help` / `flc -h` | 显示帮助。 |

坐标为十进制**纬度在前、经度在后**。负数也可以（工具会自动加 `--` 分隔符），
例如纽约：`flc set 40.690008 -74.045843`。

> **坐标系说明：**手机定位服务使用 **WGS-84**。从国内地图（高德、腾讯、百度）复制
> 的坐标是 GCJ-02 或 BD-09，在中国大陆可能偏差几百米。在国内要精确定位，请先把
> 地图坐标转换为 WGS-84。在中国大陆以外（以及多数测试场景）两者足够接近。

---

## 4. 位置是如何维持的（为什么不会跳回真实位置）

`flc set` 以**用户态隧道**模式（`--userspace`）运行 DVT 定位服务，这是一套纯
Python 网络栈，**不需要管理员、也不需要后台 tunneld**。保持脚本（`flc_set.py`）
不只是发送一次位置：

- 它在同一连接上**默认每 15 秒**重新下发一次位置（可用 `flc set ... --keep <秒>`
  改为 1–3600 秒内的任意间隔，短选项 `-k`），让手机持续报告虚拟位置，而不是漂回真实 GPS。
- 如果 USB/网络隧道断开，它会**自动重建隧道**并继续保持。
- 按 **Ctrl+C**（或终止）时，它会新建一条连接并发送**清除**指令，手机随即恢复真实
  位置。

走 Wi-Fi 时（`flc set ... --wifi`）机制完全一样：无线隧道断开（手机锁屏、离开 Wi-Fi、
网络抖动）时，flc 会重建隧道并继续维持。让手机保持解锁并在同一网络下，连接就会一直
保持。

运行窗口会打印类似内容：

```
[flc] Simulated location set: 23.137106, 113.331353
[flc] Holding location (re-applied every 15s). Keep this window open.
[flc] 03:14:50  location re-applied  (23.137106, 113.331353)
```

- **保持窗口打开**即可维持虚拟位置（窗口里会打印当前使用的间隔，如 `re-applied every 15s`）。
- 在该窗口按 **Ctrl+C** 可干净停止并恢复真实 GPS。
- 如果直接关闭窗口（或虚拟位置仍残留），运行一次 `flc set own`。

### GPX 回放

`flc set gpx <路线.gpx>` 会回放录制的**轨迹**，让手机沿轨迹移动：

- 每个轨迹点按顺序发送。如果点带有时间戳，工具会按真实时间间隔等待，复现录制时的
  速度。
- 轨迹结束后，会用相同的保活机制（默认 15 秒，可用 `--keep <秒>` 调整）**保持最后一个点**。
- 内置可用示例：`flc set gpx data\example-route.gpx`。

可从 Strava、Komoot、AllTrails、运动手表或路线规划工具导出为 **GPX 1.1 轨迹**
（`<trk>`）。仅含 `<rte>` 路线或路点的文件不会被底层库回放——请先转换成轨迹。

### 生成路线

无需手写 GPX。flc 可以从纯文本或逐行输入生成轨迹。

**A) 回放纯文本 / CSV 路线** —— `.txt` 或 `.csv` 会被自动转换为 GPX 再回放。每行
一个点，分隔符可以是空格、逗号、制表符、`;` 或 `|`。时间可省略：

```
0 23.137106 113.331353
10 23.138000 113.332000
25.5 23.139000 113.333000
```

每行格式为 `[时间] 纬度 经度`。时间为距开始的秒数（`0`、`10`、`25.5`），也可以是
时钟值 `HH:MM:SS` / `MM:SS`。省略时间时，点与点之间自动间隔 10 秒。以 `#` 开头的
行为注释。然后：

```
flc set gpx my-walk.txt
```

转换后的 GPX 会保存到 `data\` 并回放。

**B) 交互式生成路线** —— 运行 `flc set gpx new`（或 `flc set gpx` 不给文件，再输入
`new`）。会逐个提示输入点；在**空行按回车**结束。路线保存到
`data\route-<时间戳>.gpx` 并回放。

```
point 1> 0 23.137106 113.331353
point 2> 10 23.138000 113.332000
point 3> 23.139000 113.333000
point 4>
```

`.gpx` 示例旁还附带了一个 `data\example-route.txt`。

---

## 5. 移植到另一台电脑

整个文件夹是便携的。

1. 把整个 **`flc`** 文件夹复制到另一台电脑（U 盘或网络拷贝）。任意位置均可，例如
   `C:\flc`、`C:\Program Files\flc` 或移动硬盘。
2. 在那台电脑上运行一次 `flc make install`：它会安装 USB 驱动（弹一次 UAC）、缓存
   离线 DDI，并把该文件夹加入用户 PATH。想装到固定位置可用
   `flc make install --prefix="C:\flc"`。若不想改动 PATH，可改为运行
   `flc drivers install`（需要管理员）。
4. 无需安装 Python、pip 或其他软件。内置的 `assets\python` 文件夹自包含。

不要只复制 `flc.cmd`——`assets\` 文件夹必须一起带走。内置的 DDI 也意味着新电脑
无需下载大文件。

如果想把工具发布到代码仓库而不携带大型第三方二进制文件，可复制一份文件夹，运行
`flc make clean` 只保留源码后推送。使用者在能联网的电脑上运行一次
`flc configure` 和 `flc make` 即可重建便携运行时。

---

## 6. 常见问题

- **无论什么命令都只显示帮助 / 不执行** —— 确认你运行的是启动器 `flc.cmd`（或
  `make install` 后的 `flc` 命令）；引擎是 `flc-main.ps1`，不能直接按文件名运行。
  如果从旧版本升级，请**新开**一个命令窗口，让 Windows 重新把 `flc` 解析到
  `flc.cmd`。运行 `flc devices list` 应能打印 `Connected Apple devices:`。
- **提示“flc 不是内部或外部命令”** —— 在文件夹内运行 `flc.cmd`，或运行一次
  `flc make install` 后新开命令窗口。
- **纯源码文件夹提示缺少运行时** —— 运行 `flc configure` 再 `flc make`（需联网）
  构建 `assets\python`，或直接使用发布的便携包。
- **`ConnectionRefusedError [WinError 1225]` / 找不到设备** —— Apple Mobile
  Device Service 已停止或缺少驱动。运行 `flc drivers status`，然后
  `flc devices connect`（同意 UAC）和 `flc devices reconnect`。也可更换 USB 数据线/
  接口（要数据线，不是纯充电线）。
- **出现 UAC 提示** —— 安装驱动、服务控制和 `server kill` 需要管理员，点击**是**
  即可（账号本身已是管理员，通常无需密码）。
- **不出现信任提示** —— 再运行一次 `flc devices connect` 或 `flc devices reconnect`；
  拔插一次 iPhone；确保手机已解锁。
- **开发者模式 / 开发者镜像报错** —— 先开启开发者模式（见第 2 节）。镜像已离线
  内置，用 `flc ddi status` 检查、`flc ddi install` 安装到手机。给新 iPhone 首次
  安装需要一次很小的、苹果一次性的个性化握手；之后即离线可用。
- **更新的 iOS 提示 DDI build 不匹配** —— 每个 iOS beta/正式版可能需要对应 DDI。
  更新 pymobiledevice3（或替换 `assets\ddi\` 文件夹）使内置 build 号匹配，再运行
  `flc ddi sync`。
- **位置不对 / 不动 / 跳回真实 GPS** —— 保持窗口必须一直开着；它按间隔（默认 15 秒，
  可用 `--keep <秒>` 调整）重新下发，断线会重建隧道。若仍跳回，先 `flc set own` 再重新 `set`。
  部分 App 会缓存位置，请重新打开它们。
- **GPX 轨迹不动** —— 文件必须包含 `<trk>` 轨迹（不能只有 `<rte>`/路点），见
  [GPX 回放](#gpx-回放)。用内置的 `data\example-route.gpx` 可验证该功能。
- **端口 49151 已被占用** —— 已有 tunneld 在运行，执行 `flc server kill`。
- **配对 / DDI 安装报 usbmux 错误 183** —— 电脑上的旧配对记录冲突或损坏。以管理员运行 `flc server kill --pair`（短选项 `-p`），随后重插手机、在 iPhone 上重新点「信任」，再运行 `flc ddi install`。
- **`flc wifi list` 什么都没有 / `flc set --wifi` 提示看不到 iPhone** —— 这台 iPhone 必须
  已在这台电脑上用 USB 信任过至少一次、处于解锁状态，并与电脑在同一个 Wi-Fi 网络。插着
  数据线时运行一次 `flc wifi on`，再看 `flc wifi status`：**Bonjour 服务**必须是 Running
  （可用 `flc drivers install` 修复）。`flc wifi browse` 能显示此刻 Bonjour 看到的东西，
  `flc devices reconnect` 可刷新 Apple 服务。
- **手机锁屏后无线连接断开** —— 正常现象：iOS 在锁屏/休眠时会挂起 Wi-Fi 同步。解锁手机，
  flc 会自动重建隧道并继续维持。
- **总是连到另一台 iPhone** —— 用 `--udid <UDID>` 明确指定设备
  （UDID 由 `flc devices list` 列出）。
- **`flc wifi pair` 搜不到设备** —— 打开 iPhone 的开发者模式
  （设置 → 隐私与安全性 → 开发者模式），并让它和电脑在同一个 Wi-Fi 下。常规路径其实
  不需要任何配对码：用 USB 配对一次，然后 `flc wifi on`。
- **日志** —— 见 `logs\flc.log` 和 `logs\amds-install.log`。

---

## 7. 卸载

- 完整卸载：`flc make uninstall`。它先从 PATH 移除条目，随后询问是否卸载 Apple USB
  驱动并清空配对记录（确认后弹 UAC 执行），最后询问是否删除整个文件夹；加 `-y` 可
  直接删除文件夹（**不会**删除驱动）。
- 只想卸载 iPhone USB 驱动：`flc devices disconnect`，然后
  `flc drivers uninstall --clear`（同时清空配对记录，需要管理员）。

卸载驱动仅移除本机的 Apple USB 支持，不影响 iPhone。

---

## 8. 其他说明

- 本工具封装的是官方 `pymobiledevice3` 命令行，不会修改 iPhone，也不会在手机上安装
  任何东西。
- 模拟定位是面向测试、开发和个人使用的开发者功能。请合法使用，并遵守你所用 App 的
  规则。
- 虚拟位置由手机上报给 App，并非真正改变 GPS。
- `flc configure` 使用的官方下载来源：Python NuGet 包（`nuget.org/packages/python`）、
  来自 PyPI 的 Python wheel（失败时回退清华镜像）、来自 `swcdn.apple.com` 的 Apple
  Mobile Device Support `.msi`（校验 SHA-256），以及来自
  [DeveloperDiskImage](https://github.com/doronz88/DeveloperDiskImage) 镜像的 DDI。
