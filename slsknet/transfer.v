module slsknet

import os
import time
import proto
import uploads

const upload_chunk_size = 64 * 1024

// UploadStats records the progress of an upload for logging.
struct UploadStats {
mut:
	started bool
	offset  u64
	bytes   u64
	size    u64
	sw      time.StopWatch = time.new_stopwatch()
}

fn (mut c Client) is_user_busy(username string) bool {
	c.mu.lock()
	v := c.active_users[username]
	c.mu.unlock()
	return v
}

// dispatch_loop hands queued uploads to worker threads as upload slots become free.
fn (mut c Client) dispatch_loop() {
	for !c.is_stopping() {
		for {
			if c.is_stopping() {
				return
			}
			c.mu.lock()
			ready := c.logged_in && c.active_uploads < c.cfg.transfers.upload.slots
			c.mu.unlock()
			if !ready {
				break
			}
			item := c.queue.take(fn [mut c] (user string) bool {
				return c.is_user_busy(user)
			}) or { break }
			c.mu.lock()
			c.active_uploads++
			c.active_users[item.username] = true
			c.mu.unlock()
			spawn c.upload_worker(item)
		}
		select {
			_ := <-c.wake {
			}
			1 * time.second {
			}
		}
	}
}

fn (mut c Client) upload_worker(item uploads.Item) {
	mut st := UploadStats{}
	c.do_upload(item, mut st) or {
		c.log.warn('upload failed: user=${item.username} file="${item.remote}" bytes_sent=${st.bytes} reason="${err.msg()}"')
		c.mu.lock()
		c.active_uploads--
		c.active_users.delete(item.username)
		c.mu.unlock()
		c.wake_dispatcher()
		return
	}
	secs := f64(st.sw.elapsed().microseconds()) / 1_000_000.0
	speed := if secs > 0 { u64(f64(st.bytes) / secs) } else { st.bytes }
	c.log.info('upload complete: user=${item.username} file="${item.remote}" bytes=${st.bytes} duration=${secs:.2f}s avg_speed=${speed / 1024} KiB/s')
	if st.bytes > 0 {
		c.mu.lock()
		c.avg_speed = u32(speed)
		c.mu.unlock()
		c.server_send(proto.encode_send_upload_speed(u32(speed))) or {}
	}
	c.mu.lock()
	c.active_uploads--
	c.active_users.delete(item.username)
	c.mu.unlock()
	c.wake_dispatcher()
}

// do_upload runs the whole upload protocol exchange for one queued file.
fn (mut c Client) do_upload(item uploads.Item, mut st UploadStats) ! {
	if !os.is_file(item.local) {
		return error('file no longer exists')
	}
	size := u64(os.file_size(item.local))
	st.size = size

	mut pc := c.get_peer_conn(item.username) or {
		return error('cannot reach the user: ${err.msg()}')
	}

	// 1. offer the upload and wait for the peer to accept it
	token := c.next_token()
	ch := chan proto.TransferResponse{cap: 1}
	c.mu.lock()
	c.transfer_waiters[token] = ch
	c.mu.unlock()
	defer {
		c.mu.lock()
		c.transfer_waiters.delete(token)
		c.mu.unlock()
	}
	pc.send(proto.encode_transfer_request(proto.TransferRequest{
		direction: proto.dir_upload
		token:     token
		filename:  item.remote
		size:      size
	}))!
	mut resp := proto.TransferResponse{}
	select {
		r := <-ch {
			resp = r
		}
		90 * time.second {
			return error('timed out waiting for the user to accept the transfer')
		}
	}
	if !resp.allowed {
		return error('the user declined the transfer (${resp.reason})')
	}

	// 2. open the file transfer connection, send the token and read the start offset
	mut fc := c.open_connection(item.username, proto.conn_file) or {
		return error('cannot open a file connection: ${err.msg()}')
	}
	defer {
		fc.close()
	}
	mut tw := proto.Writer{}
	tw.put_u32(token)
	fc.send(tw.buf)!
	fc.set_read_timeout(30 * time.second)
	mut off_buf := []u8{len: 8}
	proto.read_exact(mut fc.tc, mut off_buf) or {
		return error('the user did not request the file: ${err.msg()}')
	}
	mut offr := proto.new_reader(off_buf)
	offset := offr.u64()!
	if offset > size {
		return error('invalid start offset ${offset} for a file of ${size} bytes')
	}
	st.offset = offset

	// 3. stream the file
	mut f := os.open(item.local) or { return error('cannot open the file: ${err}') }
	defer {
		f.close()
	}
	if offset > 0 {
		f.seek(i64(offset), .start)!
	}
	st.started = true
	st.sw = time.new_stopwatch()
	c.log.info('upload start: user=${item.username} file="${item.remote}" size=${size} offset=${offset}')

	limit := u64(c.cfg.transfers.upload.speed_limit_kib) * 1024
	mut buf := []u8{len: upload_chunk_size}
	mut remaining := size - offset
	for remaining > 0 {
		if c.is_stopping() {
			return error('daemon is shutting down')
		}
		want := if remaining < u64(buf.len) { int(remaining) } else { buf.len }
		n := f.read(mut buf[..want]) or { return error('read error: ${err}') }
		if n <= 0 {
			return error('file shrank while uploading')
		}
		fc.tc.write(buf[..n]) or { return error('connection lost: ${err.msg()}') }
		st.bytes += u64(n)
		remaining -= u64(n)
		if limit > 0 {
			// sleep until the average speed drops to the limit
			expected := time.Duration(i64(f64(st.bytes) / f64(limit) * 1e9))
			elapsed := st.sw.elapsed()
			if expected > elapsed {
				time.sleep(expected - elapsed)
			}
		}
	}

	// 4. let the downloader close the connection once it has everything
	fc.set_read_timeout(10 * time.second)
	mut tail := []u8{len: 1}
	fc.tc.read(mut tail) or {}
}
