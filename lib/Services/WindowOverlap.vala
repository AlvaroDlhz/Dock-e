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

namespace Plank
{
	/**
	 * Which windows cover the dock, as the hide modes need it.
	 */
	public struct WindowOverlap
	{
		/** Any window */
		public bool any_window;
		/** A dialog of the active application */
		public bool dialog_window;
		/** Any window of the active application */
		public bool active_application;
		/** The active window itself */
		public bool active_window;
		/** The active window, maximized in some direction */
		public bool active_maximized_window;

		/**
		 * Looks at the visible windows of the active workspace.  Nothing
		 * covers the dock while no window has the focus.
		 *
		 * @param toplevels the windows
		 * @param workspaces the workspaces, or null if the backend has none
		 * @param dock_rect the dock in logical pixels and GDK screen coordinates
		 * @param own_pid the process of the dock, whose windows never count
		 */
		public static WindowOverlap compute (Platform.ToplevelManager toplevels, Platform.WorkspaceManager? workspaces,
			Gdk.Rectangle dock_rect, int own_pid)
		{
			WindowOverlap result = {};

			unowned Platform.Toplevel? active = toplevels.active;
			if (active == null && !toplevels.non_toplevel_focused)
				return result;

			Platform.Workspace? active_workspace = null;
			if (workspaces != null) {
				active_workspace = workspaces.active;
				if (active_workspace == null)
					return result;
			}

			// The process of a focused desktop window is unknown; it owns no toplevels
			var active_pid = (active != null ? active.pid : -1);

			foreach (var toplevel in toplevels.list ()) {
				if (toplevel.has_any_state (Platform.ToplevelState.MINIMIZED))
					continue;
				if (active_workspace != null && !toplevel.is_on_workspace (active_workspace))
					continue;
				var pid = toplevel.pid;
				if (pid == own_pid)
					continue;

				Gdk.Rectangle rect;
				if (!toplevel.get_geometry (out rect) || !rect.intersect (dock_rect, null))
					continue;

				result.any_window = true;

				if (pid != active_pid)
					continue;

				result.active_application = true;
				result.active_window = result.active_window || (active == toplevel);
				result.active_maximized_window = result.active_maximized_window
					|| (active == toplevel && toplevel.has_any_state (Platform.ToplevelState.MAXIMIZED));
				result.dialog_window = result.dialog_window || toplevel.kind == Platform.ToplevelKind.DIALOG;

				if (result.active_maximized_window && result.dialog_window)
					break;
			}

			return result;
		}
	}
}
