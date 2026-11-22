module shares

import os
import regex
import sync
import time
import lib.proto

// max_search_results caps the number of files returned for a single search.
pub const max_search_results = 500

pub struct SharedFile {
pub:
	remote string // virtual path, e.g. Music\Album\track.mp3
	local  string // real path on disk (never sent to the network)
	size   u64
	ext    string // lower-case extension without dot
	dir    string // virtual directory
	name   string // file name
}

// Index is an immutable snapshot of all shared files. It is replaced atomically by Store.
@[heap]
pub struct Index {
pub:
	files    []SharedFile
	dir_list []string // sorted virtual directories (every directory including empty/intermediate ones)
	built_at time.Time
mut:
	by_remote map[string]int   // remote path -> index in files
	by_dir    map[string][]int // virtual dir -> file indexes (sorted by name)
	words     map[string][]int // lower-case word -> file indexes
}

// Store holds the current index and allows swapping it atomically.
@[heap]
pub struct Store {
mut:
	mu  &sync.RwMutex = sync.new_rwmutex()
	idx &Index        = &Index{}
}

pub fn new_store() &Store {
	return &Store{}
}

pub fn (mut s Store) current() &Index {
	s.mu.rlock()
	i := s.idx
	s.mu.runlock()
	return i
}

pub fn (mut s Store) replace(i &Index) {
	s.mu.lock()
	s.idx = i
	s.mu.unlock()
}

// ScanResult describes what a scan found.
pub struct ScanResult {
pub:
	index   &Index
	skipped int
}

// scan walks the configured directories and builds a new index.
// Symbolic links are never followed; files matching one of the `filters` regexes are skipped.
pub fn scan(directories []string, filters []string) !ScanResult {
	mut res := []regex.RE{}
	for f in filters {
		res << regex.regex_opt(f) or { return error('invalid share filter "${f}": ${err}') }
	}
	mut b := Builder{
		filters: res
	}
	mut used_aliases := map[string]bool{}
	for d in directories {
		root := os.real_path(d.trim_right('/'))
		mut base := os.file_name(root)
		if base == '' {
			base = 'root'
		}
		mut alias := base
		mut n := 2
		for used_aliases[alias] {
			alias = '${base}_${n}'
			n++
		}
		used_aliases[alias] = true
		b.dirs[alias] = true
		b.walk(root, alias)
	}
	return ScanResult{
		index:   b.build()
		skipped: b.skipped
	}
}

struct Builder {
mut:
	files   []SharedFile
	dirs    map[string]bool
	filters []regex.RE
	skipped int
}

fn (mut b Builder) is_filtered(path string) bool {
	for mut re in b.filters {
		start, _ := re.find(path)
		if start >= 0 {
			return true
		}
	}
	return false
}

fn (mut b Builder) walk(local_dir string, remote_dir string) {
	entries := os.ls(local_dir) or { return }
	mut sorted := entries.clone()
	sorted.sort()
	for name in sorted {
		local := os.join_path_single(local_dir, name)
		if os.is_link(local) {
			b.skipped++
			continue
		}
		remote := remote_dir + '\\' + name
		if os.is_dir(local) {
			b.dirs[remote] = true
			b.walk(local, remote)
			continue
		}
		if !os.is_file(local) {
			continue
		}
		if b.is_filtered(local) {
			b.skipped++
			continue
		}
		size := os.file_size(local)
		b.files << SharedFile{
			remote: remote
			local:  local
			size:   u64(size)
			ext:    os.file_ext(name).trim_left('.').to_lower()
			dir:    remote_dir
			name:   name
		}
	}
}

fn (mut b Builder) build() &Index {
	mut idx := &Index{
		files:    b.files
		dir_list: sorted_keys(b.dirs)
		built_at: time.now()
	}
	for d in idx.dir_list {
		idx.by_dir[d] = []int{}
	}
	for i, f in idx.files {
		idx.by_remote[f.remote] = i
		idx.by_dir[f.dir] << i
		for w in tokenize(f.remote) {
			if w in idx.words {
				// avoid duplicate postings for a word occurring twice in one path
				if idx.words[w].last() != i {
					idx.words[w] << i
				}
			} else {
				idx.words[w] = [i]
			}
		}
	}
	return idx
}

fn sorted_keys(m map[string]bool) []string {
	mut keys := m.keys()
	keys.sort()
	return keys
}

