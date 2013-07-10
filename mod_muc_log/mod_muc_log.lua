local prosody = prosody;
local hosts = prosody.hosts;
local tostring = tostring;
local split_jid = require "util.jid".split;
local cm = require "core.configmanager";
local datamanager = require "util.datamanager";
local data_load, data_store, data_getpath = datamanager.load, datamanager.store, datamanager.getpath;
local datastore = "muc_log";
local error_reply = require "util.stanza".error_reply;
local storagemanager = storagemanager;
local muc_form_config_option = "muc#roomconfig_enablelogging"

local mod_host = module:get_host();
local log_presences = module:get_option_boolean("muc_log_presences", true);

-- Helper Functions

local function inject_storage_config()
	local _storage = cm.getconfig()[mod_host].storage;

	module:log("debug", "injecting storage config...");
	if type(_storage) == "string" then cm.getconfig()[mod_host].default_storage = _storage; end
	if type(_storage) == "table" then -- append
		_storage.muc_log = "internal";
	else
		cm.getconfig()[mod_host].storage = { muc_log = "internal" };
	end

	storagemanager.get_driver(mod_host, "muc_log"); -- init
end

-- Module Definitions

function log_if_needed(e)
	local stanza, origin = e.stanza, e.origin;
	
	if	(stanza.name == "presence") or
		(stanza.name == "iq") or
	   	(stanza.name == "message" and tostring(stanza.attr.type) == "groupchat")
	then
		local node, host = split_jid(stanza.attr.to);
		local muc = hosts[host].muc;
		if node and host then
			local bare = node .. "@" .. host;
			if muc and muc.rooms[bare] then
				local room = muc.rooms[bare]
				local today = os.date("%y%m%d");
				local now = os.date("%X")
				local muc_to = nil
				local muc_from = nil;
				local already_joined = false;
				
				if room._data.hidden then -- do not log any data of private rooms
					return;
				end
				if not room._data.logging then -- do not log where logging is not enabled
					return;
				end
				
				if stanza.name == "presence" and stanza.attr.type == nil then
					muc_from = stanza.attr.to;
					if room._occupants and room._occupants[stanza.attr.to] then
						already_joined = true;
						stanza:tag("alreadyJoined"):text("true"); 
					end
				elseif stanza.name == "iq" and stanza.attr.type == "set" then -- kick, to is the room, from is the admin, nick who is kicked is attr of iq->query->item
					if stanza.tags[1] and stanza.tags[1].name == "query" then
						local tmp = stanza.tags[1];
						if tmp.tags[1] ~= nil and tmp.tags[1].name == "item" and tmp.tags[1].attr.nick then
							tmp = tmp.tags[1];
							for jid, nick in pairs(room._jid_nick) do
								if nick == stanza.attr.to .. "/" .. tmp.attr.nick then
									muc_to = nick;
									break;
								end
							end
						end
					end
				else
					for jid, nick in pairs(room._jid_nick) do
						if jid == stanza.attr.from then
							muc_from = nick;
							break;
						end
					end
				end

				if (muc_from or muc_to) then
					local data = data_load(node, host, datastore .. "/" .. today);
					local realFrom = stanza.attr.from;
					local realTo = stanza.attr.to;
					
					if data == nil then
						data = {};
					end
					
					stanza.attr.from = muc_from;
					stanza.attr.to = muc_to;
					data[#data + 1] = "<stanza time=\"".. now .. "\">" .. tostring(stanza) .. "</stanza>\n";
					stanza.attr.from = realFrom;
					stanza.attr.to = realTo;
					if already_joined == true then
						if stanza[#stanza].name == "alreadyJoined" then  -- normaly the faked element should be the last, remove it when it is the last
							stanza[#stanza] = nil;
						else
							for i = 1, #stanza, 1 do
								if stanza[i].name == "alreadyJoined" then  -- remove the faked element
									stanza[i] = nil;
									break;
								end
							end
						end
					end
					data_store(node, host, datastore .. "/" .. today, data);
				end
			end
		end
	end
end

module:hook("muc-config-form", function(event)
	local room, form = event.room, event.form;
	table.insert(form,
	{
		name = muc_form_config_option,
		type = "boolean",
		label = "Enable Logging?",
		value = room._data.logging or false,
	}
	);
end);

module:hook("muc-config-submitted", function(event)
	local room, fields, changed = event.room, event.fields, event.changed;
	local new = fields[muc_form_config_option];
	if new ~= room._data.logging then
		room._data.logging = new;
		if type(changed) == "table" then
			changed[muc_form_config_option] = true;
		else
			event.changed = true;
		end
	end
end);

module:hook("message/bare", log_if_needed, 1);
if log_presences then
	module:hook("iq/bare", log_if_needed, 1);
	module:hook("presence/full", log_if_needed, 1); 
end

local function reload()
	inject_storage_config();
end

function module.load()
	inject_storage_config();
end

module:log("debug", "module mod_muc_log loaded!");
