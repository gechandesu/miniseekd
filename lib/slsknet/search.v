module slsknet

import lib.proto
import lib.shares

const max_search_responses_inflight = 8

// handle_search answers a search request (from the server or the distributed network).
fn (mut c Client) handle_search(username string, token u32, query string) {
	if username == c.username() {
		return
	}
	key := '${username}:${token}'
	c.mu.lock()
	if key in c.search_seen {
		c.mu.unlock()
		return
	}
	if c.search_seen.len > 5000 {
		c.search_seen = map[string]bool{}
	}
	c.search_seen[key] = true
	busy := c.search_inflight >= max_search_responses_inflight
	c.mu.unlock()
	if busy {
		return
	}
	idx := c.store.current()
	if idx.file_count() == 0 {
		return
	}
	files := idx.search(query, shares.max_search_results)
	if files.len == 0 {
		return
	}
	c.log.debug('search from ${username} for "${query}": ${files.len} results')
	c.mu.lock()
	c.search_inflight++
	c.mu.unlock()
	spawn c.send_search_response(username, token, files)
}

fn (mut c Client) send_search_response(username string, token u32, files []proto.FileEntry) {
	defer {
		c.mu.lock()
		c.search_inflight--
		c.mu.unlock()
	}
	c.mu.lock()
	active := c.active_uploads
	speed := c.avg_speed
	c.mu.unlock()
	data := proto.encode_file_search_response(proto.SearchResponse{
		username:  c.username()
		token:     token
		files:     files
		slot_free: active < c.cfg.transfers.upload.slots
		avg_speed: speed
		queue_len: u32(c.queue.len())
	}) or {
		c.log.debug('cannot encode search response: ${err}')
		return
	}
	mut conn := c.get_peer_conn(username) or {
		c.log.debug('cannot deliver search results to ${username}: ${err}')
		return
	}
	conn.send(data) or {
		c.log.debug('cannot send search results to ${username}: ${err}')
		return
	}
	c.log.debug('sent ${files.len} search results to ${username}')
}
