-- Dovecot authentication backend for Prosody
--
-- Copyright (C) 2010 Javier Torres
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--

local socket_unix = require "socket.unix";
local datamanager = require "util.datamanager";
local log = require "util.logger".init("auth_dovecot");
local new_sasl = require "util.sasl".new;
local nodeprep = require "util.encodings".stringprep.nodeprep;
local base64 = require "util.encodings".base64;
local pposix = require "util.pposix";

local prosody = _G.prosody;
local socket_path = module:get_option_string("dovecot_auth_socket", "/var/run/dovecot/auth-login");

function new_default_provider(host)
	local provider = { name = "dovecot", c = nil, request_id = 0 };
	log("debug", "initializing dovecot authentication provider for host '%s'", host);
	
	-- Closes the socket
	function provider.close(self)
		if (provider.c ~= nil) then
			provider.c:close();
		end
		provider.c = nil;
	end
	
	-- The following connects to a new socket and send the handshake
	function provider.connect(self)
		-- Destroy old socket
		provider:close();
		
		provider.c = socket.unix();
		
		-- Create a connection to dovecot socket
		log("debug", "connecting to dovecot socket at '%s'", socket_path);
		local r, e = provider.c:connect(socket_path);
		if (not r) then
			log("warn", "error connecting to dovecot socket at '%s'. error was '%s'. check permissions", socket_path, e);
			provider:close();
			return false;
		end
		
		-- Send our handshake
		local pid = pposix.getpid();
		log("debug", "sending handshake to dovecot. version 1.1, cpid '%d'", pid);
		if not provider:send("VERSION\t1\t1\n") then
			return false
		end
		if (not provider:send("CPID\t" .. pid .. "\n")) then
			return false
		end
		
		-- Parse Dovecot's handshake
		local done = false;
		while (not done) do
			local l = provider:receive();
			if (not l) then
				return false;
			end
			
			log("debug", "dovecot handshake: '%s'", l);
			parts = string.gmatch(l, "[^\t]+");
			first = parts();
			if (first == "VERSION") then
				-- Version should be 1.1
				local v1 = parts();
				local v2 = parts();
				
				if (not (v1 == "1" and v2 == "1")) then
					log("warn", "server version is not 1.1. it is %s.%s", v1, v2);
					provider:close();
					return false;
				end
			elseif (first == "MECH") then
				-- Mechanisms should include PLAIN
				local ok = false;
				for p in parts do
					if p == "PLAIN" then
						ok = true;
					end
				end
				if (not ok) then
					log("warn", "server doesn't support PLAIN mechanism. It supports '%s'", l);
					provider:close();
					return false;
				end
			elseif (first == "DONE") then
				done = true;
			end
		end
		return true;
	end
	
	-- Wrapper for send(). Handles errors
	function provider.send(self, data)
		local r, e = provider.c:send(data);
		if (not r) then
			log("warn", "error sending '%s' to dovecot. error was '%s'", data, e);
			provider:close();
			return false;
		end
		return true;
	end
	
	-- Wrapper for receive(). Handles errors
	function provider.receive(self)
		local r, e = provider.c:receive();
		if (not r) then
			log("warn", "error receiving data from dovecot. error was '%s'", socket, e);
			provider:close();
			return false;
		end
		return r;
	end
	
	function provider.send_auth_request(self, username, password)
		if (provider.c == nil) then
			if (not provider:connect()) then
				return nil, "Auth failed. Dovecot communications error";
			end
		end
		
		-- Send auth data
		username = username .. "@" .. module.host; -- FIXME: this is actually a hack for my server
		local b64 = base64.encode(username .. "\0" .. username .. "\0" .. password);
		provider.request_id = provider.request_id + 1 % 4294967296
		
		local msg = "AUTH\t" .. provider.request_id .. "\tPLAIN\tservice=XMPP\tresp=" .. b64;
		log("debug", "sending auth request for '%s' with password '%s': '%s'", username, password, msg);
		if (not provider:send(msg .. "\n")) then
			return nil, "Auth failed. Dovecot communications error";
		end
		
		
		-- Get response
		local l = provider:receive();
		log("debug", "got auth response: '%s'", l);
		if (not l) then
			return nil, "Auth failed. Dovecot communications error";
		end
		local parts = string.gmatch(l, "[^\t]+");
		
		-- Check response
		local status = parts();
		local resp_id = tonumber(parts());
		
		if (resp_id  ~= provider.request_id) then
			log("warn", "dovecot response_id(%s) doesn't match request_id(%s)", resp_id, provider.request_id);
			provider:close();
			return nil, "Auth failed. Dovecot communications error";
		end
		
		return status, parts;
	end
	
	function provider.test_password(username, password)
		log("debug", "test password '%s' for user %s at host %s", password, username, module.host);
		
		local status, extra = provider:send_auth_request(username, password);
		
		if (status == "OK") then
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
		while (param) do
			parts = string.gmatch(param, "[^=]+");
			name = parts();
			value = parts();
			if (name == "user") then
				log("info", "user '%s' exists", username);
				return true;
			end
			
			param = extra();
		end
		
		log("info", "user '%s' does not exists (or dovecot didn't send user=<username> parameter)", username);
		return false;
	end

	function provider.create_user(username, password)
		return nil, "Cannot create_user in dovecot backend.";
	end

	function provider.get_sasl_handler()
		local realm = module:get_option("sasl_realm") or module.host;
		local getpass_authentication_profile = {
			plain_test = function(username, password, realm)
			local prepped_username = nodeprep(username);
			if not prepped_username then
				log("debug", "NODEprep failed on username: %s", username);
				return "", nil;
			end
			return usermanager.test_password(prepped_username, realm, password), true;
		end
		};
		return new_sasl(realm, getpass_authentication_profile);
	end
	
	return provider;
end

module:add_item("auth-provider", new_default_provider(module.host));
