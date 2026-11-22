module slsknet

import net
import time
import proto
import shares
import uploads

// ---------------------------------------------------------------------------
// listener
// ---------------------------------------------------------------------------

fn (mut c Client) start_listener() ! {
	addr := '${c.cfg.soulseek.listen_ip}:${c.cfg.soulseek.listen_port}'
	l := net.listen_tcp(.ip, addr) or {
		return error_with_code('cannot listen on ${addr}: ${err}', err_code_listen)
	}
	c.mu.lock()
	c.listener = l
	c.mu.unlock()
	c.log.info('listening for incoming connections on ${addr}')
	spawn c.accept_loop(l)
}

fn (mut c Client) accept_loop(l &net.TcpListener) {
	mut lst := unsafe { l }
	for !c.is_stopping() {
		tc := lst.accept() or {
			if c.is_stopping() {
				return
			}
			time.sleep(100 * time.millisecond)
			continue
		}
		spawn c.handle_incoming(tc)
	}
}

fn (mut c Client) handle_incoming(tc &net.TcpConn) {
	mut conn := new_conn(tc, '', '', true)
	conn.set_read_timeout(15 * time.second)
	payload := conn.read_frame() or {
		conn.close()
		return
	}
	init := proto.decode_init(payload) or {
		c.log.debug('invalid first message from ${conn.remote_ip()}: ${err}')
		conn.close()
		return
	}
	c.log.debug('incoming connection from ${conn.remote_ip()}: ${if init.pierce {
		'pierce firewall'
	} else {
		init.typ + ' init from ' + init.username
	}}')
	if init.pierce {
		c.deliver_pending(init.token, mut conn)
		return
	}
	conn.username = init.username
	conn.typ = init.typ
	match init.typ {
		proto.conn_peer {
			c.run_peer(mut conn)
		}
		else {
			// F connections are initiated by us when uploading, and we do not accept distributed children
			c.log.debug('closing unexpected "${init.typ}" connection from ${init.username} (${conn.remote_ip()})')
			conn.close()
		}
	}
}

// deliver_pending hands a PierceFirewall connection to whoever is waiting for its token.
fn (mut c Client) deliver_pending(token u32, mut conn Conn) {
	c.mu.lock()
	ch := c.pending[token] or {
		c.mu.unlock()
		c.log.debug('closing unsolicited indirect connection (token ${token}) from ${conn.remote_ip()}')
		conn.close()
		return
	}
	c.mu.unlock()
	select {
		ch <- conn {
		}
		else {
			conn.close()
		}
	}
}

// ---------------------------------------------------------------------------
// outgoing connections
// ---------------------------------------------------------------------------

// open_connection connects to a user, directly if possible and via the server otherwise.
// The returned connection has completed the init handshake for the requested type.
fn (mut c Client) open_connection(username string, typ string) !&Conn {
	if addr := c.get_peer_address(username) {
		if addr.port > 0 && addr.ip != '0.0.0.0' {
			if tc := dial_timeout('${addr.ip}:${addr.port}', 8 * time.second) {
				mut conn := new_conn(tc, username, typ, false)
				mut sent := true
				conn.send(proto.encode_peer_init(c.username(), typ, 0)) or { sent = false }
				if sent {
					return conn
				}
				conn.close()
			}
		}
	}
	// indirect: ask the server to make the peer connect to us
	token := c.next_token()
	ch := chan &Conn{cap: 1}
	c.mu.lock()
	c.pending[token] = ch
	c.mu.unlock()
	defer {
		c.mu.lock()
		c.pending.delete(token)
		c.mu.unlock()
	}
	c.server_send(proto.encode_connect_to_peer(token, username, typ))!
	select {
		conn := <-ch {
			mut cn := unsafe { conn }
			cn.username = username
			cn.typ = typ
			return cn
		}
		15 * time.second {
			return error('could not connect to ${username}')
		}
	}
	return error('unreachable')
}

