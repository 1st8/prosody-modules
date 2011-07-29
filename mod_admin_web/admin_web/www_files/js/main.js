var BOSH_SERVICE = '/http-bind/';
var show_log = false;

Strophe.addNamespace('C2SSTREAM', 'http://prosody.im/streams/c2s');
Strophe.addNamespace('S2SSTREAM', 'http://prosody.im/streams/s2s');
Strophe.addNamespace('ADMINSUB', 'http://prosody.im/adminsub');
Strophe.addNamespace('CAPS', 'http://jabber.org/protocol/caps');

var localJID = null;
var connection   = null;

var adminsubHost = null;

function log(msg) {
    var entry = $('<div></div>').append(document.createTextNode(msg));
    $('#log').append(entry);
}

function rawInput(data) {
    log('RECV: ' + data);
}

function rawOutput(data) {
    log('SENT: ' + data);
}

function _cbNewS2S(e) {
    var items, entry, tmp, retract, id, jid;
    items = e.getElementsByTagName('item');
    for (i = 0; i < items.length; i++) {
        id = items[i].attributes['id'].value;
        jid = items[i].getElementsByTagName('session')[0].attributes['jid'].value;

        entry = $('<li id="' + id + '">' + jid + '</li>');
        if (tmp = items[i].getElementsByTagName('encrypted')[0]) {
            if (tmp.getElementsByTagName('valid')[0]) {
                entry.append('<img src="images/secure.png" title="encrypted (certificate valid)" alt=" (secure) (encrypted)" />');
            } else {
                entry.append('<img src="images/encrypted.png" title="encrypted (certificate invalid)" alt=" (encrypted)" />');
            }
        }
        if (items[i].getElementsByTagName('compressed')[0]) {
            entry.append('<img src="images/compressed.png" title="compressed" alt=" (compressed)" />');
        }

        if (items[i].getElementsByTagName('out')[0]) {
            entry.appendTo('#s2sout');
        } else {
            entry.appendTo('#s2sin');
        }
    }
    retract = e.getElementsByTagName('retract')[0];
    if (retract) {
        id = retract.attributes['id'].value;
        $('#' + id).remove();
    }
    return true;
}

function _cbNewC2S(e) {
    var items, entry, retract, id, jid;
    items = e.getElementsByTagName('item');
    for (i = 0; i < items.length; i++) {
        id = items[i].attributes['id'].value;
        jid = items[i].getElementsByTagName('session')[0].attributes['jid'].value;
        entry = $('<li id="' + id + '">' + jid + '</li>');
        if (items[i].getElementsByTagName('encrypted')[0]) {
            entry.append('<img src="images/encrypted.png" title="encrypted" alt=" (encrypted)" />');
        }
        if (items[i].getElementsByTagName('compressed')[0]) {
            entry.append('<img src="images/compressed.png" title="compressed" alt=" (compressed)" />');
        }
        entry.appendTo('#c2s');
    }
    retract = e.getElementsByTagName('retract')[0];
    if (retract) {
        id = retract.attributes['id'].value;
        $('#' + id).remove();
    }
    return true;
}

function _cbAdminSub(e) {
    var node = e.getElementsByTagName('items')[0].attributes['node'].value;
    if (node == Strophe.NS.C2SSTREAM) {
        _cbNewC2S(e);
    } else if (node == Strophe.NS.S2SSTREAM) {
        _cbNewS2S(e);
    }

    return true;
}

function onConnect(status) {
    if (status == Strophe.Status.CONNECTING) {
        log('Strophe is connecting.');
    } else if (status == Strophe.Status.CONNFAIL) {
        log('Strophe failed to connect.');
        showConnect();
    } else if (status == Strophe.Status.DISCONNECTING) {
        log('Strophe is disconnecting.');
    } else if (status == Strophe.Status.DISCONNECTED) {
        log('Strophe is disconnected.');
        showConnect();
    } else if (status == Strophe.Status.AUTHFAIL) {
        log('Authentication failed');
        if (connection) {
            connection.disconnect();
        }
    } else if (status == Strophe.Status.CONNECTED) {
        log('Strophe is connected.');
        connection.sendIQ($iq({to: connection.domain, type: 'get', id: connection.getUniqueId()}).c('adminsub', {xmlns: Strophe.NS.ADMINSUB})
            .c('adminfor'), function(e) {
                var items;
                items = e.getElementsByTagName('item');
                if (items.length == 0) {
                    alert("You are not an administrator");
                    connection.disconnect();
                    return false;
                }
                for (i = 0; i < items.length; i++) {
                    $('#host').append('<option>' + $(items[i]).text() + '</option>');
                }
                showDisconnect();
                adminsubHost = $(items[0]).text();
                Adhoc.checkFeatures('#adhoc', adminsubHost);
                connection.addHandler(_cbAdminSub, Strophe.NS.ADMINSUB + '#event', 'message');
                connection.send($iq({to: adminsubHost, type: 'set', id: connection.getUniqueId()}).c('adminsub', {xmlns: Strophe.NS.ADMINSUB})
                    .c('subscribe', {node: Strophe.NS.C2SSTREAM}));
                connection.send($iq({to: adminsubHost, type: 'set', id: connection.getUniqueId()}).c('adminsub', {xmlns: Strophe.NS.ADMINSUB})
                    .c('subscribe', {node: Strophe.NS.S2SSTREAM}));
                connection.sendIQ($iq({to: adminsubHost, type: 'get', id: connection.getUniqueId()}).c('adminsub', {xmlns: Strophe.NS.ADMINSUB})
                    .c('items', {node: Strophe.NS.S2SSTREAM}), _cbNewS2S);
                connection.sendIQ($iq({to: adminsubHost, type: 'get', id: connection.getUniqueId()}).c('adminsub', {xmlns: Strophe.NS.ADMINSUB})
                    .c('items', {node: Strophe.NS.C2SSTREAM}), _cbNewC2S);
        });
    }
}

