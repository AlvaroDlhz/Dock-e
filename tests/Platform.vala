//
//  Copyright (C) 2026 Dock-E contributors
//
//  This file is part of Plank.
//

using Plank;
using Plank.Platform;

namespace PlankTests
{
	public static void register_platform_tests ()
	{
		Test.add_func ("/Platform/Backend/capabilities", platform_backend_capabilities);
		Test.add_func ("/Platform/Toplevel/state-flags", platform_toplevel_state_flags);
		Test.add_func ("/Platform/Toplevel/manager-signals", platform_toplevel_manager_signals);
		Test.add_func ("/Platform/Toplevel/geometry", platform_toplevel_geometry);
		Test.add_func ("/Platform/Workspace/manager", platform_workspace_manager);
#if HAVE_X11
		Test.add_func ("/Platform/X11/device-to-logical", platform_x11_device_to_logical);
		Test.add_func ("/Platform/X11/device-to-logical-intersection", platform_x11_device_to_logical_intersection);
		Test.add_func ("/Platform/X11/map-state", platform_x11_map_state);
#endif
		Test.add_func ("/Platform/show-desktop", platform_show_desktop);
		Test.add_func ("/Platform/ToplevelWaiter/known", platform_toplevel_waiter_known);
		Test.add_func ("/Platform/ToplevelWaiter/later", platform_toplevel_waiter_later);
		Test.add_func ("/Platform/ToplevelWaiter/cancel", platform_toplevel_waiter_cancel);
		Test.add_func ("/Platform/AppTracker/fake", platform_app_tracker_fake);
		Test.add_func ("/HideManager/WindowOverlap/no-focus", window_overlap_no_focus);
		Test.add_func ("/HideManager/WindowOverlap/desktop-focused", window_overlap_desktop_focused);
		Test.add_func ("/HideManager/WindowOverlap/active-maximized", window_overlap_active_maximized);
		Test.add_func ("/HideManager/WindowOverlap/application-dialog", window_overlap_application_dialog);
		Test.add_func ("/HideManager/WindowOverlap/ignored-windows", window_overlap_ignored_windows);
		Test.add_func ("/HideManager/WindowOverlap/workspaces", window_overlap_workspaces);
	}

	void platform_backend_capabilities ()
	{
		Backend backend = new FakeBackend (Capability.TOPLEVELS | Capability.WORKSPACES);
		assert (backend.has (Capability.TOPLEVELS));
		assert (backend.has (Capability.WORKSPACES));
		assert (!backend.has (Capability.THUMBNAILS));
		assert (!backend.has (Capability.EDGE_PRESSURE));
		assert (backend.create_edge_trigger (new Gtk.Window ()) == null);
		assert (backend.create_super_key_trigger () == null);
	}

	void platform_toplevel_state_flags ()
	{
		var toplevel = new FakeToplevel ();

		toplevel.fake_state = ToplevelState.MAXIMIZED_VERTICALLY;
		assert (!(ToplevelState.MAXIMIZED in toplevel.state));
		assert (toplevel.has_any_state (ToplevelState.MAXIMIZED));
		assert (!toplevel.has_any_state (ToplevelState.MINIMIZED));

		toplevel.fake_state = ToplevelState.MAXIMIZED;
		assert (ToplevelState.MAXIMIZED in toplevel.state);
		assert (ToplevelState.MAXIMIZED_HORIZONTALLY in toplevel.state);

		ToplevelState changed = 0;
		toplevel.state_changed.connect ((mask) => changed = mask);
		toplevel.set_minimized (true, 0U);
		assert (changed == ToplevelState.MINIMIZED);
		assert (toplevel.has_any_state (ToplevelState.MINIMIZED));
	}

