module slsknet

import net
import time
import proto

// session connects, authenticates and processes server messages until the connection ends.
fn (mut c Client) session() ! {
	addr := '${c.cfg.soulseek.address}:${c.cfg.soulseek.port}'
	c.log.info('connecting to Soulseek server ${addr}')
	tc := dial_timeout(addr, 15 * time.second)!
	mut conn := new_conn(tc, '', 'S', false)
	conn.set_read_timeout(30 * time.second)

	c.mu.lock()
	c.server = conn
	c.session_id++
	sid := c.session_id
	c.mu.unlock()
	defer {
		conn.close()
		c.mu.lock()
		was_logged_in := c.logged_in
		c.server = unsafe { nil }
		c.logged_in = false
		c.mu.unlock()
		c.drop_parent()
		if was_logged_in {
			c.log.info('disconnected from the Soulseek network')
		}
	}
	c.log.info('connected to server ${addr}, authenticating as "${c.username()}"')

	conn.send(proto.encode_login(c.username(), c.cfg.soulseek.password))!
	payload := conn.read_frame()!
	code, mut r := proto.peer_code(payload)!
	if code != proto.srv_login {
		return error('unexpected message ${code} in reply to login')
	}
	lr := proto.decode_login_response(mut r)!
	if !lr.success {
		c.log.error('authentication failed for user "${c.username()}": ${lr.reason}')
		if lr.reason in ['INVALIDPASS', 'INVALIDUSERNAME'] {
			return error_with_code('server rejected the credentials: ${lr.reason}', err_code_auth)
		}
		return error('login refused: ${lr.reason}')
	}
	c.mu.lock()
	c.logged_in = true
	c.own_ip = lr.own_ip
	c.mu.unlock()
	c.session_ok = true
	c.log.info('authenticated as "${c.username()}" (external ip ${lr.own_ip}, supporter: ${lr.is_supporter})')
	if lr.greeting != '' {
		c.log.debug('server greeting: ${lr.greeting}')
	}

	// announce ourselves
	idx := c.store.current()
	conn.send(proto.encode_set_wait_port(u32(c.cfg.soulseek.listen_port)))!
	conn.send(proto.encode_shared_folders_files(u32(idx.dir_count()), u32(idx.file_count())))!
	conn.send(proto.encode_set_status(proto.status_online))!
	conn.send(proto.encode_have_no_parent(true))!
	conn.send(proto.encode_accept_children(false))!
	conn.send(proto.encode_branch_level(0))!
	conn.send(proto.encode_branch_root(c.username()))!

	conn.set_read_timeout(net.infinite_timeout)
	spawn c.keepalive(sid)
	c.server_loop(mut conn)!
}

fn (mut c Client) current_session() int {
	c.mu.lock()
	v := c.session_id
	c.mu.unlock()
	return v
}

// keepalive pings the server regularly so that a dead connection is noticed.
fn (mut c Client) keepalive(sid int) {
	for {
		for _ in 0 .. 300 {
			time.sleep(1 * time.second)
			if c.is_stopping() || c.current_session() != sid {
				return
			}
		}
		c.server_send(proto.encode_ping()) or {
			c.mu.lock()
			mut s := c.server
			c.mu.unlock()
			if !isnil(s) {
				s.close()
			}
			return
		}
	}
}

// server_send sends a pre-framed message to the server.
pub fn (mut c Client) server_send(data []u8) ! {
	c.mu.lock()
	mut s := c.server
	c.mu.unlock()
	if isnil(s) {
		return error('not connected to the server')
	}
	s.send(data)!
}

fn (mut c Client) server_loop(mut conn Conn) ! {
	for {
		payload := conn.read_frame() or {
			if c.is_stopping() {
				return
			}
			msg := err.msg()
			return error(if msg == '' { 'connection closed by the server' } else { msg })
		}
		code, mut r := proto.peer_code(payload) or {
			c.log.debug('malformed server message: ${err}')
			continue
		}
		c.handle_server_message(code, mut r) or {
			if err.code() == err_code_relogged {
				return err
			}
			c.log.debug('error handling server message ${code}: ${err}')
		}
	}
}

fn (mut c Client) handle_server_message(code u32, mut r proto.Reader) ! {
	match code {
		proto.srv_connect_to_peer {
			m := proto.decode_connect_to_peer(mut r)!
			spawn c.handle_connect_to_peer(m)
		}
		proto.srv_get_peer_address {
			addr := proto.decode_peer_address(mut r)!
			c.resolve_address_waiters(addr)
		}
		proto.srv_file_search {
			s := proto.decode_file_search(mut r)!
			c.handle_search(s.username, s.token, s.query)
		}
		proto.srv_embedded_message {
			dcode, rest := proto.decode_distrib_embedded(mut r)!
			if dcode == proto.dist_search {
				mut dr := proto.new_reader(rest)
				ds := proto.decode_distrib_search(mut dr)!
				c.handle_search(ds.username, ds.token, ds.query)
			}
		}
		proto.srv_possible_parents {
			list := proto.decode_possible_parents(mut r)!
			c.handle_possible_parents(list)
		}
		proto.srv_reset_distributed {
			c.log.debug('server requested a reset of the distributed network connection')
			c.drop_parent()
		}
		proto.srv_relogged {
			c.log.error('this account was logged in from another location; disconnecting')
			return error_with_code('relogged from another location', err_code_relogged)
		}
		else {
			c.log.debug('ignoring server message ${code}')
		}
	}
}

// get_peer_address asks the server for the address of a user.
fn (mut c Client) get_peer_address(username string) !proto.PeerAddress {
	ch := chan proto.PeerAddress{cap: 1}
	c.mu.lock()
	mut list := c.addr_waiters[username] or { []chan proto.PeerAddress{} }
	list << ch
	c.addr_waiters[username] = list
	c.mu.unlock()
	c.server_send(proto.encode_get_peer_address(username))!
	select {
		a := <-ch {
			return a
		}
		8 * time.second {
			return error('timed out waiting for the address of ${username}')
		}
	}
	return error('unreachable')
}

fn (mut c Client) resolve_address_waiters(addr proto.PeerAddress) {
	c.mu.lock()
	list := c.addr_waiters[addr.username] or { []chan proto.PeerAddress{} }
	c.addr_waiters.delete(addr.username)
	c.mu.unlock()
	for ch in list {
		select {
			ch <- addr {
			}
			else {
			}
		}
	}
}
