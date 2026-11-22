module slsknet

import net
import os
import rand
import time
import lib.conf
import lib.logx
import lib.proto

// ---------------------------------------------------------------------------
// helpers: a scripted fake Soulseek server and a fake remote peer ("bob")
// ---------------------------------------------------------------------------

fn free_port() !int {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0')!
	a := l.addr()!
	p := a.port()!
	l.close()!
	return int(p)
}

fn listen_local() !(&net.TcpListener, int) {
	l := net.listen_tcp(.ip, '127.0.0.1:0')!
	a := l.addr()!
	return l, int(a.port()!)
}

fn must_frame(mut tc net.TcpConn) !(u32, proto.Reader) {
	tc.set_read_timeout(10 * time.second)
	payload := proto.read_frame(mut tc)!
	return proto.peer_code(payload)!
}

struct FakeServer {
mut:
	listener &net.TcpListener = unsafe { nil }
	conn     &Conn            = unsafe { nil }
	bob_port int
	reject   bool
	events   chan string = chan string{cap: 64}
}

fn (mut s FakeServer) run() {
	mut l := s.listener
	tc := l.accept() or { return }
	mut conn := new_conn(tc, '', 'S', true)
	s.conn = conn
	payload := conn.read_frame() or { return }
	_, mut r := proto.peer_code(payload) or { return }
	user := r.string() or { return }
	s.events <- 'login:${user}'
	mut w := proto.new_msg(proto.srv_login)
	if s.reject {
		w.put_bool(false)
		w.put_string('INVALIDPASS')
		conn.send(w.frame()) or {}
		time.sleep(200 * time.millisecond)
		conn.close()
		return
	}
	w.put_bool(true)
	w.put_string('welcome')
	w.put_u32(proto.ip_from_string('127.0.0.1'))
	w.put_string('hash')
	w.put_bool(false)
	conn.send(w.frame()) or { return }
	for {
		p := conn.read_frame() or { return }
		code, mut mr := proto.peer_code(p) or { continue }
		s.events <- 'srv:${code}'
		if code == proto.srv_branch_level {
			level := mr.u32() or { continue }
			s.events <- 'branch:${level}'
		}
		if code == proto.srv_have_no_parent {
			flag := mr.bool() or { continue }
			s.events <- 'noparent:${flag}'
		}
		if code == proto.srv_get_peer_address {
			name := mr.string() or { continue }
			mut pw := proto.new_msg(proto.srv_get_peer_address)
			pw.put_string(name)
			pw.put_u32(proto.ip_from_string('127.0.0.1'))
			pw.put_u32(u32(s.bob_port))
			conn.send(pw.frame()) or {}
		}
	}
}

fn wait_event(events chan string, prefix string) ! {
	deadline := time.now().add(10 * time.second)
	for time.now() < deadline {
		select {
			e := <-events {
				if e.starts_with(prefix) {
					return
				}
			}
			100 * time.millisecond {
			}
		}
	}
	return error('timed out waiting for event "${prefix}"')
}

fn wait_log_contains(path string, needle string) ! {
	deadline := time.now().add(10 * time.second)
	for time.now() < deadline {
		text := os.read_file(path) or { '' }
		if text.contains(needle) {
			return
		}
		time.sleep(100 * time.millisecond)
	}
	return error('timed out waiting for log line containing "${needle}"; log:\n${os.read_file(path) or { '' }}')
}

fn run_client(mut c Client, done chan string) {
	c.run() or {
		done <- '${err.code()}:${err.msg()}'
		return
	}
	done <- ''
}

struct TestEnv {
mut:
	dir         string
	share_dir   string
	log_path    string
	server      &FakeServer = unsafe { nil }
	cfg         conf.Config
	bob_listen  &net.TcpListener = unsafe { nil }
	client_port int
	file_data   []u8
}

fn setup_env(reject bool) !&TestEnv {
	dir := os.join_path(os.temp_dir(), 'slsk_it_${os.getpid()}_${rand.u32()}')
	share := os.join_path(dir, 'share')
	os.mkdir_all(share)!
	mut data := []u8{len: 300_000}
	for i in 0 .. data.len {
		data[i] = u8(i * 7 + i / 251)
	}
	os.write_file_array(os.join_path(share, 'sample.bin'), data)!
	os.write_file(os.join_path(share, 'secret.ini'), 'x')!

	sl, sport := listen_local()!
	bl, bport := listen_local()!
	mut srv := &FakeServer{
		listener: sl
		bob_port: bport
		reject:   reject
	}
	cport := free_port()!
	mut cfg := conf.Config{}
	cfg.soulseek.address = '127.0.0.1'
	cfg.soulseek.port = sport
	cfg.soulseek.username = 'daemon'
	cfg.soulseek.password = 'pw'
	cfg.soulseek.listen_ip = '127.0.0.1'
	cfg.soulseek.listen_port = cport
	cfg.soulseek.description = 'test daemon'
	cfg.shares.directories = [share]
	cfg.shares.filters = [r'\.ini$']
	cfg.transfers.upload.slots = 2
	cfg.transfers.upload.max_queued_per_user = 5
	return &TestEnv{
		dir:         dir
		share_dir:   share
		log_path:    os.join_path(dir, 'daemon.log')
		server:      srv
		cfg:         cfg
		bob_listen:  bl
		client_port: cport
		file_data:   data
	}
}

