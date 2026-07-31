#!/usr/bin/env ruby
# frozen_string_literal: true
#
# claude-dashboard.rb — localhost usage dashboard for claude-account-switch.sh
#
# A tiny single-file sidecar: it serves one self-contained HTML page plus a small
# JSON API on 127.0.0.1 ONLY (tokens/usage must never touch the LAN — each person
# runs their own instance). Read-only data comes from the CLI's `list --json`
# contract; the mutating endpoints shell straight back into the bash CLI so
# `refresh`/`activate`/`add` reuse the existing, battle-tested logic verbatim.
#
# `add` is the one that cannot finish inside a request — see the job model below.
#
# Launched by:  claude-account-switch.sh serve [--port N] [--open]
# which execs:  ruby claude-dashboard.rb --root <PROFILE_ROOT> --script <cli> [...]
#
# Stdlib only: webrick, fileutils, json, open3, optparse, securerandom.

begin
  require 'webrick'
rescue LoadError
  warn "claude-dashboard: the 'webrick' gem is required but not installed."
  warn 'Install it with:  gem install webrick'
  exit 1
end
require 'fileutils'
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

# Read-only session pool — same shape the CLI's `sessions --json` prints, for the
# same reason as read_profiles: one contract, so the page and the terminal never
# disagree. The scan itself stays in the CLI; nothing about transcripts is
# reimplemented here.
def read_sessions(limit = 40)
  out, _status = Open3.capture2e(SCRIPT, 'sessions', '--json', '--limit', limit.to_s)
  parsed = JSON.parse(out)
  parsed.is_a?(Array) ? parsed : []
rescue StandardError
  []
end

# Read-only usage history and the ranked "which account next" answer. Both are
# the CLI's own contracts (`history --json`, `next --json`) for the third time
# and the same reason: the ranking rules in particular must have exactly one
# home, or the page and the terminal will start recommending different accounts.
def read_history(points = 48)
  out, _status = Open3.capture2e(SCRIPT, 'history', '--json', '--points', points.to_s)
  parsed = JSON.parse(out)
  parsed.is_a?(Array) ? parsed : []
rescue StandardError
  []
end

def read_next
  out, _status = Open3.capture2e(SCRIPT, 'next', '--json')
  parsed = JSON.parse(out)
  parsed.is_a?(Hash) ? parsed : {}
rescue StandardError
  {}
end

# Shell a mutation back into the bash CLI. Returns [ok, combined_output] with any
# ANSI colour escapes stripped so the output is clean when surfaced in the UI.
def run_cli(*args)
  out, status = Open3.capture2e(SCRIPT, *args)
  [status.success?, out.gsub(/\e\[[0-9;?]*[A-Za-z]/, '')]
rescue StandardError => e
  [false, e.message]
end

# ── Adding an account ─────────────────────────────────────────────────────────
# `claudius add` needs a human in a browser, so it cannot finish inside a POST.
# It runs as a background job instead, with a PIPE on its stdin — verified to work:
# `claude auth login` prints its sign-in URL to stdout and does not require a TTY.
# A pipe rather than a pty is deliberate. A pty echoes what is written to it, which
# would put the pasted authorization code straight into the log this page displays;
# with a pipe there is no echo to worry about.
#
# The flow ends in one of two ways — the browser hands the terminal the login, or
# the page shows a code to paste — and BOTH then wait on a newline. So success is
# detected from the FILESYSTEM (the profile's .credentials.json appearing) rather
# than by scraping "all done" out of the output, and the trailing newline is
# supplied here the moment that happens. One code path covers both variants, and
# the page's only interactive element is the code field.
#
# The code itself is write-only: it goes to the child's stdin and is never logged,
# never echoed back in a response, and scrubbed from the log tail on the way out in
# case the child ever prints what it read.

# A sign-in nobody finishes is reaped. Overridable so tests/add.sh can prove the
# reaper actually fires without sitting there for ten minutes; clamped so the
# override cannot disable it.
ADD_DEADLINE = [[(ENV["CLAUDIUS_ADD_DEADLINE"] || 600).to_i, 1].max, 3600].min
ADD_LOG_MAX  = 8_000    # keep the tail bounded; this is a progress log, not a file
ADD_LOCK = Mutex.new
ADD_JOB  = { job: nil }

# Mirrors the CLI's sanitize_profile_name. A name that would be rewritten is
# refused rather than quietly altered, because the page then has to poll for a name
# that never appears — and because this string reaches an rm_rf below.
def valid_profile_name?(name)
  !name.empty? && name.length <= 64 && name.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/)
end

