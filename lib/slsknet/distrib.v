module slsknet

import time
import lib.proto

const first_message_timeout = 10 * time.second

// handle_possible_parents starts looking for a distributed-network parent, if we have none.
fn (mut c Client) handle_possible_parents(list []proto.PossibleParent) {
	c.log.debug('server offered ${list.len} possible distributed parents: ${list.map(it.username).join(', ')}')
	c.mu.lock()
	if c.parent_connecting || !isnil(c.parent) {
		c.mu.unlock()
		return
	}
	c.parent_connecting = true
	c.mu.unlock()
	spawn c.connect_parent(list)
}

// connect_parent tries the candidates in turn and then serves the first one that works
// until the connection ends. We only act as a leaf: no children are accepted.
fn (mut c Client) connect_parent(list []proto.PossibleParent) {
	defer {
		c.mu.lock()
		c.parent_connecting = false
		c.mu.unlock()
	}
	for p in list {
		if c.is_stopping() {
			return
		}
		tc := dial_timeout('${p.ip}:${p.port}', 6 * time.second) or {
			c.log.debug('cannot connect to distributed parent candidate ${p.username}: ${err}')
			continue
		}
		mut conn := new_conn(tc, p.username, proto.conn_distributed, false)
		conn.send(proto.encode_peer_init(c.username(), proto.conn_distributed, 0)) or {
			conn.close()
			continue
		}
		c.mu.lock()
		c.parent = conn
		c.mu.unlock()
		c.log.debug('connected to distributed parent candidate ${p.username}')
		sw := time.new_stopwatch()
		received, reason := c.parent_loop(mut conn)

		conn.close()
		c.mu.lock()
		c.parent = unsafe { nil }
		c.mu.unlock()
		if received == 0 && !c.is_stopping() {
			c.log.info('distributed network parent candidate ${p.username} stayed silent (${reason}), trying the next one')
			continue
		}
		if !c.is_stopping() {
			c.log.info('lost distributed network parent ${p.username} after ${sw.elapsed().seconds():.0f}s (${received} messages received): ${reason}')
			c.reset_branch()
		}
		return
	}
	c.log.debug('no distributed network parent could be reached')
}

fn (mut c Client) reset_branch() {
	c.server_send(proto.encode_have_no_parent(true)) or {}
	c.server_send(proto.encode_branch_level(0)) or {}
	c.server_send(proto.encode_branch_root(c.username())) or {}
}

fn (mut c Client) parent_loop(mut conn Conn) (int, string) {
	// a working parent announces its branch right after we connect; a silent one is dead weight
	conn.set_read_timeout(first_message_timeout)
	mut received := 0
	for !c.is_stopping() {
		payload := conn.read_frame() or {
			msg := err.msg()
			return received, if msg == '' { 'connection closed by the parent' } else { msg }
		}
		received++
		if received == 1 {
			// the parent is alive: adopt it
			conn.set_read_timeout(10 * time.minute)
			c.log.info('connected to distributed network parent ${conn.username}')
			c.server_send(proto.encode_have_no_parent(false)) or {}
			c.server_send(proto.encode_accept_children(false)) or {}
			// we have no children of our own
			conn.send(proto.encode_distrib_child_depth(0)) or {}
		}
		if payload.len == 0 {
			continue
		}
		mut r := proto.new_reader(payload)
		code := r.u8() or { continue }
		c.handle_distributed(code, mut r) or { c.log.debug('distributed message ${code}: ${err}') }
	}
	return received, 'shutting down'
}

fn (mut c Client) handle_distributed(code u8, mut r proto.Reader) ! {
	match code {
		proto.dist_search {
			ds := proto.decode_distrib_search(mut r)!
			c.handle_search(ds.username, ds.token, ds.query)
		}
		proto.dist_branch_level {
			level := r.u32()!
			c.log.debug('distributed parent branch level ${level}')
			c.server_send(proto.encode_branch_level(level + 1)) or {}
		}
		proto.dist_branch_root {
			root := r.string()!
			c.log.debug('distributed parent branch root ${root}')
			c.server_send(proto.encode_branch_root(root)) or {}
		}
		else {
			c.log.debug('ignoring distributed message ${code}')
		}
	}
}

// drop_parent closes the distributed parent connection, if any.
fn (mut c Client) drop_parent() {
	c.mu.lock()
	mut p := c.parent
	c.mu.unlock()
	if !isnil(p) {
		p.close()
	}
}
