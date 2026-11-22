module proto

// Message codes of the Soulseek protocol.
// Server and peer messages use a u32 code; peer-init and distributed messages use a u8 code.

// --- server messages ---
pub const srv_login = u32(1)
pub const srv_set_wait_port = u32(2)
pub const srv_get_peer_address = u32(3)
pub const srv_get_user_status = u32(7)
pub const srv_connect_to_peer = u32(18)
pub const srv_set_status = u32(28)
pub const srv_ping = u32(32)
pub const srv_shared_folders_files = u32(35)
pub const srv_relogged = u32(41)
pub const srv_privileged_users = u32(69)
pub const srv_have_no_parent = u32(71)
pub const srv_parent_min_speed = u32(83)
pub const srv_parent_speed_ratio = u32(84)
pub const srv_accept_children = u32(100)
pub const srv_possible_parents = u32(102)
pub const srv_wishlist_interval = u32(104)
pub const srv_branch_level = u32(126)
pub const srv_branch_root = u32(127)
pub const srv_reset_distributed = u32(130)
pub const srv_send_upload_speed = u32(121)
pub const srv_embedded_message = u32(93)
pub const srv_file_search = u32(26)
pub const srv_cant_connect_to_peer = u32(1001)

// --- peer messages (u32 code) ---
pub const peer_shared_file_list_request = u32(4)
pub const peer_shared_file_list_response = u32(5)
pub const peer_file_search_response = u32(9)
pub const peer_user_info_request = u32(15)
pub const peer_user_info_response = u32(16)
pub const peer_folder_contents_request = u32(36)
pub const peer_folder_contents_response = u32(37)
pub const peer_transfer_request = u32(40)
pub const peer_transfer_response = u32(41)
pub const peer_queue_upload = u32(43)
pub const peer_place_in_queue_response = u32(44)
pub const peer_upload_failed = u32(46)
pub const peer_upload_denied = u32(50)
pub const peer_place_in_queue_request = u32(51)

// --- peer init messages (u8 code) ---
pub const init_pierce_firewall = u8(0)
pub const init_peer_init = u8(1)

// --- distributed messages (u8 code) ---
pub const dist_ping = u8(0)
pub const dist_search = u8(3)
pub const dist_branch_level = u8(4)
pub const dist_branch_root = u8(5)
pub const dist_child_depth = u8(7)
pub const dist_embedded = u8(93)

// --- connection types used in PeerInit / ConnectToPeer ---
pub const conn_peer = 'P'
pub const conn_file = 'F'
pub const conn_distributed = 'D'

// Transfer directions as used in TransferRequest.
pub const dir_download = u32(0) // the sender wants the file to be sent to it
pub const dir_upload = u32(1) // the sender offers to upload the file

// User status values for SetStatus.
pub const status_offline = u32(0)
pub const status_away = u32(1)
pub const status_online = u32(2)

// Protocol version numbers sent in the login message.
pub const login_version = u32(160)
pub const login_minor_version = u32(760)
