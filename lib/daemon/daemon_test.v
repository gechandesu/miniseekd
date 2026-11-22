module daemon

import os

fn test_pid_file_lifecycle() {
	path := os.join_path(os.temp_dir(), 'slsk_daemon_test_${os.getpid()}.pid')
	os.rm(path) or {}
	check_pid_file(path)! // missing file is fine
	write_pid_file(path)!
	assert os.read_file(path)!.trim_space() == os.getpid().str()
	check_pid_file(path)! // our own pid is not a conflict

	// a live foreign process is a conflict (pid 1 always exists)
	os.write_file(path, '1\n')!
	if _ := check_pid_file(path) {
		assert false, 'a live process must block startup'
	}
	// a stale pid file is ignored
	os.write_file(path, '999999999\n')!
	check_pid_file(path)!

	remove_pid_file(path)
	assert !os.exists(path)
	remove_pid_file('') // no-op
}

fn test_signal_flags() {
	assert !stop_requested()
	assert !take_reload()
	flag_set(1, 1)
	assert take_reload()
	assert !take_reload()
	flag_set(0, 1)
	assert stop_requested()
	flag_set(0, 0)
	assert !stop_requested()
}
