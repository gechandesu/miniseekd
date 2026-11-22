module uploads

import time

fn item(user string, remote string) Item {
	return Item{
		username: user
		remote:   remote
		local:    '/x/' + remote
		size:     1
		enqueued: time.now()
	}
}

fn never_busy(_ string) bool {
	return false
}

fn test_fair_round_robin() {
	mut q := new_queue(10)
	assert q.enqueue(item('a', 'a1')) == .added
	assert q.enqueue(item('a', 'a2')) == .added
	assert q.enqueue(item('a', 'a3')) == .added
	assert q.enqueue(item('b', 'b1')) == .added
	assert q.enqueue(item('c', 'c1')) == .added
	assert q.len() == 5
	mut got := []string{}
	for {
		it := q.take(never_busy) or { break }
		got << it.remote
	}
	assert got == ['a1', 'b1', 'c1', 'a2', 'a3']
	assert q.len() == 0
}

fn test_duplicates_and_limit() {
	mut q := new_queue(2)
	assert q.enqueue(item('a', 'f1')) == .added
	assert q.enqueue(item('a', 'f1')) == .already_queued
	assert q.enqueue(item('a', 'f2')) == .added
	assert q.enqueue(item('a', 'f3')) == .user_limit
	assert q.enqueue(item('b', 'f3')) == .added
	assert q.user_len('a') == 2
}

fn test_busy_users_skipped() {
	mut q := new_queue(5)
	q.enqueue(item('a', 'a1'))
	q.enqueue(item('b', 'b1'))
	it := q.take(fn (u string) bool {
		return u == 'a'
	}) or {
		assert false
		return
	}
	assert it.username == 'b'
	// only busy user left
	assert q.take(fn (u string) bool {
		return u == 'a'
	}) == none
	assert q.len() == 1
}

fn test_remove_and_position() {
	mut q := new_queue(5)
	q.enqueue(item('a', 'a1'))
	q.enqueue(item('a', 'a2'))
	q.enqueue(item('b', 'b1'))
	assert q.position('a', 'a1')? == 1
	assert q.position('b', 'b1')? == 2
	assert q.position('a', 'a2')? == 3
	assert q.position('z', 'q') == none
	assert q.remove('a', 'a1')
	assert !q.remove('a', 'a1')
	assert q.position('a', 'a2')? == 1
	assert q.position('b', 'b1')? == 2
	assert q.remove_user('b') == 1
	assert q.len() == 1
	assert q.remove_user('nobody') == 0
}
