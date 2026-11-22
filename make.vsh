#!/usr/bin/env v

import build
import net.http
import net.urllib
import os
import v.vmod

const manifest = vmod.decode(@VMOD_FILE)!
const build_dir = '.'
const build_endpoint = '.'
const toolchains_dir = '.toolchains'
const dist_dir = 'dist'

const mingw_cross_tag = '20260823'
const musl_cross_tag = '20261001'
const toolchain_urls = {
	'linux/amd64':   'https://github.com/cross-tools/musl-cross/releases/download/${musl_cross_tag}/x86_64-unknown-linux-musl.tar.xz'
	'linux/arm64':   'https://github.com/cross-tools/musl-cross/releases/download/${musl_cross_tag}/aarch64-unknown-linux-musl.tar.xz'
	'linux/arm32':   'https://github.com/cross-tools/musl-cross/releases/download/${musl_cross_tag}/armv7-unknown-linux-musleabihf.tar.xz'
	'linux/riscv64': 'https://github.com/cross-tools/musl-cross/releases/download/${musl_cross_tag}/riscv64-unknown-linux-musl.tar.xz'
	'windows/amd64': 'https://github.com/cross-tools/mingw-cross/releases/download/${mingw_cross_tag}/x86_64-w64-mingw32.tar.xz'
}
const target_to_tuple = {
	'linux/amd64':   'x86_64-unknown-linux-musl'
	'linux/arm64':   'aarch64-unknown-linux-musl'
	'linux/arm32':   'armv7-unknown-linux-musleabihf'
	'linux/riscv64': 'riscv64-unknown-linux-musl'
	'windows/amd64': 'x86_64-w64-mingw32'
}

fn archive_path_from_url(url string, path_prefix string) string {
	return os.join_path_single(path_prefix, os.file_name(urllib.parse(url) or {
		panic('bad URL: ${url}')
	}.path))
}

fn download(url string, dest_path string) ! {
	os.mkdir_all(os.dir(dest_path))!
	_ := http.download_file_with_progress(url, dest_path)!
}

fn join_comm(words []string) string {
	mut comm := []string{}
	for w in words {
		if w.contains(' ') {
			comm << ("'" + w + "'")
		} else {
			comm << w
		}
	}
	return comm.join(' ')
}

fn run_comm(cmd ...string) ! {
	println('Run: ' + join_comm(cmd))
	_ := os.exec_opt(cmd)!
}

fn select_cross_compiler(target string) string {
	tuple := target_to_tuple[target] or { panic('unmatched target') }
	return os.join_path(toolchains_dir, tuple, 'bin', tuple + '-gcc')
}

fn build_build_artifact_path(build_dir string, target string, progname string, progver string) string {
	target_os, target_arch := target.split_once('/') or { panic('invalid target spec: ${target}') }
	ext := if target_os == 'windows' { '.exe' } else { '' }
	return os.norm_path(os.join_path_single(build_dir, '${progname}-${progver}-${target_os}-${target_arch}${ext}'))
}

fn run_compiler(target string, vflags []string) ! {
	mut proc := os.new_process('v')
	mut argv := vflags.clone()
	target_os, target_arch := target.split_once('/') or { panic('invalid target spec: ${target}') }
	argv << ['-os', target_os, '-arch', target_arch]
	argv << ['-cc', select_cross_compiler(target)]
	argv << build_endpoint
	println('Run: ' + join_comm(['v', ...argv]))
	proc.set_args(argv)
	proc.run()
	proc.wait()
	if proc.status == .exited && proc.code != 0 {
		return error('')
	}
}

mut ctx := build.context()

mut toolchain_archives := []string{}
mut toolchain_dirs := []string{}
mut build_artifacts := []string{}

for target, url in toolchain_urls {
	target_upper := target.to_upper_ascii()
	toolchain_archive_path := archive_path_from_url(url, toolchains_dir)
	toolchain_archives << toolchain_archive_path
	toolchain_dir_path := toolchain_archive_path.all_before('.tar.xz')
	toolchain_dirs << toolchain_dir_path
	build_artifact_path := build_build_artifact_path(build_dir, target, manifest.name, manifest.version)
	build_artifacts << build_artifact_path

	ctx.artifact(
		name: toolchain_archive_path
		help: 'Download ${target_upper} toolchain'
		run:  fn [url] (self build.Task) ! { download(url, self.name)! }
	)
	ctx.artifact(
		name:    toolchain_dir_path
		help:    'Extract ${target_upper} toolchain files'
		run:     fn [toolchain_archive_path] (_ build.Task) ! {
			run_comm('tar', '-C', toolchains_dir, '-xf', toolchain_archive_path)!
		}
		depends: [toolchain_archive_path]
	)
	ctx.task(
		name:    '${target}-toolchain'
		help:    'Download and extract toolchain for ${target_upper} target'
		run:     |_| {  }
		depends: [toolchain_dir_path]
	)
	ctx.artifact(
		name:    build_artifact_path
		help:    'Build program for ${target_upper}'
		run:     fn [target] (self build.Task) ! {
			os.mkdir_all(os.dir(self.name))!
			run_compiler(target, ['-prod', '-cflags', '-static -s', '-o', self.name])!
		}
		depends: [toolchain_dir_path]
	)
	ctx.task(
		name:    target
		help:    'Build program for ${target_upper}'
		run:     |_| {  }
		depends: [build_artifact_path]
	)
}

ctx.task(
	name: 'list-targets'
	help: 'Print all build targets'
	run:  fn (_ build.Task) ! {
		for t in toolchain_urls.keys() { println(t) }
	}
)

ctx.task(
	name:    'download-toolchains'
	help:    'Download all toolchains'
	run:     |_| {  }
	depends: toolchain_archives
)

ctx.task(
	name:    'all-toolchains'
	help:    'Download and extract all toolchains'
	run:     |_| {  }
	depends: toolchain_dirs
)

ctx.task(
	name:    'all'
	help:    'Build program for all targets'
	run:     |_| {  }
	depends: build_artifacts
)

ctx.task(
	name: 'dist'
	help: 'Make directory layout for Dockerfile.release build'
	run:  fn (_ build.Task) ! {
		progname := manifest.name
		for binary in os.glob('${progname}-*-linux-*') or { [] } {
			arch := binary.all_after_last('-linux-')
			platform := if arch == 'arm32' { 'linux/arm/v7' } else { 'linux/${arch}' }
			target_dir := os.join_path(dist_dir, platform)
			target_path := os.join_path(target_dir, progname)
			os.mkdir_all(target_dir)!
			os.cp(binary, target_path)!
		}
	}
)

ctx.task(
	name: 'clean'
	help: 'Remove build artifacts'
	run:  fn [build_artifacts] (_ build.Task) ! {
		run_comm('v', 'clean')!
		mut existed := true
		for artifact in build_artifacts {
			os.rm(artifact) or {
				if os.is_not_exist(err) {
					existed = false
				} else {
					eprintln('Error deleting ${artifact}: ${err}')
				}
			}
			if existed {
				println('Deleted: ${artifact}')
			}
		}
		existed = true
		os.rmdir_all(dist_dir) or {
			if os.is_not_exist(err) {
				existed = false
			}
		}
		if existed {
			println('Deleted: ${dist_dir}/')
		}
	}
)

ctx.run()
