module conf

import os
import toml

pub struct SoulseekConf {
pub mut:
	server_host string = 'vps.slsknet.org' @[toml: 'server-host']
	server_port int    = 2271              @[toml: 'server-port']
	username    string
	password    string
	listen_host string = '0.0.0.0' @[toml: 'listen-host']
	listen_port int    = 50300     @[toml: 'listen-port']
	description string = 'A Soulseek user'
}

pub struct SharesConf {
pub mut:
	directories []string
	filters     []string = [r'\.ini$', r'Thumbs\.db$', r'\.DS_Store$']
	// rescan_interval_minutes = 0 disables periodic rescans
	rescan_interval_minutes int @[toml: 'rescan-interval-minutes']
}

pub struct UploadConf {
pub mut:
	slots               int = 5
	speed_limit_kib     int      @[toml: 'speed-limit-kib'] // 0 = unlimited
	max_queued_per_user int = 50 @[toml: 'max-queued-per-user']
}

pub struct TransfersConf {
pub mut:
	upload UploadConf
}

pub struct LoggingConf {
pub mut:
	level   string = 'info'
	file    string
	console bool = true
}

pub struct DaemonConf {
pub mut:
	pid_file string @[toml: 'pid-file']
}

pub struct Config {
pub mut:
	soulseek  SoulseekConf
	shares    SharesConf
	transfers TransfersConf
	logging   LoggingConf
	daemon    DaemonConf
}

// load reads and validates a TOML configuration file.
pub fn load(path string) !Config {
	text := os.read_file(path) or { return error('cannot read config file "${path}": ${err}') }
	return parse(text)
}

// parse decodes a TOML document, applies environment overrides and validates it.
pub fn parse(text string) !Config {
	mut c := toml.decode[Config](text) or { return error('invalid config: ${err}') }
	c.apply_env()
	c.validate()!
	return c
}

fn (mut c Config) apply_env() {
	if v := os.getenv_opt('SLSK_USERNAME') {
		c.soulseek.username = v
	}
	if v := os.getenv_opt('SLSK_PASSWORD') {
		c.soulseek.password = v
	} else if v := os.getenv_opt('SLSK_PASSWORD_FILE') {
		c.soulseek.password = os.read_file(v) or { return }.trim_right('\n')
	}
}

// validate checks the configuration for obvious mistakes.
pub fn (c Config) validate() ! {
	if c.soulseek.username.trim_space() == '' {
		return error('soulseek.username must not be empty (or set SLSK_USERNAME)')
	}
	if c.soulseek.password == '' {
		return error('soulseek.password must not be empty (or set SLSK_PASSWORD/SLSK_PASSWORD_FILE)')
	}
	if c.soulseek.server_host == '' {
		return error('soulseek.server-host must not be empty')
	}
	check_port('soulseek.server-port', c.soulseek.server_port)!
	check_port('soulseek.listen-port', c.soulseek.listen_port)!
	if c.shares.directories.len == 0 {
		return error('shares.directories must contain at least one directory')
	}
	for d in c.shares.directories {
		if !os.is_dir(d) {
			return error('shares.directories: "${d}" is not an existing directory')
		}
		if !os.is_abs_path(d) {
			return error('shares.directories: "${d}" must be an absolute path')
		}
	}
	if c.transfers.upload.slots < 1 {
		return error('transfers.upload.slots must be >= 1')
	}
	if c.transfers.upload.speed_limit_kib < 0 {
		return error('transfers.upload.speed-limit-kib must be >= 0')
	}
	if c.transfers.upload.max_queued_per_user < 1 {
		return error('transfers.upload.max-queued-per-user must be >= 1')
	}
	if c.logging.level !in ['debug', 'info', 'warn', 'error'] {
		return error('logging.level must be one of: debug, info, warn, error')
	}
}

fn check_port(name string, p int) ! {
	if p < 1 || p > 65535 {
		return error('${name} must be in range 1..65535')
	}
}
