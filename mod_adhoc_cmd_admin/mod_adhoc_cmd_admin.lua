-- Copyright (C) 2009 Florian Zeitz
-- 
-- This file is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local _G = _G;

local prosody = _G.prosody;
local hosts = prosody.hosts;

local t_concat = table.concat;

local usermanager_user_exists = require "core.usermanager".user_exists;
local usermanager_get_password = require "core.usermanager".get_password;
local usermanager_create_user = require "core.usermanager".create_user;
local is_admin = require "core.usermanager".is_admin;

local st, jid, uuid = require "util.stanza", require "util.jid", require "util.uuid";
local dataforms_new = require "util.dataforms".new;
module:log("debug", module:get_name());
local adhoc_new = module:require "adhoc".new;

local add_user_layout = dataforms_new{
	title = "Adding a User";
	instructions = "Fill out this form to add a user.";

	{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/admin" };
	{ name = "accountjid", type = "jid-single", required = true, label = "The Jabber ID for the account to be added" };
	{ name = "password", type = "text-private", label = "The password for this account" };
	{ name = "password-verify", type = "text-private", label = "Retype password" };
};

local change_user_password_layout = dataforms_new{
	title = "Changing a User Password";
	instructions = "Fill out this form to change a user's password.";

	{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/admin" };
	{ name = "accountjid", type = "jid-single", required = true, label = "The Jabber ID for this account" };
	{ name = "password", type = "text-private", required = true, label = "The password for this account" };
};

local delete_user_layout = dataforms_new{
	title = "Deleting a User";
	instructions = "Fill out this form to delete a user.";

	{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/admin" };
	{ name = "accountjids", type = "jid-multi", label = "The Jabber ID(s) to delete" };
};

local get_user_password_layout = dataforms_new{
	title = "Getting User's Password";
	instructions = "Fill out this form to get a user's password.";

	{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/admin" };
	{ name = "accountjid", type = "jid-single", label = "The Jabber ID for which to retrieve the password" };
};

local get_user_password_result_layout = dataforms_new{
	{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/admin" };
	{ name = "accountjid", type = "jid-single", label = "JID" };
	{ name = "password", type = "text-single", label = "Password" };
};

local get_online_users_layout = dataforms_new{
	title = "Getting List of Online Users";
	instructions = "How many users should be returned at most?";

	{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/admin" };
	{ name = "max_items", type = "list-single", label = "Maximum number of users",
		value = { "25", "50", "75", "100", "150", "200", "all" } };
};

local get_online_users_result_layout = dataforms_new{
	{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/admin" };
	{ name = "onlineuserjids", type = "text-multi", label = "The list of all online users" };
};

local announce_layout = dataforms_new{
	title = "Making an Announcement";
	instructions = "Fill out this form to make an announcement to all\nactive users of this service.";

	{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/admin" };
	{ name = "subject", type = "text-single", label = "Subject" };
	{ name = "announcement", type = "text-multi", required = true, label = "Announcement" };
};

function add_user_command_handler(self, data, state)
	if state then
		if data.action == "cancel" then
			return { status = "canceled" };
		end
		local fields = add_user_layout:data(data.form);
		local username, host, resource = jid.split(fields.accountjid);
		if (fields["password"] == fields["password-verify"]) and username and host and host == data.to then
			if usermanager_user_exists(username, host) then
				return { status = "error", error = { type = "cancel", condition = "conflict", message = "Account already exists" } };
			else
				if usermanager_create_user(username, fields.password, host) then
					module:log("info", "Created new account " .. username.."@"..host);
					return { status = "completed", info = "Account successfully created" };
				else
					return { status = "error", error = { type = "wait", condition = "internal-server-error",
						 message = "Failed to write data to disk" } };
				end
			end
		else
			module:log("debug", fields.accountjid .. " " .. fields.password .. " " .. fields["password-verify"]);
			return { status = "error", error = { type = "cancel", condition = "conflict",
				 message = "Invalid data.\nPassword mismatch, or empty username" } };
		end
	else
		return { status = "executing", form = add_user_layout }, "executing";
	end
end

function change_user_password_command_handler(self, data, state)
	if state then
		if data.action == "cancel" then
			return { status = "canceled" };
		end
		local fields = change_user_password_layout:data(data.form);
		local username, host, resource = jid.split(fields.accountjid);
		if usermanager_user_exists(username, host) and usermanager_create_user(username, fields.password, host) then
			return { status = "completed", info = "Password successfully changed" };
		else
			return { status = "error", error = { type = "cancel", condition = "item-not-found", message = "User does not exist" } };
		end
	else
		return { status = "executing", form = change_user_password_layout }, "executing";
	end
end

function delete_user_command_handler(self, data, state)
	if state then
		if data.action == "cancel" then
			return { status = "canceled" };
		end
		local fields = delete_user_layout:data(data.form);
		local failed = {};
		local succeeded = {};
		for _, aJID in ipairs(fields.accountjids) do
			local username, host, resource = jid.split(aJID);
			if usermanager_user_exists(username, host) and usermanager_create_user(username, nil, host) then
				module:log("debug", "User " .. aJID .. " has been deleted");
				succeeded[#succeeded+1] = aJID;
			else
				module:log("debug", "Tried to delete non-existant user "..aJID);
				failed[#failed+1] = aJID;
			end
		end
		return {status = "completed", info = (#succeeded ~= 0 and
				"The following accounts were successfully deleted:\n"..t_concat(succeeded, "\n").."\n" or "")..
				(#failed ~= 0 and
				"The following accounts could not be deleted:\n"..t_concat(failed, "\n") or "") };
	else
		return { status = "executing", form = delete_user_layout }, "executing";
	end
end

function get_user_password_handler(self, data, state)
	if state then
		if data.action == "cancel" then
			return { status = "canceled" };
		end
		local fields = get_user_password_layout:data(data.form);
		local user, host, resource = jid.split(fields.accountjid);
		local accountjid = "";
		local password = "";
		if usermanager_user_exists(user, host) then
			accountjid = fields.accountjid;
			password = usermanager_get_password(user, host);
		else
			return { status = "error", error = { type = "cancel", condition = "item-not-found", message = "User does not exist" } };
		end
		return { status = "completed", result = { layout = get_user_password_result_layout, data = {accountjid = accountjid, password = password} } };
	else
		return { status = "executing", form = get_user_password_layout }, "executing";
	end
end

function get_online_users_command_handler(self, data, state)
	if state then
		if data.action == "cancel" then
			return { status = "canceled" };
		end

		local fields = add_user_layout:data(data.form);
		
		local max_items = nil
		if fields.max_items ~= "all" then
			max_items = tonumber(fields.max_items);
		end
		local count = 0;
		local users = nil;
		for username, user in pairs(hosts[data.to].sessions or {}) do
			if (max_items ~= nil) and (count >= max_items) then
				break;
			end
			users = ((users and users.."\n") or "")..(username.."@"..data.to);
			count = count + 1;
		end
		return { status = "completed", result = {layout = get_online_users_result_layout, data = {onlineuserjids=users}} };
	else
		return { status = "executing", form = get_online_users_layout }, "executing";
	end
end

function announce_handler(self, data, state)
	if state then
		if data.action == "cancel" then
			return { status = "canceled" };
		end

		local fields = announce_layout:data(data.form);

		module:log("info", "Sending server announcement to all online users");
		local host_session = hosts[data.to];
		local message = st.message({type = "headline", from = data.to}, fields.announcement):up()
			:tag("subject"):text(fields.subject or "Announcement");
		
		local c = 0;
		for user in pairs(host_session.sessions) do
			c = c + 1;
			message.attr.to = user.."@"..data.to;
			core_post_stanza(host_session, message);
		end
		
		module:log("info", "Announcement sent to %d online users", c);
		return { status = "completed", info = "Announcement sent." };
	else
		return { status = "executing", form = announce_layout }, "executing";
	end

	return true;
end

local add_user_desc = adhoc_new("Add User", "http://jabber.org/protocol/admin#add-user", add_user_command_handler, "admin");
local change_user_password_desc = adhoc_new("Change User Password", "http://jabber.org/protocol/admin#change-user-password", change_user_password_command_handler, "admin");
local delete_user_desc = adhoc_new("Delete User", "http://jabber.org/protocol/admin#delete-user", delete_user_command_handler, "admin");
local get_user_password_desc = adhoc_new("Get User Password", "http://jabber.org/protocol/admin#get-user-password", get_user_password_handler, "admin");
local get_online_users_desc = adhoc_new("Get List of Online Users", "http://jabber.org/protocol/admin#get-online-users", get_online_users_command_handler, "admin"); 
local announce_desc = adhoc_new("Send Announcement to Online Users", "http://jabber.org/protocol/admin#announce", announce_handler, "admin");

module:add_item("adhoc", add_user_desc);
module:add_item("adhoc", change_user_password_desc);
module:add_item("adhoc", delete_user_desc);
module:add_item("adhoc", get_user_password_desc);
module:add_item("adhoc", get_online_users_desc);
module:add_item("adhoc", announce_desc);
