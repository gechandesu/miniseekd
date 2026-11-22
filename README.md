```
         _      _             __      __
  __ _  (_)__  (_)__ ___ ___ / /_____/ /
 /  ' \/ / _ \/ (_-</ -_) -_)  '_/ _  /
/_/_/_/_/_//_/_/___/\__/\__/_/\_\\_,_/
```

Headless uploads-only [Soulseek](https://en.wikipedia.org/wiki/Soulseek)
client for sharing your music.

> [!NOTE]
> If you need an advanced, full-featured headless Soulseek client that can
> run as a daemon on your server, there’s an excellent option available —
> [slskd](https://github.com/slskd/slskd).
> This project supports **only file uploads**.

## Why

The reason for creating **miniseekd** is that I needed to expose my music
collection to Soulseek from a host running on a RISC-V architecture CPU.
slskd is written in C# (using the .NET framework), which makes running it
on RISC-V quite difficult.

Goals:

- Share music collection from a local directory.
- Run on server as daemon.
- Support RISC-V and other architectures.
- Be minimal: a tiny codebase, small memory footprint, low resource
  consumption.

Non-goals:

- Make a full-featured Sousleek client.
- Having GUI (maybe I'll implement an optional web UI in the future).

Compared to slskd on x86_64 Linux in idle state (connected to network)
with 5700 files served:

| App | Binary size | CPU% | Memory usage |
| --- | --- | --- | --- |
| miniseekd | 2.5 MiB (static musl) | ~ 0.0 | ~ 21.1 MiB |
| slskd | 113 MiB (dynamic musl) | ~ 1.0 | ~ 250 MiB |

## Features

- Sharing directories from local filesystem with filtering files by regexp.
- Optional periodic shares rescan.
- Uploads limits (number of concurrent uploads, max speed, queue size).
- Live configuration reloading and shares rescan by sending SIGHUP to the
  daemon.
- Logging (to file and/or to console).

## Limitations

- The daemon only uploads. It does not download files, chat, join rooms or
  search on behalf of a user.
- It acts as a leaf in the distributed network: it accepts no child connections
  and forwards no search requests.
- File attributes (bitrate, length) are not [yet] reported in search or browse
  results.

## Building

Install the [V compiler](https://vlang.io) first.

To get unoptimized development build just run:

```sh
v .
```

Optimized production build:

```sh
v -prod .
```

make.vsh script is used for release builds. It cross-compiles program for
many targets using prebuilt toolchains. Linux builds is statically linked
with musl libc.

Look at [Releases](https://github.com/gechandesu/miniseekd/releases) page for
prebuilt binaries for your platform.

```sh
./make.vsh all # build program for all targets
```

See `./make.vsh --tasks` for all available options.

## Docker

TBD.

## Configuration

See [config.example.toml](config.example.toml) for example configuration. Copy
and modify it. Parameter names are explicit.

The paths in `daemon.pid-file` and `logging.file` may be relative; they are
resolved against the working directory at startup. `shares.directories` must
be absolute.

Instead of pasting username and password into configuration file you can pass
it via environment variables:

| Variable | Meaning |
| --- | --- |
| `SLSK_USERNAME` | Soulseek account username |
| `SLSK_PASSWORD` | Soulseek account password |
| `SLSK_PASSWORD_FILE` | Path to file that contains the password, trailing newline stripped |

## Running

Foreground, logging to the console and to the file configured in `config.toml`:

```sh
miniseekd --config config.toml
```

Background daemon:

```sh
miniseekd --config config.toml --daemon --pid-file /run/miniseekd.pid
```

Also you can use systemd unit, see [miniseekd.service](miniseekd.service)
example file.

## Signals

| Signal | Effect |
| --- | --- |
| `SIGTERM`, `SIGINT` | Stop: disconnect from the server and the distributed network, let running uploads finish for up to about 10 seconds, then exit. |
| `SIGHUP` | Reload: reopen the log file, re-read the configuration file, apply new share and queue settings, and rescan the shares. A configuration that fails to load is logged and the old one is kept. |

Changes to the listen address, port, server, or credentials take effect only
after a restart.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Normal stop (`SIGTERM` or `SIGINT`). |
| `1` | Fatal runtime error: rejected credentials, listen port unavailable, initial share scan failure, or the account logged in elsewhere. Details are in the log. |
| `2` | Command-line or configuration error, including an unreadable config file or a missing log path with `--daemon`. |

## License

SPDX License ID: `Unlicense`
