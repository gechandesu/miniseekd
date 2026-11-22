module proto

import encoding.binary
import encoding.utf8
import io

// max_frame_size is the largest frame accepted from the network.
pub const max_frame_size = 32 * 1024 * 1024

// Writer builds a message payload using Soulseek's little-endian encoding.
pub struct Writer {
pub mut:
	buf []u8
}

// new_server_msg starts a message with a u32 code (server and peer messages).
pub fn new_msg(code u32) Writer {
	mut w := Writer{}
	w.put_u32(code)
	return w
}

// new_init_msg starts a message with a u8 code (peer-init and distributed messages).
pub fn new_init_msg(code u8) Writer {
	mut w := Writer{}
	w.put_u8(code)
	return w
}

pub fn (mut w Writer) put_u8(v u8) {
	w.buf << v
}

pub fn (mut w Writer) put_bool(v bool) {
	w.buf << if v { u8(1) } else { u8(0) }
}

pub fn (mut w Writer) put_u32(v u32) {
	mut b := []u8{len: 4}
	binary.little_endian_put_u32(mut b, v)
	w.buf << b
}

pub fn (mut w Writer) put_u64(v u64) {
	mut b := []u8{len: 8}
	binary.little_endian_put_u64(mut b, v)
	w.buf << b
}

pub fn (mut w Writer) put_bytes(b []u8) {
	w.buf << b
}

pub fn (mut w Writer) put_string(s string) {
	w.put_u32(u32(s.len))
	w.buf << s.bytes()
}

// frame returns the payload prefixed with its u32 length, ready to be written to a socket.
pub fn (w Writer) frame() []u8 {
	mut out := []u8{len: 4, cap: w.buf.len + 4}
	binary.little_endian_put_u32(mut out, u32(w.buf.len))
	out << w.buf
	return out
}

// Reader decodes a message payload with bounds checking.
pub struct Reader {
pub:
	data []u8
pub mut:
	pos int
}

pub fn new_reader(data []u8) Reader {
	return Reader{
		data: data
	}
}

pub fn (r Reader) remaining() int {
	return r.data.len - r.pos
}

fn (r Reader) need(n int) ! {
	if n < 0 || r.remaining() < n {
		return error('message too short: need ${n} bytes at offset ${r.pos}, have ${r.remaining()}')
	}
}

pub fn (mut r Reader) u8() !u8 {
	r.need(1)!
	v := r.data[r.pos]
	r.pos++
	return v
}

pub fn (mut r Reader) bool() !bool {
	return r.u8()! != 0
}

pub fn (mut r Reader) u32() !u32 {
	r.need(4)!
	v := binary.little_endian_u32_at(r.data, r.pos)
	r.pos += 4
	return v
}

pub fn (mut r Reader) u64() !u64 {
	r.need(8)!
	v := binary.little_endian_u64_at(r.data, r.pos)
	r.pos += 8
	return v
}

pub fn (mut r Reader) bytes(n int) ![]u8 {
	r.need(n)!
	v := r.data[r.pos..r.pos + n].clone()
	r.pos += n
	return v
}

// string reads a length-prefixed string. Invalid UTF-8 is treated as Latin-1.
pub fn (mut r Reader) string() !string {
	n := int(r.u32()!)
	if n > r.remaining() {
		return error('string length ${n} exceeds remaining ${r.remaining()} bytes')
	}
	raw := r.data[r.pos..r.pos + n].clone()
	r.pos += n
	s := raw.bytestr()
	if utf8.validate_str(s) {
		return s
	}
	return latin1_to_utf8(raw)
}

// rest returns all unread bytes.
pub fn (mut r Reader) rest() []u8 {
	v := r.data[r.pos..].clone()
	r.pos = r.data.len
	return v
}

fn latin1_to_utf8(raw []u8) string {
	mut out := []u8{cap: raw.len * 2}
	for b in raw {
		if b < 0x80 {
			out << b
		} else {
			out << u8(0xc0 | (b >> 6))
			out << u8(0x80 | (b & 0x3f))
		}
	}
	return out.bytestr()
}

// read_exact fills `buf` completely from the reader.
pub fn read_exact(mut r io.Reader, mut buf []u8) ! {
	mut got := 0
	for got < buf.len {
		n := r.read(mut buf[got..])!
		if n <= 0 {
			return error('connection closed')
		}
		got += n
	}
}

// read_frame reads one length-prefixed frame and returns its payload.
pub fn read_frame(mut r io.Reader) ![]u8 {
	mut hdr := []u8{len: 4}
	read_exact(mut r, mut hdr)!
	n := int(binary.little_endian_u32(hdr))
	if n < 0 || n > max_frame_size {
		return error('frame of ${n} bytes exceeds the maximum of ${max_frame_size}')
	}
	mut payload := []u8{len: n}
	if n > 0 {
		read_exact(mut r, mut payload)!
	}
	return payload
}

// ip_to_string converts the on-the-wire u32 (little-endian read of reversed octets) to dotted form.
pub fn ip_to_string(v u32) string {
	return '${(v >> 24) & 0xff}.${(v >> 16) & 0xff}.${(v >> 8) & 0xff}.${v & 0xff}'
}

// ip_from_string converts dotted notation to the on-the-wire u32.
pub fn ip_from_string(s string) u32 {
	parts := s.split('.')
	if parts.len != 4 {
		return 0
	}
	mut v := u32(0)
	for p in parts {
		v = (v << 8) | u32(p.int() & 0xff)
	}
	return v
}
