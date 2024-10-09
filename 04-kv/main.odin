package kv

import "core:bytes"
import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:runtime"
import "core:slice"
import "core:strings"
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

	kv_store := make(map[string]string)
	kv_store["version"] = "0.0.1"

	log.infof("Server started, listening on %s", net.endpoint_to_string(endpoint))

	sock, merr := net.make_bound_udp_socket(endpoint.address, endpoint.port)
	if merr != nil do log.error(merr)
	defer net.close(sock)
	buf: [1000]u8
	for {
		n_bytes, remote, rerr := net.recv_udp(sock, buf[:])
		if rerr != nil do log.error(rerr)
		msg := buf[:n_bytes]
		log.infof("%s: received %s", net.endpoint_to_string(remote), msg)
		if i := bytes.index(msg, {'='}); i == -1 {
			// no =, retrieve
			v := kv_store[transmute(string)msg]
			resp := fmt.tprintf("%s=%s", msg, v)
			log.infof("%s: retrieving %s", net.endpoint_to_string(remote), resp)
			_, serr := net.send_udp(sock, transmute([]u8)resp, remote)
		} else {
			// insert
			k, v := slice.split_at(msg, i)
			v = v[1:]
			if transmute(string)k == "version" do continue
			log.infof("%s: inserting %s = %s", net.endpoint_to_string(remote), k, v)
			kv_store[strings.clone_from_bytes(k)] = strings.clone_from_bytes(v)
		}

	}
}
