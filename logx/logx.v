module logx

import log
import os
import sync

// Logger is a thread-safe logger writing to the console and/or a file.
pub struct Logger {
mut:
	mu    &sync.Mutex = sync.new_mutex()
	inner log.Log
	file  string
	done  bool
}

// new creates a logger. `level` is one of debug, info, warn, error.
// If `file` is not empty, log lines are appended to it; if `console` is true they
// are also printed to stderr (or only to stderr when no file is configured).
pub fn new(level string, file string, console bool) !&Logger {
	mut l := &Logger{
		file: file
	}
	l.inner.set_level(parse_level(level))
	l.inner.set_local_time(true)
	l.inner.set_time_format(.tf_ss_milli)
	l.inner.set_always_flush(true)
	if file != '' {
		dir := os.dir(file)
		if dir != '' && !os.is_dir(dir) {
			os.mkdir_all(dir) or { return error('cannot create log directory "${dir}": ${err}') }
		}
		// make sure the file is writable before the logger panics on it
		mut f := os.open_append(file) or { return error('cannot open log file "${file}": ${err}') }
		f.close()
		l.inner.set_full_logpath(file)
		if console {
			l.inner.log_to_console_too()
		}
	}
	return l
}

// new_console creates a console-only logger (handy for tests and early startup).
pub fn new_console(level string) &Logger {
	mut l := &Logger{}
	l.inner.set_level(parse_level(level))
	l.inner.set_local_time(true)
	l.inner.set_time_format(.tf_ss_milli)
	l.inner.set_always_flush(true)
	return l
}

fn parse_level(level string) log.Level {
	return match level {
		'debug' { log.Level.debug }
		'warn' { log.Level.warn }
		'error' { log.Level.error }
		else { log.Level.info }
	}
}

pub fn (mut l Logger) debug(msg string) {
	l.mu.lock()
	if !l.done {
		l.inner.debug(sanitize(msg))
	}
	l.mu.unlock()
}

pub fn (mut l Logger) info(msg string) {
	l.mu.lock()
	if !l.done {
		l.inner.info(sanitize(msg))
	}
	l.mu.unlock()
}

pub fn (mut l Logger) warn(msg string) {
	l.mu.lock()
	if !l.done {
		l.inner.warn(sanitize(msg))
	}
	l.mu.unlock()
}

pub fn (mut l Logger) error(msg string) {
	l.mu.lock()
	if !l.done {
		l.inner.error(sanitize(msg))
	}
	l.mu.unlock()
}

// reopen reopens the log file (for log rotation).
pub fn (mut l Logger) reopen() {
	l.mu.lock()
	if !l.done {
		l.inner.reopen() or {}
	}
	l.mu.unlock()
}

// close flushes and closes the log file.
pub fn (mut l Logger) close() {
	l.mu.lock()
	if !l.done {
		l.done = true
		l.inner.flush()
		l.inner.close()
	}
	l.mu.unlock()
}

// sanitize keeps remote-controlled text (queries, names) from forging extra log lines.
fn sanitize(msg string) string {
	if !msg.contains('\n') && !msg.contains('\r') {
		return msg
	}
	return msg.replace('\r', '\\r').replace('\n', '\\n')
}
