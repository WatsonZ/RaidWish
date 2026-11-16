# RaidWish 许愿助手

《魔兽世界》："无限"的团队许愿、分数、掉落记录与拍卖插件。

- 团员在团队频道发 `xy` 加物品链接即可许愿，许愿团长那边自动录入、全团同步。
- 每人一个分数，团长可以加减；拾取时可按出分自动扣分。
- 记录掉落，命中许愿的自动标记完成。
- 同一件装备多人想要时，在团队频道出分、同分 Roll 点，结果全团同步。

详细规则见 [docs/需求说明.md](docs/需求说明.md)。

## 安装

把 `addon/RaidWish` 整个文件夹复制到游戏目录的 `Interface/AddOns/` 下，重启游戏或在角色选择界面的插件列表里勾选"RaidWish 许愿助手"。

团员和团长都需要安装。插件只在团队（不是五人小队）里通讯。

## 常用命令

| 命令 | 作用 |
|---|---|
| `/xy` | 开关许愿窗口 |
| `/xy help` | 列出全部命令 |
| `/xypm` | 拍第一件待拍物品（团长、助理） |
| 密语 `cxxy` | 查询自己的许愿和分数 |

## 目录

```
addon/RaidWish/     插件本体（发布时只需要这个文件夹）
  tests/            离线单元测试
docs/               需求说明、界面效果图、开发文档
tools/
  sim/              多客户端模拟（本机跑一遍团队流程）
  voice/            生成语音提示的脚本
  icon/             生成小地图图标的脚本
  RaidWishProbe/    接口探测插件（开发用，不随插件发布）
  lua51.py          本机没有 Lua 时用的 Lua 5.1
```

## 开发

需要 [uv](https://docs.astral.sh/uv/)（运行测试用的 Lua 5.1）和 [luacheck](https://github.com/lunarmodules/luacheck)。

```bash
cd addon/RaidWish
uv run --no-project --with lupa python -I ../../tools/lua51.py tests/run.lua
luacheck .
cd ../..
uv run --no-project --with lupa python -I tools/lua51.py tools/sim/run.lua
uv run --no-project --with lupa python -I tools/lua51.py tools/sim/crash.lua
```

三项都通过再提交。详细说明见 [docs/开发工具.md](docs/开发工具.md)。

## 许可证

[MIT](LICENSE) © 2026 迪恩温彻斯特。免费使用，可以自由使用、复制、修改和分发，但须保留原作者署名和许可声明；按"原样"提供，不附带任何担保。本插件为玩家个人作品，与暴雪娱乐、网易公司无关。

## 联系作者

发现问题或有建议：dean.addon.wow@proton.me

反馈时最好附上截图、操作步骤，以及游戏内"设置 → 关于 → 出错信息"里的内容。