// get_peer_conn returns a live P connection to a user, creating one if necessary.
fn (mut c Client) get_peer_conn(username string) !&Conn {
	c.mu.lock()
	existing := c.peers[username] or { unsafe { nil } }
	c.mu.unlock()
	if !isnil(existing) {
		mut e := unsafe { existing }
		if !e.is_closed() {
			return e
		}
	}
	mut conn := c.open_connection(username, proto.conn_peer)!
	c.register_peer(mut conn)
	spawn c.run_peer(mut conn)
	return conn
}

// handle_connect_to_peer reacts to a server request to connect to a peer (indirect connection).
fn (mut c Client) handle_connect_to_peer(m proto.ConnectToPeer) {
	tc := dial_timeout('${m.ip}:${m.port}', 8 * time.second) or {
		c.log.debug('cannot connect to ${m.username} at ${m.ip}:${m.port} (${m.typ}): ${err}')
		c.server_send(proto.encode_cant_connect_to_peer(m.token, m.username)) or {}
		return
	}
	mut conn := new_conn(tc, m.username, m.typ, false)
	conn.send(proto.encode_pierce_firewall(m.token)) or {
		conn.close()
		return
	}
	if m.typ == proto.conn_peer {
		c.run_peer(mut conn)
	} else {
		c.log.debug('closing "${m.typ}" connection to ${m.username}: not supported')
		conn.close()
	}
}

// ---------------------------------------------------------------------------
// peer connections
// ---------------------------------------------------------------------------

fn (mut c Client) register_peer(mut conn Conn) {
	if conn.username == '' {
		return
	}
	c.mu.lock()
	c.peers[conn.username] = conn
	c.mu.unlock()
}

fn (mut c Client) unregister_peer(conn &Conn) {
	c.mu.lock()
	if existing := c.peers[conn.username] {
		if existing == conn {
			c.peers.delete(conn.username)
		}
	}
	c.mu.unlock()
}

fn (mut c Client) run_peer(mut conn Conn) {
	conn.set_read_timeout(5 * time.minute)
	c.register_peer(mut conn)
	c.peer_loop(mut conn)
	c.unregister_peer(conn)
	conn.close()
}

fn (mut c Client) peer_loop(mut conn Conn) {
	for !c.is_stopping() {
		payload := conn.read_frame() or { return }
		code, mut r := proto.peer_code(payload) or { continue }
		c.handle_peer_message(mut conn, code, mut r) or {
			c.log.debug('error handling peer message ${code} from ${conn.username}: ${err}')
		}
	}
}

fn (mut c Client) handle_peer_message(mut conn Conn, code u32, mut r proto.Reader) ! {
	match code {
		proto.peer_shared_file_list_request {
			c.log.info('user ${conn.username} requested the list of shared files')
			data := c.browse_response()!
			conn.send(data)!
		}
		proto.peer_user_info_request {
			c.log.debug('user ${conn.username} requested user info')
			conn.send(proto.encode_user_info_response(c.user_info()))!
		}
		proto.peer_folder_contents_request {
			req := proto.decode_folder_contents_request(mut r)!
			c.log.debug('user ${conn.username} requested the contents of "${req.folder}"')
			mut dirs := []proto.DirEntry{}
			if !shares.has_traversal(req.folder) {
				idx := c.store.current()
				if d := idx.directory(req.folder) {
					dirs << d
				}
			}
			conn.send(proto.encode_folder_contents_response(req.token, req.folder, dirs)!)!
		}
		proto.peer_queue_upload {
			filename := r.string()!
			c.handle_queue_upload(mut conn, filename)
		}
		proto.peer_place_in_queue_request {
			filename := r.string()!
			if place := c.queue.position(conn.username, filename) {
				conn.send(proto.encode_place_in_queue_response(filename, u32(place)))!
			}
		}
		proto.peer_transfer_request {
			tr := proto.decode_transfer_request(mut r)!
			c.handle_transfer_request(mut conn, tr)!
		}
		proto.peer_transfer_response {
			tr := proto.decode_transfer_response(mut r)!
			c.deliver_transfer_response(tr)
		}
		proto.peer_upload_failed {
			filename := r.string()!
			if c.queue.remove(conn.username, filename) {
				c.log.info('user ${conn.username} cancelled the queued download of "${filename}"')
			}
		}
		else {
			c.log.debug('ignoring peer message ${code} from ${conn.username}')
		}
	}
}

