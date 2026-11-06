/// 测试用的真实 ROM 目录。
///
/// 测试直接读 `game-rom/` 里的真实 ROM —— 这是本项目最核心的验证手段。
/// ROM 有版权，不进仓库，所以路径由使用者在跑测试时指定：
///
/// ```bash
/// flutter test --dart-define=FE_ROM_DIR=/path/to/game-rom
/// ```
///
/// 不指定时用 `../game-rom`（`flutter test` 的工作目录是工程根）。
///
/// 写成 `const` 是刻意的：各测试文件用它拼路径的那些声明仍是 const，
/// 不必改成 final，改动面最小。
const _envRomDir = String.fromEnvironment('FE_ROM_DIR');
const romDir = _envRomDir != '' ? _envRomDir : '../game-rom';
