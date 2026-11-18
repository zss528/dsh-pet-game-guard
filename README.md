# 打游戏时自动把桌宠藏起来

DSH 桌面端有个桌宠（dsh-pet 插件）。平时挺可爱，一开游戏就挡视线。这个脚本干的事很简单：**检测到你在玩游戏，就把桌宠收起来；退出游戏，再放回来。**

Windows 用，PowerShell 5.1（系统自带），不用装任何东西，也不用管理员权限。

---

## 为什么写这个

桌宠是挂在桌面上的一个窗口，全屏游戏里它还在那儿飘，很碍事。每次手动去设置里关掉、打完再打开，太麻烦，就让它自己判断。

判断两件事：有没有在跑游戏（按进程名），或者前台是不是一个盖满屏幕的窗口。两个都没有，就认为你在正常用电脑。

---

## 装上

1. 下载这个仓库，解压到一个**以后不会乱动的位置**，比如 `D:\tools\pet-game-guard`；
2. 双击 `install.cmd`；
3. 看到下面这种输出就算装好了，桌宠也在后台开始受保护了：

```
── DSH 桌宠守护 · 体检 ──
DSH：http://127.0.0.1:65340（宠物：main）
  · main  display = desktop
当前判定：不在游戏 / 无全屏 → 应该显示
开机自启：已安装
```

之后每次开机它自己会起来，不用再管。

> 如果双击没反应，右键 `install.cmd` 选「以管理员身份运行」再试一次。

---

## 用起来

装完没有界面，跑在后台。想看看状态，双击 `status.cmd`。

想确认「藏起来」真的有效，又懒得开游戏，跑这个：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\PetGameGuard.ps1 -SimulateSeconds 10
```

它会假装你在打游戏 10 秒，桌宠应该消失又回来。

日志在同目录 `pet-game-guard.log`，只在状态变化、出错、和每小时一条心跳时写东西，正常用的话基本是空的。

---

## 配置

改 `pet-game-guard.config.json`，存盘后 30 秒内生效（`pollSeconds` 例外，那个要重启）。

| 键 | 默认 | 干什么的 |
|---|---|---|
| `restoreDisplay` | `"desktop"` | 游戏退出后放回哪儿，`desktop` 就是桌面。填 `none` 会被无视 |
| `hideOnFullscreen` | `true` | 全屏也藏。介意看视频也藏的话改 `false` |
| `pollSeconds` | `3` | 多久看一次，1~10 都行 |
| `dshPort` | `0` | 0 是自动找 DSH 的端口；想固定就填数字 |
| `routePrefix` | `"/dsh-pet-7340"` | 桌宠插件的接口前缀，一般不用动 |
| `heartbeatMinutes` | `60` | 多久写一条心跳日志，0 是不写 |
| `processes` | `[]` | 空着用默认规则 + `extraProcesses`；填了就只用你写的 |
| `extraProcesses` | 30 条 | 在默认规则上追加，支持 `*` 通配 |

### 加自己玩的游戏

游戏开着，在任务管理器「详细信息」里看进程名（不带 `.exe`），或者：

```
tasklist | findstr /i 游戏名
```

然后丢进 `extraProcesses`：

```json
"extraProcesses": ["MyCoolGame", "*Unity*"]
```

大小写无所谓，`*` 能匹配任意字符。

---

## 遇到问题

**`status.cmd` 说找不到 DSH。**
确认 DSH 开着、桌面上能看到桌宠。脚本每 30 秒会再找一次，DSH 起来后自己会接上。

**看视频全屏也会把桌宠藏了。**
`hideOnFullscreen` 改成 `false`，就只看游戏进程。

**我的游戏没被识别。**
进程名丢进 `extraProcesses`。虚幻引擎做的游戏一般能被 `*Win64-Shipping` 抓到。

**会不会拖慢游戏。**
每 3 秒扫一次进程名 + 读一次前台窗口位置，就这么点开销。不进游戏内存，不做注入。

**桌宠不见了，设置里也是隐藏状态。**
重启一次这个脚本（或者重启电脑）就会自动放回来——启动时它会检查，发现「藏着但没在游戏」就直接恢复。

---

---

## 它是怎么知道桌宠能不能藏的

dsh-pet 插件在本机开了几个 HTTP 接口，桌面右键菜单里那个「显示位置」用的也是它们：

- `GET /dsh-pet-7340/config` —— 看现在有哪些宠物、各自是什么显示状态；
- `POST /dsh-pet-7340/pet-display` —— 把它改成 `desktop` 或者 `none`。

脚本就是每几秒判断一次，然后调这两个接口。没改插件，没读内存，也没 hook 游戏。

---

## 文件都是干什么的

```
PetGameGuard.ps1             主脚本，install / uninstall / status 都在里面
pet-game-guard.vbs           静默启动用，快捷方式指它，免得出黑框
pet-game-guard.config.json   配置，改完存盘就生效
install.cmd                  装：建开机自启 + 后台跑起来
uninstall.cmd                卸：删自启、停进程、把桌宠放回来
status.cmd                   看状态
pet-game-guard.log           日志，超过 1MB 自动留一份旧的
pet-game-guard.state         记着上次找到的 DSH 端口，删了也没事
```

---

## 许可

MIT，随便用。dsh-pet 插件和它的素材版权归原作者，这个仓库里不含插件本身。
