module daemon

import os

fn C.setsid() int
fn C.dup2(oldfd int, newfd int) int
fn C.kill(pid int, sig int) int

// sig_flags is written from signal handlers and polled by the main loop:
// index 0 = stop requested, index 1 = reload requested.
const sig_flags = unsafe { &int(vcalloc(2 * int(sizeof(int)))) }

fn flag_get(i int) int {
	p := sig_flags
	return unsafe { p[i] }
}

fn flag_set(i int, v int) {
	mut p := sig_flags
	unsafe {
		p[i] = v
	}
}

fn on_signal(sig os.Signal) {
	match sig {
		.term, .int { flag_set(0, 1) }
		.hup { flag_set(1, 1) }
		else {}
	}
}

// install_signal_handlers makes SIGTERM/SIGINT request a stop and SIGHUP request a reload.
// SIGPIPE is ignored so that writes to closed sockets return errors instead of killing the process.
pub fn install_signal_handlers() ! {
	os.signal_opt(.term, on_signal)!
	os.signal_opt(.int, on_signal)!
	os.signal_opt(.hup, on_signal)!
	os.signal_ignore(.pipe)
}

// stop_requested reports whether SIGTERM or SIGINT was received.
pub fn stop_requested() bool {
	return flag_get(0) != 0
}

// take_reload returns true once per received SIGHUP.
pub fn take_reload() bool {
	if flag_get(1) != 0 {
		flag_set(1, 0)
		return true
	}
	return false
}

// daemonize detaches the process from the terminal (double fork, setsid, stdio to /dev/null).
// It must be called before any threads are started. The original processes exit; only the
// final child returns.
pub fn daemonize() ! {
	mut pid := os.fork()
	if pid < 0 {
		return error('fork failed')
	}
	if pid > 0 {
		exit(0)
	}
	if C.setsid() < 0 {
		return error('setsid failed')
	}
	pid = os.fork()
	if pid < 0 {
		return error('second fork failed')
	}
	if pid > 0 {
		exit(0)
	}
	os.chdir('/') or {}
	devnull := os.open_file('/dev/null', 'r+') or { return error('cannot open /dev/null: ${err}') }
	C.dup2(devnull.fd, 0)
	C.dup2(devnull.fd, 1)
	C.dup2(devnull.fd, 2)
}

// check_pid_file fails if `path` names a pid file of a process that is still alive.
pub fn check_pid_file(path string) ! {
	if path == '' || !os.exists(path) {
		return
	}
	text := os.read_file(path) or { return }
	pid := text.trim_space().int()
	if pid > 0 && pid != os.getpid() && (C.kill(pid, 0) == 0 || os.is_dir('/proc/${pid}')) {
		return error('another instance seems to be running (pid ${pid}, pid file ${path})')
	}
}

// write_pid_file stores the current process id in `path`.
pub fn write_pid_file(path string) ! {
	if path == '' {
		return
	}
	os.write_file(path, '${os.getpid()}\n') or { return error('cannot write pid file "${path}": ${err}') }
}

// remove_pid_file deletes the pid file, ignoring errors.
pub fn remove_pid_file(path string) {
	if path != '' {
		os.rm(path) or {}
	}
}
