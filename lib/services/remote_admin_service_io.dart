import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Web 管理服务回调（只使用基础类型，Web 占位实现中保持同名镜像定义）
class RemoteAdminHooks {
  /// 返回当前全部配置快照：
  /// {playLists:[...], currentPlaylistId, epgs:[...], currentEpgId}
  final Future<Map<String, dynamic>> Function() getSnapshot;

  /// 手机端保存全量配置（增删改后的列表 + 当前选中项）
  final Future<void> Function(Map<String, dynamic> data) applySnapshot;

  /// 请求重新拉取：kind = playlists / epgs
  final Future<void> Function(String kind) refresh;

  const RemoteAdminHooks({
    required this.getSnapshot,
    required this.applySnapshot,
    required this.refresh,
  });
}

/// 局域网 Web 管理服务
/// 手机扫码/浏览器打开后，可以在手机上增删改直播源与 EPG。
/// 仅监听本机网卡（默认 8963 端口，占用则自动顺延），不主动访问外网。
class RemoteAdminService {
  HttpServer? _server;
  String _ip = '127.0.0.1';
  int _port = 0;
  RemoteAdminHooks? _hooks;

  bool get isRunning => _server != null;
  String get endpoint =>
      _server == null ? '' : 'http://$_ip:$_port';

  Future<void> start({required RemoteAdminHooks hooks}) async {
    if (_server != null) return;
    _hooks = hooks;
    HttpServer? server;
    // 8963 起，被占用则向后试 9 个端口
    for (var p = 8963; p < 8973 && server == null; p++) {
      try {
        server = await HttpServer.bind(InternetAddress.anyIPv4, p);
      } catch (_) {
        server = null;
      }
    }
    if (server == null) return;
    _server = server;
    _port = server.port;
    _ip = await _localIp();
    server.listen(_handle);
  }

  void stop() {
    _server?.close(force: true);
    _server = null;
    _port = 0;
  }

  Future<void> _handle(HttpRequest req) async {
    // 简单 CORS：桌面场景可能被本机页面调用
    req.response.headers
      ..add('Access-Control-Allow-Origin', '*')
      ..add('Access-Control-Allow-Methods', 'GET,POST,OPTIONS')
      ..add('Access-Control-Allow-Headers', 'Content-Type');
    if (req.method == 'OPTIONS') {
      req.response.statusCode = 204;
      await req.response.close();
      return;
    }

    final path = req.uri.path;
    try {
      if (req.method == 'GET' && path == '/') {
        req.response.headers.contentType =
            ContentType('text', 'html', charset: 'utf-8');
        req.response.headers
          ..add('Cache-Control', 'no-store, must-revalidate')
          ..add('Pragma', 'no-cache');
        req.response.write(_adminHtml);
      } else if (req.method == 'GET' && path == '/api/snapshot') {
        final data = await _hooks!.getSnapshot();
        _json(req, data);
      } else if (req.method == 'POST' && path == '/api/snapshot') {
        final body = await utf8.decoder.bind(req).join();
        final data = jsonDecode(body) as Map<String, dynamic>;
        await _hooks!.applySnapshot(data);
        _json(req, {'ok': true});
      } else if (req.method == 'POST' && path == '/api/refresh') {
        final body = await utf8.decoder.bind(req).join();
        final kind = (jsonDecode(body) as Map)['kind']?.toString() ?? '';
        await _hooks!.refresh(kind);
        _json(req, {'ok': true});
      } else {
        req.response.statusCode = 404;
        req.response.write('not found');
      }
    } catch (e) {
      req.response.statusCode = 500;
      _json(req, {'ok': false, 'error': '$e'});
    } finally {
      await req.response.close();
    }
  }

  void _json(HttpRequest req, Object data) {
    req.response.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    req.response.write(jsonEncode(data));
  }

  Future<String> _localIp() async {
    try {
      final ifs = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
      String best = '';
      var bestScore = -1;
      for (final i in ifs) {
        final name = i.name.toLowerCase();
        final isVirtual = name.contains('virtual') ||
            name.contains('vmware') ||
            name.contains('hyper-v') ||
            name.contains('vethernet') ||
            name.contains('wsl') ||
            name.contains('docker') ||
            name.contains('vbox');
        for (final a in i.addresses) {
          if (a.isLoopback) continue;
          final addr = a.address;
          var score = 0;
          if (addr.startsWith('192.168.')) {
            score = 100;
          } else if (addr.startsWith('10.')) {
            score = 80;
          } else if (addr.startsWith('172.')) {
            score = 60;
          } else {
            score = 10;
          }
          if (isVirtual) score -= 50;
          if (score > bestScore) {
            bestScore = score;
            best = addr;
          }
        }
      }
      return best.isEmpty ? '127.0.0.1' : best;
    } catch (_) {
      return '127.0.0.1';
    }
  }
}

