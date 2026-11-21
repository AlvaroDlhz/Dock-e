//
//  Copyright (C) 2026 Dock-E contributors
//
//  This file is part of Plank.
//

using Plank.Platform;

namespace PlankTests
{
	/**
	 * A backend without a display server, filled in by the tests.
	 */
	public class FakeBackend : Object, Backend
	{
		public BackendKind kind { get { return BackendKind.WAYLAND; } }
		public Capability capabilities { get { return supported; } }
		public ToplevelManager toplevels { get { return fake_toplevels; } }
		public WorkspaceManager? workspaces { get { return fake_workspaces; } }

		public Capability supported;
		public FakeToplevelManager fake_toplevels = new FakeToplevelManager ();
		public FakeWorkspaceManager? fake_workspaces = new FakeWorkspaceManager ();

		public FakeBackend (Capability supported)
		{
			this.supported = supported;
		}

		public void log_details ()
		{
		}

		public void initialize ()
		{
		}

		public SuperKeyTrigger? create_super_key_trigger ()
		{
			return null;
		}

		public DockSurface create_dock_surface (Gtk.Window dock)
		{
			return new FakeDockSurface ();
		}

		public AppTracker apps { get { return fake_apps; } }
		public FakeAppTracker fake_apps = new FakeAppTracker ();

		public WindowThumbnailer? create_thumbnailer (int width, int height)
		{
			return null;
		}

		public EdgeTrigger? create_edge_trigger (Gtk.Window dock)
		{
			return null;
		}
	}

	public class FakeAppTracker : Object, AppTracker
	{
		public Gee.ArrayList<RunningApp> apps = new Gee.ArrayList<RunningApp> ();
		public Gee.List<string> favorites = new Gee.ArrayList<string> ();

		public Gee.List<RunningApp> running_apps ()
		{
			return apps.read_only_view;
		}

		public RunningApp? app_for_desktop_file (string uri)
		{
			foreach (var app in apps)
				if (app.desktop_file != null && File.new_for_path (app.desktop_file).get_uri () == uri)
					return app;
			return null;
		}

		public void set_favorites (Gee.List<string> desktop_files)
		{
			favorites = desktop_files;
		}
	}

	public class FakeDockSurface : Object, DockSurface
	{
		public int thickness = -1;

		public void reserve (Gtk.PositionType edge, Gdk.Rectangle area, int thickness)
		{
			this.thickness = thickness;
		}
	}

	public class FakeWorkspace : Workspace
	{
		int number;
		string fake_name;
		public FakeWorkspaceManager manager;

		public override int index { get { return number; } }
		public override string name { get { return fake_name; } }
		public override bool is_active { get { return manager.is_current (this); } }
		public override bool is_viewport { get { return false; } }

		public FakeWorkspace (FakeWorkspaceManager manager, int number)
		{
			this.manager = manager;
			this.number = number;
			fake_name = "Workspace %d".printf (number + 1);
		}

		public override void activate (uint32 timestamp)
		{
			manager.set_active (this);
		}
	}

	public class FakeWorkspaceManager : Object, WorkspaceManager
	{
		public Gee.ArrayList<Workspace> workspaces = new Gee.ArrayList<Workspace> ();
		Workspace? current = null;
		bool desktop_shown = false;

		public Workspace? active { owned get { return current; } }
		public bool showing_desktop { get { return desktop_shown; } }

		public bool is_current (Workspace workspace)
		{
			return current == workspace;
		}

		public FakeWorkspace add ()
		{
			var workspace = new FakeWorkspace (this, workspaces.size);
			workspaces.add (workspace);
			if (current == null)
				current = workspace;
			changed ();
			return workspace;
		}

		public Gee.List<Workspace> list ()
		{
			return workspaces.read_only_view;
		}

		public void set_active (Workspace? workspace)
		{
			var previous = current;
			current = workspace;
			active_changed (previous);
		}

		public void set_showing_desktop (bool show)
		{
			desktop_shown = show;
		}
	}

	public class FakeToplevel : Toplevel
	{
		static uint64 next_id = 1;

