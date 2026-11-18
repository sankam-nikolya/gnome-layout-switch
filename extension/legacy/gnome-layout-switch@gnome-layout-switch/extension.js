// GNOME Shell extension — D-Bus API for cycling input sources.
// Compatible with GNOME Shell 42–44 (legacy imports).
//
// Methods (org.gnome.Shell.Extensions.GnomeLayoutSwitch):
//   Next()       -> u
//   Previous()   -> u
//   GetCurrent() -> u
//
// Example:
//   gdbus call --session --dest org.gnome.Shell \
//     --object-path /org/gnome/Shell/Extensions/GnomeLayoutSwitch \
//     --method org.gnome.Shell.Extensions.GnomeLayoutSwitch.Next

const Gio = imports.gi.Gio;
const Keyboard = imports.ui.status.keyboard;

const IFACE =
'<node>' +
'  <interface name="org.gnome.Shell.Extensions.GnomeLayoutSwitch">' +
'    <method name="Next">' +
'      <arg type="u" name="index" direction="out"/>' +
'    </method>' +
'    <method name="Previous">' +
'      <arg type="u" name="index" direction="out"/>' +
'    </method>' +
'    <method name="GetCurrent">' +
'      <arg type="u" name="index" direction="out"/>' +
'    </method>' +
'  </interface>' +
'</node>';

function getManager() {
    return Keyboard.getInputSourceManager();
}

function getSources() {
    const manager = getManager();
    const sources = manager.inputSources;
    const list = [];
    const keys = Object.keys(sources);
    for (let i = 0; i < keys.length; i++) {
        list.push(sources[keys[i]]);
    }
    list.sort(function (a, b) {
        return a.index - b.index;
    });
    return list;
}

const LayoutSwitchService = {
    GetCurrent: function () {
        const manager = getManager();
        if (manager.currentSource)
            return manager.currentSource.index;
        return 0;
    },

    Next: function () {
        const sources = getSources();
        if (sources.length === 0)
            return 0;
        const next = (this.GetCurrent() + 1) % sources.length;
        sources[next].activate(true);
        return next;
    },

    Previous: function () {
        const sources = getSources();
        if (sources.length === 0)
            return 0;
        const prev = (this.GetCurrent() - 1 + sources.length) % sources.length;
        sources[prev].activate(true);
        return prev;
    },
};

let _dbus = null;

function enable() {
    _dbus = Gio.DBusExportedObject.wrapJSObject(IFACE, LayoutSwitchService);
    _dbus.export(Gio.DBus.session, '/org/gnome/Shell/Extensions/GnomeLayoutSwitch');
}

function disable() {
    if (_dbus) {
        _dbus.unexport();
        _dbus = null;
    }
}

function init() {
    // nothing to do at load time
}
