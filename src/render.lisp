;;;; Server-rendered pages. The board ships one JSON snapshot inline and then
;;;; polls /api/deals; bookmarks and claimed marks stay in the browser.

(in-package #:deal-aggregator)

(defun escape-html (string)
  (with-output-to-string (out)
    (loop for character across (or string "")
          do (case character
               (#\& (write-string "&amp;" out))
               (#\< (write-string "&lt;" out))
               (#\> (write-string "&gt;" out))
               (#\" (write-string "&quot;" out))
               (#\' (write-string "&#39;" out))
               (t (write-char character out))))))

(defparameter +page-css+
  "*,*::before,*::after{box-sizing:border-box}
:root{--bg:#0f1115;--surface:#171a21;--surface-alt:#1e222b;--border:#2a2f3a;
--fg:#e7e9ee;--muted:#9aa3b2;--accent:#5ad1a5;--warn:#f0b44c;--danger:#ef6d6d}
html,body{margin:0;background:var(--bg);color:var(--fg);
font:15px/1.5 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,'Noto Sans SC',sans-serif}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
header{position:sticky;top:0;z-index:5;background:rgba(15,17,21,.92);
backdrop-filter:blur(8px);border-bottom:1px solid var(--border);padding:12px 20px}
.wrap{max-width:1180px;margin:0 auto;padding:0 20px}
.bar{display:flex;gap:16px;align-items:center;flex-wrap:wrap}
.brand{font-weight:700;font-size:17px;letter-spacing:.2px}
.status{color:var(--muted);font-size:13px}
.status b{color:var(--fg);font-weight:600}
.dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:6px}
.dot.ok{background:var(--accent)}.dot.warn{background:var(--warn)}.dot.bad{background:var(--danger)}
main{padding:20px 0 60px}
.controls{display:flex;gap:10px;flex-wrap:wrap;margin:0 0 18px}
input[type=search],select,button{background:var(--surface);color:var(--fg);
border:1px solid var(--border);border-radius:8px;padding:8px 10px;font:inherit}
input[type=search]{min-width:260px;flex:1}
button{cursor:pointer}button:hover{background:var(--surface-alt)}
button:disabled{opacity:.5;cursor:progress}
.grid{display:grid;gap:12px;grid-template-columns:repeat(auto-fill,minmax(320px,1fr))}
.card{background:var(--surface);border:1px solid var(--border);border-radius:12px;
padding:14px;display:flex;flex-direction:column;gap:8px}
.card.claimed{opacity:.55}
.card h2{font-size:15px;line-height:1.4;margin:0;font-weight:600}
.card h2 a{color:var(--fg)}
.meta{display:flex;gap:8px;flex-wrap:wrap;align-items:center;color:var(--muted);font-size:12px}
.chip{display:inline-block;padding:2px 8px;border-radius:999px;background:var(--surface-alt);
border:1px solid var(--border);color:var(--muted);font-size:12px}
.chip.new{color:var(--accent);border-color:rgba(90,209,165,.4)}
.chip.soon{color:var(--warn);border-color:rgba(240,180,76,.4)}
.summary{margin:0;color:var(--muted);font-size:13px}
.actions{display:flex;gap:8px;margin-top:auto;padding-top:6px}
.actions button{padding:4px 10px;font-size:12px}
.banner{border:1px solid var(--border);border-radius:10px;padding:10px 14px;margin:0 0 16px;
background:var(--surface);color:var(--muted);font-size:13px}
.banner.warn{border-color:rgba(240,180,76,.45);color:var(--warn)}
.banner.bad{border-color:rgba(239,109,109,.45);color:var(--danger)}
.empty{color:var(--muted);padding:40px 0;text-align:center}
.login{max-width:380px;margin:12vh auto;background:var(--surface);border:1px solid var(--border);
border-radius:14px;padding:24px}
.login h1{margin:0 0 4px;font-size:18px}
.login p{color:var(--muted);font-size:13px;margin:0 0 18px}
.login label{display:block;font-size:13px;color:var(--muted);margin:0 0 6px}
.login input{width:100%;background:var(--surface-alt);border:1px solid var(--border);
border-radius:8px;padding:10px;color:var(--fg);font:inherit}
.login button{width:100%;margin-top:14px;padding:10px}
.error{color:var(--danger);font-size:13px;margin:10px 0 0}
footer{color:var(--muted);font-size:12px;border-top:1px solid var(--border);padding:16px 0;margin-top:30px}")

(defparameter +page-js+
  "const PERSONAL_KEY='deal-aggregator-personal-v1';
const LEGACY_PERSONAL_KEY='perkradar-personal-v1';
const SHOW_ALL_KEY='deal-aggregator-show-all-v1';
const LEGACY_SHOW_ALL_KEY='perkradar-show-all-v1';
const EMPTY={claimed:[],favorites:[]};
function loadPersonal(){try{const raw=localStorage.getItem(PERSONAL_KEY)||localStorage.getItem(LEGACY_PERSONAL_KEY);
if(!raw)return {...EMPTY};const parsed=JSON.parse(raw);const list=v=>Array.isArray(v)?v.filter(x=>typeof x==='string').slice(0,10000):[];
return {claimed:list(parsed.claimed),favorites:list(parsed.favorites)};}catch{return {...EMPTY};}}
function savePersonal(p){try{localStorage.setItem(PERSONAL_KEY,JSON.stringify(p));}catch{}}
function loadShowAll(){try{const v=localStorage.getItem(SHOW_ALL_KEY)||localStorage.getItem(LEGACY_SHOW_ALL_KEY);
return v===null?true:v==='1';}catch{return true;}}
function saveShowAll(v){try{localStorage.setItem(SHOW_ALL_KEY,v?'1':'0');}catch{}}
const state={deals:[],personal:loadPersonal(),showAll:loadShowAll(),query:'',category:'all',source:'all'};
const el=id=>document.getElementById(id);
function chip(text,cls){const s=document.createElement('span');s.className='chip'+(cls?' '+cls:'');s.textContent=text;return s;}
function render(){
  const grid=el('deals');grid.textContent='';
  const query=state.query.trim().toLowerCase();
  const shown=state.deals.filter(d=>{
    if(state.source!=='all'&&d.sourceId!==state.source)return false;
    if(state.category==='favorites'){if(!state.personal.favorites.includes(d.canonicalUrl))return false;}
    else if(state.category!=='all'&&d.category!==state.category)return false;
    if(!state.showAll&&state.personal.claimed.includes(d.canonicalUrl))return false;
    if(query&&!(d.title.toLowerCase().includes(query)||(d.summary||'').toLowerCase().includes(query)))return false;
    return true;});
  el('count').textContent=`${shown.length} of ${state.deals.length} shown`;
  if(!shown.length){const p=document.createElement('p');p.className='empty';
    p.textContent='Nothing matches these filters.';grid.appendChild(p);return;}
  for(const d of shown){
    const card=document.createElement('article');card.className='card';
    const claimed=state.personal.claimed.includes(d.canonicalUrl);
    const favorite=state.personal.favorites.includes(d.canonicalUrl);
    if(claimed)card.classList.add('claimed');
    const h=document.createElement('h2');const a=document.createElement('a');
    a.href=d.url;a.target='_blank';a.rel='noopener noreferrer';a.textContent=d.title;h.appendChild(a);
    card.appendChild(h);
    if(d.summary){const p=document.createElement('p');p.className='summary';p.textContent=d.summary;card.appendChild(p);}
    const meta=document.createElement('div');meta.className='meta';
    meta.appendChild(chip(d.sourceName));meta.appendChild(chip(d.categoryLabel||d.category));
    if(d.isNew)meta.appendChild(chip('new','new'));
    if(d.expiresSoon)meta.appendChild(chip('expires '+(d.expiresLabel||''),'soon'));
    else if(d.expiresLabel)meta.appendChild(chip('until '+d.expiresLabel));
    if(d.publishedLabel)meta.appendChild(chip(d.publishedLabel));
    card.appendChild(meta);
    const actions=document.createElement('div');actions.className='actions';
    const fav=document.createElement('button');fav.type='button';
    fav.textContent=favorite?'★ saved':'☆ save';
    fav.onclick=()=>{toggle('favorites',d.canonicalUrl);};
    const done=document.createElement('button');done.type='button';
    done.textContent=claimed?'claimed':'claim';
    done.onclick=()=>{toggle('claimed',d.canonicalUrl);};
    actions.append(fav,done);card.appendChild(actions);
    grid.appendChild(card);
  }
}
function toggle(kind,url){
  const list=state.personal[kind];const i=list.indexOf(url);
  if(i>=0)list.splice(i,1);else list.unshift(url);
  savePersonal(state.personal);render();
}
function updateStatus(payload){
  const s=payload.stats||{};const health=payload.sourceHealth||{};
  el('status').textContent='';
  const dot=document.createElement('span');
  const ok=health.ok===health.total&&health.total>0;const bad=health.ok===0;
  dot.className='dot '+(ok?'ok':bad?'bad':'warn');
  el('status').appendChild(dot);
  el('status').append(document.createTextNode(
    `sources ${health.ok||0}/${health.total||0} · ${payload.activeCount||0} deals · ${payload.newCount||0} new`));
  const stamp=el('stamp');stamp.textContent=payload.lastUpdatedLabel?('last round '+payload.lastUpdatedLabel):'no finished round yet';
  const banner=el('banner');
  const messages=(payload.anomalies||[]);
  if(payload.freshness&&payload.freshness.severe){messages.unshift('Data is severely stale.');}
  else if(payload.freshness&&payload.freshness.stale){messages.unshift('Data is stale.');}
  if(messages.length){banner.textContent=messages.join(' · ');banner.hidden=false;
    banner.className='banner '+(payload.freshness&&payload.freshness.severe?'bad':'warn');}
  else{banner.hidden=true;}
  if((payload.failures||[]).length){el('failures').textContent=payload.failures.map(f=>`${f.sourceName}: ${f.error}`).join(' · ');}
  else{el('failures').textContent='';}
}
async function loadBoard(){
  try{
    const response=await fetch('/api/deals?limit=2000',{headers:{'accept':'application/json'},cache:'no-store'});
    if(!response.ok)throw new Error('HTTP '+response.status);
    const payload=await response.json();
    state.deals=payload.deals||[];state.source=state.source||'all';
    const select=el('source');
    if(select.options.length<=1){
      for(const source of payload.sources||[]){
        const option=document.createElement('option');option.value=source.id;option.textContent=source.name;
        select.appendChild(option);}
    }
    updateStatus(payload);render();
  }catch(error){el('failures').textContent='Board unavailable: '+error.message;}
}
function wire(){
  el('query').addEventListener('input',event=>{state.query=event.target.value;render();});
  el('category').addEventListener('change',event=>{state.category=event.target.value;render();});
  el('source').addEventListener('change',event=>{state.source=event.target.value;render();});
  el('showAll').addEventListener('change',event=>{state.showAll=event.target.checked;saveShowAll(state.showAll);render();});
  el('refresh').addEventListener('click',async event=>{
    const button=event.target;button.disabled=true;
    try{const response=await fetch('/api/refresh',{method:'POST'});if(!response.ok)throw new Error('HTTP '+response.status);}
    catch(error){el('failures').textContent='Refresh failed: '+error.message;}
    finally{button.disabled=false;await loadBoard();}
  });
  el('showAll').checked=state.showAll;
  loadBoard();
  setInterval(()=>{if(document.visibilityState==='visible')loadBoard();},30000);
  document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible')loadBoard();});
  window.addEventListener('focus',()=>loadBoard());
}
document.addEventListener('DOMContentLoaded',wire);")

(defun render-login-page (&key error need-token)
  (with-output-to-string (out)
    (format out "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">
<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">
<title>Sign in · deal-aggregator</title><style>~a</style></head><body>
<div class=\"login\"><h1>deal-aggregator</h1>
<p>~a</p><form method=\"post\" action=\"/login\">
<label for=\"token\">Access token</label>
<input id=\"token\" name=\"token\" type=\"password\" autocomplete=\"current-password\" autofocus required>
<button type=\"submit\">Sign in</button></form>"
            +page-css+
            (if need-token
                "This instance is protected. Enter the shared access token."
                "Enter the shared access token to continue."))
    (when error
      (format out "<p class=\"error\">~a</p>" (escape-html error)))
    (write-string "</div></body></html>" out)))

(defun render-board-page (board)
  (with-output-to-string (out)
    (format out "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">
<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">
<title>deal-aggregator</title><style>~a</style></head><body>
<header><div class=\"wrap bar\">
<span class=\"brand\">deal-aggregator</span>
<span class=\"status\" id=\"status\">sources ~d/~d · ~d deals</span>
<span class=\"status\" id=\"stamp\">~a</span>
<span style=\"margin-left:auto\"></span>
<button type=\"button\" id=\"refresh\">Refresh now</button>
</div></header>
<main class=\"wrap\">
<div class=\"banner\" id=\"banner\" hidden></div>
<div class=\"status\" id=\"failures\" style=\"color:var(--danger);margin-bottom:12px\"></div>
<div class=\"controls\">
<input id=\"query\" type=\"search\" placeholder=\"Search titles and summaries\" autocomplete=\"off\">
<select id=\"category\">
<option value=\"all\">All categories</option>
<option value=\"favorites\">Saved only</option>
<option value=\"freebie\">免费白嫖</option>
<option value=\"limited-free\">限免</option>
<option value=\"low-price\">低价优惠</option>
<option value=\"membership\">会员订阅</option>
<option value=\"game\">游戏</option>
<option value=\"other\">其他</option>
</select>
<select id=\"source\"><option value=\"all\">All sources</option></select>
<label class=\"status\"><input type=\"checkbox\" id=\"showAll\"> show claimed</label>
<span class=\"status\" id=\"count\"></span>
</div>
<section class=\"grid\" id=\"deals\"></section>
<footer class=\"wrap\"><span>Classification is a title heuristic over public feeds. Check the original listing before claiming anything.</span></footer>
</main>
<script>~a</script></body></html>"
            +page-css+
            (board-source-health-ok board)
            (board-source-health-total board)
            (board-active-count board)
            (escape-html (or (board-last-updated-label board) "no finished round yet"))
            +page-js+)))
