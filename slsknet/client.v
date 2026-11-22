module slsknet

import net
import sync
import time
import conf
import logx
import proto
import shares
import uploads

// Error codes carried by errors returned from Client.run().
pub const err_code_auth = 7001 // authentication was rejected; retrying is pointless
pub const err_code_relogged = 7002 // the account was used from another location
pub const err_code_listen = 7003 // cannot listen on the configured port

// Client is the Soulseek daemon: server session, peer listener, shares and upload scheduler.
@[heap]
pub struct Client {
pub mut:
	cfg   conf.Config
	log   &logx.Logger
	store &shares.Store
	queue &uploads.Queue
mut:
	mu                &sync.Mutex = sync.new_mutex()
	stopping          bool
	server            &Conn = unsafe { nil }
	session_id        int
	logged_in         bool
	session_ok        bool // the last session got as far as a successful login
	own_ip            string
	listener          &net.TcpListener = unsafe { nil }
	peers             map[string]&Conn
	pending           map[u32]chan &Conn // indirect connection waiters by token
	transfer_waiters  map[u32]chan proto.TransferResponse
	addr_waiters      map[string][]chan proto.PeerAddress
	token_counter     u32
	active_users      map[string]bool
	active_uploads    int
	wake              chan bool = chan bool{cap: 1}
	search_seen       map[string]bool
	search_inflight   int
	browse_idx        &shares.Index = unsafe { nil }
	browse_cache      []u8
	avg_speed         u32
	parent            &Conn = unsafe { nil }
	parent_connecting bool
}

// new_client creates a client; call scan_shares() and then run().
pub fn new_client(cfg conf.Config, log &logx.Logger) &Client {
	return &Client{
		cfg:           cfg
		log:           unsafe { log }
		store:         shares.new_store()
		queue:         uploads.new_queue(cfg.transfers.upload.max_queued_per_user)
		token_counter: u32(time.now().unix() % 1_000_000) * 100
	}
}

pub fn (mut c Client) is_stopping() bool {
	c.mu.lock()
	v := c.stopping
	c.mu.unlock()
	return v
}

fn (mut c Client) next_token() u32 {
	c.mu.lock()
	c.token_counter++
	t := c.token_counter
	c.mu.unlock()
	return t
}

fn (mut c Client) username() string {
	return c.cfg.soulseek.username
}

// scan_shares (re)builds the share index.
pub fn (mut c Client) scan_shares() ! {
	c.log.info('scanning shared directories: ${c.cfg.shares.directories.join(', ')}')
	sw := time.new_stopwatch()
	res := shares.scan(c.cfg.shares.directories, c.cfg.shares.filters)!
	c.store.replace(res.index)
	c.log.info('share scan complete: ${res.index.file_count()} files in ${res.index.dir_count()} directories (${res.skipped} skipped) in ${sw.elapsed().milliseconds()} ms')
	c.send_shared_counts()
}

// reload applies a new configuration (shares and upload limits) and rescans the shares.
pub fn (mut c Client) reload(cfg conf.Config) {
	c.cfg.shares = cfg.shares
	c.cfg.transfers = cfg.transfers
	c.cfg.soulseek.description = cfg.soulseek.description
	c.queue.set_limit(cfg.transfers.upload.max_queued_per_user)
	c.scan_shares() or { c.log.error('share scan failed: ${err}') }
	c.wake_dispatcher()
}

fn (mut c Client) send_shared_counts() {
	idx := c.store.current()
	c.server_send(proto.encode_shared_folders_files(u32(idx.dir_count()), u32(idx.file_count()))) or {}
}

fn (mut c Client) wake_dispatcher() {
	select {
		c.wake <- true {
		}
		else {
		}
	}
}

// run connects to the server (reconnecting as needed) and serves until stop() is called.
// It returns an error only for fatal conditions (rejected credentials, port in use).
pub fn (mut c Client) run() ! {
	c.start_listener()!
	spawn c.dispatch_loop()
	if c.cfg.shares.rescan_interval_minutes > 0 {
		spawn c.rescan_loop()
	}
	mut backoff := 5
	for !c.is_stopping() {
		c.session_ok = false
		c.session() or {
			if err.code() == err_code_auth || err.code() == err_code_relogged {
				return err
			}
			if !c.is_stopping() {
				c.log.warn('server connection lost: ${err}')
			}
		}
		if c.is_stopping() {
			break
		}
		if c.session_ok {
			backoff = 5
		}
		c.log.info('reconnecting to the server in ${backoff} s')
		for _ in 0 .. backoff * 5 {
			if c.is_stopping() {
				break
			}
			time.sleep(200 * time.millisecond)
		}
		backoff = if backoff * 2 > 300 { 300 } else { backoff * 2 }
	}
}

fn (mut c Client) rescan_loop() {
	interval := c.cfg.shares.rescan_interval_minutes * 60
	mut waited := 0
	for !c.is_stopping() {
		time.sleep(1 * time.second)
		waited++
		if waited >= interval {
			waited = 0
			c.scan_shares() or { c.log.error('periodic share scan failed: ${err}') }
		}
	}
}

// stop shuts everything down; active uploads get a short grace period.
pub fn (mut c Client) stop() {
	c.mu.lock()
	if c.stopping {
		c.mu.unlock()
		return
	}
	c.stopping = true
	mut l := c.listener
	mut server := c.server
	c.mu.unlock()
	c.log.info('shutting down')
	if !isnil(l) {
		l.close() or {}
	}
	// give running uploads a few seconds to finish
	for _ in 0 .. 50 {
		c.mu.lock()
		n := c.active_uploads
		c.mu.unlock()
		if n == 0 {
			break
		}
		time.sleep(200 * time.millisecond)
	}
	if !isnil(server) {
		server.close()
	}
	c.mu.lock()
	mut conns := []&Conn{}
	for _, p in c.peers {
		conns << p
	}
	if !isnil(c.parent) {
		conns << c.parent
	}
	c.mu.unlock()
	for mut p in conns {
		p.close()
	}
}