function showConnect() {
    var jid = $('#jid');
    var pass = $('#pass');
    var button = $('#connect').get(0);

    button.value = 'connect';
    pass.show();
    jid.show();
    $('#menu').hide();
    $('#right').hide();
    $('#cred label').show();
    $('#cred br').show();
    $('#s2sin').empty();
    $('#s2sout').empty();
    $('#c2s').empty();
    $('#host').empty();
}

function showDisconnect() {
    var jid = $('#jid');
    var pass = $('#pass');
    var button = $('#connect').get(0);

    button.value = 'disconnect';
    pass.hide();
    jid.hide();
    $('#menu').show();
    $('#right').show();
    $('#adhoc').show();
    $('#s2sList').hide();
    $('#c2sList').hide();
    $('#cred label').hide();
    $('#cred br').hide();
}

$(document).ready(function () {
    connection = new Strophe.Connection(BOSH_SERVICE);
    if (show_log) {
        $('#log_container').show();
        connection.rawInput = rawInput;
        connection.rawOutput = rawOutput;
    }

    $("#log_toggle").click(function () {
        $("#log").toggle();
    });

    $('#cred').bind('submit', function (event) {
        var button = $('#connect').get(0);
        var jid = $('#jid');
        var pass = $('#pass');
        localJID = jid.get(0).value;

        if (button.value == 'connect') {
            $('#log').empty();
            connection.connect(localJID, pass.get(0).value, onConnect);
        } else {
            connection.disconnect();
        }
        event.preventDefault();
    });

    $('#adhocMenu').click(function (event) {
        $('#s2sList').slideUp();
        $('#c2sList').slideUp();
        $('#adhoc').slideDown();
        event.preventDefault();
    });

    $('#serverMenu').click(function (event) {
        $('#adhoc').slideUp();
        $('#c2sList').slideUp();
        $('#s2sList').slideDown();
        event.preventDefault();
    });

    $('#clientMenu').click(function (event) {
        $('#adhoc').slideUp();
        $('#s2sList').slideUp();
        $('#c2sList').slideDown();
        event.preventDefault();
    });

    $('#host').bind('change', function (event) {
        connection.send($iq({to: adminsubHost, type: 'set', id: connection.getUniqueId()}).c('adminsub', {xmlns: Strophe.NS.ADMINSUB})
            .c('unsubscribe', {node: Strophe.NS.C2SSTREAM}));
        connection.send($iq({to: adminsubHost, type: 'set', id: connection.getUniqueId()}).c('adminsub', {xmlns: Strophe.NS.ADMINSUB})
            .c('unsubscribe', {node: Strophe.NS.S2SSTREAM}));
        adminsubHost = $(this).val();
        Adhoc.checkFeatures('#adhoc', adminsubHost);
        $('#s2sin').empty();
        $('#s2sout').empty();
        $('#c2s').empty();
        connection.send($iq({to: adminsubHost, type: 'set', id: connection.getUniqueId()}).c('adminsub', {xmlns: Strophe.NS.ADMINSUB})
            .c('subscribe', {node: Strophe.NS.C2SSTREAM}));
        connection.send($iq({to: adminsubHost, type: 'set', id: connection.getUniqueId()}).c('adminsub', {xmlns: Strophe.NS.ADMINSUB})
            .c('subscribe', {node: Strophe.NS.S2SSTREAM}));
        connection.sendIQ($iq({to: adminsubHost, type: 'get', id: connection.getUniqueId()}).c('adminsub', {xmlns: Strophe.NS.ADMINSUB})
            .c('items', {node: Strophe.NS.S2SSTREAM}), _cbNewS2S);
        connection.sendIQ($iq({to: adminsubHost, type: 'get', id: connection.getUniqueId()}).c('adminsub', {xmlns: Strophe.NS.ADMINSUB})
            .c('items', {node: Strophe.NS.C2SSTREAM}), _cbNewC2S);
    });
});

window.onunload = window.onbeforeunload = function() {
    if (connection) {
        connection.disconnect();
    }
}
