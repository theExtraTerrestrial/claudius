#!/usr/bin/env ruby
# frozen_string_literal: true
#
# claude-dashboard.rb — localhost usage dashboard for claude-account-switch.sh
#
# A tiny single-file sidecar: it serves one self-contained HTML page plus a small
# JSON API on 127.0.0.1 ONLY (tokens/usage must never touch the LAN — each person
# runs their own instance). Read-only data comes from the CLI's `list --json`
# contract; the two mutating endpoints shell straight back into the bash CLI so
# `refresh`/`activate` reuse the existing, battle-tested logic verbatim.
#
# Launched by:  claude-account-switch.sh serve [--port N] [--open]
# which execs:  ruby claude-dashboard.rb --root <PROFILE_ROOT> --script <cli> [...]
#
# Stdlib only: webrick, json, open3, optparse, securerandom.

begin
  require 'webrick'
rescue LoadError
  warn "claude-dashboard: the 'webrick' gem is required but not installed."
  warn 'Install it with:  gem install webrick'
  exit 1
end
require 'json'
require 'open3'
require 'optparse'
require 'securerandom'

opts = {
  port: 8787,
  open: false,
  root: File.join(Dir.home, '.claude-profiles'),
  script: File.join(Dir.home, 'claude-account-switch.sh'),
}

OptionParser.new do |o|
  o.banner = 'usage: claude-dashboard.rb [--port N] [--open] --root DIR --script PATH'
  o.on('--port N', Integer, 'port to bind (default 8787)') { |v| opts[:port] = v }
  o.on('--open', 'open the dashboard in a browser') { opts[:open] = true }
  o.on('--root DIR', 'profile root directory') { |v| opts[:root] = v }
  o.on('--script PATH', 'path to claude-account-switch.sh') { |v| opts[:script] = v }
end.parse!(ARGV)

SCRIPT = opts[:script]
ROOT   = opts[:root]
# CSRF/drive-by guard: a random token minted per run, embedded in the page and
# required on every mutating POST. Localhost is still reachable by any page in the
# user's browser, so this stops a malicious site from POSTing to the API blindly.
TOKEN  = SecureRandom.hex(16)

unless File.file?(SCRIPT)
  warn "claude-dashboard: CLI script not found: #{SCRIPT}"
  exit 1
end

# ── Data access ───────────────────────────────────────────────────────────────
# Read-only profile list — delegates to the CLI's stable `list --json` contract so
# the dashboard and the terminal always agree. Returns a parsed array (or []).
def read_profiles
  out, _status = Open3.capture2e(SCRIPT, 'list', '--json')
  JSON.parse(out)
rescue StandardError
  []
end

