-- Copyright (C) 2009 Thilo Cestonaro
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
local prosody = prosody;
local splitJid = require "util.jid".split;
local bareJid = require "util.jid".bare;
local config_get = require "core.configmanager".get;
local httpserver = require "net.httpserver";
local serialize = require "util.serialization".serialize;
local datamanager = require "util.datamanager";
local data_load, data_store, data_getpath = datamanager.load, datamanager.store, datamanager.getpath;
local datastore = "muc_log";
local config = {};


--[[ LuaFileSystem 
* URL: http://www.keplerproject.org/luafilesystem/index.html
* Install: luarocks install luafilesystem
* ]]
local lfs = require "lfs";

local lom = require "lxp.lom";


--[[
* Default templates for the html output.
]]--
local html = {};
html.doc = [[<html>
<meta http-equiv="Content-Type" content="text/html; charset=UTF-8" >
<head>
	<title>muc_log</title>
</head>
<style type="text/css">
<!--
.timestuff {color: #AAAAAA; text-decoration: none;}
.muc_join {color: #009900; font-style: italic;}
.muc_leave {color: #009900; font-style: italic;}
.muc_statusChange {color: #009900; font-style: italic;}
.muc_title {color: #BBBBBB; font-size: 32px;}
.muc_titleChange {color: #009900; font-style: italic;}
.muc_kick {color: #009900; font-style: italic;}
.muc_bann {color: #009900; font-style: italic;}
.muc_msg_nick {color: #0000AA;}
//-->
</style>
<body>
###BODY_STUFF###
</body>
</html>]];

html.hosts = {};
html.hosts.bit = [[<a href="/muc_log/###JID###">###JID###</a><br />]]
html.hosts.body = [[<h2>Rooms hosted on this server:</h2><hr /><p>
###HOSTS_STUFF###
</p><hr />]];

html.days = {};
html.days.bit = [[<a href="/muc_log/###JID###/?year=###YEAR###&month=###MONTH###&day=###DAY###">20###YEAR###/###MONTH###/###DAY###</a><br />]];
html.days.body = [[<h2>available logged days of room: ###JID###</h2><hr /><p>
###DAYS_STUFF###
</p><hr />]];

html.day = {};
html.day.title = [[Subject: <font class="muc_title">###TITLE###</font>]];
html.day.time = [[<a name="###TIME###" href="####TIME###" class="timestuff">[###TIME###]</a> ]]; -- the one ####TIME### need to stay! it will evaluate to e.g. #09:10:56 which is an anker then
html.day.presence = {};
html.day.presence.join = [[###TIME_STUFF###<font class="muc_join"> *** ###NICK### joins the room</font><br />]];
html.day.presence.leave = [[###TIME_STUFF###<font class="muc_leave"> *** ###NICK### leaves the room</font><br />]];
html.day.presence.statusText = [[ and his status message is "###STATUS###"]];
html.day.presence.statusChange = [[###TIME_STUFF###<font class="muc_statusChange"> *** ###NICK### shows now as "###SHOW###"###STATUS_STUFF###</font><br />]];
html.day.message = [[###TIME_STUFF###<font class="muc_msg_nick">&lt;###NICK###&gt;</font> ###MSG###<br />]];
html.day.titleChange = [[###TIME_STUFF###<font class="muc_titleChange"> *** ###NICK### changed the title to "###TITLE###"</font><br />]];
html.day.reason = [[, the reason was "###REASON###"]]
html.day.kick = [[###TIME_STUFF###<font class="muc_kick"> *** ###VICTIM### got kicked###REASON_STUFF###</font><br />]];
html.day.bann = [[###TIME_STUFF###<font class="muc_bann"> *** ###VICTIM### got banned###REASON_STUFF###</font><br />]];
html.day.body = [[<h2>room ###JID### logging of 20###YEAR###/###MONTH###/###DAY###</h2>
<p>###TITLE_STUFF###</p>
<hr /><p>
###DAY_STUFF###
</p><hr />]];

html.help = [[
MUC logging is not configured correctly.<br />
Here is a example config:<br />
Component "rooms.example.com" "muc"<br />
&nbsp;&nbsp;modules_enabled = {<br />
&nbsp;&nbsp;&nbsp;&nbsp;"muc_log";<br />
&nbsp;&nbsp;}<br />
&nbsp;&nbsp;muc_log = {<br />
&nbsp;&nbsp;&nbsp;&nbsp;folder = "/opt/local/var/log/prosody/rooms";<br />
&nbsp;&nbsp;&nbsp;&nbsp;http_port = "/opt/local/var/log/prosody/rooms";<br />
&nbsp;&nbsp;}<br />
]];

local function ensureDatastorePathExists(node, host, today)
	local path = data_getpath(node, host, datastore, "dat", true);
	path = path:gsub("/[^/]*$", "");

	-- check existance
	local attributes = lfs.attributes(path);
	if attributes.mode ~= "directory" then
		module:log("warn", "muc_log folder isn't a folder: %s", path);
		return false;
	end
	
	attributes = lfs.attributes(path .. "/" .. today);
	if attributes == nil then
		return lfs.mkdir(path .. "/" .. today);
	elseif attributes.mode == "directory" then
		return true;
	end
	return false;
end

function logIfNeeded(e)
	local stanza, origin = e.stanza, e.origin;
	
	if	(stanza.name == "presence") or
		(stanza.name == "iq") or
	   	(stanza.name == "message" and tostring(stanza.attr.type) == "groupchat")
	then
		local node, host, resource = splitJid(stanza.attr.to);
		if node ~= nil and host ~= nil then
			local bare = node .. "@" .. host;
			if prosody.hosts[host] ~= nil and prosody.hosts[host].muc ~= nil and prosody.hosts[host].muc.rooms[bare] ~= nil then
				local room = prosody.hosts[host].muc.rooms[bare]
				local today = os.date("%y%m%d");
				local now = os.date("%X")
				local mucTo = nil
				local mucFrom = nil;
				local alreadyJoined = false;
		
				if stanza.name == "presence" and stanza.attr.type == nil then
					mucFrom = stanza.attr.to;
					if room._occupants ~= nil and room._occupants[stanza.attr.to] ~= nil then -- if true, the user has already joined the room
						alreadyJoined = true;
						stanza:tag("alreadyJoined"):text("true"); -- we need to log the information that the user has already joined, so add this and remove after logging
					end
				elseif stanza.name == "iq" and stanza.attr.type == "set" then -- kick, to is the room, from is the admin, nick who is kicked is attr of iq->query->item
					if stanza.tags[1] ~= nil and stanza.tags[1].name == "query" then
						local tmp = stanza.tags[1];
						if tmp.tags[1] ~= nil and tmp.tags[1].name == "item" and tmp.tags[1].attr.nick ~= nil then
							tmp = tmp.tags[1];
							for jid, nick in pairs(room._jid_nick) do
								if nick == stanza.attr.to .. "/" .. tmp.attr.nick then
									mucTo = nick;
									break;
								end
							end
						end
					end
				else
					for jid, nick in pairs(room._jid_nick) do
						if jid == stanza.attr.from then
							mucFrom = nick;
							break;
						end
					end
				end

				if (mucFrom ~= nil or mucTo ~= nil) and ensureDatastorePathExists(node, host, today) then
					local data = data_load(node, host, datastore .. "/" .. today);
					local realFrom = stanza.attr.from;
					local realTo = stanza.attr.to;
					
					if data == nil then
						data = {};
					end
					
					stanza.attr.from = mucFrom;
					stanza.attr.to = mucTo;
					data[#data + 1] = "<stanza time=\"".. now .. "\">" .. tostring(stanza) .. "</stanza>\n";
					stanza.attr.from = realFrom;
					stanza.attr.to = realTo;
					if alreadyJoined == true then
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
	return;
end

function createDoc(body)
	return html.doc:gsub("###BODY_STUFF###", body);
end

local function htmlEscape(t)
	t = t:gsub("<", "&lt;");
	t = t:gsub(">", "&gt;");
	t = t:gsub("(http://[%a%d@%.:/&%?=%-_#]+)", [[<a href="%1">%1</a>]]);
	t = t:gsub("\n", "<br />");
	-- TODO do any html escaping stuff ... 
	return t;
end

function splitQuery(query)
	local ret = {};
	local name, value = nil, nil;
	if query == nil then return ret; end
	local last = 1;
	local idx = query:find("&", last);
	while idx ~= nil do
		name, value = query:sub(last, idx - 1):match("^(%a+)=(%d+)$");
		ret[name] = value;
		last = idx + 1;
		idx = query:find("&", last);
	end
	name, value = query:sub(last):match("^(%a+)=(%d+)$");
	ret[name] = value;
	return ret;
end

function grepRoomJid(url)
	local tmp = url:sub(string.len("/muc_log/") + 1);
	local node = nil;
	local host = nil;
	local at = nil;
	local slash = nil;
	
	at = tmp:find("@");
	slash = tmp:find("/");
	if slash ~= nil then
		slash = slash - 1;
	end
	
	if at ~= nil then
	 	node = tmp:sub(1, at - 1);
		host = tmp:sub(at + 1, slash);
	end
	return node, host;
end

local function generateRoomListSiteContent()
	local rooms = "";
	for host, config in pairs(prosody.hosts) do
		if prosody.hosts[host].muc ~= nil then
			for jid, room in pairs(prosody.hosts[host].muc.rooms) do
				rooms = rooms .. html.hosts.bit:gsub("###JID###", jid);
			end
		end
	end
	
	return html.hosts.body:gsub("###HOSTS_STUFF###", rooms);
end

local function generateDayListSiteContentByRoom(bareRoomJid)
	local days = "";
	local tmp;
	local node, host, resource = splitJid(bareRoomJid);
	local path = data_getpath(node, host, datastore);
	path = path:gsub("/[^/]*$", "");
	for file in lfs.dir(path) do
		local year, month, day = file:match("^(%d%d)(%d%d)(%d%d)");
		if	year ~= nil and month ~= nil and day ~= nil and
			year ~= ""  and month ~= ""  and day ~= ""
		then
			tmp = html.days.bit;
			tmp = tmp:gsub("###JID###", bareRoomJid);
			tmp = tmp:gsub("###YEAR###", year):gsub("###MONTH###", month):gsub("###DAY###", day);
			days = tmp .. days;
		end
	end
	if days ~= "" then
		tmp = html.days.body:gsub("###DAYS_STUFF###", days);
		return tmp:gsub("###JID###", bareRoomJid);
	else
		return generateRoomListSiteContent(); -- fallback
	end
end

local function parseIqStanza(stanza, timeStuff, nick)
	local text = nil;
	for _,tag in ipairs(stanza) do
		if tag.tag == "query" then
			for _,item in ipairs(tag) do
				if item.tag == "item" then
					for _,reason in ipairs(item) do
						if reason.tag == "reason" then
							text = reason[1];
							break;
						end
					end
					break;
				end 
			end
			break;
		end
	end
	
	if text ~= nil then	
		text = html.day.reason:gsub("###REASON###", htmlEscape(text));
	else
		text = "";
	end	
	return html.day.kick:gsub("###TIME_STUFF###", timeStuff):gsub("###VICTIM###", nick):gsub("###REASON_STUFF###", text);
end

local function parsePresenceStanza(stanza, timeStuff, nick)
	local ret = "";
	if stanza.attr.type == nil then
		local show, status = nil, "";
		local alreadyJoined = false;
		for _, tag in ipairs(stanza) do
			if tag.tag == "alreadyJoined" then
				alreadyJoined = true;
			elseif tag.tag == "show" then
				show = tag[1];
			elseif tag.tag == "status" then
				status = tag[1];
			end
		end
		if alreadyJoined == true then
			if show == nil then
				show = "online";
			end
			ret = html.day.presence.statusChange:gsub("###TIME_STUFF###", timeStuff);
			if status ~= "" then
				status = html.day.presence.statusText:gsub("###STATUS###", htmlEscape(status));
			end
			ret = ret:gsub("###SHOW###", show):gsub("###NICK###", nick):gsub("###STATUS_STUFF###", status);
		else
			ret = html.day.presence.join:gsub("###TIME_STUFF###", timeStuff):gsub("###NICK###", nick);
		end
	elseif stanza.attr.type ~= nil and stanza.attr.type == "unavailable" then
		ret = html.day.presence.leave:gsub("###TIME_STUFF###", timeStuff):gsub("###NICK###", nick);
	end
	return ret;
end

local function parseMessageStanza(stanza, timeStuff, nick)
	local body, title, ret = nil, nil, "";
	
	for _,tag in ipairs(stanza) do
		if tag.tag == "body" then
			body = tag[1];
			if nick ~= nil then
				break;
			end
		elseif tag.tag == "nick" and nick == nil then
			nick = htmlEscape(tag[1]);
			if body ~= nil or title ~= nil then
				break;
			end
		elseif tag.tag == "subject" then
			title = tag[1];
			if nick ~= nil then
				break;
			end
		end
	end
	if nick ~= nil and body ~= nil then
		body = htmlEscape(body);
		ret = html.day.message:gsub("###TIME_STUFF###", timeStuff):gsub("###NICK###", nick):gsub("###MSG###", body);
	elseif nick ~= nil and title ~= nil then
		title = htmlEscape(title);
		ret = html.day.titleChange:gsub("###TIME_STUFF###", timeStuff):gsub("###NICK###", nick):gsub("###TITLE###", title);	
	end
	return ret;
end

local function parseDay(bareRoomJid, roomSubject, query)
	local ret = "";
	local year;
	local month;
	local day;
	local tmp;
	local node, host, resource = splitJid(bareRoomJid);
	
	if query.year ~= nil and query.month ~= nil and query.day ~= nil then
		local data = data_load(node, host, datastore .. "/" .. query.year .. query.month .. query.day);
		if data ~= nil then
			for i=1, #data, 1 do
				local stanza = lom.parse(data[i]);
				if stanza ~= nil and stanza.attr ~= nil and stanza.attr.time ~= nil then
					local timeStuff = html.day.time:gsub("###TIME###", stanza.attr.time);
					if stanza[1] ~= nil then
						local nick;
						
						-- grep nick from "from" resource
						if stanza[1].attr.from ~= nil then -- presence and messages
							nick = htmlEscape(stanza[1].attr.from:match("/(.+)$"));
						elseif stanza[1].attr.to ~= nil then -- iq
							nick = htmlEscape(stanza[1].attr.to:match("/(.+)$"));
						end
						
						if stanza[1].tag == "presence" and nick ~= nil then
							ret = ret .. parsePresenceStanza(stanza[1], timeStuff, nick);
						elseif stanza[1].tag == "message" then
							ret = ret .. parseMessageStanza(stanza[1], timeStuff, nick);
						elseif stanza[1].tag == "iq" then
							ret = ret .. parseIqStanza(stanza[1], timeStuff, nick);
						else
							module:log("info", "unknown stanza subtag in log found. room: %s; day: %s", bareRoomJid, query.year .. "/" .. query.month .. "/" .. query.day);
						end
					end
				end
			end
		else
			return generateDayListSiteContentByRoom(bareRoomJid); -- fallback
		end
		tmp = html.day.body:gsub("###DAY_STUFF###", ret):gsub("###JID###", bareRoomJid);
		tmp = tmp:gsub("###YEAR###", query.year):gsub("###MONTH###", query.month):gsub("###DAY###", query.day);
		tmp = tmp:gsub("###TITLE_STUFF###", html.day.title:gsub("###TITLE###", roomSubject));
		return tmp;
	else
		return generateDayListSiteContentByRoom(bareRoomJid); -- fallback
	end
end

function handle_request(method, body, request)
	local query = splitQuery(request.url.query);
	local node, host = grepRoomJid(request.url.path);
	
	if node ~= nil  and host ~= nil then
		local bare = node .. "@" .. host;
		if prosody.hosts[host] ~= nil and prosody.hosts[host].muc ~= nil and prosody.hosts[host].muc.rooms[bare] ~= nil then
			local room = prosody.hosts[host].muc.rooms[bare];
			if request.url.query == nil then
				return createDoc(generateDayListSiteContentByRoom(bare));
			else
				local subject = ""
				if room._data ~= nil and room._data.subject ~= nil then
					subject = room._data.subject;
				end
				return createDoc(parseDay(bare, subject, query));
			end
		else
			return createDoc(generateRoomListSiteContent());
		end
	else
		return createDoc(generateRoomListSiteContent());
	end
	return;
end

config = config_get(module:get_host(), "core", "muc_log");

httpserver.new_from_config({ config.http_port or true }, handle_request, { base = "muc_log" });

module:hook("message/bare", logIfNeeded, 500);
module:hook("pre-message/bare", logIfNeeded, 500);
module:hook("iq/bare", logIfNeeded, 500);
module:hook("pre-iq/bare", logIfNeeded, 500);
module:hook("presence/full", logIfNeeded, 500);
module:hook("pre-presence/full", logIfNeeded, 500);
