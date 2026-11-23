module main

import flag
import os
import time
import lib.conf
import lib.daemon
import lib.logx
import lib.slsknet

const name = 'nightseekd'
const version = '0.1.0'
const usage = 'Usage: ${name} [OPTION]'
const default_config_path = 'config.toml'

struct Flags {
	help     bool   @[xdoc: 'show this help message and exit']
	version  bool   @[xdoc: 'show version info and exit']
	config   string @[short: 'c'; xdoc: 'path to the TOML configuration file']
	daemon   bool   @[short: 'd'; xdoc: 'detach from the terminal and run in the background']
	pid_file string @[xdoc: 'write the process id to this file (overrides daemon.pid-file)']
}

fn main() {
	help := flag.to_doc[Flags](
		options: flag.DocOptions{
			compact: true
		}
	)!

	flags, unmatched := flag.to_struct[Flags](os.args, skip: 1) or {
		eprintln('error: ${err}')
		println(usage)
		println(help)
		exit(2)
	}

	if flags.help {
		println(usage)
		println(help)
		return
	}

	if flags.version {
		println(version)
		return
	}

	if unmatched.len > 0 {
		eprintln('error: unrecognized arguments: ${unmatched.join(' ')}')
		println(usage)
		println(help)
		exit(2)
	}

	config_path := os.abs_path(if flags.config != '' { flags.config } else { default_config_path })
	mut cfg := conf.load(config_path) or {
		eprintln('error: ${err}')
		exit(2)
	}
	if flags.pid_file != '' {
		cfg.daemon.pid_file = flags.pid_file
	}
	if cfg.daemon.pid_file != '' {
		cfg.daemon.pid_file = os.abs_path(cfg.daemon.pid_file)
	}
	if cfg.logging.file != '' {
		cfg.logging.file = os.abs_path(cfg.logging.file)
	}

	daemon.check_pid_file(cfg.daemon.pid_file) or {
		eprintln('error: ${err}')
		exit(1)
	}
	if flags.daemon {
		if cfg.logging.file == '' {
			eprintln('error: --daemon requires logging.file to be set in the configuration')
			exit(2)
		}
		daemon.daemonize() or {
			eprintln('error: ${err}')
			exit(1)
		}
	}

	mut logger := logx.new(cfg.logging.level, cfg.logging.file, cfg.logging.console && !flags.daemon) or {
		eprintln('error: ${err}')
		exit(2)
	}
	logger.info('${name} ${version} starting (pid ${os.getpid()}, config ${config_path})')

	daemon.write_pid_file(cfg.daemon.pid_file) or {
		logger.error('${err}')
		exit(1)
	}
	daemon.install_signal_handlers() or {
		logger.error('cannot install signal handlers: ${err}')
		exit(1)
	}

	if cfg.logging.console {
		println($embed_file('logo.ascii').to_string())
	}
	code := serve(mut logger, cfg, config_path)
	if code != 0 && !flags.daemon {
		eprintln('${name} failed, see the log for details')
	}
	daemon.remove_pid_file(cfg.daemon.pid_file)
	logger.info('${name} stopped')
	logger.close()
	exit(code)
}

// serve runs the client until it fails fatally or a stop signal arrives. Returns the exit code.
fn serve(mut logger logx.Logger, cfg conf.Config, config_path string) int {
	mut client := slsknet.new_client(cfg, logger)
	client.scan_shares() or {
		logger.error('initial share scan failed: ${err}')
		return 1
	}
	done := chan string{cap: 1}
	spawn run_client(mut client, done)

	for {
		if daemon.stop_requested() {
			logger.info('stop signal received')
			client.stop()
			return 0
		}
		if daemon.take_reload() {
			logger.info('reload signal received')
			logger.reopen()
			if new_cfg := conf.load(config_path) {
				client.reload(new_cfg)
			} else {
				logger.error('cannot reload configuration, keeping the current one: ${err}')
			}
		}
		select {
			msg := <-done {
				if msg == '' {
					return 0
				}
				logger.error('fatal: ${msg}')
				return 1
			}
			200 * time.millisecond {
			}
		}
	}
	return 0
}

fn run_client(mut client slsknet.Client, done chan string) {
	client.run() or {
		done <- err.msg()
		return
	}
	done <- ''
}