fn (mut c Client) browse_response() ![]u8 {
	idx := c.store.current()
	c.mu.lock()
	if c.browse_idx == idx && c.browse_cache.len > 0 {
		cached := c.browse_cache
		c.mu.unlock()
		return cached
	}
	c.mu.unlock()
	data := proto.encode_shared_file_list_response(idx.browse())!
	c.mu.lock()
	c.browse_idx = idx
	c.browse_cache = data
	c.mu.unlock()
	return data
}

fn (mut c Client) user_info() proto.UserInfo {
	c.mu.lock()
	active := c.active_uploads
	c.mu.unlock()
	slots := c.cfg.transfers.upload.slots
	return proto.UserInfo{
		description:    c.cfg.soulseek.description
		upload_slots:   u32(slots)
		queue_size:     u32(c.queue.len())
		slot_free:      active < slots
		upload_allowed: 1
	}
}

// enqueue_download validates and queues a file request from a user.
// It returns an error message suitable for the peer when the request is refused.
fn (mut c Client) enqueue_download(username string, filename string) ! {
	if shares.has_traversal(filename) {
		c.log.warn('user ${username} requested a file with unsafe path segments: "${filename}"')
		return error('File not shared.')
	}
	idx := c.store.current()
	f := idx.lookup(filename) or {
		c.log.info('refused download request from ${username}: "${filename}" is not shared')
		return error('File not shared.')
	}
	res := c.queue.enqueue(uploads.Item{
		username: username
		remote:   f.remote
		local:    f.local
		size:     f.size
		enqueued: time.now()
	})
	match res {
		.added {
			c.log.info('download requested: user=${username} file="${f.remote}" (queued, ${c.queue.user_len(username)} from this user, ${c.queue.len()} total)')
			c.wake_dispatcher()
		}
		.already_queued {
			c.log.debug('download of "${f.remote}" by ${username} is already queued')
		}
		.user_limit {
			c.log.info('refused download request from ${username}: too many queued files')
			return error('Too many files queued.')
		}
	}
}

fn (mut c Client) handle_queue_upload(mut conn Conn, filename string) {
	if conn.username == '' {
		return
	}
	c.enqueue_download(conn.username, filename) or {
		conn.send(proto.encode_upload_denied(filename, err.msg())) or {}
	}
}

fn (mut c Client) handle_transfer_request(mut conn Conn, tr proto.TransferRequest) ! {
	if tr.direction == proto.dir_download {
		// legacy-style direct request: queue it and tell the peer to wait
		c.enqueue_download(conn.username, tr.filename) or {
			conn.send(proto.encode_transfer_response(proto.TransferResponse{
				token:   tr.token
				allowed: false
				reason:  err.msg()
			}, false))!
			return
		}
		conn.send(proto.encode_transfer_response(proto.TransferResponse{
			token:   tr.token
			allowed: false
			reason:  'Queued'
		}, false))!
		return
	}
	// the peer wants to upload something to us; we do not accept files
	conn.send(proto.encode_transfer_response(proto.TransferResponse{
		token:   tr.token
		allowed: false
		reason:  'Cancelled'
	}, false))!
}

fn (mut c Client) deliver_transfer_response(tr proto.TransferResponse) {
	c.mu.lock()
	ch := c.transfer_waiters[tr.token] or {
		c.mu.unlock()
		return
	}
	c.mu.unlock()
	select {
		ch <- tr {
		}
		else {
		}
	}
}
