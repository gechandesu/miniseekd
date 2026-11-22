module uploads

import sync
import time

// Item is a queued upload request.
pub struct Item {
pub:
	username string
	remote   string // virtual path as requested by the peer
	local    string
	size     u64
	enqueued time.Time
}

// EnqueueError describes why a request was refused.
pub enum EnqueueResult {
	added
	already_queued
	user_limit
}

// Queue is a fair upload queue: items are served round-robin between users, oldest first per user.
@[heap]
pub struct Queue {
mut:
	mu           &sync.Mutex = sync.new_mutex()
	per_user     map[string][]Item
	rotation     []string // users in round-robin order
	max_per_user int = 50
}

pub fn new_queue(max_per_user int) &Queue {
	return &Queue{
		max_per_user: max_per_user
	}
}

// set_limit changes the maximum number of queued files per user.
pub fn (mut q Queue) set_limit(max_per_user int) {
	q.mu.lock()
	q.max_per_user = max_per_user
	q.mu.unlock()
}

// enqueue adds a request. A duplicate (same user and file) is not added twice.
pub fn (mut q Queue) enqueue(it Item) EnqueueResult {
	q.mu.lock()
	defer {
		q.mu.unlock()
	}
	mut list := q.per_user[it.username] or { []Item{} }
	for x in list {
		if x.remote == it.remote {
			return .already_queued
		}
	}
	if list.len >= q.max_per_user {
		return .user_limit
	}
	list << it
	q.per_user[it.username] = list
	if it.username !in q.rotation {
		q.rotation << it.username
	}
	return .added
}

// take returns the next item to serve, skipping users for which `busy` returns true.
// The returned item is removed from the queue.
pub fn (mut q Queue) take(busy fn (string) bool) ?Item {
	q.mu.lock()
	defer {
		q.mu.unlock()
	}
	for i, user in q.rotation {
		if busy(user) {
			continue
		}
		mut list := q.per_user[user] or { continue }
		if list.len == 0 {
			continue
		}
		it := list[0]
		list.delete(0)
		if list.len == 0 {
			q.per_user.delete(user)
			q.rotation.delete(i)
		} else {
			q.per_user[user] = list
			// move the user to the back of the line
			q.rotation.delete(i)
			q.rotation << user
		}
		return it
	}
	return none
}

// remove deletes a queued item; returns true if it existed.
pub fn (mut q Queue) remove(username string, remote string) bool {
	q.mu.lock()
	defer {
		q.mu.unlock()
	}
	mut list := q.per_user[username] or { return false }
	for i, x in list {
		if x.remote == remote {
			list.delete(i)
			if list.len == 0 {
				q.per_user.delete(username)
				idx := q.rotation.index(username)
				if idx >= 0 {
					q.rotation.delete(idx)
				}
			} else {
				q.per_user[username] = list
			}
			return true
		}
	}
	return false
}

// remove_user drops every queued item of a user and returns how many were removed.
pub fn (mut q Queue) remove_user(username string) int {
	q.mu.lock()
	defer {
		q.mu.unlock()
	}
	list := q.per_user[username] or { return 0 }
	q.per_user.delete(username)
	idx := q.rotation.index(username)
	if idx >= 0 {
		q.rotation.delete(idx)
	}
	return list.len
}

// position returns the 1-based position of an item in the order in which items would be served
// (ignoring busy users), or none if it is not queued.
pub fn (mut q Queue) position(username string, remote string) ?int {
	q.mu.lock()
	defer {
		q.mu.unlock()
	}
	// simulate round-robin
	mut cursors := map[string]int{}
	mut order := q.rotation.clone()
	mut pos := 0
	for order.len > 0 {
		mut next_order := []string{}
		for user in order {
			list := q.per_user[user] or { continue }
			c := cursors[user]
			if c >= list.len {
				continue
			}
			pos++
			if user == username && list[c].remote == remote {
				return pos
			}
			cursors[user] = c + 1
			if c + 1 < list.len {
				next_order << user
			}
		}
		order = next_order.clone()
	}
	return none
}

// len returns the total number of queued items.
pub fn (mut q Queue) len() int {
	q.mu.lock()
	defer {
		q.mu.unlock()
	}
	mut n := 0
	for _, l in q.per_user {
		n += l.len
	}
	return n
}

// user_len returns the number of queued items of a user.
pub fn (mut q Queue) user_len(username string) int {
	q.mu.lock()
	defer {
		q.mu.unlock()
	}
	l := q.per_user[username] or { return 0 }
	return l.len
}
