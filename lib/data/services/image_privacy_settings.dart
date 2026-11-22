/// 全局图片隐私设置：供导出管道（含 agent 工具路径）读取。
class ImagePrivacySettings {
  ImagePrivacySettings._();

  /// 保存/导出图片时是否清除 Alpha LSB 隐写。
  static bool stripStealth = false;

  /// 保存/导出图片时是否清除 PNG 文本块。
  static bool stripMetadata = false;
}
