module proto

import compress.zlib
import crypto.md5

// ---------------------------------------------------------------------------
// shared types
// ---------------------------------------------------------------------------

pub struct FileAttr {
pub:
	code  u32 // 0 bitrate, 1 length (s), 2 vbr, 4 sample rate, 5 bit depth
	value u32
}

pub struct FileEntry {
pub:
	filename string
	size     u64
	ext      string
	attrs    []FileAttr
}

pub struct DirEntry {
pub:
	name  string
	files []FileEntry
}

fn (mut w Writer) put_file(f FileEntry) {
	w.put_u8(1)
	w.put_string(f.filename)
	w.put_u64(f.size)
	w.put_string(f.ext)
	w.put_u32(u32(f.attrs.len))
	for a in f.attrs {
		w.put_u32(a.code)
		w.put_u32(a.value)
	}
}

fn (mut r Reader) file() !FileEntry {
	r.u8()!
	filename := r.string()!
	size := r.u64()!
	ext := r.string()!
	n := int(r.u32()!)
	if n < 0 || n > r.remaining() / 8 {
		return error('invalid attribute count ${n}')
	}
	mut attrs := []FileAttr{cap: n}
	for _ in 0 .. n {
		attrs << FileAttr{
			code:  r.u32()!
			value: r.u32()!
		}
	}
	return FileEntry{
		filename: filename
		size:     size
		ext:      ext
		attrs:    attrs
	}
}

fn (mut w Writer) put_dirs(dirs []DirEntry) {
	w.put_u32(u32(dirs.len))
	for d in dirs {
		w.put_string(d.name)
		w.put_u32(u32(d.files.len))
		for f in d.files {
			w.put_file(f)
		}
	}
}

fn (mut r Reader) dirs() ![]DirEntry {
	n := int(r.u32()!)
	if n < 0 || n > r.remaining() {
		return error('invalid directory count ${n}')
	}
	mut out := []DirEntry{cap: n}
	for _ in 0 .. n {
		name := r.string()!
		nf := int(r.u32()!)
		if nf < 0 || nf > r.remaining() {
			return error('invalid file count ${nf}')
		}
		mut files := []FileEntry{cap: nf}
		for _ in 0 .. nf {
			files << r.file()!
		}
		out << DirEntry{
			name:  name
			files: files
		}
	}
	return out
}

// ---------------------------------------------------------------------------
// server: login
// ---------------------------------------------------------------------------

// md5_hex returns the lowercase hex md5 digest of `s`.
pub fn md5_hex(s string) string {
	return md5.hexhash(s)
}

pub fn encode_login(username string, password string) []u8 {
	mut w := new_msg(srv_login)
	w.put_string(username)
	w.put_string(password)
	w.put_u32(login_version)
	w.put_string(md5_hex(username + password))
	w.put_u32(login_minor_version)
	return w.frame()
}

pub struct LoginResponse {
pub:
	success      bool
	greeting     string
	own_ip       string
	hash         string
	is_supporter bool
	reason       string // set on failure, e.g. INVALIDPASS
}

pub fn decode_login_response(mut r Reader) !LoginResponse {
	ok := r.bool()!
	if !ok {
		reason := r.string() or { 'UNKNOWN' }
		return LoginResponse{
			success: false
			reason:  reason
		}
	}
	greeting := r.string()!
	ip := ip_to_string(r.u32()!)
	hash := r.string() or { '' }
	supporter := r.bool() or { false }
	return LoginResponse{
		success:      true
		greeting:     greeting
		own_ip:       ip
		hash:         hash
		is_supporter: supporter
	}
}

// ---------------------------------------------------------------------------
// server: simple outgoing messages
// ---------------------------------------------------------------------------

pub fn encode_set_wait_port(port u32) []u8 {
	mut w := new_msg(srv_set_wait_port)
	w.put_u32(port)
	return w.frame()
}

pub fn encode_shared_folders_files(dirs u32, files u32) []u8 {
	mut w := new_msg(srv_shared_folders_files)
	w.put_u32(dirs)
	w.put_u32(files)
	return w.frame()
}

pub fn encode_set_status(status u32) []u8 {
	mut w := new_msg(srv_set_status)
	w.put_u32(status)
	return w.frame()
}

pub fn encode_have_no_parent(have_no_parent bool) []u8 {
	mut w := new_msg(srv_have_no_parent)
	w.put_bool(have_no_parent)
	return w.frame()
}

pub fn encode_accept_children(accept bool) []u8 {
	mut w := new_msg(srv_accept_children)
	w.put_bool(accept)
	return w.frame()
}