		uint64 number;
		public string fake_title = "";
		public int fake_pid = 0;
		public ToplevelState fake_state = 0;
		public ToplevelKind fake_kind = ToplevelKind.NORMAL;
		public Toplevel? parent = null;
		public Gdk.Rectangle geometry = { 0, 0, 100, 100 };
		public bool knows_geometry = true;
		public Gee.HashSet<Workspace> on_workspaces = new Gee.HashSet<Workspace> ();
		public FakeToplevelManager? manager = null;

		public override uint64 id { get { return number; } }
		public override string title { get { return fake_title; } }
		public override string? app_id { get { return null; } }
		public override int pid { get { return fake_pid; } }
		public override ToplevelState state {
			get { return fake_state | (manager != null && manager.active == this ? ToplevelState.ACTIVE : (ToplevelState) 0); }
		}
		public override ToplevelKind kind { get { return fake_kind; } }
		public override Toplevel? transient_for { owned get { return parent; } }

		public FakeToplevel (string title = "")
		{
			number = next_id++;
			fake_title = title;
		}

		/**
		 * A toplevel standing for a real window of the backend, such as an
		 * XID on X11.
		 */
		public FakeToplevel.with_id (uint64 id)
		{
			number = id;
		}

		public override bool get_geometry (out Gdk.Rectangle rect)
		{
			rect = geometry;
			return knows_geometry;
		}

		public override bool is_on_workspace (Workspace workspace)
		{
			return on_workspaces.contains (workspace);
		}

		public override bool is_in_view (Workspace workspace)
		{
			return on_workspaces.contains (workspace);
		}

		public override bool shares_view_with (Toplevel other)
		{
			return true;
		}

		public override bool icon_is_generic { get { return false; } }

		public override Gdk.Pixbuf? get_icon ()
		{
			return null;
		}

		public void change_state (ToplevelState new_state)
		{
			var changed = fake_state ^ new_state;
			fake_state = new_state;
			if (changed != 0)
				state_changed (changed);
		}

		public void move (Gdk.Rectangle rect)
		{
			geometry = rect;
			geometry_changed ();
		}

		public override void activate (uint32 timestamp)
		{
			if (manager != null)
				manager.set_active (this);
		}

		public override void close (uint32 timestamp)
		{
			if (manager != null)
				manager.remove (this);
		}

		public override void set_minimized (bool minimized, uint32 timestamp)
		{
			change_state (minimized ? fake_state | ToplevelState.MINIMIZED : fake_state & ~ToplevelState.MINIMIZED);
		}

		public override void set_maximized (bool maximized)
		{
			change_state (maximized ? fake_state | ToplevelState.MAXIMIZED : fake_state & ~ToplevelState.MAXIMIZED);
		}

		public override void set_icon_geometry (Gdk.Rectangle rect)
		{
		}
	}

	public class FakeToplevelManager : Object, ToplevelManager
	{
		Gee.ArrayList<Toplevel> toplevels = new Gee.ArrayList<Toplevel> ();
		Toplevel? current = null;

		public Toplevel? active { get { return current; } }
		public bool non_toplevel_focused { get { return desktop_focused; } }
		public bool desktop_focused = false;

		public Gee.List<Toplevel> list ()
		{
			return toplevels.read_only_view;
		}

		public void refresh ()
		{
		}

		public Toplevel? lookup_id (uint64 id)
		{
			foreach (var toplevel in toplevels)
				if (toplevel.id == id)
					return toplevel;
			return null;
		}

		public FakeToplevel add (FakeToplevel toplevel)
		{
			toplevel.manager = this;
			toplevels.add (toplevel);
			added (toplevel);
			return toplevel;
		}

		public void remove (Toplevel toplevel)
		{
			if (!toplevels.remove (toplevel))
				return;
			if (current == toplevel)
				set_active (null);
			removed (toplevel);
		}

		public void set_active (Toplevel? toplevel)
		{
			var previous = current;
			if (previous == toplevel)
				return;
			current = toplevel;
			if (previous != null)
				previous.state_changed (ToplevelState.ACTIVE);
			if (toplevel != null)
				toplevel.state_changed (ToplevelState.ACTIVE);
			active_changed (previous);
		}
	}
}
