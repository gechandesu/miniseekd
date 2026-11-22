module shares

import os

fn make_tree() !string {
	root := os.join_path(os.temp_dir(), 'slsk_shares_test_${os.getpid()}')
	os.rmdir_all(root) or {}
	os.mkdir_all(os.join_path(root, 'Music', 'Artist One', 'Album A'))!
	os.mkdir_all(os.join_path(root, 'Music', 'Empty'))!
	os.mkdir_all(os.join_path(root, 'Other'))!
	os.write_file(os.join_path(root, 'Music', 'Artist One', 'Album A', '01 First Song.mp3'),
		'aaaa')!
	os.write_file(os.join_path(root, 'Music', 'Artist One', 'Album A', '02 Second_Song.flac'),
		'bbbbbb')!
	os.write_file(os.join_path(root, 'Music', 'Artist One', 'Album A', 'Thumbs.db'), 'x')!
	os.write_file(os.join_path(root, 'Music', 'notes.ini'), 'x')!
	os.write_file(os.join_path(root, 'Other', 'readme.txt'), 'hello')!
	os.symlink(os.join_path(root, 'Other'), os.join_path(root, 'Music', 'link'))!
	return root
}

fn test_scan_and_lookup() {
	root := make_tree()!
	defer {
		os.rmdir_all(root) or {}
	}
	res := scan([os.join_path(root, 'Music'), os.join_path(root, 'Other')], [r'\.ini$', r'Thumbs\.db$'])!
	idx := res.index
	assert idx.file_count() == 3
	assert res.skipped >= 3 // two filtered files + symlink

	f := idx.lookup('Music\\Artist One\\Album A\\01 First Song.mp3') or {
		assert false, 'file must be found'
		return
	}
	assert f.size == 4
	assert f.ext == 'mp3'
	assert f.local.starts_with(root)
	assert f.dir == 'Music\\Artist One\\Album A'

	assert idx.lookup('Music\\notes.ini') == none
	assert idx.lookup('Music\\..\\Other\\readme.txt') == none
	assert idx.lookup('nope') == none
	assert idx.lookup('Other\\readme.txt') != none
}

fn test_browse_and_directory() {
	root := make_tree()!
	defer {
		os.rmdir_all(root) or {}
	}
	idx := scan([os.join_path(root, 'Music')], [r'\.ini$', r'Thumbs\.db$'])!.index
	dirs := idx.browse()
	names := dirs.map(it.name)
	assert 'Music' in names
	assert 'Music\\Artist One' in names
	assert 'Music\\Artist One\\Album A' in names
	assert 'Music\\Empty' in names
	d := idx.directory('Music\\Artist One\\Album A') or {
		assert false
		return
	}
	assert d.files.len == 2
	assert d.files[0].filename == '01 First Song.mp3'
	assert idx.directory('Music\\Nope') == none
	assert idx.dir_count() == 4
}

fn test_search() {
	root := make_tree()!
	defer {
		os.rmdir_all(root) or {}
	}
	idx := scan([os.join_path(root, 'Music'), os.join_path(root, 'Other')], [r'\.ini$', r'Thumbs\.db$'])!.index
	assert idx.search('first song', 100).len == 1
	assert idx.search('SECOND', 100).len == 1
	assert idx.search('song', 100).len == 2
	assert idx.search('song -second', 100).len == 1
	assert idx.search('song flac', 100).len == 1
	assert idx.search('artist one mp3', 100).len == 1
	assert idx.search('nothing here', 100).len == 0
	assert idx.search('', 100).len == 0
	assert idx.search('-song', 100).len == 0
	assert idx.search('song', 1).len == 1
	r := idx.search('readme', 10)
	assert r[0].filename == 'Other\\readme.txt'
}

fn test_duplicate_alias() {
	root := make_tree()!
	defer {
		os.rmdir_all(root) or {}
	}
	other := os.join_path(root, 'x', 'Other')
	os.mkdir_all(other)!
	os.write_file(os.join_path(other, 'f.txt'), 'f')!
	idx := scan([os.join_path(root, 'Other'), other], [])!.index
	assert idx.lookup('Other\\readme.txt') != none
	assert idx.lookup('Other_2\\f.txt') != none
}

fn test_has_traversal() {
	assert has_traversal('a\\..\\b')
	assert has_traversal('../x')
	assert has_traversal('a\\.\\b')
	assert has_traversal('a\0b')
	assert !has_traversal('a\\b..c\\d.mp3')
}

fn test_invalid_filter() {
	if _ := scan([], ['[']) {
		assert false
	}
}

fn test_store_swap() {
	mut s := new_store()
	assert s.current().file_count() == 0
	root := make_tree()!
	defer {
		os.rmdir_all(root) or {}
	}
	idx := scan([os.join_path(root, 'Other')], [])!.index
	s.replace(idx)
	assert s.current().file_count() == 1
}