pub fn encode_branch_level(level u32) []u8 {
	mut w := new_msg(srv_branch_level)
	w.put_u32(level)
	return w.frame()
}

pub fn encode_branch_root(root string) []u8 {
	mut w := new_msg(srv_branch_root)
	w.put_string(root)
	return w.frame()
}

pub fn encode_send_upload_speed(speed u32) []u8 {
	mut w := new_msg(srv_send_upload_speed)
	w.put_u32(speed)
	return w.frame()
}

pub fn encode_ping() []u8 {
	return new_msg(srv_ping).frame()
}

pub fn encode_get_peer_address(username string) []u8 {
	mut w := new_msg(srv_get_peer_address)
	w.put_string(username)
	return w.frame()
}

// encode_connect_to_peer asks the server to tell `username` to connect to us.
pub fn encode_connect_to_peer(token u32, username string, typ string) []u8 {
	mut w := new_msg(srv_connect_to_peer)
	w.put_u32(token)
	w.put_string(username)
	w.put_string(typ)
	return w.frame()
}

pub fn encode_cant_connect_to_peer(token u32, username string) []u8 {
	mut w := new_msg(srv_cant_connect_to_peer)
	w.put_u32(token)
	w.put_string(username)
	return w.frame()
}

// ---------------------------------------------------------------------------
// server: incoming
// ---------------------------------------------------------------------------

pub struct PeerAddress {
pub:
	username string
	ip       string
	port     u32
}

pub fn decode_peer_address(mut r Reader) !PeerAddress {
	username := r.string()!
	ip := ip_to_string(r.u32()!)
	port := r.u32()!
	return PeerAddress{
		username: username
		ip:       ip
		port:     port
	}
}

pub struct ConnectToPeer {
pub:
	username   string
	typ        string
	ip         string
	port       u32
	token      u32
	privileged bool
}

pub fn decode_connect_to_peer(mut r Reader) !ConnectToPeer {
	username := r.string()!
	typ := r.string()!
	ip := ip_to_string(r.u32()!)
	port := r.u32()!
	token := r.u32()!
	privileged := r.bool() or { false }
	return ConnectToPeer{
		username:   username
		typ:        typ
		ip:         ip
		port:       port
		token:      token
		privileged: privileged
	}
}

pub struct SearchRequest {
pub:
	username string
	token    u32
	query    string
}

// decode_file_search decodes a server FileSearch (26) body.
pub fn decode_file_search(mut r Reader) !SearchRequest {
	username := r.string()!
	token := r.u32()!
	query := r.string()!
	return SearchRequest{
		username: username
		token:    token
		query:    query
	}
}

pub struct PossibleParent {
pub:
	username string
	ip       string
	port     u32
}

pub fn decode_possible_parents(mut r Reader) ![]PossibleParent {
	n := int(r.u32()!)
	if n < 0 || n > r.remaining() {
		return error('invalid parent count ${n}')
	}
	mut out := []PossibleParent{cap: n}
	for _ in 0 .. n {
		username := r.string()!
		ip := ip_to_string(r.u32()!)
		port := r.u32()!
		out << PossibleParent{
			username: username
			ip:       ip
			port:     port
		}
	}
	return out
}

// ---------------------------------------------------------------------------
// peer init
// ---------------------------------------------------------------------------

pub fn encode_pierce_firewall(token u32) []u8 {
	mut w := new_init_msg(init_pierce_firewall)
	w.put_u32(token)
	return w.frame()
}

pub fn encode_peer_init(username string, typ string, token u32) []u8 {
	mut w := new_init_msg(init_peer_init)
	w.put_string(username)
	w.put_string(typ)
	w.put_u32(token)
	return w.frame()
}

// InitMessage is the first message received on a new peer connection.
pub struct InitMessage {
pub:
	pierce   bool // true: PierceFirewall (only token is set), false: PeerInit
	username string
	typ      string
	token    u32
}

pub fn decode_init(payload []u8) !InitMessage {
	mut r := new_reader(payload)
	code := r.u8()!
	match code {
		init_pierce_firewall {
			return InitMessage{
				pierce: true
				token:  r.u32()!
			}
		}
		init_peer_init {
			username := r.string()!
			typ := r.string()!
			token := r.u32()!
			return InitMessage{
				username: username
				typ:      typ
				token:    token
			}
		}
		else {
			return error('unexpected init message code ${code}')
		}
	}
}

// ---------------------------------------------------------------------------
// peer messages
// ---------------------------------------------------------------------------

