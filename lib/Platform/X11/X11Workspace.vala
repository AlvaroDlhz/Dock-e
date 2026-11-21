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
	 * A {@link Wnck.Workspace}.
	 */
	public class X11Workspace : Workspace
	{
		public unowned Wnck.Workspace workspace { get; private set; }

		public override int index { get { return workspace.get_number (); } }
		public override string name { get { return workspace.get_name (); } }
		public override bool is_active { get { return (workspace.get_screen ().get_active_workspace () == workspace); } }
		public override bool is_viewport { get { return workspace.is_virtual (); } }

		internal X11Workspace (Wnck.Workspace workspace)
		{
			this.workspace = workspace;
		}

		public override void activate (uint32 timestamp)
		{
			workspace.activate (timestamp);
		}
	}

	/**
	 * The workspaces of a {@link Wnck.Screen}.
	 */
	public class X11WorkspaceManager : Object, WorkspaceManager
	{
		unowned Wnck.Screen screen;
		Gee.HashMap<unowned Wnck.Workspace, X11Workspace> workspaces;

		public Workspace? active { owned get { return lookup (screen.get_active_workspace ()); } }
		public bool showing_desktop { get { return screen.get_showing_desktop (); } }

		public X11WorkspaceManager (Wnck.Screen screen)
		{
			this.screen = screen;
			workspaces = new Gee.HashMap<unowned Wnck.Workspace, X11Workspace> ();

			screen.workspace_created.connect (handle_workspaces_changed);
			screen.workspace_destroyed.connect (handle_workspaces_changed);
			screen.active_workspace_changed.connect (handle_active_workspace_changed);
			screen.viewports_changed.connect (handle_viewports_changed);
		}

		~X11WorkspaceManager ()
		{
			screen.workspace_created.disconnect (handle_workspaces_changed);
			screen.workspace_destroyed.disconnect (handle_workspaces_changed);
			screen.active_workspace_changed.disconnect (handle_active_workspace_changed);
			screen.viewports_changed.disconnect (handle_viewports_changed);
		}

		public Gee.List<Workspace> list ()
		{
			// Make sure the list of Wnck is up to date
			screen.force_update ();

			var result = new Gee.ArrayList<Workspace> ();
			foreach (unowned Wnck.Workspace workspace in screen.get_workspaces ())
				result.add (lookup (workspace));
			return result;
		}

		/**
		 * The wrapper of a Wnck workspace, created on demand.
		 */
		public X11Workspace? lookup (Wnck.Workspace? workspace)
		{
			if (workspace == null)
				return null;

			var result = workspaces.get (workspace);
			if (result == null) {
				result = new X11Workspace (workspace);
				workspaces.set (workspace, result);
			}

			return result;
		}

		public void set_showing_desktop (bool show)
		{
			screen.toggle_showing_desktop (show);
		}

		[CCode (instance_pos = -1)]
		void handle_workspaces_changed (Wnck.Screen screen, Wnck.Workspace workspace)
		{
			// Forget destroyed workspaces
			var alive = new Gee.HashSet<unowned Wnck.Workspace> ();
			foreach (unowned Wnck.Workspace w in screen.get_workspaces ())
				alive.add (w);
			var it = workspaces.map_iterator ();
			while (it.next ())
				if (!alive.contains (it.get_key ()))
					it.unset ();

			changed ();
		}

		[CCode (instance_pos = -1)]
		void handle_active_workspace_changed (Wnck.Screen screen, Wnck.Workspace? previous)
		{
			active_changed (lookup (previous));
		}

		/**
		 * Moving to another viewport of a Compiz-like workspace is what
		 * switching workspaces is elsewhere.
		 */
		[CCode (instance_pos = -1)]
		void handle_viewports_changed (Wnck.Screen screen)
		{
			var current = active;
			if (current != null && current.is_viewport)
				active_changed (current);
		}
	}
}
