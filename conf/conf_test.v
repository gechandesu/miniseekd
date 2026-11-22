module conf

fn test_parse_minimal() {
	c := parse('[soulseek]
username = "bob"
password = "secret"

[shares]
directories = ["/tmp"]
')!
	assert c.soulseek.username == 'bob'
	assert c.soulseek.port == 2271
	assert c.soulseek.listen_port == 50300
	assert c.transfers.upload.slots == 5
	assert c.logging.console
	assert c.shares.filters.len == 3
}

fn test_parse_overrides() {
	c := parse('[soulseek]
username = "bob"
password = "secret"
listen-port = 12345

[shares]
directories = ["/tmp"]
filters = []

[transfers.upload]
slots = 2
speed-limit-kib = 100

[logging]
level = "debug"
console = false
')!
	assert c.soulseek.listen_port == 12345
	assert c.transfers.upload.slots == 2
	assert c.transfers.upload.speed_limit_kib == 100
	assert c.logging.level == 'debug'
	assert !c.logging.console
	assert c.shares.filters.len == 0
}

fn test_validation_errors() {
	if _ := parse('[soulseek]
password = "x"
[shares]
directories = ["/tmp"]
') {
		assert false, 'empty username must fail'
	}
	if _ := parse('[soulseek]
username = "a"
password = "x"
[shares]
directories = ["/definitely/not/here"]
') {
		assert false, 'missing dir must fail'
	}
	if _ := parse('[soulseek]
username = "a"
password = "x"
listen-port = 70000
[shares]
directories = ["/tmp"]
') {
		assert false, 'bad port must fail'
	}
}
