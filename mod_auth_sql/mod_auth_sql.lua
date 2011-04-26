-- Simple SQL Authentication module for Prosody IM
-- Copyright (C) 2011 Tomasz Sterna <tomek@xiaoka.com>
--

local log = require "util.logger".init("auth_sql");
local new_sasl = require "util.sasl".new;
local nodeprep = require "util.encodings".stringprep.nodeprep;

local DBI;
local connection;
local params = module:get_option("sql");

local resolve_relative_path = require "core.configmanager".resolve_relative_path;

local function test_connection()
	if not connection then return nil; end
	if connection:ping() then
		return true;
	else
		module:log("debug", "Database connection closed");
		connection = nil;
	end
end
local function connect()
	if not test_connection() then
		prosody.unlock_globals();
		local dbh, err = DBI.Connect(
			params.driver, params.database,
			params.username, params.password,
			params.host, params.port
		);
		prosody.lock_globals();
		if not dbh then
			module:log("debug", "Database connection failed: %s", tostring(err));
			return nil, err;
		end
		module:log("debug", "Successfully connected to database");
		dbh:autocommit(true); -- don't run in transaction
		connection = dbh;
		return connection;
	end
end

do -- process options to get a db connection
	DBI = require "DBI";

	params = params or { driver = "SQLite3" };
	
	if params.driver == "SQLite3" then
		params.database = resolve_relative_path(prosody.paths.data or ".", params.database or "prosody.sqlite");
	end
	
	assert(params.driver and params.database, "Both the SQL driver and the database need to be specified");
	
	assert(connect());
end

local function getsql(sql, ...)
	if params.driver == "PostgreSQL" then
		sql = sql:gsub("`", "\"");
	end
	if not test_connection() then connect(); end
	-- do prepared statement stuff
	local stmt, err = connection:prepare(sql);
	if not stmt and not test_connection() then error("connection failed"); end
	if not stmt then module:log("error", "QUERY FAILED: %s %s", err, debug.traceback()); return nil, err; end
	-- run query
	local ok, err = stmt:execute(...);
	if not ok and not test_connection() then error("connection failed"); end
	if not ok then return nil, err; end
	
	return stmt;
end

function new_default_provider(host)
	local provider = { name = "sql" };
	module:log("debug", "initializing default authentication provider for host '%s'", host);

	function provider.test_password(username, password)
		module:log("debug", "test_password '%s' for user %s at host %s", password, username, host);

		local stmt, err = getsql("SELECT `username` FROM `authreg` WHERE `username`=? AND `password`=? AND `realm`=?",
			username, password, host);

		if stmt ~= nil then
			local count = 0;
			for row in stmt:rows(true) do
				count = count + 1;
			end
			if count > 0 then
				return true;
			end
		else
			module:log("error", "QUERY ERROR: %s %s", err, debug.traceback());
			return nil, err;
		end

		return false;
	end

	function provider.get_password(username)
		module:log("debug", "get_password for username '%s' at host '%s'", username, host);

		local stmt, err = getsql("SELECT `password` FROM `authreg` WHERE `username`=? AND `realm`=?",
			username, host);

		local password = nil;
		if stmt ~= nil then
			for row in stmt:rows(true) do
				password = row.password;
			end
		else
			module:log("error", "QUERY ERROR: %s %s", err, debug.traceback());
			return nil;
		end

		return password;
	end

	function provider.set_password(username, password)
		return nil, "Setting password is not supported.";
	end

	function provider.user_exists(username)
		module:log("debug", "test user %s existence at host %s", username, host);

		local stmt, err = getsql("SELECT `username` FROM `authreg` WHERE `username`=? AND `realm`=?",
			username, host);

		if stmt ~= nil then
			local count = 0;
			for row in stmt:rows(true) do
				count = count + 1;
			end
			if count > 0 then
				return true;
			end
		else
			module:log("error", "QUERY ERROR: %s %s", err, debug.traceback());
			return nil, err;
		end

		return false;
	end

	function provider.create_user(username, password)
		return nil, "Account creation/modification not supported.";
	end

	function provider.get_sasl_handler()
		local realm = module:get_option("sasl_realm") or host;
		local getpass_authentication_profile = {
			plain = function(sasl, username, realm)
				local prepped_username = nodeprep(username);
				if not prepped_username then
					module:log("debug", "NODEprep failed on username: %s", username);
					return "", nil;
				end
				local password = usermanager.get_password(prepped_username, realm);
				if not password then
					return "", nil;
				end
				return password, true;
			end
		};
		return new_sasl(realm, getpass_authentication_profile);
	end

	return provider;
end

module:add_item("auth-provider", new_default_provider(module.host));

