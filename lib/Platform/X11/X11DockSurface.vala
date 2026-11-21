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

namespace Plank.Platform
{
	/**
	 * The dock window as an X11 client: _NET_WM_STRUT_PARTIAL reserves its
	 * space.
	 */
	public class X11DockSurface : Object, DockSurface
	{
		// The order of _NET_WM_STRUT_PARTIAL; _NET_WM_STRUT is its first four values
		enum Strut
		{
			LEFT,
			RIGHT,
			TOP,
			BOTTOM,
			LEFT_START,
			LEFT_END,
			RIGHT_START,
			RIGHT_END,
			TOP_START,
			TOP_END,
			BOTTOM_START,
			BOTTOM_END,
			N_VALUES
		}

		unowned Gtk.Window dock;

		public X11DockSurface (Gtk.Window dock)
		{
			this.dock = dock;
		}

		public void reserve (Gtk.PositionType edge, Gdk.Rectangle area, int thickness)
		{
			if (!dock.get_realized ())
				return;

			unowned Gdk.X11.Display gdk_display = (dock.get_display () as Gdk.X11.Display);
			if (gdk_display == null)
				return;

			unowned Gdk.X11.Window gdk_window = (dock.get_window () as Gdk.X11.Window);
			if (gdk_window == null)
				return;

			var struts = new ulong [Strut.N_VALUES];

			if (thickness > 0)
				compute_struts (dock.get_screen (), gdk_window.get_scale_factor (), edge, area, thickness, struts);

			var first_struts = new ulong [Strut.BOTTOM + 1];
			for (var i = 0; i < first_struts.length; i++)
				first_struts [i] = struts [i];

			unowned X.Display display = gdk_display.get_xdisplay ();
			var xid = gdk_window.get_xid ();

			gdk_display.error_trap_push ();
			display.change_property (xid, display.intern_atom ("_NET_WM_STRUT_PARTIAL", false), X.XA_CARDINAL,
			                      32, X.PropMode.Replace, (uchar[]) struts, struts.length);
			display.change_property (xid, display.intern_atom ("_NET_WM_STRUT", false), X.XA_CARDINAL,
			                      32, X.PropMode.Replace, (uchar[]) first_struts, first_struts.length);
			if (gdk_display.error_trap_pop () != X.Success)
				critical ("Error while setting struts");
		}

		/**
		 * Struts are measured from the edges of the whole X screen and in
		 * device pixels, while the dock knows logical pixels inside area.
		 */
		static void compute_struts (Gdk.Screen screen, int scale, Gtk.PositionType edge,
			Gdk.Rectangle area, int thickness, ulong[] struts)
		{
			switch (edge) {
			default:
			case Gtk.PositionType.BOTTOM:
				struts [Strut.BOTTOM] = (thickness + screen.get_height () - area.y - area.height) * scale;
				struts [Strut.BOTTOM_START] = area.x * scale;
				struts [Strut.BOTTOM_END] = (area.x + area.width) * scale - 1;
				break;
			case Gtk.PositionType.TOP:
				struts [Strut.TOP] = (area.y + thickness) * scale;
				struts [Strut.TOP_START] = area.x * scale;
				struts [Strut.TOP_END] = (area.x + area.width) * scale - 1;
				break;
			case Gtk.PositionType.LEFT:
				struts [Strut.LEFT] = (area.x + thickness) * scale;
				struts [Strut.LEFT_START] = area.y * scale;
				struts [Strut.LEFT_END] = (area.y + area.height) * scale - 1;
				break;
			case Gtk.PositionType.RIGHT:
				struts [Strut.RIGHT] = (thickness + screen.get_width () - area.x - area.width) * scale;
				struts [Strut.RIGHT_START] = area.y * scale;
				struts [Strut.RIGHT_END] = (area.y + area.height) * scale - 1;
				break;
			}
		}
	}
}
