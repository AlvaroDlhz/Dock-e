//
// Scaled-down pictures of other applications' windows on X11.
//

namespace Plank.Platform
{
	/**
	 * Keeps a small picture of each window which is asked for, and takes a
	 * new one only after the window has actually painted something.
	 *
	 * Reading a window means copying all of its pixels from the X server, so
	 * doing that on a timer costs the same whether anything changed or not.
	 * The X Damage extension reports the changes instead.
	 */
	public class X11WindowThumbnailer : GLib.Object, WindowThumbnailer
	{
		// A window which keeps painting, like a video, is read this often at most
		const uint REFRESH_INTERVAL = 250U;
		// How often every window is read again where changes are not reported
		const uint POLL_INTERVAL = 750U;

		class Entry
		{
			public Toplevel toplevel;
			public Gdk.Pixbuf? pixbuf;
			// The window changed since the picture was taken
			public bool stale = true;
#if HAVE_XDAMAGE
			public XDamage.Damage damage;
#endif
		}

		int width;
		int height;
		Gee.HashMap<uint, Entry> entries;
		Gee.HashSet<uint> pending;
		uint notify_timer_id = 0U;
		uint poll_timer_id = 0U;
		bool changes_reported = false;
#if HAVE_XDAMAGE
		int damage_event = 0;
#endif

		/**
		 * @param width the most room a picture gets, which it is fit into
		 * @param height the most room a picture gets, which it is fit into
		 */
		public X11WindowThumbnailer (int width, int height)
		{
			this.width = width;
			this.height = height;
			entries = new Gee.HashMap<uint, Entry> ();
			pending = new Gee.HashSet<uint> ();
#if HAVE_XDAMAGE
			unowned X.Display? display = get_xdisplay ();
			int error_base;
			if (display != null && XDamage.query_extension (display, out damage_event, out error_base)) {
				changes_reported = true;
				gdk_window_add_filter (null, (Gdk.FilterFunc) xevent_filter);
			}
#endif
		}

		~X11WindowThumbnailer ()
		{
			clear ();
#if HAVE_XDAMAGE
			if (changes_reported)
				gdk_window_remove_filter (null, (Gdk.FilterFunc) xevent_filter);
#endif
		}

		public Gdk.Pixbuf? lookup (Toplevel toplevel)
		{
			var xid = (uint32) toplevel.id;
			Entry? entry = entries[xid];
			if (entry == null) {
				entry = new Entry ();
				entry.toplevel = toplevel;
				entries[xid] = entry;
				watch (xid, entry);
			}
			if (entry.stale) {
				entry.stale = false;
				// Before reading, so what is painted meanwhile is reported again
				acknowledge (entry);
				entry.pixbuf = capture (xid);
			}
			return entry.pixbuf;
		}

		public void clear ()
		{
			if (notify_timer_id > 0U) {
				Source.remove (notify_timer_id);
				notify_timer_id = 0U;
			}
			if (poll_timer_id > 0U) {
				Source.remove (poll_timer_id);
				poll_timer_id = 0U;
			}
			pending.clear ();
#if HAVE_XDAMAGE
			if (changes_reported && entries.size > 0) {
				unowned X.Display? display = get_xdisplay ();
				if (display != null) {
					// A window which was closed took its damage object along
					Gdk.error_trap_push ();
					foreach (var entry in entries.values)
						if (entry.damage != 0)
							XDamage.destroy (display, entry.damage);
					Gdk.error_trap_pop_ignored ();
				}
			}
#endif
			entries.clear ();
		}

		Gdk.Pixbuf? capture (uint32 xid)
		{
			unowned Gdk.X11.Display? display = Gdk.Display.get_default () as Gdk.X11.Display;
			if (display == null)
				return null;
			Gdk.Pixbuf? pixbuf = null;
			Gdk.error_trap_push ();
			var foreign = new Gdk.X11.Window.foreign_for_display (display, (X.Window) xid);
			if (foreign != null) {
				var window_width = foreign.get_width ();
				var window_height = foreign.get_height ();
				if (window_width > 1 && window_height > 1)
					pixbuf = Gdk.pixbuf_get_from_window (foreign, 0, 0, window_width, window_height);
			}
			Gdk.error_trap_pop_ignored ();
			if (pixbuf == null)
				return null;
			// Fit into the room there is, keeping the proportions of the window
			var scale = double.min ((double) width / pixbuf.width, (double) height / pixbuf.height);
			if (scale == 1.0)
				return pixbuf;
			return pixbuf.scale_simple (int.max (1, (int) (pixbuf.width * scale)),
				int.max (1, (int) (pixbuf.height * scale)), Gdk.InterpType.HYPER);
		}

		void watch (uint32 xid, Entry entry)
		{
#if HAVE_XDAMAGE
			if (changes_reported) {
				unowned X.Display? display = get_xdisplay ();
				if (display != null) {
					Gdk.error_trap_push ();
					entry.damage = XDamage.create (display, (X.Drawable) xid,
						XDamage.REPORT_NON_EMPTY);
					Gdk.error_trap_pop_ignored ();
				}
				return;
			}
#endif
			if (poll_timer_id == 0U)
				poll_timer_id = Timeout.add (POLL_INTERVAL, poll);
		}

		void acknowledge (Entry entry)
		{
#if HAVE_XDAMAGE
			if (!changes_reported || entry.damage == 0)
				return;
			unowned X.Display? display = get_xdisplay ();
			if (display == null)
				return;
			// Changes are reported once and then held back until this is done,
			// so a busy window cannot flood the dock with events
			Gdk.error_trap_push ();
			XDamage.subtract (display, entry.damage, 0UL, 0UL);
			Gdk.error_trap_pop_ignored ();
#endif
		}

		bool poll ()
		{
			foreach (var item in entries.entries) {
				item.value.stale = true;
				pending.add (item.key);
			}
			announce ();
			return true;
		}

		void mark_changed (uint xid, Entry entry)
		{
			if (entry.stale)
				return;
			entry.stale = true;
			pending.add (xid);
			if (notify_timer_id > 0U)
				return;
			notify_timer_id = Timeout.add (REFRESH_INTERVAL, () => {
				notify_timer_id = 0U;
				announce ();
				return false;
			});
		}

		void announce ()
		{
			// A handler may forget every window while it is being told
			var xids = pending.to_array ();
			pending.clear ();
			foreach (var xid in xids) {
				Entry? entry = entries[xid];
				if (entry != null)
					changed (entry.toplevel);
			}
		}

		static unowned X.Display? get_xdisplay ()
		{
			unowned Gdk.X11.Display? display = Gdk.Display.get_default () as Gdk.X11.Display;
			return display == null ? null : display.get_xdisplay ();
		}

#if HAVE_XDAMAGE
		[CCode (instance_pos = -1)]
		Gdk.FilterReturn xevent_filter (Gdk.XEvent gdk_xevent, Gdk.Event gdk_event)
		{
			X.Event* xevent = (X.Event*) gdk_xevent;
			if (xevent.type != damage_event + XDamage.NOTIFY)
				return Gdk.FilterReturn.CONTINUE;
			XDamage.NotifyEvent* notify = (XDamage.NotifyEvent*) gdk_xevent;
			foreach (var item in entries.entries) {
				if (item.value.damage == notify.damage) {
					mark_changed (item.key, item.value);
					// Nobody else has a use for the event of this damage object
					return Gdk.FilterReturn.REMOVE;
				}
			}
			return Gdk.FilterReturn.CONTINUE;
		}
#endif
	}
}
