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
	 * A {@link Wnck.Window}.
	 */
	public class X11Toplevel : Toplevel
	{
		// A reference of our own: someone may hold the toplevel after the window closed
		public Wnck.Window window { get; private set; }

		unowned X11ToplevelManager manager;

		public override uint64 id { get { return window.get_xid (); } }
		public override string title { get { return window.get_name (); } }
		public override string? app_id { get { return window.get_class_group_name (); } }
		public override int pid { get { return window.get_pid (); } }
		public override ToplevelState state { get { return map_state (window.get_state ()) | (manager.active == this ? ToplevelState.ACTIVE : (ToplevelState) 0); } }
		public override ToplevelKind kind { get { return map_kind (window.get_window_type ()); } }
		public override Toplevel? transient_for {
			owned get {
				unowned Wnck.Window? parent = window.get_transient ();
				return (parent != null ? manager.lookup (parent) : null);
			}
		}

		internal X11Toplevel (X11ToplevelManager manager, Wnck.Window window)
		{
			this.manager = manager;
			this.window = window;

			window.state_changed.connect (handle_state_changed);
			window.geometry_changed.connect (handle_geometry_changed);
			window.name_changed.connect (handle_name_changed);
		}

		~X11Toplevel ()
		{
			window.state_changed.disconnect (handle_state_changed);
			window.geometry_changed.disconnect (handle_geometry_changed);
			window.name_changed.disconnect (handle_name_changed);
		}

		[CCode (instance_pos = -1)]
		void handle_state_changed (Wnck.Window w, Wnck.WindowState changed_mask, Wnck.WindowState new_state)
		{
			var mask = map_state (changed_mask);
			if (mask != 0)
				state_changed (mask);
		}

		[CCode (instance_pos = -1)]
		void handle_geometry_changed (Wnck.Window w)
		{
			geometry_changed ();
		}

		[CCode (instance_pos = -1)]
		void handle_name_changed (Wnck.Window w)
		{
			title_changed ();
		}

		public override bool get_geometry (out Gdk.Rectangle rect)
		{
			int x, y, width, height;
			window.get_geometry (out x, out y, out width, out height);
			rect = device_to_logical (x, y, width, height, manager.scale_factor);
			return true;
		}

		public override bool is_on_workspace (Workspace workspace)
		{
			unowned X11Workspace? x11_workspace = (workspace as X11Workspace);
			return (x11_workspace != null && window.is_on_workspace (x11_workspace.workspace));
		}

		public override Gdk.Pixbuf? get_icon ()
		{
			return window.get_icon ();
		}

		public override void activate (uint32 timestamp)
		{
			window.activate (timestamp);
		}

		public override void close (uint32 timestamp)
		{
			window.close (timestamp);
		}

		public override void set_minimized (bool minimized, uint32 timestamp)
		{
			if (minimized)
				window.minimize ();
			else
				window.unminimize (timestamp);
		}

		public override void set_maximized (bool maximized)
		{
			if (maximized)
				window.maximize ();
			else
				window.unmaximize ();
		}

		public override void set_icon_geometry (Gdk.Rectangle rect)
		{
			window.set_icon_geometry (rect.x, rect.y, rect.width, rect.height);
		}

		public static ToplevelState map_state (Wnck.WindowState wnck_state)
		{
			ToplevelState result = 0;

			if (Wnck.WindowState.MINIMIZED in wnck_state)
				result |= ToplevelState.MINIMIZED;
			if (Wnck.WindowState.MAXIMIZED_HORIZONTALLY in wnck_state)
				result |= ToplevelState.MAXIMIZED_HORIZONTALLY;
			if (Wnck.WindowState.MAXIMIZED_VERTICALLY in wnck_state)
				result |= ToplevelState.MAXIMIZED_VERTICALLY;
			if (Wnck.WindowState.FULLSCREEN in wnck_state)
				result |= ToplevelState.FULLSCREEN;
			if (Wnck.WindowState.URGENT in wnck_state || Wnck.WindowState.DEMANDS_ATTENTION in wnck_state)
				result |= ToplevelState.URGENT;
			if (Wnck.WindowState.SKIP_TASKLIST in wnck_state)
				result |= ToplevelState.SKIP_TASKBAR;
			if (Wnck.WindowState.SKIP_PAGER in wnck_state)
				result |= ToplevelState.SKIP_PAGER;

			return result;
		}

		static ToplevelKind map_kind (Wnck.WindowType type)
		{
			switch (type) {
			case Wnck.WindowType.NORMAL:
				return ToplevelKind.NORMAL;
			case Wnck.WindowType.DIALOG:
				return ToplevelKind.DIALOG;
			case Wnck.WindowType.UTILITY:
				return ToplevelKind.UTILITY;
			default:
				return ToplevelKind.OTHER;
			}
		}

		/**
		 * Desktops, docks (ourselves included), menus and splash screens
		 * are not toplevels for the dock.
		 */
		internal static bool is_ignored_type (Wnck.WindowType type)
		{
			return (type == Wnck.WindowType.DESKTOP || type == Wnck.WindowType.DOCK
				|| type == Wnck.WindowType.MENU || type == Wnck.WindowType.SPLASHSCREEN);
		}

		static int floor_div (int a, int b)
		{
			return (a >= 0 ? a / b : -((-a + b - 1) / b));
		}

		/**
		 * Converts device pixels to logical ones, rounding outwards: a
		 * device rectangle meets the scaled-up logical rectangle D exactly
		 * when the result meets D.
		 */
		public static Gdk.Rectangle device_to_logical (int x, int y, int width, int height, int scale)
		{
			if (scale <= 1)
				return { x, y, width, height };

			var x1 = floor_div (x, scale);
			var y1 = floor_div (y, scale);
			var x2 = -floor_div (-(x + width), scale);
			var y2 = -floor_div (-(y + height), scale);

			return { x1, y1, x2 - x1, y2 - y1 };
		}
	}

	/**
	 * The windows of a {@link Wnck.Screen}.
	 */
	public class X11ToplevelManager : Object, ToplevelManager
	{
		unowned Wnck.Screen screen;
		Gee.HashMap<unowned Wnck.Window, X11Toplevel> toplevels;
		X11Toplevel? active_toplevel = null;

		public Toplevel? active { get { return active_toplevel; } }

		public bool non_toplevel_focused { get { return focus_elsewhere; } }
		bool focus_elsewhere = false;

		internal int scale_factor {
			get {
				unowned Gdk.Screen? gdk_screen = Gdk.Screen.get_default ();
				return (gdk_screen != null ? gdk_screen.get_root_window ().get_scale_factor () : 1);
			}
		}

		public X11ToplevelManager (Wnck.Screen screen)
		{
			this.screen = screen;
			toplevels = new Gee.HashMap<unowned Wnck.Window, X11Toplevel> ();

			foreach (unowned Wnck.Window window in screen.get_windows ())
				add_window (window);
			update_active ();

			screen.window_opened.connect (handle_window_opened);
			screen.window_closed.connect (handle_window_closed);
			screen.active_window_changed.connect (handle_active_window_changed);
		}

		~X11ToplevelManager ()
		{
			screen.window_opened.disconnect (handle_window_opened);
			screen.window_closed.disconnect (handle_window_closed);
			screen.active_window_changed.disconnect (handle_active_window_changed);
		}

		public Gee.List<Toplevel> list ()
		{
			var result = new Gee.ArrayList<Toplevel> ();

			foreach (unowned Wnck.Window window in screen.get_windows_stacked ()) {
				var toplevel = toplevels.get (window);
				if (toplevel != null)
					result.add (toplevel);
			}

			return result;
		}

		/**
		 * The toplevel of a Wnck window, or null if it is not a toplevel.
		 */
		public X11Toplevel? lookup (Wnck.Window window)
		{
			return toplevels.get (window);
		}

		public Toplevel? lookup_id (uint64 id)
		{
			unowned Wnck.Window? window = Wnck.Window.@get ((ulong) id);
			return (window != null ? toplevels.get (window) : null);
		}

		void update_active ()
		{
			unowned Wnck.Window? window = screen.get_active_window ();
			active_toplevel = lookup_or_null (window);
			focus_elsewhere = (window != null && active_toplevel == null);
		}

		X11Toplevel? lookup_or_null (Wnck.Window? window)
		{
			return (window != null ? toplevels.get (window) : null);
		}

		X11Toplevel? add_window (Wnck.Window window)
		{
			if (X11Toplevel.is_ignored_type (window.get_window_type ()))
				return null;

			var toplevel = new X11Toplevel (this, window);
			toplevels.set (window, toplevel);
			return toplevel;
		}

		[CCode (instance_pos = -1)]
		void handle_window_opened (Wnck.Screen screen, Wnck.Window window)
		{
			if (toplevels.has_key (window))
				return;

			var toplevel = add_window (window);
			if (toplevel != null)
				added (toplevel);
		}

		[CCode (instance_pos = -1)]
		void handle_window_closed (Wnck.Screen screen, Wnck.Window window)
		{
			X11Toplevel toplevel;
			if (!toplevels.unset (window, out toplevel))
				return;

			if (active_toplevel == toplevel)
				active_toplevel = null;

			removed (toplevel);
		}

		[CCode (instance_pos = -1)]
		void handle_active_window_changed (Wnck.Screen screen, Wnck.Window? previous_window)
		{
			var previous = active_toplevel;
			var was_non_toplevel_focused = non_toplevel_focused;
			update_active ();

			if (previous == active_toplevel && was_non_toplevel_focused == non_toplevel_focused)
				return;

			if (previous != active_toplevel) {
				if (previous != null)
					previous.state_changed (ToplevelState.ACTIVE);
				if (active_toplevel != null)
					active_toplevel.state_changed (ToplevelState.ACTIVE);
			}

			active_changed (previous);
		}
	}
}
