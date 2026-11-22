module proto

fn strip_frame(f []u8) []u8 {
	mut r := new_reader(f)
	n := int(r.u32() or { panic(err) })
	assert n == f.len - 4
	return f[4..]
}

fn test_writer_reader_roundtrip() {
	mut w := new_msg(42)
	w.put_u8(7)
	w.put_bool(true)
	w.put_u32(0xdeadbeef)
	w.put_u64(0x0102030405060708)
	w.put_string('héllo')
	payload := strip_frame(w.frame())
	mut r := new_reader(payload)
	assert r.u32()! == 42
	assert r.u8()! == 7
	assert r.bool()! == true
	assert r.u32()! == 0xdeadbeef
	assert r.u64()! == 0x0102030405060708
	assert r.string()! == 'héllo'
	assert r.remaining() == 0
	if _ := r.u8() {
		assert false, 'must fail on short read'
	}
}

fn test_fixed_bytes() {
	mut w := new_msg(2)
	w.put_u32(50300)
	assert w.frame() == [u8(8), 0, 0, 0, 2, 0, 0, 0, 0x7c, 0xc4, 0, 0]
	mut s := Writer{}
	s.put_string('ab')
	assert s.buf == [u8(2), 0, 0, 0, `a`, `b`]
}

fn test_string_bounds_and_latin1() {
	mut r := new_reader([u8(100), 0, 0, 0, 1, 2])
	if _ := r.string() {
		assert false, 'oversized string must fail'
	}
	mut r2 := new_reader([u8(3), 0, 0, 0, `c`, 0xe9, `t`])
	assert r2.string()! == 'cét'
}

fn test_ip_conversion() {
	assert ip_to_string(ip_from_string('1.2.3.4')) == '1.2.3.4'
	// on the wire the octets are reversed: 1.2.3.4 -> bytes 04 03 02 01 -> LE u32 0x01020304
	assert ip_from_string('1.2.3.4') == 0x01020304
	mut w := Writer{}
	w.put_u32(ip_from_string('192.168.0.10'))
	assert w.buf == [u8(10), 0, 168, 192]
}

fn test_login_encoding() {
	frame := encode_login('bob', 'pw')
	payload := strip_frame(frame)
	mut r := new_reader(payload)
	assert r.u32()! == srv_login
	assert r.string()! == 'bob'
	assert r.string()! == 'pw'
	assert r.u32()! == login_version
	assert r.string()! == md5_hex('bobpw')
	assert r.u32()! == login_minor_version
}

fn test_md5() {
	assert md5_hex('') == 'd41d8cd98f00b204e9800998ecf8427e'
}

fn test_login_response() {
	mut w := Writer{}
	w.put_bool(true)
	w.put_string('hi')
	w.put_u32(ip_from_string('5.6.7.8'))
	w.put_string('abc')
	w.put_bool(false)
	mut r := new_reader(w.buf)
	lr := decode_login_response(mut r)!
	assert lr.success
	assert lr.greeting == 'hi'
	assert lr.own_ip == '5.6.7.8'

	mut f := Writer{}
	f.put_bool(false)
	f.put_string('INVALIDPASS')
	mut r2 := new_reader(f.buf)
	lr2 := decode_login_response(mut r2)!
	assert !lr2.success
	assert lr2.reason == 'INVALIDPASS'
}

fn test_connect_to_peer() {
	mut w := Writer{}
	w.put_string('alice')
	w.put_string('F')
	w.put_u32(ip_from_string('10.0.0.5'))
	w.put_u32(2234)
	w.put_u32(99)
	w.put_bool(true)
	mut r := new_reader(w.buf)
	c := decode_connect_to_peer(mut r)!
	assert c.username == 'alice'
	assert c.typ == 'F'
	assert c.ip == '10.0.0.5'
	assert c.port == 2234
	assert c.token == 99
	assert c.privileged
}

fn test_init_messages() {
	m := decode_init(strip_frame(encode_pierce_firewall(1234)))!
	assert m.pierce
	assert m.token == 1234
	m2 := decode_init(strip_frame(encode_peer_init('carol', 'P', 0)))!
	assert !m2.pierce
	assert m2.username == 'carol'
	assert m2.typ == 'P'
	if _ := decode_init([u8(9)]) {
		assert false
	}
}

fn sample_dirs() []DirEntry {
	return [
		DirEntry{
			name:  'share\\Music'
			files: [
				FileEntry{
					filename: 'a.mp3'
					size:     123456789012
					ext:      'mp3'
					attrs:    [FileAttr{0, 320}, FileAttr{1, 200}]
				},
				FileEntry{
					filename: 'b.flac'
					size:     5
					ext:      'flac'
				},
			]
		},
		DirEntry{
			name: 'share\\Empty'
		},
	]
}

