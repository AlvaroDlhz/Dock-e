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

/**
 * Everything the dock needs from the windowing system goes through this
 * namespace.  Only the backends below lib/Platform/ know which display
 * server is running; the rest of the dock asks for capabilities instead.
 *
 * See docs/x11-aislamiento.md for the plan behind these interfaces.
 */
namespace Plank.Platform
{
	public enum BackendKind
	{
		X11,
		WAYLAND
	}

	/**
	 * What a backend is able to do.  The UI hides or degrades the features a
	 * backend lacks instead of asking which display server is running.
	 */
	[Flags]
	public enum Capability
	{
		/** List of windows with actions on them */
		TOPLEVELS,
		/** Position and size of foreign windows */
		TOPLEVEL_GEOMETRY,
		TOPLEVEL_PID,
		STACKING_ORDER,
		/** An icon per window; otherwise the one of the .desktop file is used */
		WINDOW_ICONS,
		THUMBNAILS,
		WORKSPACES,
		/** Which workspace each window belongs to */
		WINDOW_WORKSPACE,
		SHOW_DESKTOP,
		/** Target of the minimize animation */
		ICON_GEOMETRY,
		/** Struts or exclusive zone */
		RESERVE_SPACE,
		/** Pressure barriers at the screen edge */
		EDGE_PRESSURE,
		GLOBAL_SUPER_KEY,
		/** Pointer position outside of our own windows */
		GLOBAL_POINTER,
		/** move () to global coordinates */
		ABSOLUTE_PLACEMENT
	}

	/**
	 * The entry point of a windowing system backend.
	 */
	public interface Backend : Object
	{
		public abstract BackendKind kind { get; }
		public abstract Capability capabilities { get; }

		/**
		 * Whether this backend supports the given capability.
		 */
		public bool has (Capability capability)
		{
			return (capability in capabilities);
		}
	}

	static Backend? backend = null;
	static bool backend_probed = false;

	/**
	 * Returns the backend for the default display, or null if there is no
	 * backend for it.  The backend is created on the first call.
	 */
	public Backend? get_backend ()
	{
		if (backend_probed)
			return backend;

		backend_probed = true;

		unowned Gdk.Display? display = Gdk.Display.get_default ();
		if (display is Gdk.X11.Display)
			backend = new X11Backend ((Gdk.X11.Display) display);

		return backend;
	}
}
