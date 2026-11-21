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
	 * The X11 backend: Wnck, BAMF, Xlib, XDamage, XFixes and XInput live
	 * below lib/Platform/X11/ and nowhere else.
	 */
	public class X11Backend : Object, Backend
	{
		public BackendKind kind { get { return BackendKind.X11; } }

		public Capability capabilities { get { return supported; } }

		public Gdk.X11.Display display { get; construct; }

		Capability supported;

		public X11Backend (Gdk.X11.Display display)
		{
			Object (display : display);
		}

		construct
		{
			supported = Capability.TOPLEVELS
				| Capability.TOPLEVEL_GEOMETRY
				| Capability.TOPLEVEL_PID
				| Capability.STACKING_ORDER
				| Capability.WINDOW_ICONS
				| Capability.THUMBNAILS
				| Capability.WORKSPACES
				| Capability.WINDOW_WORKSPACE
				| Capability.SHOW_DESKTOP
				| Capability.ICON_GEOMETRY
				| Capability.RESERVE_SPACE
				| Capability.GLOBAL_SUPER_KEY
				| Capability.GLOBAL_POINTER
				| Capability.ABSOLUTE_PLACEMENT;
#if HAVE_BARRIERS
			supported |= Capability.EDGE_PRESSURE;
#endif
		}

		public void log_details ()
		{
			message ("Wnck version: %d.%d.%d", Wnck.Version.MAJOR_VERSION, Wnck.Version.MINOR_VERSION, Wnck.Version.MICRO_VERSION);
#if HAVE_BARRIERS
			message ("+ XInput Barriers support enabled");
#endif
		}

		public SuperKeyTrigger? create_super_key_trigger ()
		{
			return new X11SuperKeyTrigger (display);
		}

		public DockSurface create_dock_surface (Gtk.Window dock)
		{
			return new X11DockSurface (dock);
		}

		X11ToplevelManager? toplevel_manager = null;
		X11WorkspaceManager? workspace_manager = null;

		// Created lazily: Wnck must not be touched before WindowControl
		// made us a pager
		public ToplevelManager toplevels { get { return ensure_toplevels (); } }

		public WorkspaceManager? workspaces {
			get {
				if (workspace_manager == null)
					workspace_manager = new X11WorkspaceManager (Wnck.Screen.get_default ());
				return workspace_manager;
			}
		}

		/**
		 * The X11 view of {@link toplevels}, for the parts of the X11 backend
		 * which start from an XID.
		 */
		public X11ToplevelManager x11_toplevels { get { return ensure_toplevels (); } }

		unowned X11ToplevelManager ensure_toplevels ()
		{
			if (toplevel_manager == null)
				toplevel_manager = new X11ToplevelManager (Wnck.Screen.get_default ());
			return toplevel_manager;
		}

		public EdgeTrigger? create_edge_trigger (Gtk.Window dock)
		{
#if HAVE_BARRIERS
			return X11EdgeTrigger.try_create (display);
#else
			return null;
#endif
		}
	}
}