# Shell a mutation back into the bash CLI. Returns [ok, combined_output] with any
# ANSI colour escapes stripped so the output is clean when surfaced in the UI.
def run_cli(*args)
  out, status = Open3.capture2e(SCRIPT, *args)
  [status.success?, out.gsub(/\e\[[0-9;?]*[A-Za-z]/, '')]
rescue StandardError => e
  [false, e.message]
end

def json_response(res, obj, status = 200)
  res.status = status
  res['Content-Type'] = 'application/json'
  res.body = JSON.generate(obj)
end

# Reject cross-site POSTs lacking the per-run token.
def authorized?(req)
  req['X-CSRF-Token'] == TOKEN
end

# Read a param from the URL query string. WEBrick's req.query parses the POST body
# (not the URL) for POST requests, so read the query string explicitly instead.
def query_param(req, key)
  WEBrick::HTTPUtils.parse_query(req.query_string)[key].to_s
end

# ── HTML page (self-contained: inline CSS/JS, no CDN) ─────────────────────────
def page_html
  <<~HTML
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta name="csrf-token" content="#{TOKEN}">
      <title>Claude accounts</title>
      <style>
        :root{
          --bg:#0f1115; --panel:#171a21; --panel2:#1d212b; --line:#262b36;
          --fg:#e6e9ef; --muted:#9aa4b2; --dim:#6b7280;
          --accent:#39a0ff; --green:#3ecf8e; --amber:#f5a623; --red:#ff5f56;
          --active:#1b3a2a;
        }
        @media (prefers-color-scheme: light){
          :root{
            --bg:#f5f6f8; --panel:#ffffff; --panel2:#f0f2f5; --line:#e2e5ea;
            --fg:#1a1d23; --muted:#5b6472; --dim:#8a93a1;
            --active:#e3f6ec;
          }
        }
        *{box-sizing:border-box}
        body{margin:0;font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
          background:var(--bg);color:var(--fg);-webkit-font-smoothing:antialiased}
        header{display:flex;align-items:center;gap:12px;padding:20px 24px;border-bottom:1px solid var(--line)}
        header h1{font-size:16px;margin:0;font-weight:650;letter-spacing:.2px}
        header .root{color:var(--dim);font-size:12px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
        header .spacer{flex:1}
        button{font:inherit;cursor:pointer;border:1px solid var(--line);background:var(--panel2);
          color:var(--fg);padding:6px 12px;border-radius:8px;transition:background .12s,border-color .12s}
        button:hover{border-color:var(--accent)}
        button:disabled{opacity:.5;cursor:default}
        button.primary{background:var(--accent);border-color:var(--accent);color:#fff}
        .wrap{max-width:820px;margin:0 auto;padding:24px}
        .toolbar{display:flex;align-items:center;gap:10px;margin-bottom:16px}
        .toolbar .status{color:var(--dim);font-size:12px;margin-left:auto}
        .card{background:var(--panel);border:1px solid var(--line);border-radius:14px;
          padding:16px 18px;margin-bottom:14px}
        .card.active{border-color:var(--green);background:linear-gradient(0deg,var(--active),var(--panel) 60%)}
        .card .top{display:flex;align-items:center;gap:10px}
        .card .name{font-weight:650;font-size:15px}
        .card .dot{width:8px;height:8px;border-radius:50%;background:var(--green);box-shadow:0 0 0 3px rgba(62,207,142,.18)}
        .card .ident{color:var(--muted);font-size:12.5px;margin-top:2px}
        .badge{font-size:11px;padding:2px 8px;border-radius:999px;border:1px solid var(--line);
          color:var(--muted);text-transform:uppercase;letter-spacing:.4px}
        .badge.active{color:var(--green);border-color:var(--green)}
        .card .actions{margin-left:auto;display:flex;gap:8px}
        .meters{display:grid;grid-template-columns:1fr 1fr;gap:14px;margin-top:14px}
        @media (max-width:560px){.meters{grid-template-columns:1fr}}
        .meter .lbl{display:flex;justify-content:space-between;font-size:12px;color:var(--muted);margin-bottom:5px}
        .meter .lbl b{color:var(--fg);font-variant-numeric:tabular-nums}
        .bar{height:8px;border-radius:6px;background:var(--panel2);overflow:hidden;border:1px solid var(--line)}
        .bar>span{display:block;height:100%;border-radius:6px;transition:width .3s}
        .g{background:var(--green)} .a{background:var(--amber)} .r{background:var(--red)}
        .none{color:var(--dim);font-size:12px}
        .age{color:var(--dim);font-size:11.5px;margin-top:12px}
        .empty{color:var(--muted);text-align:center;padding:60px 0}
        .spin{display:inline-block;width:12px;height:12px;border:2px solid var(--line);
          border-top-color:var(--accent);border-radius:50%;animation:s .7s linear infinite;vertical-align:-1px}
        @keyframes s{to{transform:rotate(360deg)}}
        .toast{position:fixed;bottom:20px;left:50%;transform:translateX(-50%);background:var(--panel);
          border:1px solid var(--line);border-radius:10px;padding:10px 16px;font-size:13px;
          box-shadow:0 6px 24px rgba(0,0,0,.3);opacity:0;transition:opacity .2s;pointer-events:none}
        .toast.show{opacity:1}
      </style>
    </head>
    <body>
      <header>
        <h1>Claude accounts</h1>
        <span class="root">#{ROOT}</span>
      </header>
      <div class="wrap">
        <div class="toolbar">
          <button id="refreshAll" class="primary">Refresh all</button>
          <label style="font-size:12px;color:var(--muted);display:flex;align-items:center;gap:6px">
            <input type="checkbox" id="autopoll"> auto-poll cache
          </label>
          <span class="status" id="status"></span>
        </div>
        <div id="cards"><div class="empty"><span class="spin"></span> loading…</div></div>
      </div>
      <div class="toast" id="toast"></div>
      <script>
        const TOKEN = document.querySelector('meta[name=csrf-token]').content;
        const $ = s => document.querySelector(s);
        const esc = s => String(s==null?'':s).replace(/[&<>"']/g, c =>
          ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

        function cls(p){ return p>=80?'r':p>=50?'a':'g'; }
        function ago(uts){
          if(!uts) return 'no cache';
          let d = Math.max(0, Math.floor(Date.now()/1000) - uts);
          if(d<60) return 'just now';
          if(d<3600) return Math.floor(d/60)+'m ago';
          if(d<86400) return Math.floor(d/3600)+'h ago';
          return Math.floor(d/86400)+'d ago';
        }
        function meter(label, p){
          if(p==null) return `<div class="meter"><div class="lbl"><span>${label}</span></div>`+
            `<div class="none">no data</div></div>`;
          return `<div class="meter"><div class="lbl"><span>${label}</span><b>${p}%</b></div>`+
            `<div class="bar"><span class="${cls(p)}" style="width:${Math.min(100,p)}%"></span></div></div>`;
        }
        function card(p){
          const ident = p.email ? esc(p.email) + (p.org? ' · '+esc(p.org):'') : '(no identity saved)';
          return `<div class="card ${p.active?'active':''}" data-name="${esc(p.name)}">
            <div class="top">
              ${p.active?'<span class="dot"></span>':''}
              <div>
                <div class="name">${esc(p.name)}</div>
                <div class="ident">${ident}</div>
              </div>
              <span class="badge ${p.active?'active':''}">${p.active?'active':esc(p.sub||'—')}</span>
              <div class="actions">
                <button class="ref" data-name="${esc(p.name)}">Refresh</button>
                ${p.active?'':`<button class="act" data-name="${esc(p.name)}">Activate</button>`}
              </div>
            </div>
            <div class="meters">${meter('5h window', p.u5)}${meter('7d window', p.u7)}</div>
            <div class="age">cache: ${ago(p.uts)}</div>
          </div>`;
        }

        function render(list){
          if(!list.length){ $('#cards').innerHTML = '<div class="empty">No profiles found.</div>'; return; }
          $('#cards').innerHTML = list.map(card).join('');
        }

        let toastT;
        function toast(msg){
          const t = $('#toast'); t.textContent = msg; t.classList.add('show');
          clearTimeout(toastT); toastT = setTimeout(()=>t.classList.remove('show'), 2600);
        }
        function setStatus(s){ $('#status').innerHTML = s; }

        async function load(){
          try{
            const r = await fetch('/api/profiles'); render(await r.json());
            setStatus('updated ' + new Date().toLocaleTimeString());
          }catch(e){ setStatus('load failed'); }
        }

        async function post(path, name, btn){
          const old = btn ? btn.textContent : null;
          if(btn){ btn.disabled = true; btn.innerHTML = '<span class="spin"></span>'; }
          try{
            const r = await fetch(path+'?profile='+encodeURIComponent(name), {
              method:'POST', headers:{'X-CSRF-Token':TOKEN}
            });
            const data = await r.json();
            if(!r.ok || data.ok===false){ toast(data.error || 'action failed'); }
            if(Array.isArray(data.profiles)) render(data.profiles); else await load();
            return data;
          }catch(e){ toast('request failed'); await load(); }
          finally{ if(btn){ btn.disabled=false; if(old) btn.textContent=old; } }
        }

        document.addEventListener('click', e => {
          const ref = e.target.closest('.ref');
          if(ref){ post('/api/refresh', ref.dataset.name, ref); return; }
          const act = e.target.closest('.act');
          if(act){
            if(confirm('Activate "'+act.dataset.name+'"? This switches the global ~/.claude account.'))
              post('/api/activate', act.dataset.name, act);
          }
        });

        $('#refreshAll').addEventListener('click', async e => {
          const btn = e.currentTarget; btn.disabled = true;
          const names = [...document.querySelectorAll('.card')].map(c => c.dataset.name);
          for(const n of names){ setStatus('refreshing '+esc(n)+'… <span class="spin"></span>'); await post('/api/refresh', n); }
          btn.disabled = false; await load();
        });

        let pollT = null;
        $('#autopoll').addEventListener('change', e => {
          if(e.target.checked){ pollT = setInterval(load, 30000); }
          else if(pollT){ clearInterval(pollT); pollT = null; }
        });

        load();
      </script>
    </body>
    </html>
  HTML
end

# ── Server ────────────────────────────────────────────────────────────────────
server = WEBrick::HTTPServer.new(
  BindAddress: '127.0.0.1',           # localhost ONLY — never expose tokens on the LAN
  Port: opts[:port],
  Logger: WEBrick::Log.new(File::NULL),
  AccessLog: []
)

server.mount_proc('/') do |req, res|
  if req.path == '/'
    res['Content-Type'] = 'text/html; charset=utf-8'
    res.body = page_html
  else
    res.status = 404
    res.body = 'not found'
  end
end

server.mount_proc('/api/profiles') do |_req, res|
  json_response(res, read_profiles)
end

server.mount_proc('/api/refresh') do |req, res|
  if req.request_method != 'POST'
    json_response(res, { ok: false, error: 'POST required' }, 405)
  elsif !authorized?(req)
    json_response(res, { ok: false, error: 'forbidden' }, 403)
  else
    name = query_param(req, 'profile')
    if name.empty?
      json_response(res, { ok: false, error: 'missing profile' }, 400)
    else
      ok, out = run_cli('refresh', name)
      json_response(res, { ok: ok, output: out.strip, profiles: read_profiles })
    end
  end
end

server.mount_proc('/api/activate') do |req, res|
  if req.request_method != 'POST'
    json_response(res, { ok: false, error: 'POST required' }, 405)
  elsif !authorized?(req)
    json_response(res, { ok: false, error: 'forbidden' }, 403)
  else
    name = query_param(req, 'profile')
    if name.empty?
      json_response(res, { ok: false, error: 'missing profile' }, 400)
    else
      ok, out = run_cli('activate', name)
      json_response(res, { ok: ok, output: out.strip, profiles: read_profiles })
    end
  end
end

url = "http://127.0.0.1:#{opts[:port]}/"
trap('INT') { server.shutdown }
trap('TERM') { server.shutdown }

if opts[:open]
  opener = %w[xdg-open open].find { |c| system("command -v #{c} >/dev/null 2>&1") }
  opener ||= 'start' if RUBY_PLATFORM =~ /mswin|mingw|cygwin/
  Thread.new { sleep 0.6; system(opener, url) if opener } if opener
end

puts "claude-dashboard: serving #{url} (bound to 127.0.0.1 only)"
puts 'Press Ctrl-C to stop.'
server.start