// peer_code returns the u32 code of a peer message payload and a reader positioned after it.
pub fn peer_code(payload []u8) !(u32, Reader) {
	mut r := new_reader(payload)
	code := r.u32()!
	return code, r
}

pub fn encode_shared_file_list_request() []u8 {
	return new_msg(peer_shared_file_list_request).frame()
}

// encode_shared_file_list_response builds a compressed browse response.
pub fn encode_shared_file_list_response(dirs []DirEntry) ![]u8 {
	mut body := Writer{}
	body.put_dirs(dirs)
	body.put_u32(0) // unknown
	body.put_u32(0) // number of private directories
	packed := zlib.compress(body.buf)!
	mut w := new_msg(peer_shared_file_list_response)
	w.put_bytes(packed)
	return w.frame()
}

// decode_shared_file_list_response decodes the (compressed) remainder of a browse response.
pub fn decode_shared_file_list_response(mut r Reader) ![]DirEntry {
	raw := zlib.decompress(r.rest())!
	mut br := new_reader(raw)
	return br.dirs()!
}

pub fn encode_folder_contents_request(token u32, folder string) []u8 {
	mut w := new_msg(peer_folder_contents_request)
	w.put_u32(token)
	w.put_string(folder)
	return w.frame()
}

pub struct FolderContentsRequest {
pub:
	token  u32
	folder string
}

pub fn decode_folder_contents_request(mut r Reader) !FolderContentsRequest {
	token := r.u32()!
	folder := r.string()!
	return FolderContentsRequest{
		token:  token
		folder: folder
	}
}

pub fn encode_folder_contents_response(token u32, folder string, dirs []DirEntry) ![]u8 {
	mut body := Writer{}
	body.put_u32(token)
	body.put_string(folder)
	body.put_dirs(dirs)
	packed := zlib.compress(body.buf)!
	mut w := new_msg(peer_folder_contents_response)
	w.put_bytes(packed)
	return w.frame()
}

pub struct FolderContentsResponse {
pub:
	token  u32
	folder string
	dirs   []DirEntry
}

pub fn decode_folder_contents_response(mut r Reader) !FolderContentsResponse {
	raw := zlib.decompress(r.rest())!
	mut br := new_reader(raw)
	token := br.u32()!
	folder := br.string()!
	dirs := br.dirs()!
	return FolderContentsResponse{
		token:  token
		folder: folder
		dirs:   dirs
	}
}

pub struct SearchResponse {
pub:
	username  string
	token     u32
	files     []FileEntry
	slot_free bool
	avg_speed u32
	queue_len u32
}

pub fn encode_file_search_response(sr SearchResponse) ![]u8 {
	mut body := Writer{}
	body.put_string(sr.username)
	body.put_u32(sr.token)
	body.put_u32(u32(sr.files.len))
	for f in sr.files {
		body.put_file(f)
	}
	body.put_bool(sr.slot_free)
	body.put_u32(sr.avg_speed)
	body.put_u32(sr.queue_len)
	body.put_u32(0) // unknown / upper half of the queue length
	body.put_u32(0) // number of privately shared results
	packed := zlib.compress(body.buf)!
	mut w := new_msg(peer_file_search_response)
	w.put_bytes(packed)
	return w.frame()
}

pub fn decode_file_search_response(mut r Reader) !SearchResponse {
	raw := zlib.decompress(r.rest())!
	mut br := new_reader(raw)
	username := br.string()!
	token := br.u32()!
	n := int(br.u32()!)
	if n < 0 || n > br.remaining() {
		return error('invalid file count ${n}')
	}
	mut files := []FileEntry{cap: n}
	for _ in 0 .. n {
		files << br.file()!
	}
	slot_free := br.bool()!
	avg_speed := br.u32()!
	queue_len := br.u32()!
	return SearchResponse{
		username:  username
		token:     token
		files:     files
		slot_free: slot_free
		avg_speed: avg_speed
		queue_len: queue_len
	}
}

pub fn encode_user_info_request() []u8 {
	return new_msg(peer_user_info_request).frame()
}

pub struct UserInfo {
pub:
	description    string
	upload_slots   u32
	queue_size     u32
	slot_free      bool
	upload_allowed u32 // 0 no one, 1 everyone, 2 friends, 3 trusted
}

pub fn encode_user_info_response(ui UserInfo) []u8 {
	mut w := new_msg(peer_user_info_response)
	w.put_string(ui.description)
	w.put_bool(false) // no picture
	w.put_u32(ui.upload_slots)
	w.put_u32(ui.queue_size)
	w.put_bool(ui.slot_free)
	w.put_u32(ui.upload_allowed)
	return w.frame()
}

