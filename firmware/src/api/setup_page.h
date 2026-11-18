#pragma once

#include <Arduino.h>

// Telefondan açılan Wi-Fi kurulum sayfası (http://192.168.4.1/).
//
// Güvenlik notları:
//  - Ağ adları (SSID) saldırgan kontrolündedir: yalnızca textContent ile DOM'a yazılır (innerHTML YOK).
//  - Şifre alanı gönderimden sonra temizlenir; hiçbir yere kaydedilmez/loglanmaz (console.log YOK).
//  - Tarama/bağlanma uç noktaları sunucuda yalnızca BOOT penceresi açıkken çalışır ve
//    `X-Setup-Request` başlığı ister (çapraz kaynaklı istekler CORS ile engellenir).
static const char SETUP_PAGE_HTML[] PROGMEM = R"HTML(<!doctype html>
<html lang="tr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>ESP32 ARGB Kurulum</title>
<style>
:root{color-scheme:dark}
*{box-sizing:border-box}
body{margin:0;font:16px system-ui,sans-serif;background:#0a0e21;color:#fff;padding:16px;max-width:560px;margin:auto}
h1{font-size:20px;margin:4px 0 12px}
.card{background:#1c1e2d;border-radius:14px;padding:14px;margin:12px 0;border:1px solid #ffffff14}
.note{background:#ffab4020;border:1px solid #ffab4080}
.ok{background:#00e67620;border:1px solid #00e67680}
.err{background:#ff525220;border:1px solid #ff525280}
ol{margin:6px 0 0 18px;padding:0}li{margin:6px 0}
button{width:100%;padding:13px;border:0;border-radius:12px;background:#6c63ff;color:#fff;font-size:16px;font-weight:600;margin-top:8px}
button:disabled{opacity:.4}
button.sec{background:#252842}
.net{display:flex;justify-content:space-between;align-items:center;padding:12px;border-radius:10px;background:#252842;margin:6px 0;cursor:pointer}
.net.sel{outline:2px solid #6c63ff}
.net small{color:#b0b3c5}
input[type=text],input[type=password]{width:100%;padding:12px;border-radius:10px;border:1px solid #ffffff30;background:#0a0e21;color:#fff;font-size:16px;margin-top:6px}
label{display:block;margin-top:10px;font-size:14px;color:#b0b3c5}
.row{display:flex;gap:8px;align-items:center;margin-top:8px;font-size:14px}
#ip{font-size:26px;font-weight:700;text-align:center;margin:8px 0}
.hide{display:none}
</style></head><body>
<h1>ESP32 ARGB Wi-Fi Kurulumu</h1>

<div id="win" class="card note"></div>

<div class="card">
<b>İlk kurulum adımları</b>
<ol>
<li>ESP32 üzerindeki <b>BOOT</b> düğmesine <b>3 saniye</b> basılı tutup bırakın. Mavi LED hızlı yanıp söner; kurulum penceresi <b>120 saniye</b> açık kalır.</li>
<li><b>Ağları Tara</b>'ya basın ve evinizdeki 2.4&nbsp;GHz Wi-Fi ağını seçin.</li>
<li>Şifreyi girip <b>Bağlan</b>'a basın. ESP32 bağlanınca aldığı IP adresi burada görünür.</li>
</ol>
<small>Güvenlik: Wi-Fi ayarı yalnızca cihaza fiziksel erişimle (BOOT) değiştirilebilir.</small>
</div>

<div id="scanBox" class="card">
<button id="scan" disabled>Ağları Tara</button>
<div id="list"></div>
<button id="hiddenBtn" class="sec">Gizli ağ / SSID'yi elle gir</button>
</div>

<div id="form" class="card hide">
<label>Ağ adı (SSID)<input id="ssid" type="text" maxlength="32" autocomplete="off" autocapitalize="off" spellcheck="false"></label>
<div id="pwWrap"><label>Wi-Fi şifresi<input id="pw" type="password" maxlength="63" autocomplete="off" spellcheck="false"></label>
<div class="row"><input id="show" type="checkbox"><span>Şifreyi göster</span></div></div>
<div class="row hide" id="openRow"><input id="open" type="checkbox"><span>Bu ağ açık (şifresiz)</span></div>
<button id="connect">Bağlan</button>
</div>

<div id="msg" class="card hide"></div>

<script>
(function(){
var $=function(i){return document.getElementById(i)};
var selOpen=false,hidden=false,connecting=false,startedAt=0,winOpen=false,scanTimer=null;
var ERR={auth_failed:"Wi-Fi şifresi yanlış görünüyor.",not_found:"Ağ bulunamadı. ESP32 yalnızca 2.4 GHz ağları görür.",timeout:"Bağlantı zaman aşımına uğradı."};
function api(path,opt){opt=opt||{};opt.headers=Object.assign({"X-Setup-Request":"1"},opt.headers||{});
return fetch(path,opt).then(function(r){return r.json().catch(function(){return {}}).then(function(j){return {ok:r.ok,status:r.status,j:j}})})}
function show(cls,text){var m=$("msg");m.className="card "+cls;m.textContent="";var p=document.createElement("div");p.textContent=text;m.appendChild(p);return m}
function bars(r){return r>=-55?"▂▄▆█":r>=-65?"▂▄▆░":r>=-75?"▂▄░░":r>=-85?"▂░░░":"░░░░"}
function status(){return api("/setup/status").then(function(r){
 var s=r.j||{};winOpen=!!s.window;var w=$("win");
 if(winOpen){w.className="card ok";w.textContent="Kurulum penceresi AÇIK ("+Math.ceil((s.remainingMs||0)/1000)+" sn kaldı)."}
 else{w.className="card note";w.textContent="Kurulum penceresi KAPALI. ESP32 üzerindeki BOOT düğmesine 3 saniye basılı tutup bırakın."}
 $("scan").disabled=!winOpen||connecting;
 if(connecting){
  if(s.state==="connected"&&s.ip){connecting=false;done(s)}
  else if(s.state==="failed"&&Date.now()-startedAt>2500){connecting=false;fail(ERR[s.error]||"Bağlantı kurulamadı.")}
  else if(Date.now()-startedAt>70000){connecting=false;fail(ERR.timeout)}
 }
 }).catch(function(){
  if(connecting&&Date.now()-startedAt>4000){show("note","ESP32 ile bağlantı kesildi. Bağlantı kurulurken kurulum ağı kapanabilir. Telefonunuzu ev Wi-Fi ağına bağlayıp uygulamadan ESP32'yi bulun (esp32-argb.local).")}
 })}
function done(s){var m=show("ok","ESP32 Wi-Fi ağına bağlandı ve bilgiler kaydedildi.");
 var a=document.createElement("div");a.id="ip";a.textContent=s.ip;m.appendChild(a);
 var t=document.createElement("div");t.textContent="Ağ: "+(s.ssid||"");m.appendChild(t);
 var n=document.createElement("small");n.textContent="Kurulum ağı kısa süre sonra kapanır. Telefonunuzu ev Wi-Fi ağına bağlayın ve uygulamadan ESP32'yi bulun veya http://"+s.ip+" adresini kullanın.";m.appendChild(n);
 $("form").className="card hide";$("scanBox").className="card hide"}
function fail(text){var m=show("err",text);var b=document.createElement("button");b.textContent="Tekrar dene";
 b.onclick=function(){$("msg").className="card hide";$("form").className="card";$("pw").focus()};m.appendChild(b)}
function renderList(nets){var l=$("list");l.textContent="";
 if(!nets.length){var e=document.createElement("div");e.textContent="Hiç ağ bulunamadı. ESP32'yi modeme yaklaştırıp tekrar tarayın.";l.appendChild(e);return}
 var best={};nets.forEach(function(n){if(!n.ssid)return;if(!best[n.ssid]||n.rssi>best[n.ssid].rssi)best[n.ssid]=n});
 Object.keys(best).map(function(k){return best[k]}).sort(function(a,b){return b.rssi-a.rssi}).forEach(function(n){
  var d=document.createElement("div");d.className="net";var left=document.createElement("div");
  var nm=document.createElement("div");nm.textContent=n.ssid;var sub=document.createElement("small");
  var open=n.security==="OPEN",ent=n.security==="WPA2_ENTERPRISE";
  sub.textContent=(open?"Açık ağ":n.security.replace(/_/g," "))+(ent?" • desteklenmiyor":"");
  left.appendChild(nm);left.appendChild(sub);var sg=document.createElement("span");sg.textContent=bars(n.rssi);
  d.appendChild(left);d.appendChild(sg);
  if(!ent)d.onclick=function(){pick(n.ssid,open)};else d.style.opacity=".4";
  l.appendChild(d)})}
function pick(ssid,open){hidden=false;selOpen=open;$("ssid").value=ssid;$("ssid").readOnly=true;$("pw").value="";
 $("pwWrap").className=open?"hide":"";$("openRow").className="row hide";$("open").checked=open;
 $("form").className="card";$("msg").className="card hide";$("pw").focus()}
$("hiddenBtn").onclick=function(){hidden=true;selOpen=false;$("ssid").value="";$("ssid").readOnly=false;$("pw").value="";
 $("pwWrap").className="";$("openRow").className="row";$("open").checked=false;$("form").className="card";$("msg").className="card hide";$("ssid").focus()};
$("open").onchange=function(){$("pwWrap").className=$("open").checked?"hide":""};
$("show").onchange=function(){$("pw").type=$("show").checked?"text":"password"};
$("scan").onclick=function(){if(!winOpen)return;$("scan").disabled=true;$("list").textContent="Ağlar taranıyor…";
 api("/setup/scan",{method:"POST"}).then(function(r){if(!r.ok){$("list").textContent="";show("err",r.status===403?"Kurulum penceresi kapalı. BOOT düğmesine tekrar basın.":"Tarama başlatılamadı.");return}
  var tries=0;clearInterval(scanTimer);scanTimer=setInterval(function(){tries++;
   api("/setup/scan").then(function(q){var j=q.j||{};
    if(!q.ok){clearInterval(scanTimer);$("list").textContent="";return}
    if(j.status==="done"){clearInterval(scanTimer);renderList(j.networks||[]);$("scan").disabled=!winOpen}
    else if(tries>55){clearInterval(scanTimer);$("list").textContent="Tarama zaman aşımına uğradı.";$("scan").disabled=!winOpen}})},1000)})};
$("connect").onclick=function(){var ssid=$("ssid").value;var pass=($("open").checked||selOpen)?"":$("pw").value;
 if(!ssid){show("err","Ağ adı gerekli.");return}
 if(pass&&(pass.length<8||pass.length>63)){show("err","WPA şifresi 8 ile 63 karakter arasında olmalı.");return}
 $("pw").value="";connecting=true;startedAt=Date.now();show("note","ESP32 ağa bağlanıyor ve IP alıyor…");
 api("/setup/connect",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({ssid:ssid,password:pass})}).then(function(r){
  pass="";if(!r.ok){connecting=false;fail(r.status===403?"Kurulum penceresi kapalı. BOOT düğmesine tekrar basın.":"İstek reddedildi ("+((r.j&&r.j.code)||r.status)+").")}})
 .catch(function(){})};
status();setInterval(status,1200);
})();
</script></body></html>)HTML";
