-- mod_candy.lua
-- Copyright (C) 2013 Kim Alvefur
--
-- Run this in www_files
-- curl -L http://github.com/candy-chat/candy/tarball/master | tar xzfv - --strip-components=1

local json_encode = require"util.json".encode;

local serve = module:depends"http_files".serve;

module:provides("http", {
	route = {
		["GET /prosody.js"] = function(event)
			event.response.headers.content_type = "text/javascript";
			return ("// Generated by Prosody\n"
				.."var Prosody = %s;\n")
					:format(json_encode({
						bosh_path = module:http_url("bosh","/http-bind");
						version = prosody.version;
						host = module:get_host();
						anonymous = module:get_option_string("authentication") == "anonymous";
					}));
		end;
		["GET /*"] = serve(module:get_directory().."/www_files");
	}
});