def add_job_public(job)
  log = job[:log].dup
  # Belt and braces: the child has no tty echo, but if it ever prints the code
  # back, it must not reach the browser.
  log = log.gsub(job[:secret], '[code]') if job[:secret] && !job[:secret].empty?
  {
    id: job[:id], name: job[:name], state: job[:state],
    url: log[%r{https?://\S+}],
    needs_code: log.include?('Paste code'),
    activated: job[:activate],
    log: log.length > ADD_LOG_MAX ? log[-ADD_LOG_MAX..] : log,
    error: job[:error]
  }
end

# Remove a profile directory this job created and did not finish. Guarded twice
# over: the name passed valid_profile_name? before the job started, and the path is
# rebuilt from ROOT here rather than carried around as a string.
def add_discard(name)
  return unless valid_profile_name?(name)
  dir = File.join(ROOT, name)
  FileUtils.rm_rf(dir) if File.directory?(dir) && File.dirname(dir) == ROOT
rescue StandardError
  nil
end

def add_start(name, activate)
  args = ['add', name]
  args << '--no-activate' unless activate
  # Its own process group. `claudius add` runs `claude auth login` as a CHILD, so
  # signalling the bash pid alone would leave that child alive, still holding the
  # stdin pipe — the exact leak this job model exists to prevent.
  stdin, out, wait = Open3.popen2e(SCRIPT, *args, pgroup: true)
  job = { id: SecureRandom.hex(8), name: name, state: 'running', log: +'',
          stdin: stdin, wait: wait, activate: activate, secret: nil,
          started: Time.now, nudged: false, error: nil }

  # Reader: everything the CLI says, as it says it.
  Thread.new do
    begin
      # Char at a time, not line at a time: the prompt this flow ends on
      # ("Paste code here if prompted > ") carries no newline, so a line reader
      # would never surface the one thing the page most needs to show.
      out.each_char { |c| ADD_LOCK.synchronize { job[:log] << c } }
    rescue StandardError
      nil
    ensure
      out.close rescue nil
    end
  end

  # Supervisor: watches for the credentials to land, answers the trailing prompt,
  # and enforces the deadline so an abandoned sign-in cannot leave a child and a
  # half-made profile behind for the rest of the session.
  Thread.new do
    creds = File.join(ROOT, name, '.credentials.json')
    loop do
      break unless job[:state] == 'running'
      if !job[:nudged] && File.size?(creds)
        job[:nudged] = true
        # Both variants stop at "press enter" once the sign-in is through. Nobody
        # should have to press it twice, so it is answered here.
        begin; stdin.write("\n"); stdin.flush; rescue StandardError; nil; end
      end
      # A terminal state is published LAST, after any cleanup has finished. The
      # page reloads the profile list the moment it sees one, and a half-made
      # profile still on disk at that instant would read as a real account.
      unless wait.alive?
        code = begin; wait.value.exitstatus; rescue StandardError; 1; end
        ok = code.zero? && File.size?(creds)
        add_discard(name) unless ok
        ADD_LOCK.synchronize do
          job[:error] = 'the sign-in did not complete' unless ok
          job[:state] = ok ? 'done' : 'failed'
        end
        break
      end
      if Time.now - job[:started] > ADD_DEADLINE
        # 'stopping' is not terminal, and it takes this loop out of the running
        # branch so nothing else claims the job while it is being torn down.
        ADD_LOCK.synchronize { job[:state] = 'stopping' }
        add_stop(job)
        add_discard(name)
        ADD_LOCK.synchronize do
          job[:error] = 'the sign-in was not finished in time'
          job[:state] = 'expired'
        end
        break
      end
      sleep 0.4
    end
    job[:secret] = nil            # the code outlives nothing
    stdin.close rescue nil
  end

  job
end

# Signals the whole process group, so `claude` goes with the `claudius` that
# started it. Falls back to the bare pid if the group has already gone.
def add_stop(job)
  pid = job[:wait].pid
  ['TERM', 'KILL'].each do |sig|
    break unless job[:wait].alive?
    begin
      Process.kill('-' + sig, pid)
    rescue StandardError
      begin
        Process.kill(sig, pid)
      rescue StandardError
        nil
      end
    end
    sleep 0.3
  end
rescue StandardError
  nil
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

server.mount_proc('/api/sessions') do |req, res|
  raw = query_param(req, 'limit')
  # An explicit limit=0 asks for the whole pool and is honoured — the page only
  # sends it when someone presses the button that says so. Anything else is
  # clamped: a positive value to a sane ceiling, junk or absence to the default.
  limit = if raw == '0' then 0
          elsif raw.to_i > 0 then [raw.to_i, 500].min
          else 40
          end
  json_response(res, read_sessions(limit))
end

server.mount_proc('/api/history') do |req, res|
  raw = query_param(req, 'points')
  points = raw.to_i > 0 ? [raw.to_i, 500].min : 48
  json_response(res, read_history(points))
end

server.mount_proc('/api/next') do |_req, res|
  json_response(res, read_next)
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

server.mount_proc('/api/add') do |req, res|
  if req.request_method != 'POST'
    json_response(res, { ok: false, error: 'POST required' }, 405)
  elsif !authorized?(req)
    json_response(res, { ok: false, error: 'forbidden' }, 403)
  else
    name = query_param(req, 'profile')
    # The CLI would ask "overwrite it?" for a name that exists, and answering that
    # prompt on someone's behalf is not the sidecar's business — so an existing
    # name is refused here instead.
    existing = valid_profile_name?(name) && File.directory?(File.join(ROOT, name))
    # 'stopping' counts as in flight: it is still tearing a profile dir down, and
    # starting another sign-in over the top of that is how you lose one.
    busy_states = ['running', 'stopping']
    running = ADD_LOCK.synchronize { ADD_JOB[:job] && busy_states.include?(ADD_JOB[:job][:state]) }
    if !valid_profile_name?(name)
      json_response(res, { ok: false,
                           error: 'a name may use letters, digits, dot, dash and underscore' }, 400)
    elsif existing
      json_response(res, { ok: false, error: "#{name} already exists" }, 409)
    elsif running
      json_response(res, { ok: false, error: 'a sign-in is already in progress' }, 409)
    else
      job = add_start(name, query_param(req, 'activate') == '1')
      ADD_LOCK.synchronize { ADD_JOB[:job] = job }
      json_response(res, { ok: true }.merge(add_job_public(job)))
    end
  end
end

server.mount_proc('/api/add/status') do |req, res|
  job = ADD_LOCK.synchronize { ADD_JOB[:job] }
  if job.nil? || (!query_param(req, 'id').empty? && query_param(req, 'id') != job[:id])
    json_response(res, { ok: false, error: 'no such job' }, 404)
  else
    payload = ADD_LOCK.synchronize { add_job_public(job) }
    payload[:profiles] = read_profiles if payload[:state] == 'done'
    json_response(res, { ok: true }.merge(payload))
  end
end

# The authorization code, and nothing else, goes to the child's stdin. It arrives
# in the request BODY rather than the query string — a query string is the one part
# of a localhost URL that ends up in browser history — and the response says only
# that it was accepted.
server.mount_proc('/api/add/code') do |req, res|
  job = ADD_LOCK.synchronize { ADD_JOB[:job] }
  if req.request_method != 'POST'
    json_response(res, { ok: false, error: 'POST required' }, 405)
  elsif !authorized?(req)
    json_response(res, { ok: false, error: 'forbidden' }, 403)
  elsif job.nil? || job[:state] != 'running'
    json_response(res, { ok: false, error: 'no sign-in is waiting' }, 409)
  else
    body = begin; JSON.parse(req.body.to_s); rescue StandardError; {}; end
    # One line, and only one: newlines are stripped so a pasted blob cannot answer
    # prompts this endpoint was never meant to reach.
    code = body['code'].to_s.gsub(/[\r\n]/, '').strip[0, 512]
    if code.empty?
      json_response(res, { ok: false, error: 'no code given' }, 400)
    else
      job[:secret] = code
      begin
        job[:stdin].write(code + "\n")
        job[:stdin].flush
        json_response(res, { ok: true })
      rescue StandardError
        json_response(res, { ok: false, error: 'the sign-in is no longer listening' }, 409)
      end
    end
  end
end

server.mount_proc('/api/add/cancel') do |req, res|
  job = ADD_LOCK.synchronize { ADD_JOB[:job] }
  if req.request_method != 'POST'
    json_response(res, { ok: false, error: 'POST required' }, 405)
  elsif !authorized?(req)
    json_response(res, { ok: false, error: 'forbidden' }, 403)
  elsif job.nil?
    json_response(res, { ok: false, error: 'no such job' }, 404)
  else
    if job[:state] == 'running'
      ADD_LOCK.synchronize { job[:state] = 'stopping' }
      add_stop(job)
      add_discard(job[:name])
      ADD_LOCK.synchronize do
        job[:error] = 'cancelled'
        job[:state] = 'cancelled'
      end
    end
    json_response(res, { ok: true, state: job[:state] })
  end
end

url = "http://127.0.0.1:#{opts[:port]}/"
# A sign-in in flight when the sidecar goes down would otherwise be orphaned: a
# `claude` waiting on a pipe nobody holds, and a half-made profile dir.
# A `proc`, not a lambda: `trap` hands the handler the signal number, and a lambda
# with no parameters raises on the extra argument — inside a trap, where the error
# is swallowed and the process simply never shuts down.
shutdown = proc do
  job = ADD_JOB[:job]
  if job && job[:state] == 'running'
    job[:state] = 'cancelled'
    add_stop(job)
    add_discard(job[:name])
  end
  server.shutdown
end
trap('INT', &shutdown)
trap('TERM', &shutdown)

if opts[:open]
  opener = %w[xdg-open open].find { |c| system("command -v #{c} >/dev/null 2>&1") }
  opener ||= 'start' if RUBY_PLATFORM =~ /mswin|mingw|cygwin/
  Thread.new { sleep 0.6; system(opener, url) if opener } if opener
end

puts "claude-dashboard: serving #{url} (bound to 127.0.0.1 only)"
puts 'Press Ctrl-C to stop.'
server.start
