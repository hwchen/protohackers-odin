package prime_time

import "core:bytes"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:math/big"
import "core:net"
import "core:os"
import "core:runtime"
import "core:slice"
import "core:strconv"
import "core:testing"
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

	log.infof(
		"Server started, listening on %s on %d threads",
		net.endpoint_to_string(endpoint),
		THREAD_COUNT,
	)

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
	log.infof("Connection accepted from %s", src)
	defer {
		net.close(conn)
		log.infof("Connection terminated from %s", src)
		free_all(context.temp_allocator)
	}

	// make buffer big enough to handle entire request at once, don't worry about streaming lines
	buf: [4096 * 10]u8
	resp_len := 0
	for {
		n_bytes, rerr := net.recv_tcp(conn, buf[resp_len:])
		if rerr != nil do log.error(rerr)
		if n_bytes == 0 do break
		resp_len += n_bytes
		// continue reading if it's not the end of the request
		if buf[resp_len - 1] != '\n' do continue

		lines := buf[:resp_len]
		for line in bytes.split_iterator(&lines, {'\n'}) {
			log.infof("Received request (%d) %s", n_bytes, line)
			num, nerr := extract_num(line)
			switch nerr {
			case .Ok, .Float:
				is_prime := is_prime(num)
				log.infof("Sending resp is_prime=%v to %s", is_prime, src)
				out := fmt.tprint(`{"method":"isPrime","prime":`, is_prime, "}\n")
				_, werr := net.send_tcp(conn, transmute([]u8)out)
				if werr != nil do log.error(werr)
			case .Other:
				log.infof("Sending malformed to %s; %s", src, line)
				_, werr := net.send_tcp(conn, {'{', '}', '\n'})
				if werr != nil do log.error(werr)
				return
			}
		}
		resp_len = 0
	}
}

ExtractError :: enum {
	Ok,
	Float,
	Other,
}

// json parsing odin core is too permissive, it allows strings to be parsed as numbers
// so do this hacky ad-hoc brittle thing;
extract_num :: proc(resp: []u8) -> (num: i64, err: ExtractError) {
	//default error to .Other
	err = .Other

	method_is_prime_str := transmute([]u8)string(`"method":"isPrime"`)
	number_prefix := transmute([]u8)string(`"number"`)

	if resp[0] != '{' || resp[len(resp) - 1] != '}' do return
	resp_trimmed := bytes.trim(resp, {'{', '}'})
	kv_strs := bytes.split(resp_trimmed, {','})
	if len(kv_strs) < 2 do return

	number_kv_str: []u8
	has_is_prime := false
	for kv_str in kv_strs {
		if slice.equal(kv_str, method_is_prime_str) {
			has_is_prime = true
		}
		if bytes.has_prefix(kv_str, number_prefix) {
			number_kv_str = kv_str
		}
	}

	if !has_is_prime do return

	split_num := bytes.split(number_kv_str, {':'})
	number, nok := strconv.parse_i64(transmute(string)split_num[1])
	if !nok {
		_, fok := strconv.parse_f64(transmute(string)split_num[1])
		if fok do err = .Float;return
	}
	num = number
	err = .Ok
	return
}

@(test)
test_extract_num :: proc(t: ^testing.T) {
	{
		_, err := extract_num(transmute([]u8)string(`{"method":"isPrime"}`))
		testing.expect_value(t, err, ExtractError.Other)
	}
	{
		_, err := extract_num(transmute([]u8)string(`{"method":"isPrime",`))
		testing.expect_value(t, err, ExtractError.Other)
	}
	{
		_, err := extract_num(transmute([]u8)string(`{"method":"isPrime","number":"1"}`))
		testing.expect_value(t, err, ExtractError.Other)
	}
	{
		_, err := extract_num(transmute([]u8)string(`{"method":"isPrime","number":1}`))
		testing.expect_value(t, err, ExtractError.Ok)
	}
	{
		_, err := extract_num(
			transmute([]u8)string(`{"method":"isPrime","number":1,"nummar":"zzz"}`),
		)
		testing.expect_value(t, err, ExtractError.Ok)
	}
}

is_prime :: proc(n: i64) -> bool {
	if n <= 1 do return false
	if n == 2 || n == 3 do return true
	if n % 2 == 0 || n % 3 == 0 do return false

	i: i64 = 5
	for ; i * i <= n; i += 6 {
		if n % i == 0 || n % (i + 2) == 0 do return false
	}

	return true
}

@(test)
test_is_prime :: proc(t: ^testing.T) {
	testing.expect_value(t, is_prime(2), true)
	testing.expect_value(t, is_prime(5), true)
	testing.expect_value(t, is_prime(12), false)
}