	void platform_toplevel_manager_signals ()
	{
		var manager = new FakeToplevelManager ();
		var added = 0, removed = 0, active_changes = 0;
		Toplevel? last_previous = null;

		manager.added.connect (() => added++);
		manager.removed.connect (() => removed++);
		manager.active_changed.connect ((previous) => {
			active_changes++;
			last_previous = previous;
		});

		var first = manager.add (new FakeToplevel ("first"));
		var second = manager.add (new FakeToplevel ("second"));
		assert (added == 2);
		assert (manager.list ().size == 2);
		assert (first.id != second.id);

		var second_changes = 0;
		second.state_changed.connect ((mask) => {
			if (ToplevelState.ACTIVE in mask)
				second_changes++;
		});

		first.activate (0U);
		assert (manager.active == first);
		assert (ToplevelState.ACTIVE in first.state);
		assert (!(ToplevelState.ACTIVE in second.state));
		assert (last_previous == null);

		second.activate (0U);
		assert (manager.active == second);
		assert (last_previous == first);
		assert (second_changes == 1);

		second.close (0U);
		assert (removed == 1);
		assert (manager.active == null);
		assert (active_changes == 3);
		assert (manager.list ().size == 1);
	}

	void platform_toplevel_geometry ()
	{
		var toplevel = new FakeToplevel ();
		var moves = 0;
		toplevel.geometry_changed.connect (() => moves++);

		toplevel.move ({ 10, 20, 300, 200 });
		Gdk.Rectangle rect;
		assert (toplevel.get_geometry (out rect));
		assert (rect.x == 10 && rect.y == 20 && rect.width == 300 && rect.height == 200);
		assert (moves == 1);

		toplevel.knows_geometry = false;
		assert (!toplevel.get_geometry (out rect));
	}

	void platform_workspace_manager ()
	{
		var backend = new FakeBackend (Capability.WORKSPACES);
		unowned FakeWorkspaceManager workspaces = backend.fake_workspaces;
		var changes = 0;
		workspaces.changed.connect (() => changes++);

		var first = workspaces.add ();
		var second = workspaces.add ();
		assert (changes == 2);
		assert (backend.workspaces.list ().size == 2);
		assert (first.is_active && !second.is_active);
		assert (second.index == 1);

		Workspace? previous = null;
		workspaces.active_changed.connect ((p) => previous = p);
		second.activate (0U);
		assert (second.is_active);
		assert (previous == first);

		var toplevel = new FakeToplevel ();
		toplevel.on_workspaces.add (second);
		assert (toplevel.is_on_workspace (second));
		assert (!toplevel.is_on_workspace (first));
	}

#if HAVE_X11
	void platform_x11_device_to_logical ()
	{
		var same = X11Toplevel.device_to_logical (-7, 3, 11, 5, 1);
		assert (same.x == -7 && same.y == 3 && same.width == 11 && same.height == 5);

		var exact = X11Toplevel.device_to_logical (200, 100, 400, 60, 2);
		assert (exact.x == 100 && exact.y == 50 && exact.width == 200 && exact.height == 30);

		// Odd device pixels grow the logical rectangle outwards
		var odd = X11Toplevel.device_to_logical (201, -3, 2, 4, 2);
		assert (odd.x == 100 && odd.width == 2);
		assert (odd.y == -2 && odd.height == 3);
	}

	/**
	 * The hiding code used to scale the dock up to device pixels and meet
	 * the device geometry of each window; with logical geometry it meets
	 * the dock as it is.  Both must agree for every position.
	 */
	void platform_x11_device_to_logical_intersection ()
	{
		Gdk.Rectangle dock = { 3, 2, 4, 3 };

		for (var scale = 2; scale <= 3; scale++) {
			Gdk.Rectangle dock_device = { dock.x * scale, dock.y * scale, dock.width * scale, dock.height * scale };

			for (var x = -4; x < 30; x++)
				for (var width = 1; width < 8; width++)
					for (var y = -4; y < 20; y += 3)
						for (var height = 1; height < 7; height += 2) {
							Gdk.Rectangle window_device = { x, y, width, height };
							var logical = X11Toplevel.device_to_logical (x, y, width, height, scale);
							assert (window_device.intersect (dock_device, null) == logical.intersect (dock, null));
						}
		}
	}

