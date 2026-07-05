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

# ── HTML page ────────────────────────────────────────────────────────────────
# The page lives in dashboard.html next to this file (easier to edit than a Ruby
# heredoc). {{TOKEN}} and {{ROOT}} placeholders are substituted here at serve time.
DASHBOARD_HTML = File.expand_path("dashboard.html", __dir__)

def html_escape(s)
  s.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
end

def page_html
  File.read(DASHBOARD_HTML)
      .gsub("{{TOKEN}}", TOKEN)
      .gsub("{{ROOT}}", html_escape(ROOT))
rescue StandardError => e
  %(<!doctype html><meta charset=utf-8><pre style="font:14px monospace;padding:24px">) +
    "dashboard.html could not be read next to claude-dashboard.rb\n\n" +
    html_escape(e.message) + "</pre>"
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
