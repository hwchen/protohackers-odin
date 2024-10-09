package means

import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:runtime"
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

	log.infof("Server started, listening on %v on %d threads", endpoint, THREAD_COUNT)

	for {
		conn, source, cerr := net.accept_tcp(listener)
		if cerr != nil do log.error(cerr)

		state := new(ConnState)
		state.conn = conn
		state.source = source
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
				handle_conn(state.conn, state.source)
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
}

handle_conn :: proc(conn: net.TCP_Socket, source: net.Endpoint) {
	src := net.endpoint_to_string(source)
	log.infof("Connection accepted from %v", src)
	defer {
		net.close(conn)
		log.infof("Connection terminated from %v", src)
	}

	// store prices w/ timestamp.
	prices := make([dynamic]Price)

	buf: [4096 * 1000]u8 // enough to handle an entire transaction; not streamed by line
	read_len := 0
	for {
		// Read. Continue reading if we don't end on a message boundary
		// Each message is 9 bytes
		n_bytes, rerr := net.recv_tcp(conn, buf[read_len:])
		if rerr != nil do log.error(rerr)
		read_len += n_bytes
		if read_len % 9 != 0 do continue

		// handle messages (chunks of 9 bytes)
		for i := 0; i < read_len; i += 9 {
			msg := transmute(^Message)raw_data(buf[i:i + 9])
			switch msg.type {
			case 'I':
				log.infof("Insert: %d %d", msg.a, msg.b)
				append(&prices, Price{timestamp = msg.a, amount = msg.b})
			case 'Q':
				log.infof("Query: %d %d", msg.a, msg.b)
				count: i64 = 0
				total: i64 = 0
				for price in prices {
					if msg.a <= price.timestamp && price.timestamp <= msg.b {
						count += 1
						total += i64(price.amount)
					}
				}
				log.infof("Calculate mean %d / %d", total, count)
				mean: i64 = 0
				if count != 0 do mean = total / count
				resp := transmute([4]u8)i32be(mean)
				log.infof("Resp: %d", mean)
				_, werr := net.send_tcp(conn, resp[:])
				if werr != nil do log.error(werr)
			case:
				// undefined behavior, just skip to next msg
				continue
			}
		}
		read_len = 0
	}
}

Message :: struct #packed {
	type: u8,
	a:    i32be,
	b:    i32be,
}

Price :: struct {
	amount:    i32be,
	timestamp: i32be,
}
