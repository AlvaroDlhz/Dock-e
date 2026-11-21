//
//  Copyright (C) 2026 Dock-E
//
//  This file is part of Plank.
//
//  Plank is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Plank is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

#if HAVE_BARRIERS
namespace Plank.Platform
{
	/**
	 * A pointer barrier of XFixes whose events arrive through XInput 2.3.
	 */
	public class X11EdgeTrigger : Object, EdgeTrigger
	{
		unowned Gdk.X11.Display gdk_display;
		XFixes.PointerBarrier barrier = 0;
		int opcode = 0;

		/**
		 * Creates a trigger if the X server supports barriers.
		 *
		 * @return null without XInput 2.3
		 */
		public static X11EdgeTrigger? try_create (Gdk.X11.Display gdk_display)
		{
			unowned X.Display display = gdk_display.get_xdisplay ();
			int opcode, error_base, first_event_return;

			if (!display.query_extension ("XInputExtension", out opcode, out first_event_return, out error_base)) {
				debug ("Barriers disabled (XInput needed)");
				return null;
			}

			int major = 2, minor = 3;
			var has_xinput = (XInput.query_version (display, ref major, ref minor) == X.Success);
			if (!(has_xinput && major >= 2 && minor >= 3)) {
				debug ("Barriers disabled (XInput %i.%i not sufficient)", major, minor);
				return null;
			}

			message ("Barriers enabled (XInput %i.%i support)\n", major, minor);
			return new X11EdgeTrigger (gdk_display, opcode);
		}

		X11EdgeTrigger (Gdk.X11.Display gdk_display, int opcode)
		{
			this.gdk_display = gdk_display;
			this.opcode = opcode;
			gdk_window_add_filter (null, (Gdk.FilterFunc) xevent_filter);
		}

		~X11EdgeTrigger ()
		{
			gdk_window_remove_filter (null, (Gdk.FilterFunc) xevent_filter);
			clear ();
		}

		public void clear ()
		{
			if (barrier == 0)
				return;

			XFixes.destroy_pointer_barrier (gdk_display.get_xdisplay (), barrier);
			barrier = 0;
		}

		public void set_edge (Gtk.PositionType edge, Gdk.Rectangle line)
		{
			clear ();

			unowned X.Display display = gdk_display.get_xdisplay ();
			var root_xwindow = display.default_root_window ();

			// Enable barrier events
			uchar[] mask_bits = new uchar[XInput.mask_length (XInput.EventType.LASTEVENT)];
			XInput.EventMask mask = { XInput.ALL_MASTER_DEVICES, (int) (sizeof (uchar) * mask_bits.length), (owned) mask_bits };
			XInput.set_mask (mask.mask, XInput.EventType.BARRIER_HIT);
			XInput.set_mask (mask.mask, XInput.EventType.BARRIER_LEAVE);
			XInput.select_events (display, root_xwindow, &mask, 1);

			debug ("Barrier: %i,%i - %i,%i\n", line.x, line.y, line.x + line.width, line.y + line.height);

			barrier = XFixes.create_pointer_barrier (
				display, root_xwindow,
				line.x, line.y, line.x + line.width,
				line.y + line.height,
				0,
				0, null);

			warn_if_fail (barrier > 0);
		}

		/**
		 * Event filter method needed to fetch X.Events
		 */
		[CCode (instance_pos = -1)]
		Gdk.FilterReturn xevent_filter (Gdk.XEvent gdk_xevent, Gdk.Event gdk_event)
		{
			X.Event* xevent = (X.Event*) gdk_xevent;
			X.GenericEventCookie* xcookie = &xevent.xcookie;
			unowned X.Display display = xcookie.display;

			// Did we got a barrier-event?
			if (barrier == 0
				|| (xcookie.extension != opcode)
				|| (xcookie.evtype != XInput.EventType.BARRIER_HIT && xcookie.evtype != XInput.EventType.BARRIER_LEAVE))
				return Gdk.FilterReturn.CONTINUE;

			X.get_event_data (display, xcookie);

			// Does it match our registered barrier?
			XInput.BarrierEvent* barrier_event = (XInput.BarrierEvent*) (xcookie.data);
			if (barrier_event.barrier != barrier) {
				X.free_event_data (display, xcookie);
				return Gdk.FilterReturn.CONTINUE;
			}

			switch (xcookie.evtype) {
			case XInput.EventType.BARRIER_HIT:
				hit (barrier_event.dx, barrier_event.dy, (uint32) barrier_event.time);
				break;
			case XInput.EventType.BARRIER_LEAVE:
				left ();
				break;
			default:
				break;
			}

			XInput.barrier_release_pointer (display, barrier_event.deviceid,
				barrier, barrier_event.eventid);

			display.flush ();

			X.free_event_data (display, xcookie);
			return Gdk.FilterReturn.REMOVE;
		}
	}
}
#endif
