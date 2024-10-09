package chat

import "base:runtime"
import "core:bytes"
import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"

THREAD_COUNT :: 128

main :: proc() {
	context.logger = log.create_console_logger(.Info)
	defer log.destroy_console_logger(context.logger)

	if len(os.args) != 2 {
		fmt.eprintln("Please pass only address:port as arg")
		os.exit(1)
	}

	endpoint, eok := net.parse_endpoint(os.args[1])
	if !eok {
		fmt.eprintln("Error parsing endpoint")
		os.exit(1)
	}

	listener, lerr := net.listen_tcp(endpoint)
	if lerr != nil {
		fmt.eprintln("Error setting up tcp listener", lerr)
		os.exit(1)
	}

	pool: thread.Pool
	thread.pool_init(&pool, context.allocator, THREAD_COUNT)
	defer thread.pool_destroy(&pool)
	thread.pool_start(&pool)

	chat: Chat

	log.infof("Server started, listening on %v on %d threads", endpoint, THREAD_COUNT)

	for {
		conn, source, cerr := net.accept_tcp(listener)
		if cerr != nil do log.error(cerr)

		state := new(ConnState)
		state.conn = conn
		state.source = source
		state.chat = &chat
		thread.pool_add_task(
			&pool,
			context.allocator,
			proc(t: thread.Task) {
				// Looks like logging is not thread-safe, but this is good enough for now.
				// https://github.com/odin-lang/Odin/blob/35857d3103b65020ce486571506aa69f53ad9a1a/core/log/file_console_logger.odin#L97-L98
				context = runtime.default_context()
				context.logger = log.create_console_logger(.Info)
				defer log.destroy_console_logger(context.logger)

				state := cast(^ConnState)t.data
				handle_conn(state.conn, state.source, state.chat)
			},
			rawptr(state),
		)
		// not needed, but cleans up the dynamic array tracking done tasks
		// will work better w/out tracking: https://github.com/odin-lang/Odin/pull/2668
		thread.pool_pop_done(&pool)
	}
}

ConnState :: struct {
	conn:   net.TCP_Socket,
	source: net.Endpoint,
	chat:   ^Chat,
}

handle_conn :: proc(conn: net.TCP_Socket, source: net.Endpoint, chat: ^Chat) {
	// Defined in Initialization section
	client_id: u64
	name: string

	src := net.endpoint_to_string(source)
	log.infof("%s Connected", src)
	defer {
		net.close(conn)
		log.infof("%s Terminated", src)
		// Announce disconnect to other clients
		sync.mutex_lock(&chat.mutex)
		client_idx, ok := chat_find_client(chat, client_id)
		if ok {
			unordered_remove(&chat.clients, client_idx)
			disconnect_str := fmt.aprintf("* %s has left the room", name)
			chat_broadcast_sys(chat, client_id, disconnect_str)
		} else {
			log.infof("client id %d not removed; probably not joined yet", client_id)
		}
		sync.mutex_unlock(&chat.mutex)
	}

	// Initialization
	log.infof("%s Welcome", src)
	send_user(conn, "welcome, name?")
	log.infof("%s Get name and validate", src)
	name_buf: [16]u8
	n_bytes, rerr := net.recv_tcp(conn, name_buf[:])
	if rerr != nil do log.error(rerr)
	if n_bytes == 0 {
		log.errorf("No bytes read for %s", src)
		return
	}
	name = fmt.aprintf("%s", name_buf[:n_bytes - 1])
	for c in name {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9':
			{}
		case:
			return
		}
	}
	log.infof("%s: Join action, acquire lock", name)
	sync.mutex_lock(&chat.mutex)
	client := Client {
		id   = chat_next_id(chat),
		name = name,
		conn = conn,
	}
	client_id = client.id // Set id for local use
	log.infof("%d %s: Room list", client_id, name)
	roomlist: strings.Builder
	fmt.sbprintf(&roomlist, "* room contains: ")
	for client in chat.clients {
		fmt.sbprintf(&roomlist, "%s", client.name)
	}
	send_user(conn, strings.to_string(roomlist))
	log.infof("%d %s: Announce presence", client_id, name)
	announce := fmt.tprintf("* %s has entered the room", name)
	chat_broadcast_sys(chat, client_id, announce)
	append(&chat.clients, client)
	sync.mutex_unlock(&chat.mutex)

	// Handling normal messages
	buf: [4096 * 1000]u8 // enough to handle an entire transaction; not streamed by line
	read_len := 0
	for {
		// Read. Continue reading if we don't end on a message boundary \n
		n_bytes, rerr := net.recv_tcp(conn, buf[read_len:])
		if rerr != nil do log.error(rerr)
		if n_bytes == 0 do break
		read_len += n_bytes
		if buf[read_len - 1] != '\n' do continue
		log.infof("%d %s: Received messages", client_id, name)

		// handle each message (line)
		lines := buf[:read_len]
		for line in bytes.split_iterator(&lines, {'\n'}) {
			log.infof("%d %s: Broadcasting message", client_id, name)
			sync.mutex_lock(&chat.mutex)
			chat_broadcast_user(chat, client_id, name, transmute(string)line)
			sync.mutex_unlock(&chat.mutex)
		}
		read_len = 0
	}
}

chat_broadcast_sys :: proc(chat: ^Chat, from: u64, msg: string) {
	log.infof("%d: Broadcasting sys: %s", from, msg)
	for client in chat.clients {
		if client.id != from {
			_, err1 := net.send_tcp(client.conn, transmute([]u8)msg)
			if err1 != nil do log.errorf("Error: sending to %d %v", client.id, err1)
			_, err2 := net.send_tcp(client.conn, {'\n'})
			if err2 != nil do log.errorf("Error: sending to %d %v", client.id, err2)
		}
	}
}

chat_broadcast_user :: proc(chat: ^Chat, from: u64, name: string, msg: string) {
	m := fmt.tprintf("[%s] %s \n", name, msg)
	log.infof("%d: Broadcasting user: %s", from, m)
	for client in chat.clients {
		if client.id != from {
			_, err := net.send_tcp(client.conn, transmute([]u8)m)
			if err != nil do log.error(err)
		}
	}
}

send_user :: proc(conn: net.TCP_Socket, msg: string) {
	_, err1 := net.send_tcp(conn, transmute([]u8)msg)
	if err1 != nil do log.error(err1)
	_, err2 := net.send_tcp(conn, {'\n'})
	if err2 != nil do log.error(err2)
}

// Factored out to make sure there's no way to forget the +=1
chat_next_id :: proc(chat: ^Chat) -> u64 {
	chat.next_id += 1
	return chat.next_id
}

chat_find_client :: proc(chat: ^Chat, client_id: u64) -> (index: int, found: bool) {
	for client, i in chat.clients {
		if client.id == client_id {
			return i, true
		}
	}
	return -1, false
}

Chat :: struct {
	clients: [dynamic]Client,
	mutex:   sync.Mutex,
	next_id: u64,
}

Client :: struct {
	id:   u64,
	name: string,
	conn: net.TCP_Socket,
}
