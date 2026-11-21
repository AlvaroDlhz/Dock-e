//
//  Copyright (C) 2011-2012 Robert Dyer, Rico Tzschichholz
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

namespace Plank
{
	/**
	 * What the dock does with the windows of an application.  Works on any
	 * backend; Compiz-like viewports are a detail of the X11 backend.
	 */
	public class WindowControl : GLib.Object
	{
		// when working on a group of windows, wait this amount between each action
		public const uint WINDOW_GROUP_DELAY = 10000U;
		// when changing a viewport, wait this time (for viewport change animations) before continuing
		public const uint VIEWPORT_CHANGE_DELAY = 200U;
		
		static uint delayed_focus_timer_id = 0U;
		static Platform.Toplevel? delayed_focus_window = null;
		static bool watching_toplevels = false;
		
		WindowControl ()
		{
		}
		
		static unowned Platform.ToplevelManager? get_toplevels ()
		{
			unowned Platform.Backend? backend = Platform.get_backend ();
			if (backend == null)
				return null;
			
			if (!watching_toplevels) {
				watching_toplevels = true;
				backend.toplevels.removed.connect (handle_window_closed);
			}
			
			return backend.toplevels;
		}
		
		static Platform.Workspace? get_active_workspace ()
		{
			unowned Platform.Backend? backend = Platform.get_backend ();
			if (backend == null || backend.workspaces == null)
				return null;
			return backend.workspaces.active;
		}
		
		static void handle_window_closed (Platform.Toplevel window)
		{
			if (delayed_focus_timer_id > 0U && delayed_focus_window == window) {
				GLib.Source.remove (delayed_focus_timer_id);
				delayed_focus_timer_id = 0U;
				delayed_focus_window = null;
			}
		}
		
		static bool in_view (Platform.Toplevel window, Platform.Workspace? workspace)
		{
			return (workspace != null && window.is_in_view (workspace));
		}
		
		static bool is_minimized (Platform.Toplevel window)
		{
			return window.has_any_state (Platform.ToplevelState.MINIMIZED);
		}
		
		static bool is_skip_tasklist (Platform.Toplevel window)
		{
			return window.has_any_state (Platform.ToplevelState.SKIP_TASKBAR);
		}
		
		public static Gdk.Pixbuf? get_app_icon (Platform.RunningApp app)
		{
			foreach (var window in app.get_windows ())
				return (window.icon_is_generic ? null : window.get_icon ());
			
			return null;
		}
		
		public static Gdk.Pixbuf? get_window_icon (Platform.Toplevel window)
		{
			return (window.icon_is_generic ? null : window.get_icon ());
		}
		
		public static bool has_maximized_window (Platform.RunningApp app)
		{
			foreach (var window in app.get_windows ())
				if (Platform.ToplevelState.MAXIMIZED in window.state)
					return true;
			
			return false;
		}
		
		public static bool has_minimized_window (Platform.RunningApp app)
		{
			foreach (var window in app.get_windows ())
				if (is_minimized (window))
					return true;
			
			return false;
		}
		
		public static bool has_window_on_workspace (Platform.RunningApp app, Platform.Workspace workspace)
		{
			var is_virtual = workspace.is_viewport;
			
			foreach (var window in app.get_windows ()) {
				if (is_skip_tasklist (window))
					continue;
				
				if (!is_virtual) {
					if (window.is_on_workspace (workspace))
						return true;
				} else {
					if (window.is_in_view (workspace))
						return true;
				}
			}
			
			return false;
		}
		
		public static void update_icon_regions (Platform.RunningApp app, Gdk.Rectangle rect)
		{
			foreach (var window in app.get_windows ())
				window.set_icon_geometry (rect);
		}
		
		public static void close_all (Platform.RunningApp app, uint32 event_time)
		{
			foreach (var window in app.get_windows ())
				if (!is_skip_tasklist (window))
					window.close (event_time);
		}
		
		public static void focus_window (Platform.Toplevel window, uint32 event_time)
		{
			window.activate (event_time);
		}
		
		static int find_active_index (Gee.List<Platform.Toplevel> windows)
		{
			var i = 0;
			for (; i < windows.size; i++)
				if (Platform.ToplevelState.ACTIVE in windows[i].state)
					break;
			return i;
		}
		
		public static void focus_previous (Platform.RunningApp app, uint32 event_time)
		{
			var windows = app.get_windows ();
			if (windows.size == 0)
				return;
			
			var i = find_active_index (windows);
			i = i < windows.size ? i - 1 : 0;
			
			if (i < 0)
				i = windows.size - 1;
			
			focus_window (windows[i], event_time);
		}
		
		public static void focus_next (Platform.RunningApp app, uint32 event_time)
		{
			var windows = app.get_windows ();
			if (windows.size == 0)
				return;
			
			var i = find_active_index (windows);
			i = i < windows.size ? i + 1 : 0;
			
			if (i == windows.size)
				i = 0;
			
			focus_window (windows[i], event_time);
		}
		
		public static void minimize (Platform.RunningApp app)
		{
			var active_workspace = get_active_workspace ();
			foreach (var window in get_ordered_window_stack (app)) {
				if (!is_minimized (window) && in_view (window, active_workspace)) {
					window.set_minimized (true, 0U);
					Thread.usleep (WINDOW_GROUP_DELAY);
				}
			}
		}
		
