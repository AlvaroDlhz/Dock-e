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
		 * Logs the versions and optional features of the libraries behind
		 * this backend, next to the rest of the startup information.
		 */
		public abstract void log_details ();

		/**
		 * Prepares the backend once at startup, before any dock exists.
		 */
		public abstract void initialize ();

		/**
		 * Claims the global Super key for one dock.  Every dock asks for its
		 * own trigger; only the first one gets the key on X11.
		 *
		 * @return null if the backend has no {@link Capability.GLOBAL_SUPER_KEY}
		 */
		public abstract SuperKeyTrigger? create_super_key_trigger ();

		/**
		 * Wraps the window of a dock.  The surface does not keep the window
		 * alive.
		 */
		public abstract DockSurface create_dock_surface (Gtk.Window dock);

		/**
		 * Shows the tooltips, previews and panels of the docks.
		 */
		public abstract PopupPlacer popups { get; }

		/**
		 * Creates a trigger for the screen edge the dock sits on.
		 *
		 * @return null if the backend has no {@link Capability.EDGE_PRESSURE}
		 *         or the display server lacks it at runtime
		 */
		public abstract EdgeTrigger? create_edge_trigger (Gtk.Window dock);

		/**
		 * The windows of other clients.  Created on first use.
		 */
		public abstract ToplevelManager toplevels { get; }

		/**
		 * The virtual desktops, or null without {@link Capability.WORKSPACES}.
		 * Created on first use.
		 */
		public abstract WorkspaceManager? workspaces { get; }

		/**
		 * Creates a cache of pictures of toplevels; each user has its own,
		 * with the size it shows them at.
		 *
		 * @param width the most room a picture gets
		 * @param height the most room a picture gets
		 * @return null without {@link Capability.THUMBNAILS}
		 */
		public abstract WindowThumbnailer? create_thumbnailer (int width, int height);

		/**
		 * The running applications.  Created on first use.
		 */
		public abstract AppTracker apps { get; }

		/**
		 * Whether this backend supports the given capability.
		 */
		public bool has (Capability capability)
		{
			return (capability in capabilities);
		}
	}

	/**
	 * Finds out which kind of display server the default display talks to,
	 * judging by the type of the {@link Gdk.Display} and not by environment
	 * variables.
	 *
	 * @param kind the kind of display server
	 * @return false if there is no display or it is of an unknown kind
	 */
	public bool detect_backend (out BackendKind kind)
	{
		kind = BackendKind.X11;

		unowned Gdk.Display? display = Gdk.Display.get_default ();
		if (display == null)
			return false;

		if (display is Gdk.X11.Display)
			return true;

		// Checked by name to avoid depending on gdk-wayland
		if (display.get_type ().name () == "GdkWaylandDisplay") {
			kind = BackendKind.WAYLAND;
			return true;
		}

		return false;
	}

	static Backend? backend = null;
	static bool backend_probed = false;

	/**
	 * Replaces the backend of the display, for tests.  null goes back to
	 * the backend of the display.
	 */
	public void set_backend_for_tests (Backend? replacement)
	{
		backend = replacement;
		backend_probed = (replacement != null);
	}

	/**
	 * Returns the backend for the default display, or null if there is no
	 * backend for it.  The backend is created on the first call.
	 */
	public unowned Backend? get_backend ()
	{
		if (backend_probed)
			return backend;

		backend_probed = true;

		BackendKind kind;
		if (!detect_backend (out kind))
			return null;

		switch (kind) {
		case BackendKind.X11:
			backend = new X11Backend ((Gdk.X11.Display) Gdk.Display.get_default ());
			break;
		default:
			// There is no Wayland backend yet
			break;
		}

		return backend;
	}
}
