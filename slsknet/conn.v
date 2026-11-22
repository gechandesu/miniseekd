module slsknet

import net
import sync
import time
import proto

// Conn is a TCP connection with a write lock and idempotent close.
@[heap]
pub struct Conn {
pub mut:
	tc       &net.TcpConn = unsafe { nil }
	username string // remote user name, if known
	typ      string // P, F or D
	incoming bool
mut:
	wmu    &sync.Mutex = sync.new_mutex()
	cmu    &sync.Mutex = sync.new_mutex()
	closed bool
}

pub fn new_conn(tc &net.TcpConn, username string, typ string, incoming bool) &Conn {
	return &Conn{
		tc:       tc
		username: username
		typ:      typ
		incoming: incoming
	}
}

// send writes bytes atomically with respect to other senders.
pub fn (mut c Conn) send(data []u8) ! {
	c.wmu.lock()
	defer {
		c.wmu.unlock()
	}
	if c.is_closed() {
		return error('connection closed')
	}
	c.tc.write(data)!
}

// read_frame reads one length-prefixed message.
pub fn (mut c Conn) read_frame() ![]u8 {
	return proto.read_frame(mut c.tc)
}

pub fn (mut c Conn) set_read_timeout(d time.Duration) {
	c.tc.set_read_timeout(d)
}

pub fn (mut c Conn) set_write_timeout(d time.Duration) {
	c.tc.set_write_timeout(d)
}

pub fn (mut c Conn) is_closed() bool {
	c.cmu.lock()
	v := c.closed
	c.cmu.unlock()
	return v
}

pub fn (mut c Conn) close() {
	c.cmu.lock()
	if c.closed {
		c.cmu.unlock()
		return
	}
	c.closed = true
	c.cmu.unlock()
	c.tc.close() or {}
}

pub fn (mut c Conn) remote_ip() string {
	return c.tc.peer_ip() or { '?' }
}

struct DialResult {
	conn &net.TcpConn = unsafe { nil }
	err  string
}

fn dial_worker(addr string, ch chan DialResult) {
	tc := net.dial_tcp(addr) or {
		ch <- DialResult{
			err: err.msg()
		}
		return
	}
	ch <- DialResult{
		conn: tc
	}
}

// reap_dial closes a connection that finished connecting after the caller gave up.
fn reap_dial(ch chan DialResult) {
	r := <-ch
	if !isnil(r.conn) {
		mut t := r.conn
		t.close() or {}
	}
}

// dial_timeout connects with a connect timeout (net.dial_tcp has none of its own).
pub fn dial_timeout(addr string, timeout time.Duration) !&net.TcpConn {
	ch := chan DialResult{cap: 1}
	spawn dial_worker(addr, ch)
	select {
		r := <-ch {
			if r.err != '' {
				return error(r.err)
			}
			return r.conn
		}
		timeout {
			spawn reap_dial(ch)
			return error('connect to ${addr} timed out')
		}
	}
	return error('unreachable')
}
