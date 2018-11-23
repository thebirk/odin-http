package http

import "core:os"
import "core:fmt"

VERSION_11 :: "HTTP/1.1";
CRLF :: "\r\n";
CR :: '\r';
LF :: '\n';
SP :: ' ';
HT :: '\t';

MAX_ENTITY_SIZE :: 8192;

Version :: struct {
	major, minor: u8,
}

Method :: enum {
	Invalid,
	OPTIONS,
	GET,
	HEAD,
	POST,
	PUT,
	DELETE,
	TRACE,
	CONNECT,
}

URI :: struct {
	//flesh out
	uri: string,
}

Request :: struct {
	method: Method,
	uri: URI,
	version: Version,
	headers: map[string]string,
	body: [dynamic]u8,
}

Error :: enum {
	None,
	EntityTooLarge,
	EmptyRequestLine,
	InvalidMethod,
	InvalidVersion,
}

ParserState :: struct {
	stream: os.Handle,
	client_socket: ^zed.Socket,
	current_rune: rune,
	offset: int,
	total_read: int,
}

next_rune :: proc(state: ^ParserState) -> Error {
	//TODO: utf8
	when false {
		buffer: [1]u8;
		_, errno := os.read(state.stream, buffer[:]);
		fmt.printf("os.read ernno: %d\n", errno);
	} else {
		buffer: [1]u8;
		zed.tcp_socket_receive(state.client_socket, &buffer[0], 1);
	}

	state.current_rune = rune(buffer[0]);
	state.total_read += 1;

	if state.total_read >= MAX_ENTITY_SIZE do return Error.EntityTooLarge;
	return Error.None;
}

read_line :: proc(using state: ^ParserState) -> (string, Error) {
	buffer: [dynamic]u8;
	prev_char := rune(0);
	err := next_rune(state);
	for {
		if prev_char == CR && current_rune == LF {
			return string(buffer[:]), err;
		}
		if prev_char != 0 do append(&buffer, u8(prev_char));
		prev_char = current_rune;
		err = next_rune(state);
	}

	return "", Error.EntityTooLarge;
}

init_state :: proc(using state: ^ParserState, stream_handle: os.Handle, socket: ^zed.Socket) -> Error {
	stream = stream_handle;
	client_socket = socket;
	//next_rune(state);
	return Error.None;
}

// returns false if we are at the end of the line
skip_sp :: proc(line: string, offset: ^int) -> bool {
	if offset^ >= len(line) do return false;
	for line[offset^] == SP {
		offset^ += 1;
		if offset^ >= len(line) do return false;
	}
	return true;
}

read_word :: proc(line: string, offset: ^int) -> string {
	start := offset^;
	for line[offset^] != SP {
		offset^ += 1;
		if offset^ >= len(line) do return string(line[start:offset^]);
	}
	return string(line[start:offset^]);
}

validate_method_str :: proc(str: string) -> Method {
	switch str {
		case "OPTIONS": return Method.OPTIONS;
		case "GET":     return Method.GET;
		case "HEAD":    return Method.HEAD;
		case "POST":    return Method.POST;
		case "PUT":     return Method.PUT;
		case "DELETE":  return Method.DELETE;
		case "TRACE":   return Method.TRACE;
		case "CONNECT": return Method.CONNECT;
	
		case: return Method.Invalid;
	}
}

_parse_int :: proc(s: string, offset: int) -> (result: int, new_offset: int, ok: bool) {
	// Grabbed from core:fmt
	is_digit :: inline proc(r: byte) -> bool { return '0' <= r && r <= '9' }

	new_offset = offset;
	for new_offset < len(s) {
		c := s[new_offset];
		if !is_digit(c) do break;
		new_offset += 1;

		result *= 10;
		result += int(c)-'0';
	}
	ok = new_offset > offset;
	return;
}

parse_version :: proc(str: string) -> (Version, Error) {
	result: Version;

	min_len := 8; // HTTP/1*n.1*n
	if len(str) < min_len do return result, Error.InvalidVersion;

	http_part := str[:5];
	if http_part != "HTTP/" do return result, Error.InvalidVersion;

	version_part := str[5:];

	major, offset, ok := _parse_int(version_part, 0);
	if !ok do return result, Error.InvalidVersion;
	if major < 0 || major > 255 do return result, Error.InvalidVersion;

	if version_part[offset] != '.' do return result, Error.InvalidVersion;
	offset += 1;

	minor: int;
	minor, offset, ok = _parse_int(version_part, offset);
	if !ok do return result, Error.InvalidVersion;
	if minor < 0 || minor > 255 do return result, Error.InvalidVersion;

	result.major = u8(major);
	result.minor = u8(minor);

	return result, Error.None;
}

