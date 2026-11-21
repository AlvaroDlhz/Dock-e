//
//  Copyright (C) 2011-2012 Robert Dyer, Rico Tzschichholz
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
	 * A {@link Bamf.Application}.
	 */
	public class BamfApp : RunningApp
	{
		public Bamf.Application app { get; private set; }

		unowned BamfAppTracker tracker;
		bool closed_emitted = false;

		public override string? desktop_file {
			get {
				unowned string? file = app.get_desktop_file ();
				if (file == null || file == "")
					return null;
				return file;
			}
		}
		public override string name { owned get { return app.get_name (); } }
		public override bool is_running { get { return app.is_running (); } }
		public override bool is_active { get { return app.is_active (); } }
		public override bool is_urgent { get { return app.is_urgent (); } }
		public override bool is_user_visible { get { return app.is_user_visible (); } }

		internal BamfApp (BamfAppTracker tracker, Bamf.Application app)
		{
			this.tracker = tracker;
			this.app = app;

			app.active_changed.connect (handle_active_changed);
			app.urgent_changed.connect (handle_urgent_changed);
			app.running_changed.connect (handle_running_changed);
			app.user_visible_changed.connect (handle_user_visible_changed);
			app.name_changed.connect (handle_name_changed);
			app.window_added.connect (handle_window_added);
			app.window_removed.connect (handle_window_removed);
			app.closed.connect (handle_closed);
		}

		internal void detach ()
		{
			app.active_changed.disconnect (handle_active_changed);
			app.urgent_changed.disconnect (handle_urgent_changed);
			app.running_changed.disconnect (handle_running_changed);
			app.user_visible_changed.disconnect (handle_user_visible_changed);
			app.name_changed.disconnect (handle_name_changed);
			app.window_added.disconnect (handle_window_added);
			app.window_removed.disconnect (handle_window_removed);
			app.closed.disconnect (handle_closed);
		}

		public override Gee.List<Toplevel> get_windows ()
		{
			var result = new Gee.ArrayList<Toplevel> ();

			foreach (unowned Bamf.Window window in app.get_windows ()) {
				var toplevel = tracker.lookup_toplevel (window.get_xid ());
				if (toplevel != null)
					result.add (toplevel);
			}

			return result;
		}

		void handle_active_changed (bool active)
		{
			notify_property ("is-active");
		}

		void handle_urgent_changed (bool urgent)
		{
			notify_property ("is-urgent");
		}

		void handle_running_changed (bool running)
		{
			notify_property ("is-running");
		}

		void handle_user_visible_changed (bool user_visible)
		{
			notify_property ("is-user-visible");
		}

		void handle_name_changed (string old_name, string new_name)
		{
			notify_property ("name");
		}

		void handle_window_added (Bamf.Window window)
		{
			tracker.when_toplevel (window.get_xid (), (toplevel) => window_added (toplevel));
		}

		void handle_window_removed (Bamf.Window window)
		{
			var xid = window.get_xid ();
			tracker.forget_toplevel (xid);
			var toplevel = tracker.lookup_toplevel (xid);
			if (toplevel != null)
				window_removed (toplevel);
		}

		void handle_closed ()
		{
			emit_closed ();
		}

		void emit_closed ()
		{
			if (closed_emitted)
				return;
			closed_emitted = true;
			closed ();
		}

		/**
		 * BAMF reports the end of an application twice, on the matcher and
		 * on the application, in either order; it ends here once.
		 */
		internal void finish ()
		{
			emit_closed ();
			detach ();
		}
	}

	/**
	 * Applications as BAMF matches them, with the windows as toplevels of
	 * the X11 backend (their ids are XIDs).
	 */
	public class BamfAppTracker : Object, AppTracker
	{
		unowned X11Backend? backend;
		Gee.HashSet<Bamf.View> pending_views;
		Bamf.Matcher? bamf_matcher;
		Gee.HashMap<unowned Bamf.Application, BamfApp> apps;
		ToplevelWaiter? waiter = null;

		/**
		 * @param backend where the toplevels come from, or null for none
		 */
		public BamfAppTracker (X11Backend? backend)
		{
			this.backend = backend;
		}

		construct
		{
			pending_views = new Gee.HashSet<Bamf.View> ();
			apps = new Gee.HashMap<unowned Bamf.Application, BamfApp> ();

			bamf_matcher = Bamf.Matcher.get_default ();
			bamf_matcher.active_application_changed.connect_after (handle_active_application_changed);
			bamf_matcher.active_window_changed.connect_after (handle_active_window_changed);
			bamf_matcher.view_opened.connect_after (handle_view_opened);
			bamf_matcher.view_closed.connect_after (handle_view_closed);
		}

		~BamfAppTracker ()
		{
			foreach (var view in pending_views)
				view.user_visible_changed.disconnect (handle_view_user_visible_changed);

			foreach (var app in apps.values)
				app.detach ();

			bamf_matcher.active_application_changed.disconnect (handle_active_application_changed);
			bamf_matcher.active_window_changed.disconnect (handle_active_window_changed);
			bamf_matcher.view_opened.disconnect (handle_view_opened);
			bamf_matcher.view_closed.disconnect (handle_view_closed);
			bamf_matcher = null;
		}

		//
		// Toplevels, which Wnck may learn about after BAMF
		//

		internal Toplevel? lookup_toplevel (uint64 xid)
		{
			return (backend != null ? backend.toplevels.lookup_id (xid) : null);
		}

		internal void when_toplevel (uint64 xid, owned ToplevelReady action)
		{
			if (backend == null)
				return;
			if (waiter == null)
				waiter = new ToplevelWaiter (backend.toplevels);
			waiter.run (xid, (owned) action);
		}

		internal void forget_toplevel (uint64 xid)
		{
			if (waiter != null)
				waiter.cancel (xid);
		}

		BamfApp? wrap (Bamf.Application? app)
		{
			if (app == null)
				return null;

			var result = apps.get (app);
			if (result == null) {
				result = new BamfApp (this, app);
				apps.set (app, result);
			}

			return result;
		}

		//
		// BAMF events
		//

		void handle_active_application_changed (Bamf.Application? arg1, Bamf.Application? arg2)
		{
			active_app_changed (wrap (arg1), wrap (arg2));
		}

		void handle_active_window_changed (Bamf.Window? arg1, Bamf.Window? arg2)
		{
			active_window_changed (arg1 != null ? lookup_toplevel (arg1.get_xid ()) : null,
				arg2 != null ? lookup_toplevel (arg2.get_xid ()) : null);
		}

		void handle_view_user_visible_changed (Bamf.View view, bool user_visible)
		{
			if (!user_visible)
				return;

			promote_pending_view (view);
		}

		void promote_pending_view (Bamf.View view)
		{
			if (!pending_views.remove (view))
				return;

			view.user_visible_changed.disconnect (handle_view_user_visible_changed);
			handle_view_opened (view);
		}

		void handle_view_opened (Bamf.View arg1)
		{
			if (arg1 is Bamf.Application && !arg1.is_user_visible ()) {
				if (pending_views.add (arg1))
					arg1.user_visible_changed.connect_after (handle_view_user_visible_changed);

				// The visibility can change while is_user_visible() performs its
				// D-Bus roundtrip. Re-check after connecting so that transition
				// cannot be missed and leave the application pending forever.
				if (arg1.is_user_visible ())
					promote_pending_view (arg1);
				return;
			}

			if (arg1 is Bamf.Window) {
				unowned Bamf.Window window = (Bamf.Window) arg1;
				when_toplevel (window.get_xid (), (toplevel) => window_opened (toplevel));
			} else if (arg1 is Bamf.Application) {
				unowned Bamf.Application app = (Bamf.Application) arg1;
				app_opened (wrap (app));
			}
		}

		void handle_view_closed (Bamf.View arg1)
		{
			if (pending_views.remove (arg1)) {
				arg1.user_visible_changed.disconnect (handle_view_user_visible_changed);
				return;
			}

			if (arg1 is Bamf.Window) {
				unowned Bamf.Window window = (Bamf.Window) arg1;
				forget_toplevel (window.get_xid ());
			} else if (arg1 is Bamf.Application) {
				unowned Bamf.Application app = (Bamf.Application) arg1;
				BamfApp wrapper;
				if (!apps.unset (app, out wrapper))
					wrapper = new BamfApp (this, app);
				app_closed (wrapper);
				wrapper.finish ();
			}
		}

		//
		// Queries
		//

		Gee.ArrayList<Bamf.Application> bamf_running_applications ()
		{
			var apps = bamf_matcher.get_running_applications ();
			var list = new Gee.ArrayList<Bamf.Application> ();

			warn_if_fail (apps != null);
			if (apps == null)
				return list;

			foreach (var app in apps)
				list.add (app);

			return list;
		}

		Bamf.Application? bamf_app_for_uri (string uri)
		{
			string launcher;
			try {
				launcher = Filename.from_uri (uri);
			} catch (ConvertError e) {
				warning (e.message);
				return null;
			}

			unowned Bamf.Application app = bamf_matcher.get_application_for_desktop_file (launcher, false);

			warn_if_fail (app != null);

			return app;
		}

		public Gee.List<RunningApp> running_apps ()
		{
			var result = new Gee.ArrayList<RunningApp> ();
			foreach (var app in bamf_running_applications ())
				result.add (wrap (app));
			return result;
		}

		public RunningApp? app_for_desktop_file (string uri)
		{
			return wrap (bamf_app_for_uri (uri));
		}

		public void set_favorites (Gee.List<string> desktop_files)
		{
			var paths = new string[desktop_files.size];

			for (var i = 0; i < desktop_files.size; i++)
				paths [i] = desktop_files.get (i);

			bamf_matcher.register_favorites (paths);
		}
	}
}