	void platform_x11_map_state ()
	{
		var state = X11Toplevel.map_state (Wnck.WindowState.MINIMIZED | Wnck.WindowState.MAXIMIZED_VERTICALLY
			| Wnck.WindowState.DEMANDS_ATTENTION | Wnck.WindowState.SKIP_TASKLIST);
		assert (state == (ToplevelState.MINIMIZED | ToplevelState.MAXIMIZED_VERTICALLY
			| ToplevelState.URGENT | ToplevelState.SKIP_TASKBAR));
		assert (X11Toplevel.map_state (0) == 0);
	}
#endif

	const int DOCK_PID = 4242;
	const Gdk.Rectangle OVERLAP_DOCK = { 400, 730, 480, 70 };
	const Gdk.Rectangle OVERLAP_COVERING = { 0, 0, 1280, 800 };
	const Gdk.Rectangle OVERLAP_ASIDE = { 40, 40, 300, 200 };

	FakeToplevel overlap_window (FakeBackend backend, int pid, Gdk.Rectangle geometry,
		ToplevelKind kind = ToplevelKind.NORMAL)
	{
		var toplevel = new FakeToplevel ();
		toplevel.fake_pid = pid;
		toplevel.geometry = geometry;
		toplevel.fake_kind = kind;
		toplevel.on_workspaces.add (backend.fake_workspaces.active);
		return backend.fake_toplevels.add (toplevel);
	}

	FakeBackend overlap_backend ()
	{
		var backend = new FakeBackend (Capability.TOPLEVELS | Capability.TOPLEVEL_GEOMETRY | Capability.WORKSPACES);
		backend.fake_workspaces.add ();
		backend.fake_workspaces.add ();
		return backend;
	}

	WindowOverlap overlap_of (FakeBackend backend)
	{
		return WindowOverlap.compute (backend.toplevels, backend.workspaces, OVERLAP_DOCK, DOCK_PID);
	}

	void window_overlap_no_focus ()
	{
		var backend = overlap_backend ();
		overlap_window (backend, 10, OVERLAP_COVERING);

		var overlap = overlap_of (backend);
		assert (!overlap.any_window && !overlap.active_application);
	}

	void window_overlap_desktop_focused ()
	{
		var backend = overlap_backend ();
		overlap_window (backend, 10, OVERLAP_COVERING);
		backend.fake_toplevels.desktop_focused = true;

		var overlap = overlap_of (backend);
		assert (overlap.any_window);
		assert (!overlap.active_application && !overlap.active_window);
	}

	void window_overlap_active_maximized ()
	{
		var backend = overlap_backend ();
		var window = overlap_window (backend, 10, OVERLAP_COVERING);
		window.activate (0U);

		var overlap = overlap_of (backend);
		assert (overlap.any_window && overlap.active_application && overlap.active_window);
		assert (!overlap.active_maximized_window && !overlap.dialog_window);

		window.fake_state = ToplevelState.MAXIMIZED_VERTICALLY;
		overlap = overlap_of (backend);
		assert (overlap.active_maximized_window);

		window.move (OVERLAP_ASIDE);
		overlap = overlap_of (backend);
		assert (!overlap.any_window && !overlap.active_maximized_window);
	}

	void window_overlap_application_dialog ()
	{
		var backend = overlap_backend ();
		var main_window = overlap_window (backend, 10, OVERLAP_ASIDE);
		overlap_window (backend, 10, OVERLAP_COVERING, ToplevelKind.DIALOG);
		main_window.activate (0U);

		var overlap = overlap_of (backend);
		assert (overlap.any_window && overlap.active_application && overlap.dialog_window);
		assert (!overlap.active_window);

		var other = overlap_window (backend, 11, OVERLAP_COVERING);
		other.activate (0U);
		overlap = overlap_of (backend);
		assert (overlap.any_window && overlap.active_application && overlap.active_window);
		assert (!overlap.dialog_window);
	}