parse_request_line :: proc(r: ^Request, state: ^ParserState) -> Error {
	line, err := read_line(state);
	//TODO: defer delete(line), and allocate seperate strings for all the props
	if err != Error.None do return err;

	//TODO: RFC 2616 recommends for robustness sake to ignore CRLFs sent before the Request-Line (Section 4.1)
	if line == "" do return Error.EmptyRequestLine;

	fmt.printf("line: '%s'\n", line);

	offset := 0;
	method_str := read_word(line, &offset);
	fmt.printf("method_str: '%s'\n", method_str);
	
	method := validate_method_str(method_str);
	fmt.printf("method: %v\n", method);
	if method == Method.Invalid {
		return Error.InvalidMethod;
	}
	r.method = method;

	if !skip_sp(line, &offset) {
		// handle error
		assert(false);
	}

	uri_str := read_word(line, &offset);
	fmt.printf("url: '%s'\n", uri_str);
	r.uri = URI{uri_str};

	if !skip_sp(line, &offset) {
		// handle error
		assert(false);
	}

	version_str := read_word(line, &offset);
	version, error := parse_version(version_str);
	if error != Error.None do return error;
	r.version = version;

	return Error.None;
}

parse_request :: proc(stream: os.Handle, socket: ^zed.Socket) -> (Request, Error) {
	result := Request{};
	state: ParserState;
	init_state(&state, stream, socket);

	fmt.printf("Parsing request line\n");

	error := parse_request_line(&result, &state);
	// send a bad request and terminate the connection, once we get to the connection part
	// Perhaps a 'Not Implemented' message would be better as the method could be an extension. Error.InvalidMethod specific?
	if error != Error.None do return result, error;

	fmt.printf("Parsed request\n");

	// parser_headers
	line: string = "";
	line, error = read_line(&state);
	if error != Error.None do return result, error;
	for line != "" {
		//TODO: Handle Header continuation RFC 2616 Sec. 2.2 - LWS
		fmt.printf("header: '%s'\n", line);
		offset := 0;
		for line[offset] != ':' {
			//TODO: Handle never finding a colon
			offset += 1;
		}

		header_name := line[:offset];
		//TODO: strip SPs
		header_part := line[offset+1:];
		result.headers[header_name] = header_part;

		line, error = read_line(&state);
		if error != Error.None do return result, error;
	}

	// check content-length and parse content

	return result, error;
}

import zed "shared:zed_net"
main :: proc() {
	if zed.init() != 0 {
		fmt.printf("zed_net error: '%s'\n", zed.get_error());
		return;
	}
	defer zed.shutdown();

	listen_socket: zed.Socket;
	zed.tcp_socket_open(&listen_socket, 4040, 0, 1);

	client_socket: zed.Socket;
	client_addr: zed.Address;
	for zed.tcp_accept(&listen_socket, &client_socket, &client_addr) == 0 {
		fmt.printf("Accepted! client address: '%s'\n", zed.host_to_str(client_addr.host));
		req, err := parse_request(os.Handle(client_socket.handle), &client_socket);
		fmt.printf("err: %v\n", err);
		fmt.printf("req: %#v\n", req);

		response := "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 13\r\n\r\nHello, world!asdasdasd";
		zed.tcp_socket_send(&client_socket, &response[0], i32(len(response)));

		zed.socket_close(&client_socket);
	}

	/*example, errno := os.open("request_example.txt", os.O_RDONLY);
	assert(errno == os.ERROR_NONE);*/

	
}

/*
General headers
===============

Cache-Control
Connection
Date
Pragma
Trailer
Transfer-Encoding
Upgrade
Via
Warning
*/

/*
Request methods
===============

OPTIONS
GET
HEAD
POST
PUT
DELETE
TRACE
CONNECt

Request headers
===============

Accept
Accept-Charset
Accept-Encoding
Accept-Language
Authorization
Expect
From
Host - required in HTTP/1.1
If-Match
If-Modified-Since
If-None-Match
If-Range
If-Unmodified-Since
Max-Forwards
Proxy-Authorization
Range
Referer
TE
User-Agent
*/

/*
Response header
===============

Accept-Ranges
Age
ETag
Location
Proxy-Authenticate
Retry-After
Server
Vary
WWW-Authenticate
*/

/*
Entity header
=============

Allow
Content-Encoding
Content-Language
Content-Length
Content-Location
Content-MD5
Content-Range
Content-Type
Expires
Last-Modified

*/