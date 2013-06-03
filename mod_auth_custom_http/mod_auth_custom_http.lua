-- Prosody IM
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local log = require "util.logger".init("auth_custom_http");
local new_sasl = require "util.sasl".new;
local nodeprep = require "util.encodings".stringprep.nodeprep;

local provider = {};

function provider.test_password(username, password)
	return nil, "Not supported"
end

function provider.get_password(username)
	return nil, "Not supported"
end

function provider.set_password(username, password)
	return nil, "Not supported"
end

function provider.user_exists(username)
	return true;
end

function provider.create_user(username, password)
	return nil, "Not supported"
end

function provider.delete_user(username)
	return nil, "Not supported"
end

function provider.get_sasl_handler()
	local getpass_authentication_profile = {
		plain_test = function(sasl, username, password, realm)
			local postdata = require "util.json".encode({ username = username, password = password });
			local result = require "socket.http".request("http://example.com/path", postdata);
			return result == "true", true;
		end,
	};
	return new_sasl(module.host, getpass_authentication_profile);
end
	

module:provides("auth", provider);

