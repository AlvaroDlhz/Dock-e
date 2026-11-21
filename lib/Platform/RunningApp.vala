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
	 * A running application: its toplevels grouped and matched to a
	 * .desktop file.  Changes of the boolean properties and of the name
	 * are reported with GObject's notify.
	 */
	public abstract class RunningApp : Object
	{
		/** The absolute path of the .desktop file, or null if none matched */
		public abstract string? desktop_file { get; }
		public abstract string name { owned get; }
		public abstract bool is_running { get; }
		public abstract bool is_active { get; }
		public abstract bool is_urgent { get; }
		/** False for applications which only have hidden windows yet */
		public abstract bool is_user_visible { get; }

		/**
		 * The toplevels of the application.  Windows the backend does not
		 * know as toplevels yet are left out.
		 */
		public abstract Gee.List<Toplevel> get_windows ();

		public signal void window_added (Toplevel toplevel);
		public signal void window_removed (Toplevel toplevel);
		public signal void closed ();
	}

	public interface AppTracker : Object
	{
		/** The running applications */
		public abstract Gee.List<RunningApp> running_apps ();

		/**
		 * The application of a .desktop file.
		 *
		 * @param uri the URI of the .desktop file
		 * @return null if it is not known
		 */
		public abstract RunningApp? app_for_desktop_file (string uri);

		/**
		 * The .desktop files the dock keeps, which helps matching windows.
		 *
		 * @param desktop_files absolute paths
		 */
		public abstract void set_favorites (Gee.List<string> desktop_files);

		/** A visible application appeared */
		public signal void app_opened (RunningApp app);
		public signal void app_closed (RunningApp app);
		public signal void active_app_changed (RunningApp? old_app, RunningApp? new_app);
		/** A window of an application appeared; emitted once it is a toplevel */
		public signal void window_opened (Toplevel toplevel);
		public signal void active_window_changed (Toplevel? old_window, Toplevel? new_window);
	}
}