// tokenize splits `s` into lower-case words made of letters and digits.
pub fn tokenize(s string) []string {
	mut words := []string{}
	mut cur := []u8{}
	for b in s.to_lower().bytes() {
		if (b >= `a` && b <= `z`) || (b >= `0` && b <= `9`) || b >= 0x80 {
			cur << b
		} else if cur.len > 0 {
			words << cur.bytestr()
			cur = []u8{}
		}
	}
	if cur.len > 0 {
		words << cur.bytestr()
	}
	return words
}

// ---------------------------------------------------------------------------
// Index queries
// ---------------------------------------------------------------------------

pub fn (i &Index) file_count() int {
	return i.files.len
}

pub fn (i &Index) dir_count() int {
	return i.dir_list.len
}

// has_traversal reports whether a remote path contains '.' or '..' segments or NUL bytes.
pub fn has_traversal(path string) bool {
	if path.contains('\0') {
		return true
	}
	for seg in path.replace('/', '\\').split('\\') {
		if seg == '..' || seg == '.' {
			return true
		}
	}
	return false
}

// lookup returns the shared file for a virtual path.
pub fn (i &Index) lookup(remote string) ?SharedFile {
	if has_traversal(remote) {
		return none
	}
	idx := i.by_remote[remote] or { return none }
	return i.files[idx]
}

fn (i &Index) to_entry(f SharedFile, full_name bool) proto.FileEntry {
	return proto.FileEntry{
		filename: if full_name { f.remote } else { f.name }
		size:     f.size
		ext:      f.ext
	}
}

// browse returns the whole share tree for a SharedFileListResponse.
pub fn (i &Index) browse() []proto.DirEntry {
	mut out := []proto.DirEntry{cap: i.dir_list.len}
	for d in i.dir_list {
		out << i.directory(d) or { continue }
	}
	return out
}

// directory returns a single directory (file names are not qualified).
pub fn (i &Index) directory(remote_dir string) ?proto.DirEntry {
	ids := i.by_dir[remote_dir] or { return none }
	mut files := []proto.FileEntry{cap: ids.len}
	for id in ids {
		files << i.to_entry(i.files[id], false)
	}
	return proto.DirEntry{
		name:  remote_dir
		files: files
	}
}

// ParsedQuery is a search query split into required and excluded words.
pub struct ParsedQuery {
pub:
	include []string
	exclude []string
}

// parse_query understands plain terms and `-term` exclusions.
pub fn parse_query(q string) ParsedQuery {
	mut inc := []string{}
	mut exc := []string{}
	for term in q.split(' ') {
		t := term.trim_space()
		if t == '' {
			continue
		}
		if t.starts_with('-') && t.len > 1 {
			exc << tokenize(t[1..])
		} else {
			inc << tokenize(t)
		}
	}
	return ParsedQuery{
		include: inc
		exclude: exc
	}
}

// search returns the files whose paths contain every included word and none of the excluded ones.
pub fn (i &Index) search(query string, limit int) []proto.FileEntry {
	pq := parse_query(query)
	if pq.include.len == 0 {
		return []
	}
	// start from the rarest word
	mut lists := [][]int{}
	for w in pq.include {
		l := i.words[w] or { return [] }
		lists << l
	}
	lists.sort_with_compare(fn (a &[]int, b &[]int) int {
		return a.len - b.len
	})
	mut excluded := map[int]bool{}
	for w in pq.exclude {
		if l := i.words[w] {
			for id in l {
				excluded[id] = true
			}
		}
	}
	mut out := []proto.FileEntry{}
	for id in lists[0] {
		if id in excluded {
			continue
		}
		mut ok := true
		for k in 1 .. lists.len {
			if !contains_sorted(lists[k], id) {
				ok = false
				break
			}
		}
		if !ok {
			continue
		}
		out << i.to_entry(i.files[id], true)
		if out.len >= limit {
			break
		}
	}
	return out
}

// contains_sorted does a binary search; posting lists are built in ascending order.
fn contains_sorted(l []int, v int) bool {
	mut lo := 0
	mut hi := l.len - 1
	for lo <= hi {
		mid := (lo + hi) / 2
		if l[mid] == v {
			return true
		}
		if l[mid] < v {
			lo = mid + 1
		} else {
			hi = mid - 1
		}
	}
	return false
}