		public static void restore (Platform.RunningApp app, uint32 event_time)
		{
			var active_workspace = get_active_workspace ();
			var stack = get_ordered_window_stack (app);
			for (var i = stack.size - 1; i >= 0; i--) {
				var window = stack[i];
				if (is_minimized (window) && in_view (window, active_workspace)) {
					window.set_minimized (false, event_time);
					Thread.usleep (WINDOW_GROUP_DELAY);
				}
			}
		}
		
		public static void maximize (Platform.RunningApp app)
		{
			foreach (var window in get_ordered_window_stack (app))
				if (!(Platform.ToplevelState.MAXIMIZED in window.state))
					window.set_maximized (true);
		}
		
		public static void unmaximize (Platform.RunningApp app)
		{
			foreach (var window in get_ordered_window_stack (app))
				if (Platform.ToplevelState.MAXIMIZED in window.state)
					window.set_maximized (false);
		}
		
		/**
		 * The windows of an application from the bottom of the stack to the
		 * top, or in order of appearance without {@link Platform.Capability.STACKING_ORDER}.
		 */
		public static Gee.List<Platform.Toplevel> get_ordered_window_stack (Platform.RunningApp app)
		{
			var windows = new Gee.ArrayList<Platform.Toplevel> ();
			unowned Platform.ToplevelManager? toplevels = get_toplevels ();
			if (toplevels == null)
				return windows;
			
			var own = app.get_windows ();
			foreach (var window in toplevels.list ())
				if (own.contains (window))
					windows.add (window);
			
			return windows;
		}
		
		public static void smart_focus (Platform.RunningApp app, uint32 event_time)
		{
			var windows = get_ordered_window_stack (app);
			var active_workspace = get_active_workspace ();
			
			var not_in_viewport = true;
			var urgent = false;
			
			foreach (var window in windows) {
				if (!is_skip_tasklist (window) && in_view (window, active_workspace))
					not_in_viewport = false;
				if (window.has_any_state (Platform.ToplevelState.URGENT))
					urgent = true;
			}
			
			// Focus off-viewport window if it needs attention
			if (not_in_viewport || urgent) {
				foreach (var window in windows) {
					if (urgent && !window.has_any_state (Platform.ToplevelState.URGENT))
						continue;
					
					if (!is_skip_tasklist (window)) {
						intelligent_focus_off_viewport_window (window, windows, event_time);
						return;
					}
				}
			}
			
			// Unminimize minimized windows if there is one or more
			foreach (var window in windows) {
				if (is_minimized (window) && in_view (window, active_workspace)) {
					foreach (var w in windows)
						if (is_minimized (w) && in_view (w, active_workspace)) {
							w.set_minimized (false, event_time);
							Thread.usleep (WINDOW_GROUP_DELAY);
						}
					return;
				}
			}
			
			// Minimize all windows if this application owns the active window
			unowned Platform.ToplevelManager? toplevels = get_toplevels ();
			foreach (var window in windows) {
				if ((Platform.ToplevelState.ACTIVE in window.state && in_view (window, active_workspace))
					|| (toplevels != null && window == toplevels.active)) {
					foreach (var w in windows)
						if (!is_minimized (w) && in_view (w, active_workspace)) {
							w.set_minimized (true, event_time);
							Thread.usleep (WINDOW_GROUP_DELAY);
						}
					return;
				}
			}

			// Get all windows on the current workspace in the foreground
			foreach (var window in windows) {
				if (in_view (window, active_workspace)) {
					foreach (var w in windows)
						if (in_view (w, active_workspace)) {
							w.activate (event_time);
							Thread.usleep (WINDOW_GROUP_DELAY);
						}
					return;
				}
			}
			
			// Focus most-top window and all others on its workspace
			if (windows.size > 0)
				intelligent_focus_off_viewport_window (windows[0], windows, event_time);
		}
		
		static void intelligent_focus_off_viewport_window (Platform.Toplevel target_window,
			Gee.List<Platform.Toplevel> additional_windows, uint32 event_time)
		{
			for (var i = additional_windows.size - 1; i >= 0; i--) {
				var window = additional_windows[i];
				if (window == target_window)
					continue;
				if (!is_minimized (window) && target_window.shares_view_with (window)) {
					window.activate (event_time);
					Thread.usleep (WINDOW_GROUP_DELAY);
				}
			}
			
			target_window.activate (event_time);
			
			if (additional_windows.size <= 1)
				return;
			
			// we do this to make sure our active window is also at the front... Its a tricky thing to do.
			// sometimes compiz plays badly.  This hacks around it
			get_toplevels ();
			if (delayed_focus_timer_id > 0U)
				GLib.Source.remove (delayed_focus_timer_id);
			delayed_focus_window = target_window;
			delayed_focus_timer_id = Gdk.threads_add_timeout (VIEWPORT_CHANGE_DELAY, () => {
				delayed_focus_timer_id = 0U;
				delayed_focus_window.activate (event_time);
				delayed_focus_window = null;
				return false;
			});
		}
	}
}
