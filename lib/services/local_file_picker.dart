// 条件导出：Web 端浏览器沙箱不支持本地文件路径，
// 桌面/移动端可通过系统文件选择器拿到绝对路径。
export 'local_file_picker_stub.dart'
    if (dart.library.io) 'local_file_picker_io.dart';