fn (mut e TestEnv) cleanup() {
	e.server.listener.close() or {}
	e.bob_listen.close() or {}
	os.rmdir_all(e.dir) or {}
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

fn test_authentication_failure_is_fatal_and_logged() {
	mut env := setup_env(true)!
	defer {
		env.cleanup()
	}
	mut logger := logx.new('debug', env.log_path, false)!
	mut client := new_client(env.cfg, logger)
	client.scan_shares()!
	spawn env.server.run()
	done := chan string{cap: 1}
	spawn run_client(mut client, done)
	select {
		r := <-done {
			assert r.starts_with('${err_code_auth}:'), 'unexpected result: ${r}'
		}
		15 * time.second {
			assert false, 'run() did not return after rejected credentials'
		}
	}
	client.stop()
	logger.close()
	log := os.read_file(env.log_path)!
	assert log.contains('connecting to Soulseek server')
	assert log.contains('authentication failed for user "daemon": INVALIDPASS')
}

fn test_login_search_browse_and_upload() {
	mut env := setup_env(false)!
	defer {
		env.cleanup()
	}
	mut logger := logx.new('debug', env.log_path, false)!
	mut client := new_client(env.cfg, logger)
	client.scan_shares()!
	spawn env.server.run()
	done := chan string{cap: 1}
	spawn run_client(mut client, done)

	// --- login and announcements ---
	wait_event(env.server.events, 'login:daemon')!
	wait_event(env.server.events, 'srv:28')! // SetStatus: all announcements sent
	wait_log_contains(env.log_path, 'authenticated as "daemon"')!

	// --- a server-relayed search is answered by connecting to the searcher ---
	mut sw := proto.new_msg(proto.srv_file_search)
	sw.put_string('bob')
	sw.put_u32(5)
	sw.put_string('SAMPLE bin -ini')
	env.server.conn.send(sw.frame())!

	mut bl := env.bob_listen
	mut c1 := bl.accept()!
	mut initp := proto.read_frame(mut c1)!
	init := proto.decode_init(initp)!
	assert !init.pierce
	assert init.username == 'daemon'
	assert init.typ == 'P'
	code, mut r := must_frame(mut c1)!
	assert code == proto.peer_file_search_response
	sr := proto.decode_file_search_response(mut r)!
	assert sr.username == 'daemon'
	assert sr.token == 5
	assert sr.files.len == 1
	assert sr.files[0].filename == 'share\\sample.bin'
	assert sr.files[0].size == 300_000
	assert sr.slot_free

	// --- bob connects to the daemon: user info and browse ---
	mut direct := net.dial_tcp('127.0.0.1:${env.client_port}')!
	direct.write(proto.encode_peer_init('alice', 'P', 0))!
	direct.write(proto.encode_user_info_request())!
	code2, mut r2 := must_frame(mut direct)!
	assert code2 == proto.peer_user_info_response
	ui := proto.decode_user_info_response(mut r2)!
	assert ui.description == 'test daemon'
	assert ui.slot_free

	direct.write(proto.encode_shared_file_list_request())!
	code3, mut r3 := must_frame(mut direct)!
	assert code3 == proto.peer_shared_file_list_response
	dirs := proto.decode_shared_file_list_response(mut r3)!
	assert dirs.len == 1
	assert dirs[0].name == 'share'
	assert dirs[0].files.len == 1 // secret.ini is filtered out
	assert dirs[0].files[0].filename == 'sample.bin'

	direct.write(proto.encode_folder_contents_request(9, 'share'))!
	code4, mut r4 := must_frame(mut direct)!
	assert code4 == proto.peer_folder_contents_response
	fc := proto.decode_folder_contents_response(mut r4)!
	assert fc.token == 9
	assert fc.dirs.len == 1 && fc.dirs[0].files.len == 1

	// --- requests for files that are not shared (or unsafe) are refused ---
	direct.write(proto.encode_queue_upload('share\\secret.ini'))!
	code5, mut r5 := must_frame(mut direct)!
	assert code5 == proto.peer_upload_denied
	assert r5.string()! == 'share\\secret.ini'
	assert r5.string()! == 'File not shared.'
	direct.write(proto.encode_queue_upload('share\\..\\..\\etc\\passwd'))!
	code6, _ := must_frame(mut direct)!
	assert code6 == proto.peer_upload_denied
	direct.close()!

	// --- bob queues the file on the connection the daemon opened to him ---
	c1.write(proto.encode_queue_upload('share\\sample.bin'))!
	code7, mut r7 := must_frame(mut c1)!
	assert code7 == proto.peer_transfer_request
	tr := proto.decode_transfer_request(mut r7)!
	assert tr.direction == proto.dir_upload
	assert tr.filename == 'share\\sample.bin'
	assert tr.size == 300_000
	c1.write(proto.encode_transfer_response(proto.TransferResponse{ token: tr.token, allowed: true },
		false))!

	// the daemon now opens a file connection to bob (address looked up through the server)
	mut fconn := bl.accept()!
	fconn.set_read_timeout(10 * time.second)
	finit := proto.decode_init(proto.read_frame(mut fconn)!)!
	assert finit.typ == 'F'
	assert finit.username == 'daemon'
	mut tok := []u8{len: 4}
	proto.read_exact(mut fconn, mut tok)!
	mut tokr := proto.new_reader(tok)
	assert tokr.u32()! == tr.token
	offset := u64(1000)
	mut ow := proto.Writer{}
	ow.put_u64(offset)
	fconn.write(ow.buf)!
	mut got := []u8{len: int(300_000 - offset)}
	proto.read_exact(mut fconn, mut got)!
	assert got == env.file_data[int(offset)..]
	fconn.close()!

	wait_log_contains(env.log_path, 'upload complete: user=bob file="share\\sample.bin" bytes=299000')!
	c1.close()!

	// --- shutdown ---
	client.stop()
	select {
		res := <-done {
			assert res == '', 'run() returned an error: ${res}'
		}
		10 * time.second {
			assert false, 'run() did not return after stop()'
		}
	}
	logger.close()
	log := os.read_file(env.log_path)!
	assert log.contains('connected to server')
	assert log.contains('authenticated as "daemon"')
	assert log.contains('download requested: user=bob file="share\\sample.bin"')
	assert log.contains('upload start: user=bob file="share\\sample.bin" size=300000 offset=1000')
	assert log.contains('upload complete: user=bob file="share\\sample.bin" bytes=299000')
	assert !log.contains('upload failed')
}

fn test_declined_upload_is_logged_as_failed() {
	mut env := setup_env(false)!
	defer {
		env.cleanup()
	}
	mut logger := logx.new('debug', env.log_path, false)!
	mut client := new_client(env.cfg, logger)
	client.scan_shares()!
	spawn env.server.run()
	done := chan string{cap: 1}
	spawn run_client(mut client, done)
	wait_event(env.server.events, 'srv:28')!

	mut direct := net.dial_tcp('127.0.0.1:${env.client_port}')!
	direct.write(proto.encode_peer_init('bob', 'P', 0))!
	direct.write(proto.encode_queue_upload('share\\sample.bin'))!
	code, mut r := must_frame(mut direct)!
	assert code == proto.peer_transfer_request
	tr := proto.decode_transfer_request(mut r)!
	direct.write(proto.encode_transfer_response(proto.TransferResponse{
		token:   tr.token
		allowed: false
		reason:  'Cancelled'
	}, false))!
	wait_log_contains(env.log_path, 'upload failed: user=bob file="share\\sample.bin" bytes_sent=0 reason="the user declined the transfer (Cancelled)"')!
	direct.close()!
	client.stop()
	logger.close()
}

fn test_distributed_parent_search() {
	mut env := setup_env(false)!
	defer {
		env.cleanup()
	}
	mut logger := logx.new('debug', env.log_path, false)!
	mut client := new_client(env.cfg, logger)
	client.scan_shares()!
	spawn env.server.run()
	done := chan string{cap: 1}
	spawn run_client(mut client, done)
	wait_event(env.server.events, 'srv:28')!

	// the server proposes bob as a parent
	mut pw := proto.new_msg(proto.srv_possible_parents)
	pw.put_u32(1)
	pw.put_string('bob')
	pw.put_u32(proto.ip_from_string('127.0.0.1'))
	pw.put_u32(u32(env.server.bob_port))
	env.server.conn.send(pw.frame())!

	mut bl := env.bob_listen
	mut parent := bl.accept()!
	parent.set_read_timeout(10 * time.second)
	init := proto.decode_init(proto.read_frame(mut parent)!)!
	assert init.typ == 'D'
	assert init.username == 'daemon'

	// the parent announces its branch level; we adopt it and must report level + 1 to the server
	mut lw := proto.new_init_msg(proto.dist_branch_level)
	lw.put_u32(2)
	parent.write(lw.frame())!
	wait_event(env.server.events, 'noparent:false')!
	wait_event(env.server.events, 'branch:3')!

	// a distributed search makes us contact the searcher
	parent.write(proto.encode_distrib_search(proto.DistribSearch{
		username: 'carol'
		token:    77
		query:    'sample'
	}))!
	// carol is resolved to the same fake address (bob_port)
	mut c2 := bl.accept()!
	c2.set_read_timeout(10 * time.second)
	init2 := proto.decode_init(proto.read_frame(mut c2)!)!
	assert init2.typ == 'P'
	code, mut r := must_frame(mut c2)!
	assert code == proto.peer_file_search_response
	sr := proto.decode_file_search_response(mut r)!
	assert sr.token == 77
	assert sr.files.len == 1

	// losing the parent is reported to the server
	parent.close()!
	wait_event(env.server.events, 'noparent:true')!
	c2.close()!
	client.stop()
	logger.close()
	log := os.read_file(env.log_path)!
	assert log.contains('connected to distributed network parent bob')
	assert log.contains('lost distributed network parent bob')
}