/// 手机管理页（单文件，原生 JS，无外部依赖）。
/// 视觉与兼容性说明：
/// - 不使用 CSS Grid（旧版微信 X5 内核对 grid 支持差，会把整页挤成
///   竖条）；按钮用 flex-basis:calc() 固定等分，white-space:nowrap
///   防止文字竖排
/// - 所有滚动/固定布局只用 flex 与固定定位，并给 -webkit- 前缀
const _adminHtml = r'''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
<meta name="format-detection" content="telephone=no">
<title>OMPlayer 直播源管理</title>
<style>
*{box-sizing:border-box;margin:0;padding:0;-webkit-tap-highlight-color:transparent}
html{-webkit-text-size-adjust:100%}
body{
  font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Microsoft YaHei",sans-serif;
  background:#0d0f14;
  background-image:-webkit-linear-gradient(180deg,#12151d 0,#0d0f14 320px);
  color:#e8eaed;
  padding-bottom:calc(96px + env(safe-area-inset-bottom));
  -webkit-font-smoothing:antialiased;
}
button{font-family:inherit;cursor:pointer;-webkit-appearance:none;appearance:none}
.top{
  position:-webkit-sticky;position:sticky;top:0;z-index:20;
  background:rgba(18,21,29,.96);
  -webkit-backdrop-filter:blur(8px);backdrop-filter:blur(8px);
  border-bottom:1px solid #232838;
  padding:calc(12px + env(safe-area-inset-top)) 16px 12px;
}
.brand{display:-webkit-flex;display:flex;-webkit-align-items:center;align-items:center}
.logo{
  width:34px;height:34px;border-radius:9px;margin-right:10px;-webkit-flex:0 0 auto;flex:0 0 auto;
  background:-webkit-linear-gradient(135deg,#3b82f6,#2563eb);
  display:-webkit-flex;display:flex;-webkit-align-items:center;align-items:center;-webkit-justify-content:center;justify-content:center;
  font-size:18px;font-weight:700;color:#fff;
  -webkit-box-shadow:0 3px 10px rgba(37,99,235,.35);box-shadow:0 3px 10px rgba(37,99,235,.35);
}
.brand .titles{-webkit-flex:1 1 auto;flex:1 1 auto;min-width:0}
.brand h1{font-size:17px;font-weight:600;letter-spacing:.2px;line-height:1.25}
.brand .sub{font-size:11.5px;color:#7e879c;margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.brand .sub b{color:#9fb2e8;font-weight:500}
.seg-tabs{
  display:-webkit-flex;display:flex;
  margin-top:12px;background:#0c0e13;border:1px solid #222736;border-radius:11px;padding:3px;
}
.seg-tabs button{
  -webkit-flex:1 1 0;flex:1 1 0;min-width:0;
  padding:9px 0;border:none;border-radius:8px;
  background:transparent;color:#8b93a5;font-size:14px;font-weight:500;
  -webkit-transition:background .15s,color .15s;transition:background .15s,color .15s;
}
.seg-tabs button.on{background:#2563eb;color:#fff;font-weight:600}
.wrap{padding:14px 14px 0}
.card{
  background:#161a23;border:1px solid #232a3a;border-radius:14px;
  padding:14px 14px 12px;margin-bottom:12px;
  -webkit-box-shadow:0 2px 10px rgba(0,0,0,.25);box-shadow:0 2px 10px rgba(0,0,0,.25);
}
.card.is-cur{border-color:#27583c;background:#151d22}
.card-head{display:-webkit-flex;display:flex;-webkit-align-items:center;align-items:center}
.card .name{
  -webkit-flex:1 1 auto;flex:1 1 auto;min-width:0;
  font-size:16px;font-weight:600;line-height:1.35;
  white-space:nowrap;overflow:hidden;text-overflow:ellipsis;
}
.badge{
  -webkit-flex:0 0 auto;flex:0 0 auto;margin-left:8px;
  font-size:11px;font-weight:600;color:#5fd993;
  border:1px solid #27583c;background:#123524;
  padding:3px 9px;border-radius:99px;white-space:nowrap;
}
.url{
  margin-top:9px;padding:8px 10px;border-radius:8px;
  background:#0e1118;border:1px solid #1e2433;
  font-size:12px;color:#93a0b8;line-height:1.55;
  word-break:break-all;
  font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
}
.meta{margin-top:8px;font-size:11.5px;color:#62708e;line-height:1.5}
.meta .tag{display:inline-block;color:#8ea0cc;margin-right:6px}
.acts{display:-webkit-flex;display:flex;margin-top:12px}
.acts+.acts{margin-top:8px}
.btn{
  height:40px;border-radius:9px;border:1px solid #2b3242;background:#1d2330;
  color:#cfd6e6;font-size:13.5px;font-weight:500;
  display:-webkit-flex;display:flex;-webkit-align-items:center;align-items:center;-webkit-justify-content:center;justify-content:center;
  white-space:nowrap;overflow:hidden;
  -webkit-transition:background .12s;transition:background .12s;
}
.btn:active{background:#283144}
.acts .b3{-webkit-flex:0 0 calc((100% - 16px)/3);flex:0 0 calc((100% - 16px)/3);min-width:0;margin-right:8px}
.acts .b3:last-child{-webkit-flex:1 1 0;flex:1 1 0;margin-right:0}
.acts .b2{-webkit-flex:0 0 calc((100% - 8px)/2);flex:0 0 calc((100% - 8px)/2);min-width:0;margin-right:8px}
.acts .b2:last-child{margin-right:0}
.btn.ok{background:#153d28;border-color:#1f5d3c;color:#62e39b}
.btn.ok:active{background:#1b4d32}
.btn.danger{background:#351c23;border-color:#5b2733;color:#ff8a95}
.btn.danger:active{background:#47222c}
.group-title{font-size:12px;color:#7e879c;margin:4px 2px 9px;font-weight:600;letter-spacing:.5px}
.sw-row{
  display:-webkit-flex;display:flex;-webkit-align-items:center;align-items:center;
  background:#161a23;border:1px solid #232a3a;border-radius:14px;
  padding:14px 14px;margin-bottom:10px;
}
.sw-row:active{background:#1a1f2b}
.sw-text{-webkit-flex:1 1 auto;flex:1 1 auto;min-width:0;padding-right:12px}
.sw-title{font-size:15px;color:#e8eaed;font-weight:500;line-height:1.3}
.sw-sub{font-size:11.5px;color:#6b7488;margin-top:3px;line-height:1.4}
.sw-track{
  -webkit-flex:0 0 auto;flex:0 0 auto;
  width:46px;height:27px;border-radius:99px;background:#2c3344;
  position:relative;-webkit-transition:background .15s;transition:background .15s;
}
.sw-track .sw-thumb{
  position:absolute;top:3px;left:3px;width:21px;height:21px;border-radius:50%;
  background:#fff;
  -webkit-transition:left .15s;transition:left .15s;
  -webkit-box-shadow:0 1px 3px rgba(0,0,0,.4);box-shadow:0 1px 3px rgba(0,0,0,.4);
}
.sw-track.on{background:#2563eb}
.sw-track.on .sw-thumb{left:22px}
.set-hint{font-size:11.5px;color:#55607a;margin:2px 2px 0;line-height:1.6}
.fab{
  position:fixed;right:18px;
  bottom:calc(20px + env(safe-area-inset-bottom));
  width:54px;height:54px;border-radius:50%;
  border:none;color:#fff;font-size:30px;line-height:54px;text-align:center;
  background:-webkit-linear-gradient(135deg,#3b82f6,#2563eb);
  -webkit-box-shadow:0 8px 22px rgba(37,99,235,.45);box-shadow:0 8px 22px rgba(37,99,235,.45);
  z-index:30;padding:0;
}
.fab:active{-webkit-transform:scale(.94);transform:scale(.94)}
.sheet-mask{
  position:fixed;top:0;right:0;bottom:0;left:0;background:rgba(0,0,0,.62);
  display:none;-webkit-align-items:flex-end;align-items:flex-end;z-index:50;
}
.sheet-mask.show{display:-webkit-flex;display:flex}
.sheet{
  background:#161a23;width:100%;
  border-radius:20px 20px 0 0;
  padding:8px 16px calc(18px + env(safe-area-inset-bottom));
  max-height:88vh;overflow:auto;-webkit-overflow-scrolling:touch;
}
.handle{width:38px;height:4px;border-radius:2px;background:#333b4d;margin:6px auto 2}
.sheet h2{font-size:17px;margin:8px 0 12px;font-weight:600}
label{display:block;font-size:13px;color:#98a2b8;margin:12px 0 7px}
input{
  width:100%;padding:13px;border-radius:11px;
  border:1px solid #2a3040;background:#0f131b;color:#e8eaed;font-size:15px;
  -webkit-appearance:none;appearance:none;outline:none;
}
input:focus{border-color:#3b82f6}
.seg{display:-webkit-flex;display:flex}
.seg button+button{margin-left:8px}
.seg button{
  -webkit-flex:1 1 0;flex:1 1 0;min-width:0;
  padding:11px 0;border-radius:10px;border:1px solid #2a3040;
  background:#0f131b;color:#98a2b8;font-size:14px;white-space:nowrap;
}
.seg button.on{background:#2563eb;border-color:#2563eb;color:#fff;font-weight:600}
.sheet-actions{display:-webkit-flex;display:flex;margin-top:20px}
.sheet-actions .btn+.btn{margin-left:10px}
.sheet-actions .btn{-webkit-flex:1 1 0;flex:1 1 0;height:46px;font-size:15.5px;border-radius:11px}
.btn.primary{background:#2563eb;border-color:#2563eb;color:#fff}
.btn.primary:active{background:#1d4ed8}
.empty{text-align:center;color:#6b7488;padding:72px 24px;font-size:14px;line-height:1.7}
.empty .ic{
  width:64px;height:64px;border-radius:18px;margin:0 auto 16px;
  background:#161a23;border:1px solid #232a3a;
  display:-webkit-flex;display:flex;-webkit-align-items:center;align-items:center;-webkit-justify-content:center;justify-content:center;
  font-size:28px;color:#3d475c;
}
.loading{text-align:center;color:#6b7488;padding:72px 0;font-size:14px}
.toast{
  position:fixed;left:50%;bottom:calc(104px + env(safe-area-inset-bottom));
  -webkit-transform:translateX(-50%);transform:translateX(-50%);
  background:rgba(22,26,35,.97);padding:11px 20px;border-radius:99px;
  font-size:14px;display:none;z-index:80;border:1px solid #2d3547;
  white-space:nowrap;max-width:88%;overflow:hidden;text-overflow:ellipsis;
}
</style>
</head>
<body>
<div class="top">
  <div class="brand">
    <div class="logo">OM</div>
    <div class="titles">
      <h1>直播源管理</h1>
      <div class="sub">同 Wi-Fi 下使用 · <b id="host"></b> · 自动保存</div>
    </div>
  </div>
  <div class="seg-tabs">
    <button id="tab-pl" class="on" onclick="switchTab('pl')">直播源</button>
    <button id="tab-epg" onclick="switchTab('epg')">EPG</button>
    <button id="tab-set" onclick="switchTab('set')">设置</button>
  </div>
</div>
<div class="wrap" id="list"><div class="loading">加载中…</div></div>
<button class="fab" id="fab" aria-label="添加" onclick="openEdit()">+</button>
<div class="sheet-mask" id="mask" onclick="if(event.target===this)closeEdit()">
  <div class="sheet">
    <div class="handle"></div>
    <h2 id="sheet-title">添加</h2>
    <label>名称</label>
    <input id="f-name" placeholder="例如：我的电视">
    <div id="type-wrap">
      <label>类型</label>
      <div class="seg">
        <button id="t-url" class="on" onclick="setType('url')">网络地址</button>
        <button id="t-local" onclick="setType('local')">本地文件</button>
      </div>
    </div>
    <label id="url-label">地址 URL</label>
    <input id="f-url" placeholder="http://... 或本地文件路径" autocapitalize="off" autocorrect="off">
    <div class="sheet-actions">
      <button class="btn" onclick="closeEdit()">取消</button>
      <button class="btn primary" onclick="saveEdit()">保存</button>
    </div>
  </div>
</div>
<div class="toast" id="toast"></div>
<script>
var hostEl=document.getElementById('host');
hostEl.textContent=location.host||'OMPlayer';
var state={playlists:[],epgs:[],currentPlaylistId:null,currentEpgId:null,settings:{}};
var tab='pl', editing=null, editType='url';
function esc(s){return String(s==null?'':s).replace(/[&<>"]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]})}
function findById(arr,id){for(var i=0;i<arr.length;i++)if(arr[i].id===id)return arr[i];return null}
function load(){
  fetch('/api/snapshot').then(function(r){return r.json()}).then(function(d){state=d;render()})
    .catch(function(){document.getElementById('list').innerHTML='<div class="empty"><div class="ic">!</div>加载失败<br>请确认手机与电脑在同一 Wi-Fi</div>'});
}
function switchTab(t){
  tab=t;
  document.getElementById('tab-pl').className=t==='pl'?'on':'';
  document.getElementById('tab-epg').className=t==='epg'?'on':'';
  document.getElementById('tab-set').className=t==='set'?'on':'';
  // 设置页没有添加操作，隐藏右下角 FAB
  document.getElementById('fab').style.display=t==='set'?'none':'block';
  render();
}
function fmtTime(iso){
  if(!iso)return '';
  var d=new Date(iso),p=function(n){return(n<10?'0':'')+n};
  return d.getFullYear()+'/'+p(d.getMonth()+1)+'/'+p(d.getDate())+' '+p(d.getHours())+':'+p(d.getMinutes());
}
function render(){
  if(tab==='set'){renderSettings();return}
  var items=tab==='pl'?state.playlists:state.epgs;
  var curId=tab==='pl'?state.currentPlaylistId:state.currentEpgId;
  var el=document.getElementById('list');
  if(!items.length){
    el.innerHTML='<div class="empty"><div class="ic">+</div>暂无'+(tab==='pl'?'直播源':'节目单')+'<br>点右下角 + 添加</div>';
    return;
  }
  var html='';
  for(var i=0;i<items.length;i++){
    var it=items[i], cur=it.id===curId;
    var meta='';
    if(tab==='pl'){
      meta='<div class="meta"><span class="tag">'+(it.type==='local'?'本地文件':'网络地址')+'</span>自动识别格式'
        +(it.lastUpdated?' · 更新 '+fmtTime(it.lastUpdated):'')+'</div>';
    }
    var row1='',row2='';
    if(!cur)row1+='<button class="btn ok b3" onclick="selectItem(\''+it.id+'\')">设为当前</button>';
    var rc=cur?'b2':'b3';
    row1+='<button class="btn '+rc+'" onclick="refreshItem()">刷新</button>'
      +'<button class="btn '+rc+'" onclick="copyItem(\''+it.id+'\')">复制</button>';
    row2='<button class="btn b2" onclick="openEdit(\''+it.id+'\')">编辑</button>'
      +'<button class="btn danger b2" onclick="delItem(\''+it.id+'\')">删除</button>';
    html+='<div class="card'+(cur?' is-cur':'')+'">'
      +'<div class="card-head"><div class="name">'+esc(it.name)+'</div>'
      +(cur?'<span class="badge">播放中</span>':'')+'</div>'
      +'<div class="url">'+esc(it.url)+'</div>'+meta
      +'<div class="acts">'+row1+'</div>'
      +'<div class="acts">'+row2+'</div></div>';
  }
  el.innerHTML=html;
}
// 设置页开关定义：[key, 标题, 说明, 是否仅桌面端]
function settingDefs(){
  return [
    ['showClock','显示时间','右上角常驻显示系统时钟',false],
    ['autoPlayNext','自动播放下一台','当前频道结束后自动切到下一频道',false],
    ['startFullscreen','启动即全屏','程序启动后直接进入全屏',false],
    ['dlnaEnabled','DLNA 投屏接收','允许手机/其它设备投屏到本机',false],
    ['alwaysOnTop','窗口置顶','桌面端保持播放器窗口在最前',true],
    ['launchAtStartup','开机自启动','登录系统后自动启动 OMPlayer',true]
  ];
}
function renderSettings(){
  var el=document.getElementById('list');
  var s=state.settings||{};
  var html='<div class="group-title">常用开关</div>';
  var defs=settingDefs();
  for(var i=0;i<defs.length;i++){
    var d=defs[i];
    if(d[3]&&s.isDesktop===false)continue;
    var on=s[d[0]]===true;
    html+='<div class="sw-row" onclick="toggleSetting(\''+d[0]+'\')">'
      +'<div class="sw-text"><div class="sw-title">'+d[1]+'</div>'
      +'<div class="sw-sub">'+d[2]+'</div></div>'
      +'<div class="sw-track'+(on?' on':'')+'"><div class="sw-thumb"></div></div></div>';
  }
  html+='<div class="set-hint">修改即时生效并自动保存。更多设置请在设备上打开「设置」面板。</div>';
  el.innerHTML=html;
}
function toggleSetting(key){
  if(!state.settings)state.settings={};
  state.settings[key]=!state.settings[key];
  persist().then(function(){
    render();
    toast('已'+(state.settings[key]?'开启':'关闭'));
  });
}
function setType(t){
  editType=t;
  document.getElementById('t-url').className=t==='url'?'on':'';
  document.getElementById('t-local').className=t==='local'?'on':'';
  document.getElementById('url-label').textContent=t==='url'?'地址 URL':'本地文件完整路径';
}
function openEdit(id){
  editing=id||null;
  var items=tab==='pl'?state.playlists:state.epgs;
  var it=findById(items,id);
  document.getElementById('sheet-title').textContent=it?'编辑':'添加'+(tab==='pl'?'直播源':'EPG');
  document.getElementById('type-wrap').style.display=tab==='pl'?'block':'none';
  document.getElementById('f-name').value=it?it.name:'';
  document.getElementById('f-url').value=it?it.url:'';
  if(tab==='pl') setType(it?(it.type||'url'):'url');
  document.getElementById('mask').className='sheet-mask show';
}
function closeEdit(){document.getElementById('mask').className='sheet-mask'}
function persist(){
  return fetch('/api/snapshot',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(state)});
}
function saveEdit(){
  var name=document.getElementById('f-name').value.trim();
  var url=document.getElementById('f-url').value.trim();
  if(!name||!url){toast('请填写名称和地址');return}
  var items=tab==='pl'?state.playlists:state.epgs;
  var it=findById(items,editing);
  if(it){it.name=name;it.url=url;if(tab==='pl')it.type=editType;}
  else{
    var id=String(Date.now())+String(Math.floor(Math.random()*1000));
    if(tab==='pl'){state.playlists.push({id:id,name:name,url:url,type:editType,format:'unknown',addedAt:new Date().toISOString()});
      if(!state.currentPlaylistId)state.currentPlaylistId=id;}
    else{state.epgs.push({id:id,name:name,url:url,addedAt:new Date().toISOString()});
      if(!state.currentEpgId)state.currentEpgId=id;}
  }
  persist().then(function(){closeEdit();load();toast('已保存')});
}
function delItem(id){
  if(!confirm('确定删除？'))return;
  if(tab==='pl'){state.playlists=state.playlists.filter(function(x){return x.id!==id});if(state.currentPlaylistId===id)state.currentPlaylistId=null;}
  else{state.epgs=state.epgs.filter(function(x){return x.id!==id});if(state.currentEpgId===id)state.currentEpgId=null;}
  persist().then(function(){load();toast('已删除')});
}
function selectItem(id){
  if(tab==='pl')state.currentPlaylistId=id;else state.currentEpgId=id;
  persist().then(function(){
    load();
    fetch('/api/refresh',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({kind:tab==='pl'?'playlists':'epgs'})});
    toast('已切换');
  });
}
function refreshItem(){
  fetch('/api/refresh',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({kind:tab==='pl'?'playlists':'epgs'})});
  toast('已通知电脑刷新');
}
function copyItem(id){
  var items=tab==='pl'?state.playlists:state.epgs;
  var it=findById(items,id);
  var text=it.name+'\n'+it.url;
  if(navigator.clipboard&&navigator.clipboard.writeText){navigator.clipboard.writeText(text).then(function(){toast('名称和地址已复制')})}
  else{var ta=document.createElement('textarea');ta.value=text;document.body.appendChild(ta);ta.select();document.execCommand('copy');ta.remove();toast('已复制')}
}
var toastTimer;
function toast(msg){var t=document.getElementById('toast');t.textContent=msg;t.style.display='block';clearTimeout(toastTimer);toastTimer=setTimeout(function(){t.style.display='none'},1800)}
load();
</script>
</body>
</html>
''';
