# 火纹改版工具（fe_editor）

安卓端 GBA《火焰之纹章》三部曲 ROM 改版工具。Flutter 实现，零第三方插件依赖。

**接手开发前请先读 `~/workspace/AGENTS.md`**——里面有构建命令、核心概念、已知的坑和待办。

## 功能

- **ROM 识别**：不依赖 game code，改为「结构匹配」——看哪个版本的指针槽在 ROM 里全部有效。兼容改版改写 game code（如 BE8E 的 20MB 重度改版）的情况
- **角色 / 职业 / 道具表**：浏览与数值编辑（等级、属性、成长率、移动、体格），改动可撤销，导出前不写文件。列表 ID 恒等于表内偏移，空条目显示为「（未命名）」而不跳过
- **表地址**：可手动指定各数据表的基址，用于表被搬到别处且指针槽失效的改版
- **道具浏览**：按种类分组（剑 / 枪 / 斧 / 弓 / 杖 / 理光闇魔法 / 消耗品 / 指环 / 龙石），可搜索筛选；详情页显示武器等级、射程、数值加成（HP/攻击/技巧…）与可用职业列表
- **肖像浏览**：枚举全部角色肖像，按 sheet 拼装 96×80 正脸，另可看半目/闭眼、嘴型帧、32×32 地图头像与 80×80 职业卡（只读，自动适配 FE6/FE7/FE8 三种数据布局与 LZ77）
- **文本查看器**：枚举全部对话文本，控制码渲染为可读符号，支持搜索；自动适配三种文本引擎（标准 Huffman+SJIS / 明文 GBK 汉化 / Huffman+中文码表汉化）
- **十六进制编辑器**：按地址查看与修改任意字节、按十六进制搜索
- **空位搜索**：查找连续 FF/00 空白区
- **补丁库**：内置 115 个 FEBuilderGBA 社区补丁，一键安装 / 撤销 / 搜索
- **导出**：改后 GBA、UPS 补丁（推荐）、IPS 补丁（16MB 内），走系统「另存为」

## 构建

```bash
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-arm64
export PATH="$PATH:/root/.local/flutter-3.27.4/bin"
flutter build apk --release --target-platform android-arm64
```

测试：`flutter test`（需要 `~/workspace/game-rom/` 下有真实 ROM 样本）。

## 许可与致谢

本项目代码独立实现。FE6/FE7/FE8 地址表数据参考 [FEBuilderGBA](https://github.com/FEBuilderGBA/FEBuilderGBA)（GPL-3.0，7743 著）；内置补丁与中文码表（`.tbl`）提取自其发行数据，补丁版权归各补丁原作者（见补丁详情页 AUTHOR 字段）。仅用于修改自己合法拥有的 ROM。
