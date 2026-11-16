#pragma once

#include <Arduino.h>

// Mobil LED kontrol arayüzü (http://<ip>/) — yalnızca ENABLE_WLED_COMPAT ile derlenir.
//
// Tamamen gömülü: CDN, harici betik, yazı tipi yok. Yalnızca cihazın kendi WLED JSON API'sini
// (/json/eff, /json/si, POST /json/state) ve WebSocket'ini (/ws) kullanır; YENİ yazma uç noktası YOKTUR.
// Erişim kuralları sunucudadır (WledCompat): `off` iken bu sayfa sunulmaz, `readonly` iken yazma 403 döner;
// sayfa yalnızca bunu kullanıcıya yansıtır (kontrolleri devre dışı bırakır).
//
// Güvenlik: DOM'a yalnızca textContent ile yazılır (innerHTML YOK), depolama/log YOK.
// Efekt yetenek tablosu (CAPS) argb_controller_app/lib/models/effect_capabilities.dart ile aynıdır:
//   bit0=hız, bit1=yoğunluk, bit2=renk, bit3=2. renk.
static const char CONTROL_PAGE_HTML[] PROGMEM = R"HTML(<!doctype html>
<html lang="tr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#0a0e21"><title>ESP32 ARGB</title>
<style>
:root{color-scheme:dark;--bg:#0a0e21;--sf:#1c1e2d;--sl:#252842;--pr:#6c63ff;--se:#00d2ff;--ok:#00e676;--wn:#ffab40;--er:#ff5252;--mu:#b0b3c5}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
body{margin:0;background:var(--bg);color:#fff;font:15px/1.35 -apple-system,system-ui,sans-serif;padding:max(12px,env(safe-area-inset-top)) max(14px,env(safe-area-inset-right)) max(24px,env(safe-area-inset-bottom)) max(14px,env(safe-area-inset-left))}
main{max-width:520px;margin:auto}
header{display:flex;justify-content:space-between;align-items:center;margin:4px 0 10px}
header b{font-size:18px;letter-spacing:.5px}small,.mu{color:var(--mu);font-size:12px}
.dot{width:11px;height:11px;border-radius:50%;background:var(--er)}.dot.on{background:var(--ok);box-shadow:0 0 8px var(--ok)}.dot.po{background:var(--wn)}
.card{background:var(--sf);border:1px solid #ffffff10;border-radius:18px;padding:14px;margin:10px 0}
.card h3{margin:0 0 10px;font-size:12px;letter-spacing:1.1px;color:var(--mu);font-weight:600}
.row{display:flex;align-items:center;gap:12px}.grow{flex:1}
#pw{width:64px;height:64px;border-radius:50%;border:2px solid #fff3;background:var(--sl);color:var(--mu);font-size:28px;padding:0}
#pw.on{background:var(--pr);color:#fff;box-shadow:0 0 18px #6c63ffaa}
input[type=range]{width:100%;height:36px;accent-color:var(--se);margin:0}
.chips{display:flex;flex-wrap:wrap;gap:8px}
.chip,.fx,.pre,.slot{border:1px solid #ffffff1a;background:var(--sl);color:#fff;border-radius:12px;padding:10px 12px;font-size:14px;min-height:44px}
.chip.s,.fx.s,.slot.s{outline:2px solid var(--pr);background:#6c63ff33}
.chip i{display:inline-block;width:8px;height:8px;border-radius:50%;background:#555;margin-right:6px}.chip i.o{background:var(--ok)}
.fxg{display:grid;grid-template-columns:1fr 1fr;gap:8px}.fx{text-align:left}
.wh{position:relative;width:min(100%,260px);aspect-ratio:1;margin:8px auto;touch-action:none}
#wc{width:100%;height:100%;border-radius:50%;display:block}
#mk{position:absolute;width:22px;height:22px;margin:-11px 0 0 -11px;border-radius:50%;border:3px solid #fff;box-shadow:0 0 6px #000;pointer-events:none}
.pres{display:grid;grid-template-columns:repeat(6,1fr);gap:8px;margin-top:8px}.pre{padding:0;height:44px}
.slots{display:flex;gap:8px;margin-bottom:6px}.slot{flex:1;display:flex;align-items:center;gap:8px}.slot span{width:22px;height:22px;border-radius:50%;border:1px solid #fff5}
.ban{border-radius:12px;padding:10px 12px;margin:8px 0;background:#ffab4020;border:1px solid #ffab4080}.ban.e{background:#ff525220;border-color:#ff525280}
.hide{display:none}fieldset{border:0;margin:0;padding:0;min-width:0}fieldset:disabled .card{opacity:.45}fieldset:disabled button,fieldset:disabled input{pointer-events:none}
.dim{opacity:.4;pointer-events:none}
.kv{display:grid;grid-template-columns:auto 1fr;gap:4px 12px;font-size:13px}.kv span:nth-child(odd){color:var(--mu)}
#tt{position:fixed;left:50%;bottom:calc(16px + env(safe-area-inset-bottom));transform:translateX(-50%);background:#000c;border:1px solid #fff3;border-radius:12px;padding:10px 14px;max-width:90%;z-index:9}
a{color:var(--se)}
</style></head><body><main>
<header><div><b id="nm">ESP32 ARGB</b><br><small id="sb">bağlanıyor…</small></div><span id="dot" class="dot"></span></header>
<div id="ban" class="ban hide"></div>
<fieldset id="ctl">
<div class="card"><div class="row"><button id="pw" aria-label="Aç/Kapat">&#x23FB;</button>
<div class="grow"><div class="row"><b>Parlaklık</b><span class="mu" id="bv"></span></div><input id="br" type="range" min="1" max="255"></div></div></div>
<div class="card hide" id="chc"><h3>KANALLAR</h3><div class="chips" id="chs"></div><small class="mu">Renk, efekt ve ayarlar seçili kanallara uygulanır.</small></div>
<div class="card"><h3>RENK</h3><div class="slots"><button class="slot s" id="s0"><span id="c0"></span>1. renk</button><button class="slot" id="s1"><span id="c1"></span>2. renk</button></div>
<div id="cw"><div class="wh"><canvas id="wc" width="240" height="240"></canvas><div id="mk"></div></div><div class="pres" id="pr"></div></div>
<small class="mu hide" id="cn">Bu efekt rengi kullanmaz.</small></div>
<div class="card"><h3>EFEKT</h3><div class="fxg" id="fg"></div></div>
<div class="card"><h3>EFEKT AYARLARI</h3>
<div id="spw"><div class="row"><span>Hız</span><span class="mu" id="spv"></span></div><input id="sp" type="range" min="0" max="255"></div>
<div id="inw"><div class="row"><span>Yoğunluk</span><span class="mu" id="inv"></span></div><input id="ix" type="range" min="0" max="255"></div>
<label class="row" style="margin-top:6px"><input id="rv" type="checkbox"><span>Ters yön</span></label></div>
</fieldset>
<div class="card"><h3>CİHAZ</h3><div class="kv" id="kv"></div><p><small class="mu">Wi-Fi ayarı için <a href="/setup">/setup</a></small></p></div>
</main><div id="tt" class="hide"></div>
<script>
(function(){
var $=function(i){return document.getElementById(i)};
var S={on:false,bri:0,seg:[]},I={},E=[],sel={},slot=0,ws=null,wsOk=false,bo=1000,ptm=null,tm={},lt={},tc={};
var CAPS=[4,3,3,7,13,13,7,15,3,7,15,15,13,15,13,7,7,3,14,15];
var PRE=[[255,0,0],[255,96,0],[255,180,107],[255,220,0],[140,255,0],[0,255,70],[0,255,200],[0,210,255],[0,70,255],[108,99,255],[200,0,255],[255,255,255]];
var W=function(){return I.access==="control"};
function toast(t,bad){var e=$("tt");e.textContent=t;e.className="";e.style.borderColor=bad?"#ff5252":"#fff3";clearTimeout(toast.t);toast.t=setTimeout(function(){e.className="hide"},3500)}
function el(t,c,x){var e=document.createElement(t);if(c)e.className=c;if(x!=null)e.textContent=x;return e}
function rgb(c){return"rgb("+c[0]+","+c[1]+","+c[2]+")"}
function segs(){return S.seg||[]}
function chosen(){return segs().filter(function(s){return sel[s.id]})}
function allSel(){return segs().length>0&&chosen().length===segs().length}
function touched(k){return Date.now()-(tc[k]||0)<700}
function touch(k){tc[k]=Date.now()}
/* ---------- gönderim ---------- */
function post(o){o.v=true;fetch("/json/state",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(o)})
.then(function(r){return r.json().then(function(j){if(!r.ok){toast(j&&j.message==="wled_read_only"?"Salt okunur mod: değişiklik yapılamaz":"İstek reddedildi ("+((j&&j.message)||r.status)+")",true);return}
if(j&&j.seg){S=j;render()}})}).catch(function(){toast("Cihaza ulaşılamadı",true)})}
function send(o){if(!W()){toast("Salt okunur mod: kontroller kapalı",true);return}
if(ws&&ws.readyState===1)ws.send(JSON.stringify(o));else post(o)}
function thr(k,f){var n=Date.now(),d=80-(n-(lt[k]||0));clearTimeout(tm[k]);if(d<=0){lt[k]=n;f()}else tm[k]=setTimeout(function(){lt[k]=Date.now();f()},d)}
function segCmd(f){return{seg:chosen().map(function(s){var o={id:s.id};for(var k in f)o[k]=f[k];return o})}}
function setPower(on){send(allSel()?{on:on}:segCmd({on:on}))}
function setBri(b){send(allSel()?{bri:b}:segCmd({bri:b}))}
function setCol(c){var a=slot===0?[c]:[null,c];send(segCmd({col:a}));
 chosen().forEach(function(s){s.col=s.col||[[0,0,0],[0,0,0],[0,0,0]];s.col[slot]=c});renderCol()}
/* ---------- çizim ---------- */
function cur(){return chosen()[0]||segs()[0]||{}}
function render(){
 var sg=segs();sg.forEach(function(s){if(!(s.id in sel))sel[s.id]=true});
 var f=cur(),w=W();
 $("nm").textContent=I.name||"ESP32 ARGB";
 $("pw").className=S.on?"on":"";
 if(!touched("br")){var mb=allSel()?S.bri:Math.max.apply(null,chosen().map(function(s){return s.bri||0}).concat([0]));$("br").value=Math.max(1,mb);$("bv").textContent=Math.round(mb*100/255)+"%"}
 var cc=$("chc");cc.className=sg.length>1?"card":"card hide";var cs=$("chs");cs.textContent="";
 sg.forEach(function(s){var b=el("button","chip"+(sel[s.id]?" s":""));var i=el("i",s.on?"o":"");b.appendChild(i);b.appendChild(document.createTextNode("Kanal "+(s.id+1)+" · "+(s.len||0)+" LED"));
  b.onclick=function(){sel[s.id]=!sel[s.id];if(!chosen().length)sel[s.id]=true;render()};cs.appendChild(b)});
 var fx=f.fx|0,cp=CAPS[fx]||0;
 Array.prototype.forEach.call($("fg").children,function(b,i){b.className="fx"+(i===fx?" s":"")});
 if(!touched("sp")){$("sp").value=f.sx||0;$("spv").textContent=Math.round((f.sx||0)*100/255)+"%"}
 if(!touched("ix")){$("ix").value=f.ix||0;$("inv").textContent=Math.round((f.ix||0)*100/255)+"%"}
 $("spw").className=cp&1?"":"dim";$("inw").className=cp&2?"":"dim";
 $("rv").checked=!!f.rev;
 $("s1").className="slot"+(slot===1?" s":"")+(cp&8?"":" dim");$("s0").className="slot"+(slot===0?" s":"");
 if(slot===1&&!(cp&8)){slot=0;$("s0").className="slot s"}
 $("cw").className=cp&(4|8)?"":"dim";$("cn").className=cp&(4|8)?"mu hide":"mu";
 renderCol();
 var ban=$("ban");
 if(I.access==="readonly"){ban.className="ban";ban.textContent="Salt okunur mod: kontroller devre dışı. Kontrolü açmak için Flutter uygulamasında cihaz ayarları ▸ WLED uyumluluğu ▸ Kontrol (ESP32 BOOT düğmesine 3 sn basılı tutulur)."}
 else if(I.access&&I.access!=="control"){ban.className="ban e";ban.textContent="Kontrol arayüzü kapalı."}
 else ban.className="ban hide";
 $("ctl").disabled=!w;
 var rs=I.wifi&&I.wifi.rssi,k=$("kv");k.textContent="";
 function kv(a,b){k.appendChild(el("span","",a));k.appendChild(el("span","",b))}
 kv("Bağlantı",wsOk?"Canlı (WebSocket)":"Yoklama (WebSocket yok)");
 kv("Wi-Fi",rs?rs+" dBm · %"+(I.wifi.signal||0):"-");kv("IP",I.ip||location.hostname);
 kv("LED",(I.leds&&I.leds.count||0)+" · "+sg.length+" kanal");kv("Çalışma",up(I.uptime));
 kv("Bellek",Math.round((I.freeheap||0)/1024)+" KB boş");kv("Yazılım",(I.brand||"")+" "+(I.ver||""));
 $("sb").textContent=(I.ip||location.hostname)+(rs?" · "+rs+" dBm":"");
 $("dot").className="dot "+(wsOk?"on":"po");
}
function up(s){s=s|0;var d=Math.floor(s/86400),h=Math.floor(s%86400/3600),m=Math.floor(s%3600/60);return(d?d+"g ":"")+h+"s "+m+"d"}
function renderCol(){var f=cur(),c=f.col||[];for(var i=0;i<2;i++)$("c"+i).style.background=rgb(c[i]||[0,0,0]);if(!touched("wh"))placeMk()}
/* ---------- renk çarkı ---------- */
var cv=$("wc"),cx=cv.getContext("2d"),R=120;
function hsv(h,s){var f=function(n){var k=(n+h/60)%6;return 255*(1-s*Math.max(0,Math.min(k,4-k,1)))};return[Math.round(f(5)),Math.round(f(3)),Math.round(f(1))]}
function toHs(c){var r=c[0]/255,g=c[1]/255,b=c[2]/255,mx=Math.max(r,g,b),mn=Math.min(r,g,b),d=mx-mn,h=0;
 if(d){h=mx===r?((g-b)/d)%6:mx===g?(b-r)/d+2:(r-g)/d+4;h*=60;if(h<0)h+=360}return[h,mx?d/mx:0]}
function drawWheel(){var im=cx.createImageData(240,240),d=im.data;for(var y=0;y<240;y++)for(var x=0;x<240;x++){var dx=x-R,dy=y-R,r=Math.sqrt(dx*dx+dy*dy),o=(y*240+x)*4;
 if(r<=R){var h=(Math.atan2(dy,dx)*180/Math.PI+360)%360,c=hsv(h,r/R);d[o]=c[0];d[o+1]=c[1];d[o+2]=c[2];d[o+3]=255}}cx.putImageData(im,0,0)}
function placeMk(){var f=cur(),c=(f.col||[])[slot]||[255,255,255],hs=toHs(c),a=hs[0]*Math.PI/180,m=$("mk"),w=cv.clientWidth||240;
 m.style.left=(w/2+Math.cos(a)*hs[1]*w/2)+"px";m.style.top=(w/2+Math.sin(a)*hs[1]*w/2)+"px";m.style.background=rgb(c)}
function pick(e){var b=cv.getBoundingClientRect(),dx=e.clientX-b.left-b.width/2,dy=e.clientY-b.top-b.height/2,r=Math.sqrt(dx*dx+dy*dy)/(b.width/2);
 if(r>1){dx/=r;dy/=r;r=1}var h=(Math.atan2(dy,dx)*180/Math.PI+360)%360,c=hsv(h,r);touch("wh");thr("col",function(){setCol(c)})}
var dn=false;
cv.parentNode.addEventListener("pointerdown",function(e){if(!W())return;dn=true;this.setPointerCapture(e.pointerId);pick(e)});
cv.parentNode.addEventListener("pointermove",function(e){if(dn)pick(e)});
cv.parentNode.addEventListener("pointerup",function(){dn=false});
cv.parentNode.addEventListener("pointercancel",function(){dn=false});
/* ---------- kontroller ---------- */
$("pw").onclick=function(){setPower(!S.on)};
$("br").oninput=function(){var v=+this.value;touch("br");$("bv").textContent=Math.round(v*100/255)+"%";thr("br",function(){setBri(v)})};
$("sp").oninput=function(){var v=+this.value;touch("sp");$("spv").textContent=Math.round(v*100/255)+"%";thr("sp",function(){send(segCmd({sx:v}))})};
$("ix").oninput=function(){var v=+this.value;touch("ix");$("inv").textContent=Math.round(v*100/255)+"%";thr("ix",function(){send(segCmd({ix:v}))})};
$("rv").onchange=function(){send(segCmd({rev:this.checked}))};
$("s0").onclick=function(){slot=0;render()};$("s1").onclick=function(){slot=1;render()};
PRE.forEach(function(c){var b=el("button","pre");b.style.background=rgb(c);b.setAttribute("aria-label",rgb(c));b.onclick=function(){setCol(c)};$("pr").appendChild(b)});
/* ---------- veri ---------- */
function apply(j){if(!j)return;if(j.state)S=j.state;if(j.info)I=j.info;render()}
function load(){return fetch("/json/si").then(function(r){if(!r.ok)throw r.status;return r.json()}).then(apply)}
function poll(){clearTimeout(ptm);ptm=setTimeout(function(){if(wsOk)return;load().catch(function(){$("dot").className="dot";$("sb").textContent="bağlantı yok"}).then(poll)},2500)}
function open(){try{ws=new WebSocket("ws://"+location.host+"/ws")}catch(e){poll();return}
 ws.onopen=function(){wsOk=true;bo=1000;render()};
 ws.onmessage=function(m){if(typeof m.data!=="string"||m.data==="pong")return;var j;try{j=JSON.parse(m.data)}catch(e){return}
  if(j.error){toast(j.message==="wled_read_only"?"Salt okunur mod: değişiklik yapılamaz":j.message==="busy"?"Cihaz meşgul, tekrar deneyin":"Cihaz hatası: "+(j.message||j.error),true);return}apply(j)};
 ws.onclose=function(){wsOk=false;render();poll();setTimeout(open,bo);bo=Math.min(bo*2,8000)}}
setInterval(function(){if(wsOk&&ws.readyState===1)ws.send("p")},20000);
drawWheel();
fetch("/json/eff").then(function(r){return r.json()}).then(function(a){E=a;var g=$("fg");a.forEach(function(n,i){var b=el("button","fx",n);b.onclick=function(){send(segCmd({fx:i}))};g.appendChild(b)})})
.catch(function(){toast("Efekt listesi alınamadı",true)}).then(load).then(open,function(){toast("Cihaza ulaşılamadı",true);poll();open()});
})();
</script></body></html>)HTML";

// off modunda sunulan, hiçbir cihaz verisi içermeyen sayfa
static const char OFF_PAGE_HTML[] PROGMEM = R"HTML(<!doctype html>
<html lang="tr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>ESP32 ARGB</title><style>body{margin:0;padding:24px;background:#0a0e21;color:#fff;font:16px system-ui,sans-serif;max-width:520px;margin:auto}
.c{background:#1c1e2d;border-radius:16px;padding:16px;margin-top:16px}a{color:#00d2ff}</style></head><body>
<h2>ESP32 ARGB Denetleyici</h2>
<div class="c">Tarayıcı/WLED kontrol arayüzü <b>kapalı</b>. Cihazı kontrol etmek için eşleştirilmiş Flutter uygulamasını kullanın.<br><br>
Kontrol arayüzünü açmak: uygulamada cihaz ayarları ▸ WLED uyumluluğu.</div>
<div class="c">Wi-Fi kurulumu: <a href="/setup">/setup</a></div></body></html>)HTML";
