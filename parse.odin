package http

CRLF :: "\r\n";
CR :: '\r';
LF :: '\n';
SP :: ' ';
HT :: '\t';

parse_token :: proc(line: string, offset: int) -> (result: string, new_offset: int) {
	new_offset = offset;
	
	for new_offset < len(line) {
		switch line[new_offset] {
			// Seperators
			case '(', ')', '<', '>', '@', ',', ';', ':', '\\' , '"', '/', '[', ']', '?', '=', '{', '}', SP, HT:
				result = line[offset:new_offset];
				return;
			// CTLs - Control characters
			case 0..31:
				result = line[offset:new_offset];
				return;
		}

		new_offset += 1;
	}

	result = line[offset:new_offset];
	return;
}

skip_sp :: proc(line: string, offset: int) -> (end_of_string: bool, new_offset: int) {
	new_offset = offset;
	if new_offset >= len(line) do return true, new_offset;

	for new_offset < len(line) && line[new_offset] == SP {
		new_offset += 1;
	}

	end_of_string = new_offset >= len(line);
	return;
/*
	if offset^ >= len(line) do return false;
	for line[offset^] == SP {
		offset^ += 1;
		if offset^ >= len(line) do return false;
	}
	return true;*/
}