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
	 * The applications of BAMF, as the dock items still use them.
	 *
	 * Only a facade of {@link Platform.BamfAppTracker} now, kept until the
	 * dock items work with {@link Platform.RunningApp} (stage 10 in
	 * docs/x11-aislamiento.md).
	 */
	public class Matcher : GLib.Object
	{
		public signal void active_window_changed (Bamf.Window? old_win, Bamf.Window? new_win);
		public signal void window_opened (Bamf.Window w);
		public signal void window_closed (Bamf.Window w);
		
		public signal void active_application_changed (Bamf.Application? old_app, Bamf.Application? new_app);
		public signal void application_opened (Bamf.Application app);
		public signal void application_closed (Bamf.Application app);
		
		static Matcher? matcher = null;
		
		public static Matcher get_default ()
		{
			if (matcher == null)
				matcher = new Matcher ();
			return matcher;
		}
		
		Platform.BamfAppTracker tracker;
		
		private Matcher ()
		{
		}
		
		construct
		{
			unowned Platform.X11Backend? x11 = (Platform.get_backend () as Platform.X11Backend);
			tracker = (x11 != null ? x11.bamf_apps : new Platform.BamfAppTracker (null));
			
			tracker.bamf_active_application_changed.connect (forward_active_application_changed);
			tracker.bamf_active_window_changed.connect (forward_active_window_changed);
			tracker.bamf_window_opened.connect (forward_window_opened);
			tracker.bamf_window_closed.connect (forward_window_closed);
			tracker.bamf_application_opened.connect (forward_application_opened);
			tracker.bamf_application_closed.connect (forward_application_closed);
		}
		
		~Matcher ()
		{
			tracker.bamf_active_application_changed.disconnect (forward_active_application_changed);
			tracker.bamf_active_window_changed.disconnect (forward_active_window_changed);
			tracker.bamf_window_opened.disconnect (forward_window_opened);
			tracker.bamf_window_closed.disconnect (forward_window_closed);
			tracker.bamf_application_opened.disconnect (forward_application_opened);
			tracker.bamf_application_closed.disconnect (forward_application_closed);
		}
		
		void forward_active_application_changed (Bamf.Application? old_app, Bamf.Application? new_app)
		{
			active_application_changed (old_app, new_app);
		}
		
		void forward_active_window_changed (Bamf.Window? old_win, Bamf.Window? new_win)
		{
			active_window_changed (old_win, new_win);
		}
		
		void forward_window_opened (Bamf.Window w)
		{
			window_opened (w);
		}
		
		void forward_window_closed (Bamf.Window w)
		{
			window_closed (w);
		}
		
		void forward_application_opened (Bamf.Application app)
		{
			application_opened (app);
		}
		
		void forward_application_closed (Bamf.Application app)
		{
			application_closed (app);
		}
		
		public Gee.ArrayList<Bamf.Application> active_launchers ()
		{
			return tracker.bamf_running_applications ();
		}
		
		public Bamf.Application? app_for_uri (string uri)
		{
			return tracker.bamf_app_for_uri (uri);
		}
		
		public void set_favorites (Gee.ArrayList<string> favs)
		{
			tracker.set_favorites (favs);
		}
	}
}
