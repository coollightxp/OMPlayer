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

/// 手机管理页（单文件，原生 JS，无外部依赖）
const _adminHtml = r'''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
<title>OMPlayer 直播源管理</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,"PingFang SC","Microsoft YaHei",sans-serif;background:#0f1115;color:#e8eaed;padding-bottom:90px}
header{position:sticky;top:0;background:#161a22;padding:14px 16px;border-bottom:1px solid #262b36;z-index:10}
header h1{font-size:17px;font-weight:600}
header .sub{font-size:12px;color:#8b93a5;margin-top:2px}
.tabs{display:flex;gap:8px;padding:12px 16px 0}
.tabs button{flex:1;padding:10px;border:1px solid #2a3040;background:#161a22;color:#aab2c5;border-radius:10px;font-size:15px}
.tabs button.on{background:#2563eb;border-color:#2563eb;color:#fff}
.wrap{padding:12px 16px}
.card{background:#161a22;border:1px solid #232838;border-radius:12px;padding:14px;margin-bottom:10px}
.card .name{font-size:16px;font-weight:600;word-break:break-all}
.card .url{font-size:12px;color:#8b93a5;margin-top:6px;word-break:break-all;line-height:1.5}
.card .meta{font-size:11px;color:#5f6a85;margin-top:6px}
.row{display:flex;gap:8px;margin-top:10px;flex-wrap:wrap}
.btn{padding:8px 14px;border-radius:8px;border:1px solid #2a3040;background:#1f2532;color:#cfd6e6;font-size:13px}
.btn.primary{background:#2563eb;border-color:#2563eb;color:#fff}
.btn.danger{background:#3a1d24;border-color:#5b2733;color:#ff8a95}
.btn.ok{background:#14301f;border-color:#1f5132;color:#5fd993}
.fab{position:fixed;right:18px;bottom:22px;width:56px;height:56px;border-radius:50%;background:#2563eb;color:#fff;font-size:30px;border:none;box-shadow:0 6px 20px rgba(37,99,235,.4)}
.sheet-mask{position:fixed;inset:0;background:rgba(0,0,0,.6);display:none;align-items:flex-end;z-index:50}
.sheet-mask.show{display:flex}
.sheet{background:#161a22;width:100%;border-radius:18px 18px 0 0;padding:18px 16px calc(18px + env(safe-area-inset-bottom));max-height:88vh;overflow:auto}
.sheet h2{font-size:17px;margin-bottom:14px}
label{display:block;font-size:13px;color:#aab2c5;margin:10px 0 6px}
input,select{width:100%;padding:12px;border-radius:10px;border:1px solid #2a3040;background:#0f131b;color:#e8eaed;font-size:15px}
.seg{display:flex;gap:8px}
.seg button{flex:1;padding:10px;border-radius:10px;border:1px solid #2a3040;background:#0f131b;color:#aab2c5;font-size:14px}
.seg button.on{background:#2563eb;border-color:#2563eb;color:#fff}
.sheet-actions{display:flex;gap:10px;margin-top:18px}
.sheet-actions .btn{flex:1;padding:13px;font-size:15px}
.toast{position:fixed;left:50%;bottom:110px;transform:translateX(-50%);background:rgba(20,24,33,.95);padding:10px 18px;border-radius:10px;font-size:14px;display:none;z-index:80;border:1px solid #2a3040}
.empty{text-align:center;color:#6b7488;padding:60px 20px;font-size:14px}
</style>
</head>
<body>
<header>
  <h1>OMPlayer 直播源管理</h1>
  <div class="sub">与电脑在同一 Wi‑Fi 下使用 · 修改自动保存</div>
</header>
<div class="tabs">
  <button id="tab-pl" class="on" onclick="switchTab('pl')">直播源</button>
  <button id="tab-epg" onclick="switchTab('epg')">EPG 节目单</button>
</header>
<div class="wrap" id="list"></div>
<button class="fab" onclick="openEdit()">+</button>
<div class="sheet-mask" id="mask" onclick="if(event.target===this)closeEdit()">
  <div class="sheet">
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
    <input id="f-url" placeholder="http://... 或本地文件路径">
    <div class="sheet-actions">
      <button class="btn" onclick="closeEdit()">取消</button>
      <button class="btn primary" onclick="saveEdit()">保存</button>
    </div>
  </div>
</div>
<div class="toast" id="toast"></div>
<script>
let state={playlists:[],epgs:[],currentPlaylistId:null,currentEpgId:null};
let tab='pl', editing=null, editType='url';
function esc(s){return String(s==null?'':s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))}
async function load(){
  const r=await fetch('/api/snapshot'); state=await r.json(); render();
}
function switchTab(t){tab=t;document.getElementById('tab-pl').className=t==='pl'?'on':'';document.getElementById('tab-epg').className=t==='epg'?'on':'';render()}
function render(){
  const items=tab==='pl'?state.playlists:state.epgs;
  const curId=tab==='pl'?state.currentPlaylistId:state.currentEpgId;
  const el=document.getElementById('list');
  if(!items.length){el.innerHTML='<div class="empty">暂无内容，点右下角 + 添加</div>';return}
  el.innerHTML=items.map(it=>{
    const cur=it.id===curId;
    const type = tab==='pl' ? '<div class="meta">'+(it.type==='local'?'本地文件':'网络地址')+' · 自动识别格式'+(it.lastUpdated?' · 更新 '+new Date(it.lastUpdated).toLocaleString():'')+'</div>' : '';
    return '<div class="card">'
      +'<div class="name">'+(cur?'<span style="color:#5fd993">● </span>':'')+esc(it.name)+'</div>'
      +'<div class="url">'+esc(it.url)+'</div>'+type
      +'<div class="row">'
      +(cur?'':'<button class="btn ok" onclick="selectItem(\''+it.id+'\')">设为当前</button>')
      +'<button class="btn" onclick="refreshItem()">刷新</button>'
      +'<button class="btn" onclick="copyItem(\''+it.id+'\')">复制</button>'
      +'<button class="btn" onclick="openEdit(\''+it.id+'\')">编辑</button>'
      +'<button class="btn danger" onclick="delItem(\''+it.id+'\')">删除</button>'
      +'</div></div>';
  }).join('');
}
function setType(t){editType=t;document.getElementById('t-url').className=t==='url'?'on':'';document.getElementById('t-local').className=t==='local'?'on':'';
  document.getElementById('url-label').textContent=t==='url'?'地址 URL':'本地文件完整路径';}
function openEdit(id){
  editing=id||null;
  const items=tab==='pl'?state.playlists:state.epgs;
  const it=items.find(x=>x.id===id);
  document.getElementById('sheet-title').textContent=it?'编辑':'添加'+(tab==='pl'?'直播源':'EPG');
  document.getElementById('type-wrap').style.display=tab==='pl'?'block':'none';
  document.getElementById('f-name').value=it?it.name:'';
  document.getElementById('f-url').value=it?it.url:'';
  if(tab==='pl') setType(it?(it.type||'url'):'url');
  document.getElementById('mask').className='sheet-mask show';
}
function closeEdit(){document.getElementById('mask').className='sheet-mask'}
async function persist(){
  await fetch('/api/snapshot',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(state)});
}
async function saveEdit(){
  const name=document.getElementById('f-name').value.trim();
  const url=document.getElementById('f-url').value.trim();
  if(!name||!url){toast('请填写名称和地址');return}
  const items=tab==='pl'?state.playlists:state.epgs;
  const it=items.find(x=>x.id===editing);
  if(it){it.name=name;it.url=url;if(tab==='pl')it.type=editType;}
  else{
    const id=String(Date.now())+String(Math.floor(Math.random()*1000));
    if(tab==='pl'){state.playlists.push({id,name,url,type:editType,format:'unknown',addedAt:new Date().toISOString()});
      if(!state.currentPlaylistId)state.currentPlaylistId=id;}
    else{state.epgs.push({id,name,url,addedAt:new Date().toISOString()});
      if(!state.currentEpgId)state.currentEpgId=id;}
  }
  await persist(); closeEdit(); await load(); toast('已保存');
}
async function delItem(id){
  if(!confirm('确定删除？'))return;
  if(tab==='pl'){state.playlists=state.playlists.filter(x=>x.id!==id);if(state.currentPlaylistId===id)state.currentPlaylistId=null;}
  else{state.epgs=state.epgs.filter(x=>x.id!==id);if(state.currentEpgId===id)state.currentEpgId=null;}
  await persist(); await load(); toast('已删除');
}
async function selectItem(id){
  if(tab==='pl')state.currentPlaylistId=id;else state.currentEpgId=id;
  await persist(); await load();
  await fetch('/api/refresh',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({kind:tab==='pl'?'playlists':'epgs'})});
  toast('已切换');
}
async function refreshItem(){
  await fetch('/api/refresh',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({kind:tab==='pl'?'playlists':'epgs'})});
  toast('已通知电脑刷新');
}
function copyItem(id){
  const items=tab==='pl'?state.playlists:state.epgs;
  const it=items.find(x=>x.id===id);
  const text=it.name+'\n'+it.url;
  if(navigator.clipboard&&navigator.clipboard.writeText){navigator.clipboard.writeText(text).then(()=>toast('名称和地址已复制'))}
  else{const ta=document.createElement('textarea');ta.value=text;document.body.appendChild(ta);ta.select();document.execCommand('copy');ta.remove();toast('已复制')}
}
let toastTimer;
function toast(msg){const t=document.getElementById('toast');t.textContent=msg;t.style.display='block';clearTimeout(toastTimer);toastTimer=setTimeout(()=>t.style.display='none',1800)}
load();
</script>
</body>
</html>
''';
