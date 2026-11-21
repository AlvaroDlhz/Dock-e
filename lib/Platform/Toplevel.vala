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
	 * Desktops, docks, menus and splash screens are never toplevels; the
	 * backend leaves them out.
	 */
	public enum ToplevelKind
	{
		NORMAL,
		DIALOG,
		UTILITY,
		OTHER
	}

	[Flags]
	public enum ToplevelState
	{
		ACTIVE = 1 << 0,
		MINIMIZED = 1 << 1,
		MAXIMIZED_HORIZONTALLY = 1 << 2,
		MAXIMIZED_VERTICALLY = 1 << 3,
		FULLSCREEN = 1 << 4,
		/** Urgent or demanding attention */
		URGENT = 1 << 5,
		SKIP_TASKBAR = 1 << 6,
		SKIP_PAGER = 1 << 7,
		/** Maximized in both directions */
		MAXIMIZED = MAXIMIZED_HORIZONTALLY | MAXIMIZED_VERTICALLY
	}

	/**
	 * A window of another client.
	 */
	public abstract class Toplevel : Object
	{
		/**
		 * The XID on X11, a local counter elsewhere.  Only for indexing,
		 * never for talking to the display server.
		 */
		public abstract uint64 id { get; }
		public abstract string title { get; }
		/** WM_CLASS on X11, app_id on Wayland */
		public abstract string? app_id { get; }
		/** 0 if unknown */
		public abstract int pid { get; }
		public abstract ToplevelState state { get; }
		public abstract ToplevelKind kind { get; }
		public abstract Toplevel? transient_for { owned get; }

		/**
		 * Whether any of the given state flags is set.
		 */
		public bool has_any_state (ToplevelState flags)
		{
			return ((state & flags) != 0);
		}

		/**
		 * The position and size of the window in logical pixels and GDK
		 * screen coordinates.  Rounded outwards, so the rectangle covers
		 * every device pixel of the window.
		 *
		 * @return false if the backend does not know the geometry (see
		 *         {@link Capability.TOPLEVEL_GEOMETRY})
		 */
		public abstract bool get_geometry (out Gdk.Rectangle rect);

		public abstract bool is_on_workspace (Workspace workspace);

		/**
		 * Whether the window is on the workspace and inside the part of it
		 * that is shown: the current viewport of a Compiz-like workspace.
		 * The same as {@link is_on_workspace} elsewhere.
		 */
		public abstract bool is_in_view (Workspace workspace);

		/**
		 * Whether both windows would be shown together: on the same viewport
		 * of a Compiz-like workspace, or both on the screen elsewhere.
		 */
		public abstract bool shares_view_with (Toplevel other);

		/**
		 * Whether {@link get_icon} is a generic icon of the backend rather
		 * than one the window provides.
		 */
		public abstract bool icon_is_generic { get; }

		/**
		 * The icon of the window; may be a generic icon of the backend if
		 * the window has none.
		 *
		 * @return null without {@link Capability.WINDOW_ICONS}
		 */
		public abstract Gdk.Pixbuf? get_icon ();

		/**
		 * @param changed_mask the flags which changed
		 */
		public signal void state_changed (ToplevelState changed_mask);
		public signal void geometry_changed ();
		public signal void title_changed ();

		/**
		 * Brings the window to the front: switches to its workspace,
		 * restores it if it is minimized, and focuses it, or the dialog it
		 * has open.
		 */
		public abstract void activate (uint32 timestamp);
		public abstract void close (uint32 timestamp);
		public abstract void set_minimized (bool minimized, uint32 timestamp);
		public abstract void set_maximized (bool maximized);

		/**
		 * Where the window goes when it is minimized: _NET_WM_ICON_GEOMETRY
		 * on X11, set_rectangle on wlr-foreign-toplevel.
		 *
		 * @param rect the icon on the dock, in the coordinates
		 *        {@link PositionManager.get_icon_geometry} gives
		 */
		public abstract void set_icon_geometry (Gdk.Rectangle rect);
	}

	public interface ToplevelManager : Object
	{
		public abstract Toplevel? active { get; }

		/**
		 * The focus is on a window which is not a toplevel, such as the
		 * desktop; {@link active} is null then.
		 */
		public abstract bool non_toplevel_focused { get; }

		/**
		 * All toplevels, from the bottom to the top if the backend has
		 * {@link Capability.STACKING_ORDER}, in order of appearance otherwise.
		 */
		public abstract Gee.List<Toplevel> list ();

		/**
		 * The toplevel with this {@link Toplevel.id}, or null.
		 */
		public abstract Toplevel? lookup_id (uint64 id);

		/**
		 * Makes sure the list matches the display server right now, for
		 * windows another source announced first.
		 */
		public abstract void refresh ();

		public signal void added (Toplevel toplevel);
		public signal void removed (Toplevel toplevel);
		/**
		 * The active toplevel changed, or the focus moved between
		 * {@link non_toplevel_focused} and no window at all.
		 */
		public signal void active_changed (Toplevel? previous);
	}
}
