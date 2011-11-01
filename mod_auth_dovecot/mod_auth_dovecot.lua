-- Dovecot authentication backend for Prosody
--
-- Copyright (C) 2010 Javier Torres
-- Copyright (C) 2010-2011 Matthew Wild
-- Copyright (C) 2010-2011 Waqas Hussain
-- Copyright (C) 2011 Kim Alvefur
--

pcall(require, "socket.unix");
local datamanager = require "util.datamanager";
local usermanager = require "core.usermanager";
local log = require "util.logger".init("auth_dovecot");
local new_sasl = require "util.sasl".new;
local nodeprep = require "util.encodings".stringprep.nodeprep;
local base64 = require "util.encodings".base64;
local sha1 = require "util.hashes".sha1;

local prosody = prosody;
local socket_path = module:get_option_string("dovecot_auth_socket", "/var/run/dovecot/auth-login");
local socket_host = module:get_option_string("dovecot_auth_host", "127.0.0.1");
local socket_port = module:get_option_string("dovecot_auth_port");
local append_host = module:get_option_boolean("auth_append_host", false);
if not socket_port and not socket.unix then
	error("LuaSocket was not compiled with UNIX socket support. Try using Dovecot 2.x with inet_listener support, or recompile LuaSocket with UNIX socket support.");
end

function new_provider(host)
	local provider = { name = "dovecot", request_id = 0 };
	log("debug", "initializing dovecot authentication provider for host '%s'", host);
	
	local conn;
	-- Generate an id for this connection (must be a 31-bit number, unique per process)
	local pid = tonumber(sha1(host, true):sub(1, 6), 16);
	
	-- Closes the socket
	function provider.close(self)
		if conn then
			conn:close();
			conn = nil;
		end
	end
	
	-- The following connects to a new socket and send the handshake
	function provider.connect(self)
		-- Destroy old socket
		provider:close();
		
		local ok, err;
		if socket_port then
			log("debug", "connecting to dovecot TCP socket at '%s':'%s'", socket_host, socket_port);
			conn = socket.tcp();
			ok, err = conn:connect(socket_host, socket_port);
		elseif socket.unix then
			log("debug", "connecting to dovecot UNIX socket at '%s'", socket_path);
			conn = socket.unix();
			ok, err = conn:connect(socket_path);
		else
			err = "luasocket was not compiled with UNIX sockets support";
		end
		if not ok then
			if socket_port then
				log("error", "error connecting to dovecot TCP socket at '%s':'%s'. error was '%s'. check permissions", socket_host, socket_port, err);
			else
				log("error", "error connecting to dovecot UNIX socket at '%s'. error was '%s'. check permissions", socket_path, err);
			end
			provider:close();
			return false;
		end
		
		-- Send our handshake
		log("debug", "sending handshake to dovecot. version 1.1, cpid '%d'", pid);
		if not provider:send("VERSION\t1\t1\n") then
			return false
		end
		if not provider:send("CPID\t" .. pid .. "\n") then
			return false
		end
		
		-- Parse Dovecot's handshake
		local done = false;
		local supported_mechs = {};
		while (not done) do
			local line = provider:receive();
			if not line then
				return false;
			end
			
			log("debug", "dovecot handshake: '%s'", line);
			local parts = line:gmatch("[^\t]+");
			local first = parts();
			if first == "VERSION" then
				-- Version should be 1.1
				local major_version = parts();
				
				if major_version ~= "1" then
					log("error", "dovecot server version is not 1.x. it is %s.x", major_version);
					provider:close();
					return false;
				end
			elseif first == "MECH" then
				local mech = parts();
				supported_mechs[mech] = true;
			elseif first == "DONE" then
				-- We need PLAIN
				if not supported_mechs.PLAIN then
					log("warn", "server doesn't support PLAIN mechanism.");
					provider:close();
					return false;
				end
				done = true;
			end
		end
		return true;
	end
	
	-- Wrapper for send(). Handles errors
	function provider.send(self, data)
		local ok, err = conn:send(data);
		if not ok then
			log("error", "error sending '%s' to dovecot. error was '%s'", data, err);
			provider:close();
			return false;
		end
		return true;
	end
	
	-- Wrapper for receive(). Handles errors
	function provider.receive(self)
		local line, err = conn:receive();
		if not line then
			log("error", "error receiving data from dovecot. error was '%s'", err);
			provider:close();
			return false;
		end
		return line;
	end
	
	function provider.send_auth_request(self, username, password)
		if not conn then
			if not provider:connect() then
				return nil, "Auth failed. Dovecot communications error";
			end
		end
		
		-- Send auth data
		if append_host then
			username = username .. "@" .. module.host;
		end
		local b64 = base64.encode(username .. "\0" .. username .. "\0" .. password);
		provider.request_id = provider.request_id + 1 % 4294967296
		
		local msg = "AUTH\t" .. provider.request_id .. "\tPLAIN\tservice=XMPP\tresp=" .. b64;
		log("debug", "sending auth request for '%s' with password '%s': '%s'", username, password, msg);
		if not provider:send(msg .. "\n") then
			return nil, "Auth failed. Dovecot communications error";
		end
		
		
		-- Get response
		local line = provider:receive();
		log("debug", "got auth response: '%s'", line);
		if not line then
			return nil, "Auth failed. Dovecot communications error";
		end
		local parts = line:gmatch("[^\t]+");
		
		-- Check response
		local status = parts();
		local resp_id = tonumber(parts());
		
		if resp_id  ~= provider.request_id then
			log("warn", "dovecot response_id(%s) doesn't match request_id(%s)", resp_id, provider.request_id);
			provider:close();
			return nil, "Auth failed. Dovecot communications error";
		end
		
		return status, parts;
	end
	
	function provider.test_password(username, password)
		log("debug", "test password '%s' for user %s at host %s", password, username, module.host);
		
		local status, extra = provider:send_auth_request(username, password);
		
		if status == "OK" then
			log("info", "login ok for '%s'", username);
			return true;
		else
			log("info", "login failed for '%s'", username);
			return nil, "Auth failed. Invalid username or password.";
		end
	end

	function provider.get_password(username)
		return nil, "Cannot get_password in dovecot backend.";
	end
	
	function provider.set_password(username, password)
		return nil, "Cannot set_password in dovecot backend.";
	end

	function provider.user_exists(username)
		log("debug", "user_exists for user %s at host %s", username, module.host);
		
		-- Send a request. If the response (FAIL) contains an extra
		-- parameter like user=<username> then it exists.
		local status, extra = provider:send_auth_request(username, "");
		
		local param = extra();
		while param do
			local parts = param:gmatch("[^=]+");
			local name = parts();
			local value = parts();
			if name == "user" then
				log("debug", "user '%s' exists", username);
				return true;
			end
			
			param = extra();
		end
		
		log("debug", "user '%s' does not exists (or dovecot didn't send user=<username> parameter)", username);
		return false;
	end

	function provider.create_user(username, password)
		return nil, "Cannot create_user in dovecot backend.";
	end

	function provider.get_sasl_handler()
		local getpass_authentication_profile = {
			plain_test = function(sasl, username, password, realm)
			local prepped_username = nodeprep(username);
			if not prepped_username then
				log("debug", "NODEprep failed on username: %s", username);
				return "", nil;
			end
			return usermanager.test_password(prepped_username, realm, password), true;
		end
		};
		return new_sasl(module.host, getpass_authentication_profile);
	end
	
	return provider;
end

module:add_item("auth-provider", new_provider(module.host));
