local next = next;
local setmetatable = setmetatable;

local log = require "util.logger".init("mongodb");
local params = module:get_option("mongodb");

local mongo = require "mongo";

local conn = mongo.Connection.New ( true );
conn:connect ( params.server );
conn:auth ( params );

local keyval_store = {};
keyval_store.__index = keyval_store;

function keyval_store:get(username)
	local host, store = module.host, self.store;

	local namespace = params.dbname .. "." .. host;
	local v = { _id = { store = store ; username = username } };

	local cursor , err = conn:query ( namespace , v );
	if not cursor then return nil , err end;

	local r , err = cursor:next ( );
	if not r then return nil , err end;
	return r.data;
end

function keyval_store:set(username, data)
	local host, store = module.host, self.store;
	if not host then return nil , "mongodb cannot currently be used for host-less data" end;

	local namespace = params.dbname .. "." .. host;
	local v = { _id = { store = store ; username = username } };

	if next(data) ~= nil then -- set data
		v.data = data;
		return conn:insert ( namespace , v );
	else -- delete data
		return conn:remove ( namespace , v );
	end;
end

local driver = { name = "mongodb" };

function driver:open(store, typ)
	if not typ then -- default key-value store
		return setmetatable({ store = store }, keyval_store);
	end;
	return nil, "unsupported-store";
end

module:add_item("data-driver", driver);
