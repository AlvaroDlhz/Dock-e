//
// Global Super-key binding for Dock-E on X11.
//

namespace Plank.Platform
{
	/**
	 * Owns a passive X11 grab for the left and right Super keys.
	 *
	 * The keyboard stays frozen only until the next keyboard event.  Releasing
	 * Super without pressing another key activates the binding; any other key
	 * is replayed so shortcuts such as Super+L keep working normally.
	 */
	public class X11SuperKeyTrigger : Object, SuperKeyTrigger
	{
		const uint[] IGNORED_MODIFIER_COMBINATIONS = {
			0U,
			(uint) X.KeyMask.LockMask,
			(uint) X.KeyMask.Mod2Mask,
			(uint) (X.KeyMask.LockMask | X.KeyMask.Mod2Mask)
		};

		unowned Gdk.X11.Display x11_display;
		unowned X.Display xdisplay;
		X.Window root;
		uint left_keycode;
		uint right_keycode;
		bool installed = false;
		bool super_pending = false;

		public bool available { get { return installed; } }

		public X11SuperKeyTrigger (Gdk.X11.Display display)
		{
			x11_display = display;

			xdisplay = x11_display.get_xdisplay ();
			root = xdisplay.default_root_window ();
			left_keycode = xdisplay.keysym_to_keycode (X.string_to_keysym ("Super_L"));
			right_keycode = xdisplay.keysym_to_keycode (X.string_to_keysym ("Super_R"));
			if (left_keycode == 0U && right_keycode == 0U) {
				warning ("No Super key was found in the current X11 keymap");
				return;
			}

			x11_display.error_trap_push ();
			grab_keycode (left_keycode);
			if (right_keycode != left_keycode)
				grab_keycode (right_keycode);
			xdisplay.flush ();
			var error = x11_display.error_trap_pop ();
			if (error != 0) {
				ungrab_keys ();
				warning ("Dock-E could not claim the Super key; remove the desktop's existing Super-only shortcut and restart Dock-E");
				return;
			}

			installed = true;
			gdk_window_add_filter (null, (Gdk.FilterFunc) xevent_filter);
		}

		~X11SuperKeyTrigger ()
		{
			if (!installed)
				return;
			gdk_window_remove_filter (null, (Gdk.FilterFunc) xevent_filter);
			ungrab_keys ();
		}

		void grab_keycode (uint keycode)
		{
			if (keycode == 0U)
				return;
			foreach (var modifiers in IGNORED_MODIFIER_COMBINATIONS)
				xdisplay.grab_key ((int) keycode, modifiers, root, false,
					X.GrabMode.Async, X.GrabMode.Sync);
		}

		void ungrab_keys ()
		{
			foreach (var modifiers in IGNORED_MODIFIER_COMBINATIONS) {
				if (left_keycode != 0U)
					xdisplay.ungrab_key ((int) left_keycode, modifiers, root);
				if (right_keycode != 0U && right_keycode != left_keycode)
					xdisplay.ungrab_key ((int) right_keycode, modifiers, root);
			}
			xdisplay.flush ();
		}

		bool is_super_key (uint keycode)
		{
			return keycode == left_keycode || keycode == right_keycode;
		}

		[CCode (instance_pos = -1)]
		Gdk.FilterReturn xevent_filter (Gdk.XEvent gdk_xevent, Gdk.Event? gdk_event)
		{
			X.Event* xevent = (X.Event*) gdk_xevent;
			if (xevent.type != X.EventType.KeyPress && xevent.type != X.EventType.KeyRelease)
				return Gdk.FilterReturn.CONTINUE;

			X.KeyEvent* key = &xevent.xkey;
			if (!super_pending) {
				if (xevent.type != X.EventType.KeyPress || !is_super_key (key.keycode))
					return Gdk.FilterReturn.CONTINUE;
				super_pending = true;
				xdisplay.allow_events (X.AllowEventsMode.SyncKeyboard, (int) key.time);
				xdisplay.flush ();
				return Gdk.FilterReturn.REMOVE;
			}

			if (is_super_key (key.keycode) && xevent.type == X.EventType.KeyRelease) {
				super_pending = false;
				xdisplay.allow_events (X.AllowEventsMode.AsyncKeyboard, (int) key.time);
				xdisplay.flush ();
				var time = (uint32) key.time;
				Idle.add (() => {
					activated (time);
					return false;
				});
				return Gdk.FilterReturn.REMOVE;
			}

			if (is_super_key (key.keycode) && xevent.type == X.EventType.KeyPress) {
				xdisplay.allow_events (X.AllowEventsMode.SyncKeyboard, (int) key.time);
				xdisplay.flush ();
				return Gdk.FilterReturn.REMOVE;
			}

			// Another key makes this a regular desktop shortcut.  Reprocess that
			// event with its original Mod4 state and release our passive grab.
			super_pending = false;
			xdisplay.allow_events (X.AllowEventsMode.ReplayKeyboard, (int) key.time);
			xdisplay.flush ();
			return Gdk.FilterReturn.REMOVE;
		}
	}
}
