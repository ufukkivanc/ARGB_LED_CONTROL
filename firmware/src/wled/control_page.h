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
.chg{display:grid;grid-template-columns:1fr 1fr;gap:8px}
.chk{display:flex;align-items:center;gap:10px;min-height:48px;border:1px solid #ffffff1a;background:var(--sl);border-radius:12px;padding:8px 12px;font-size:15px}
.chk input{width:22px;height:22px;margin:0;accent-color:var(--pr)}
.chk.s{outline:2px solid var(--pr);background:#6c63ff33;font-weight:700}.chk.x{opacity:.45}
.chh{display:flex;justify-content:space-between;align-items:center;margin-bottom:10px}.chh h3{margin:0}.chh button{min-height:36px;padding:6px 10px}
.fxg{display:grid;grid-template-columns:1fr 1fr;gap:8px}.fx{text-align:left}
.wh{position:relative;width:min(100%,260px);aspect-ratio:1;margin:8px auto;touch-action:none}
#wc{width:100%;height:100%;border-radius:50%;display:block}
#mk{position:absolute;left:50%;top:50%;width:26px;height:26px;margin:-13px 0 0 -13px;border-radius:50%;border:3px solid #fff;box-shadow:0 0 0 2px #000b,0 0 8px #000;pointer-events:none;background:#fff;z-index:2}
.pal{display:flex;gap:10px;flex-wrap:wrap;margin-bottom:8px}.pal button{width:46px;height:46px;border-radius:50%;border:2px solid #fff4;padding:0;color:#fff;font-size:22px;background:var(--sl)}
.pal button.s{outline:3px solid var(--pr);outline-offset:2px}
.pb{display:flex;gap:8px;flex-wrap:wrap}.pb button,.btn{border:1px solid #ffffff1a;background:var(--sl);color:#fff;border-radius:12px;padding:10px 14px;font-size:14px;min-height:44px}
.pb button:disabled,.btn:disabled{opacity:.4}
.num{width:96px;min-height:40px;border-radius:10px;border:1px solid #ffffff30;background:var(--sl);color:#fff;font-size:16px;padding:6px 10px;text-align:right}
.lcr{display:flex;align-items:center;gap:10px;margin:6px 0}
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
<div class="card" id="chc"><div class="chh"><h3>KANALLAR</h3><span><button class="btn" id="chA">Tümü</button> <button class="btn" id="chN">Hiçbiri</button></span></div>
<div class="chg" id="chs"></div><small class="mu" id="chm" style="display:block;margin-top:8px"></small></div>
<div class="card"><h3>RENK</h3><div class="slots"><button class="slot s" id="s0"><span id="c0"></span>1. renk</button><button class="slot" id="s1"><span id="c1"></span>2. renk</button></div>
<div id="cw"><div class="wh"><canvas id="wc" width="240" height="240"></canvas><div id="mk"></div></div><div class="pres" id="pr"></div></div>
<small class="mu hide" id="cn">Bu efekt rengi kullanmaz.</small></div>
<div class="card" id="plc"><h3>ÇOK RENKLİ PALET</h3><div class="pal" id="pl"></div>
<div class="pb"><button id="pL" aria-label="Sola taşı">&#x25C0;</button><button id="pR" aria-label="Sağa taşı">&#x25B6;</button><button id="pD">Sil</button><button id="pC">Temizle</button></div>
<small class="mu" id="pn"></small></div>
<div class="card"><h3>EFEKT</h3><div class="fxg" id="fg"></div></div>
<div class="card"><h3>EFEKT AYARLARI</h3>
<div id="spw"><div class="row"><span>Hız</span><span class="mu" id="spv"></span></div><input id="sp" type="range" min="0" max="255"></div>
<div id="inw"><div class="row"><span>Yoğunluk</span><span class="mu" id="inv"></span></div><input id="ix" type="range" min="0" max="255"></div>
<label class="row" style="margin-top:6px"><input id="rv" type="checkbox"><span>Ters yön</span></label></div>
<div class="card" id="stc"><h3>AYARLAR</h3>
<div><b>LED sayısı</b><div id="lc"></div>
<div class="row" style="margin-top:8px"><button class="btn" id="lcA" disabled>Uygula</button><button class="btn hide" id="rbt">Yeniden başlat</button></div>
<small id="lcm" class="mu"></small>
<small class="mu" style="display:block;margin-top:6px">LED sayısı yazılımsal bir ayardır: fiziksel şerit uzunluğu otomatik algılanamaz, kendiniz girin. 0 = kanal kapalı.</small></div>
<hr style="border:0;border-top:1px solid #ffffff14;margin:12px 0">
<div><b>Wi-Fi</b><p style="margin:6px 0 0"><small class="mu">Wi-Fi ağı ayarı için <a href="/setup">/setup</a> sayfasını açın.</small></p></div></div>
</fieldset>
<div class="card"><h3>CİHAZ</h3><div class="kv" id="kv"></div></div>
</main><div id="tt" class="hide"></div>
<script>
(function(){
var $=function(i){return document.getElementById(i)};
var S={on:false,bri:0,seg:[]},I={},E=[],slot=0,pi=-1,lcD={},ws=null,wsOk=false,bo=1000,ptm=null,tm={},lt={},tc={};
var CAPS=[4,3,3,7,13,13,7,15,3,7,15,15,13,15,13,7,7,3,14,15];
var PRE=[[255,0,0],[255,96,0],[255,180,107],[255,220,0],[140,255,0],[0,255,70],[0,255,200],[0,210,255],[0,70,255],[108,99,255],[200,0,255],[255,255,255]];
var W=function(){return I.access==="control"};
function toast(t,bad){var e=$("tt");e.textContent=t;e.className="";e.style.borderColor=bad?"#ff5252":"#fff3";clearTimeout(toast.t);toast.t=setTimeout(function(){e.className="hide"},3500)}
function el(t,c,x){var e=document.createElement(t);if(c)e.className=c;if(x!=null)e.textContent=x;return e}
function rgb(c){return"rgb("+c[0]+","+c[1]+","+c[2]+")"}
function segs(){return S.seg||[]}
/* Kanal seçimi — Windows uygulamasıyla AYNI kurallar (docs/PROTOCOL.md §3.8):
   1 yalnızca etkin kanal seçilebilir; 2 ilk durumda tüm etkin kanallar seçilir, sonradan etkinleşen eklenmez;
   3 kapanan kanal seçimden çıkar; 4 boş seçim geçerlidir ve HİÇBİR kanal komutu gönderilmez;
   5 kontroller seçili en küçük kanalı (boşsa ilk etkin kanalı) gösterir; 6 seçim cihaza bir şey göndermez. */
var SEL={init:false,on:{},
 enabled:function(){var e={};segs().forEach(function(s){e[s.id]=1});return e},
 reconcile:function(){var e=this.enabled(),k=Object.keys(e);if(!k.length&&!this.init)return;
  if(!this.init){this.on={};k.forEach(function(i){SEL.on[i]=1});this.init=true;return}
  Object.keys(this.on).forEach(function(i){if(!e[i])delete SEL.on[i]})},
 toggle:function(id){if(!this.enabled()[id])return;if(this.on[id])delete this.on[id];else this.on[id]=1},
 all:function(){var e=this.enabled();this.on={};Object.keys(e).forEach(function(i){SEL.on[i]=1});this.init=true},
 none:function(){this.on={};this.init=true},
 has:function(id){return!!this.on[id]}};
function chosen(){return segs().filter(function(s){return SEL.has(s.id)}).sort(function(a,b){return a.id-b.id})}
function touched(k){return Date.now()-(tc[k]||0)<700}
function touch(k){tc[k]=Date.now()}
/* ---------- gönderim ---------- */
function post(o){o.v=true;fetch("/json/state",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(o)})
.then(function(r){return r.json().then(function(j){if(!r.ok){toast(j&&j.message==="wled_read_only"?"Salt okunur mod: değişiklik yapılamaz":"İstek reddedildi ("+((j&&j.message)||r.status)+")",true);return}
if(j&&j.seg){S=j;render()}})}).catch(function(){toast("Cihaza ulaşılamadı",true)})}
function send(o){if(!o){noSel();return}if(!W()){toast("Salt okunur mod: kontroller kapalı",true);return}
if(ws&&ws.readyState===1)ws.send(JSON.stringify(o));else post(o)}
function thr(k,f){var n=Date.now(),d=80-(n-(lt[k]||0));clearTimeout(tm[k]);if(d<=0){lt[k]=n;f()}else tm[k]=setTimeout(function(){lt[k]=Date.now();f()},d)}
/* Yalnızca seçili kanallar; seçim boşsa null (hiçbir şey gönderilmez). Üst düzey on/bri KULLANILMAZ
   (tüm kanalları etkilerdi); her değişiklik seçili segmentlere ayrı ayrı gider. */
function segCmd(f){var c=chosen();if(!c.length)return null;return{seg:c.map(function(s){var o={id:s.id};for(var k in f)o[k]=f[k];return o})}}
function setPower(on){send(segCmd({on:on}));chosen().forEach(function(s){s.on=on});render()}
function setBri(b){send(segCmd({bri:b}));chosen().forEach(function(s){s.bri=b})}
function setCol(c){if(slot===2){editPal(pi,c);return}var a=slot===0?[c]:[null,c],m=segCmd({col:a});if(!m){noSel();return}send(m);
 chosen().forEach(function(s){s.col=s.col||[[0,0,0],[0,0,0],[0,0,0]];s.col[slot]=c});renderCol()}
function noSel(){toast("Kanal seçilmedi: değişiklik gönderilmedi",true);renderCol()}
/* ---------- palet (1-5 renk, kanal başına; apal) ---------- */
function maxP(){return I.argb&&I.argb.maxpal||5}
function curPal(){var f=cur();return Array.isArray(f.apal)?f.apal:[]}
function clonePal(a){return a.map(function(x){return x.slice()})}
function sendPal(a){var m=segCmd({apal:a});if(!m){noSel();return}send(m);chosen().forEach(function(s){s.apal=clonePal(a)})}
function editPal(i,c){var a=clonePal(curPal());if(i<0||i>=a.length)return;if(!chosen().length){noSel();return}a[i]=c;
 chosen().forEach(function(s){s.apal=clonePal(a)});renderPal();thr("pal",function(){send(segCmd({apal:a}))})}
function palBase(){var a=curPal();if(slot===2&&a[pi])return a[pi];var c=(cur().col||[])[slot===1?1:0];return c||[255,255,255]}
function renderPal(){var a=curPal(),h=$("pl"),n=maxP();h.textContent="";
 if(pi>=a.length)pi=a.length-1;if(slot===2&&pi<0)slot=0;
 a.forEach(function(c,i){var b=el("button",i===pi&&slot===2?"s":"");b.style.background=rgb(c);b.setAttribute("aria-label","Palet rengi "+(i+1));
  b.onclick=function(){pi=i;slot=2;render()};h.appendChild(b)});
 if(a.length<n){var p=el("button","","+");p.setAttribute("aria-label","Renk ekle");p.onclick=function(){var c=palBase().slice(),b=clonePal(curPal());b.push(c);pi=b.length-1;slot=2;sendPal(b);render()};h.appendChild(p)}
 var on=slot===2&&pi>=0;$("pL").disabled=!(on&&pi>0);$("pR").disabled=!(on&&pi<a.length-1);$("pD").disabled=!on;$("pC").disabled=!a.length;
 $("pn").textContent=a.length?"Palet etkin ("+a.length+" renk): efektler yalnızca palet renklerini kullanır. Bir renge dokunup çarktan değiştirin.":"Palet boş: efektler kendi renklerini kullanır. + ile renk ekleyin (en çok "+n+").";
 $("s0").className="slot"+(slot===0?" s":"")}
$("pL").onclick=function(){var a=clonePal(curPal());if(pi>0){var t=a[pi];a[pi]=a[pi-1];a[pi-1]=t;pi--;sendPal(a);render()}};
$("pR").onclick=function(){var a=clonePal(curPal());if(pi>=0&&pi<a.length-1){var t=a[pi];a[pi]=a[pi+1];a[pi+1]=t;pi++;sendPal(a);render()}};
$("pD").onclick=function(){var a=clonePal(curPal());if(pi>=0&&pi<a.length){a.splice(pi,1);pi=Math.min(pi,a.length-1);if(pi<0)slot=0;sendPal(a);render()}};
$("pC").onclick=function(){pi=-1;if(slot===2)slot=0;sendPal([]);render()};
/* ---------- çizim ---------- */
function cur(){return chosen()[0]||segs().slice().sort(function(a,b){return a.id-b.id})[0]||{}}
function render(){
 var sg=segs();SEL.reconcile();
 var f=cur(),w=W();
 $("nm").textContent=I.name||"ESP32 ARGB";
 $("pw").className=f.on?"on":"";
 if(!touched("br")){var mb=f.bri||0;$("br").value=Math.max(1,mb);$("bv").textContent=Math.round(mb*100/255)+"%"}
 renderCh();
 var fx=f.fx|0,cp=CAPS[fx]||0;
 Array.prototype.forEach.call($("fg").children,function(b,i){b.className="fx"+(i===fx?" s":"")});
 if(!touched("sp")){$("sp").value=f.sx||0;$("spv").textContent=Math.round((f.sx||0)*100/255)+"%"}
 if(!touched("ix")){$("ix").value=f.ix||0;$("inv").textContent=Math.round((f.ix||0)*100/255)+"%"}
 $("spw").className=cp&1?"":"dim";$("inw").className=cp&2?"":"dim";
 $("rv").checked=!!f.rev;
 $("s1").className="slot"+(slot===1?" s":"")+(cp&8?"":" dim");$("s0").className="slot"+(slot===0?" s":"");
 if(slot===1&&!(cp&8)){slot=0;$("s0").className="slot s"}
 var pOn=curPal().length>0;
 $("cw").className=(cp&(4|8))||slot===2?"":"dim";$("cn").className=(cp&(4|8))||slot===2||pOn?"mu hide":"mu";
 renderPal();renderLc();
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
function renderCh(){var cs=$("chs"),en=SEL.enabled(),A=I.argb,ids=[0,1,2,3],c=chosen();cs.textContent="";
 ids.forEach(function(id){var on=!!en[id],s=SEL.has(id)&&on,seg=segs().filter(function(x){return x.id===id})[0];
  var l=el("label","chk"+(s?" s":"")+(on?"":" x"));l.id="ck"+id;var i=document.createElement("input");i.type="checkbox";i.checked=s;i.disabled=!on;
  i.setAttribute("aria-label","CH"+(id+1));i.onchange=function(){SEL.toggle(id);render()};l.appendChild(i);
  var t=el("span","","CH"+(id+1));l.appendChild(t);if(!on&&(seg||A))l.appendChild(el("small","mu","kapalı"));
  if(seg&&seg.on===false)l.appendChild(el("small","mu","⏻"));cs.appendChild(l)});
 var m=$("chm");if(!c.length){m.textContent="Kanal seçilmedi: renk ve efekt değişiklikleri gönderilmez.";m.style.color="#ffab40"}
 else{m.textContent="Değişiklikler yalnızca seçili kanallara uygulanır: "+c.map(function(s){return"CH"+(s.id+1)}).join(", ");m.style.color=""}
 $("chA").disabled=!Object.keys(en).length;$("chN").disabled=!c.length}
$("chA").onclick=function(){SEL.all();render()};$("chN").onclick=function(){SEL.none();render()};
function up(s){s=s|0;var d=Math.floor(s/86400),h=Math.floor(s%86400/3600),m=Math.floor(s%3600/60);return(d?d+"g ":"")+h+"s "+m+"d"}
function renderCol(){var f=cur(),c=f.col||[];for(var i=0;i<2;i++)$("c"+i).style.background=rgb(c[i]||[0,0,0]);if(!touched("wh"))placeMk()}
/* ---------- LED sayısı (Ayarlar) ---------- */
function renderLc(){var A=I.argb;if(!A||!A.ch)return;var box=$("lc");
 if(!box.children.length)A.ch.forEach(function(c){var r=el("div","lcr");r.appendChild(el("span","grow","CH"+(c.id+1)));
  var i=document.createElement("input");i.type="number";i.inputMode="numeric";i.min=0;i.max=A.maxlen;i.className="num";i.id="ln"+c.id;
  i.oninput=function(){lcD[c.id]=1;lcCheck()};r.appendChild(i);var p=el("small","mu","");p.id="lp"+c.id;r.appendChild(p);box.appendChild(r)});
 A.ch.forEach(function(c){var i=$("ln"+c.id);if(!i)return;if(!lcD[c.id]&&document.activeElement!==i)i.value=c.n;
  $("lp"+c.id).textContent=c.pn!=null&&c.pn!==c.n?"→ "+c.pn+" (yeniden başlatınca)":""});
 $("rbt").className=A.reboot?"btn":"btn hide";lcCheck()}
function lcCheck(){var A=I.argb;if(!A||!A.ch)return;var tot=0,bad="",warn="";
 A.ch.forEach(function(c){var i=$("ln"+c.id);if(!i)return;var v=parseInt(i.value,10);
  if(isNaN(v)||v<0||v>A.maxlen){bad="CH"+(c.id+1)+": 0–"+A.maxlen+" arası bir sayı girin"}else{tot+=v;if(v>A.warnlen)warn="Yüksek LED sayısı: kare hızı düşebilir"}});
 if(!bad&&tot>A.maxtotal)bad="Toplam "+tot+" LED, "+A.maxtotal+" sınırını aşıyor";
 if(!bad&&tot>A.warntotal)warn="Yüksek toplam LED sayısı: kare hızı düşebilir";
 var m=$("lcm");m.textContent=bad||warn;m.style.color=bad?"#ff5252":"#ffab40";$("lcA").disabled=!!bad||!Object.keys(lcD).length}
$("lcA").onclick=function(){var A=I.argb,l=[],want={};A.ch.forEach(function(c){if(lcD[c.id]){var n=parseInt($("ln"+c.id).value,10);l.push({id:c.id,n:n});want[c.id]=n}});
 if(!l.length)return;send({argb:{leds:l}});lcD={};
 setTimeout(function(){load().then(function(){var A2=I.argb,miss=A2&&A2.ch.filter(function(c){return c.id in want&&c.n!==want[c.id]&&c.pn!==want[c.id]});
  if(miss&&miss.length)toast("LED sayısı uygulanamadı (toplam sınırı veya hata)",true)})},900)};
$("rbt").onclick=function(){send({argb:{reboot:true}});toast("Cihaz yeniden başlatılıyor…")};
/* ---------- renk çarkı ---------- */
var cv=$("wc"),cx=cv.getContext("2d"),R=120;
function hsv(h,s){var f=function(n){var k=(n+h/60)%6;return 255*(1-s*Math.max(0,Math.min(k,4-k,1)))};return[Math.round(f(5)),Math.round(f(3)),Math.round(f(1))]}
function toHs(c){var r=c[0]/255,g=c[1]/255,b=c[2]/255,mx=Math.max(r,g,b),mn=Math.min(r,g,b),d=mx-mn,h=0;
 if(d){h=mx===r?((g-b)/d)%6:mx===g?(b-r)/d+2:(r-g)/d+4;h*=60;if(h<0)h+=360}return[h,mx?d/mx:0]}
function drawWheel(){var im=cx.createImageData(240,240),d=im.data;for(var y=0;y<240;y++)for(var x=0;x<240;x++){var dx=x-R,dy=y-R,r=Math.sqrt(dx*dx+dy*dy),o=(y*240+x)*4;
 if(r<=R){var h=(Math.atan2(dy,dx)*180/Math.PI+360)%360,c=hsv(h,r/R);d[o]=c[0];d[o+1]=c[1];d[o+2]=c[2];d[o+3]=255}}cx.putImageData(im,0,0)}
function wheelCol(){var f=cur();if(slot===2){var a=curPal();return a[pi]||[255,255,255]}return(f.col||[])[slot]||[255,255,255]}
function mkAt(nx,ny,c){var m=$("mk");m.style.left=(50+nx*50)+"%";m.style.top=(50+ny*50)+"%";m.style.background=rgb(c)}
function placeMk(){var c=wheelCol(),hs=toHs(c),a=hs[0]*Math.PI/180;mkAt(Math.cos(a)*hs[1],Math.sin(a)*hs[1],c)}
function pick(e){var b=cv.getBoundingClientRect(),dx=e.clientX-b.left-b.width/2,dy=e.clientY-b.top-b.height/2,r=Math.sqrt(dx*dx+dy*dy)/(b.width/2);
 if(r>1){dx/=r;dy/=r;r=1}var h=(Math.atan2(dy,dx)*180/Math.PI+360)%360,c=hsv(h,r);touch("wh");mkAt(dx/(b.width/2),dy/(b.width/2),c);thr("col",function(){setCol(c)})}
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
function apply(j){if(!j)return;if(j.state)S=j.state;if(j.info)I=j.info;if(!E.length&&Array.isArray(j.effects))buildFx(j.effects);render()}
function load(){return fetch("/json/si").then(function(r){if(!r.ok)throw r.status;return r.json()}).then(apply)}
function poll(){clearTimeout(ptm);ptm=setTimeout(function(){if(wsOk)return;load().catch(function(){$("dot").className="dot";$("sb").textContent="bağlantı yok"}).then(poll)},2500)}
function open(){try{ws=new WebSocket("ws://"+location.host+"/ws")}catch(e){poll();return}
 ws.onopen=function(){wsOk=true;bo=1000;render()};
 ws.onmessage=function(m){if(typeof m.data!=="string"||m.data==="pong")return;var j;try{j=JSON.parse(m.data)}catch(e){return}
  if(j.error){toast(j.message==="wled_read_only"?"Salt okunur mod: değişiklik yapılamaz":j.message==="busy"?"Cihaz meşgul, tekrar deneyin":"Cihaz hatası: "+(j.message||j.error),true);return}apply(j)};
 ws.onclose=function(){wsOk=false;render();poll();setTimeout(open,bo);bo=Math.min(bo*2,8000)}}
setInterval(function(){if(wsOk&&ws.readyState===1)ws.send("p")},20000);
drawWheel();
/* Efekt listesi: /json/eff (dizi) -> /json -> /json/si ("effects" alanı); her biri doğrulanır, hepsi başarısızsa yeniden denenir */
function getJ(u){return fetch(u,{cache:"no-store"}).then(function(r){if(!r.ok)throw new Error("HTTP "+r.status);return r.json()})}
function pickEff(j){if(Array.isArray(j))return j;if(j&&Array.isArray(j.effects))return j.effects;return null}
function buildFx(a){if(!a||!a.length||E.length)return;E=a;var g=$("fg");g.textContent="";
 a.forEach(function(n,i){var b=el("button","fx",String(n));b.onclick=function(){send(segCmd({fx:i}))};g.appendChild(b)});render()}
function effList(){var U=["/json/eff","/json","/json/si"],last="";
 function one(i){if(i>=U.length)return Promise.reject(new Error(last));
  return getJ(U[i]).then(function(j){var a=pickEff(j);if(!a||!a.length)throw new Error("beklenmeyen yanıt "+U[i]);return a})
  .catch(function(e){last=U[i]+": "+(e&&e.message||e);return one(i+1)})}
 function att(k){return one(0).catch(function(e){if(k>=2)throw e;return new Promise(function(f){setTimeout(f,700*(k+1))}).then(function(){return att(k+1)})})}
 return att(0)}
function effRetry(n){if(E.length||n>6)return;setTimeout(function(){effList().then(buildFx,function(){effRetry(n+1)})},5000)}
effList().then(buildFx,function(e){toast("Efekt listesi alınamadı ("+(e&&e.message||e)+")",true);effRetry(0)}).then(load).then(open,function(){toast("Cihaza ulaşılamadı",true);poll();open()});
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
