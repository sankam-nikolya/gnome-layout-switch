// GNOME Shell extension that exposes a small, safe D-Bus API for cycling
// input sources. Used by the gnome-layout-switch daemon.
//
// Methods (org.gnome.Shell.Extensions.GnomeLayoutSwitch):
//   Next()       -> u   switch to next layout, return new index
//   Previous()   -> u   switch to previous layout, return new index
//   GetCurrent() -> u   return current layout index
//
// Example:
//   gdbus call --session --dest org.gnome.Shell \
//     --object-path /org/gnome/Shell/Extensions/GnomeLayoutSwitch \
//     --method org.gnome.Shell.Extensions.GnomeLayoutSwitch.Next

import Gio from 'gi://Gio';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Keyboard from 'resource:///org/gnome/shell/ui/status/keyboard.js';

const IFACE = `
<node>
  <interface name="org.gnome.Shell.Extensions.GnomeLayoutSwitch">
    <method name="Next">
      <arg type="u" name="index" direction="out"/>
    </method>
    <method name="Previous">
      <arg type="u" name="index" direction="out"/>
    </method>
    <method name="GetCurrent">
      <arg type="u" name="index" direction="out"/>
    </method>
  </interface>
</node>`;

class LayoutSwitchService {
    get _manager() {
        return Keyboard.getInputSourceManager();
    }

    get _sources() {
        const sources = this._manager.inputSources;
        return Object.keys(sources)
            .map(k => sources[k])
            .sort((a, b) => a.index - b.index);
    }

    GetCurrent() {
        return this._manager.currentSource?.index ?? 0;
    }

    Next() {
        const sources = this._sources;
        if (sources.length === 0)
            return 0;
        const next = (this.GetCurrent() + 1) % sources.length;
        sources[next].activate(true);
        return next;
    }

    Previous() {
        const sources = this._sources;
        if (sources.length === 0)
            return 0;
        const prev = (this.GetCurrent() - 1 + sources.length) % sources.length;
        sources[prev].activate(true);
        return prev;
    }
}

export default class GnomeLayoutSwitchExtension extends Extension {
    enable() {
        this._dbus = Gio.DBusExportedObject.wrapJSObject(
            IFACE, new LayoutSwitchService());
        this._dbus.export(
            Gio.DBus.session,
            '/org/gnome/Shell/Extensions/GnomeLayoutSwitch');
    }

    disable() {
        this._dbus?.unexport();
        this._dbus = null;
    }
}
