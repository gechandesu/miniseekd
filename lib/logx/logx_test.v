module logx

import os

fn test_file_logger() {
	dir := os.join_path(os.temp_dir(), 'slskd_logx_test_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'test.log')
	mut l := new('info', path, false)!
	l.info('hello world')
	l.debug('hidden debug')
	l.warn('careful')
	l.close()
	content := os.read_file(path)!
	assert content.contains('hello world')
	assert content.contains('careful')
	assert !content.contains('hidden debug')
}

fn test_log_injection_is_neutralised() {
	assert sanitize('a\nb\r\nc') == 'a\\nb\\r\\nc'
	assert sanitize('plain') == 'plain'
	dir := os.join_path(os.temp_dir(), 'slskd_logx_inj_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'inj.log')
	mut l := new('info', path, false)!
	l.info('query "x\n2026-01-01 [ERROR] forged"')
	l.close()
	content := os.read_file(path)!
	assert content.trim_space().split_into_lines().len == 1
}