fn test_shared_file_list_roundtrip() {
	frame := encode_shared_file_list_response(sample_dirs())!
	mut r := new_reader(strip_frame(frame))
	assert r.u32()! == peer_shared_file_list_response
	dirs := decode_shared_file_list_response(mut r)!
	assert dirs.len == 2
	assert dirs[0].name == 'share\\Music'
	assert dirs[0].files.len == 2
	assert dirs[0].files[0].size == 123456789012
	assert dirs[0].files[0].attrs[1].value == 200
	assert dirs[1].files.len == 0
}

fn test_folder_contents_roundtrip() {
	frame := encode_folder_contents_response(77, 'share\\Music', sample_dirs()[..1])!
	code, mut r := peer_code(strip_frame(frame))!
	assert code == peer_folder_contents_response
	fc := decode_folder_contents_response(mut r)!
	assert fc.token == 77
	assert fc.folder == 'share\\Music'
	assert fc.dirs.len == 1
}

fn test_search_response_roundtrip() {
	sr := SearchResponse{
		username:  'me'
		token:     555
		files:     sample_dirs()[0].files
		slot_free: true
		avg_speed: 1000
		queue_len: 3
	}
	frame := encode_file_search_response(sr)!
	code, mut r := peer_code(strip_frame(frame))!
	assert code == peer_file_search_response
	got := decode_file_search_response(mut r)!
	assert got.username == 'me'
	assert got.token == 555
	assert got.files.len == 2
	assert got.slot_free
	assert got.avg_speed == 1000
	assert got.queue_len == 3
}

fn test_transfer_messages() {
	frame := encode_transfer_request(TransferRequest{
		direction: dir_upload
		token:     5
		filename:  'x\\y.mp3'
		size:      1 << 33
	})
	code, mut r := peer_code(strip_frame(frame))!
	assert code == peer_transfer_request
	tr := decode_transfer_request(mut r)!
	assert tr.direction == dir_upload
	assert tr.token == 5
	assert tr.filename == 'x\\y.mp3'
	assert tr.size == 1 << 33

	// download-direction request has no size
	f2 := encode_transfer_request(TransferRequest{
		direction: dir_download
		token:     6
		filename:  'z'
	})
	_, mut r2 := peer_code(strip_frame(f2))!
	tr2 := decode_transfer_request(mut r2)!
	assert tr2.direction == dir_download
	assert tr2.size == 0

	f3 := encode_transfer_response(TransferResponse{ token: 5, allowed: false, reason: 'Queued' },
		false)
	_, mut r3 := peer_code(strip_frame(f3))!
	resp := decode_transfer_response(mut r3)!
	assert !resp.allowed
	assert resp.reason == 'Queued'

	f4 := encode_transfer_response(TransferResponse{ token: 5, allowed: true, size: 99 },
		true)
	_, mut r4 := peer_code(strip_frame(f4))!
	resp2 := decode_transfer_response(mut r4)!
	assert resp2.allowed
	assert resp2.size == 99
}

fn test_user_info_roundtrip() {
	f := encode_user_info_response(UserInfo{
		description:    'hello'
		upload_slots:   3
		queue_size:     4
		slot_free:      true
		upload_allowed: 1
	})
	_, mut r := peer_code(strip_frame(f))!
	ui := decode_user_info_response(mut r)!
	assert ui.description == 'hello'
	assert ui.upload_slots == 3
	assert ui.queue_size == 4
	assert ui.slot_free
}

fn test_distrib_search() {
	f := encode_distrib_search(DistribSearch{ username: 'zed', token: 9, query: 'foo bar' })
	payload := strip_frame(f)
	mut r := new_reader(payload)
	assert r.u8()! == dist_search
	ds := decode_distrib_search(mut r)!
	assert ds.username == 'zed'
	assert ds.token == 9
	assert ds.query == 'foo bar'
}

fn test_possible_parents() {
	mut w := Writer{}
	w.put_u32(2)
	for i in 0 .. 2 {
		w.put_string('p${i}')
		w.put_u32(ip_from_string('1.1.1.${i + 1}'))
		w.put_u32(2000 + u32(i))
	}
	mut r := new_reader(w.buf)
	ps := decode_possible_parents(mut r)!
	assert ps.len == 2
	assert ps[1].ip == '1.1.1.2'
	assert ps[1].port == 2001
}

fn test_malformed_input_does_not_crash() {
	// truncated payloads must produce errors, never panics
	mut r := new_reader([u8(1), 2])
	if _ := decode_transfer_request(mut r) {
		assert false
	}
	mut r2 := new_reader([u8(0xff), 0xff, 0xff, 0xff])
	if _ := decode_possible_parents(mut r2) {
		assert false
	}
	mut r3 := new_reader([u8(1), 2, 3])
	if _ := decode_shared_file_list_response(mut r3) {
		assert false
	}
}

fn test_child_depth() {
	mut r := new_reader(strip_frame(encode_distrib_child_depth(0)))
	assert r.u8()! == dist_child_depth
	assert r.u32()! == 0
	assert r.remaining() == 0
}
