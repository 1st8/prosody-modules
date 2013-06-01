
local jid = require "util.jid";
local st = require "util.stanza";
local new_throttle = require "util.throttle".create;

local xmlns_muc = "http://jabber.org/protocol/muc";

local period = math.max(module:get_option_number("muc_event_rate", 0.5), 0);
local burst = math.max(module:get_option_number("muc_burst_factor", 6), 1);

local max_nick_length = module:get_option_number("muc_max_nick_length", 23); -- Default chosen through scientific methods

local function handle_stanza(event)
	local origin, stanza = event.origin, event.stanza;
	if stanza.name == "presence" and stanza.attr.type == "unavailable" then -- Don't limit room leaving
		return;
	end
	local dest_room, dest_host, dest_nick = jid.split(stanza.attr.to);
	local room = hosts[module.host].modules.muc.rooms[dest_room.."@"..dest_host];
	if not room then return; end
	local from_jid = stanza.attr.from;
	local occupant = room._occupants[room._jid_nick[from_jid]];
	if occupant and occupant.affiliation then
		module:log("debug", "Skipping stanza from affiliated user...");
		return;
	elseif max_nick_length and stanza.name == "presence" and not room._occupants[stanza.attr.to] and #dest_nick > max_nick_length then
		module:log("debug", "Forbidding long (%d bytes) nick in %s", #dest_nick, dest_room)
		origin.send(st.error_reply(stanza, "modify", "policy-violation", "Your nick name is too long, please use a shorter one")
			:up():tag("x", { xmlns = xmlns_muc }));
		return true;
	end
	local throttle = room.throttle;
	if not room.throttle then
		throttle = new_throttle(period*burst, burst);
		room.throttle = throttle;
	end
	if not throttle:poll(1) then
		module:log("warn", "Dropping stanza for %s@%s from %s, over rate limit", dest_room, dest_host, from_jid);
		local reply = st.error_reply(stanza, "wait", "policy-violation", "The room is currently overactive, please try again later");
		local body = stanza:get_child_text("body");
		if body then
			reply:up():tag("body"):text(body):up();
		end
		local x = stanza:get_child("x", xmlns_muc);
		if x then
			reply:add_child(st.clone(x));
		end
		origin.send(reply);
		return true;
	end
end

function module.unload()
	for room_jid, room in pairs(hosts[module.host].modules.muc.rooms) do
		room.throttle = nil;
	end
end

module:hook("message/bare", handle_stanza, 10);
module:hook("message/full", handle_stanza, 10);
module:hook("presence/bare", handle_stanza, 10);
module:hook("presence/full", handle_stanza, 10);