	void window_overlap_ignored_windows ()
	{
		var backend = overlap_backend ();
		var active = overlap_window (backend, 10, OVERLAP_ASIDE);
		active.activate (0U);

		var minimized = overlap_window (backend, 11, OVERLAP_COVERING);
		minimized.fake_state = ToplevelState.MINIMIZED;
		overlap_window (backend, DOCK_PID, OVERLAP_COVERING);
		var unknown_geometry = overlap_window (backend, 12, OVERLAP_COVERING);
		unknown_geometry.knows_geometry = false;

		var overlap = overlap_of (backend);
		assert (!overlap.any_window);
	}

	void window_overlap_workspaces ()
	{
		var backend = overlap_backend ();
		var active = overlap_window (backend, 10, OVERLAP_ASIDE);
		active.activate (0U);
		var elsewhere = overlap_window (backend, 11, OVERLAP_COVERING);
		elsewhere.on_workspaces.clear ();
		elsewhere.on_workspaces.add (backend.fake_workspaces.list ()[1]);

		assert (!overlap_of (backend).any_window);

		backend.fake_workspaces.list ()[1].activate (0U);
		active.on_workspaces.add (backend.fake_workspaces.list ()[1]);
		assert (overlap_of (backend).any_window);

		// Without workspaces every window counts; without an active one none does
		assert (WindowOverlap.compute (backend.toplevels, null, OVERLAP_DOCK, DOCK_PID).any_window);
		backend.fake_workspaces.set_active (null);
		assert (!overlap_of (backend).any_window);
	}

	void platform_show_desktop ()
	{
		var backend = new FakeBackend (Capability.WORKSPACES | Capability.SHOW_DESKTOP);
		set_backend_for_tests (backend);

		assert (can_show_desktop ());
		toggle_showing_desktop ();
		assert (backend.workspaces.showing_desktop);
		toggle_showing_desktop ();
		assert (!backend.workspaces.showing_desktop);

		backend.supported = Capability.WORKSPACES;
		assert (!can_show_desktop ());
		toggle_showing_desktop ();
		assert (!backend.workspaces.showing_desktop);

		set_backend_for_tests (null);
	}

	void platform_toplevel_waiter_known ()
	{
		var manager = new FakeToplevelManager ();
		var known = manager.add (new FakeToplevel ());
		var waiter = new ToplevelWaiter (manager);

		Toplevel? got = null;
		waiter.run (known.id, (toplevel) => got = toplevel);
		assert (got == known);
		assert (!waiter.is_waiting (known.id));
	}

	void platform_toplevel_waiter_later ()
	{
		var manager = new FakeToplevelManager ();
		var waiter = new ToplevelWaiter (manager);
		var window = new FakeToplevel.with_id (0x2a00007);

		var runs = 0;
		waiter.run (window.id, (toplevel) => {
			assert (toplevel == window);
			runs++;
		});
		waiter.run (window.id, () => runs++);
		assert (runs == 0);
		assert (waiter.is_waiting (window.id));

		// Other windows do not wake it up
		manager.add (new FakeToplevel ());
		assert (runs == 0);

		manager.add (window);
		assert (runs == 2);
		assert (!waiter.is_waiting (window.id));

		// Each action runs once
		manager.added (window);
		assert (runs == 2);
	}

	void platform_toplevel_waiter_cancel ()
	{
		var manager = new FakeToplevelManager ();
		var waiter = new ToplevelWaiter (manager);
		var window = new FakeToplevel.with_id (0x2a00009);

		var runs = 0;
		waiter.run (window.id, () => runs++);
		waiter.cancel (window.id);
		manager.add (window);
		assert (runs == 0);
	}

	void platform_app_tracker_fake ()
	{
		var backend = new FakeBackend (Capability.TOPLEVELS);
		var favorites = new Gee.ArrayList<string> ();
		favorites.add ("/usr/share/applications/example.desktop");
		backend.apps.set_favorites (favorites);
		assert (backend.fake_apps.favorites.size == 1);
		assert (backend.apps.running_apps ().size == 0);
		assert (backend.apps.app_for_desktop_file ("file:///usr/share/applications/example.desktop") == null);
	}
}
