-- Copyright (C) 2009 Florian Zeitz
-- 
-- This file is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local st, jid, uuid = require "util.stanza", require "util.jid", require "util.uuid";
local usermanager_user_exists = require "core.usermanager".user_exists;
local usermanager_create_user = require "core.usermanager".create_user;

local is_admin = require "core.usermanager".is_admin;
local admins = set.new(config.get(module:get_host(), "core", "admins"));

local sessions = {};

function add_user_command_handler(item, origin, stanza)
	if not is_admin(stanza.attr.from) then
		module:log("warn", "Non-admin %s tried to add a user", tostring(jid.bare(stanza.attr.from)));
		origin.send(st.error_reply(stanza, "auth", "forbidden", "You don't have permission to add a user"):up()
			:tag("command", {xmlns="http://jabber.org/protocol/commands",
				node="http://jabber.org/protocol/admin#add-user", status="canceled"})
			:tag("note", {type="error"}):text("You don't have permission to add a user"));
		return true;
	end
	if stanza.tags[1].attr.sessionid and sessions[stanza.tags[1].attr.sessionid] then
		if stanza.tags[1].attr.action == "cancel" then
			origin.send(st.reply(stanza):tag("command", {xmlns="http://jabber.org/protocol/commands",
				node="http://jabber.org/protocol/admin#add-user",
				sessionid=stanza.tags[1].attr.sessionid, status="canceled"}));
			sessions[stanza.tags[1].attr.sessionid] = nil;
			return true;
		end
		for _, tag in ipairs(stanza.tags[1].tags) do
			if tag.name == "x" and tag.attr.xmlns == "jabber:x:data" then
				form = tag;
				break;
			end
		end
		local fields = {};
		for _, field in ipairs(form.tags) do
			if field.name == "field" and field.attr.var then
				for i, tag in ipairs(field.tags) do
					if tag.name == "value" and #tag.tags == 0 then
						fields[field.attr.var] = tag[1] or "";
					end
				end
			end
		end
		local username, host, resource = jid.split(fields.accountjid);
		if (fields.password == fields["password-verify"]) and username and host and host == stanza.attr.to then
			if usermanager_user_exists(username, host) then
				origin.send(st.error_reply(stanza, "cancel", "conflict", "Account already exists"):up()
					:tag("command", {xmlns="http://jabber.org/protocol/commands",
						node="http://jabber.org/protocol/admin#add-user", status="canceled"})
					:tag("note", {type="error"}):text("Account already exists"));
				sessions[stanza.tags[1].attr.sessionid] = nil;
				return true;
			else
				if usermanager_create_user(username, fields.password, host) then
					origin.send(st.reply(stanza):tag("command", {xmlns="http://jabber.org/protocol/commands",
						node="http://jabber.org/protocol/admin#add-user",
						sessionid=stanza.tags[1].attr.sessionid, status="completed"})
						:tag("note", {type="info"}):text("Account successfully created"));
					sessions[stanza.tags[1].attr.sessionid] = nil;
					module:log("debug", "Created new account " .. username.."@"..host);
					return true;
				else
					origin.send(st.error_reply(stanza, "wait", "internal-server-error",
						"Failed to write data to disk"):up()
						:tag("command", {xmlns="http://jabber.org/protocol/commands",
							node="http://jabber.org/protocol/admin#add-user", status="canceled"})
						:tag("note", {type="error"}):text("Failed to write data to disk"));
					sessions[stanza.tags[1].attr.sessionid] = nil;
					return true;
				end
			end
		else
			module:log("debug", fields.accountjid .. " " .. fields.password .. " " .. fields["password-verify"]);
			origin.send(st.error_reply(stanza, "cancel", "conflict",
				"Invalid data.\nPasswords missmatch, or empy username"):up()
				:tag("command", {xmlns="http://jabber.org/protocol/commands",
					node="http://jabber.org/protocol/admin#add-user", status="canceled"})
				:tag("note", {type="error"}):text("Invalid data.\nPasswords missmatch, or empy username"));
			sessions[stanza.tags[1].attr.sessionid] = nil;
			return true;
		end
	else
		sessionid=uuid.generate();
		sessions[sessionid] = "executing";
		origin.send(st.reply(stanza):tag("command", {xmlns="http://jabber.org/protocol/commands",
			node="http://jabber.org/protocol/admin#add-user", sessionid=sessionid,
			status="executing"})
			:tag("x", { xmlns = "jabber:x:data", type = "form" })
				:tag("title"):text("Adding a User"):up()
				:tag("instructions"):text("Fill out this form to add a user."):up()
				:tag("field", { type = "hidden", var = "FORM_TYPE" })
					:tag("value"):text("http://jabber.org/protocol/admin"):up():up()
				:tag("field", { label = "The Jabber ID for the account to be added",
					type = "jid-single", var = "accountjid" })
					:tag("required"):up():up()
				:tag("field", { label = "The password for this account",
					type = "text-private", var = "password" }):up()
				:tag("field", { label = "Retype password", type = "text-private",
					var = "password-verify" }):up():up()
		);
	end
	return true;
end

local descriptor = { name="Add User", node="http://jabber.org/protocol/admin#add-user", handler=add_user_command_handler };

function module.unload()
	module:remove_item("adhoc", descriptor);
end

module:add_item ("adhoc", descriptor);