pub fn decode_user_info_response(mut r Reader) !UserInfo {
	description := r.string()!
	has_pic := r.bool()!
	if has_pic {
		n := int(r.u32()!)
		r.bytes(n)!
	}
	slots := r.u32()!
	queue := r.u32()!
	slot_free := r.bool()!
	allowed := r.u32() or { 0 }
	return UserInfo{
		description:    description
		upload_slots:   slots
		queue_size:     queue
		slot_free:      slot_free
		upload_allowed: allowed
	}
}

pub struct TransferRequest {
pub:
	direction u32
	token     u32
	filename  string
	size      u64 // only present when direction == dir_upload
}

pub fn encode_transfer_request(tr TransferRequest) []u8 {
	mut w := new_msg(peer_transfer_request)
	w.put_u32(tr.direction)
	w.put_u32(tr.token)
	w.put_string(tr.filename)
	if tr.direction == dir_upload {
		w.put_u64(tr.size)
	}
	return w.frame()
}

pub fn decode_transfer_request(mut r Reader) !TransferRequest {
	direction := r.u32()!
	token := r.u32()!
	filename := r.string()!
	mut size := u64(0)
	if direction == dir_upload {
		size = r.u64()!
	}
	return TransferRequest{
		direction: direction
		token:     token
		filename:  filename
		size:      size
	}
}

pub struct TransferResponse {
pub:
	token   u32
	allowed bool
	size    u64    // present when allowed in reply to a download-direction request
	reason  string // present when not allowed
}

// encode_transfer_response builds a TransferResponse. `with_size` should be true only when
// replying to a download-direction request with allowed = true.
pub fn encode_transfer_response(tr TransferResponse, with_size bool) []u8 {
	mut w := new_msg(peer_transfer_response)
	w.put_u32(tr.token)
	w.put_bool(tr.allowed)
	if tr.allowed {
		if with_size {
			w.put_u64(tr.size)
		}
	} else {
		w.put_string(tr.reason)
	}
	return w.frame()
}

pub fn decode_transfer_response(mut r Reader) !TransferResponse {
	token := r.u32()!
	allowed := r.bool()!
	if allowed {
		size := if r.remaining() >= 8 { r.u64()! } else { u64(0) }
		return TransferResponse{
			token:   token
			allowed: true
			size:    size
		}
	}
	reason := r.string() or { '' }
	return TransferResponse{
		token:   token
		allowed: false
		reason:  reason
	}
}

pub fn encode_queue_upload(filename string) []u8 {
	mut w := new_msg(peer_queue_upload)
	w.put_string(filename)
	return w.frame()
}

pub fn encode_place_in_queue_request(filename string) []u8 {
	mut w := new_msg(peer_place_in_queue_request)
	w.put_string(filename)
	return w.frame()
}

pub fn encode_place_in_queue_response(filename string, place u32) []u8 {
	mut w := new_msg(peer_place_in_queue_response)
	w.put_string(filename)
	w.put_u32(place)
	return w.frame()
}

pub fn encode_upload_failed(filename string) []u8 {
	mut w := new_msg(peer_upload_failed)
	w.put_string(filename)
	return w.frame()
}

pub fn encode_upload_denied(filename string, reason string) []u8 {
	mut w := new_msg(peer_upload_denied)
	w.put_string(filename)
	w.put_string(reason)
	return w.frame()
}

// ---------------------------------------------------------------------------
// distributed messages
// ---------------------------------------------------------------------------

pub struct DistribSearch {
pub:
	username string
	token    u32
	query    string
}

// decode_distrib_search decodes the body of a distributed search (after the u8 code).
pub fn decode_distrib_search(mut r Reader) !DistribSearch {
	r.u32()! // unknown
	username := r.string()!
	token := r.u32()!
	query := r.string()!
	return DistribSearch{
		username: username
		token:    token
		query:    query
	}
}

pub fn encode_distrib_search(ds DistribSearch) []u8 {
	mut w := new_init_msg(dist_search)
	w.put_u32(0)
	w.put_string(ds.username)
	w.put_u32(ds.token)
	w.put_string(ds.query)
	return w.frame()
}

// decode_distrib_embedded decodes DistribEmbedded (93): u8 distributed code and payload.
pub fn decode_distrib_embedded(mut r Reader) !(u8, []u8) {
	code := r.u8()!
	return code, r.rest()
}

// encode_distrib_child_depth tells our distributed parent how deep our own subtree is.
pub fn encode_distrib_child_depth(depth u32) []u8 {
	mut w := new_init_msg(dist_child_depth)
	w.put_u32(depth)
	return w.frame()
}
